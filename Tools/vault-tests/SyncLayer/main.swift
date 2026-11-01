import Foundation

var failures = 0
var passes = 0
func check(_ cond: Bool, _ what: String) {
    if cond { passes += 1 } else { failures += 1; print("✗ \(what)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    if a == b { passes += 1 } else { failures += 1; print("✗ \(what)\n    实得 \(a)\n    期望 \(b)") }
}

let base = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vaultsync-\(UUID().uuidString)", isDirectory: true)
let fm = FileManager.default
func fresh(_ name: String) -> URL {
    let url = base.appendingPathComponent(name, isDirectory: true)
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
    return VaultSync.canon(url)
}
defer { try? fm.removeItem(at: base) }

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "«读不出»" }
func noteText(_ url: URL) -> String { Vault.readNote(at: url)?.note.text ?? "«不是便签»" }
func items(_ url: URL) -> [DeskItem] {
    Vault.readProject(at: url)?.lines.compactMap { if case let .item(i) = $0 { return i } else { return nil } } ?? []
}

/// 一份「两张便签 + 一个类别两块板」的最小数据
struct Seed {
    var noteA = StickyNote(text: "买菜\n牛奶、鸡蛋", colorIndex: 1)
    var noteB = StickyNote(text: "周会记录")
    var itemA = DeskItem(title: "订下周三的会议室")
    var itemB = DeskItem(title: "写季度总结", deadline: Date(timeIntervalSince1970: 1_800_000_000))
    var projectX = Project(name: "工作")
    var projectY = Project(name: "个人")
    var category = Category(name: "生活")

    init() {
        noteA.id = UUID(); noteB.id = UUID(); projectX.id = UUID(); projectY.id = UUID()
        projectX.items = [itemA, itemB]
        category.projects = [projectX, projectY]
    }

    var data: BoardData {
        var d = BoardData()
        d.notes = [noteA, noteB]
        d.categories = [category]
        return d
    }
}

func reseed(_ root: URL) -> (Seed, BoardData) {
    let seed = Seed()
    VaultSync.migrate(data: seed.data, root: root)
    return (seed, seed.data)
}

// ---------------------------------------------------------------- 1 decide 判定表
let s = VaultSync.FileState(kind: .note, path: "/x.md", diskHash: "D0", appHash: "A0")
eq(VaultSync.decide(before: nil, diskNow: nil, appNow: "A0"), .write, "新建对象：磁盘没文件就写出去")
eq(VaultSync.decide(before: nil, diskNow: "D0", appNow: "A0"), .adopt, "外部建的文件：以磁盘为准")
eq(VaultSync.decide(before: s, diskNow: "D0", appNow: "A0"), .keep, "两边都没动：什么都不做")
eq(VaultSync.decide(before: s, diskNow: "D0", appNow: "A1"), .write, "只有 App 动了：写盘")
eq(VaultSync.decide(before: s, diskNow: "D1", appNow: "A0"), .adopt, "只有磁盘动了：采纳")
eq(VaultSync.decide(before: s, diskNow: "D1", appNow: "A1"), .conflict, "两边都动了：冲突")
eq(VaultSync.decide(before: s, diskNow: nil, appNow: "A0"), .write, "文件消失：补回去，不当成删除")
eq(VaultSync.decide(before: s, diskNow: nil, appNow: "A1"), .write, "文件消失且 App 改过：仍然补回去")
eq(VaultSync.decide(before: s, diskNow: "", appNow: "A0"), .adopt, "空文件和「没文件」是两回事")

// ---------------------------------------------------------------- 2 appHash 只看会进文件的字段
var note = StickyNote(text: "正文", colorIndex: 2)
let h0 = VaultSync.appHash(note)
note.pinnedToDesktop = true
note.collapsed = true
note.expandedHeight = 480
eq(VaultSync.appHash(note), h0, "钉住/折叠/高度不参与比对：本地状态不算改了正文")
note.text = "正文改一个字"
check(VaultSync.appHash(note) != h0, "改正文一定要换哈希")
let cal = Calendar.current
let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
var p = Project(name: "工作"); p.items = [DeskItem(title: "a", deadline: noon)]
let ph0 = VaultSync.appHash(p, category: "生活")
p.items[0].deadline = noon.addingTimeInterval(3600 * 5)
eq(Vault.dayOnly.string(from: noon), Vault.dayOnly.string(from: noon.addingTimeInterval(3600 * 5)),
   "用例本身成立：这两刻还在同一天")
eq(VaultSync.appHash(p, category: "生活"), ph0, "Deadline 只比哪一天：文件里就是天粒度")
p.items[0].done = true
check(VaultSync.appHash(p, category: "生活") != ph0, "勾完成一定要换哈希")
p.items[0].done = false
check(VaultSync.appHash(p, category: "工作") != ph0, "类别换了名也要换哈希")

// ---------------------------------------------------------------- 3 建库：一次写全
let r1 = fresh("migrate")
let seed1 = Seed()
let st1 = VaultSync.migrate(data: seed1.data, root: r1)
eq(st1.files.count, 4, "建库登记四份：两张便签 + 两块板")
check(fm.fileExists(atPath: VaultSync.stateURL(r1).path), "state.json 落在 .desknote 里")
check(fm.fileExists(atPath: Vault.noteURL(r1, title: seed1.noteA.firstLine, id: seed1.noteA.id).path),
      "便签 A 的文件在 notes/ 下")
check(read(Vault.noteURL(r1, title: seed1.noteA.firstLine, id: seed1.noteA.id)).contains("牛奶"),
      "文件里是真的正文")
check(read(Vault.projectURL(r1, category: "生活", project: "工作", id: seed1.projectX.id)).contains("订下周三"),
      "待办板写成 markdown 复选框")
check(!fm.fileExists(atPath: VaultSync.trashDir(r1).path), "没删过东西就不建 trash 目录")
AppEnv.vaultURL = r1
eq(VaultSync.activeRoot(), r1, "有 state.json 才算建过库")
let r1b = fresh("empty-dir")
AppEnv.vaultURL = r1b
check(VaultSync.activeRoot() == nil, "光有目录不算建库：iCloud 会先建空壳")

// ---------------------------------------------------------------- 4 不循环：建库后立刻同步 = 什么都不做
var d1 = seed1.data
let r4 = VaultSync.sync(data: &d1, root: r1)
eq(r4.written, 0, "建库后第一轮：不该再写一遍")
eq(r4.adopted, 0, "建库后第一轮：不该改数据")
eq(r4.changed, false, "没动过就是没动过（自动备份靠这一格）")
eq(r4.problem, nil, "建库后第一轮没有报错")
let bytes1 = read(Vault.noteURL(r1, title: seed1.noteA.firstLine, id: seed1.noteA.id))

// ---------------------------------------------------------------- 5 只改 App：写出去
d1.notes[0].text = "买菜\n改了的一行"
let r5 = VaultSync.sync(data: &d1, root: r1)
eq(r5.written, 1, "改一张便签只写那一份")
eq(r5.adopted, 0, "写盘方向不算采纳")
check(noteText(Vault.noteURL(r1, title: "买菜", id: seed1.noteA.id)).contains("改了的一行"),
      "磁盘那份跟着改了")
eq(read(Vault.noteURL(r1, title: "买菜", id: seed1.noteA.id)), bytes1.replacingOccurrences(of: "牛奶、鸡蛋", with: "改了的一行"),
    "只有正文变了，frontmatter 一个字节没动")
let r5b = VaultSync.sync(data: &d1, root: r1)
eq(r5b.changed, false, "同一轮改动不该连续写两次（自我写盘抑制）")

// ---------------------------------------------------------------- 6 只改磁盘：采纳，且不覆盖本地状态
let urlA = Vault.noteURL(r1, title: "买菜", id: seed1.noteA.id)
var external = d1.notes[0]
external.text = "买菜\n外部编辑器写的"
try! Vault.writeNote(external, to: urlA)
d1.notes[0].pinnedToDesktop = true
d1.notes[0].expandedHeight = 400
let r6 = VaultSync.sync(data: &d1, root: r1)
eq(r6.adopted, 1, "外部改的正文被采纳")
eq(r6.written, 0, "采纳不该再写回磁盘")
eq(d1.notes[0].text, "买菜\n外部编辑器写的", "内存里的正文换成磁盘那份")
eq(d1.notes[0].pinnedToDesktop, true, "采纳不动钉住状态：整块换掉会把便签弹离桌面")
eq(d1.notes[0].expandedHeight, 400, "采纳不动折叠高度")
eq(VaultSync.sync(data: &d1, root: r1).changed, false, "采纳完这一轮就闭环了")

// ---------------------------------------------------------------- 7 两边都改：冲突副本 + 以 App 为准
external = d1.notes[0]
external.text = "买菜\n磁盘这一份的话"
try! Vault.writeNote(external, to: urlA)
d1.notes[0].text = "买菜\nApp 这一份的话"
let r7 = VaultSync.sync(data: &d1, root: r1)
eq(r7.conflicts.count, 1, "两边都动就要留冲突副本")
eq(r7.written, 1, "正文那一份按 App 写出去")
eq(r7.adopted, 0, "冲突时不许悄悄采纳")
eq(d1.notes[0].text, "买菜\nApp 这一份的话", "内存里的以 App 为准")
eq(noteText(urlA), "买菜\nApp 这一份的话", "磁盘上的正文也换成 App 那份")
let dirURLs = Vault.scanNotes(r1)
let conflictFile = dirURLs.first { Vault.isConflict($0) }
check(conflictFile != nil, "同目录里能找到带「冲突」标记的那一份")
eq(noteText(conflictFile!), "买菜\n磁盘这一份的话", "副本里存的正是被覆盖掉的磁盘那份")
// 副本带同一个 id：下一轮不许把它当正文认回来
let r7b = VaultSync.sync(data: &d1, root: r1)
eq(r7b.changed, false, "冲突副本不参与身份识别（否则两份文件来回抢）")
eq(noteText(urlA), "买菜\nApp 这一份的话", "写完一轮之后正文那一份还是 App 那份")

// ---------------------------------------------------------------- 8 改名/挪目录：认得回来，不产生副本
let r8 = fresh("rename")
let (seed8, _) = reseed(r8)
var d8 = seed8.data
_ = VaultSync.sync(data: &d8, root: r8)
let moved = r8.appendingPathComponent("notes").appendingPathComponent("Typora 里改的名.md")
try! fm.moveItem(at: Vault.noteURL(r8, title: seed8.noteA.firstLine, id: seed8.noteA.id), to: moved)
let r8b = VaultSync.sync(data: &d8, root: r8)
eq(r8b.changed, false, "外部改了文件名不算内容改动")
eq(r8b.trashed.isEmpty, true, "改个名不该把老文件扔进回收站")
eq(VaultSync.loadState(r8).files[seed8.noteA.id.uuidString]?.path, moved.path,
   "state 里的路径跟着挪到新名字")
eq(Vault.scanNotes(r8).filter { $0.lastPathComponent == "Typora 里改的名.md" }.count, 1, "新名字的文件还在库里")
// 再改 App 正文：要写到新位置，不是写回老路径
d8.notes[0].text = "买菜\n改名之后又改正文"
_ = VaultSync.sync(data: &d8, root: r8)
eq(noteText(moved), "买菜\n改名之后又改正文", "写的是改名后的那一份")
check(!fm.fileExists(atPath: Vault.noteURL(r8, title: "买菜", id: seed8.noteA.id).path),
      "老路径上没有长出第二份")

// ---------------------------------------------------------------- 9 App 里删掉：文件进 .desknote/trash
let r9 = fresh("trash")
let (seed9, _) = reseed(r9)
var d9 = seed9.data
_ = VaultSync.sync(data: &d9, root: r9)
let urlB = Vault.noteURL(r9, title: seed9.noteB.firstLine, id: seed9.noteB.id)
d9.notes.remove(at: 1)
let r9b = VaultSync.sync(data: &d9, root: r9)
eq(r9b.trashed.count, 1, "删掉的便签有一份进回收站")
check(!fm.fileExists(atPath: urlB.path), "库里那份已经不在了")
check(fm.fileExists(atPath: VaultSync.trashDir(r9).appendingPathComponent(urlB.lastPathComponent).path),
      "文件在 .desknote/trash 里，不是被抹掉")
eq(VaultSync.loadState(r9).files[seed9.noteB.id.uuidString], nil, "state 里不再登记已删除的对象")
eq(VaultSync.sync(data: &d9, root: r9).trashed.count, 0, "同一份不该被收两次")

// ---------------------------------------------------------------- 10 磁盘上被删：补回来，并闭环
let r10 = fresh("vanished")
let (seed10, _) = reseed(r10)
var d10 = seed10.data
_ = VaultSync.sync(data: &d10, root: r10)
let urlC = Vault.noteURL(r10, title: seed10.noteB.firstLine, id: seed10.noteB.id)
try! fm.removeItem(at: urlC)
let r10b = VaultSync.sync(data: &d10, root: r10)
eq(r10b.written, 1, "文件没了就从 App 补一份")
eq(r10b.problem, nil, "补回来不算报错")
check(fm.fileExists(atPath: urlC.path), "补出来的文件回到原位")
eq(noteText(urlC), "周会记录", "补的是原来的正文")
eq(VaultSync.sync(data: &d10, root: r10).changed, false, "补完这一轮闭环，不会每次都写")

// ---------------------------------------------------------------- 11 待办板：外部正文行原样留着
let r11 = fresh("board")
let (seed11, _) = reseed(r11)
var d11 = seed11.data
_ = VaultSync.sync(data: &d11, root: r11)
let boardURL = Vault.projectURL(r11, category: "生活", project: "工作", id: seed11.projectX.id)
var parsed = Vault.readProject(at: boardURL)!
parsed.lines.insert(.text("## 这一段的说明是我在 Obsidian 里加的"), at: 0)
try! Vault.writeProject(id: seed11.projectX.id, category: "生活", lines: parsed.lines, to: boardURL)
let r11b = VaultSync.sync(data: &d11, root: r11)
eq(r11b.adopted, 1, "板上多了一行说明 = 磁盘动了，采纳")
check(read(boardURL).contains("Obsidian 里加的"), "采纳不许把外部写的说明抹掉（内容没变，只是认了基线）")
// 采纳之后再改 App 的事项：写出去时说明行必须还在
d11.categories[0].projects[0].items[0].title = "订下周五的会议室"
_ = VaultSync.sync(data: &d11, root: r11)
check(read(boardURL).contains("Obsidian 里加的"), "写盘时按位置留着外部正文行")
check(read(boardURL).contains("订下周五的会议室"), "事项标题跟着更新")
check(!read(boardURL).contains("订下周三的会议室"), "改过的事项不留旧行")

// ---------------------------------------------------------------- 12 板上勾完成/加日期：采纳到内存
let r12 = fresh("board2")
let (seed12, _) = reseed(r12)
var d12 = seed12.data
_ = VaultSync.sync(data: &d12, root: r12)
let board2 = Vault.projectURL(r12, category: "生活", project: "个人", id: seed12.projectY.id)
try! "x".write(to: board2.appendingPathExtension("bak"), atomically: true, encoding: .utf8)
var p2 = Vault.readProject(at: board2)!.lines
p2 = [.item(DeskItem(title: "外部新加的一条")), Vault.Line.text(""), .item(DeskItem(title: "还有一条"))]
try! Vault.writeProject(id: seed12.projectY.id, category: "生活", lines: p2, to: board2)
let r12b = VaultSync.sync(data: &d12, root: r12)
eq(r12b.adopted, 1, "板上加了两条 = 磁盘动了")
eq(d12.categories[0].projects[1].items.count, 2, "内存里跟着变成两条")
eq(d12.categories[0].projects[1].items[0].title, "外部新加的一条", "顺序也照磁盘")
// 在 Typora 里手打的行没有 id：认不出身份就当新的一条，但不许凭空长出来
var p3 = items(board2)
p3[0].done = true
p3[0].deadline = Date(timeIntervalSince1970: 1_900_000_000)
try! Vault.writeProject(id: seed12.projectY.id, category: "生活", lines: p3.map { Vault.Line.item($0) }, to: board2)
_ = VaultSync.sync(data: &d12, root: r12)
eq(d12.categories[0].projects[1].items[0].done, true, "磁盘上勾了完成，内存跟着勾")
eq(Vault.dayOnly.string(from: d12.categories[0].projects[1].items[0].deadline!),
   Vault.dayOnly.string(from: Date(timeIntervalSince1970: 1_900_000_000)), "日期只到哪天")
eq(VaultSync.sync(data: &d12, root: r12).changed, false, "带日期的行采纳完不该自认为又改了")

// ---------------------------------------------------------------- 13 读不出的文件：报错，但不动内容
let r13 = fresh("corrupt")
let (seed13, _) = reseed(r13)
var d13 = seed13.data
_ = VaultSync.sync(data: &d13, root: r13)
let urlD = Vault.noteURL(r13, title: seed13.noteB.firstLine, id: seed13.noteB.id)
let garbage = Data([0xB1, 0xA8, 0xCA, 0xC2, 0xFF, 0xFE, 0x00, 0x01])
try! garbage.write(to: urlD)
let r13b = VaultSync.sync(data: &d13, root: r13)
check(r13b.problem != nil, "非 UTF-8 的便签文件要报出来")
eq(r13b.adopted, 0, "读不出就不算采纳")
eq(try! Data(contentsOf: urlD), garbage, "读不出的那份一个字都不许覆盖：宁可留着坏文件")
eq(d13.notes[1].text, seed13.noteB.text, "内存里的那张便签没被换掉")

// ---------------------------------------------------------------- 14 同一份文件被复制成两处
let r14 = fresh("dup")
let (seed14, _) = reseed(r14)
var d14 = seed14.data
_ = VaultSync.sync(data: &d14, root: r14)
let src = Vault.noteURL(r14, title: seed14.noteA.firstLine, id: seed14.noteA.id)
let copy = r14.appendingPathComponent("notes").appendingPathComponent("拷一份.md")
try! fm.copyItem(at: src, to: copy)
let r14b = VaultSync.sync(data: &d14, root: r14)
check(r14b.problem != nil, "同一个 id 有两份文件要说出来，不许随机认一份")
eq(r14b.changed, true, "报问题也算动过，横幅得亮")
let r14c = VaultSync.sync(data: &d14, root: r14)
eq(r14c.written, 0, "重复文件不该被反复写盘")
try! fm.removeItem(at: copy)

// ---------------------------------------------------------------- 15 一句话总结
var rep = VaultSync.Report()
eq(VaultSync.words(rep), "", "啥都没做就别说话")
rep.written = 3; rep.adopted = 1; rep.conflicts = ["a.md"]; rep.trashed = ["b.md"]
let words = VaultSync.words(rep)
check(words.contains("已写入 3 份") && words.contains("已采纳 1 份外部改动")
      && words.contains("1 份冲突") && words.contains("trash"), "四个数都要出现在总结里：\(words)")

// ---------------------------------------------------------------- 16 空库与空对象
let r16 = fresh("empty")
var d16 = BoardData()
let r16b = VaultSync.sync(data: &d16, root: r16)
eq(r16b.changed, false, "没有库目录就是空转")
try! fm.createDirectory(at: r16, withIntermediateDirectories: true)
d16 = BoardData()
eq(VaultSync.sync(data: &d16, root: r16).written, 0, "空数据写不出文件")
let blank = StickyNote(text: "")
let blankURL = Vault.noteURL(r16, title: blank.firstLine, id: blank.id)
check(blankURL.lastPathComponent.hasSuffix(".md"), "空正文也要有个合法文件名")

// ---------------------------------------------------------------- 17 没改动的一轮不许重写 state.json
// state.json 就躺在被监听的库里：每轮无条件写一次，等于每轮给自己发一条文件事件，
// 事件再触发下一轮同步。实测这个自循环约 5 秒一圈，主线程整圈占在同步上——界面自然卡。
let r17 = fresh("quiet")
let (seed17, _) = reseed(r17)
var d17 = seed17.data
_ = VaultSync.sync(data: &d17, root: r17)
_ = VaultSync.sync(data: &d17, root: r17)      // 先跑两轮，让登记彻底稳定下来
let state17 = VaultSync.stateURL(r17)
func stateMtime() -> Date {
    (try! fm.attributesOfItem(atPath: state17.path))[.modificationDate] as? Date ?? .distantPast
}
let quietBefore = stateMtime()
eq(VaultSync.sync(data: &d17, root: r17).changed, false, "连着什么都没动的一轮报告是空的")
eq(stateMtime() == quietBefore, true, "没改动就不落盘：不给自己发事件")
d17.notes[0].text += "\n真的改了一行"
_ = VaultSync.sync(data: &d17, root: r17)
check(stateMtime() > quietBefore, "真有改动时还得落盘：不能拿「不写」当省电")

// ---------------------------------------------------------------- 18 事件口径：只忽略库内那两个点目录
let r18 = fresh("bookkeeping")
check(VaultSync.isBookkeeping(r18.appendingPathComponent(".desknote/state.json").path, root: r18),
      "自己写的账不算外部改动")
check(VaultSync.isBookkeeping(r18.appendingPathComponent(".obsidian/workspace.json").path, root: r18),
      "Obsidian 的记账不该惊动同步")
check(!VaultSync.isBookkeeping(r18.appendingPathComponent("notes/a.md").path, root: r18),
      "库里的 .md 照常算事")
check(!VaultSync.isBookkeeping(r18.appendingPathComponent(".desknote-x/state.json").path, root: r18),
      "名字像但不是的别误杀")
check(!VaultSync.isBookkeeping("/tmp/someone-else/.desknote/state.json", root: r18),
      "库外的路径不在这个口径里")

// ---------------------------------------------------------------- 19 stat 闸门：省的是重复读
// 这一组测的是「什么情况下不重读」和「什么时候必须重读」，两条都得钉住：
// 只测省钱，就会把漏检也一起省掉。
let r19 = fresh("stat-gate")
let (seed19, _) = reseed(r19)
var d19 = seed19.data
_ = VaultSync.sync(data: &d19, root: r19)
let gateURL = VaultSync.canon(Vault.noteURL(r19, title: seed19.noteA.firstLine, id: seed19.noteA.id))
let gateMtime = (try! fm.attributesOfItem(atPath: gateURL.path))[.modificationDate] as! Date

// 19a 换字不换字节数、时间戳按原样贴回去：三格 stat 全没动
let swap = read(gateURL).replacingOccurrences(of: "买菜", with: "买米")
check(swap != read(gateURL), "正文真的换了")
eq(Data(swap.utf8).count, Data(read(gateURL).utf8).count, "字节数没变（这一条不成立下面的用例就没意义）")
try! swap.write(to: gateURL, atomically: false, encoding: .utf8)
try! fm.setAttributes([.modificationDate: gateMtime], ofItemAtPath: gateURL.path)
eq(VaultSync.sync(data: &d19, root: r19, diskPaths: []).changed, false,
   "stat 三格都没动的常规一轮：不重读，所以认不出这份改动（这是明码标价的代价）")
eq(VaultSync.sync(data: &d19, root: r19, diskPaths: nil).adopted, 1,
   "漏事件那一轮 diskPaths=nil 跳过闸门：同一份改动必须被认出来")
eq(noteText(gateURL).hasPrefix("买米"), true, "补扫真的把改动收进来了")
eq(VaultSync.sync(data: &d19, root: r19, diskPaths: []).changed, false, "补完这一轮又闭环比，不反复采纳")

// 19b 只有 size 变了也算动：闸门是三个字段一起判的
let onlySize = read(gateURL) + "多一个字符"
try! onlySize.write(to: gateURL, atomically: false, encoding: .utf8)
try! fm.setAttributes([.modificationDate: gateMtime], ofItemAtPath: gateURL.path)
eq(VaultSync.sync(data: &d19, root: r19, diskPaths: []).adopted, 1,
   "字节数变了就要重读，哪怕时间戳被按回去")

// 19c 库里的「别人的 .md」：整库那一趟读一次，之后只看事件报上来的路径
let r19c = fresh("stat-gate-foreign")
let (seed19c, _) = reseed(r19c)
var d19c = seed19c.data
for index in 0..<12 {
    try! Vault.write("# 外部笔记 \(index)\n\n正文",
                     to: r19c.appendingPathComponent("工作/外\(index).md"))
}
_ = VaultSync.sync(data: &d19c, root: r19c)
eq(VaultSync.index.counted, 12 + seed19c.data.notes.count + 2, "整库每个 .md 都记上一格 stat")
let beforeCount = VaultSync.index.counted
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [])
eq(VaultSync.index.counted, beforeCount, "App 动了的那一轮不碰磁盘账：一条事件也没报上来")
// 新增：报一条上一格；被删：报一条掉一格。两次都不重走整库，所以别的文件一格没动
let newOne = r19c.appendingPathComponent("工作/外99.md")
try! Vault.write("# 新建的\n\n正文", to: newOne)
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [newOne.path])
eq(VaultSync.index.counted, beforeCount + 1, "事件报上来一份新文件：账上多一格")
let gone = r19c.appendingPathComponent("工作/外3.md")
try! fm.removeItem(at: gone)
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [gone.path])
eq(VaultSync.index.counted, beforeCount, "报上来的那份磁盘上已经没了：那一格掉下去，不能拿旧 stat 空判")
d19c.notes[0].text += "\n改了 App 这一份"
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [])
eq(VaultSync.index.counted, beforeCount, "自己写出去的那份也登记进账：下一轮不必再读它的文件头")

