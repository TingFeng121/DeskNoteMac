import AppKit
import SwiftUI

// MARK: - SwiftUI 入口

/// Typora 式便签编辑器：# 井号、- 短横、[ ] 方括号、** 星号打完就消失，正文立刻变成
/// 标题/项目符号/勾选框/粗体，但 textStorage 里存的始终是原始 Markdown。
///
/// 之所以选「只改属性把符号藏起来」而不是「显示文本与存储文本分开维护」：
/// 前者让输入法组字、撤销重做、粘贴、选中全部走 AppKit 原生路径，我们不需要维护两套下标映射，
/// 存盘也就是把 string 交出去；后者任何一个环节算错下标都会吃掉用户打的字。
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// 桌面浮窗和正文栏打开即打字；卡片墙里的就地编辑不抢焦点，点谁哪儿。
    var autoFocus = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        let tv = MarkdownTextView()
        tv.baseFontSize = CGFloat(fontSize)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.inkColor = .labelColor
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        // 自动替换会把 -- 变成破折号、把引号换成弯引号，直接破坏 Markdown 语法
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.textContainer?.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NoteLayout.editorInset
        tv.delegate = context.coordinator
        tv.loadMarkdown(text, keepSelection: false)
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? MarkdownTextView else { return }
        context.coordinator.text = $text
        tv.baseFontSize = CGFloat(fontSize)
        // 只有外部改了正文才回写（预览里点勾、恢复备份、换一张便签）。自己打字时两边恒等，
        // 一旦整段重设，插入点就会被弹到末尾——「按删除键光标跳到最后」正是这么来的。
        if tv.string != text { tv.loadMarkdown(text) }
        if autoFocus, !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var didFocus = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? MarkdownTextView else { return }
            text.wrappedValue = tv.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? MarkdownTextView)?.selectionChanged()
        }
    }
}

// MARK: - 编辑器

final class MarkdownTextView: NSTextView {
    var baseFontSize: CGFloat = 13 {
        didSet { guard baseFontSize != oldValue else { return }; restyle() }
    }

    /// 正文墨色。绝不能就地取 `textColor`：那只是 typingAttributes 的一个投影，
    /// 而 typingAttributes 会被我们涂成 clear 的语法符号污染，取回来就是全透明，整段文字直接消失。
    var inkColor: NSColor = .labelColor

    /// 被藏起来的语法符号，删除键要整段吞掉而不是让用户去数看不见的字符
    private var hiddenRuns: [NSRange] = []
    /// 需要在页边额外画东西的行（项目符号、勾选圈、序号、引用条、分隔线）
    private var marks: [(para: NSRange, kind: MarkdownSyntax.LineKind)] = []
    private var codeParas: [NSRange] = []
    private var typingByPara: [(NSRange, [NSAttributedString.Key: Any])] = []
    private var restyling = false

