import AppKit
import SwiftUI

/// 演示实例的开关。`--demo` 把数据文件和偏好都挪到隔离位置：真实的 data.json、
/// 用户设置、钥匙串、系统通知、全局热键、触发角、自动备份一概不碰。
/// 再配 `--shots <目录>` 就是把界面离屏渲染成 PNG 后退出，窗口一次都不上屏。
enum AppEnv {
    static let demo = CommandLine.arguments.contains("--demo")

    static let defaults: UserDefaults = {
        guard demo else { return .standard }
        return UserDefaults(suiteName: "local.desknote.app.demo") ?? .standard
    }()

    static var dataURL: URL {
        let dir: URL
        if demo {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeskNote-demo", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DeskNote", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }
}

/// 截图里的内容全是编的示例，跟任何人的真实笔记无关
enum DemoData {
    private static let now = Date()

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

        shot(dir, "panel", NoteLayout.panelSize) { PanelView() }
        if let pinned = Store.shared.notes.first(where: { $0.pinnedToDesktop }) {
            shot(dir, "sticky", NoteLayout.stickySize) { StickyNoteView(noteID: pinned.id) }
        }
        shot(dir, "settings", NSSize(width: 400, height: 620)) { SettingsView() }

        settings.section = .all
        settings.sidebarCollapsed = true
        settings.theme = .light
        shot(dir, "board-light", NoteLayout.mainSize) { RootView() }
    }

    private static func shot<V: View>(_ dir: URL, _ name: String, _ size: NSSize,
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

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("ok \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            print("fail \(name): \(error)")
        }
        win.orderOut(nil)
    }
}
