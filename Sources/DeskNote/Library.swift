import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// `LibraryFilter` 和 `LibraryRow` 在 LibraryScan.swift（只有 Foundation，回归测试层碰得到）。
/// 这个文件管的是「扫完之后这一页怎么画」；扫描本身、过滤口径、搜索匹配都在那一层。

/// 库页索引：从磁盘重建文件、全文搜索和反向链接。编辑由 LibraryDocument 管理。
/// 「库是文件不是数据库」这句话在这一页的落点就是：每次进来重新扫，界面上没有任何一份
/// 只有这里才有的内容。
@Observable
final class LibraryModel {
    static let shared = LibraryModel()

    private(set) var rows: [LibraryRow] = []
    private(set) var treeIndex = LibraryTreeIndex.empty
    /// 每个过滤片里有多少行：扫描那一趟顺手算完。这一条每帧都要画，现场重算就是每帧五趟全量。
    private(set) var counts: [LibraryFilter: Int] = [:]
    /// 上一次扫描看到的每份文件指纹。和同步层那本账同一个类型——一个库不该记两本 stat。
    /// 基线不在就一律算「刚见到」，直接干净，免得第一次开库满屏都标成外部改动。
    private(set) var baseline: [String: FileStamp] = [:]
    private(set) var lastScan: Date?
    var scanning = false
    var message: String?
    /// 上一轮同步干了什么（写了几份、采纳了几份、有没有冲突）。和 message 分开：
    /// 一个是「这里出错了」，一个是「刚替你做了事」，混成一条会让人以为同步失败。
    var notice: String?
    /// 后台那几轮（在便签里打字、勾完成）自己写盘产生的报告：没走 notice 通道，挂在 Store 上。
    /// 视图 body 里读一次 `Store.shared` 就会跟着被观察，下一轮存盘横幅自己就变了。
    var lastSync: VaultSync.Report? { Store.shared.vaultReport }
    var selected: UUID?
    /// 深搜（「搜正文深处」）那一轮的三格。行上只留 32 KB，深处的词要读盘才知道，
    /// 所以这一份结果**不属于扫描**：不常驻、不进基线，用户改了搜索词或点了清除就作废。
    private(set) var deepQuery = ""
    /// 标准化路径 → 命中。用字典而不是数组：并进行集那一头按路径查，一次深搜几百份，
    /// 数组就得在每行的过滤里再走一遍全量。
    private(set) var deepHits: [String: LibrarySearch.Hit] = [:]
    private(set) var deepSearching = false

    private let defaults = AppEnv.defaults
    /// 换 v2 是故意的：老键存的是 `(size, mtime)`，新的带 ctime 且按整毫秒对齐。
    /// 读不进来就当没见过这库，第一轮全 `.clean`——和第一次开库同一个语义，不用猜。
    private var baselineKey = "libraryBaseline.v2"
    /// 每次扫描发一个号，回来的时候只认最新那个。换库目录、手动重扫、开机恢复会挤在一起，
    /// 晚到的旧结果要是直接盖上去，界面就会「扫完了却满屏已同步」。
    private var scanToken = 0
    /// 深搜那一轮自己也要能被下一次盖掉：同一把号的道理，见 `scanToken`。
    private var deepToken = 0
    private var deepTask: Task<Void, Never>?