// 19c2 整个子目录被搬走：账下它的名下每一格都要掉，不然改名会被读成「文件没了」
let movedAway = r19c.appendingPathComponent("工作", isDirectory: true)
let movedTo = r19c.appendingPathComponent("搬到别处", isDirectory: true)
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [movedAway.path])
check(VaultSync.index.entry(at: VaultSync.canon(newOne).path) != nil, "目录里那份在账上")
try! fm.moveItem(at: movedAway, to: movedTo)
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [movedAway.path])
eq(VaultSync.index.counted, seed19c.data.notes.count + 2,
   "老目录整层从账上掉下去，只剩下 notes/ 里那两份和两块板")
_ = VaultSync.sync(data: &d19c, root: r19c, diskPaths: [movedTo.path])
eq(VaultSync.index.counted, 12 + seed19c.data.notes.count + 2,
   "新目录报上来一次，里面那十二份又全认回来")

// 19d 老 state.json（没有 stamp 这一格）必须还能读：读不出来等于整盘基线没了
let r19d = fresh("legacy-state")
let (seed19d, _) = reseed(r19d)
var d19d = seed19d.data
let legacy = VaultSync.loadState(r19d)
var stripped = "{\"version\":\(Vault.formatVersion),\"files\":{"
for (key, st) in legacy.files {
    stripped += "\"\(key)\":{\"kind\":\"\(st.kind.rawValue)\",\"path\":\"\(st.path)\","
        + "\"diskHash\":\"\(st.diskHash)\",\"appHash\":\"\(st.appHash)\"},"
}
stripped += "}}"
try! Data(stripped.utf8).write(to: VaultSync.stateURL(r19d))
let loaded19d = VaultSync.loadState(r19d)
eq(loaded19d.files.count, legacy.files.count, "老格式的 state.json 读得回来，对象一个不丢")
check(loaded19d.files.values.allSatisfy { $0.stamp == nil }, "老格式没 stamp 这一格，读进来是空而不是崩")
eq(VaultSync.sync(data: &d19d, root: r19d, diskPaths: []).changed, false,
   "老基线的第一轮什么也不做：没 stamp 就重读一遍，读完不动内容")
