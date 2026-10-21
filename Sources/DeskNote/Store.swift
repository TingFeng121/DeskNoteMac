import Foundation
import Observation

extension Notification.Name {
    static let storeDidChange = Notification.Name("desknote.storeDidChange")
}

@Observable
final class Store {
    static let shared = Store()

    private(set) var data = BoardData()
    /// 改动流水号：每动一次加一格，跟着落盘一起持久化。自动备份靠它判断
    /// 「自上次备份以来到底改没改」——比对 JSON 字节是不行的，同一个值两次
    /// encode 出来的键序都不一样（实测 200 次能得 160 种结果）。
    private(set) var revision = UserDefaults.standard.integer(forKey: "dataRevision")
    private var saveTimer: Timer?
    /// 本轮改动里第一次排入存盘的时刻，用来给防抖兜一个上限
    private var pendingSince: Date?
    /// 删除前的整盘快照，只保一步——够救「手滑删了整个类别」
    private var undoSnapshot: BoardData?

    /// 就地改名的认领信号：id 对上自己才响应。blank = 刚建出来，默认名不填进输入框。
    struct RenameRequest: Equatable {
        let id: UUID
        var blank = false
    }

    /// 需要就地改名的类别/项目 id：新建时先塞默认名，视图认领后置空
    var renaming: RenameRequest?
    /// 要求主窗口跳到某个事项：RootView 滚到位并闪一下高亮，随后置空
    var revealRequest: UUID?