    private static let hiddenParaStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 0.1
        p.maximumLineHeight = 0.1
        return p
    }()

    /// 藏字符 = 字号压到 0.1 再涂透明。试过 .expansion = -1，实测推进宽度并不会塌缩。
    /// 这里绝不能带 paragraphStyle：段落样式取段首字符那份，行首标记正好是段首，
    /// 一塞进去整行（标题、列表、分隔线）都会被压成 0.1 高。
    private static let hiddenRunAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 0.1),
        .foregroundColor: NSColor.clear,
    ]

    /// 整行都要塌掉的（代码围栏那两行 ```）才允许带段落样式
    private static let hiddenLineAttrs: [NSAttributedString.Key: Any] = {
        var attrs = hiddenRunAttrs
        attrs[.paragraphStyle] = hiddenParaStyle
        return attrs
    }()

    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    /// 外部整体替换正文：绕开 didChangeText，免得把改动又回写一遍存储层
    func loadMarkdown(_ md: String, keepSelection: Bool = true) {
        let caret = min(selectedRange().location, (md as NSString).length)
        let base = NSFont.systemFont(ofSize: baseFontSize)
        textStorage?.setAttributedString(NSAttributedString(string: md, attributes: [
            .font: base,
            .foregroundColor: inkColor,
            .paragraphStyle: MarkdownStyle.para(.plain, size: baseFontSize),
        ]))
        restyle()
        if keepSelection { setSelectedRange(NSRange(location: caret, length: 0)) }
    }

    // MARK: 排版

    func restyle() {
        // 输入法正在组字时不能动属性，否则候选框会跳、上屏会错
        guard !restyling, let storage = textStorage, !hasMarkedText() else { return }
        restyling = true
        defer { restyling = false }

        let ns = storage.string as NSString
        let ink = inkColor
        let base = NSFont.systemFont(ofSize: baseFontSize)

        hiddenRuns = []
        marks = []
        codeParas = []
        typingByPara = []

        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: ink,
                               .paragraphStyle: MarkdownStyle.para(.plain, size: baseFontSize)],
                              range: NSRange(location: 0, length: ns.length))
        var inFence = false
        MarkdownSyntax.forEachParagraph(ns) { para, raw in
            let content = MarkdownSyntax.contentRange(ns, para)
            let line = ns.substring(with: content)
            let info = MarkdownSyntax.classify(line)

            if info.kind == .fence {
                // 围栏连换行一起缩掉，这一行塌成 0 高，看起来跟不存在一样
                storage.addAttributes(Self.hiddenLineAttrs, range: para)
                hiddenRuns.append(para)
                inFence.toggle()
                return
            }
            style(kind: inFence ? .code : info.kind, para: para, content: content,
                  line: line, info: info, storage: storage, ink: ink)
        }
        storage.endEditing()

        needsDisplay = true
        syncTypingAttributes()
    }

    private func style(kind: MarkdownSyntax.LineKind, para: NSRange, content: NSRange, line: String,
                       info: MarkdownSyntax.LineInfo, storage: NSTextStorage, ink: NSColor) {
        var font = NSFont.systemFont(ofSize: baseFontSize)
        var color = ink
        switch kind {
        case .plain, .fence, .bullet, .todo, .numbered, .divider:
            break
        case let .heading(level):
            font = NSFont.systemFont(ofSize: MarkdownSyntax.headingSize(baseFontSize, level), weight: .bold)
        case .quote:
            color = .secondaryLabelColor
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        case .code:
            font = NSFont.monospacedSystemFont(ofSize: max(9, baseFontSize - 1), weight: .regular)
            codeParas.append(para)
        }

        let paraStyle = MarkdownStyle.para(kind, size: baseFontSize)
        storage.addAttribute(.paragraphStyle, value: paraStyle, range: para)
        if content.length > 0 {
            storage.addAttribute(.font, value: font, range: content)
            storage.addAttribute(.foregroundColor, value: color, range: content)
        }

        if kind != .code, kind != .divider, content.length > 0 {
            for mark in MarkdownSyntax.inlineMarks(storage.string as NSString, in: content) {
                var f = font
                if mark.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if mark.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if mark.mono { f = NSFont.monospacedSystemFont(ofSize: f.pointSize, weight: .regular) }
                storage.addAttribute(.font, value: f, range: mark.inner)
                if mark.strike {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                         range: mark.inner)
                }
                for d in mark.delims where d.length > 0 {
                    storage.addAttributes(Self.hiddenRunAttrs, range: d)
                    hiddenRuns.append(d)
                }
            }
        }

        // 行首标记最后藏：前面所有属性都按整段铺过，这一步盖上去才不会又被放大。
        // 必须用 addAttributes——段落的排版样式取段首字符那一份，setAttributes 会把它抹掉，
        // 整行于是退化成 0.1pt 行高。
        let marker = NSRange(location: content.location + info.marker.location,
                             length: min(info.marker.length,
                                         max(0, content.length - info.marker.location)))
        if marker.length > 0 {
            storage.addAttributes(Self.hiddenRunAttrs, range: marker)
            hiddenRuns.append(marker)
        }
        if kind == .divider, content.length > 0 {
            storage.addAttributes(Self.hiddenRunAttrs, range: content)
            hiddenRuns.append(content)
        }

        switch kind {
        case .bullet, .todo, .numbered, .quote, .divider: marks.append((para, kind))
        default: break
        }
        typingByPara.append((para, [.font: font, .foregroundColor: color, .paragraphStyle: paraStyle]))
    }

    /// 光标停在被隐藏的语法符号上时，存储里的字是 0.1pt 透明的，直接打字就等于没打。
    /// 所以打字用的属性按「这一段本来该长什么样」给，而不是照抄存储。
    func syncTypingAttributes() {
        let ns = string as NSString
        guard ns.length > 0 else { return }
        let loc = min(max(0, selectedRange().location), max(0, ns.length - 1))
        let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        if let attrs = typingByPara.first(where: { $0.0 == para })?.1 {
            typingAttributes = attrs
        }
    }

    func selectionChanged() {
        syncTypingAttributes()
        // 光标掉进看不见的符号中间时挪到符号末尾，不然打进去的字会被当成语法符号吃掉
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        for run in hiddenRuns where run.location < sel.location && sel.location < NSMaxRange(run)
            && NSMaxRange(run) <= storage.length {
            setSelectedRange(NSRange(location: NSMaxRange(run), length: 0))
            return
        }
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        drawCodeBlocks(dirtyRect)
        super.draw(dirtyRect)
        drawMarginMarks(dirtyRect)
    }

    private func fragments() -> (NSLayoutManager, NSTextContainer, NSString)? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return nil }
        return (lm, tc, storage.string as NSString)
    }

    private func drawCodeBlocks(_ dirtyRect: NSRect) {
        guard !codeParas.isEmpty, let (lm, tc, ns) = fragments(), ns.length > 0 else { return }
        let origin = textContainerOrigin
        let width = tc.size.width
        // quaternaryLabelColor 本身只有 ~0.1 不透明度，再乘一层就什么都看不见了
        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        var merged: [NSRange] = []
        for para in codeParas {
            if let last = merged.last, last.location + last.length == para.location {
                merged[merged.count - 1] = NSRange(location: last.location, length: last.length + para.length)
            } else {
                merged.append(para)
            }
        }
        for range in merged {
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let r = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
            guard r.intersects(dirtyRect) else { continue }
            NSBezierPath(roundedRect: NSRect(x: origin.x, y: r.minY - 4, width: max(1, width),
                                             height: r.height + 8),
                         xRadius: 5, yRadius: 5).fill()
        }
    }

    private func drawMarginMarks(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let (lm, tc, ns) = fragments(), ns.length > 0 else { return }
        let origin = textContainerOrigin
        for entry in marks {
            let glyphs = lm.glyphRange(forCharacterRange: entry.para, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var used = NSRange(location: 0, length: 0)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &used)
            guard fragment.height > 0 else { continue }
            let full = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let ps = MarkdownStyle.para(entry.kind, size: baseFontSize)
            // 正文从 firstLineHeadIndent 起排，符号就占它前面那条页边
            let slot = NSRect(x: origin.x + fragment.minX + 2,
                              y: origin.y + fragment.minY,
                              width: max(10, ps.firstLineHeadIndent - 5),
                              height: fragment.height)
            let box = NSRect(x: origin.x + full.minX, y: origin.y + full.minY,
                             width: full.width, height: full.height)
            guard slot.intersects(dirtyRect) || box.intersects(dirtyRect) else { continue }
            draw(entry.kind, at: slot, full: box)
        }
    }

    private func draw(_ kind: MarkdownSyntax.LineKind, at slot: NSRect, full: NSRect) {
        switch kind {
        case .bullet:
            label("•", in: slot, color: .secondaryLabelColor, alignment: .center)
        case let .numbered(digits):
            // 右对齐：1. 和 12. 的句点要对齐，正文才不会被推来推去
            label(digits + ".", in: slot, color: .secondaryLabelColor, alignment: .right)
        case let .todo(done):
            checkbox(in: slot, done: done)
        case .quote:
            let bar = NSRect(x: slot.minX + 1, y: full.minY + 2, width: 2, height: max(2, full.height - 4))
            NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        case .divider:
            NSColor.separatorColor.setStroke()
            let rule = NSBezierPath()
            rule.lineWidth = 1
            rule.move(to: NSPoint(x: full.minX + 2, y: full.midY))
            rule.line(to: NSPoint(x: full.maxX - 2, y: full.midY))
            rule.stroke()
        default:
            break
        }
    }

    private func label(_ text: String, in rect: NSRect, color: NSColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: baseFontSize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func checkbox(in rect: NSRect, done: Bool) {
        let d = max(10, baseFontSize)
        let box = NSRect(x: rect.midX - d / 2, y: rect.minY + (rect.height - d) / 2, width: d, height: d)
        let circle = NSBezierPath(ovalIn: box.insetBy(dx: 0.8, dy: 0.8))
        circle.lineWidth = 1.2
        if done {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let tick = NSBezierPath()
            tick.lineWidth = 1.4
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.move(to: NSPoint(x: box.minX + d * 0.28, y: box.midY))
            tick.line(to: NSPoint(x: box.minX + d * 0.44, y: box.minY + d * 0.22))
            tick.line(to: NSPoint(x: box.minX + d * 0.74, y: box.maxY - d * 0.24))
            tick.stroke()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            circle.stroke()
        }
    }

    // MARK: 输入

    /// 回车续上同一级列表；空条目回车则收掉标记，回到普通段落。
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0, !hasMarkedText(), ns.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let para = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length - 1), length: 0))
        let content = MarkdownSyntax.contentRange(ns, para)
        let line = ns.substring(with: content)
        let lineNS = line as NSString
        let info = MarkdownSyntax.classify(line)
        let head = lineNS.substring(to: min(info.marker.location, lineNS.length))
        let marker = lineNS.substring(with: info.marker)
        let bodyStart = min(NSMaxRange(info.marker), lineNS.length)
        let body = lineNS.substring(from: bodyStart).trimmingCharacters(in: .whitespaces)

        let next: String
        switch info.kind {
        case .bullet: next = head + marker
        case .todo: next = head + "- [ ] "
        case let .numbered(digits): next = head + "\((Int(digits) ?? 0) + 1). "
        case .quote: next = head + "> "
        default:
            super.insertNewline(sender)
            return
        }
        guard !body.isEmpty else {
            // 空条目：这一行只剩标记，删掉标记就是退出列表
            let run = NSRange(location: content.location + info.marker.location, length: info.marker.length)
            if run.length > 0, shouldChangeText(in: run, replacementString: "") {
                replaceCharacters(in: run, with: "")
                didChangeText()
            }
            return
        }
        insertText("\n" + next, replacementRange: sel)
    }

    /// 删除键一次吞掉整段语法符号：符号是看不见的，一个一个删会让用户摸不着头脑。
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0,
           let run = hiddenRuns.first(where: { $0.length > 0 && NSMaxRange($0) == sel.location }) {
            let range = NSRange(location: run.location, length: sel.location - run.location)
            if range.length > 0, shouldChangeText(in: range, replacementString: "") {
                replaceCharacters(in: range, with: "")
                didChangeText()
                return
            }
        }
        super.deleteBackward(sender)
    }

    // 撤销/重做可能只回滚字符串不滚属性，存储层一动就重新排版一次
    private var observesStorage = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !observesStorage, let storage = textStorage else { return }
        observesStorage = true
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                               object: storage, queue: .main) { [weak self] _ in
            self?.restyle()
        }
    }
}

