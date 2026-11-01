import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ what: String) {
    if cond { passes += 1 } else { failures += 1; print("✗ \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    if a == b { passes += 1 } else { failures += 1; print("✗ \(what)\n    实得 \(a)\n    期望 \(b)") }
}

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vaulttest-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

// 1 文件名安全化
eq(Vault.slug("买菜、做饭"), "买菜、做饭", "中文标题原样")
eq(Vault.slug("a/b:c*d?e\"f<g>|h"), "abcdefgh", "非法符号去掉")
eq(Vault.slug("第一行\n第二行"), "第一行 第二行", "换行压成空格")
eq(Vault.slug("  两头空格  "), "两头空格", "首尾空白去掉")
eq(Vault.slug(".隐藏"), "隐藏", "开头的点去掉")
eq(Vault.slug("v1.2 发布"), "v1.2 发布", "中间的点留着")
eq(Vault.slug("CON"), "无标题", "Windows 保留名不用")
eq(Vault.slug("con"), "无标题", "保留名不分大小写")
eq(Vault.slug("！！"), "！！", "全角标点算正常字，留着")
eq(Vault.slug("/\\:*"), "无标题", "全是非法符号不产生空文件名")
eq(Vault.slug(""), "无标题", "空标题")
eq(Vault.slug("\u{200B}零宽"), "零宽", "零宽字符去掉")
eq(Vault.slug(String(repeating: "长", count: 100)).count, 24, "按字截断到 24")
eq(Vault.slug("a\u{0}\u{1}b"), "ab", "控制字符去掉")

// 2 同名不覆盖：id 不同但首行一样，短 id 恰好也不会撞
let idA = UUID(), idB = UUID()
let uA = Vault.noteURL(root, title: "开会", id: idA)
let uB = Vault.noteURL(root, title: "开会", id: idB, taken: ["开会-\(Vault.shortID(idB)).md"])
check(uA.lastPathComponent != uB.lastPathComponent, "首行相同的两张便签文件名不同")
check(uB.lastPathComponent.contains(idB.uuidString.lowercased()), "撞名后退回完整 id")
let uC = Vault.noteURL(root, title: "开会", id: idB,
                       taken: ["开会-\(Vault.shortID(idB)).md", uB.lastPathComponent])
check(uC.lastPathComponent.hasSuffix("-2.md"), "完整 id 还撞就加序号")

// 3 便签往返
var note = StickyNote(text: "## 标题\n\n正文 **加粗**\n- [x] 事项", colorIndex: 3,
                      remindAt: Date(timeIntervalSince1970: 1_800_000_000),
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                      updatedAt: Date(timeIntervalSince1970: 1_750_000_000))
note.id = idA
let noteURL = Vault.noteURL(root, title: note.firstLine, id: idA)
try! Vault.writeNote(note, to: noteURL)
let back = Vault.readNote(at: noteURL)
eq(back?.note.text, note.text, "正文原样回来")
eq(back?.note.id, note.id, "id 认得回来")
eq(back?.note.colorIndex, 3, "颜色")
eq(back?.note.remindAt, note.remindAt, "提醒时间")
eq(back?.note.createdAt, note.createdAt, "创建时间")
eq(back?.note.updatedAt, note.updatedAt, "更新时间")
eq(back?.synthesizedID, false, "有 id 的文件不算合成")

// 4 幂等：内容没变，字节也不能变（自身写入抑制全靠这个）
let bytes1 = try! Data(contentsOf: noteURL)
try! Vault.writeNote(note, to: noteURL)
eq(try! Data(contentsOf: noteURL), bytes1, "同样内容写两次字节完全一致")

// 5 用户自己的 frontmatter 一个字都不许动
let foreign = """
---
tags: [工作, 重要]
aliases:
  - 别名一
  - 别名二
publish:
  blog: true
中文键: 值
---
正文内容
"""
try! foreign.write(to: noteURL, atomically: true, encoding: .utf8)
try! Vault.writeNote(note, to: noteURL)
let kept = try! String(contentsOf: noteURL, encoding: .utf8)
check(kept.contains("tags: [工作, 重要]"), "tags 留着")
check(kept.contains("  - 别名一"), "列表型属性留着")
check(kept.contains("publish:\n  blog: true"), "别人的嵌套块留着")
check(kept.contains("中文键: 值"), "中文键留着")
eq(Vault.readNote(at: noteURL)?.note.text, note.text, "混着用户属性也能读回正文")

// 6 陌生 md（完全没有 frontmatter）
let plainURL = root.appendingPathComponent("notes/随手记.md")
try! "只有一段话，没有任何元数据。".write(to: plainURL, atomically: true, encoding: .utf8)
let plain = Vault.readNote(at: plainURL)
eq(plain?.note.text, "只有一段话，没有任何元数据。", "无 frontmatter 时全文当正文")
eq(plain?.synthesizedID, true, "缺 id 的文件标成合成身份")
check(plain?.note.id != nil, "照样给出可用 id")

// 7 CRLF + BOM
let crlf = "\u{FEFF}---\r\ndesknote:\r\n  id: \(idA.uuidString)\r\n  color: 1\r\n---\r\n第一行\r\n第二行\r\n"
let crlfURL = root.appendingPathComponent("notes/crlf.md")
try! crlf.write(to: crlfURL, atomically: true, encoding: .utf8)
let crlfNote = Vault.readNote(at: crlfURL)
eq(crlfNote?.note.text, "第一行\n第二行", "CRLF/BOM 读回来是干净 LF")
eq(crlfNote?.note.id, idA, "CRLF 文件里的 id 也认")
eq(crlfNote?.note.colorIndex, 1, "CRLF 文件里的字段也认")

// 8 frontmatter 没闭合
let broken = root.appendingPathComponent("notes/broken.md")
try! "---\ndesknote:\n  id: 不是uuid\n正文没写完".write(to: broken, atomically: true, encoding: .utf8)
eq(Vault.readNote(at: broken)?.note.text, "---\ndesknote:\n  id: 不是uuid\n正文没写完", "未闭合的块不吞正文")

// 9 项目文件往返
let item1 = DeskItem(id: UUID(), title: "整理季度复盘材料", deadline: Date(timeIntervalSince1970: 1_800_000_000))
var item2 = DeskItem(id: UUID(), title: "回复设计评审意见")
item2.done = true
let item3 = DeskItem(id: UUID(), title: "带 反斜杠 \\ 和 星号 * 的标题")
let projURL = Vault.projectURL(root, category: "工作", project: "本周", id: item1.id)
let lines: [Vault.Line] = [.text("# 本周"), .text(""), .item(item1), .item(item2),
                           .item(item3), .text("> 备注：这条是我在 Obsidian 里加的")]
try! Vault.writeProject(id: item1.id, category: "工作", lines: lines, to: projURL)
/// 文件里只有「完成态 + 标题 + 天 + 块引用」：createdAt 和 deadline 的精确时刻都走 sidecar，
/// 比对也只能按这个口径来——`📅` 后面本来就只到日。
func shape(_ line: Vault.Line) -> String {
    switch line {
    case let .text(text): return "| \(text)"
    case let .item(item):
        return "\(item.done ? "x" : " ")|\(item.title)|"
            + "\(item.deadline.map { Vault.dayOnly.string(from: $0) } ?? "-")|\(item.id.uuidString)"
    }
}
let proj = Vault.readProject(at: projURL)
eq(proj?.lines.map(shape), lines.map(shape), "项目文件往返：事项、散文、空行、完成状态、日期全回来")
eq(proj?.id, item1.id, "项目 id")
eq(proj?.category, "工作", "类别名")
let projBytes1 = try! Data(contentsOf: projURL)
try! Vault.writeProject(id: item1.id, category: "工作", lines: lines, to: projURL)
eq(try! Data(contentsOf: projURL), projBytes1, "项目文件幂等写出")
let raw = try! String(contentsOf: projURL, encoding: .utf8)
check(raw.contains("- [x] 回复设计评审意见 ^"), "完成态写成 [x]")
check(raw.contains("📅"), "日期写成 Obsidian Tasks 认的样子")

// 10 项目文件里用户加的属性
let projForeign = "---\ntags: [看板]\ndesknote:\n  id: \(item1.id.uuidString)\n  category: 工作\n---\n- [ ] 老事项 ^\(UUID().uuidString)\n"
try! projForeign.write(to: projURL, atomically: true, encoding: .utf8)
try! Vault.writeProject(id: item1.id, category: "工作", lines: [.item(item2)], to: projURL)
let projBack = try! String(contentsOf: projURL, encoding: .utf8)
check(projBack.contains("tags: [看板]"), "项目文件里用户的 tags 留着")
eq(Vault.readProject(at: projURL)?.lines.map(shape), [shape(.item(item2))], "项目事项按新内容写")

// 11 冲突文件名在 Windows 上也合法
let conflict = Vault.conflictURL(noteURL)
check(!conflict.lastPathComponent.contains(":"), "冲突文件名不带冒号")
check(conflict.pathExtension == "md", "冲突文件仍是 .md")

// 12 扫描忽略隐藏目录与嵌套过深的文件
try! Vault.writeNote(note, to: root.appendingPathComponent("notes/第二张.md"))
try! Vault.write("x", to: root.appendingPathComponent(".git/keep.md"))
try! Vault.write("x", to: root.appendingPathComponent("工作/.hidden.md"))
try! Vault.write("x", to: root.appendingPathComponent("notes/.DS_Store"))
let notes = Vault.scanNotes(root)
eq(notes.count, 5, "notes/ 下的 md 都扫到")
check(!notes.contains { $0.lastPathComponent.hasPrefix(".") }, "隐藏文件不算便签")
let projects = Vault.scanProjects(root)
eq(projects.count, 1, "类别目录里只认 md，隐藏 md 不算")

// 13 哈希
eq(Vault.hash("abc"), Vault.hash("abc"), "同样内容哈希一致")
check(Vault.hash("abc") != Vault.hash("abd"), "内容变了哈希就变")
eq(Vault.hash(root.appendingPathComponent("不存在.md")), "", "读不到的文件给空哈希")

// 14 正文首尾的空行也是内容，往返一次一个都不能少
var spaced = StickyNote(text: "\n\n开头两行空\n\n中间空一行\n\n结尾两行空\n\n")
spaced.id = UUID()
let spacedURL = Vault.noteURL(root, title: "空行", id: spaced.id)
try! Vault.writeNote(spaced, to: spacedURL)
eq(Vault.readNote(at: spacedURL)?.note.text, spaced.text, "正文首尾的空行原样回来")
let spacedBytes = try! Data(contentsOf: spacedURL)
try! Vault.writeNote(spaced, to: spacedURL)
eq(try! Data(contentsOf: spacedURL), spacedBytes, "含空行的正文写出幂等")

// 15 正文里混进 CRLF 时落盘要先归一成 LF，否则每次往返哈希都变
var mixed = StickyNote(text: "第一行\r\n第二行")
mixed.id = UUID()
let mixedURL = Vault.noteURL(root, title: "换行符", id: mixed.id)
try! Vault.writeNote(mixed, to: mixedURL)
eq(Vault.readNote(at: mixedURL)?.note.text, "第一行\n第二行", "正文里的 \\r 不落盘")

// 16 项目换类别：旧 frontmatter 不许把新类别盖回去
try! Vault.writeProject(id: item1.id, category: "生活", lines: [.item(item2)], to: projURL)
eq(Vault.readProject(at: projURL)?.category, "生活", "换类别写出去就是新类别")

// 17 事项标题里漏了换行不许把一条拆成两条
let multiline = DeskItem(id: UUID(), title: "第一行\n第二行")
let mlURL = Vault.projectURL(root, category: "工作", project: "换行", id: multiline.id)
try! Vault.writeProject(id: multiline.id, category: "工作", lines: [.item(multiline)], to: mlURL)
let ml = Vault.readProject(at: mlURL)
eq(ml?.lines.count, 1, "换行标题只占一行")
// 整块比 DeskItem 会把 createdAt 一起比进去，而那个字段本来就不在文件里，比不出相等的两个 Date()
if case .item(let back)? = ml?.lines.first {
    eq([back.id.uuidString, back.title, "\(back.done)"],
       [multiline.id.uuidString, "第一行 第二行", "false"], "标题压成空格后身份不变")
} else {
    check(false, "标题压成空格后身份不变")
}

// 18 空项目文件往返稳定，不凭空长行
let emptyID = UUID()
let emptyURL = Vault.projectURL(root, category: "工作", project: "空", id: emptyID)
try! Vault.writeProject(id: emptyID, category: "工作", lines: [], to: emptyURL)
let emptyBytes = try! Data(contentsOf: emptyURL)
try! Vault.writeProject(id: emptyID, category: "工作", lines: Vault.readProject(at: emptyURL)?.lines ?? [],
                        to: emptyURL)
eq(try! Data(contentsOf: emptyURL), emptyBytes, "空项目读回来再写出不长字节")

// 19 库页的枚举：整棵树的 .md，notes/ 要在，点开头和 node_modules 不要
let enumRoot = root.appendingPathComponent("enum", isDirectory: true)
try! FileManager.default.createDirectory(at: enumRoot.appendingPathComponent("notes"),
                                         withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: enumRoot.appendingPathComponent(".desknote"),
                                         withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: enumRoot.appendingPathComponent("node_modules/pkg"),
                                         withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: enumRoot.appendingPathComponent("工作/子目录"),
                                         withIntermediateDirectories: true)
for path in ["notes/a.md", "工作/b.md", "工作/子目录/c.md", "readme.txt",
             ".desknote/state.md", "node_modules/pkg/d.md", ".hidden.md"] {
    try! "x".write(to: enumRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
}
// 枚举回来的路径解过软链（/var → /private/var），截前缀也得先标准化，不然会截出半截目录名
let enumPath = enumRoot.standardizedFileURL.path
let found = Vault.markdownFiles(enumRoot)
    .map { $0.standardizedFileURL.path.dropFirst(enumPath.count + 1) }
eq(Set(found), Set(["notes/a.md", "工作/b.md", "工作/子目录/c.md"]), "库页枚举：递归收 .md，躲开工作目录")

// 20 只读文件头：为了拿一个 id 整篇读进来，是「同步把主线程占满」的直接原因
let headRoot = root.appendingPathComponent("head", isDirectory: true)
try! FileManager.default.createDirectory(at: headRoot, withIntermediateDirectories: true)
let bigNote = StickyNote(text: "图片\n\n![内嵌](data:image/png;base64,"
                         + String(repeating: "A", count: 4_000_000) + ")", colorIndex: 0)
let bigURL = headRoot.appendingPathComponent("big.md")
try! Vault.writeNote(bigNote, to: bigURL)
eq(Vault.readFrontmatter(at: bigURL)?.uuid, bigNote.id, "4 MB 正文也只读文件头就认得回 id")
let headBytes = Vault.readHead(of: bigURL, limit: 4096).map { $0.utf8.count } ?? 0
check(headBytes > 0 && headBytes <= 4096, "readHead 真的只读这么多（实得 \(headBytes) 字节）")

let plainHeadURL = headRoot.appendingPathComponent("plain.md")
try! Vault.write("# 没有属性\n", to: plainHeadURL)
check(Vault.readFrontmatter(at: plainHeadURL) == nil, "没有 frontmatter 的文件不硬造一份")

let crlfHeadID = UUID()
let crlfHeadURL = headRoot.appendingPathComponent("crlf.md")
try! "---\ndesknote:\r\n  id: \(crlfHeadID.uuidString)\r\n---\r\n\r\n正文\r\n"
    .write(to: crlfHeadURL, atomically: true, encoding: .utf8)
eq(Vault.readFrontmatter(at: crlfHeadURL)?.uuid, crlfHeadID, "CRLF 写的 frontmatter 也认（normalize 只作用在文件头上）")

// 文件头里等不到收尾栅栏，说明这份的属性长过 64 KB：退回整篇读，别拿半截属性当准
let wideID = UUID()
let wideURL = headRoot.appendingPathComponent("wide.md")
try! Vault.write("---\ndesknote:\n  id: \(wideID.uuidString)\n  blob: "
                 + String(repeating: "b", count: 100_000) + "\n---\n\n正文\n", to: wideURL)
eq(Vault.readFrontmatter(at: wideURL)?.uuid, wideID, "属性长过文件头时退回整篇读")

print("\n通过 \(passes) 条，失败 \(failures) 条")
exit(failures == 0 ? 0 : 1)
