import Foundation

var failures = 0
var passes = 0
func check(_ condition: Bool, _ description: String) {
    if condition { passes += 1 } else { failures += 1; print("✗ \(description)") }
}
func eq<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
    if actual == expected { passes += 1 }
    else {
        failures += 1
        print("✗ \(description)\n    实得 \(actual)\n    期望 \(expected)")
    }
}

/// 旧 LibraryWorkspace.entries(_:) 算法的 Foundation-only 副本，用于基准对照。
/// 输入 files 对应 model.rows(in:query:) 的结果；searching 对应旧视图的搜索/筛选状态。
struct LegacyTreeEntry: Equatable {
    let url: URL
    let directory: Bool
    let depth: Int
}

enum LegacyTree {
    static func entries(root: URL, folders: [URL], files: [URL],
                        collapsed: Set<String>, searching: Bool) -> [LegacyTreeEntry] {
        var all = folders.filter { folder in
            !searching || files.contains { $0.path.hasPrefix(folder.path + "/") }
        }.map { LegacyTreeEntry(url: $0, directory: true, depth: depth($0, root)) }
        all += files.map { LegacyTreeEntry(url: $0, directory: false, depth: depth($0, root)) }
        all.sort { a, b in
            let aa = relative(a.url, root).split(separator: "/").map(String.init)
            let bb = relative(b.url, root).split(separator: "/").map(String.init)
            for i in 0..<min(aa.count, bb.count) {
                if aa[i] == bb[i] { continue }
                let aFolder = i < aa.count - 1 || a.directory
                let bFolder = i < bb.count - 1 || b.directory
                if aFolder != bFolder { return aFolder }
                return aa[i].localizedStandardCompare(bb[i]) == .orderedAscending
            }
            return aa.count < bb.count
        }
        return all.filter { entry in
            searching || !collapsed.contains(where: { entry.url.path.hasPrefix($0 + "/") })
        }
    }