// MARK: - 语法识别

enum MarkdownSyntax {
    enum LineKind: Equatable {
        case plain, heading(Int), bullet, todo(Bool), numbered(String), quote, divider, fence, code
    }

    struct LineInfo {
        var kind: LineKind = .plain
        /// 行首要藏起来的语法符号，按行内 UTF-16 偏移计（标记全是 ASCII，跟字符数一致）
        var marker = NSRange(location: 0, length: 0)
    }

    struct InlineMark {
        var inner = NSRange()
        var delims: [NSRange] = []
        var bold = false
        var italic = false
        var mono = false
        var strike = false
    }

    static func headingSize(_ base: CGFloat, _ level: Int) -> CGFloat {
        base + (level == 1 ? 5 : level == 2 ? 3 : 1)
    }

    static func forEachParagraph(_ ns: NSString, _ body: (NSRange, String) -> Void) {
        var loc = 0
        while loc < ns.length {
            let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            body(para, ns.substring(with: para))
            loc = max(NSMaxRange(para), loc + 1)
        }
    }

    /// 段落区间含结尾换行，去掉换行才是这一行的实际文字
    static func contentRange(_ ns: NSString, _ para: NSRange) -> NSRange {
        var len = para.length
        if len > 0 {
            let last = ns.character(at: para.location + len - 1)
            if last == 0x0A || last == 0x0D { len -= 1 }
        }
        return NSRange(location: para.location, length: len)
    }

