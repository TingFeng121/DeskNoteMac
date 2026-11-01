import Foundation

/// 磁盘 ↔ Store 的双向同步引擎。只有 Foundation：整条路径能在不带 SwiftUI 的测试里跑。
///
/// 三方比对里的「第三方」是 `<vault>/.desknote/state.json`：每个 DeskNote 自己的对象记两格哈希——
/// 上次看到的磁盘那份、上次落盘时 App 这一份。两边各跟自己的那格比，才知道动的是谁：
/// 只有 App 动了就写盘，只有磁盘动了就采纳，两边都动了就谁也不许覆盖谁（磁盘那份另存冲突副本）。
///
/// 只同步 DeskNote 自己造出来的对象（frontmatter 里有 `desknote.id` 且对得上）。
/// 库里别人的 .md 这一层一个字都不写，它是「外部文档」，不是我们的责任范围。
enum VaultSync {
    enum Kind: String, Codable { case note, board }

    /// `FileStamp` 在 FileStamp.swift：同步层和库页扫描层共用同一个 stat 口径。

    /// 「这个文件我这一趟已经看过了」的内存账：规范路径 → stat + 它带的 desknote id。
    /// 只记 stat 和 id，不记正文——和 Obsidian 那个 FsCache 一个形状：路径索引里压根没有内容。
    ///
    /// 不写进 state.json：那会让这本账变成被监听目录里最大的那个文件，
    /// 每轮落盘又给自己发一次事件，正是上一轮「追自己尾巴」的那个坑。
    final class VaultIndex {
        struct Entry { var stamp: FileStamp; var id: UUID? }
        private var entries: [String: Entry] = [:]

        func entry(at path: String) -> Entry? { entries[path] }
        func set(_ path: String, stamp: FileStamp, id: UUID?) { entries[path] = Entry(stamp: stamp, id: id) }
        /// 库里删掉的、改名走的，账上不能留：留着就是在拿一个不存在的文件的 stat 做判断。
        func drop(_ path: String) { entries[path] = nil }
        func reset() { entries.removeAll() }
        var counted: Int { entries.count }

        /// id → 这个 id 在磁盘上的所有落点。一份 id 出现在两处是用户手动复制过，
        /// 谁赢由 `sync` 里那套「认 state 记过的路径」决定，这一层只管列。
        var idMap: [UUID: [URL]] {
            var out: [UUID: [URL]] = [:]
            for (path, known) in entries {
                guard let id = known.id else { continue }
                out[id, default: []].append(URL(fileURLWithPath: path))
            }
            return out
        }

        /// 整库重走：建库、换库、冷启动、以及系统说「事件可能漏了」的那一轮。
        /// 从空账开始，所以每个文件的 frontmatter 都要读一遍——这是这一层最贵的地方。
        func rebuild(root: URL) {
            entries.removeAll()
            absorb(Vault.markdownFiles(root), under: root)
        }

        /// 只看事件报上来的这几条路径。FSEvents 给的是「哪个文件/哪个目录动了」，
        /// 这一层把它翻译成账上的增删改：整库重走从此只在补漏时发生。
        ///
        /// 目录事件重走那一层（改名、删除只体现在目录列表里，没有单独的文件事件）；
        /// 文件事件只 stat 那一份。实测 213 个文件的库：整库 39 ms，报上来两条不到 1 ms。
        func update(_ paths: [String], root: URL) {
            let fm = FileManager.default
            for raw in paths {
                let url = VaultSync.canon(URL(fileURLWithPath: raw))
                var isDir = ObjCBool(false)
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                    guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { continue }
                    drop(url.path)
                    // 整个目录被搬走/删掉：它下面的每一格都不该留着，否则改名会被读成「文件没了」
                    for path in entries.keys where path.hasPrefix(url.path + "/") { entries[path] = nil }
                    continue
                }
                guard url.path == root.path || url.path.hasPrefix(root.path + "/"),
                      !VaultSync.isBookkeeping(url.path, root: root) else { continue }
                if isDir.boolValue {
                    absorb(Vault.markdownFiles(url), under: url)
                } else if url.pathExtension.lowercased() == "md" {
                    absorb([url], under: nil)
                }
            }
        }

