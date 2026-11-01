import Foundation
import Observation

/// Disclosure state belongs to the tree, so toggling it cannot invalidate the Markdown pane.
@Observable
final class LibraryTreeState {
    private(set) var visibleEntries: [LibraryTreeIndex.Entry] = []
    /// 用户**显式展开**过的文件夹路径。不在这个集合里 = 默认折叠——
    /// 启动不再把所有文件夹一股脑展开（之前的行为），且展开/折叠状态按 vault 持久化，
    /// 关了再开保持上次的模样（用户明确要「之前关闭是什么状态就是什么状态」）。
    private(set) var expanded: Set<String> = []
    var selectedFolder: URL?
    private(set) var fileCount = 0
    @ObservationIgnored private var index = LibraryTreeIndex.empty
    @ObservationIgnored private var included: Set<Int>?
    /// 当前已载入展开集合的那个库根；换库时据此决定要不要重新读盘。
    @ObservationIgnored private var expandedRoot: URL?

    func update(index: LibraryTreeIndex, matchingPaths: Set<String>?, fileCount: Int) {
        if self.index.root != index.root {
            selectedFolder = nil
            loadExpanded(for: index.root)
        }
        self.index = index
        included = index.includedEntries(matchingPaths: matchingPaths)
        self.fileCount = fileCount
        rebuild()
    }
    func toggle(_ folder: URL) {
        selectedFolder = folder
        let path = folder.path
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        persistExpanded()
        rebuild()
    }
    func reveal(_ url: URL) { selectFolder(url.deletingLastPathComponent()) }
    func selectFolder(_ folder: URL) {
        selectedFolder = folder == index.root ? nil : folder
        var ancestor = folder
        var changed = false
        while ancestor.path != "/", ancestor != index.root {
            // 跳到某篇时把沿途祖先展开，那篇才看得见（展开 = 进集合）。
            if expanded.insert(ancestor.path).inserted { changed = true }
            ancestor.deleteLastPathComponent()
        }
        if changed { persistExpanded(); rebuild() }
    }
    private func rebuild() { visibleEntries = index.visibleEntries(expanded: expanded, included: included) }

    // MARK: 展开状态持久化（按 vault 分别存，换库互不串台）

    private func expandedKey(for root: URL) -> String {
        "libraryExpanded:" + root.standardizedFileURL.path
    }
    private func loadExpanded(for root: URL?) {
        guard let root else { expanded = []; expandedRoot = nil; return }
        let key = expandedKey(for: root)
        if let saved = AppEnv.defaults.array(forKey: key) as? [String], !saved.isEmpty {
            expanded = Set(saved)
        } else {
            expanded = []
        }
        expandedRoot = root
    }
    private func persistExpanded() {
        guard let root = expandedRoot else { return }
        AppEnv.defaults.set(Array(expanded), forKey: expandedKey(for: root))
    }
}
