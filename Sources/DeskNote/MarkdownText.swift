import SwiftUI

struct ReminderPreset: Identifiable {
    let title: String
    let date: Date
    var id: String { title }
}

enum NoteBlock: Identifiable {
    case heading(level: Int, text: String, line: Int)
    case todo(text: String, done: Bool, line: Int)
    case bullet(text: String, line: Int)
    case numbered(text: String, marker: String, line: Int)
    case quote(text: String, line: Int)
    case code(text: String, line: Int)
    case divider(line: Int)
    case paragraph(text: String, line: Int)

    var line: Int {
        switch self {
        case .heading(_, _, let l), .todo(_, _, let l), .bullet(_, let l), .numbered(_, _, let l),
             .quote(_, let l), .code(_, let l), .divider(let l), .paragraph(_, let l):
            return l
        }
    }

    var id: Int { line }
}

/// 只做块级解析，行内交给系统自带的 Markdown 解析器（加粗/斜体/行内代码/删除线都免费）
enum MarkdownText {
    static func blocks(from text: String) -> [NoteBlock] {
        var out: [NoteBlock] = []
        var inCode = false
        var codeStart = 0
        var codeLines: [String] = []

        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(text: codeLines.joined(separator: "\n"), line: codeStart))
                    codeLines = []
                    inCode = false
                } else {
                    inCode = true
                    codeStart = index
                }
                continue
            }
            if inCode {
                codeLines.append(raw)
                continue
            }
            if trimmed.isEmpty { continue }
            out.append(block(of: trimmed, line: index))
        }
        if inCode {
            out.append(.code(text: codeLines.joined(separator: "\n"), line: codeStart))
        }
        return out
    }

    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// 只翻转行内的 [ ] / [x] 标记，其余字符原样保留
    static func setCheckbox(_ line: String, done: Bool) -> String {
        guard let range = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return line }
        return line.replacingCharacters(in: range, with: done ? "[x]" : "[ ]")
    }

    static func reminderPresets(now: Date = Date()) -> [ReminderPreset] {
        let cal = Calendar.current
        let tomorrowNine = cal.date(byAdding: .day, value: 1, to: cal.date(
            bySettingHour: 9, minute: 0, second: 0, of: now) ?? now) ?? now
        return [
            ReminderPreset(title: "15 分钟后", date: now.addingTimeInterval(60 * 15)),
            ReminderPreset(title: "1 小时后", date: now.addingTimeInterval(3600)),
            ReminderPreset(title: "3 小时后", date: now.addingTimeInterval(3600 * 3)),
            ReminderPreset(title: "明早 9 点", date: tomorrowNine),
        ]
    }

    // MARK: - 单行判定

    private static func block(of t: String, line index: Int) -> NoteBlock {
        if t == "---" || t == "***" || t == "___" { return .divider(line: index) }
        if let (level, text) = heading(t) { return .heading(level: level, text: text, line: index) }
        if t.hasPrefix("> ") { return .quote(text: String(t.dropFirst(2)), line: index) }
        if t == ">" { return .quote(text: "", line: index) }
        if let body = bulletBody(t) {
            if body.hasPrefix("[ ] ") { return .todo(text: String(body.dropFirst(4)), done: false, line: index) }
            if body.lowercased().hasPrefix("[x] ") { return .todo(text: String(body.dropFirst(4)), done: true, line: index) }
            return .bullet(text: body, line: index)
        }
        if let (marker, text) = numberedItem(t) { return .numbered(text: text, marker: marker, line: index) }
        return .paragraph(text: t, line: index)
    }

    private static func heading(_ t: String) -> (Int, String)? {
        var rest = Substring(t)
        var level = 0
        while rest.first == "#", level < 3 {
            rest = rest.dropFirst()
            level += 1
        }
        guard level > 0, rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    private static func bulletBody(_ t: String) -> String? {
        for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) { return String(t.dropFirst(2)) }
        return nil
    }

    private static func numberedItem(_ t: String) -> (String, String)? {
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, t.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return ("\(digits).", String(t.dropFirst(digits.count + 2)))
    }
}

struct NoteBodyView: View {
    let text: String
    var fontSize: Double = 13
    var interactive = false
    var onToggle: ((Int, Bool) -> Void)?

    var body: some View {
        let all = MarkdownText.blocks(from: text)
        VStack(alignment: .leading, spacing: fontSize * 0.3) {
            if all.isEmpty {
                Text("空便签")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
            }
            ForEach(all) { block in
                NoteBlockRow(block: block, fontSize: fontSize,
                             interactive: interactive, onToggle: onToggle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteBlockRow: View {
    let block: NoteBlock
    var fontSize: Double
    var interactive: Bool
    var onToggle: ((Int, Bool) -> Void)?

    var body: some View {
        switch block {
        case let .heading(level, text, _):
            Text(MarkdownText.inline(text))
                .font(.system(size: fontSize + (level == 1 ? 5 : level == 2 ? 3 : 1), weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

        case let .todo(text, done, line):
            let row = HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: fontSize))
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
                lineText(text)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            // 整行可点：13pt 的勾选圈太小，预览态点哪都该算勾上。
            // 不可交互时不能留这个手势，否则卡片墙里点这一行会把点击吃掉，进不了就地编辑。
            if interactive {
                row.onTapGesture { onToggle?(line, !done) }
            } else {
                row
            }

        case let .bullet(text, _):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("•")
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: fontSize, alignment: .leading)
                lineText(text)
            }

        case let .numbered(text, marker, _):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker)
                    .font(.system(size: fontSize - 1).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: fontSize * 1.6, alignment: .trailing)
                lineText(text)
            }

        case let .quote(text, _):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 2)
                lineText(text).italic().foregroundStyle(.secondary)
            }

        case let .code(text, _):
            Text(text)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))

        case .divider:
            Divider().opacity(0.5).padding(.vertical, 2)

        case let .paragraph(text, _):
            lineText(text)
        }
    }

    private func lineText(_ text: String) -> some View {
        Text(MarkdownText.inline(text)).font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
    }
}