    private static func relative(_ url: URL, _ root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }
    private static func depth(_ url: URL, _ root: URL) -> Int {
        max(0, relative(url, root).split(separator: "/").count - 1)
    }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("tree-layer-\(UUID().uuidString)", isDirectory: true)
func url(_ relativePath: String, directory: Bool = false) -> URL {
    root.appendingPathComponent(relativePath, isDirectory: directory)
}

let folderPaths = [
    "Folder10", "Folder2", "Folder1", "Folder1/Deep2", "Folder1/Deep10",
    "Folder2/Sub", "Empty"
]
let filePaths = [
    "z-root.md", "a-root.md", "Folder1/Note10.md", "Folder1/Note2.md",
    "Folder1/Deep2/Needle.md", "Folder1/Deep2/Other.md", "Folder1/Deep10/Last.md",
    "Folder2/Root.md", "Folder2/Sub/Doc10.md", "Folder2/Sub/Doc2.md"
]
let folders = folderPaths.map { url($0, directory: true) }
let files = filePaths.map { LibraryTreeIndex.File(url: url($0)) }
let index = LibraryTreeIndex(root: root, folders: folders, files: files)
let allPaths = index.entries.map(\.relativePath)

// 1 同级目录按自然顺序排列，目录在文件前；文件名也按自然顺序排列。
let expectedOrder = [
    "Empty",
    "Folder1", "Folder1/Deep2", "Folder1/Deep2/Needle.md", "Folder1/Deep2/Other.md",
    "Folder1/Deep10", "Folder1/Deep10/Last.md", "Folder1/Note2.md", "Folder1/Note10.md",
    "Folder2", "Folder2/Sub", "Folder2/Sub/Doc2.md", "Folder2/Sub/Doc10.md", "Folder2/Root.md",
    "Folder10", "a-root.md", "z-root.md"
]
eq(allPaths, expectedOrder, "目录优先且目录、文件都按自然顺序排列")

// 2 空目录保留在索引中，并且没有伪造子项。
if let empty = index.entries.first(where: { $0.relativePath == "Empty" }) {
    check(empty.directory, "空目录仍作为目录项出现")
    eq(empty.subtreeEnd, (index.entries.firstIndex(where: { $0.id == empty.id }) ?? -1) + 1,
       "空目录子树范围只有自身")
} else {
    check(false, "空目录仍作为目录项出现")
}

// 3 收起中层目录时保留目录行、完整跳过后代，并显示后续兄弟节点。
let folder1 = url("Folder1", directory: true)
let collapsedFolder = index.visibleEntries(collapsed: [folder1.path]).map(\.relativePath)
let expectedFolderCollapse = allPaths.filter { $0 == "Folder1" || !$0.hasPrefix("Folder1/") }
eq(collapsedFolder, expectedFolderCollapse, "收起目录完整跳过全部子树")
check(collapsedFolder.contains("Folder2") && collapsedFolder.contains("a-root.md"),
      "收起子树后仍显示后续目录和根文件")

// 4 深层目录独立收起，只隐藏它自己的后代。
let deep2 = url("Folder1/Deep2", directory: true)
let collapsedDeep = index.visibleEntries(collapsed: [deep2.path]).map(\.relativePath)
let expectedDeepCollapse = allPaths.filter { $0 == "Folder1/Deep2" || !$0.hasPrefix("Folder1/Deep2/") }
eq(collapsedDeep, expectedDeepCollapse, "深层收起只跳过深层目录自己的子树")

// 5 搜索匹配文件时包含祖先目录；搜索时忽略此前的折叠状态。
let needle = url("Folder1/Deep2/Needle.md")
let included = index.includedEntries(matchingPaths: [needle.path])
let matching = index.visibleEntries(collapsed: [folder1.path, deep2.path], included: included)
eq(matching.map(\.relativePath), ["Folder1", "Folder1/Deep2", "Folder1/Deep2/Needle.md"],
   "搜索匹配文件时父目录可见，且折叠状态不隐藏搜索结果")
let searchLegacy = LegacyTree.entries(root: root, folders: folders, files: [needle],
                                      collapsed: [folder1.path, deep2.path], searching: true)
eq(matching.map(\.relativePath), searchLegacy.map { relativePath($0.url, root) },
   "搜索表现与旧算法一致")

// 6 展开恢复时复用同一份索引，所有原条目重新可见。
var collapsedState: Set<String> = []
let expandedBefore = index.visibleEntries(collapsed: collapsedState).map(\.relativePath)
collapsedState.insert(folder1.path)
_ = index.visibleEntries(collapsed: collapsedState)
collapsedState.remove(folder1.path)
eq(index.visibleEntries(collapsed: collapsedState).map(\.relativePath), expandedBefore,
   "再次展开后完整恢复原树")
eq(index.entries.map(\.relativePath), allPaths, "折叠与展开不会改写索引")

// 7 非搜索状态下，旧算法和新索引显示相同的树与折叠结果。
let legacyExpanded = LegacyTree.entries(root: root, folders: folders, files: filePaths.map { url($0) },
                                        collapsed: [], searching: false)
eq(allPaths, legacyExpanded.map { relativePath($0.url, root) }, "未折叠时与旧算法顺序一致")
let legacyCollapsed = LegacyTree.entries(root: root, folders: folders, files: filePaths.map { url($0) },
                                         collapsed: [folder1.path, deep2.path], searching: false)
eq(index.visibleEntries(collapsed: [folder1.path, deep2.path]).map(\.relativePath),
   legacyCollapsed.map { relativePath($0.url, root) }, "折叠后与旧算法可见项一致")

// 8 折叠状态：点击只改可见行，不更新文件计数或重建排序索引。
let treeState = LibraryTreeState()
treeState.update(index: index, matchingPaths: nil, fileCount: filePaths.count)
let stateAllPaths = treeState.visibleEntries.map(\.relativePath)
treeState.toggle(folder1)
check(treeState.collapsed.contains(folder1.path), "toggle 收起文件夹")
eq(treeState.selectedFolder, folder1, "toggle 选中文件夹")
eq(treeState.fileCount, filePaths.count, "toggle 不调用 update 改写文件计数")
eq(treeState.visibleEntries.map(\.relativePath), expectedFolderCollapse, "state 折叠完整跳过子树")
treeState.toggle(folder1)
check(!treeState.collapsed.contains(folder1.path), "再次 toggle 展开文件夹")
eq(treeState.visibleEntries.map(\.relativePath), stateAllPaths, "再次展开恢复完整可见树")

// 同库更新保留展开状态和选择；换库时清空它们。
treeState.toggle(folder1)
let addedFile = url("Folder1/Added.md")
let sameLibraryUpdate = LibraryTreeIndex(root: root, folders: folders,
                                         files: files + [LibraryTreeIndex.File(url: addedFile)])
treeState.update(index: sameLibraryUpdate, matchingPaths: nil, fileCount: filePaths.count + 1)
check(treeState.collapsed.contains(folder1.path), "同库 update 保留折叠状态")
eq(treeState.selectedFolder, folder1, "同库 update 保留文件夹选择")
eq(treeState.fileCount, filePaths.count + 1, "同库 update 刷新文件数")
check(!treeState.visibleEntries.contains { $0.url == addedFile }, "折叠时同库新增文件仍在子树内隐藏")
treeState.toggle(folder1)
check(treeState.visibleEntries.contains { $0.url == addedFile }, "展开后能看到同库新增文件")

// reveal 会打开路径上的所有祖先，并将目标文件的父文件夹设为选择。
treeState.toggle(folder1)
treeState.toggle(deep2)
treeState.reveal(needle)
check(treeState.collapsed.isEmpty, "reveal 展开目标的所有折叠祖先")
eq(treeState.selectedFolder, deep2, "reveal 选中文件所在的父文件夹")
check(treeState.visibleEntries.contains { $0.url == needle }, "reveal 后目标文件可见")
eq(treeState.fileCount, filePaths.count + 1, "toggle 与 reveal 均不调用 update")
eq(index.entries.map(\.relativePath), allPaths, "toggle 与 reveal 不重排既有索引")

let otherRoot = root.appendingPathComponent("other-library", isDirectory: true)
let otherFolder = otherRoot.appendingPathComponent("Other", isDirectory: true)
let otherFile = otherFolder.appendingPathComponent("new.md")
let otherIndex = LibraryTreeIndex(root: otherRoot, folders: [otherFolder],
                                  files: [LibraryTreeIndex.File(url: otherFile)])
treeState.toggle(otherFolder)
treeState.update(index: otherIndex, matchingPaths: nil, fileCount: 1)
check(treeState.collapsed.isEmpty, "切换库后清空旧折叠状态")
eq(treeState.selectedFolder, nil as URL?, "切换库后清空旧文件夹选择")
eq(treeState.visibleEntries.map(\.relativePath), ["Other", "Other/new.md"], "切换库显示新文件树")

func relativePath(_ url: URL, _ root: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
}

// 9 合成 10,000 个文件：旧 body 每次调用会完整计算 entries 两遍；
// 新实现把排序放在索引初始化里，点击折叠只走 visibleEntries 热路径。
let benchmarkRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("tree-benchmark", isDirectory: true)
var benchmarkFolders: [URL] = []
var benchmarkFiles: [URL] = []
benchmarkFolders.reserveCapacity(1_100)
benchmarkFiles.reserveCapacity(10_000)
for group in 0..<100 {
    let groupName = String(format: "Group%03d", group)
    let groupURL = benchmarkRoot.appendingPathComponent(groupName, isDirectory: true)
    benchmarkFolders.append(groupURL)
    for part in 0..<10 {
        let partName = String(format: "Part%02d", part)
        let partURL = groupURL.appendingPathComponent(partName, isDirectory: true)
        benchmarkFolders.append(partURL)
        for file in 0..<10 {
            let fileName = String(format: "Report%02d.md", file)
            benchmarkFiles.append(partURL.appendingPathComponent(fileName))
        }
    }
}
let benchmarkCollapse: Set<String> = [benchmarkRoot.appendingPathComponent("Group050", isDirectory: true).path]
let rounds = 3
let oldVisibleOnce = LegacyTree.entries(root: benchmarkRoot, folders: benchmarkFolders,
                                        files: benchmarkFiles, collapsed: benchmarkCollapse,
                                        searching: false).count
let oldStart = DispatchTime.now().uptimeNanoseconds
var oldChecksum = 0
for _ in 0..<rounds {
    // Match the two entries(root) calls in the old SwiftUI body: ForEach plus isEmpty.
    oldChecksum += LegacyTree.entries(root: benchmarkRoot, folders: benchmarkFolders,
                                      files: benchmarkFiles, collapsed: benchmarkCollapse,
                                      searching: false).count
    oldChecksum += LegacyTree.entries(root: benchmarkRoot, folders: benchmarkFolders,
                                      files: benchmarkFiles, collapsed: benchmarkCollapse,
                                      searching: false).isEmpty ? 1 : 0
}
let oldElapsed = DispatchTime.now().uptimeNanoseconds - oldStart

let initStart = DispatchTime.now().uptimeNanoseconds
let benchmarkIndex = LibraryTreeIndex(root: benchmarkRoot,
                                       folders: benchmarkFolders,
                                       files: benchmarkFiles.map { LibraryTreeIndex.File(url: $0) })
let initElapsed = DispatchTime.now().uptimeNanoseconds - initStart
let newVisibleOnce = benchmarkIndex.visibleEntries(collapsed: benchmarkCollapse).count
let visibleStart = DispatchTime.now().uptimeNanoseconds
var newChecksum = 0
for _ in 0..<rounds {
    newChecksum += benchmarkIndex.visibleEntries(collapsed: benchmarkCollapse).count
}
let visibleElapsed = DispatchTime.now().uptimeNanoseconds - visibleStart

check(benchmarkFiles.count == 10_000, "性能样本包含 10,000 个文件")
eq(oldVisibleOnce, newVisibleOnce, "基准中旧、新算法可见行数一致")
eq(oldChecksum, oldVisibleOnce * rounds, "旧算法基准确实每轮计算两遍")
eq(newChecksum, newVisibleOnce * rounds, "新算法基准重复使用预排序索引")
func milliseconds(_ nanoseconds: UInt64) -> String {
    String(format: "%.2f", Double(nanoseconds) / 1_000_000)
}
print("\n合成 10,000 文件性能对比（仅算法，不含 SwiftUI body/layout/diff/render；无固定耗时阈值）")
print("旧 entries：每次 body 两遍 × \(rounds) 轮 = \(milliseconds(oldElapsed)) ms")
print("新索引初始化与排序（一次）= \(milliseconds(initElapsed)) ms")
print("新折叠 visibleEntries 热路径 × \(rounds) 轮 = \(milliseconds(visibleElapsed)) ms")

print("\n通过 \(passes) 条，失败 \(failures) 条")
exit(failures == 0 ? 0 : 1)
