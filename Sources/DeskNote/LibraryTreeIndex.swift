import Foundation

/// Built when the file inventory changes, never while a disclosure control is being clicked.
/// Preorder subtree bounds let a collapsed folder skip all descendants in one step.
struct LibraryTreeIndex {
    struct File {
        let url: URL
        var conflict = false
    }
    struct Entry: Identifiable, Equatable {
        let url: URL
        let directory: Bool
        let depth: Int
        let relativePath: String
        let title: String
        let conflict: Bool
        let parent: Int?
        var subtreeEnd: Int
        let id: String
    }
    let root: URL?
    let entries: [Entry]
    private let positions: [String: Int]
    /// 这一棵树搭在哪个根上、树里有哪些条目。库页扫描拿它判「这一轮的树要不要重搭」：
    /// 两百份文件重搭一次三十多毫秒，而绝大多数轮子文件一个没增减。
    /// 集合里的键用 `Entry.id` 同一个口径（枚举器给的原始路径），不比 `standardizedFileURL`：
    /// 软链根下那个形态和枚举器返回的不是一套，两边对不上的话每一轮都会白搭一次树——
    /// 而「对不上」在测试里看不出来，只有时间会诚实。
    let rootPath: String
    let treePaths: Set<String>
    let conflictPaths: Set<String>
    static let empty = LibraryTreeIndex()

    private init() {
        root = nil; entries = []; positions = [:]
        rootPath = ""; treePaths = []; conflictPaths = []
    }

    init(root: URL, folders: [URL], files: [File]) {
        self.root = root
        final class Node {
            var url: URL
            let name: String
            var file: File?
            var children: [String: Node] = [:]
            init(url: URL, name: String) { self.url = url; self.name = name }
        }
        let base = root.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let trunk = Node(url: root, name: "")
        func insert(_ url: URL, file: File?) {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return }
            let parts = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
            var node = trunk
            for part in parts {
                if let child = node.children[part] { node = child }
                else {
                    let child = Node(url: node.url.appendingPathComponent(part), name: part)
                    node.children[part] = child
                    node = child
                }
            }
            node.url = url
            node.file = file
        }
        for folder in folders { insert(folder, file: nil) }
        for file in files { insert(file.url, file: file) }
        var flattened: [Entry] = []
        flattened.reserveCapacity(folders.count + files.count)
        func flatten(_ node: Node, depth: Int, parent: Int?, relative: String) {
            let children = node.children.values.sorted {
                let aDirectory = $0.file == nil
                let bDirectory = $1.file == nil
                if aDirectory != bDirectory { return aDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for child in children {
                let position = flattened.count
                let path = relative.isEmpty ? child.name : relative + "/" + child.name
                flattened.append(Entry(url: child.url, directory: child.file == nil, depth: depth,
                                       relativePath: path,
                                       title: child.file == nil ? child.name : child.url.deletingPathExtension().lastPathComponent,
                                       conflict: child.file?.conflict ?? false,
                                       parent: parent, subtreeEnd: position + 1, id: child.url.path))
                flatten(child, depth: depth + 1, parent: position, relative: path)
                flattened[position].subtreeEnd = flattened.count
            }
        }
        flatten(trunk, depth: 0, parent: nil, relative: "")
        entries = flattened
        rootPath = base
        var paths: Set<String> = []
        var conflicts: Set<String> = []
        paths.reserveCapacity(flattened.count)
        for entry in flattened {
            paths.insert(entry.id)
            if entry.conflict { conflicts.insert(entry.id) }
        }
        treePaths = paths
        conflictPaths = conflicts
        positions = Dictionary(uniqueKeysWithValues: flattened.enumerated().map { ($0.element.id, $0.offset) })
    }

    /// 两棵树管的是不是同一批文件。`LibraryModel` 用它决定「这一轮要不要把 treeIndex 写出去」——
    /// 写一次，观察它的整棵侧栏就重画一次，而绝大多数扫描轮子什么都没动。
    func sharesInventory(with other: LibraryTreeIndex) -> Bool {
        rootPath == other.rootPath && treePaths == other.treePaths && conflictPaths == other.conflictPaths
    }

    /// Compute search ancestors only when the query/filter changes. Nil means no filter.
    func includedEntries(matchingPaths: Set<String>?) -> Set<Int>? {        guard let matchingPaths else { return nil }
        var included: Set<Int> = []
        for path in matchingPaths {
            var position = positions[path]
            while let current = position {
                guard included.insert(current).inserted else { break }
                position = entries[current].parent
            }
        }
        return included
    }

    /// `expanded` 是用户**显式展开**过的文件夹路径。不在这个集合里的文件夹默认折叠——
    /// 这样启动不再把所有文件夹一股脑展开，且展开/折叠状态由 `LibraryTreeState` 按 vault 持久化。
    func visibleEntries(expanded: Set<String>, included: Set<Int>? = nil) -> [Entry] {
        var visible: [Entry] = []
        var position = 0
        while position < entries.count {
            let entry = entries[position]
            if let included, !included.contains(position) {
                position = entry.subtreeEnd
                continue
            }
            visible.append(entry)
            // Search intentionally reveals matches even inside previously collapsed folders.
            position = included == nil && entry.directory && !expanded.contains(entry.id)
                ? entry.subtreeEnd : position + 1
        }
        return visible
    }
}