        /// 收下这一批：stat 没变就不读 frontmatter；`under` 给了这批来自哪个目录，
        /// 于是「账上记着、这一批里没有」就是被改名或删掉了，顺手掉账。
        private func absorb(_ urls: [URL], under dir: URL?) {
            var seen = Set<String>()
            for raw in urls {
                let url = VaultSync.canon(raw)
                // 冲突副本带着同一个 id，算进账里就会跟正文那份抢身份
                guard !Vault.isConflict(url) else { continue }
                let path = url.path
                seen.insert(path)
                guard let stamp = FileStamp(url) else { entries[path] = nil; continue }
                if let known = entries[path], known.stamp == stamp { continue }
                entries[path] = Entry(stamp: stamp, id: Vault.readFrontmatter(at: url)?.uuid)
            }
            guard let dir else { return }
            let prefix = VaultSync.canon(dir).path + "/"
            for path in entries.keys where path.hasPrefix(prefix) && !seen.contains(path) { entries[path] = nil }
        }
    }

    static let index = VaultIndex()

    struct FileState: Codable, Equatable {
        var kind: Kind
        var path: String
        /// 上次看到的磁盘内容
        var diskHash: String
        /// 上次落盘时 App 这一侧对象的内容
        var appHash: String
        /// diskHash 是对应哪一次 stat。旧 state.json 里没有这一格，读进来就是 nil：
        /// 那一轮老老实实重读一遍，读完就补上。
        var stamp: FileStamp?
    }

    struct State: Codable, Equatable {
        var version = Vault.formatVersion
        var files: [String: FileState] = [:]   // 键 = desknote id 的 uuidString
    }

    struct Report: Equatable {
        var written = 0
        var adopted = 0
        var trashed: [String] = []
        var conflicts: [String] = []
        var problem: String?

        var changed: Bool { written > 0 || adopted > 0 || !trashed.isEmpty
            || !conflicts.isEmpty || problem != nil }
    }

    // MARK: 库的存在与状态

    /// 一律用「解开软链之后的真实路径」来记录与比对。`/var` 只是 `/private/var` 的软链，
    /// 自己拼出来的路径带 /var，枚举磁盘回来的带 /private/var：同一个文件两个写法，
    /// 路径比对就会把「没改名」读成「改了名」，retire 会把刚写好的那份正文搬进回收站。
    static func canon(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    static func stateURL(_ root: URL) -> URL {
        root.appendingPathComponent(Vault.hiddenDir, isDirectory: true)
            .appendingPathComponent("state.json")
    }

    static func trashDir(_ root: URL) -> URL {
        root.appendingPathComponent(Vault.hiddenDir, isDirectory: true)
            .appendingPathComponent("trash", isDirectory: true)
    }

    /// 库内这两个点目录不是同步对象：`.desknote/` 是我们自己每轮写的账，`.obsidian/` 是 Obsidian
    /// 自己的记账（在它窗口里点一下就写一次）。`Vault.markdownFiles` 靠 skipsHiddenFiles 跳过它们，
    /// 事件这一侧必须用同一套口径——否则 DeskNote 就是在追自己的尾巴。
    static func isBookkeeping(_ path: String, root: URL) -> Bool {
        guard path.hasPrefix(root.path + "/") else { return false }
        let relative = path.dropFirst(root.path.count + 1)
        return relative == ".desknote" || relative.hasPrefix(".desknote/")
            || relative == ".obsidian" || relative.hasPrefix(".obsidian/")
    }

    /// 认库只认 state.json：目录可能被 iCloud 建了个空壳，也可能用户自己 mkdir 了一个 vault。
    /// 没有 state.json 就是「还没建库」，这一层一次文件 IO 都不该做。
    static func activeRoot() -> URL? {
        let root = canon(AppEnv.vaultURL)
        return FileManager.default.fileExists(atPath: stateURL(root).path) ? root : nil
    }

    static func loadState(_ root: URL) -> State {
        guard let raw = try? Data(contentsOf: stateURL(root)),
              let decoded = try? JSONDecoder().decode(State.self, from: raw) else { return State() }
        return decoded
    }

    @discardableResult
    static func saveState(_ state: State, root: URL) -> Bool {
        let url = stateURL(root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let raw = try? JSONEncoder().encode(state) else { return false }
        do { try raw.write(to: url, options: .atomic); return true } catch { return false }
    }

    // MARK: App 这一侧的内容指纹

    /// 只哈希「会进文件」的字段。pinnedToDesktop / collapsed / expandedHeight 是本地状态，
    /// 不进 .md，也就不参与比对——否则钉一下便签就会被当成「App 改了正文」。
    static func appHash(_ note: StickyNote) -> String {
        Vault.hash(["note", note.id.uuidString, note.text, String(note.colorIndex),
                    note.remindAt.map(Vault.stamp) ?? "", Vault.stamp(note.createdAt),
                    Vault.stamp(note.updatedAt)].joined(separator: "\u{1f}")
            + "\u{1e}")
    }

    /// Deadline 只比「哪一天」：文件里就是天的粒度（Obsidian Tasks 的约定），
    /// 拿带时刻的值去比，写盘再读回来永远算不出相等。
    static func appHash(_ project: Project, category: String) -> String {
        var text = ["board", project.id.uuidString, category, project.name].joined(separator: "\u{1f}") + "\n"
        for item in project.items {
            text += [item.id.uuidString, item.title, item.done ? "x" : " ",
                     item.deadline.map { Vault.dayOnly.string(from: $0) } ?? ""].joined(separator: "\u{1f}") + "\n"
        }
        return Vault.hash(text)
    }

    /// 磁盘指纹。stat 和记着的那次一模一样 → 沿用记着的哈希，一个字节都不读。
    /// 文件不在就是 nil —— 空文件是 ""，两者不能混：
    /// 「同步盘还没下下来」和「用户把正文删空了」要走不同的路。
    private static func diskHash(_ url: URL, against recorded: FileState?, full: Bool) -> (stamp: FileStamp?, hash: String?) {
        guard let now = FileStamp(url) else { return (nil, nil) }
        if !full, let recorded, recorded.stamp == now, recorded.diskHash.isEmpty == false {
            return (now, recorded.diskHash)
        }
        return (now, Vault.hash(url))
    }

    // MARK: 一次性迁移

    /// 建库：把现在的所有便签和待办板写成文件，并生成初始 state。
    /// 这一步以 App 为准（库是新建的空目录），所以不走比对。
    /// 返回的 state 只包含真正写出去的那些文件，调用方拿它和应有数量一比就知道目录是不是只读。
    @discardableResult
    static func migrate(data: BoardData, root: URL) -> State {
        let root = canon(root)
        index.reset()
        var state = State()
        var taken = Set<String>()
        for note in data.notes {
            let url = Vault.noteURL(root, title: note.firstLine, id: note.id, taken: taken)
            taken.insert(url.lastPathComponent)
            guard let st = write(note, to: url) else { continue }
            state.files[note.id.uuidString] = st
        }
        for category in data.categories {
            for project in category.projects {
                let url = Vault.projectURL(root, category: category.name, project: project.name, id: project.id)
                guard let st = write(project, category: category.name, to: url, existing: nil) else { continue }
                state.files[project.id.uuidString] = st
            }
        }
        saveState(state, root: root)
        return state
    }

    // MARK: 同步

    /// 跑一轮双向同步。`data` 是要被磁盘改动就地更新的整盘数据（采纳路径会改它）。
    ///
    /// `diskPaths` 是这一趟「磁盘上哪些地方可能变了」：
    /// - `nil`：别信任何缓存。建库/换库之后的第一轮、系统说漏事件的那一轮走这条路——
    ///   整库重走，而且连 state.json 里那格 stat 也不信，每个文件重读一遍。
    /// - `[]`：磁盘上没有已知的改动，这轮是 App 这一侧动了要写出去。每次存盘都是这种。
    /// - 有值：FSEvents 报上来的那几条路径，只看它们。
    ///
    /// 判错的代价是对称的：把「[]」用在真有外部改动的那一轮会漏采纳（下一次事件补回来），
    /// 把「nil」用在每次存盘那一轮就是打字时那一下卡。
    static func sync(data: inout BoardData, root: URL, diskPaths: [String]? = nil) -> Report {
        // 先解软链：/var 会被枚举成 /private/var，前缀截断和路径比对都得在同一套写法上做，
        // 不然 state.json 里记的路径和磁盘上扫到的是两个字符串，永远对不上。
        let root = canon(root)
        let full = diskPaths == nil
        var report = Report()
        var state = loadState(root)
        let loaded = state
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return report }

        // 身份只认 frontmatter 里的 id：文件被改名、被挪目录、被 Obsidian 搬走都还认得回来。
        if let diskPaths {
            index.update(diskPaths, root: root)
        } else {
            index.rebuild(root: root)
        }
        let foundByID = index.idMap
        var diskByID: [UUID: URL] = [:]
        for (id, urls) in foundByID {
            // 同一个 id 出现在两处（用户手动复制过一份）：认 state 里记过的那条路径，
            // 没有记录就按路径排序取第一个——随机挑一份会让内容在两处来回漂移。
            let sorted = urls.sorted { $0.path < $1.path }
            let recorded = state.files[id.uuidString]?.path
            diskByID[id] = sorted.first { $0.path == recorded } ?? sorted[0]
            if urls.count > 1, report.problem == nil {
                report.problem = "有同一个便签的两份文件，DeskNote 只认 \(sorted[0].lastPathComponent)；另一份请自己删掉或改掉 id。"
            }
        }

        for index in data.notes.indices {
            let id = data.notes[index].id
            let key = id.uuidString
            let url = resolve(id: id, recorded: state.files[key]?.path, from: diskByID) {
                Vault.noteURL(root, title: data.notes[index].firstLine, id: id)
            }
            let before = state.files[key]
            let (stampNow, diskNow) = diskHash(url, against: before, full: full)
            let appNow = appHash(data.notes[index])
            let action = decide(before: before, diskNow: diskNow, appNow: appNow)

            switch action {
            case .write, .conflict:
                if case .conflict = action {
                    guard let copy = stashConflict(url) else {
                        report.problem = "冲突那份存不下副本，这一份先没动：\(url.lastPathComponent)"
                        continue
                    }
                    report.conflicts.append(copy)
                }
                guard let st = write(data.notes[index], to: url) else {
                    report.problem = "写不出去：\(url.lastPathComponent)（磁盘满了，还是这一份不是 UTF-8？）"
                    continue
                }
                report.written += 1
                retire(old: before?.path, at: url, root: root, report: &report)
                state.files[key] = st
            case .adopt:
                // 只采纳「带着自己 id」的那一份：读不出 id（非 UTF-8、被别的 app 覆写成纯文本）
                // 时 readNote 会合成一张空便签，照单采纳就等于把用户的正文抹掉。
                guard let parsed = Vault.readNote(at: url), parsed.id == id else {
                    report.problem = "有一份便签文件读不出内容：\(url.lastPathComponent)"
                    continue
                }
                adopt(parsed.note, into: &data.notes[index])
                state.files[key] = FileState(kind: .note, path: url.path,
                                             diskHash: diskNow ?? "", appHash: appHash(data.notes[index]),
                                             stamp: stampNow)
                report.adopted += 1
            case .keep:
                if var st = before {
                    st.path = url.path
                    st.diskHash = diskNow ?? st.diskHash
                    st.stamp = stampNow ?? st.stamp
                    state.files[key] = st
                }
            }
        }

        for category in data.categories.indices {
            for project in data.categories[category].projects.indices {
                let id = data.categories[category].projects[project].id
                let key = id.uuidString
                let categoryName = data.categories[category].name
                let url = resolve(id: id, recorded: state.files[key]?.path, from: diskByID) {
                    Vault.projectURL(root, category: categoryName,
                                     project: data.categories[category].projects[project].name, id: id)
                }
                let before = state.files[key]
                let (stampNow, diskNow) = diskHash(url, against: before, full: full)
                let appNow = appHash(data.categories[category].projects[project], category: categoryName)
                let action = decide(before: before, diskNow: diskNow, appNow: appNow)

                switch action {
                case .write, .conflict:
                    if case .conflict = action {
                        guard let copy = stashConflict(url) else {
                            report.problem = "冲突那份存不下副本，这一份先没动：\(url.lastPathComponent)"
                            continue
                        }
                        report.conflicts.append(copy)
                    }
                    guard let st = write(data.categories[category].projects[project],
                                         category: categoryName, to: url,
                                         existing: Vault.readProject(at: url)?.lines) else {
                        report.problem = "写不出去：\(url.lastPathComponent)"
                        continue
                    }
                    report.written += 1
                    retire(old: before?.path, at: url, root: root, report: &report)
                    state.files[key] = st
                case .adopt:
                    guard let parsed = Vault.readProject(at: url), parsed.id == id else {
                        report.problem = "有一份待办板文件读不出内容：\(url.lastPathComponent)"
                        continue
                    }
                    data.categories[category].projects[project].items =
                        parsed.lines.compactMap { if case let .item(item) = $0 { return item } else { return nil } }
                    state.files[key] = FileState(kind: .board, path: url.path, diskHash: diskNow ?? "",
                                                 appHash: appHash(data.categories[category].projects[project],
                                                                  category: categoryName),
                                                 stamp: stampNow)
                    report.adopted += 1
                case .keep:
                    if var st = before {
                        st.path = url.path
                        st.diskHash = diskNow ?? st.diskHash
                        st.stamp = stampNow ?? st.stamp
                        state.files[key] = st
                    }
                }
            }
        }

        // 对象没了 = 在 DeskNote 里被删了。文件进 .desknote/trash，不直接抹掉。
        for (key, st) in state.files where !tracked(key, in: data) {
            // 按 id 找现址：在 Typora 里改过名或挪过目录，删的也该是那一份，不是 state.json 里记的老路径
            var url = canon(URL(fileURLWithPath: st.path))
            if let uuid = UUID(uuidString: key), let found = diskByID[uuid] { url = found }
            if let moved = move(to: url, intoTrashOf: root) { report.trashed.append(moved) }
            state.files.removeValue(forKey: key)
        }

        // state.json 就在被监听的那个目录里：每轮都无条件写一次，等于每轮给自己发一条文件事件，
        // 事件再触发下一轮同步。实测这个自循环约 5 秒一圈，主线程整圈占在 readFrontmatter 上。
        // 登记没变就不落盘，让这一圈断掉。
        if state != loaded { saveState(state, root: root) }
        return report
    }

    // MARK: 判定

    enum Action: Equatable { case write, adopt, conflict, keep }

    /// 没有基线时：磁盘上有文件就先信文件（那是用户在外部建的），没有就写一份出去。
    /// 文件消失了也判写入：这一侧磁盘没有需要保护的内容，而「同步盘抽一下、iCloud 占位没落地」
    /// 在真实机器上天天发生，把读不到文件当成删除，会白丢一整张便签。
    static func decide(before: FileState?, diskNow: String?, appNow: String) -> Action {
        guard let before else { return diskNow == nil ? .write : .adopt }
        if diskNow == nil { return .write }
        let diskMoved = diskNow != before.diskHash
        let appMoved = appNow != before.appHash
        if diskMoved && appMoved { return .conflict }
        if appMoved { return .write }
        if diskMoved { return .adopt }
        return .keep
    }

    // MARK: 落盘与采纳

    /// 写一张便签。`Vault.writeNote` 会把用户自己写的 frontmatter 键原样带回去。
    private static func write(_ note: StickyNote, to url: URL) -> FileState? {
        do { try Vault.writeNote(note, to: url) } catch { return nil }
        return settle(FileState(kind: .note, path: url.path, diskHash: Vault.hash(url),
                                appHash: appHash(note)), at: url, id: note.id)
    }

    /// 写一块待办板。磁盘上已有的 `.text` 行（用户在 Obsidian 里加的说明、表头）按位置留着，
    /// 事项按 id 对位替换，App 里新增的追加在后面。
    private static func write(_ project: Project, category: String, to url: URL,
                              existing lines: [Vault.Line]?) -> FileState? {
        var merged: [Vault.Line] = []
        var placed = Set<UUID>()
        for line in lines ?? [] {
            guard case let .item(item) = line else { merged.append(line); continue }
            guard let match = project.items.first(where: { $0.id == item.id }) else { continue }
            merged.append(.item(match))
            placed.insert(item.id)
        }
        merged += project.items.filter { !placed.contains($0.id) }.map { Vault.Line.item($0) }
        do { try Vault.writeProject(id: project.id, category: category, lines: merged, to: url) } catch { return nil }
        return settle(FileState(kind: .board, path: url.path, diskHash: Vault.hash(url),
                                appHash: appHash(project, category: category)), at: url, id: project.id)
    }

    /// 刚写出去的那一份：正文读回来算哈希之后才 stat，顺序反了就等于把一个可能比正文旧的
    /// stamp 记进账里，下一次真改动就会被闸门吃掉。stat 到手就登记，账和磁盘这才对齐。
    private static func settle(_ file: FileState, at url: URL, id: UUID) -> FileState {
        var file = file
        guard let stamp = FileStamp(url) else { return file }
        file.stamp = stamp
        index.set(url.path, stamp: stamp, id: id)
        return file
    }

    /// 采纳只覆盖「会进文件」的那几个字段。钉在桌面、折叠、高度是本地状态，磁盘上那份没有，
    /// 整块换掉会把用户钉好的便签弹回桌面之外。
    private static func adopt(_ incoming: StickyNote, into current: inout StickyNote) {
        current.text = incoming.text
        current.colorIndex = incoming.colorIndex
        current.remindAt = incoming.remindAt
        current.createdAt = incoming.createdAt
        current.updatedAt = incoming.updatedAt
    }

    // MARK: 杂项

    private static func resolve(id: UUID, recorded: String?, from diskByID: [UUID: URL],
                                fresh: () -> URL) -> URL {
        if let found = diskByID[id] { return found }
        if let recorded {
            let url = canon(URL(fileURLWithPath: recorded))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return fresh()
    }

    private static func tracked(_ key: String, in data: BoardData) -> Bool {
        guard let id = UUID(uuidString: key) else { return true }
        if data.notes.contains(where: { $0.id == id }) { return true }
        return data.categories.contains(where: { $0.projects.contains { $0.id == id } })
    }

    /// 文件名换了（只有新建才会）：旧路径上那份留着的只会是同一张便签的两个版本，进回收站。
    private static func retire(old: String?, at url: URL, root: URL, report: inout Report) {
        guard let old else { return }
        let oldURL = canon(URL(fileURLWithPath: old))
        guard oldURL.path != url.path, FileManager.default.fileExists(atPath: oldURL.path) else { return }
        if let moved = move(to: oldURL, intoTrashOf: root) { report.trashed.append(moved) }
    }

    /// 一轮同步的人话总结，给库页那条横幅用。
    static func words(_ report: Report) -> String {
        var parts: [String] = []
        if report.written > 0 { parts.append("已写入 \(report.written) 份") }
        if report.adopted > 0 { parts.append("已采纳 \(report.adopted) 份外部改动") }
        if !report.conflicts.isEmpty { parts.append("\(report.conflicts.count) 份冲突，磁盘那份另存了副本") }
        if !report.trashed.isEmpty { parts.append("\(report.trashed.count) 份进了 .desknote/trash") }
        return parts.joined(separator: " · ")
    }

    /// 冲突副本：磁盘那份原样另存，名字里带时间，谁都不许悄悄丢。
    /// 同一秒里连着撞两次（外部编辑器保存快）就加序号——存不下必须让调用方知道，
    /// 因为它下一步要拿 App 那份覆盖原文件，副本没保成就是真丢内容。
    private static func stashConflict(_ url: URL) -> String? {
        let fm = FileManager.default
        var target = Vault.conflictURL(url)
        var index = 2
        while fm.fileExists(atPath: target.path) {
            target = url.deletingPathExtension()
                .appendingPathExtension("\(Vault.conflictMarker)\(index) ")
                .appendingPathExtension(url.pathExtension)
            index += 1
        }
        do { try fm.moveItem(at: url, to: target) }
        catch { return nil }
        // 搬走的那条路径已经不指向任何正文了，账上留着就是拿一份不存在的文件的 stat 做判断；
        // 落点（.desknote/trash 或冲突副本）都在同步范围之外，所以只掉不记。
        // 写全名：这一层里 `index` 是那个重名序号。
        VaultSync.index.drop(url.path)
        return target.lastPathComponent
    }

    /// 删掉的文件先进 `.desknote/trash`。库目录会被 iCloud 同步，直接抹掉等于跨设备比谁手快。
    @discardableResult
    private static func move(to url: URL, intoTrashOf root: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let dir = trashDir(root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(url.lastPathComponent)
        var index = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(index)"
                                                + ".\(url.pathExtension)")
            index += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            // 这里的 `index` 是重名序号，写全名才够得着那份账
            VaultSync.index.drop(url.path)
            return target.lastPathComponent
        } catch { return nil }
    }
}
