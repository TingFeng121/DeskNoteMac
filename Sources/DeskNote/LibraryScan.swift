import Foundation
import CryptoKit

/// 库页的过滤口径，选过一次记进偏好：这一页天天开，每次都重新点一遍是折磨。
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, notes, board, changed, conflict

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .notes: return "便签"
        case .board: return "待办板"
        case .changed: return "磁盘改动"
        case .conflict: return "冲突"
        }
    }

    /// 片上那两个字放不下口径，说给想知道的人：「磁盘改动」是谁改的，只有点过的人才记得。
    var hint: String {
        switch self {
        case .all: return "库里全部 .md 文件"
        case .notes: return "DeskNote 里建的便签，一个文件一张"
        case .board: return "待办板，一块板一个文件"
        case .changed: return "上次扫描之后磁盘上被写过的那几份"
        case .conflict: return "两边都改过、要你拍板的那几份"
        }
    }
}

/// 磁盘上一个 .md 在这一页上的样子
struct LibraryRow: Identifiable, Equatable {
    /// 表格最左边那一格的字标。颜色方块只有悬停才知道是什么，一个字谁都能读出来。
    enum Kind {
        case note, board, document

        var tag: String {
            switch self {
            case .note: return "签"
            case .board: return "板"
            case .document: return "文"
            }
        }

        var words: String {
            switch self {
            case .note: return "便签"
            case .board: return "待办板"
            case .document: return "Markdown"
            }
        }
    }

    /// 谁的那份更新。名字念着绕，但它就是三方比对的全部输出：磁盘 vs DeskNote vs 上次扫描
    enum State { case clean, pending, changed, conflict }

    let id: UUID
    let kind: Kind
    var name: String
    /// 相对库根的目录，空串 = 就在根上
    var folder: String
    var url: URL
    var updatedAt: Date
    var words: Int
    var state: State
    var excerpt: String
    /// 正文里写下的 `[[目标]]` 主干，用来算反向链接
    var linkStems: [String]
    /// 便签类文件对回哪张便签；外部文档没有
    var noteID: UUID?
    /// 正文开头那一段。整篇正文不背在行上：真实库 512 MB，那样等于把整个库装进内存，
    /// 而且每敲一个搜索字符都要把全部正文 `lowercased()` 重扫一遍。
    /// 名字、摘录、双链、随手搜索要的都在这一段里；深处的词走 `LibrarySearch`。
    var head: String
    /// 这份比 `LibraryScan.readLimit` 长，`head` 之外还有内容。摘录和搜索都只到这儿为止。
    var truncated: Bool
    /// `(名字 ␟ 目录 ␟ 开头)` 预先小写好，扫描那一轮顺手算完，搜索时只剩 `contains`。
    var searchBlob: String
    /// 这一行是按哪份磁盘指纹算出来的。下一轮 stat 一模一样就整行复用，一个字节都不读。
    var stamp: FileStamp?

    /// 只有冲突真的等人拍板：磁盘改和便签改同步层自己会收掉，把它们算进「要你处理」是吓人。
    var needsYou: Bool { state == .conflict }
}

/// 一次扫描 = 枚举整棵树 + 只读「stat 变了或新出现」的那几份。
///
/// 目录枚举保持全量（200 条 ≈ 4 ms，而且文件树要的就是这份目录清单）；贵的一直是逐份读正文。
/// Obsidian 也是这个形状：事件只更新被点到的路径，`mtime + size` 没变就不重解析。
enum LibraryScan {
    /// 每行留住的正文长度。
    static let headBytes = 32 * 1024
    /// 读的时候多给一些：frontmatter 再长也不至于把正文开头挤没。
    static let readLimit = headBytes + 8 * 1024

    struct Result {
        var rows: [LibraryRow]
        var baseline: [String: FileStamp]
        var counts: [LibraryFilter: Int]
        var treeIndex: LibraryTreeIndex
        var problem: String?
    }