    var rootURL: URL? {
        let url = AppEnv.vaultURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init() {
        if let raw = defaults.data(forKey: baselineKey),
           let saved = try? JSONDecoder().decode([String: FileStamp].self, from: raw) { baseline = saved }
        rescan(reveal: true)
    }

    /// 首屏就有的行；过滤与搜索词由视图再筛一层
    func rows(in filter: LibraryFilter, query: String) -> [LibraryRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let deep = !needle.isEmpty && needle == deepQuery && !deepHits.isEmpty
        return rows.filter { row in
            guard LibraryScan.include(row, in: filter) else { return false }
            if LibraryScan.matches(row, query: query) { return true }
            return deep && deepHits[row.url.standardizedFileURL.path] != nil
        }
    }

    /// 「搜正文深处」：近文搜只看行上那 32 KB，没搜到不等于库里没有。
    /// 只读 `truncated` 的那些行——没截断的那份，整篇正文已经在行上了，再读一遍是白读。
    /// 后台一块一块读、每块查一次取消；结果只在这一刻的搜索词上成立。
    func deepSearch(query raw: String, in filter: LibraryFilter) {
        let needle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { clearDeepSearch(); return }
        let files = rows.filter { row in
            LibraryScan.include(row, in: filter) && row.truncated && !LibraryScan.matches(row, query: needle)
        }.map(\.url)
        deepToken += 1
        deepTask?.cancel()
        deepQuery = needle
        deepHits = [:]
        guard !files.isEmpty else { deepSearching = false; deepTask = nil; return }
        deepSearching = true
        let token = deepToken
        deepTask = Task.detached(priority: .userInitiated) {
            let hits = LibrarySearch.run(files: files, query: needle, stop: { Task.isCancelled })
            let stopped = Task.isCancelled
            await MainActor.run {
                guard token == self.deepToken, !stopped else { return }
                var map: [String: LibrarySearch.Hit] = [:]
                for hit in hits { map[hit.url.standardizedFileURL.path] = hit }
                self.deepHits = map
                self.deepSearching = false
            }
        }
    }

    /// 这一行是不是被深搜捞出来的、捞到几处、大概在哪一段。给文件树当悬停说明用。
    func deepHit(for url: URL) -> LibrarySearch.Hit? {
        deepHits[url.standardizedFileURL.path]
    }

    func clearDeepSearch() {
        deepToken += 1
        deepTask?.cancel()
        deepTask = nil
        deepQuery = ""
        deepHits = [:]
        deepSearching = false
    }

    /// reveal = 只是开机想把上次选中的那张恢复出来，别把界面弄成「正在忙」的样子
    func rescan(reveal: Bool = false) {
        guard let root = rootURL else {
            rows = []
            treeIndex = .empty
            counts = [:]
            lastScan = Date()
            return
        }
        if !reveal { scanning = true }
        let known = baseline
        let seen = keyedByPath(rows)
        let lastTree = treeIndex
        let pending = Store.shared.data
        scanToken += 1
        let token = scanToken
        Task.detached(priority: .userInitiated) {
            let scan = LibraryScan.scan(root: root, baseline: known, previous: seen,
                                        notes: pending, previousTree: lastTree)
            await MainActor.run {
                // 这里绝不能写 LibraryModel.shared：init 里就会重入单例的 dispatch_once，直接 trap
                guard token == self.scanToken else { return }
                // 值没变就不许写：写一次，观察 `rows` 的那一整张表就重画一次。
                // 监听器每隔一秒叫一轮，而绝大多数轮子磁盘上一个字节都没动。
                if scan.rows != self.rows { self.rows = scan.rows }
                if scan.counts != self.counts { self.counts = scan.counts }
                if !scan.treeIndex.sharesInventory(with: self.treeIndex) { self.treeIndex = scan.treeIndex }
                self.baseline = scan.baseline
                self.lastScan = Date()
                self.scanning = false
                self.message = scan.problem
                self.persist(scan.baseline)
            }
        }
    }

    /// 出图路径专用：先摆好基线，再同步扫一遍。
    /// 走 `rescan` 就得赌那 0.3 秒空转能不能等到后台回来，演示不该有时序风险。
    func rescanSync() {
        scanToken += 1
        guard let root = rootURL else { rows = []; treeIndex = .empty; counts = [:]; lastScan = Date(); return }
        let scan = LibraryScan.scan(root: root, baseline: baseline, previous: keyedByPath(rows),
                                    notes: Store.shared.data, previousTree: treeIndex)
        if scan.rows != rows { rows = scan.rows }
        if scan.counts != counts { counts = scan.counts }
        if !scan.treeIndex.sharesInventory(with: treeIndex) { treeIndex = scan.treeIndex }
        baseline = scan.baseline
        lastScan = Date()
        scanning = false
        message = scan.problem
    }

    /// 上一轮的行按标准化路径摊开，这一轮拿来判断「这份没动，那行原样留着」。
    /// 真出现同路径两行（软链、大小写撞车）就是后者覆盖前者，不影响正确性——
    /// 那种库本来由同步层报「有两份文件」。
    private func keyedByPath(_ rows: [LibraryRow]) -> [String: LibraryRow] {
        var out: [String: LibraryRow] = [:]
        for row in rows { out[row.url.standardizedFileURL.path] = row }
        return out
    }

    private func persist(_ map: [String: FileStamp]) {
        guard let raw = try? JSONEncoder().encode(map) else { return }
        defaults.set(raw, forKey: baselineKey)
    }

    /// 装一份基线并作废所有在飞的扫描：状态是「相对上一次看到的样子」算出来的，
    /// 演示要演出外部改动就得先把「上一次」摆好，这是这一页唯一的输入。
    func prime(baseline: [String: FileStamp]) {
        scanToken += 1
        scanning = false
        self.baseline = baseline
        selected = nil
    }

    /// 反向链接：别人的 [[目标]] 指到我这个文件名，就算引用方。
    func backlinks(of row: LibraryRow) -> [LibraryRow] {
        let mine = Vault.stem(row.url.deletingPathExtension().lastPathComponent)
        let alsoFromTitle = Vault.stem(row.name)
        return rows.filter { other in
            other.id != row.id && (other.linkStems.contains(mine) || other.linkStems.contains(alsoFromTitle))
        }
    }

    // MARK: 库的建立与选择

    /// 建立库：把 data.json 里的便签与待办板写成真的 .md。写完不删 data.json——它退成缓存，
    /// 出问题还能整个退回文件层之前。
    func createLibrary() {
        let root = AppEnv.vaultURL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 写文件 + 生成 state.json 一次做完：state.json 是「库建起来了」的唯一凭据，
            // 少了它这一页下次进来还是「还没建库」，同步那一层也永远不会开。
            let state = VaultSync.migrate(data: Store.shared.data, root: root)
            let expected = Store.shared.data.notes.count
                + Store.shared.data.categories.reduce(0) { $0 + $1.projects.count }
            message = state.files.count == expected ? nil
                : "库建起来了，但 \(expected - state.files.count) 份没写出去——看看这个目录是不是只读、还剩多少空间。"
            restartWatcher()
            rescan()
        } catch {
            message = "库没建起来：\(error.localizedDescription)"
        }
    }

