import Foundation
import CryptoKit

/// 阅读模式的解析：把一篇 Markdown 切成「一段散文 / 一张表 / 一张图」。
///
/// 单独一个文件是因为它**不带 SwiftUI 和 AppKit**：`LibraryReader` 那一半要画表格、解图片，
/// 回归测试层链不进去；解析本身才是会写坏的那一半（`run.sh` 的第五层 `reader` 就测它）。
///
/// 解析是纯函数，输入只有那篇文本；缓存挂在 `ReaderCache` 上，键是内容哈希——
/// 改名、移动、重开同一篇都不必再解析一遍。
enum ReaderParse {
    /// 一行 Base64 内嵌图最多按这么多字节去解。解码出来的位图比这串码大一个量级，
    /// 再叠上「画一帧解一次」，不封顶就是拿滚动换内存。超限额的连摘要都不给，压根不解。
    static let maximumDataURIBytes = 32 * 1024 * 1024

    /// `shouldStop` 每 256 行查一次。大文档一次解析要几十毫秒到几百毫秒，
    /// 用户接着打字时这一轮就该立刻作废——不然同时跑着 N 份整篇解析，
    /// 而 `Task.detached` 不继承取消，取消信号只能这样自己查。
    /// 返回 nil 表示没解析完；调用方留着上一版画面就行，别把半截结果摆上去。
    /// 散文攒到这么多字节就在**行边界**收口。
    ///
    /// 不是为了解析快，是为了画得动：一段散文交给 `NoteBodyView`，它每帧都要在主线程把这一串
    /// 重切成块（`MarkdownText.blocks`）。一篇没有表格没有图片的长文原本会整篇变成一个 chunk，
    /// 于是 30 MB 那一档每次刷新都在主线程重切一遍——界面就卡在这条上。
    /// 切成 32 KB 一块之后，重切的最坏情况是个常数，滚动时看得见的块才参与计算。
    static let markdownChunkBytes = 32 * 1024