check(VaultSync.loadState(r19d).files.values.contains { $0.stamp != nil }, "重读过之后把 stat 补进账里")

// ---------------------------------------------------------------- 20 闸门到底省了多少（只报数，不设阈值）
let r20 = fresh("gate-cost")
let (seed20, _) = reseed(r20)
var d20 = seed20.data
// 400 份「别人的 .md」：每份 8 KB，正好是 readFrontmatter + hash 都要付的那种体量
for index in 0..<400 {
    let body = "# 外部笔记 \(index)\n\n" + String(repeating: "正文内容填充。", count: 220)
    try! Vault.write(body, to: r20.appendingPathComponent("工作/子\(index % 8)/外\(index).md"))
}
func rounds(_ count: Int, diskPaths: [String]?) -> TimeInterval {
    let start = Date()
    for _ in 0..<count { _ = VaultSync.sync(data: &d20, root: r20, diskPaths: diskPaths) }
    return Date().timeIntervalSince(start) / Double(count)
}
let cold = rounds(1, diskPaths: nil)        // 账是空的：读遍整库
let push = rounds(5, diskPaths: [])         // 打字时每隔 0.4 秒那一轮：一个目录也不走
let forced = rounds(5, diskPaths: nil)      // 等于整改之前的每一轮
print("400 份 .md 的一轮耗时：冷启动 \(String(format: "%.1f", cold * 1000)) ms · "
      + "App 侧那一轮 \(String(format: "%.1f", push * 1000)) ms · 整库重走 \(String(format: "%.1f", forced * 1000)) ms")
