import Foundation

/// 近文搜只看行上那 32 KB（见 `LibraryRow.head`）；词在更深处怎么办——只能重新读盘。
/// 这一层就是那条**明说**的路：用户点一下「搜正文深处」，后台一块一块地读，命中了记下来。
///
/// 为什么不整篇读进来：真实库 512 MB，一次深搜把正文全捞进内存，「按需」就变成「按内存」了。
/// Obsidian 的全库搜也是同一个形状——一份一份读、一个词一个词找，没有索引库；
/// 差别只在于它把结果也缓存，而这里只在人主动点的那一轮记着。
///
/// 找词在**字节**上做，不做解码、也不用 `range(of:options:)`：后者一块 256 KB 要 100 ms，
/// 7 MB 读下来就是 1.7 秒；字节比较加一张 Horspool 跳转表，一块不到 1 ms。
/// 代价说清楚：大小写只折 ASCII。搜「alpha」能找到「ALPHA」，搜「eclair」找不到「éclair」——
/// 近文搜那一头用的是 `String.lowercased()`，全字母都折，所以这个盲区只在词落到 32 KB 之外时才碰得到。
enum LibrarySearch {
    /// 一次读这么多字节。够装上万行中文，也不至于让一次读盘把内存顶起来。
    static let chunkBytes = 256 * 1024
    /// 上一块尾巴带进下一块这么多字节。压在块边界上的那个词靠它接上：
    /// 只按块切，词会被切成两段、两边各半截，谁也搜不到。
    static let carryBytes = 512
    /// 一份文件最多留几段上下文：深搜要的是「在哪份、大概哪一段」，不是把文章重排一遍。
    static let excerptsPerFile = 3
    /// 一份文件数到这儿就不数了。命中几百次的词，继续找下去只是让转圈多转几秒。
    static let matchCap = 20
    /// 一次最多读这么多份。深搜是给「我知道它在某个文件里」用的，不是给「搜遍全库」用的。
    static let fileLimit = 400
    /// 上下文左右各留这么多字（按字符数，不是字节数）。
    static let contextChars = 40
    /// 属性块的收尾线最远找到这儿：再长就不是属性块了。
    static let frontmatterProbeBytes = 64 * 1024

    struct Hit: Equatable {
        let url: URL
        /// 命中处的上下文，已掐头去尾、换行压成空格
        let excerpts: [String]
        /// 命中处数：一份文件数到 `matchCap` 就停，所以这一格念作「至少这么多」。
        let matches: Int
    }

    /// `stop` 每读一块查一次：改搜索词、切页、关窗口都要能立刻刹车。
    /// 调用方负责按当前过滤片把 `files` 筛过——近文搜已经命中的那些不必再读盘。
    static func run(files: [URL], query: String, stop: () -> Bool = { false }) -> [Hit] {
        let needle = Array(folded(query.trimmingCharacters(in: .whitespacesAndNewlines)).utf8)
        guard !needle.isEmpty else { return [] }
        let skip = skipTable(needle)
        var out: [Hit] = []
        for url in files.prefix(fileLimit) {
            if stop() { break }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            var excerpts: [String] = []
            var matches = 0
            var hay: [UInt8] = []
            var isFirst = true
            while !stop(), matches < matchCap {
                let piece: Data?
                do { piece = try handle.read(upToCount: chunkBytes) } catch { piece = nil }
                guard let piece, !piece.isEmpty else { break }
                var bytes = [UInt8](piece)
                if isFirst {
                    isFirst = false
                    // 第一块要跳过属性块：搜「生活」命中别人家的 `category:` 不算找到正文。
                    bytes.removeFirst(frontmatterBytes(bytes))
                }
                // 边界 = 追加之前那些字节，也就是上一块的尾巴：上一块数过、摘过的都在这儿。
                let boundary = hay.count
                hay.append(contentsOf: bytes)
                var at = 0
                while let start = firstMatch(hay, needle, skip, from: at) {
                    at = start + needle.count
                    guard start + needle.count > boundary else { continue }
                    matches += 1
                    if excerpts.count < excerptsPerFile {
                        excerpts.append(excerpt(of: hay, start: start, length: needle.count))
                    }
                    if matches >= matchCap { break }
                }
                if hay.count > carryBytes + needle.count { hay.removeFirst(hay.count - carryBytes - needle.count) }
            }
            if matches > 0 { out.append(Hit(url: url, excerpts: excerpts, matches: matches)) }
        }
        return out
    }