    /// `previous` 按标准化路径索引上一轮的行；`baseline` 是上一轮记着的指纹。
    /// 两者不是一回事：`previous` 决定「这行要不要重算」，`baseline` 决定「这一行标成磁盘改」。
    /// `previousTree` 是上一轮搭好的文件树，路径清单和冲突点没动就直接沿用（见 `LibraryTreeIndex`）。
    static func scan(root: URL, baseline: [String: FileStamp],
                     previous: [String: LibraryRow], notes: BoardData,
                     previousTree: LibraryTreeIndex? = nil) -> Result {
        var out: [LibraryRow] = []
        var fresh: [String: FileStamp] = [:]
        var problem: String?
        // 树上点着冲突的那些路径，单独攒一份：它是「文件树要不要重搭」的第二个条件。
        // 这两份集合用枚举器给的原始路径，和 `Entry.id` 同一个口径（见 `LibraryTreeIndex`），
        // 顺手也省掉每份文件一次 `standardizedFileURL`。
        var treePaths: Set<String> = []
        var conflictPaths: Set<String> = []
        // 枚举回来的路径是解过软链的（/var 会写成 /private/var），拿未解析的根去截前缀
        // 会截出「/private会议记录」这种半个目录；基线的键也一样，两边都得先标准化。
        let rootPath = root.standardizedFileURL.path
        let inventory = LibraryFiles.inventory(root)
        for folder in inventory.folders { treePaths.insert(folder.path) }
        for url in inventory.markdown {
            let path = url.standardizedFileURL.path
            guard let stamp = FileStamp(url) else { continue }   // 扫到一半被删了
            fresh[path] = stamp
            // 冲突副本带着「冲突」那个字样的文件名，它本身就是答案：不管两边谁新，它都要人看一眼。
            let conflict = Vault.isConflict(url)

            // 上一轮已经把这行算出来了，而且磁盘上还是同一份字节：只重算那两个徽标，正文一个字节都不读。
            if let known = previous[path], known.stamp == stamp {
                let state = ledger(baseline: baseline, stamp: stamp, path: path,
                                   noteID: known.noteID, notes: notes, conflict: conflict)
                out.append(known.withState(state))
                treePaths.insert(url.path)
                if state == .conflict || conflict { conflictPaths.insert(url.path) }
                continue
            }

            let head: String
            if stamp.size == 0 {
                head = ""                                   // 空文件是「没有正文」，不是「读不出来」
            } else if let text = Vault.readHead(of: url, limit: readLimit) {
                head = text
            } else {
                problem = "有文件读不出来（\(url.lastPathComponent)），可能是编码不是 UTF-8。"
                continue
            }

            let parts = Vault.split(Vault.normalize(head))
            let front = parts.front
            // 摘出来的开头才是这一行真正背着的字节。少切这一下，行上留的就是整次读盘的量：
            // 大文档本来只该占 `headBytes`，切错就等于把 `readLimit` 当成了常驻预算。
            let body = cut(parts.body, to: headBytes)
            let kind: LibraryRow.Kind = front["category"] != nil ? .board
                : (front.uuid != nil ? .note : .document)
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            let folder = parent.hasPrefix(rootPath + "/") ? String(parent.dropFirst(rootPath.count + 1)) : ""
            let name: String
            switch kind {
            case .note: name = firstMeaningfulLine(body, fallback: trimmed(url.deletingPathExtension().lastPathComponent))
            case .board: name = trimmed(url.deletingPathExtension().lastPathComponent)
            case .document: name = front["title"] ?? firstMeaningfulLine(body,
                        fallback: trimmed(url.deletingPathExtension().lastPathComponent))
            }
            let noteID = front.uuid
            let blob = name + "\u{1F}" + folder + "\u{1F}" + body
            let state = ledger(baseline: baseline, stamp: stamp, path: path,
                               noteID: noteID, notes: notes, conflict: conflict)
            treePaths.insert(url.path)
            if state == .conflict || conflict { conflictPaths.insert(url.path) }
            out.append(LibraryRow(
                id: synthesizedID(path),
                kind: kind,
                name: name,
                folder: folder,
                url: url,
                updatedAt: front.dateValue("updated") ?? stamp.date,
                words: body.count,
                state: state,
                excerpt: Vault.excerpt(body),
                linkStems: Vault.wikiLinks(body).map(\.stem),
                noteID: noteID,
                head: body,
                truncated: stamp.size > readLimit || body.utf8.count < parts.body.utf8.count,
                searchBlob: blob.lowercased(),
                stamp: stamp))
        }
        // 文件没增减、冲突点没挪地方，上一轮的树就还是这一轮的树。
        // 换库时 `LibraryModel` 把 `treeIndex` 摆成 `.empty`，`rootPath` 对不上，自然重搭。
        let treeIndex: LibraryTreeIndex
        if let known = previousTree, known.rootPath == rootPath,
           known.treePaths == treePaths, known.conflictPaths == conflictPaths {
            treeIndex = known
        } else {
            treeIndex = LibraryTreeIndex(root: root, folders: inventory.folders,
                files: out.map { LibraryTreeIndex.File(url: $0.url, conflict: $0.state == .conflict) })
        }
        return Result(rows: out.sorted { $0.updatedAt > $1.updatedAt },
                      baseline: fresh,
                      counts: tally(out),
                      treeIndex: treeIndex,
                      problem: problem)
    }