check(push < forced, "App 侧那一轮必须远轻于整库重走，不然事件清单这一层是白加的")
eq(VaultSync.index.counted, 404, "整库都在账上：400 份外部的 + 4 份自己的")

// ---------------------------------------------------------------- 21 热的一轮，钱花在哪
// 只报数，不设阈值（和 tree 层那份基准一样）。留着它是为了下次有人说「还是卡」时，
// 能指着一条说得出名字的时间，而不是整轮一个总数。
func timed(_ body: () -> Void) -> TimeInterval {
    let start = Date()
    body()
    return Date().timeIntervalSince(start)
}

// 按用户真实库的形状造一份：两百来份文档，外加一张塞了大 Base64 内联图的便签
let r21 = fresh("round-cost")
var seed21 = Seed()
seed21.noteA = StickyNote(text: "看图\n\n![附件](data:image/png;base64,"
    + String(repeating: "QkhTLmV4YW1wbGUtYnl0ZXM=", count: 34_000) + ")")
VaultSync.migrate(data: seed21.data, root: r21)
for index in 0..<213 {
    try! Vault.write("# 文档 \(index)\n\n" + String(repeating: "内容。", count: 200),
                     to: r21.appendingPathComponent("工作/子\(index % 6)/文\(index).md"))
}
var d21 = seed21.data
_ = VaultSync.sync(data: &d21, root: r21)          // 把账做热