    /// 打开已有文件夹；普通 Markdown 直接读写，带 DeskNote 身份的文件参与同步。
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "用这个文件夹"
        panel.message = "DeskNote 只读写库里的 .md，别的文件不动"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings().vaultDirectory = url.path
        baseline = [:]
        selected = nil
        // 指过来的是不是上一台机器的库，这里见分晓：对得上 id 的文件被采纳进来，
        // 对不上的便签写出去，谁的都不丢。state.json 一落，同步层就开工了。
        var data = Store.shared.data
        let report = VaultSync.sync(data: &data, root: url)
        if report.adopted > 0 { Store.shared.replaceFromVault(data) }
        notice = report.changed ? VaultSync.words(report) : nil
        restartWatcher()
        rescan()
    }

    /// `VaultWatcher` 是 `@MainActor`，而 `LibraryModel` 不是（它的 `scan` 在 `Task.detached` 里跑）。
    /// 给类整个贴 `@MainActor` 会把扫描拖回主线程，所以在调用点跳一次。
    private func restartWatcher() {
        Task { @MainActor in VaultWatcher.shared.restart() }
    }

    private func settings() -> AppSettings { AppSettings.shared }

    /// 按钮上写哪个编辑器名字，跟 `openInEditor` 实际会调起的是同一个 app。
    /// 没装 Typora 也没装 Obsidian 时返回 nil，让调用方说「打开」而不是编一个不存在的 app 名。
    var editorName: String? {
        preferredEditorURL?.deletingPathExtension().lastPathComponent
    }

    func openInEditor(_ row: LibraryRow) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if let preferred = preferredEditorURL {
            NSWorkspace.shared.open([row.url], withApplicationAt: preferred, configuration: config)
            return
        }
        NSWorkspace.shared.open(row.url)
    }

    /// 用户指定过就用他指的，否则按 Typora → Obsidian 的顺序找装了的那个。
    /// 打开动作一律 activates = false：设计库的人不该被弹到另一个 app 前面。
    private var preferredEditorURL: URL? {
        if let path = AppEnv.defaults.string(forKey: "libraryEditor") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        for id in ["abnerworks.Typora", "md.obsidian"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    func revealInFinder(_ row: LibraryRow) {
        NSWorkspace.shared.activateFileViewerSelecting([row.url])
    }

    /// 整库跳 Finder。「库就是磁盘上一个文件夹」这句话，点开一次文件夹就再也不用解释了。
    func revealRoot() {
        guard let root = rootURL else { return }
        NSWorkspace.shared.open(root)
    }

    /// 家目录折成 `~`：这一条只有 22pt，完整路径能把按钮挤出窗口。
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - 页面

/// 库表按哪一列排。列名和表头一字不差，用户点哪排哪。
enum LibrarySortColumn: String, CaseIterable {
    case name, folder, updated, state, words

    var label: String {
        switch self {
        case .name: return "名称"
        case .folder: return "所在目录"
        case .updated: return "更新"
        case .state: return "状态"
        case .words: return "字数"
        }
    }
}

extension LibraryRow.State {
    /// 「要动手的排前面」：状态列排序用的强度，冲突 > 外部改动 > 待落盘 > 同步
    var rank: Int {
        switch self {
        case .conflict: return 3
        case .changed: return 2
        case .pending: return 1
        case .clean: return 0
        }
    }

    /// 抽屉与 tooltip 用话说清这一次到底怎么了。双轨条是签名动作，但它不该是密码本。
    /// 口径要说准：这一页的状态是「自上次扫描以来哪一边动过」，不是「哪里坏了」。
    var words: String {
        switch self {
        case .clean: return "磁盘和 DeskNote 一样，不用管"
        case .changed: return "磁盘上这份被写过——外部编辑器改的，或 DeskNote 刚落盘"
        case .pending: return "DeskNote 里这张便签比磁盘上那份新，改动还没落盘"
        case .conflict: return "两边都改过，同步层不敢替你选"
        }
    }

    /// 表格里的词。双轨条负责「哪条长」，这三个字负责说人话：看不懂条子的人也有入口。
    var tag: String {
        switch self {
        case .clean: return "同步"
        case .changed: return "磁盘改"
        case .pending: return "便签改"
        case .conflict: return "冲突"
        }
    }

    /// 抽屉里那句「那你现在该做什么」。只有冲突真的等人拍板，另外两种同步层自己会收掉——
    /// 把不用动手的状态写成「需要处理」，人才会真的慌。
    var next: String? {
        switch self {
        case .clean: return nil
        case .changed: return "不用你动手：下一次同步会把磁盘这份收进来。"
        case .pending: return "也不用你动手：下一次存盘就写回磁盘。"
        case .conflict: return "这一种要你拍板：磁盘那份已经原样存成「冲突 …」副本，\n要留它就把它的内容复制回正文。"
        }
    }
}

