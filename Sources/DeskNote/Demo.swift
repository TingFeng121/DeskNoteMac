import AppKit
import SwiftUI
import WebKit

/// 演示实例的开关。`--demo` 把数据文件和偏好都挪到隔离位置：真实的 data.json、
/// 用户设置、钥匙串、系统通知、全局热键、触发角、自动备份一概不碰。
/// 再配 `--shots <目录>` 就是把界面离屏渲染成 PNG 后退出，窗口一次都不上屏。
enum AppEnv {
    static let demo = CommandLine.arguments.contains("--demo")

    static let defaults: UserDefaults = {
        guard demo else { return .standard }
        return UserDefaults(suiteName: "local.desknote.app.demo") ?? .standard
    }()

    /// 数据文件与库所在的目录：演示实例在临时目录，真机在 Application Support
    static var supportDir: URL {
        let dir: URL
        if demo {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskNote-demo", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeskNote", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var dataURL: URL { supportDir.appendingPathComponent("data.json") }

    /// Markdown 库的根目录。用户没选过就是支持目录下的 `vault`；演示实例永远只在临时目录里，
    /// 出图跑一百遍也不会碰坏真实笔记。
    static var vaultURL: URL {
        if !demo, let chosen = AppSettings.shared.vaultDirectory, !chosen.isEmpty {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return supportDir.appendingPathComponent("vault", isDirectory: true)
    }
}

/// 截图里的内容全是编的示例，跟任何人的真实笔记无关
enum DemoData {
    static let now = Date()

    private static func ago(_ minutes: Int) -> Date {
        now.addingTimeInterval(-Double(minutes) * 60)
    }

    /// 编辑器示例：层级缩进、待办、行内语法都在这一段里
    static let editorSample = """
    ## Markdown 便签

    正文直接打字，语法符号只在敲的时候显形。

    - [x] 加粗、*斜体*、`行内代码`、~~删除线~~
    - [ ] 按 Tab 往里缩，两格一级
      - 缩进一级
        - 缩进二级
          - 缩进三级
    - 无序列表和待办共用同一套层级
      1. 有序列表也跟着走
      2. 再缩一级也一样

    > 引用块缩进来照样对齐
    """

    static func board() -> BoardData {
        var data = BoardData()
        data.categories = [
            Category(name: "工作", projects: [
                Project(name: "本周", items: [
                    DeskItem(title: "整理季度复盘材料", deadline: now.addingTimeInterval(3600 * 5)),
                    DeskItem(title: "新版图标出三稿"),
                    DeskItem(title: "回复设计评审意见", done: true),
                    DeskItem(title: "约用户访谈", deadline: now.addingTimeInterval(3600 * 30), createdAt: ago(600)),
                ]),
                Project(name: "待排期", items: [
                    DeskItem(title: "补齐官网截图", createdAt: ago(24 * 60)),
                    DeskItem(title: "整理快捷键文档", done: true, createdAt: ago(48 * 60)),
                ]),
            ]),
            Category(name: "生活", projects: [
                Project(name: "默认项目", items: [
                    DeskItem(title: "交水电费", deadline: now.addingTimeInterval(3600 * 40)),
                    DeskItem(title: "买猫粮", createdAt: ago(90)),
                    DeskItem(title: "预约牙科", done: true, createdAt: ago(3 * 24 * 60)),
                ]),
            ]),
        ]
        data.notes = [
            StickyNote(text: editorSample, colorIndex: 2,
                       createdAt: ago(40), updatedAt: now),
            StickyNote(text: """
            # 周末采购

            - [x] 猫粮
            - [ ] 咖啡豆
            - [ ] 黄油

            > 楼下那家 20:00 关门
            """, colorIndex: 0, pinnedToDesktop: true, remindAt: now.addingTimeInterval(3600 * 6),
                       createdAt: ago(120), updatedAt: ago(95)),
            StickyNote(text: """
            ## 备份文件名

            ```text
            2026-10-21-143012.json
            ```

            - 一天一份，默认留 20 份
            - 有改动才上传
            """, colorIndex: 4, createdAt: ago(26 * 60), updatedAt: ago(25 * 60)),
            StickyNote(text: """
            电话本

            1. 水电 12345
            2. 物业 67890
            """, colorIndex: 3, createdAt: ago(4 * 24 * 60), updatedAt: ago(3 * 24 * 60)),
            StickyNote(text: """
            - [ ] 试试新建一个事项
            - [x] 点击时钟图标设置 Deadline
            """, colorIndex: 1, createdAt: ago(8 * 24 * 60), updatedAt: ago(7 * 24 * 60)),
        ]
        return data
    }
}

/// 演示库：把示例便签与待办板写成真的 .md，再补两份「用户在 Typora 里自己写」的外部文档。
/// 表上的「外部改动 / 待落盘 / 冲突」不是画上去的：写完文件把 mtime 拨到指定时刻，
/// 再摆一份扫描基线，状态由真实的比对代码自己算出来。
enum DemoVault {
    private static func ago(_ minutes: Double) -> Date {
        DemoData.now.addingTimeInterval(-minutes * 60)
    }

    /// 每张便签在表上演哪个角色，全靠「文件 mtime / 基线 mtime / 这张便签的 updatedAt」三者的先后。
    /// 下标对应 `DemoData.board()` 里的顺序：样例、周末采购、备份文件名、电话本、试试新建。
    private static let notePlan: [(mtime: Date, baseline: Date?)] = [
        (ago(20), ago(4_320)),        // 冲突：磁盘刚被外部改过，DeskNote 这边也有没落盘的改动
        (ago(30), ago(60)),           // 外部改动：只有磁盘这份动了
        (ago(1_488), nil),            // 已同步
        (ago(4_400), nil),            // 待落盘：DeskNote 里改了，磁盘上还是上一版
        (ago(10_080), nil),           // 已同步
    ]

    /// 写文件 + 摆基线 + 同步扫一遍。每次出图前都要重新调一次：扫完基线就更新成「现在这样」了。
    /// `unreadable` 用来出报错那张：往库里丢一份 Windows 记事本存的 GBK 文本，
    /// UTF-8 读不出来 —— 这是真实会遇到的事，不能只在代码里处理过就当它不存在。
    @MainActor
    static func prepare(store: Store, unreadable: Bool = false) {
        guard AppEnv.demo, let map = seed(store: store) else { return }
        if unreadable {
            let url = AppEnv.vaultURL.appendingPathComponent("会议记录/旧机器拷来的.md")
            try? Data([0xB1, 0xA8, 0xCA, 0xC2, 0xFF, 0xFE, 0x00, 0x01]).write(to: url)
        }
        LibraryModel.shared.prime(baseline: map)
        LibraryModel.shared.rescanSync()
    }

    @MainActor
    private static func seed(store: Store) -> [String: FileStamp]? {
        let root = AppEnv.vaultURL
        try? FileManager.default.removeItem(at: root)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { return nil }

        var map: [String: FileStamp] = [:]
        var taken = Set<String>()

        for (index, note) in store.notes.enumerated() {
            let url = Vault.noteURL(root, title: note.firstLine, id: note.id, taken: taken)
            taken.insert(url.lastPathComponent)
            try? Vault.writeNote(note, to: url)
            let plan = notePlan.indices.contains(index) ? notePlan[index] : (note.updatedAt, nil)
            place(url, mtime: plan.0, baseline: plan.1, into: &map)
        }

        for category in store.data.categories {
            for project in category.projects {
                let url = Vault.projectURL(root, category: category.name, project: project.name,
                                           id: project.id)
                let lines: [Vault.Line] = store.sortedItems(project.items).map { .item($0) }
                try? Vault.writeProject(id: project.id, category: category.name, lines: lines, to: url)
                place(url, mtime: ago(60), baseline: nil, into: &map)
            }
        }

        // 「外部编辑器里写的」：没有 desknote.id，只有自己的 frontmatter，双链指向库里的便签
        let review = """
        ---
        tags: [评审, 设计]
        ---

        # 2026-10-28 设计评审

        结论：图标先按 [[Markdown 便签]] 那套层级走，正文不许出现第二种圆角。

        - 便签的钉住状态要跟着窗口关就取消
        - [[周末采购]] 里那条咖啡豆改到周末再买
        """
        let reviewURL = root.appendingPathComponent("会议记录").appendingPathComponent("2026-10-28 设计评审.md")
        try? Vault.write(review, to: reviewURL)
        place(reviewURL, mtime: ago(90), baseline: ago(200), into: &map)

        let expense = """
        # 报销流程备忘

        1. 发票贴 A4，一张不超过 12 张
        2. 月底前交，逾期走特殊审批

        > 抄自内网 wiki，DeskNote 不动这个文件
        """
        let expenseURL = reviewURL.deletingLastPathComponent().appendingPathComponent("报销流程备忘.md")
        try? Vault.write(expense, to: expenseURL)
        place(expenseURL, mtime: ago(2 * 24 * 60), baseline: nil, into: &map)
        // Render fixtures exercise inline data images and Obsidian attachment syntax without user data.
        let image = NSImage(size: NSSize(width: 420, height: 120))
        image.lockFocus()
        NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.37, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 420, height: 120).fill()
        ("Markdown image · 本地图片" as NSString).draw(at: NSPoint(x: 24, y: 45), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let images = root.appendingPathComponent("附件", isDirectory: true)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try? png.write(to: images.appendingPathComponent("格式示例.png"))
            // 出图用的样例：内嵌 data URI、Obsidian 嵌入、相对路径、尖括号、一行两张、
            // 行内代码里的图片语法、坏 data URI、指向库外的路径 —— 后三种都是会崩或会泄的地方
            var sample = "# 图片兼容\n\n内嵌 Base64 图片：\n\n![内嵌示例](data:image/png;base64,"
            sample += png.base64EncodedString() + ")\n"
            sample += """
            Obsidian 图片嵌入：

            ![[附件/格式示例.png|320]]

            相对路径、尖括号、同一行两张：

            ![相对](附件/格式示例.png) ![尖括号](<附件/格式示例.png>)

            行内代码里不该变成图片：`![不是图片](附件/格式示例.png)`

            坏掉的 data URI 只该给一句短提示，不把编码吐到界面上：

            ![坏图](data:image/png;base64,@@@不是 base64@@@)

            库外的路径不许读：

            ![越界](../../Windows/win.ini)
            """
            let url = root.appendingPathComponent("图片兼容.md")
            try? Vault.write(sample, to: url)
            place(url, mtime: ago(180), baseline: nil, into: &map)
        }
        let rich = #"""
        # 格式兼容

        > [!info] 文档解析
        > 图表和公式在本地渲染，不联网。

        ```mermaid
        flowchart LR
            A[读取文件] --> B[解析 Markdown]
            B --> C[显示正文]
        ```

        $$
        \int_0^1 x^2\,dx = \frac{1}{3}
        $$

        ```swift
        let message = "Hello, Markdown"
        print(message)
        ```

        | 内容 | 状态 |
        | --- | --- |
        | [[2026-10-28 设计评审]] | 支持内部链接 |
        """#
        let richURL = root.appendingPathComponent("格式兼容.md")
        try? Vault.write(rich, to: richURL)
        place(richURL, mtime: ago(180), baseline: nil, into: &map)
        return map
    }

    /// 落一个时刻给文件、把「上一次看到的样子」记进基线。`baseline = nil` 表示那份没动过。
    private static func place(_ url: URL, mtime: Date, baseline: Date?,
                              into map: inout [String: FileStamp]) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs?[.size] as? Int) != nil else { return }
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let stamp = (baseline ?? mtime).timeIntervalSinceReferenceDate
        map[url.path] = FileStamp(modified: stamp, size: size)
    }
}

/// Store ↔ VaultSync 的端到端自检。只在 `--demo`（数据全在临时目录）下认，绝不碰真实笔记：
/// 建库 → 外部改文件 → 采纳 → App 改 → 写盘 → 双向冲突 → 外部删除 → App 删除 → 不循环。
/// 单元层测的是判定表，这一层测的是「接上 Store 之后真的会动盘」。
@MainActor
enum VaultSelfTest {
    static var requested: Bool { AppEnv.demo && CommandLine.arguments.contains("--vault-selftest") }

    static func run() {
        var bad = 0
        func expect(_ cond: Bool, _ what: String) {
            print(cond ? "✓ \(what)" : "✗ \(what)")
            if !cond { bad += 1 }
        }
        let fm = FileManager.default
        let root = AppEnv.vaultURL
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 1 建库：每份便签和每块板都落文件，data.json 退成缓存但不能消失
        let store = Store.shared
        let boards = store.data.categories.reduce(0) { $0 + $1.projects.count }
        let expected = store.notes.count + boards
        let state = VaultSync.migrate(data: store.data, root: root)
        expect(state.files.count == expected, "建库写出 \(expected) 份，登记 \(state.files.count) 份")
        expect(fm.fileExists(atPath: VaultSync.stateURL(root).path), "state.json 落在 .desknote 里")
        expect(fm.fileExists(atPath: AppEnv.dataURL.path), "data.json 还在：它现在是缓存，不是唯一真相")
        expect(VaultSync.activeRoot() == root, "建过库之后 activeRoot 认得出这一份")

        guard let noteID = store.notes.first?.id, let path = state.files[noteID.uuidString]?.path
        else { print("✗ 演示数据里没有便签，自检跑不动"); exit(1) }
        let noteURL = URL(fileURLWithPath: path)

        // 2 外部编辑器改了一份正文：采纳进来，且不动本地状态
        let pinnedBefore = store.note(noteID)?.pinnedToDesktop ?? false
        var external = store.note(noteID)!
        external.text += "\nTypora 里加的一行"
        try? Vault.writeNote(external, to: noteURL)
        var report = store.pullFromVault()
        expect(report?.adopted == 1, "外部改动被采纳（\(report.map { VaultSync.words($0) } ?? "nil")）")
        expect(store.note(noteID)?.text.contains("Typora 里加的一行") == true, "内存里的正文跟着变")
        expect(store.note(noteID)?.pinnedToDesktop == pinnedBefore, "采纳不覆盖钉住状态")

        // 2b 监听那条路走的是事件清单：只报这一条路径也要认得出外部改动。
        // 整库重走（pullFromVault() 不带参数）留给冷启动和「漏事件」，每次存盘那一轮压根不看磁盘账。
        var typed = store.note(noteID)!
        typed.text += "\nTypora 里又加的一行"
        try? Vault.writeNote(typed, to: noteURL)
        report = store.pullFromVault(diskPaths: [noteURL.path])
        expect(report?.adopted == 1, "只报一条路径的那一轮也认得回这份改动"
               + "（\(report.map { VaultSync.words($0) } ?? "nil")）")
        expect(store.note(noteID)?.text.hasSuffix("Typora 里又加的一行") == true, "事件清单真的收进来了")

        // 3 App 里改：下一次存盘就该把文件带走
        store.mutateNote(noteID) { $0.text = "App 写的正文\n\( $0.text)" }
        store.flush()
        expect(Vault.readNote(at: noteURL)?.note.text.contains("App 写的正文") == true,
               "防抖存盘顺带把 .md 写出去了")
        expect((store.vaultReport?.written ?? 0) >= 1, "后台写盘那份报告挂上了：\(store.vaultReport.map(VaultSync.words) ?? "nil")")

        // 4 两边同时改：磁盘那份必须留副本，正文按 App 走
        var again = store.note(noteID)!
        again.text = "磁盘这一份的话"
        try? Vault.writeNote(again, to: noteURL)
        store.mutateNote(noteID) { $0.text = "App 这一份的话" }
        store.flush()
        let conflictCopy = Vault.scanNotes(root).first(where: Vault.isConflict).flatMap(read)
        expect(store.vaultReport?.conflicts.isEmpty == false, "冲突那份登记了")
        expect(conflictCopy?.contains("磁盘这一份的话") == true, "副本里是被覆盖掉的磁盘那份：\(conflictCopy ?? "无")")
        expect(Vault.readNote(at: noteURL)?.note.text == "App 这一份的话", "正文那一份以 App 为准")

        // 5 外部把文件删了：补回来，而不是把便签删掉。
        // 补回来的文件名跟着正文首行走（上面几步把首行改过），所以认 id 不认路径。
        try? fm.removeItem(at: noteURL)
        report = store.pullFromVault()
        expect(Vault.scanNotes(root).contains { Vault.readFrontmatter(at: $0)?.uuid == noteID },
               "外部删掉的文件按 id 补回来了")
        expect(report?.problem == nil, "补回来不算报错")
        expect(store.note(noteID) != nil, "外部删文件不删便签：同步盘抽一下不该白丢内容")

        // 6 App 里删便签：文件进 .desknote/trash，不直接抹掉
        let doomedID = (store.notes.first { $0.id != noteID } ?? store.notes.last)!.id
        let doomedPath = VaultSync.loadState(root).files[doomedID.uuidString]?.path
        store.removeNote(doomedID, keepUndo: false)
        store.flush()
        if let doomedPath {
            let p = URL(fileURLWithPath: doomedPath)
            expect(!fm.fileExists(atPath: p.path), "删掉的便签从库里走了")
            expect(fm.fileExists(atPath: VaultSync.trashDir(root).appendingPathComponent(p.lastPathComponent).path),
                   "它躺在 .desknote/trash 里")
        }

        // 7 不循环：连着两轮什么都没动，报告必须是 nil（自动备份就看这一格）
        store.flush()
        expect(store.pullFromVault() == nil, "同内容连着同步 = 什么都没做")
        store.flush()
        expect(store.vaultReport == nil, "没改动就不留报告：备份不该被自己惊动")

        // 8 事件流：外部编辑器存一次盘，不点任何按钮就该自己采纳进来。
        // 这一段是真 FSEvents，只能整机跑：延迟 0.2 + 防抖 0.5 + 扫描，给它 3 秒。
        let livePath = VaultSync.loadState(root).files[noteID.uuidString]?.path
        if let livePath, fm.fileExists(atPath: livePath) {
            VaultWatcher.shared.restart()
            var viaEvent = store.note(noteID)!
            viaEvent.text = "事件流里改的一行"
            try? Vault.writeNote(viaEvent, to: URL(fileURLWithPath: livePath))
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            VaultWatcher.shared.stop()
            expect(store.note(noteID)?.text == "事件流里改的一行",
                   "FSEvents 自己把外部改动收进来了（实得 \(store.note(noteID)?.text ?? "无")）")
            expect(LibraryModel.shared.notice?.contains("采纳") == true,
                   "库页横幅自己写了话：\(LibraryModel.shared.notice ?? "无")")
        } else {
            expect(false, "自检找不到那张便签现在落在哪个文件，事件流没测成")
        }

        // 9 库内直接编辑也必须贯通 Store，任意 Markdown 不转成便签。
        let document = LibraryDocument.shared
        let plainURL = root.appendingPathComponent("普通文档.md")
        try? Vault.write("---\ntags: [保留]\n---\n\n原文\n", to: plainURL)
        expect(document.open(plainURL, root: root), "库编辑器能打开普通 Markdown")
        document.edited("\n库里编辑的正文\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        expect((try? String(contentsOf: plainURL, encoding: .utf8)) == "---\ntags: [保留]\n---\n\n库里编辑的正文\n", "防抖自动保存保留属性与正文首尾空行")
        document.edited("尚未保存的稿子")
        try? Vault.write("外部编辑器同时写入", to: plainURL)
        expect(document.save(), "库编辑冲突时仍能保存编辑副本")
        expect((try? String(contentsOf: plainURL, encoding: .utf8)) == "外部编辑器同时写入", "库编辑不会覆盖外部同时写入的内容")
        expect(document.url != plainURL && document.url.map(Vault.isConflict) == true, "冲突后编辑器指向保存好的副本")
        if let path = VaultSync.loadState(root).files[noteID.uuidString]?.path {
            let managed = URL(fileURLWithPath: path)
            expect(document.open(managed, root: root), "库编辑器能打开便签文件")
            document.edited("直接在库里编辑便签")
            expect(document.save() && store.note(noteID)?.text == "直接在库里编辑便签", "库内保存同步更新便签")
            let folder = root.appendingPathComponent("多层/深层", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let moved = folder.appendingPathComponent("改名后的便签.md")
            try? fm.moveItem(at: managed, to: moved)
            document.relocated(from: managed, to: moved)
            _ = store.pullFromVault()
            expect(VaultSync.loadState(root).files[noteID.uuidString]?.path == moved.path, "便签移动到深层目录后身份不变")
        }

        // 9b 库文档的两条尾巴：存盘那一轮不许整库重走，存盘/重扫之后也不许再读一整篇。
        //    同步层上一轮修完的是「打字叫起全库」，账还差这里——每 0.6 秒一次的两次全量读。
        let gateURL = root.appendingPathComponent("闸门文档.md")
        try? Vault.write("# 闸门\n\n第一版\n", to: gateURL)
        expect(document.open(gateURL, root: root), "库编辑器能打开刚写出的文档")
        document.edited("# 闸门\n\n落一次盘\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        // 陷阱格：一个库外的、永远不会被事件报上来的路径。整库重走（`index.rebuild`）
        // 会把账清空重记，它就没了；只走被点到的那几条（`index.update`）就动不到它。
        let trap = "/自检陷阱-不存在于任何库.md"
        VaultSync.index.set(trap, stamp: FileStamp(modified: 1, size: 1), id: nil)
        let trapCount = VaultSync.index.counted
        let rereadBefore = document.rereads
        document.edited("# 闸门\n\n再落一次盘\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        expect(VaultSync.index.counted == trapCount && VaultSync.index.entry(at: trap) != nil,
               "库内存盘这一轮没走整库重走（账上 \(VaultSync.index.counted) 格 / 应为 \(trapCount)）")
        expect(document.rereads == rereadBefore,
               "存盘之后没再读一整篇（多读了 \(document.rereads - rereadBefore) 次）")
        document.refresh()
        expect(document.rereads == rereadBefore, "磁盘没动过一次字节，refresh 一个字节都不读")
        do { try Vault.write("# 闸门\n\n外面真的改了一版，字数也不同\n", to: gateURL) }
        catch { expect(false, "自检写外部改动就没写成：\(error)") }
        document.refresh()
        expect(document.rereads == rereadBefore + 1, "stat 一动就要读回来（实得多读 \(document.rereads - rereadBefore) 次）")
        expect(document.text == "# 闸门\n\n外面真的改了一版，字数也不同\n",
               "外部改动进编辑器（实得「\(document.text)」）")
        expect(!document.dirty, "刚读回来的这一份不是未保存的改动")

        // 9c 深搜并进行集：行上只留 32 KB，深处的词要靠人点的那一轮才捞得回来。
        //    Foundation 那一层测的是找词本身；这几条测的是「并进列表」这一段，只有单例能测。
        let model = LibraryModel.shared
        let deepURL = root.appendingPathComponent("深处文档.md")
        try? Vault.write("# 深处\n\n" + String(repeating: "填充的一段中文。\n", count: 4_000)
            + "\n只有深处才有的自检词\n", to: deepURL)
        model.rescanSync()
        // 比标准化路径，不比 `URL`：这一轮的库根在临时目录里，枚举器报回来的是 /private/var，
        // 我们自己拼的那份是 /var——同步层和扫描层内部都按标准化路径记账，这里跟着同一个口径走。
        let sameURL: (URL) -> Bool = { $0.standardizedFileURL.path == deepURL.standardizedFileURL.path }
        expect(model.rows.first(where: { sameURL($0.url) })?.truncated == true,
               "深搜这一轮的样本要真超出近文搜的范围")
        expect(model.rows(in: .all, query: "只有深处才有的自检词").isEmpty,
               "近文搜看不到深处的词：看到了这一轮就没测到深度")
        model.deepSearch(query: "只有深处才有的自检词", in: .all)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        expect(!model.deepSearching, "深搜那一轮自己回来了，没卡在「正在读」")
        expect(model.deepHit(for: deepURL)?.excerpts.first?.contains("只有深处才有的自检词") == true,
               "深处那一段带着上下文捞回来了")
        expect(model.rows(in: .all, query: "只有深处才有的自检词").contains { sameURL($0.url) },
               "深搜命中的那份并进了文件树那一头的行集")
        model.clearDeepSearch()
        expect(model.rows(in: .all, query: "只有深处才有的自检词").isEmpty,
               "清除之后行集回到近文搜的口径，不给列表留着上一句的命中")

        // 9d 大文档的装载与缓存键。两件事都只有单例这一层能验：
        //    点一下文件名不许把主线程钉住（同步读一整篇），而重开/改名不许再解析一遍（靠内容指纹命中）。
        let bigDocURL = root.appendingPathComponent("大文档装载.md")
        let bigBody = "# 大文档\n\n" + String(repeating: "这一行中文用来把整篇撑过同步读限额。\n", count: 70_000)
        try? Vault.write(bigBody, to: bigDocURL)
        expect(bigBody.utf8.count > ReaderCache.synchronousLoadLimit,
               "样本得真超过同步限额（\(bigBody.utf8.count / 1024 / 1024) MB）")
        let asyncBefore = document.asyncLoads
        let rereadBeforeDoc = document.rereads
        expect(document.open(bigDocURL, root: root), "大文档 open 要立刻返回，不等字节")
        expect(document.loading && document.text.isEmpty,
               "装载还在后台：这一会儿既不摆半截正文，也不说它已经读完了")
        expect(document.asyncLoads == asyncBefore + 1, "这一篇确实走了后台那一轮")
        // 磁盘基线没到之前不许键盘写盘：那几毫秒里落下去的是那串空正文，会把整篇顶掉。
        document.edited("装载期间敲的字")
        expect(document.text.isEmpty && !document.dirty, "装载期间的按键被拒了，没把空正文认成未保存的改动")
        _ = document.save()
        expect((try? String(contentsOf: bigDocURL, encoding: .utf8)) == bigBody,
               "装载期间存盘没有覆盖磁盘上那一整篇")
        func waitLoaded(_ limit: TimeInterval = 30) {
            let deadline = Date().addingTimeInterval(limit)
            while document.loading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        waitLoaded()
        expect(!document.loading, "后台那一轮自己收了尾，没把界面留在「正在装载」")
        expect(document.text == bigBody, "整篇字节都回来了（实得 \(document.text.utf8.count / 1024) KB）")
        expect(document.contentHash == ReaderParse.digest(bigBody),
               "内容指纹跟着字节一起算好——阅读层的缓存键就是它，改名重开都认得")
        expect(!document.dirty && document.rereads == rereadBeforeDoc,
               "回来的这一份就是磁盘那一份，不算改动也没多读一遍")
        let bigHash = document.contentHash

        // 小文档照旧同步读：一次 stat 一次读，别把「点开就有」变成「等一下」。
        expect(document.open(gateURL, root: root), "小文档照样打开")
        expect(!document.loading && document.asyncLoads == asyncBefore + 1,
               "两 MB 以下没走后台，一个字节都不用等")
        expect(document.contentHash == ReaderParse.digest(document.text),
               "同步读这一支也算得出同一个指纹")

        expect(document.open(bigDocURL, root: root), "重开那篇大文档")
        waitLoaded()
        expect(document.contentHash == bigHash, "重开同一篇的缓存键一模一样：阅读层那一轮命中，不重解析")
        let bigRevision = document.revision      // 这一格的基准要到这一刻才对：前面每次 open 都换过正文

        // 改名不重解析：正文没动，指纹就不动，task id 只换了个路径。
        let renamedDocURL = root.appendingPathComponent("大文档改名.md")
        try? fm.moveItem(at: bigDocURL, to: renamedDocURL)
        document.relocated(from: bigDocURL, to: renamedDocURL)
        expect(document.contentHash == bigHash && document.revision == bigRevision,
               "改名既没换正文也没换指纹：阅读层不必重来")
        expect(document.text == bigBody && !document.dirty, "改名之后正文一个字都没丢")
        let rereadAfterRename = document.rereads
        document.refresh()
        expect(document.rereads == rereadAfterRename, "改名保留了 stat，重扫这一轮也读不出新东西")
        expect(document.open(renamedDocURL, root: root) && document.text == bigBody,
               "再点一次改名后的那篇照样打得开")

        // 10 读图：出图只能证明「这一次截对了」，这几条断言才管得住下一次改解析的人。
        func images(_ src: String) -> [(alt: String, dest: String, width: Int?)] {
            LibraryReader.parse(src).compactMap { item in
                guard case let .image(alt, dest, width, _) = item.content else { return nil }
                return (alt, dest, width)
            }
        }
        func prose(_ src: String) -> [String] {
            LibraryReader.parse(src).compactMap { item in
                guard case let .markdown(text) = item.content else { return nil }
                return text
            }
        }
        expect(images("![内嵌](data:image/png;base64,AAAA)").count == 1,
               "data URI 当图片处理")
        expect(prose("![内嵌](data:image/png;base64,AAAA)").isEmpty,
               "整行就是一张图：编码不该漏进正文")
        let wiki = images("![[附件/格式示例.png|320]]")
        expect(wiki.count == 1 && wiki[0].dest == "附件/格式示例.png" && wiki[0].width == 320,
               "Obsidian 嵌入认路径和尺寸（实得 \(wiki.map { "\($0.dest)|\($0.width.map(String.init) ?? "无")" }.joined())）")
        let pair = images("![相对](附件/a.png) ![尖括号](<附件/b b.png>)")
        expect(pair.count == 2 && pair[1].dest == "附件/b b.png",
               "一行两张都要，尖括号里的空格留着（实得 \(pair.count) 张）")
        expect(prose("![a](附件/a.png) ![b](附件/b.png)").isEmpty,
               "两张图中间那个空格不攒成一段空正文")
        expect(images("行内代码：`![不是图](附件/a.png)`").isEmpty
                 && prose("行内代码：`![不是图](附件/a.png)`").first?.contains("不是图") == true,
               "行内代码里的图片语法原样留着")
        let nested = images("[![半截语法](附件/a.png)](附件/b.png)")
        expect(nested.count == 1 && nested[0].dest == "附件/a.png",
               "套了一层壳的图片只按里面那张算（实得 \(nested.count) 张）")

        let attachment = root.appendingPathComponent("附件", isDirectory: true)
        try? fm.createDirectory(at: attachment, withIntermediateDirectories: true)
        try? Vault.write("png", to: attachment.appendingPathComponent("格式示例.png"))
        // 文档放在子目录里，「相对文档目录」这条分支才真的被走到；只测根目录那条等于少测一半
        let docFolder = root.appendingPathComponent("工作", isDirectory: true)
        try? fm.createDirectory(at: docFolder, withIntermediateDirectories: true)
        let reader = LibraryReader(text: "", fileURL: docFolder.appendingPathComponent("文档.md"),
                                   rootURL: root, fontSize: 13, onOpen: { _ in })
        expect(reader.safeLocalImageURL("附件/格式示例.png") != nil, "库内相对路径读得到")
        expect(reader.safeLocalImageURL("../附件/格式示例.png") != nil, "从文档目录往上跳回库内也算合法")
        // 跳出库的那一格要用一个「真的存在」的文件：拿不存在的路径测，检查删了也照样过
        let sibling = root.deletingLastPathComponent().appendingPathComponent("库外真文件.png")
        try? Vault.write("png", to: sibling)
        expect(reader.safeLocalImageURL("../库外真文件.png") == nil, "往上跳一级确实跳出库了，不读")
        expect(reader.safeLocalImageURL("/etc/hosts") == nil, "绝对路径不读")
        expect(reader.safeLocalImageURL("附件/不存在的.png") == nil, "不存在的不猜")
        // 软链：库里一个链接指向库外真文件，解完软链必须还在库里
        let link = attachment.appendingPathComponent("偷链.png")
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: sibling)
        expect(reader.safeLocalImageURL("附件/偷链.png") == nil, "借软链绕出库外的也不读")
        try? fm.removeItem(at: link)
        try? fm.removeItem(at: sibling)

        // 11 折叠与侧栏不许骗出第二次解析。这一条得挂一个真的视图：`.task` 只在视图树里才起来。
        //    窗口甩在所有屏幕之外、也不排序，用户看不见，也不占出图的那套流程。
        let countURL = root.appendingPathComponent("计数文档.md")
        try? Vault.write("# 计数\n\n" + String(repeating: "一行正文，用来让解析有点分量。\n", count: 4_000), to: countURL)
        let modeBefore = document.mode
        document.mode = "read"
        expect(document.open(countURL, root: root), "计数这一篇打得开")
        let tree = LibraryTreeState()
        let settings = AppSettings.shared
        let drawerBefore = settings.libraryDrawerCollapsed
        let probeWindow = FloatingWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 780, height: 520),
                                         styleMask: [.titled, .fullSizeContentView],
                                         backing: .buffered, defer: false)
        probeWindow.isReleasedWhenClosed = false
        if let plate = probeWindow.contentView {
            let host = NSHostingView(rootView: LibraryView(query: "", tree: tree))
            host.frame = plate.bounds
            host.autoresizingMask = [.width, .height]
            plate.addSubview(host)
            plate.layoutSubtreeIfNeeded()
            let firstRound = ReaderCache.misses
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            // `parsing` 是会增减的那一格：非零就说明还有一轮在飞，这时候比谁的增量都不算数。
            expect(LibraryReader.parsing == 0, "测量有效：后台那一轮自己回来了")
            let afterFirst = ReaderCache.misses
            expect(afterFirst > firstRound, "挂上视图那一轮确实解析了一次（增量 \(afterFirst - firstRound)）")
            settings.libraryDrawerCollapsed = true
            if let folder = model.treeIndex.entries.first(where: { $0.directory }) { tree.toggle(folder.url) }
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
            expect(LibraryReader.parsing == 0, "折叠这一轮也没有卡在飞的解析里")
            expect(ReaderCache.misses == afterFirst,
                   "收起文件树 + 折叠一个目录没多跑一次解析（多了 \(ReaderCache.misses - afterFirst) 次）")
            settings.libraryDrawerCollapsed = drawerBefore
            // 切走再切回：切走那一次是另一篇的正文，本来就该解析；要证的是「切回来命中缓存」。
            _ = document.open(gateURL, root: root)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let afterSwitch = ReaderCache.misses
            _ = document.open(countURL, root: root)
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
            expect(LibraryReader.parsing == 0, "重开那一轮也回来了")
            expect(ReaderCache.misses == afterSwitch,
                   "重开同一篇命中缓存，一次解析都没多跑（多了 \(ReaderCache.misses - afterSwitch) 次）")
            host.removeFromSuperview()
        } else {
            expect(false, "自检建不出离屏视图，折叠那两条没测成")
        }
        probeWindow.orderOut(nil)
        settings.libraryDrawerCollapsed = drawerBefore
        document.mode = modeBefore

        // 12 富渲染的分流判定。这一段只管「该不该换网页读者」和「资源在不在位」；
        //    网页真画成什么样在第 13 段，那儿问的是页面本身，不靠这里推断。
        let richCases: [(source: String, what: String, rich: Bool)] = [
            ("一段普通正文。\n\n- 一个列表项\n\n| 甲 | 乙 |\n| -- | -- |\n| 1 | 2 |", "普通正文加表格", false),
            ("```swift\nlet x = 1\n```", "原生画得出 ``` 代码块", false),
            ("```mermaidish\nx\n```", "语言名不是 mermaid 的不算", false),
            ("- [ ] 买猫粮 📅 2026-11-02", "任务清单原生已画成方框", false),
            ("价格 $5 和 $10", "钱不是公式", false),
            ("这里没有语法标记", "什么都不命中", false),
            ("正文里提一句 ```mermaid 这四个字\n不算围栏开头", "行中间的三个反引号不算围栏", false),
            ("~~~python\nprint(1)\n~~~", "~~~ 围栏原生不认", true),
            ("```mermaid\ngraph TD; A-->B;\n```", "Mermaid", true),
            ("行内 $E=mc^2$ 在这儿", "行内公式", true),
            ("$$\nT(n) = 2T(n/2) + n\n$$", "块级公式", true),
            ("这里有个脚注[^1]。\n\n[^1]: 说明", "脚注", true),
            ("> [!note] 提醒\n> 正文", "callout", true),
            ("> [!tip]- 可折叠\n> 正文", "可折叠 callout", true),
            ("<div class=\"x\">原始 HTML</div>", "原始 HTML 块", true),
            ("<!-- 注释 -->", "HTML 注释", true)
        ]
        for item in richCases {
            expect(LibraryRichReader.isNeeded(item.source) == item.rich,
                   "分流「\(item.what)」判成\(item.rich ? "网页" : "原生")")
        }
        do {   // 闸门：正文没换就别再扫第二遍。这一条挂在 body 上，漏了就是一帧一趟。
            let sample = String(repeating: "一行没什么标记的正文。\n", count: 2_000)
            let before = LibraryRichReader.scans
            _ = LibraryRichReader.isNeeded(text: sample, revision: 41, path: "/闸.md")
            let afterFirst = LibraryRichReader.scans
            _ = LibraryRichReader.isNeeded(text: sample, revision: 41, path: "/闸.md")
            expect(LibraryRichReader.scans == afterFirst, "同一篇同一版不重扫（多扫 \(LibraryRichReader.scans - afterFirst) 趟）")
            _ = LibraryRichReader.isNeeded(text: sample, revision: 42, path: "/闸.md")
            expect(LibraryRichReader.scans == afterFirst + 1, "换了一版才重扫（增量 \(LibraryRichReader.scans - before - 1)）")
        }
        expect(RendererLocations.current != nil, "富渲染资源在位：\(RendererLocations.current?.path ?? "找不到")")
        if let directory = RendererLocations.current {
            let missing = RendererLocations.requiredFiles.filter {
                !fm.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
            expect(missing.isEmpty, "十一个文件一个不缺（缺 \(missing.joined(separator: "、"))）")
            // 装漏一个文件时判出来的必须是「不用网页读者」——这条是「不白屏」的全部依据：
            // 只要它是 false，`LibraryRichReader.body` 就退回原生读者，压根不会去建那个空壳 WKWebView。
            let stripped = root.appendingPathComponent("残缺渲染器", isDirectory: true)
            try? fm.createDirectory(at: stripped, withIntermediateDirectories: true)
            for name in RendererLocations.requiredFiles.dropLast() {
                let target = stripped.appendingPathComponent(name)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "".write(to: target, atomically: true, encoding: .utf8)
            }
            expect(RendererLocations.isComplete(stripped) == false, "少最后一个文件就判不完整（整个退回原生读者）")
            for name in RendererLocations.requiredFiles {
                let target = stripped.appendingPathComponent(name)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "".write(to: target, atomically: true, encoding: .utf8)
            }
            expect(RendererLocations.isComplete(stripped), "补齐之后判成完整")
            try? fm.removeItem(at: stripped)
            expect(RendererLocations.isComplete(root.appendingPathComponent("压根没有这层", isDirectory: true)) == false,
                   "目录不在位判不完整")
            // 离线靠页面的 CSP 兜住。第 13 段那条「外联没拿到响应」要用这三口子才算数：
            // 哪天 index.html 把 http 放进 img-src 或给 script 开了 'unsafe-eval'，读数是绿的，路却已经不通了。
            if let html = try? String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8) {
                expect(html.contains("default-src 'none'"), "CSP 的 default-src 收到最紧的一档")
                expect(html.contains("connect-src 'none'"), "CSP 不给页面留 fetch/XHR 的口子")
                let script = html.range(of: #"script-src([^;]*)"#, options: [.regularExpression])
                    .map { String(html[$0]).lowercased() } ?? ""
                expect(script.contains("unsafe-eval") == false && script.contains("*") == false,
                       "script-src 没开 'unsafe-eval'（写的是 \(script.trimmingCharacters(in: .whitespacesAndNewlines))）")
                let img = html.range(of: #"img-src([^;]*)"#, options: [.regularExpression])
                    .map { String(html[$0]).lowercased() } ?? ""
                expect(img.isEmpty == false && img.contains("http") == false && img.contains("*") == false,
                       "img-src 没放行 http，也没开通配（写的是 \(img.trimmingCharacters(in: .whitespacesAndNewlines))）")
            } else {
                expect(false, "读不到 index.html，CSP 那四条没测成")
            }
        }
        // 图片解析要和原生读者同口径：先按文档目录找，找不到再按库根找，跳出库外的一律不读。
        let richRoot = root
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "附件/格式示例.png") != nil,
               "文档目录下没有这一张，按库根兜回来")
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "../附件/格式示例.png") != nil,
               "从文档目录往上跳回库内算合法")
        expect(RichReaderImages.url(root: richRoot, note: "", target: "附件/格式示例.png") != nil,
               "note 为空（这篇不在库里）按库根找")
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "/etc/hosts") == nil, "绝对路径不读")
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "https://x/a.png") == nil, "带协议的不读")
        expect(RichReaderImages.url(root: richRoot, note: "../../库外/文档.md", target: "附件/格式示例.png") == nil,
               "note 自己跳出库外的不认路")
        let richEscape = root.deletingLastPathComponent().appendingPathComponent("库外真图.png")
        try? Vault.write("png", to: richEscape)
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "../../库外真图.png") == nil,
               "往上跳两级逃出库的不读")
        let spaced = attachment.appendingPathComponent("有空 格.png")
        try? Vault.write("png", to: spaced)
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "../附件/有空%20格.png") != nil,
               "作者写的 %20 转义按空格解，和原生读者一样")
        let stolen = attachment.appendingPathComponent("偷链.png")
        try? fm.removeItem(at: stolen)
        try? fm.createSymbolicLink(at: stolen, withDestinationURL: richEscape)
        expect(RichReaderImages.url(root: richRoot, note: "工作/文档.md", target: "../附件/偷链.png") == nil,
               "借软链绕出库外的也不读")
        try? fm.removeItem(at: richEscape)
        try? fm.removeItem(at: spaced)
        try? fm.removeItem(at: stolen)

        // 13 端到端：把这一篇真的挂进网页读者，然后向页面要几个数。
        //    CSP 拦没拦住脚本、mermaid 在 WebKit 里要不要 'unsafe-eval'、desknote-image 那
        //    一路真把字节喂回来没有——这些在 Chromium 里试过一遍，但出图的宿主是 WebKit。
        let richDocURL = root.appendingPathComponent("富渲染.md")
        let richImage = attachment.appendingPathComponent("富渲染图.png")
        expect(makeSamplePNG(to: richImage), "自检造出一张真能解开的 PNG")
        try? Vault.write("""
        # 富渲染

        行内公式 $E = mc^2$，块级公式：

        $$
        T(n) = 2T(n/2) + n
        $$

        > [!note] 提醒
        > 这一篇要走网页读者。

        ```mermaid
        graph TD; 甲-->乙;
        ```

        ```swift
        let n = 1
        ```

        | 甲 | 乙 |
        | -- | -- |
        | 1 | 2 |

        一个内链 [[另一个文档]]，一个外链 [官网](https://example.com)。

        这里有个脚注[^1]。

        [^1]: 脚注说明

        ![图](附件/富渲染图.png)

        ![外联](https://example.invalid/a.png)

        <img src=x onerror="window.__xss = 1">
        <script>window.__pwn = 1</script>
        [坏](javascript:alert(1))
        """, to: richDocURL)
        expect(document.open(richDocURL, root: root), "富渲染这一篇打得开")
        expect(LibraryRichReader.isNeeded(text: document.text, revision: document.revision, path: richDocURL.path),
               "这一篇确实被判给网页读者")
        let richModeBefore = document.mode
        document.mode = "read"
        let richDrawn = richCycle()
        expect(richDrawn.mounted, "第 13 段的离屏网页窗口搭起来了")
        expect(richDrawn.drawn, "网页读者真把公式、Mermaid 和图片画完了（没画完，下面几条读数全是白测）")
        document.mode = richModeBefore

        func counted(_ key: String) -> Double { (richReadout?[key] as? Double) ?? -1 }
        func shown(_ key: String) -> String { richReadout?[key].map { "\($0)" } ?? "无读数" }
        expect((richReadout?["bridge"] as? String) == "function", "脚本在 WebKit 里起来了（CSP 没拦住本地脚本）")
        expect(counted("math") >= 2, "行内和块级公式都出了 KaTeX（实得 \(shown("math"))）")
        expect(counted("callout") >= 1, "callout 成卡片（实得 \(shown("callout"))）")
        expect(counted("mermaid") >= 1, "Mermaid 在 WebKit 里画成 SVG，没有 'unsafe-eval'（实得 \(shown("mermaid"))）")
        expect(counted("table") >= 1, "表格画出来了（实得 \(shown("table"))）")
        expect(counted("hljs") >= 1, "代码块带了高亮 class（实得 \(shown("hljs"))）")
        expect(counted("image") >= 1, "desknote-image://local 真把图片字节喂回来了（实得 \(shown("image"))；"
               + "节点 \(shown("imgCount")) 个 · loading=\(shown("imgLoading")) · complete=\(shown("imgComplete")) · "
               + "src=\(shown("imgSrc"))）")
        expect(counted("xss") == 0, "正文里的 onerror 没跑起来（实得 \(shown("xss"))）")
        expect((richReadout?["pwn"] as? String) == "undefined", "正文里的 <script> 压根没执行")
        expect(counted("inlineScript") == 0, "页面里没有残留的内联 script（实得 \(shown("inlineScript"))）")
        expect(counted("link") >= 1, "[[]] 内链接成了可点的那一格（实得 \(shown("link"))）")
        expect(counted("footnote") >= 1, "脚注收到文末的列表里（实得 \(shown("footnote"))）")
        expect(counted("external") == 0, "正文里的外联图片一条也没拿到响应（实得 \(shown("external")) 条：\(shown("externalNames"))）")
        expect(counted("badLink") == 0, "javascript: 那条没变成链接（实得 \(shown("badLink"))）")
        expect(counted("overflow") == 0, "网页读者没有横向溢出（实得 \(shown("overflow"))）")

        // 14 十轮「同一个网页读者换下一篇」，量的是本进程的 phys_footprint。
        //    为什么不是十轮挂上/拆掉：挂拆一轮要新建一份 WKWebView，那是 ~1.5 MB 的固定壳子，
        //    十轮下来涨的全是壳子，跟用户怎么用没关系。真实路径是开着一个读者连着翻十篇——
        //    跨进程搬正文、页面重画、图片字节从 desknote-image 回来，攒下什么才看得见。
        //    网页正文住在 WebContent 那个进程里，不记在本进程的账上；这里量的是 Swift 这一侧留下的。
        //    每一篇都按用户实际的形状写：正文有点分量、两个 Mermaid、两段公式、一张真图。
        //    公式要两格、标题要各不同：`richSettled` 认的是「行内 + 块级都出来了」，
        //    而换文档那一轮必须认标题，否则量的还是上一篇。
        var memoryURLs: [URL] = []
        for n in 1...10 {
            var body = "# 内存轮 \(n)\n\n公式 $a^2 + b^2 = c^2$，再来一段块级的：\n\n$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n\n"
            for block in 0..<2 {
                body += "```mermaid\ngraph TD; 甲\(block)-->乙\(block); 乙\(block)-->丙\(block);\n```\n\n"
            }
            body += String(repeating: "第 \(n) 篇的一行正文，让这一篇有点分量。\n", count: 1_200)
            body += "\n![图](附件/富渲染图.png)\n"
            let url = root.appendingPathComponent("内存轮 \(n).md")
            try? Vault.write(body, to: url)
            memoryURLs.append(url)
        }
        // 网页读者是分流出来的那一支，得先有一篇富文档挂着它，再谈换篇。第 13 篇还在文档上。
        document.mode = "read"
        var earlyRound: UInt64 = 0
        var lastRound: UInt64 = 0
        var switched = 0
        if let mount = richMount(), let web = mount.web {
            for n in 1...10 {
                func cells(_ key: String) -> String { (richReadout?[key] as? Double).map { "\($0)" } ?? "-" }
                expect(document.open(memoryURLs[n - 1], root: root), "第 \(n) 篇内存轮打得开")
                let drawn = richWaitSettled(web, title: "内存轮 \(n)", want: richSelftestSettle)
                switched += drawn ? 1 : 0
                expect(drawn, "第 \(n) 轮：同一个网页读者换到这一篇并画完了"
                       + "（页面标题现在是 \((richReadout?["title"] ?? "无读数"))）"
                       + " · 公式\(cells("math")) 图\(cells("image")) Mermaid\(cells("mermaid"))）")
                // 第一轮的数不当基线：头一次进网页读者要付 WebKit 起进程那笔一次性的钱。
                if n == 2 { earlyRound = physFootprint() }
                if n == 10 { lastRound = physFootprint() }
            }
            richUnmount(mount)
        } else {
            expect(false, "第 14 段的网页读者没挂起来，后面十轮没测")
        }
        document.mode = richModeBefore
        let mb = UInt64(1024 * 1024)
        let growth = lastRound > earlyRound ? lastRound - earlyRound : 0
        print("富渲染十次换篇（同一个网页读者）：第 2 轮 \(earlyRound / mb) MB → 第 10 轮 \(lastRound / mb) MB（增 \(growth / mb) MB）· "
            + "画完 \(switched)/10 轮")
        // 拆完再等一会儿：WKWebView 要等它那一头的 WebContent 真退出才还得掉，那是几秒的事，
        // 不是这里的泄漏。所以量两笔——换篇途中的增，和拆干净之后的尾。
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        let settledRound = physFootprint()
        let tail = settledRound > earlyRound ? settledRound - earlyRound : 0
        print("拆掉读者后静置 4 秒：\(settledRound / mb) MB（比第 2 轮高 \(tail / mb) MB）")
        expect(growth < 20 * mb, "十次换篇在本进程只攒了 \(growth / mb) MB，没把正文一份份留下（阈值 20 MB）")
        expect(tail < 40 * mb, "拆掉之后只剩 \(tail / mb) MB，没把网页攒在本进程里（阈值 40 MB）")

        // 15 单调计数 parseStarted：证明「重开同一篇真的没再解析」（A8，也是 A6 的 L2 真命中）
        //    `parsing` 会增减、被取消后还可能留非零，拿它当标尺会说谎；parseStarted 只增不减。
        //    文档打开那一轮 `.task` 入口 +1；收起侧栏 / 重开同一篇不改变 (path, revision) 这个 task id，
        //    于是 .task 不重跑，增量停在 1，最后一步停在 0。
        let parseDocURL = root.appendingPathComponent("A8 大文档.md")
        try? ("# A8 大文档\n\n" + String(repeating: "一行正文用来撑点分量。\n", count: 1_500)).write(
            to: parseDocURL, atomically: true, encoding: .utf8)
        let parseBefore = LibraryReader.parseStarted
        expect(document.open(parseDocURL, root: root), "A8：大文档打得开")
        document.mode = "read"
        if let mount = richMount() {
            for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let parseAfter = LibraryReader.parseStarted
            expect(LibraryReader.parsing == 0, "A8：测量点一 parsing 应已归零（实得 \(LibraryReader.parsing)）")
            expect(parseAfter - parseBefore == 1, "A8：打开一篇新文档 parseStarted 恰好 +1（实得 \(parseAfter - parseBefore)）")
            // 收起侧栏：不改变这篇的 (path, revision)，.task 不该重跑，增量仍停在 1
            AppSettings.shared.libraryDrawerCollapsed = true
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
            expect(LibraryReader.parsing == 0, "A8：测量点二 parsing 应已归零（实得 \(LibraryReader.parsing)）")
            expect(LibraryReader.parseStarted - parseAfter == 0, "A8：收起侧栏后增量仍停在 1（实得 \(LibraryReader.parseStarted - parseAfter)）")
            // 重开同一篇：(path, revision) 没变，.task 不重跑 ⇒ 增量 0，证明 A6 的 L2 真命中、视图不重解析
            _ = document.open(parseDocURL, root: root)
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
            expect(LibraryReader.parsing == 0, "A8：测量点三 parsing 应已归零（实得 \(LibraryReader.parsing)）")
            expect(LibraryReader.parseStarted - parseAfter == 0, "A8：重开同一篇增量 0（实得 \(LibraryReader.parseStarted - parseAfter)）")
            richUnmount(mount)
        } else {
            expect(false, "A8：库工作区没挂起来，后面几条没测")
        }
        AppSettings.shared.libraryDrawerCollapsed = false

        print(bad == 0 ? "SELFTEST OK" : "SELFTEST FAIL（\(bad) 条）")
        exit(bad == 0 ? 0 : 1)
    }

    private static func read(_ url: URL) -> String? {
        guard let raw = Vault.readNote(at: url)?.note.text else { return nil }
        return raw
    }
}

/// 视图树里那个网页读者。SwiftUI 把 `NSViewRepresentable` 建出来要过一帧，所以调用方得泵一下循环再找。
@MainActor private func firstWebView(in view: NSView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    for sub in view.subviews { if let found = firstWebView(in: sub) { return found } }
    return nil
}

/// 本进程的真实内存占用。`phys_footprint` 而不是 `resident_size`：后者把压缩掉和共享的页也算进来，
/// 十轮开关下来回晃动的全是它，看不出真的攒了什么。
@MainActor private func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    // 头里的 TASK_VM_INFO_COUNT 是个 sizeof 表达式，Swift 不收这种宏，按结构体自己算。
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

/// 一轮网页读者的结果。拆成两格是因为它们是不同的病：脚手架没搭起来（那轮压根没测）
/// 和渲染真没画完（这才轮到断言去说）。合成一格会把前者报成后者。
@MainActor private struct RichRound {
    var mounted = false
    var drawn = false
}

/// 向网页读者要它自己那一块的位图。`takeSnapshot` 是异步的，泵主循环等它回来。
/// 不给 `snapshotWidth`：它默认就按屏幕倍率出像素，跟窗口那张 `bitmapImageRepForCachingDisplay` 对得上。
@MainActor private func richSnapshot(of web: WKWebView) -> NSImage? {
    shotWebImage = nil
    web.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in shotWebImage = image }
    for _ in 0..<60 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if shotWebImage != nil { break }
    }
    return shotWebImage
}

@MainActor private var shotWebImage: NSImage?

/// 把正文里第一张库内图片滚进视口。`loading="lazy"` 的图不滚就不发请求——这不是缺陷，
/// 正是它该有的样子；但自检要量的是「字节真从 desknote-image 那条路回来了」，
/// 而第 14 段那一篇的图压在 1200 行正文底下，所以按用户的方式先滚一下。
@MainActor private func richScrollToImage(_ web: WKWebView) {
    web.evaluateJavaScript("var i = document.querySelector('img.desknote-img'); if (i) i.scrollIntoView();",
                           completionHandler: nil)
}

/// 挂一次网页读者：建离屏窗口 → 等它真画完 → 拆干净。第 13 段用这一趟。
@MainActor private func richCycle() -> RichRound {
    var round = RichRound()
    guard let mount = richMount() else { return round }
    round.mounted = true
    if let web = mount.web {
        round.drawn = richWaitSettled(web, want: richSelftestSettle)
    }
    richUnmount(mount)
    return round
}

/// 把网页读者摆上一个不排序、在所有屏幕之外的窗口。返回的三格都由调用方拿着：
/// 提前撒手等于没拆，那一轮的数就量到别的东西上去了。
@MainActor private func richMount() -> (window: FloatingWindow, host: NSHostingView<LibraryView>, web: WKWebView?)? {
    let window = FloatingWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 820, height: 600),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    guard let plate = window.contentView else {
        window.orderOut(nil)
        return nil
    }
    let host = NSHostingView(rootView: LibraryView(query: "", tree: LibraryTreeState()))
    host.frame = plate.bounds
    host.autoresizingMask = [.width, .height]
    plate.addSubview(host)
    plate.layoutSubtreeIfNeeded()
    richReadout = nil
    richSettled = false
    // SwiftUI 把 NSViewRepresentable 建出来要过一帧，所以得泵几下才找得到那个 WKWebView。
    var web: WKWebView?
    for _ in 0..<10 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        web = firstWebView(in: host)
        if web != nil { break }
    }
    return (window, host, web)
}

/// 拆掉一轮网页读者。最后泵一下：`dismantleNSView` 和 WebKit 交还那份宿主层都是接下来的事，
/// 不泵就采样，采到的是「还没拆完」。
@MainActor private func richUnmount(_ mount: (window: FloatingWindow, host: NSHostingView<LibraryView>, web: WKWebView?)) {
    mount.web?.stopLoading()
    mount.host.removeFromSuperview()
    mount.window.orderOut(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
}

/// 等页面把该画的画完：每 0.25 秒泵一次主循环、滚一下那张 lazy 的图、再问一遍 DOM。
/// 判据由 `want` 给，最多 10 秒——真画不出来也该由断言说，不该由这段无限等。
/// `title` 是「这一轮要的是哪一篇」：同一个网页读者换文档时，它得等页面真换过去。
@MainActor private func richWaitSettled(_ web: WKWebView, title: String? = nil, want: RichSettle) -> Bool {
    richSettled = false
    richReadout = nil
    richWantTitle = title
    richWant = want
    richProbe(web)
    for _ in 0..<40 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        if richSettled { break }
        richScrollToImage(web)
        richProbe(web)
    }
    let settled = richSettled
    richWantTitle = nil
    return settled
}

/// 网页读者自检的读数格。放文件级而不是段里的局部变量：`evaluateJavaScript` 的回调由
/// WebKit 那边异步喊回来，往里写可变的局部变量在并发检查下不干净。
@MainActor private var richReadout: [String: Any]?
@MainActor private var richSettled = false
/// 换了文档时，页面上那一版的标题得真的换成新的才算画完——旧 DOM 还挂在屏幕上，
/// 只数节点的话第一轮就能「通过」，量的却是上一篇。
@MainActor private var richWantTitle: String?

/// 「这一篇画完了没有」的判据。自检那两篇带库内图片，出图用的示例篇没有，所以各条能分开要。
@MainActor private struct RichSettle {
    var math = 0.0
    var mermaid = 0.0
    var callout = 0.0
    var image = false
    /// Mermaid 的节点是逐格淡入的，KaTeX 的字形要等 @font-face 回来。出图要的是「画完了的那一帧」，
    /// 所以再加两条：页面里没有还在跑的动画，字体状态是 loaded。否则截回来一张框子里只坐着
    /// 半截节点、公式空着的图——那种图不能当验收图。
    var quiet = false

    func satisfied(_ dict: [String: Any]) -> Bool {
        func count(_ key: String) -> Double { (dict[key] as? Double) ?? 0 }
        if count("math") < math || count("mermaid") < mermaid || count("callout") < callout { return false }
        if image && count("image") < 1 { return false }
        if !quiet { return true }
        return count("pending") == 0 && (dict["fonts"] as? String) == "loaded"
    }
}

@MainActor private var richWant = RichSettle()

/// 自检那两篇的形状：行内 + 块级两段公式、一张 Mermaid SVG、一张真从 desknote-image 回来的图。
@MainActor private let richSelftestSettle = RichSettle(math: 2, mermaid: 1, image: true)

/// 自检要的那张图必须真能解开：拿几个字符冒充 `.png` 写进库，scheme 那边照样把字节喂回去，
/// 但页面解不出位图，`error` 一响就把 `<img>` 换成了一句实话——那条断言于是永远测不到路。
@MainActor private func makeSamplePNG(to url: URL) -> Bool {
    let image = NSImage(size: NSSize(width: 240, height: 90))
    image.lockFocus()
    NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.37, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 240, height: 90).fill()
    ("DeskNote 富渲染" as NSString).draw(at: NSPoint(x: 18, y: 34), withAttributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white])
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return false }
    do { try png.write(to: url); return true } catch { return false }
}

private let richProbeScript = """
JSON.stringify({
  title: (function () { var h = document.querySelector('h1'); return h ? (h.textContent || '').trim() : ''; })(),
  bridge: typeof window.deskNoteRender,
  math: document.querySelectorAll('.katex').length,
  callout: document.querySelectorAll('.desknote-callout').length,
  mermaid: document.querySelectorAll('.desknote-mermaid svg').length,
  table: document.querySelectorAll('table').length,
  hljs: document.querySelectorAll('pre code.hljs').length,
  image: (function () { var i = document.querySelector('img.desknote-img'); return i && i.naturalWidth > 0 ? 1 : 0; })(),
  imgCount: document.querySelectorAll('img.desknote-img').length,
  imgLoading: (function () { var i = document.querySelector('img.desknote-img'); return i ? String(i.loading) : '-'; })(),
  imgComplete: (function () { var i = document.querySelector('img.desknote-img'); return i ? (i.complete ? 1 : 0) : -1; })(),
  imgSrc: (function () { var i = document.querySelector('img.desknote-img'); return i ? (i.getAttribute('src') || '').slice(0, 90) : '-'; })(),
  badLink: document.querySelectorAll('a[href^="javascript"]').length,
  external: (function () {
    // 被 CSP 拦下的加载在 WebKit 里仍会留一条记账，但那一格永远没有响应：时长 0、字节 0、
    // 没有状态码。要拦的是「真有一次外联拿到了数据」，所以只看这三种信号。
    var bad = 0;
    performance.getEntriesByType('resource').forEach(function (e) {
      if (!/^https?:/.test(e.name)) return;
      if (e.responseEnd > e.startTime || e.encodedBodySize > 0 || (e.responseStatus || 0) > 0) bad++;
    });
    return bad;
  })(),
  externalNames: (function () {
    return performance.getEntriesByType('resource').filter(function (e) {
      return /^https?:/.test(e.name);
    }).map(function (e) {
      return e.initiatorType + ' ' + e.name + ' dur=' + Math.round(e.duration)
        + ' bytes=' + e.encodedBodySize + ' status=' + (e.responseStatus || 0);
    }).join(' | ').slice(0, 220);
  })(),
  footnote: document.querySelectorAll('.footnotes li').length,
  link: document.querySelectorAll('.desknote-internal').length,
  xss: window.__xss ? 1 : 0,
  pwn: typeof window.__pwn,
  inlineScript: document.querySelectorAll('script:not([src])').length,
  pending: document.getAnimations ? document.getAnimations().length : 0,
  fonts: document.fonts ? document.fonts.status : 'loaded',
  overflow: document.documentElement.scrollWidth > window.innerWidth + 1 ? 1 : 0
})
"""

/// 向页面本身要几个数——不是「Swift 这边以为画了」，是 DOM 里真有几个节点。
/// 公式两个、mermaid 出一张 svg、图片字节回来，这三条齐了就置 `richSettled`，让等的那段收手。
/// 换了文档时还要先对上标题：旧 DOM 上那几个节点数一个不差，认数不认篇的话量的全是上一篇。
@MainActor private func richProbe(_ web: WKWebView) {
    web.evaluateJavaScript(richProbeScript) { value, _ in
        guard let text = value as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return }
        richReadout = dict
        if let want = richWantTitle, (dict["title"] as? String) != want { return }
        if richWant.satisfied(dict) { richSettled = true }
    }
}

/// 离屏出图：给每个界面建一个不排序、不上屏的窗口，直接 cacheDisplay 到位图再写 PNG。
/// 用 `--demo --shots <目录>` 触发，README 里的截图就是这么来的。
@MainActor
enum DemoShots {
    static var destination: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--shots"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let dir = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func run(into dir: URL) {
        let settings = AppSettings.shared
        settings.theme = .dark
        settings.sidebarCollapsed = false
        settings.section = .all
        shot(dir, "board", NoteLayout.mainSize) { RootView() }

        settings.section = .notes
        settings.notesGallery = false
        shot(dir, "notes-editor", NoteLayout.mainSize) { RootView() }
        settings.notesGallery = true
        shot(dir, "notes-gallery", NoteLayout.mainSize) { RootView() }
        settings.notesGallery = false

        settings.section = .library
        settings.libraryFilter = .all
        // 建库之前那一屏是新用户真正的第一面，它得有自己的图：prepare 之后文件夹就存在了
        shot(dir, "library-setup", NoteLayout.mainSize) { RootView() }
        DemoVault.prepare(store: Store.shared)
        LibraryDocument.shared.mode = "read"
        if let row = LibraryModel.shared.rows.first(where: { $0.url.lastPathComponent == "2026-10-28 设计评审.md" }) ?? LibraryModel.shared.rows.first {
            _ = LibraryDocument.shared.open(row.url, root: AppEnv.vaultURL)
        }
        shot(dir, "library", NoteLayout.mainSize, parse: 3) { RootView() }
        LibraryDocument.shared.mode = "edit"
        shot(dir, "library-editor", NoteLayout.mainSize) { RootView() }
        LibraryDocument.shared.mode = "split"
        shot(dir, "library-split", NSSize(width: 1100, height: 700), parse: 3) { RootView() }
        shot(dir, "library-compact", NoteLayout.mainMinSize, parse: 3) { RootView() }
        LibraryDocument.shared.mode = "read"

        let tree = LibraryTreeState()
        tree.update(index: LibraryModel.shared.treeIndex, matchingPaths: nil, fileCount: LibraryModel.shared.rows.count)
        if let folder = LibraryModel.shared.treeIndex.entries.first(where: { $0.directory && $0.title == "会议记录" }) {
            tree.toggle(folder.url)
            shot(dir, "library-folded", NoteLayout.mainSize, parse: 3) {
                LibraryView(query: "", tree: tree)
                    .environment(\.noteFontSize, settings.fontSize)
                    .background(Color.panelDark)
            }
        }
        // 这两张是图片与高级语法的验收图：大 Base64 那份解码要时间，等不到就是白截
        for (filename, shotName, height) in [("图片兼容.md", "library-images", 1120.0),
                                             ("格式兼容.md", "library-rich", 850.0)] {
            if let row = LibraryModel.shared.rows.first(where: { $0.url.lastPathComponent == filename }) {
                _ = LibraryDocument.shared.open(row.url, root: AppEnv.vaultURL)
                shot(dir, shotName, NSSize(width: 1000, height: height), parse: 10) { RootView() }
            }
        }
        // 窄分屏是图片最容易撑破的一种窗口：树占掉一半，正文只剩两三百 pt
        LibraryDocument.shared.mode = "split"
        if let row = LibraryModel.shared.rows.first(where: { $0.url.lastPathComponent == "图片兼容.md" }) {
            _ = LibraryDocument.shared.open(row.url, root: AppEnv.vaultURL)
            shot(dir, "library-images-narrow", NSSize(width: 620, height: 620), parse: 10) { RootView() }
        }
        LibraryDocument.shared.mode = "read"
        if let row = LibraryModel.shared.rows.first(where: { $0.url.lastPathComponent == "2026-10-28 设计评审.md" }) {
            _ = LibraryDocument.shared.open(row.url, root: AppEnv.vaultURL)
        }

        shot(dir, "panel", NoteLayout.panelSize) { PanelView() }
        if let pinned = Store.shared.notes.first(where: { $0.pinnedToDesktop }) {
            shot(dir, "sticky", NoteLayout.stickySize) { StickyNoteView(noteID: pinned.id) }
        }
        shot(dir, "settings", NSSize(width: 400, height: 620)) { SettingsView() }

        settings.section = .all
        settings.sidebarCollapsed = true
        settings.theme = .light
        shot(dir, "board-light", NoteLayout.mainSize) { RootView() }

        settings.section = .library
        settings.sidebarCollapsed = false
        DemoVault.prepare(store: Store.shared)
        shot(dir, "library-light", NoteLayout.mainSize, parse: 3) { RootView() }

        // 收起文件树之后的样子。这一格以前是「写了没人读」的死设置，两张图一模一样，
        // 等于这张图什么都没证明；现在它真的驱动 LibraryView 的树。
        settings.libraryDrawerCollapsed = true
        shot(dir, "library-wide", NoteLayout.mainSize, parse: 3) { RootView() }
        settings.libraryDrawerCollapsed = false

        // 报错那条横幅只有在真有文件读不出来时才存在，所以它得有一张自己的图
        DemoVault.prepare(store: Store.shared, unreadable: true)
        shot(dir, "library-error", NoteLayout.mainSize, parse: 3) { RootView() }
        DemoVault.prepare(store: Store.shared)
    }

    private static func shot<V: View>(_ dir: URL, _ name: String, _ size: NSSize,
                                      parse: TimeInterval = 0,
                                      @ViewBuilder _ root: () -> V) {
        // 空转一小会儿：设置页的「Deadline 通知」状态是异步读的，不等它就得一句「检查中…」
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 原点甩到所有屏幕之外：哪怕哪天误上了屏，用户也看不见
        let win = FloatingWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(
            named: AppSettings.shared.theme == .dark ? .darkAqua : .aqua)
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(button)?.isHidden = true
        }
        guard let content = win.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        let host = NSHostingView(rootView: root())
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        win.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()

        // 阅读器的解析在后台任务里：不等它回来就 cacheDisplay，截到的永远是「正在读取文档…」，
        // 那张图不能当验收图。先让 `.task` 起来，再等计数器归零，最多等 `parse` 秒。
        if parse > 0 {
            let deadline = Date().addingTimeInterval(parse)
            // 先给 `.task` 一点时间起来，否则计数还是 0，等于没等
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if LibraryReader.parsing == 0 { break }
            }
            host.layoutSubtreeIfNeeded()
        }

        // 这一屏如果是网页读者，`cacheDisplay` 只会给它留下一个同尺寸的洞：那块的画面住在
        // WebContent 进程里，不走视图的 draw 路径。所以等它画完、单独向它要一张，再贴回原位。
        // 等不到就明说并放弃这张——一张空正文的图混进 README，比少一张图糟得多。
        var webImage: NSImage?
        var webRect = NSRect.zero
        if let web = firstWebView(in: content), web.bounds.width > 1, web.bounds.height > 1 {
            let drawn = richWaitSettled(web, want: RichSettle(math: 1, mermaid: 1, callout: 1, quiet: true))
            // 两种失败分开报：没答话是桥没起来，答了没画完是渲染慢——报错了方向就找错了地方。
            guard richReadout != nil else {
                print("fail \(name): 网页读者没答话（脚本没起来？），这张不能当验收图")
                win.orderOut(nil)
                return
            }
            guard drawn, let snapshot = richSnapshot(of: web) else {
                print("fail \(name): 网页读者没画完（还在跑的动画 \(richReadout?["pending"] ?? -1) 条 · "
                    + "字体 \((richReadout?["fonts"] as? String) ?? "无读数")），这张不能当验收图")
                win.orderOut(nil)
                return
            }
            webImage = snapshot
            webRect = web.convert(web.bounds, to: content)
        }

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        var printable = rep
        if let webImage {
            // 两边都按点坐标交给 NSImage 对齐 DPI：直接往 rep 的图形上下文里画要自己算分辨率，容易错一倍。
            let base = NSImage(size: content.bounds.size)
            base.addRepresentation(rep)
            let merged = NSImage(size: content.bounds.size)
            merged.lockFocus()
            base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size), operation: .copy, fraction: 1)
            webImage.draw(in: webRect, from: NSRect(origin: .zero, size: webImage.size), operation: .copy, fraction: 1)
            merged.unlockFocus()
            if let composed = merged.representations.first as? NSBitmapImageRep { printable = composed }
        }
        guard let png = printable.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("ok \(name).png \(printable.pixelsWide)x\(printable.pixelsHigh)"
                  + (webImage == nil ? "" : " · 含网页读者"))
        } catch {
            print("fail \(name): \(error)")
        }
        win.orderOut(nil)
    }
}