    var canUndoDelete: Bool { undoSnapshot != nil }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskNote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }

    init() {
        load()
        if data.categories.isEmpty {
            data.categories = [
                Category(name: "生活", projects: [
                    Project(name: "默认项目", items: [
                        DeskItem(title: "试试新建一个事项"),
                        DeskItem(title: "点击时钟图标设置 Deadline", deadline: Date().addingTimeInterval(3600 * 24)),
                    ]),
                ]),
            ]
            save()
        }
    }

    // MARK: - Persistence

    func load() {
        guard let raw = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(BoardData.self, from: raw) else { return }
        data = decoded
    }

    private func changed() {
        revision += 1
        scheduleSave()
        NotificationCenter.default.post(name: .storeDidChange, object: nil)
    }

    private func scheduleSave() {
        let now = Date()
        if pendingSince == nil { pendingSince = now }
        saveTimer?.invalidate()
        // 连续打字会把 0.4s 防抖一直重置，几分钟都不落盘；到上限就先落一次
        if now.timeIntervalSince(pendingSince!) >= 3 {
            pendingSince = nil
            save()
            Notifier.sync(self)
            return
        }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pendingSince = nil
            self.save()
            // 便签正文是逐字符改的，每敲一个字就重排一遍系统通知会被打爆
            Notifier.sync(self)
        }
    }

    /// 退出、失去焦点时把还压在防抖里的数据落掉
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard pendingSince != nil else { return }
        pendingSince = nil
        save()
        Notifier.sync(self)
    }

    func save() {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? raw.write(to: Self.fileURL, options: .atomic)
        // 跟着数据一起落盘：崩在防抖里没写出去的话，流水号也不会凭空多走一格
        UserDefaults.standard.set(revision, forKey: "dataRevision")
    }

    /// 从远端备份整盘恢复：先把本地这份复制成 data.json.bak，恢复错了还能手动回退
    func replaceAll(_ incoming: BoardData) {
        if let current = try? Data(contentsOf: Self.fileURL) {
            try? current.write(to: Self.fileURL.appendingPathExtension("bak"))
        }
        // 整盘都被换掉了，再拿旧快照撤销会把恢复结果吐回去
        clearUndoPoint()
        data = incoming
        save()
        changed()
    }

    // MARK: - Queries

    var allItems: [DeskItem] {
        data.categories.flatMap { $0.projects.flatMap { $0.items } }
    }

    var openCount: Int { allItems.filter { !$0.done }.count }
    var doneCount: Int { allItems.filter { $0.done }.count }

    func category(_ id: UUID) -> Category? {
        data.categories.first { $0.id == id }
    }

    /// 事项连同它所属的类别/项目，供「已完成」页、搜索结果和桌面面板跳转使用。
    /// 光有名字不够：点面板某一行要能切回它所在的类别页并滚到位。
    struct Located: Identifiable {
        let categoryName: String
        let categoryID: UUID
        let projectName: String
        let projectID: UUID
        let item: DeskItem
        var id: UUID { item.id }
    }

    var locatedItems: [Located] {
        data.categories.flatMap { cat in
            cat.projects.flatMap { proj in
                proj.items.map {
                    Located(categoryName: cat.name, categoryID: cat.id,
                            projectName: proj.name, projectID: proj.id, item: $0)
                }
            }
        }
    }

    var doneItems: [Located] { locatedItems.filter { $0.item.done } }

    func location(of itemID: UUID) -> Located? {
        locatedItems.first { $0.id == itemID }
    }

    func count(in category: Category) -> Int {
        category.projects.flatMap(\.items).filter { !$0.done }.count
    }

    /// 有 Deadline 的按时间靠前，没日期的按创建顺序垫底
    private func precedes(_ a: DeskItem, _ b: DeskItem) -> Bool {
        if a.done != b.done { return !a.done }
        switch (a.deadline, b.deadline) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.createdAt < b.createdAt
        }
    }

    func sortedItems(_ items: [DeskItem]) -> [DeskItem] {
        items.sorted { precedes($0, $1) }
    }

    func sortedItems(_ items: [Located]) -> [Located] {
        items.sorted { precedes($0.item, $1.item) }
    }

    // MARK: - 删除撤销

    /// 破坏性操作前留一份整盘。只保一步：多步撤销要做成真正的历史栈，代价不成比例。
    private func takeUndoPoint() { undoSnapshot = data }

    /// 恢复最近一次删除。返回 false 表示没有可恢复的东西。
    @discardableResult
    func undoDelete() -> Bool {
        guard let snapshot = undoSnapshot else { return false }
        undoSnapshot = nil
        data = snapshot
        changed()
        return true
    }

    /// 撤销之后就没必要再撤一次，别的改动（比如改名）不该被旧的撤销点覆盖
    func clearUndoPoint() { undoSnapshot = nil }

    // MARK: - Mutations

    func update(_ transform: (inout BoardData) -> Void) {
        transform(&data)
        changed()
    }

    /// 返回新 id：调用方要拿它去认领「就地改名」，新建完直接就能打字
    @discardableResult
    func addCategory(named name: String) -> UUID {
        let category = Category(name: name)
        update { $0.categories.append(category) }
        return category.id
    }

    func removeCategory(_ id: UUID) {
        takeUndoPoint()
        update { $0.categories.removeAll { $0.id == id } }
    }

    func renameCategory(_ id: UUID, to name: String) {
        update { d in
            if let i = d.categories.firstIndex(where: { $0.id == id }) { d.categories[i].name = name }
        }
    }

    func toggleCategoryCollapsed(_ id: UUID) {
        update { d in
            if let i = d.categories.firstIndex(where: { $0.id == id }) { d.categories[i].collapsed.toggle() }
        }
    }

    @discardableResult
    func addProject(to categoryID: UUID, name: String = "新项目") -> UUID? {
        var created: UUID?
        update { d in
            guard let i = d.categories.firstIndex(where: { $0.id == categoryID }) else { return }
            let project = Project(name: name)
            created = project.id
            d.categories[i].projects.append(project)
        }
        return created
    }

    func removeProject(categoryID: UUID, projectID: UUID) {
        takeUndoPoint()
        update { d in
            if let i = d.categories.firstIndex(where: { $0.id == categoryID }) {
                d.categories[i].projects.removeAll { $0.id == projectID }
            }
        }
    }

    func renameProject(categoryID: UUID, projectID: UUID, to name: String) {
        update { d in
            guard let i = d.categories.firstIndex(where: { $0.id == categoryID }),
                  let j = d.categories[i].projects.firstIndex(where: { $0.id == projectID }) else { return }
            d.categories[i].projects[j].name = name
        }
    }

    func toggleProjectCollapsed(categoryID: UUID, projectID: UUID) {
        update { d in
            guard let i = d.categories.firstIndex(where: { $0.id == categoryID }),
                  let j = d.categories[i].projects.firstIndex(where: { $0.id == projectID }) else { return }
            d.categories[i].projects[j].collapsed.toggle()
        }
    }

    /// 快速添加的落点：优先用记下的项目，它被删了就退回第一个可用项目
    func resolveProject(_ id: UUID?) -> (category: Category, project: Project)? {
        if let id {
            for cat in data.categories {
                if let proj = cat.projects.first(where: { $0.id == id }) { return (cat, proj) }
            }
        }
        guard let cat = data.categories.first, let proj = cat.projects.first else { return nil }
        return (cat, proj)
    }

    func addItem(categoryID: UUID, projectID: UUID, title: String, deadline: Date? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update { d in
            guard let i = d.categories.firstIndex(where: { $0.id == categoryID }),
                  let j = d.categories[i].projects.firstIndex(where: { $0.id == projectID }) else { return }
            d.categories[i].projects[j].items.append(DeskItem(title: trimmed, deadline: deadline))
        }
    }

    func removeItem(_ itemID: UUID) {
        takeUndoPoint()
        update { d in
            for cat in d.categories.indices {
                for proj in d.categories[cat].projects.indices {
                    d.categories[cat].projects[proj].items.removeAll { $0.id == itemID }
                }
            }
        }
    }

    func mutateItem(_ itemID: UUID, _ transform: (inout DeskItem) -> Void) {
        update { d in
            for cat in d.categories.indices {
                for proj in d.categories[cat].projects.indices {
                    if let idx = d.categories[cat].projects[proj].items.firstIndex(where: { $0.id == itemID }) {
                        transform(&d.categories[cat].projects[proj].items[idx])
                        return
                    }
                }
            }
        }
    }

    func toggleItem(_ itemID: UUID) {
        mutateItem(itemID) { $0.done.toggle() }
    }

    func setDeadline(_ itemID: UUID, to date: Date?) {
        mutateItem(itemID) { $0.deadline = date }
    }

    /// 拖到某一行上：往下拖插到它之后，往上拖插到它之前（否则拖到紧邻的下一行等于原地不动）。
    func moveItem(_ draggedID: UUID, onto targetID: UUID) {
        guard draggedID != targetID else { return }
        update { d in
            let order = d.categories.flatMap { $0.projects.flatMap { $0.items.map(\.id) } }
            guard let from = order.firstIndex(of: draggedID),
                  let to = order.firstIndex(of: targetID),
                  let source = locateItem(draggedID, in: d) else { return }
            let item = d.categories[source.category].projects[source.project].items.remove(at: source.item)
            guard let target = locateItem(targetID, in: d) else {
                d.categories[source.category].projects[source.project].items.insert(item, at: source.item)
                return
            }
            let items = d.categories[target.category].projects[target.project].items
            let at = from < to ? min(target.item + 1, items.count) : target.item
            d.categories[target.category].projects[target.project].items.insert(item, at: at)
        }
    }

    /// 拖到项目末尾（"添加事项"那一行）。
    func moveItem(_ draggedID: UUID, toEndOfProject projectID: UUID) {
        update { d in
            guard let source = locateItem(draggedID, in: d),
                  let target = locateItem(projectID: projectID, in: d) else { return }
            let item = d.categories[source.category].projects[source.project].items.remove(at: source.item)
            d.categories[target.category].projects[target.project].items.append(item)
        }
    }

    func moveCategory(_ draggedID: UUID, onto targetID: UUID) {
        guard draggedID != targetID else { return }
        update { d in
            guard let from = d.categories.firstIndex(where: { $0.id == draggedID }),
                  let to = d.categories.firstIndex(where: { $0.id == targetID }) else { return }
            let category = d.categories.remove(at: from)
            d.categories.insert(category, at: to)
        }
    }

    func moveCategoryToLast(_ draggedID: UUID) {
        update { d in
            guard let from = d.categories.firstIndex(where: { $0.id == draggedID }) else { return }
            d.categories.append(d.categories.remove(at: from))
        }
    }

    // MARK: - 便签

    var notes: [StickyNote] { data.notes }

    func note(_ id: UUID) -> StickyNote? { data.notes.first { $0.id == id } }

    @discardableResult
    func addNote(text: String = "") -> UUID {
        var note = StickyNote(text: text)
        note.colorIndex = data.notes.count % NotePalette.count
        update { d in d.notes.insert(note, at: 0) }
        return note.id
    }

    func mutateNote(_ id: UUID, _ transform: (inout StickyNote) -> Void) {
        update { d in
            guard let i = d.notes.firstIndex(where: { $0.id == id }) else { return }
            transform(&d.notes[i])
            d.notes[i].updatedAt = Date()
        }
    }

    /// 关掉一张空便签时的自动删除不该存撤销点：那一步是留给「误删了一大坨」救命的，
    /// 只保一步，被一张没写过字的便签顶掉就救不回类别了。
    func removeNote(_ id: UUID, keepUndo: Bool = true) {
        if keepUndo { takeUndoPoint() }
        update { d in d.notes.removeAll { $0.id == id } }
    }

    func duplicateNote(_ id: UUID) {
        update { d in
            guard let i = d.notes.firstIndex(where: { $0.id == id }) else { return }
            var copy = d.notes[i]
            copy.id = UUID()
            copy.pinnedToDesktop = false
            copy.remindAt = nil
            copy.collapsed = false
            copy.expandedHeight = nil
            d.notes.insert(copy, at: i)
        }
    }

    func moveNote(_ draggedID: UUID, onto targetID: UUID) {
        guard draggedID != targetID else { return }
        update { d in
            guard let from = d.notes.firstIndex(where: { $0.id == draggedID }),
                  let to = d.notes.firstIndex(where: { $0.id == targetID }) else { return }
            let note = d.notes.remove(at: from)
            d.notes.insert(note, at: to)
        }
    }

    func moveNoteToLast(_ draggedID: UUID) {
        update { d in
            guard let from = d.notes.firstIndex(where: { $0.id == draggedID }) else { return }
            d.notes.append(d.notes.remove(at: from))
        }
    }

    func toggleNoteCheckbox(_ noteID: UUID, line: Int, to done: Bool) {
        mutateNote(noteID) { note in
            var lines = note.text.components(separatedBy: "\n")
            guard lines.indices.contains(line) else { return }
            lines[line] = MarkdownText.setCheckbox(lines[line], done: done)
            note.text = lines.joined(separator: "\n")
        }
    }

    /// 折叠不算改内容，别把「更新于」时间顶到当下
    func setNoteCollapsed(_ id: UUID, collapsed: Bool, expandedHeight: Double?) {
        update { d in
            guard let i = d.notes.firstIndex(where: { $0.id == id }) else { return }
            d.notes[i].collapsed = collapsed
            d.notes[i].expandedHeight = expandedHeight
        }
    }

    private func locateItem(_ itemID: UUID, in d: BoardData) -> (category: Int, project: Int, item: Int)? {
        for c in d.categories.indices {
            for p in d.categories[c].projects.indices {
                if let i = d.categories[c].projects[p].items.firstIndex(where: { $0.id == itemID }) {
                    return (c, p, i)
                }
            }
        }
        return nil
    }

    private func locateItem(projectID: UUID, in d: BoardData) -> (category: Int, project: Int)? {
        for c in d.categories.indices {
            if let p = d.categories[c].projects.firstIndex(where: { $0.id == projectID }) { return (c, p) }
        }
        return nil
    }
}
