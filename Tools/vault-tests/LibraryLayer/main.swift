import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ what: String) {
    if cond { passes += 1 } else { failures += 1; print("✗ \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    if a == b { passes += 1 } else { failures += 1; print("✗ \(what)\n    实得 \(a)\n    期望 \(b)") }
}

let temp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("library-layer-\(UUID().uuidString)", isDirectory: true)
let root = temp.appendingPathComponent("vault", isDirectory: true)
let outside = temp.appendingPathComponent("outside", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

// 1 YAML 原样透传，CRLF 和正文边界都保留
let yaml = "---\r\ntags: [工作, 重要]\r\ncustom: value  \r\n  nested: keep\r\n---\r\n\r\n# 正文\r\n最后一行\r\n"
let yamlPrefix = "---\r\ntags: [工作, 重要]\r\ncustom: value  \r\n  nested: keep\r\n---\r\n"
let yamlBody = "\r\n# 正文\r\n最后一行\r\n"
let snapshot = LibraryFiles.Snapshot(yaml)
eq(snapshot.raw, yaml, "快照保存完整原文")
eq(snapshot.prefix, yamlPrefix, "YAML frontmatter 前缀逐字保留 CRLF")
eq(snapshot.body, yamlBody, "CRLF frontmatter 后正文边界逐字保留")

// 2 无 frontmatter 和空正文
let plain = "# 普通 Markdown\n\n这里没有 frontmatter。\n"
let plainSnapshot = LibraryFiles.Snapshot(plain)
eq(plainSnapshot.prefix, "", "无 frontmatter 时前缀为空")
eq(plainSnapshot.body, plain, "无 frontmatter 时全文是正文")
let emptySnapshot = LibraryFiles.Snapshot("")
eq(emptySnapshot.prefix, "", "空文件没有前缀")
eq(emptySnapshot.body, "", "空文件正文为空")
let emptyBodyRaw = "---\r\ntags: [空正文]\r\n---\r\n"
let emptyBody = LibraryFiles.Snapshot(emptyBodyRaw)
eq(emptyBody.prefix, emptyBodyRaw, "只有 frontmatter 的文件前缀完整")
eq(emptyBody.body, "", "frontmatter 后没有正文时正文为空")

// 3 只有磁盘与快照基线一致时才覆盖原文件
let saveURL = root.appendingPathComponent("save.md")
let original = "---\ntags: [原样]\n---\n\n旧正文\n"
try! original.write(to: saveURL, atomically: true, encoding: .utf8)
let saveSnapshot = LibraryFiles.Snapshot(original)
switch try! LibraryFiles.save(body: "新正文\n", snapshot: saveSnapshot, url: saveURL, root: root) {
case .original:
    check(true, "基线一致时保存原文件")
case .conflict:
    check(false, "基线一致时不应另存冲突副本")
}
eq(try! String(contentsOf: saveURL, encoding: .utf8), saveSnapshot.prefix + "新正文\n", "保存仅替换正文")

// 4 并发外部编辑时写冲突副本，原文件保持外部版本
let changedURL = root.appendingPathComponent("changed.md")
let changedBase = "---\ntags: [保留]\n---\n\n初始\n"
let changedOnDisk = "---\ntags: [外部修改]\n---\n\n外部正文\n"
try! changedBase.write(to: changedURL, atomically: true, encoding: .utf8)
let changedSnapshot = LibraryFiles.Snapshot(changedBase)
try! changedOnDisk.write(to: changedURL, atomically: true, encoding: .utf8)
let changedSaved = try! LibraryFiles.save(body: "本地正文\n", snapshot: changedSnapshot,
                                           url: changedURL, root: root)
if case .conflict(let conflictURL) = changedSaved {
    eq(try! String(contentsOf: changedURL, encoding: .utf8), changedOnDisk, "外部修改原文件未被覆盖")
    eq(try! String(contentsOf: conflictURL, encoding: .utf8),
       changedSnapshot.prefix + "本地正文\n", "本地编辑保存到冲突副本")
} else {
    check(false, "并发外部修改应保存冲突副本")
}

// 5 外部删除时也只保存冲突副本，不把原文件复活
let deletedURL = root.appendingPathComponent("deleted.md")
let deletedBase = "---\ntags: [删除测试]\n---\n\n原正文\n"
try! deletedBase.write(to: deletedURL, atomically: true, encoding: .utf8)
let deletedSnapshot = LibraryFiles.Snapshot(deletedBase)
try! FileManager.default.removeItem(at: deletedURL)
let deletedSaved = try! LibraryFiles.save(body: "尚未同步的修改\n", snapshot: deletedSnapshot,
                                           url: deletedURL, root: root)
if case .conflict(let conflictURL) = deletedSaved {
    check(!FileManager.default.fileExists(atPath: deletedURL.path), "外部刪除的原文件不会复活")
    eq(try! String(contentsOf: conflictURL, encoding: .utf8),
       deletedSnapshot.prefix + "尚未同步的修改\n", "外部删除后的本地内容另存")
} else {
    check(false, "外部删除应保存冲突副本")
}

// 6 创建时遇到同名文件必须失败
let duplicate = try! LibraryFiles.create(name: "重复名称", folder: root, directory: false, root: root)
eq(duplicate.lastPathComponent, "重复名称.md", "新 Markdown 文件自动补 .md")
do {
    _ = try LibraryFiles.create(name: "重复名称.md", folder: root, directory: false, root: root)
    check(false, "创建重名文件应失败")
} catch LibraryFiles.Failure.exists {
    check(true, "创建重名文件明确报已存在")
} catch {
    check(false, "创建重名文件报错类型正确")
}

// 7 文件和目录重命名，目录内文件随目录移动
let draft = try! LibraryFiles.create(name: "草稿", folder: root, directory: false, root: root)
try! "文件内容".write(to: draft, atomically: true, encoding: .utf8)
let final = try! LibraryFiles.rename(draft, to: "定稿", directory: false, root: root)
eq(final.lastPathComponent, "定稿.md", "文件重命名自动补 .md")
check(!FileManager.default.fileExists(atPath: draft.path), "文件重命名移走旧路径")
eq(try! String(contentsOf: final, encoding: .utf8), "文件内容", "文件重命名保留内容")

let reports = try! LibraryFiles.create(name: "报告", folder: root, directory: true, root: root)
let report = try! LibraryFiles.create(name: "季度", folder: reports, directory: false, root: root)
try! "报告正文".write(to: report, atomically: true, encoding: .utf8)
let archive = try! LibraryFiles.rename(reports, to: "归档", directory: true, root: root)
let archivedReport = archive.appendingPathComponent("季度.md")
check(!FileManager.default.fileExists(atPath: reports.path), "目录重命名移走旧路径")
eq(try! String(contentsOf: archivedReport, encoding: .utf8), "报告正文", "目录重命名保留子文件")

// 8 符号链接指向库外时不能写入，也不能被文件夹扫描跟随
let outsideDoc = outside.appendingPathComponent("secret.md")
try! "库外文件".write(to: outsideDoc, atomically: true, encoding: .utf8)
let outsideFolderLink = root.appendingPathComponent("外部目录", isDirectory: true)
try! FileManager.default.createSymbolicLink(at: outsideFolderLink, withDestinationURL: outside)
do {
    _ = try LibraryFiles.create(name: "逃逸", folder: outsideFolderLink, directory: false, root: root)
    check(false, "通过库内目录软链创建文件应被拒绝")
} catch LibraryFiles.Failure.outsideRoot {
    check(true, "通过库内目录软链创建文件被拒绝")
} catch {
    check(false, "库内目录软链报错类型正确")
}
let outsideFileLink = root.appendingPathComponent("外部文件.md")
try! FileManager.default.createSymbolicLink(at: outsideFileLink, withDestinationURL: outsideDoc)
do {
    try LibraryFiles.validate(outsideFileLink, root: root)
    check(false, "指向库外文件的软链应被拒绝")
} catch LibraryFiles.Failure.outsideRoot {
    check(true, "指向库外文件的软链被拒绝")
} catch {
    check(false, "库外文件软链报错类型正确")
}

// 9 文件夹扫描包含空目录，跳过隐藏目录和库外软链
let emptyFolder = try! LibraryFiles.create(name: "空目录", folder: root, directory: true, root: root)
let nestedFolder = try! LibraryFiles.create(name: "普通目录", folder: root, directory: true, root: root)
_ = try! LibraryFiles.create(name: "子目录", folder: nestedFolder, directory: true, root: root)
try! FileManager.default.createDirectory(at: root.appendingPathComponent(".隐藏目录", isDirectory: true),
                                         withIntermediateDirectories: false)
let rootPath = root.standardizedFileURL.path
let folderPaths = Set(LibraryFiles.folders(root).map {
    String($0.standardizedFileURL.path.dropFirst(rootPath.count + 1))
})
check(folderPaths.contains(String(emptyFolder.lastPathComponent)), "空文件夹仍被扫描到")
check(folderPaths.contains("普通目录") && folderPaths.contains("普通目录/子目录"), "普通目录树递归扫描")
check(!folderPaths.contains(".隐藏目录"), "隐藏目录不显示")
check(!folderPaths.contains("外部目录"), "扫描不跟随库外文件夹软链")

// 10 扫描建行：便签 / 待办板 / 外部文档三种身份都靠 frontmatter 认，不猜路径
func keyed(_ rows: [LibraryRow]) -> [String: LibraryRow] {
    var out: [String: LibraryRow] = [:]
    for row in rows { out[row.url.standardizedFileURL.path] = row }
    return out
}
func row(_ rows: [LibraryRow], _ url: URL) -> LibraryRow? {
    rows.first { $0.url.standardizedFileURL == url.standardizedFileURL }
}

let scanRoot = temp.appendingPathComponent("scan", isDirectory: true)
for sub in ["notes", "生活", "会议记录"] {
    try! FileManager.default.createDirectory(at: scanRoot.appendingPathComponent(sub, isDirectory: true),
                                             withIntermediateDirectories: true)
}
let scanNoteID = UUID()
var scanNote = StickyNote(text: "买菜\n牛奶、鸡蛋，看 [[周末采购]]", colorIndex: 1)
scanNote.id = scanNoteID
let scanNoteURL = scanRoot.appendingPathComponent("notes/买菜-\(scanNoteID.uuidString.prefix(8)).md")
try! Vault.writeNote(scanNote, to: scanNoteURL)
let scanBoardURL = scanRoot.appendingPathComponent("生活/周末采购.md")
// 我们自己写的键都在 desknote: 那一层里，顶层那几个键是别人家的，split 只透传不吃
try! "---\ndesknote:\n  id: \(UUID().uuidString)\n  category: 生活\n---\n\n- [ ] 买猫粮\n".write(
    to: scanBoardURL, atomically: true, encoding: .utf8)
let scanDocURL = scanRoot.appendingPathComponent("会议记录/设计评审.md")
try! "---\ntags: [评审]\n---\n\n# 2026-10-28 设计评审\n\n图标按 [[买菜]] 那套层级走。\n".write(
    to: scanDocURL, atomically: true, encoding: .utf8)

let cold = LibraryScan.scan(root: scanRoot, baseline: [:], previous: [:], notes: BoardData())
eq(cold.rows.count, 3, "三份 .md 扫出三行")
let noteRow = row(cold.rows, scanNoteURL)
eq(noteRow?.kind, .note, "带 desknote.id 的是便签")
eq(noteRow?.name, "买菜", "便签的行名取第一行")
eq(noteRow?.noteID, scanNoteID, "身份从 frontmatter 认回来")
let boardRow = row(cold.rows, scanBoardURL)
eq(boardRow?.kind, .board, "带 category 的是待办板")
eq(boardRow?.name, "周末采购", "待办板的名字用文件名")
let docRow = row(cold.rows, scanDocURL)
eq(docRow?.kind, .document, "两个都没有的是外部文档")
eq(docRow?.folder, "会议记录", "行记着相对库根的目录")
check(docRow?.linkStems.contains("买菜") == true, "外部文档里的 [[双链]] 进得了反向链接")
eq(cold.problem, nil, "正常一轮不该有报错")
check(cold.rows.allSatisfy { $0.state == .clean }, "没有基线 = 刚见到，满屏都不该标「磁盘改动」")
eq(cold.counts[.all], 3, "counts：全部")
eq(cold.counts[.notes], 1, "counts：便签")
eq(cold.counts[.board], 1, "counts：待办板")
eq(cold.counts[.changed], 0, "counts：磁盘改动")

// 11 增量：stat 一模一样就整行复用，正文一个字节都不读
//   证明方式要狠一点：原地换成**等长**内容并把 mtime 贴回去，三格里能动的都动不了。
//   于是复用的那行还是旧正文——这一条同时把闸门唯一的盲点写在账上：
//   mtime + size 都不动的原地覆写，库页这一层看不见（同步层靠整库重走那一轮兜）。
let docBase = try! String(contentsOf: scanDocURL, encoding: .utf8)
let docStamp = FileStamp(scanDocURL)!
let sameLength = docBase.replacingOccurrences(of: "那套层级", with: "这套配色")   // 4 个字换 4 个字
try! sameLength.write(to: scanDocURL, atomically: false, encoding: .utf8)
try! FileManager.default.setAttributes([.modificationDate: docStamp.date], ofItemAtPath: scanDocURL.path)
eq(FileStamp(scanDocURL)!.contentMatches(docStamp), true, "等长覆写 + 贴回 mtime：三格里比的那两格没动")
let reused = LibraryScan.scan(root: scanRoot, baseline: cold.baseline, previous: keyed(cold.rows),
                              notes: BoardData())
eq(row(reused.rows, scanDocURL)?.head.contains("那套层级"), true, "没动 stat = 整行复用，一个字节都没再读")
eq(row(reused.rows, scanDocURL)?.id, docRow?.id, "同一份文件每次都是同一个行 id（选中状态靠它恢复）")

// 12 动了 mtime 就要重读，新正文认得回来
let newer = Date(timeIntervalSinceReferenceDate: docStamp.modified + 5)
try! FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: scanDocURL.path)
let reread = LibraryScan.scan(root: scanRoot, baseline: cold.baseline, previous: keyed(cold.rows),
                              notes: BoardData())
eq(row(reread.rows, scanDocURL)?.head.contains("这套配色"), true, "mtime 一动就重读，新正文进得来")
eq(row(reread.rows, scanDocURL)?.state, .changed, "这一行对上次扫描来说是磁盘改过的")

// 13 徽标四种各自都要出得来：磁盘改 / 便签改 / 冲突 / 文件名带「冲突」
let badgeRoot = temp.appendingPathComponent("badge", isDirectory: true)
try! FileManager.default.createDirectory(at: badgeRoot, withIntermediateDirectories: true)
var badgeNote = StickyNote(text: "徽标\n正文", colorIndex: 0)
badgeNote.updatedAt = Date(timeIntervalSinceReferenceDate: 700_000_050)
let badgeURL = badgeRoot.appendingPathComponent("徽标.md")
try! Vault.writeNote(badgeNote, to: badgeURL)
let badgeSeed = LibraryScan.scan(root: badgeRoot, baseline: [:], previous: [:], notes: BoardData())
let realStamp = badgeSeed.baseline[badgeURL.standardizedFileURL.path]!
// 上一次扫描看到的是「更早的那一格时间」，磁盘现在这份更新 → 磁盘改
let olderBaseline = [badgeURL.standardizedFileURL.path:
                        FileStamp(modified: realStamp.modified - 60, size: realStamp.size)]
let diskOnly = LibraryScan.scan(root: badgeRoot, baseline: olderBaseline, previous: [:], notes: BoardData())
eq(row(diskOnly.rows, badgeURL)?.state, .changed, "只有磁盘动了 = 磁盘改动")
// 基线和磁盘一模一样，但 DeskNote 这张便签比上次扫描晚 → 待落盘
var pendingData = BoardData()
badgeNote.updatedAt = Date(timeIntervalSinceReferenceDate: realStamp.modified + 60)
pendingData.notes = [badgeNote]
let appOnly = LibraryScan.scan(root: badgeRoot, baseline: badgeSeed.baseline, previous: [:], notes: pendingData)
eq(row(appOnly.rows, badgeURL)?.state, .pending, "只有 DeskNote 动了 = 待落盘")
// 两边都动 → 冲突
let bothBaseline = [badgeURL.standardizedFileURL.path:
                        FileStamp(modified: realStamp.modified - 120, size: realStamp.size)]
let both = LibraryScan.scan(root: badgeRoot, baseline: bothBaseline, previous: [:], notes: pendingData)
eq(row(both.rows, badgeURL)?.state, .conflict, "两边都动过 = 冲突，要人拍板")
// 冲突副本带着「冲突」字样：哪怕 stat 和基线完全对得上，也必须还是冲突
let copyURL = badgeRoot.appendingPathComponent("冲突 徽标.md")
try! Vault.writeNote(badgeNote, to: copyURL)
let bothStamps = LibraryScan.scan(root: badgeRoot, baseline: [:], previous: [:], notes: BoardData())
let cleanCopy = LibraryScan.scan(root: badgeRoot, baseline: bothStamps.baseline,
                                 previous: keyed(bothStamps.rows), notes: BoardData())
eq(row(cleanCopy.rows, copyURL)?.state, .conflict, "文件名带「冲突」的那份永远标着冲突")
check(row(cleanCopy.rows, badgeURL)?.state == .clean, "同一轮里正常那份不该被连坐")

// 14 空文件和「读不出来」是两件事
let mixedRoot = temp.appendingPathComponent("mixed", isDirectory: true)
try! FileManager.default.createDirectory(at: mixedRoot, withIntermediateDirectories: true)
try! "".write(to: mixedRoot.appendingPathComponent("空的.md"), atomically: true, encoding: .utf8)
try! Data([0xB1, 0xA8, 0xCA, 0xC2, 0xFF, 0xFE, 0x00, 0x01]).write(
    to: mixedRoot.appendingPathComponent("旧机器拷来的.md"))
let mixed = LibraryScan.scan(root: mixedRoot, baseline: [:], previous: [:], notes: BoardData())
eq(mixed.rows.count, 1, "空文件是一行，读不出来的那份不是")
eq(row(mixed.rows, mixedRoot.appendingPathComponent("空的.md"))?.head, "", "空文件正文为空，不报错")
check(mixed.problem != nil, "UTF-8 读不出来的那份要说出来")

// 15 head 截断：深处的词不在近文搜里，名字和摘录照旧
let bigRoot = temp.appendingPathComponent("big", isDirectory: true)
try! FileManager.default.createDirectory(at: bigRoot, withIntermediateDirectories: true)
let bigURL = bigRoot.appendingPathComponent("长文档.md")
let filler = String(repeating: "填充的一行中文文字\n", count: 8_000)          // ≈ 190 KB
try! ("# 开头词 alpha\n\n" + filler + "\n深处的词 zulu\n").write(to: bigURL, atomically: true, encoding: .utf8)
let big = LibraryScan.scan(root: bigRoot, baseline: [:], previous: [:], notes: BoardData())
let bigRow = row(big.rows, bigURL)!
eq(bigRow.name, "开头词 alpha", "截断不影响行名")
eq(bigRow.truncated, true, "比 readLimit 长的这份要老实承认截过")
eq(LibraryScan.matches(bigRow, query: "alpha"), true, "近文搜得着头部")
eq(LibraryScan.matches(bigRow, query: "zulu"), false, "深处的词不在近文搜里——那条走「搜正文深处」")
let smallURL = bigRoot.appendingPathComponent("短文档.md")
try! "# 短\n深处的词 zulu 在短文档里就搜得到\n".write(to: smallURL, atomically: true, encoding: .utf8)
let small = LibraryScan.scan(root: bigRoot, baseline: big.baseline, previous: keyed(big.rows), notes: BoardData())
let smallRow = row(small.rows, smallURL)!
eq(smallRow.truncated, false, "没到 readLimit 的不算截断")
eq(LibraryScan.matches(smallRow, query: "zulu"), true, "短文档里的词搜得到")
eq(LibraryScan.matches(smallRow, query: "ZULU"), true, "搜索不区分大小写")
eq(LibraryScan.matches(smallRow, query: "短文档"), true, "文件名也参与搜索")

// 15b 读进来的量和留下的量是两件事：超过 headBytes 的正文要切干净，切了要承认
check(bigRow.head.utf8.count <= LibraryScan.headBytes, "行上留的正文不超过 headBytes")
let midURL = bigRoot.appendingPathComponent("中等文档.md")
try! ("# 中等\n\n" + String(repeating: "中。\n", count: 5_000)).write(to: midURL, atomically: true, encoding: .utf8)
let midScan = LibraryScan.scan(root: bigRoot, baseline: [:], previous: [:], notes: BoardData())
let midRow = row(midScan.rows, midURL)!
check(midRow.stamp!.size <= LibraryScan.readLimit, "这份小到整个读得进来")
eq(midRow.truncated, true, "整个读进来也算截断：正文比 headBytes 长就要承认")
check(midRow.head.utf8.count <= LibraryScan.headBytes, "读得多也要切得下")
check(!midRow.head.contains("\u{FFFD}"), "切在多字节字符上要退到上一个完整字，不许留乱码")

// 16 打印基准：213 份的库，冷扫和增量扫各多久（和同步层 §21 同一个口径，不设阈值断言）
let benchRoot = temp.appendingPathComponent("bench", isDirectory: true)
try! FileManager.default.createDirectory(at: benchRoot, withIntermediateDirectories: true)
// 每 20 份塞一份超出 readLimit 的：增量轮要复用、行上常驻要见小，都靠它
for index in 0..<213 {
    let body = index % 20 == 0 ? "# 文档 \(index)\n\n" + String(repeating: "正文。\n", count: 12_000)
        : "# 文档 \(index)\n\n短正文一行。\n"
    try! body.write(to: benchRoot.appendingPathComponent("文档-\(index).md"), atomically: true, encoding: .utf8)
}
func timed(_ body: () -> Void) -> Double {
    let start = Date()
    body()
    return Date().timeIntervalSince(start) * 1000
}
var benchRows: [LibraryRow] = []
var benchBaseline: [String: FileStamp] = [:]
var benchTree = LibraryTreeIndex.empty
let coldMs = timed { let one = LibraryScan.scan(root: benchRoot, baseline: [:], previous: [:], notes: BoardData())
    benchRows = one.rows; benchBaseline = one.baseline; benchTree = one.treeIndex }
// `keyed` 在真实那一轮里是进后台之前算好的，不算进这一轮的时间
let benchSeen = keyed(benchRows)
let warmMs = timed { _ = LibraryScan.scan(root: benchRoot, baseline: benchBaseline, previous: benchSeen,
                                          notes: BoardData(), previousTree: benchTree) }
let warmAgainMs = timed { _ = LibraryScan.scan(root: benchRoot, baseline: benchBaseline, previous: benchSeen,
                                               notes: BoardData(), previousTree: benchTree) }
// 同一轮、唯一差别是不给上一轮的树：两者之差就是「复用文件树」到底省了多少。
// 差值要是没了，说明那一轮其实每轮都在重搭（增量轮的账就全白记了）。
let rebuildMs = timed { _ = LibraryScan.scan(root: benchRoot, baseline: benchBaseline, previous: benchSeen,
                                             notes: BoardData(), previousTree: nil) }
check(rebuildMs - warmMs > 5, "文件树复用要真省下时间（本轮 \(String(format: "%.1f", rebuildMs - warmMs)) ms）")
let resident = benchRows.reduce(0) { $0 + $1.head.utf8.count }
let onDisk = benchRows.reduce(0) { $0 + ($1.stamp?.size ?? 0) }
let inventoryMs = timed { _ = LibraryFiles.inventory(benchRoot) }
let benchURLs = LibraryFiles.inventory(benchRoot).markdown
var stampTotal = 0
let stampMs = timed { for url in benchURLs { stampTotal += FileStamp(url)?.size ?? 0 } }
let pathMs = timed { for url in benchURLs { _ = url.standardizedFileURL.path } }
let treeFiles = benchRows.map { LibraryTreeIndex.File(url: $0.url) }
let treeFolders = LibraryFiles.inventory(benchRoot).folders
let treeMs = timed { _ = LibraryTreeIndex(root: benchRoot, folders: treeFolders, files: treeFiles) }
let treeAgainMs = timed { _ = LibraryTreeIndex(root: benchRoot, folders: treeFolders, files: treeFiles) }
print("213 份的一轮扫描：冷启动 \(String(format: "%.1f", coldMs)) ms · 增量轮 \(String(format: "%.1f", warmMs)) ms（同一轮但强制重搭文件树 \(String(format: "%.1f", rebuildMs)) ms）· 连着第二轮 \(String(format: "%.1f", warmAgainMs)) ms")
print("增量轮的开销都在哪儿：枚举 \(String(format: "%.1f", inventoryMs)) ms · stat \(String(format: "%.1f", stampMs)) ms · 路径标准化 \(String(format: "%.1f", pathMs)) ms（\(stampTotal / 1024) KB）；文件树单搭 \(String(format: "%.1f", treeMs)) ms / 再搭 \(String(format: "%.1f", treeAgainMs)) ms")
print("行上常驻的正文 \(resident / 1024) KB / 磁盘正文 \(onDisk / 1024) KB")
check(warmMs < coldMs, "增量轮要比冷启动轮快——慢了就说明闸门没生效")
check(resident < onDisk, "超出 readLimit 的那几份只留开头，行上不该背着整篇正文")

// 17 文件树只在「这一批文件真的变了」时重搭
let sameTree = LibraryScan.scan(root: benchRoot, baseline: benchBaseline, previous: benchSeen,
                                notes: BoardData(), previousTree: benchTree)
check(sameTree.treeIndex.sharesInventory(with: benchTree), "什么都没动的增量轮不用重搭文件树")
try! "# 新加入的一份\n\n内容\n".write(to: benchRoot.appendingPathComponent("文档-999.md"),
                                     atomically: true, encoding: .utf8)
let grewTree = LibraryScan.scan(root: benchRoot, baseline: benchBaseline, previous: benchSeen,
                                notes: BoardData(), previousTree: benchTree)
check(!grewTree.treeIndex.sharesInventory(with: benchTree), "多出一份文件就得重搭文件树")
eq(grewTree.treeIndex.treePaths.count, benchTree.treePaths.count + 1, "新文件进了树的清单")
// 空目录里没有 .md，行集一动不动，但侧栏要看得见它——只靠行集判「要不要重搭」是判不出来的
try! FileManager.default.createDirectory(at: benchRoot.appendingPathComponent("空目录", isDirectory: true),
                                         withIntermediateDirectories: true)
let folderScan = LibraryScan.scan(root: benchRoot, baseline: grewTree.baseline, previous: keyed(grewTree.rows),
                                  notes: BoardData(), previousTree: grewTree.treeIndex)
check(!folderScan.treeIndex.sharesInventory(with: grewTree.treeIndex), "只多了一个空目录也要重搭文件树")
// 冲突是树上的一个点，挪动了它同样要重搭
let conflictRoot = temp.appendingPathComponent("conflict-tree", isDirectory: true)
try! FileManager.default.createDirectory(at: conflictRoot, withIntermediateDirectories: true)
let plainURL = conflictRoot.appendingPathComponent("正常.md")
try! "# 正常\n\n正文\n".write(to: plainURL, atomically: true, encoding: .utf8)
let cleanTree = LibraryScan.scan(root: conflictRoot, baseline: [:], previous: [:], notes: BoardData())
check(cleanTree.treeIndex.conflictPaths.isEmpty, "没有冲突副本时树上不该有点")
let markedURL = conflictRoot.appendingPathComponent("正常（冲突 2026-10-30 10.20.30）.md")
try! "# 冲突\n\n另一份\n".write(to: markedURL, atomically: true, encoding: .utf8)
let markedTree = LibraryScan.scan(root: conflictRoot, baseline: cleanTree.baseline,
                                  previous: keyed(cleanTree.rows), notes: BoardData(),
                                  previousTree: cleanTree.treeIndex)
check(!markedTree.treeIndex.sharesInventory(with: cleanTree.treeIndex), "多了个冲突点要重搭文件树")
eq(markedTree.treeIndex.conflictPaths.count, 1, "冲突副本在树上是点得出来的")

// 18 按需深搜：词在 32 KB 之外时那条读盘的路要走得对、要能刹车、不许把整篇留下
let deep = LibrarySearch.run(files: [bigURL], query: "zulu")
eq(deep.count, 1, "深搜在长文档的深处找到那个词")
eq(deep.first?.matches, 1, "一处就是一处，不许数出两处")
check(deep.first?.excerpts.first?.contains("zulu") == true, "命中要带上下文，好让人知道是不是那处")
eq(LibraryScan.matches(bigRow, query: "zulu"), false, "同一个词近文搜还是没有：两条路各管各的深度")
check(LibrarySearch.run(files: [bigURL], query: "ZULU").count == 1, "深搜也不区分大小写")
eq(LibrarySearch.run(files: [bigURL], query: "   ").count, 0, "空白搜索词一个字节都不读")
eq(LibrarySearch.run(files: [bigRoot.appendingPathComponent("这会儿没这份.md")], query: "任何词").count, 0,
   "文件这会儿不在就跳过，不抛不崩")
// 属性块不是正文：搜「只在属性里」命中别人家的 category，会凭空多出几份「找到了」
let fmURL = bigRoot.appendingPathComponent("属性里的词.md")
try! "---\ndesknote:\n  category: 只在属性里\n---\n\n正文里没有那个词\n".write(
    to: fmURL, atomically: true, encoding: .utf8)
eq(LibrarySearch.run(files: [fmURL], query: "只在属性里").count, 0, "属性块跳过：词只在 frontmatter 里就不算命中")

// 跨块的那个词：只按字节切会把它切成两段、两边各半截。carry 和 splitUTF8 就是为这一条装的。
let straddleURL = bigRoot.appendingPathComponent("跨块.md")
var straddle = "# 开头\n\n"
while straddle.utf8.count < LibrarySearch.chunkBytes - 4 { straddle += "x" }   // 全 ASCII，正好压在线上
straddle += "跨块钉子\n\n结尾\n"
try! straddle.write(to: straddleURL, atomically: true, encoding: .utf8)
let struck = LibrarySearch.run(files: [straddleURL], query: "跨块钉子")
eq(struck.count, 1, "压在块边界上的词也要找到")
eq(struck.first?.matches, 1, "跨块那一处只数一次：边界规则不许把它算成两处")
check(struck.first?.excerpts.first?.contains("跨块钉子") == true, "上下文里得是完整的词，不是两半")
check(struck.first?.excerpts.first?.contains("\u{FFFD}") == false, "块边界上不许留下乱码")

// 命中几百次的词：摘录封顶、每块计数封顶，不然一次深搜能把 CPU 吃掉好几秒
let manyURL = bigRoot.appendingPathComponent("很多词.md")
try! ("# 很多\n\n" + String(repeating: "满满的一行中文和 满词 一起\n", count: 400)).write(
    to: manyURL, atomically: true, encoding: .utf8)
let many = LibrarySearch.run(files: [manyURL], query: "满词")
eq(many.first?.excerpts.count, LibrarySearch.excerptsPerFile, "上下文只留几段，不是把整篇重排一遍")
eq(many.first?.matches, LibrarySearch.matchCap, "一份里数到封顶就停：这是深搜的耗时上限")

// 刹车：`stop` 一真就要停，不能把剩下的文件接着读下去
let stopRoot = temp.appendingPathComponent("deep-stop", isDirectory: true)
try! FileManager.default.createDirectory(at: stopRoot, withIntermediateDirectories: true)
let stopURLs = ["甲.md", "乙.md", "丙.md"].map { name -> URL in
    let url = stopRoot.appendingPathComponent(name)
    try! "# 共同的词\n\n正文\n".write(to: url, atomically: true, encoding: .utf8)
    return url
}
eq(LibrarySearch.run(files: stopURLs, query: "共同的词") { true }.count, 0, "一上来就要停，那就一份都不读")
var stops = 0
eq(LibrarySearch.run(files: stopURLs, query: "共同的词") { stops += 1; return stops > 2 }.count, 1,
   "叫到第三次才停：第一份读完，第二份一个字节都不读")

// 深基准：20 份 × ~0.26 MB ≈ 5 MB，词只写在最后一份里（不设阈值，念给改代码的人听）
let deepBench = temp.appendingPathComponent("deep-bench", isDirectory: true)
try! FileManager.default.createDirectory(at: deepBench, withIntermediateDirectories: true)
var deepBytes = 0
for index in 0..<20 {
    let body = "# 深基准 \(index)\n\n" + String(repeating: "正文一段中文给深搜用。\n", count: 12_000)
        + (index == 19 ? "\n只在最后一份里出现的深词\n" : "")
    let url = deepBench.appendingPathComponent("深-\(index).md")
    try! body.write(to: url, atomically: true, encoding: .utf8)
    deepBytes += body.utf8.count
}
let deepFiles = LibraryFiles.inventory(deepBench).markdown
var deepFound: [LibrarySearch.Hit] = []
let deepMs = timed { deepFound = LibrarySearch.run(files: deepFiles, query: "只在最后一份里出现的深词") }
eq(deepFound.count, 1, "5 MB 的库里那个词只在一处")
check(deepMs < 5_000, "深搜一轮要在几秒内回来（本轮 \(String(format: "%.1f", deepMs)) ms）")
print("深搜 \(deepFiles.count) 份 / \(deepBytes / 1024 / 1024) MB：\(String(format: "%.1f", deepMs)) ms（读盘 + 逐块找词，全程不整篇驻留）")

print("\n通过 \(passes) 条，失败 \(failures) 条")
exit(failures == 0 ? 0 : 1)