let paths = Vault.markdownFiles(r21)
let enumOnly = timed { _ = Vault.markdownFiles(r21) }
let statOnly = timed { for url in paths { _ = FileStamp(url) } }
let hashAll = timed {
    _ = VaultSync.appHash(seed21.noteA)
    _ = VaultSync.appHash(seed21.noteB)
    _ = VaultSync.appHash(seed21.projectX, category: seed21.category.name)
    _ = VaultSync.appHash(seed21.projectY, category: seed21.category.name)
}
let round = timed { _ = VaultSync.sync(data: &d21, root: r21) }
let pushRound = timed { _ = VaultSync.sync(data: &d21, root: r21, diskPaths: []) }
let readAll = timed { for url in paths { _ = Vault.hash(url) } }
check(Data(seed21.noteA.text.utf8).count > 400_000, "那张便签真的够大：\(Data(seed21.noteA.text.utf8).count) 字节")
print(String(format: "213 份 .md + 一张 %.1f MB 便签：整库重走 %.1f ms（枚举 %.1f · 逐份 stat %.1f · App 侧哈希 %.1f · 全库重读 %.1f）",
              Double(Data(seed21.noteA.text.utf8).count) / 1_048_576,
              round * 1000, enumOnly * 1000, statOnly * 1000, hashAll * 1000, readAll * 1000))