    /// 「这一行归哪个过滤片」的口径只有一份：`counts` 和 `rows(in:query:)` 都用它，
    /// 否则数字和列表会各说一套。
    static func include(_ row: LibraryRow, in filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: return true
        case .notes: return row.kind == .note
        case .board: return row.kind == .board
        case .changed: return row.state == .changed
        case .conflict: return row.state == .conflict
        }
    }

    static func matches(_ row: LibraryRow, query: String) -> Bool {
        query.isEmpty || row.searchBlob.contains(query.lowercased())
    }

    // MARK: 徽标

    /// 磁盘 vs DeskNote vs 上次扫描——三方比对里这一页只看两个信号。
    /// stat 的变更判定只比 `mtime + size`（跟同步层同一个口径）；`created` 不参与：
    /// 它是给「原子写换了 inode」准备的，而这里的基线是演示和冷启动一点点摆出来的。
    private static func ledger(baseline: [String: FileStamp], stamp: FileStamp,
                               path: String, noteID: UUID?, notes: BoardData,
                               conflict: Bool) -> LibraryRow.State {
        if conflict { return .conflict }
        let past = baseline[path]
        let diskNewer = past.map { !$0.contentMatches(stamp) } ?? false
        var appNewer = false
        if let id = noteID, let past,
           let wrote = notes.notes.first(where: { $0.id == id })?.updatedAt {
            // 比的是**上一次扫描记着的那个时间**，不是磁盘现在这个 mtime：
            // 「磁盘刚被外部改过 + 我这边也有没落盘的改动」= 冲突，两个信号必须各自对上次那一轮比。
            appNewer = wrote.timeIntervalSinceReferenceDate > past.modified + 1
        }
        if diskNewer, appNewer { return .conflict }
        if diskNewer { return .changed }
        if appNewer { return .pending }
        return .clean
    }

    private static func tally(_ rows: [LibraryRow]) -> [LibraryFilter: Int] {
        var out: [LibraryFilter: Int] = [:]
        for filter in LibraryFilter.allCases { out[filter] = 0 }
        for row in rows {
            for filter in LibraryFilter.allCases where include(row, in: filter) { out[filter, default: 0] += 1 }
        }
        return out
    }

    // MARK: 行上的字怎么来的

    /// 按字节留开头那一段，切在多字节字符上就退到上一个完整字符——
    /// 半个汉字在搜索串里是一个谁都可能点到的乱码。
    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var bytes = Array(text.utf8.prefix(limit))
        while let last = bytes.last, last & 0b1100_0000 == 0b1000_0000 { bytes.removeLast() }
        if let lead = bytes.last, lead & 0b1000_0000 != 0 { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 外部文档没有 desknote.id，身份由路径哈希合成：同一个路径每次都是同一个 id，
    /// 选中状态才恢复得回来。改两个 bit 标成 uuid v4，不然 UUID 不认这串字节。
    private static func synthesizedID(_ path: String) -> UUID {
        var digest = SHA256.hash(data: Data(path.utf8)).makeIterator()
        var bytes = (0..<16).map { _ in digest.next() ?? 0 }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func firstMeaningfulLine(_ text: String, fallback: String) -> String {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 标题符号和列表符号都不是名字：一张只写了 `- [ ] 买猫粮` 的便签，名字叫「买猫粮」
            let bare = line
                .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^[-*+]\\s+(\\[[ xX]\\]\\s*)?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if bare.isEmpty { continue }
            return String(bare.prefix(40))
        }
        return fallback
    }

    private static func trimmed(_ name: String) -> String {
        // 去掉尾巴上的 -<8 位 id>，那串是文件名的一部分，不是标题
        name.replacingOccurrences(of: #"-[0-9a-f]{8}$"#, with: "", options: .regularExpression)
    }
}

private extension LibraryRow {
    /// 复用旧行时唯一会变的就是徽标：App 侧那张便签可能被勾了一下，基线也可能刚被摆过。
    /// 带着上一轮的 `.changed` 不放，就是「扫完了却满屏已同步」的反面。
    func withState(_ state: LibraryRow.State) -> LibraryRow {
        var copy = self
        copy.state = state
        return copy
    }
}