    static func classify(_ raw: String) -> LineInfo {
        let ns = raw as NSString
        var info = LineInfo()
        var lead = 0
        while lead < ns.length, ns.character(at: lead) == 0x20 || ns.character(at: lead) == 0x09 { lead += 1 }
        guard lead < ns.length else { return info }
        let t = Array(raw.dropFirst(lead))

        if t.count >= 3, t[0] == "`", t[1] == "`", t[2] == "`" {
            info.kind = .fence
            info.marker = NSRange(location: 0, length: ns.length)
            return info
        }
        let s = String(t)
        if s == "---" || s == "***" || s == "___" {
            info.kind = .divider
            info.marker = NSRange(location: lead, length: s.count)
            return info
        }
        var hashes = 0
        while hashes < 3, hashes < t.count, t[hashes] == "#" { hashes += 1 }
        if hashes > 0, hashes < t.count, t[hashes] == " " {
            info.kind = .heading(hashes)
            info.marker = NSRange(location: lead, length: hashes + 1)
            return info
        }
        if t.count >= 6, t[0] == "-", t[1] == " ", t[2] == "[",
           t[3] == " " || t[3] == "x" || t[3] == "X", t[4] == "]", t[5] == " " {
            info.kind = .todo(t[3] != " ")
            info.marker = NSRange(location: lead, length: 6)
            return info
        }
        if t.count >= 2, t[1] == " ", t[0] == "-" || t[0] == "*" || t[0] == "+" {
            info.kind = .bullet
            info.marker = NSRange(location: lead, length: 2)
            return info
        }
        var digits = 0
        while digits < t.count, t[digits].isNumber, t[digits].isASCII { digits += 1 }
        if digits > 0, digits + 1 < t.count, t[digits] == ".", t[digits + 1] == " " {
            info.kind = .numbered(String(t[0..<digits]))
            info.marker = NSRange(location: lead, length: digits + 2)
            return info
        }
        if t[0] == ">" {
            info.kind = .quote
            info.marker = NSRange(location: lead, length: t.count > 1 && t[1] == " " ? 2 : 1)
            return info
        }
        return info
    }