    /// `shouldStop` 每 256 行查一次。大文档一次解析要几十毫秒到几百毫秒，
    /// 用户接着打字时这一轮就该立刻作废——不然同时跑着 N 份整篇解析，
    /// 而 `Task.detached` 不继承取消，取消信号只能这样自己查。
    /// 返回 nil 表示没解析完；调用方留着上一版画面就行，别把半截结果摆上去。
    static func parse(_ text: String, shouldStop: () -> Bool = { false }) -> [ReaderItem]? {
        let lines = text.components(separatedBy: .newlines)
        var result: [ReaderItem] = []
        var markdown: [String] = []
        var pendingBytes = 0
        var index = 0

        func flushMarkdown() {
            guard !markdown.isEmpty else { return }
            let source = markdown.joined(separator: "\n")
            markdown.removeAll(keepingCapacity: true)
            pendingBytes = 0
            // 一行放两张图时，中间那个空格也会攒成一段。空段交给 NoteBodyView 就是那句
            // 「空便签」占位——两张图之间凭空多一行灰字，所以这段压根不该进结果。
            guard source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
            result.append(ReaderItem(id: result.count, content: .markdown(wikiLinks(in: source))))
        }

        /// 只在整行上进这一块。图片那一支切的是同一行的两半，切完立刻收口，攒不起重量。
        func accumulate(_ line: String) {
            if pendingBytes >= markdownChunkBytes { flushMarkdown() }
            markdown.append(line)
            pendingBytes += line.utf8.count + 1
        }

        while index < lines.count {
            if index & 255 == 0, shouldStop() { return nil }
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Keep fenced code intact: neither tables, images, nor wiki links are interpreted in it.
            if trimmed.hasPrefix("```") {
                flushMarkdown()
                var fence = [line]
                index += 1
                while index < lines.count {
                    let codeLine = lines[index]
                    fence.append(codeLine)
                    index += 1
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                }
                result.append(ReaderItem(id: result.count, content: .markdown(fence.joined(separator: "\n"))))
                continue
            }

            if index + 1 < lines.count, let header = tableCells(line), isTableDivider(lines[index + 1]) {
                flushMarkdown()
                let alignments = dividerAlignments(lines[index + 1])
                var rows = [header]
                index += 2
                while index < lines.count, let row = tableCells(lines[index]) {
                    rows.append(row)
                    index += 1
                }
                result.append(ReaderItem(id: result.count, content: .table(rows, alignments)))
                continue
            }

            // Pull image syntax into its own view so local files can be rendered as native images.
            let matches = imageMatches(in: line)
            if !matches.isEmpty {
                var cursor = line.startIndex
                for match in matches {
                    // Keep malformed/overlapping syntax from producing an invalid String slice.
                    guard match.range.lowerBound >= cursor else { continue }
                    let before = String(line[cursor..<match.range.lowerBound])
                    if !before.isEmpty { markdown.append(before) }
                    flushMarkdown()
                    result.append(ReaderItem(id: result.count,
                                             content: .image(match.alt, match.destination, match.width, match.dataCacheKey)))
                    cursor = match.range.upperBound
                }
                let after = String(line[cursor...])
                if !after.isEmpty { markdown.append(after) }
                index += 1
                continue
            }

            accumulate(line)
            index += 1
        }
        flushMarkdown()
        return result
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func isTableDivider(_ line: String) -> Bool {
        guard let cells = tableCells(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }

    private static func dividerAlignments(_ line: String) -> [CellAlignment] {
        (tableCells(line) ?? []).map { cell in
            if cell.hasPrefix(":") && cell.hasSuffix(":") { return .center }
            if cell.hasSuffix(":") { return .trailing }
            return .leading
        }
    }

    private static func imageMatches(in line: String) -> [ReaderImageMatch] {
        guard line.contains("![") else { return [] }
        var wikiMatches: [ReaderImageMatch] = []
        if let wikiRegex = try? NSRegularExpression(pattern: #"!\[\[([^\]]+)\]\]"#) {
            for match in wikiRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let whole = Range(match.range, in: line),
                      let innerRange = Range(match.range(at: 1), in: line) else { continue }
                let inner = String(line[innerRange])
                let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let destination = String(parts.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let width = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                let cleanDestination = unwrappedDestination(destination)
                wikiMatches.append(ReaderImageMatch(range: whole, alt: "", destination: cleanDestination, width: width,
                                                    dataCacheKey: dataCacheKey(for: cleanDestination), isWiki: true))
            }
        }

        // Accept both angle-bracket paths and unwrapped paths containing spaces.
        var markdownMatches: [ReaderImageMatch] = []
        if let markdownRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\((<[^>]+>|.*?)(?:\s+\"[^\"]*\")?\)"#) {
            for match in markdownRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let whole = Range(match.range, in: line),
                      let altRange = Range(match.range(at: 1), in: line),
                      let destinationRange = Range(match.range(at: 2), in: line) else { continue }
                let alt = String(line[altRange])
                let destination = unwrappedDestination(String(line[destinationRange]))
                markdownMatches.append(ReaderImageMatch(range: whole, alt: alt, destination: destination, width: nil,
                                                       dataCacheKey: dataCacheKey(for: destination), isWiki: false))
            }
        }
        // Obsidian embeds take precedence if a malformed hybrid line matches both syntaxes.
        var found = wikiMatches + markdownMatches.filter { markdown in
            !wikiMatches.contains { wiki in
                markdown.range.lowerBound < wiki.range.upperBound && wiki.range.lowerBound < markdown.range.upperBound
            }
        }
        found.removeAll { isInsideInlineCode(at: $0.range.lowerBound, in: line) }
        return found.sorted {
            if $0.range.lowerBound == $1.range.lowerBound { return $0.isWiki && !$1.isWiki }
            return $0.range.lowerBound < $1.range.lowerBound
        }
    }

    private static func isInsideInlineCode(at position: String.Index, in line: String) -> Bool {
        guard let ticks = try? NSRegularExpression(pattern: #"`+"#) else { return false }
        let prefix = String(line[..<position])
        let matches = ticks.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
        var delimiter: String?
        for match in matches {
            guard let range = Range(match.range, in: prefix) else { continue }
            let current = String(prefix[range])
            if delimiter == current { delimiter = nil }
            else if delimiter == nil { delimiter = current }
        }
        return delimiter != nil
    }

    private static func unwrappedDestination(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "<", trimmed.last == ">" {
            return String(trimmed.dropFirst().dropLast())
        }
        if let title = trimmed.range(of: #"\s+\"[^\"]*\"$"#, options: .regularExpression) {
            return String(trimmed[..<title.lowerBound])
        }
        return trimmed
    }

    /// data URI 的摘要在解析这一趟算一次：画一张图就要重刷一遍几十万字符的哈希，
    /// 那是把「滚动」变成「重新编码」。超过限额的不给摘要，也就不会去解那串码。
    private static func dataCacheKey(for destination: String) -> String? {
        guard destination.lowercased().hasPrefix("data:"), destination.utf8.count <= maximumDataURIBytes else { return nil }
        return digest(destination)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `[[目标]]` / `[[目标|别名]]` 换成能点的链接。代码段里的那一串不动——
    /// 表格单元格也走这里，所以视图那一侧要能拿到它，不再另写一份。
    static func wikiLinks(in source: String) -> String {
        // Leave Markdown code spans untouched while converting links in surrounding prose.
        guard let ticks = try? NSRegularExpression(pattern: #"`+"#) else { return source }
        let matches = ticks.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return replaceWikiLinks(in: source) }
        var output = ""
        var cursor = source.startIndex
        var codeDelimiter: String?
        for match in matches {
            guard let range = Range(match.range, in: source) else { continue }
            let prose = String(source[cursor..<range.lowerBound])
            output += codeDelimiter == nil ? replaceWikiLinks(in: prose) : prose
            let delimiter = String(source[range])
            output += delimiter
            if codeDelimiter == delimiter {
                codeDelimiter = nil
            } else if codeDelimiter == nil {
                codeDelimiter = delimiter
            }
            cursor = range.upperBound
        }
        let tail = String(source[cursor...])
        output += codeDelimiter == nil ? replaceWikiLinks(in: tail) : tail
        return output
    }

    private static func replaceWikiLinks(in source: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#) else { return source }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return source }
        var output = source
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: output) else { continue }
            let targetRange = Range(match.range(at: 1), in: source)!
            let target = String(source[targetRange]).trimmingCharacters(in: .whitespaces)
            let label: String
            if match.range(at: 2).location != NSNotFound, let aliasRange = Range(match.range(at: 2), in: source) {
                label = String(source[aliasRange]).trimmingCharacters(in: .whitespaces)
            } else {
                label = target
            }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
            let escapedLabel = label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            output.replaceSubrange(whole, with: "[\(escapedLabel)](desknote://open?target=\(encoded))")
        }
        return output
    }
}

enum CellAlignment: Sendable {
    case leading, center, trailing
}

struct ReaderItem: Identifiable, Sendable {
    enum Content: Sendable {
        case markdown(String)
        case table([[String]], [CellAlignment])
        case image(String, String, Int?, String?)
    }

    let id: Int
    let content: Content
}

struct ReaderImageMatch {
    let range: Range<String.Index>
    let alt: String
    let destination: String
    let width: Int?
    let dataCacheKey: String?
    let isWiki: Bool
}