print(String(format: "                                    App 侧那一轮（每次存盘都跑）：%.2f ms", pushRound * 1000))

// ---------------------------------------------------------------- 22 改名：报上新旧一对路径，账上只该挪一格
//   这是「库文档存一次盘」那条路的另一半：`LibraryDocument.save()` 从此只报被点到的那几条，
//   改名走的是 `perform()` 那一对（旧路径 + 新路径）。整库重走要是还被这条路叫起来，
//   上一轮把打字降到 0.6 ms 的账就白记了。
let r22 = fresh("rename-pair")
let (seed22, base22) = reseed(r22)
var d22 = base22
_ = VaultSync.sync(data: &d22, root: r22, diskPaths: nil)                  // 把整库记进账
let oldA = VaultSync.index.idMap[seed22.noteA.id]?.first?.path ?? ""
let otherB = VaultSync.index.idMap[seed22.noteB.id]?.first?.path ?? ""
check(!oldA.isEmpty && !otherB.isEmpty, "账上两张便签都在自己的路径上")
let counted22 = VaultSync.index.counted
let movedA = r22.appendingPathComponent("归档").appendingPathComponent(URL(fileURLWithPath: oldA).lastPathComponent)
try! fm.createDirectory(at: movedA.deletingLastPathComponent(), withIntermediateDirectories: true)
try! fm.moveItem(at: URL(fileURLWithPath: oldA), to: movedA)
let renamed = VaultSync.sync(data: &d22, root: r22, diskPaths: [oldA, movedA.path])
check(VaultSync.index.entry(at: oldA) == nil, "旧路径从账上掉了：留着就是拿一个不存在的文件做判断")
eq(VaultSync.index.entry(at: movedA.path)?.id, seed22.noteA.id, "新路径认回同一个 id，不是当新文件收进来")
eq(VaultSync.index.counted, counted22, "改名只是挪一格，账的总数不该变")
eq(VaultSync.index.idMap[seed22.noteB.id]?.first?.path, otherB, "没被报到的那张便签，一格都没动")
eq(d22.notes.count, 2, "改名不许多出一张便签")
eq(d22.notes.first { $0.id == seed22.noteA.id }?.text, seed22.noteA.text, "改名的这一轮不吞正文")
eq(renamed.adopted, 0, "改名不是「外部改了内容」")