    private struct Rule {
        var pattern: String
        var bold = false, italic = false, mono = false, strike = false
    }

    private static let rules: [Rule] = [
        Rule(pattern: "\\*\\*([+\\s\\S]+?)\\*\\*", bold: true),
        Rule(pattern: "__([+\\s\\S]+?)__", bold: true),
        Rule(pattern: "~~([+\\s\\S]+?)~~", strike: true),
        Rule(pattern: "`([^`\\n]+)`", mono: true),
        Rule(pattern: "(?<!\\*)\\*([^*\\n]+?)\\*(?!\\*)", italic: true),
        Rule(pattern: "(?<!_)_([^_\\n]+?)_(?!_)", italic: true),
    ]

    private static let compiled: [(NSRegularExpression, Rule)] = rules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule) }
    }

    static func inlineMarks(_ ns: NSString, in range: NSRange) -> [InlineMark] {
        let text = ns.substring(with: range)
        let haystack = text as NSString
        var out: [InlineMark] = []
        var taken = IndexSet()
        for (regex, rule) in compiled {
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: haystack.length)) { match, _, _ in
                guard let match, match.numberOfRanges == 2 else { return }
                let inner = match.range(at: 1)
                guard inner.location != NSNotFound, inner.length > 0 else { return }
                let whole = match.range(at: 0)
                var overlap = IndexSet(integersIn: whole.location..<NSMaxRange(whole))
                overlap.formIntersection(taken)
                guard overlap.isEmpty else { return }
                taken.formUnion(IndexSet(integersIn: whole.location..<NSMaxRange(whole)))
                let shift = range.location
                var mark = InlineMark()
                mark.inner = NSRange(location: inner.location + shift, length: inner.length)
                mark.bold = rule.bold
                mark.italic = rule.italic
                mark.mono = rule.mono
                mark.strike = rule.strike
                let head = NSRange(location: whole.location + shift, length: inner.location - whole.location)
                let tail = NSRange(location: NSMaxRange(inner) + shift,
                                   length: NSMaxRange(whole) - NSMaxRange(inner))
                mark.delims = [head, tail]
                out.append(mark)
            }
        }
        return out
    }
}

// MARK: - 段落样式

enum MarkdownStyle {
    static func para(_ kind: MarkdownSyntax.LineKind, size: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = size * 0.22
        switch kind {
        // 缩进就是页边符号的位置：正文从 firstLineHeadIndent 起排，符号画在 [2, indent-3] 这一段，
        // 换行继续排也要对齐正文，所以 headIndent 跟它取一样。
        case .bullet:
            p.firstLineHeadIndent = 20
            p.headIndent = 20
        case .todo:
            p.firstLineHeadIndent = 23
            p.headIndent = 23
        case .numbered:
            p.firstLineHeadIndent = 27
            p.headIndent = 27
        case .quote:
            p.firstLineHeadIndent = 15
            p.headIndent = 15
        case .code:
            p.firstLineHeadIndent = 8
            p.headIndent = 8
        case .divider:
            // 正文（---）被藏成 0.1pt，行高得手动撑回来，不然分隔线挤成一条缝
            p.minimumLineHeight = size
            p.maximumLineHeight = size
            p.lineSpacing = size * 0.3
        case .heading(let level):
            p.lineSpacing = size * (level == 1 ? 0.34 : 0.24)
        case .plain, .fence:
            break
        }
        return p
    }
}