    /// 属性块吃掉多少字节：和 `Vault.split` 同一个规则（第一行是 `---`，往下找到 `---` 或 `...`），
    /// 只是这一层不解码、CRLF 也照样认。找不到收尾线就当没有属性块——一份 64 KB 全是属性的文件不值得伺候。
    private static func frontmatterBytes(_ bytes: [UInt8]) -> Int {
        var line = 0
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { line = 3 }
        func isLine(_ at: Int, _ end: Int, _ text: String) -> Bool {
            let want = Array(text.utf8)
            var i = at
            if end - at < want.count { return false }
            for byte in want { if bytes[i] != byte { return false }; i += 1 }
            return end == i || (end - i == 1 && bytes[i] == 0x0D)
        }
        let probe = min(bytes.count, frontmatterProbeBytes)
        guard let firstEnd = indexOfNewline(bytes, from: 0, limit: probe), isLine(line, firstEnd, "---") else {
            return 0
        }
        var start = firstEnd + 1
        while start < probe {
            let end = indexOfNewline(bytes, from: start, limit: probe) ?? probe
            if isLine(start, end, "---") || isLine(start, end, "...") { return end < bytes.count ? end + 1 : end }
            start = end + 1
        }
        return 0
    }

    private static func indexOfNewline(_ bytes: [UInt8], from: Int, limit: Int) -> Int? {
        var i = from
        while i < limit { if bytes[i] == 0x0A { return i }; i += 1 }
        return nil
    }

    /// Horspool：按needle 最后一格建跳转表，坏字符一步跳过去。UTF-8 是自同步的，
    /// 所以字节序列不会在字符中间撞出个假命中——续字节的值域进不了首字节。
    private static func firstMatch(_ hay: [UInt8], _ needle: [UInt8], _ skip: [Int], from: Int) -> Int? {
        guard !needle.isEmpty else { return nil }
        let last = needle.count - 1
        var i = from
        while i + needle.count <= hay.count {
            var j = last
            while j >= 0, fold(bytes: hay[i + j]) == needle[j] { j -= 1 }
            if j < 0 { return i }
            i += max(1, skip[Int(fold(bytes: hay[i + last]))])
        }
        return nil
    }

    private static func skipTable(_ needle: [UInt8]) -> [Int] {
        var out = [Int](repeating: needle.count, count: 256)
        if needle.count > 1 {
            for i in 0..<needle.count - 1 { out[Int(needle[i])] = needle.count - 1 - i }
        }
        return out
    }

    /// 只折 ASCII 大写。折在字节上做，needle 那一头也走同一个函数，两边对得上。
    private static func fold(bytes: UInt8) -> UInt8 { bytes >= 0x41 && bytes <= 0x5A ? bytes + 32 : bytes }
    private static func folded(_ text: String) -> String {
        String(decoding: Array(text.utf8).map(fold(bytes:)), as: UTF8.self)
    }

    /// 掐一段上下文：两头都退到完整字符的开头/结尾，半个汉字在悬停说明里是一串乱码。
    private static func excerpt(of hay: [UInt8], start: Int, length: Int) -> String {
        let lo = step(hay, from: start, by: contextChars, backward: true)
        let hi = step(hay, from: start + length, by: contextChars, backward: false)
        var cut = Array(hay[lo..<hi])
        while let first = cut.first, first & 0b1100_0000 == 0b1000_0000 { cut.removeFirst() }
        // 换行和回车压成空格：0x0A / 0x0D 出现在多字节序列内部是不可能的，所以按字节换安全。
        for i in cut.indices where cut[i] == 0x0A || cut[i] == 0x0D { cut[i] = 0x20 }
        let body = String(decoding: cut, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return (lo > 0 ? "…" : "") + body + (hi < hay.count ? "…" : "")
    }

    /// 按**字符**走这么多格：落在续字节上就接着挪，别把一个字切开。
    private static func step(_ hay: [UInt8], from: Int, by chars: Int, backward: Bool) -> Int {
        var i = from
        var n = 0
        if backward {
            while i > 0, n < chars { i -= 1; if hay[i] & 0b1100_0000 != 0b1000_0000 { n += 1 } }
            return i
        }
        while i < hay.count, n < chars { if hay[i] & 0b1100_0000 != 0b1000_0000 { n += 1 }; i += 1 }
        while i < hay.count, hay[i] & 0b1100_0000 == 0b1000_0000 { i += 1 }
        return i
    }
}