// 只报新路径（改名被合成成一条事件时就这样）：旧格没人清，账上同一 id 两处。
// 记在这儿是因为它现在确实是个洞——由 `problem` 那条「有两份文件」兜住，不靠运气。
let oldC = VaultSync.index.idMap[seed22.noteB.id]?.first?.path ?? ""
let movedC = r22.appendingPathComponent("只报新路径.md")
try! fm.moveItem(at: URL(fileURLWithPath: oldC), to: movedC)
let halfKnown = VaultSync.sync(data: &d22, root: r22, diskPaths: [movedC.path])
check(VaultSync.index.entry(at: oldC) != nil, "只报新路径时旧格还在账上（已知的洞，别当它不存在）")
eq(d22.notes.count, 2, "这个洞也不许多吞一张便签")
check(halfKnown.problem != nil, "同一份 id 落在两处要说出来：\(halfKnown.problem ?? "«没报»")")

// ---------------------------------------------------------------- 23 同一个 URL 对象问两次，指纹要跟着磁盘走
//   `URL.resourceValues(forKeys:)` 把读到的值缓存在那个 NSURL 实例上。库文档把 URL 存在
//   `document.url` 里、每次存盘和刷新都拿同一个对象来问指纹——不绕开缓存，
//   「磁盘又被人改过」这件事就永远看不见，A2 那道闸门会变成一条永远不放行的死路。
let r23 = fresh("stamp-fresh")
let replacedURL = r23.appendingPathComponent("换个文件.md")
try! "短".write(to: replacedURL, atomically: true, encoding: .utf8)
let first23 = FileStamp(replacedURL)!
try! "长得多得多的新内容写进同一个文件".write(to: replacedURL, atomically: true, encoding: .utf8)
let second23 = FileStamp(replacedURL)!
check(second23.size > first23.size, "同一个 URL 对象第二次问要拿到现在的字节数（\(first23.size) → \(second23.size)）")
check(second23 != first23, "字节数变了，指纹就该跟着变")
let inPlaceURL = r23.appendingPathComponent("原地改.md")
try! "一".write(to: inPlaceURL, atomically: false, encoding: .utf8)
let sameInode = FileStamp(inPlaceURL)!
try! "二二二二".write(to: inPlaceURL, atomically: false, encoding: .utf8)
check(!sameInode.contentMatches(FileStamp(inPlaceURL)!), "原地覆写（不换 inode）也要被闸门认出来")
// creation 那一格管的是「换了 inode」：原子存盘先写临时文件再 rename，出生时间必然是新的。
// 反过来，原地覆写根本不换 inode，三格全都能对上——那一种闸门就是看不见，写在这儿是把盲点摊开。
let sneakyURL = r23.appendingPathComponent("贴回时间.md")
try! "AAA".write(to: sneakyURL, atomically: false, encoding: .utf8)
let sneakyStamp = FileStamp(sneakyURL)!
try! "BBB".write(to: sneakyURL, atomically: false, encoding: .utf8)
try? FileManager.default.setAttributes([.modificationDate: sneakyStamp.date], ofItemAtPath: sneakyURL.path)
let sneakyNow = FileStamp(sneakyURL)!
check(sneakyNow == sneakyStamp, "原地覆写 + 贴回 mtime：整份指纹都看不见这一笔（已知盲点，靠整库那一轮兜）")
let atomicURL = r23.appendingPathComponent("原子存盘.md")
try! "AAA".write(to: atomicURL, atomically: false, encoding: .utf8)
let atomicStamp = FileStamp(atomicURL)!
func inode(_ url: URL) -> UInt64 {
    var info = stat()
    guard url.withUnsafeFileSystemRepresentation({ rep in rep != nil && stat(rep, &info) == 0 }) else { return 0 }
    return UInt64(bitPattern: Int64(info.st_ino))
}
let atomicIno = inode(atomicURL)
// 两次写要落在不同的毫秒里：整份指纹的粒度就是整毫秒，贴着写的话出生时间会被压成同一个数
Thread.sleep(forTimeInterval: 0.01)
try! "BBB".write(to: atomicURL, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.modificationDate: atomicStamp.date], ofItemAtPath: atomicURL.path)
let atomicNow = FileStamp(atomicURL)!
check(atomicNow.contentMatches(atomicStamp), "等长 + 贴回 mtime：mtime 和字节数这两格都没动")
check(inode(atomicURL) != atomicIno, "Foundation 的原子存盘确实换了 inode（\(atomicIno) → \(inode(atomicURL))）")
check(atomicNow.created == atomicStamp.created,
      "但出生时间被它照原样贴回了（\(atomicStamp.created) → \(atomicNow.created)）：三格全看不见这一笔")

print("\n同步层：通过 \(passes) 条，失败 \(failures) 条")
exit(failures == 0 ? 0 : 1)
