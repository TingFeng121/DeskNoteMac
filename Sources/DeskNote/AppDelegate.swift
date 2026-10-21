import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static private(set) var shared: AppDelegate?

    private var mainWindow: NoteWindowController!
    private var panelWindow: DesktopPanelController?
    private var statusItem: NSStatusItem!
    private let settings = AppSettings.shared
    /// 已经落到系统那边的开关状态。拖一次透明度滑块就发一次 .settingsChanged，
    /// 每次都去注销再注册热键、重挂鼠标监听的话，中间那几下移动全丢了
    private var hotKeyWanted = false
    private var hotCornerInstalled: HotCorner = .off
    /// 触发角攒下来的那张草稿，用来判断「这次是唤回还是新建」
    private var cornerDraftID: UUID?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        setupStatusItem()

        Notifier.setup()
        Notifier.sync(Store.shared)

        mainWindow = NoteWindowController()
        mainWindow.show()
        StickyWindowManager.shared.syncPinned()

        applyDesktopPanel()
        applyGlobalHotKey()
        applyHotCorner(force: true)
        BackupManager.shared.reschedule()
        NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyDesktopPanel()
            // 热键和触发角的对象都挂在主线上，回主线程再动它们
            Task { @MainActor in
                self?.applyGlobalHotKey()
                self?.applyHotCorner()
            }
        }
        // 换显示器 / 插外接屏之后，角落矩形还是按老屏幕算的，重新挂一次
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotCorner(force: true) }
        }
        // 备份定时器只在备份相关设置变化时重挂：不然拖一次透明度就要重建一次
        NotificationCenter.default.addObserver(
            forName: .backupSettingsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in BackupManager.shared.reschedule() }
        }
        NotificationCenter.default.addObserver(
            forName: .storeDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusTitle()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // 防抖里可能还压着最后一次编辑，切走之前先落干净
        Store.shared.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户被弹窗带去「系统设置 → 隐私与安全性 → 辅助功能」勾完回来：
        // 不在这时重挂一次，触发角就得重启 App 才生效
        applyHotCorner(force: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.flush()
    }

    // MARK: - Menu bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = mainMenu.addItem(withTitle: "桌面便签", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "新建便签", action: #selector(newStickyNote), keyEquivalent: "n")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        appMenu.addItem(.separator())
        // 能不能撤由 validateMenuItem 在菜单打开时现查，这里不用自己盯状态
        let undo = appMenu.addItem(
            withTitle: "撤销刚才的删除", action: #selector(undoDelete), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏桌面便签", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出桌面便签", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in appMenu.items {
            switch item.action {
            case #selector(showSettingsWindow), #selector(newStickyNote), #selector(undoDelete):
                item.target = self
            default: item.target = NSApp
            }
        }
        appItem.submenu = appMenu

        // 没有 Edit 菜单的话 ⌘V/⌘C/⌘X 这类标准快捷键根本不会被派发进文本编辑器
        let editItem = mainMenu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu()
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "桌面便签")
        refreshStatusTitle()

        let menu = NSMenu()
        menu.addItem(withTitle: "新建便签…", action: #selector(newStickyNote), keyEquivalent: "")
        menu.addItem(withTitle: "撤销刚才的删除", action: #selector(undoDelete), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示/隐藏便签", action: #selector(toggleMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "桌面组件", action: #selector(toggleDesktopPanel), keyEquivalent: "")
            .state = settings.desktopPanelEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettingsWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func refreshStatusTitle() {
        statusItem.button?.title = " \(Store.shared.openCount)"
    }

    @objc private func toggleDesktopPanel() {
        settings.desktopPanelEnabled.toggle()
    }

    /// 撤销只有一步，能不能点就看有没有快照
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(undoDelete) ? Store.shared.canUndoDelete : true
    }

    @MainActor @objc private func undoDelete() {
        guard Store.shared.undoDelete() else { return }
        // 删掉的便签可能正开在桌面上，恢复回来要重新钉一次
        StickyWindowManager.shared.syncPinned()
    }

    private func applyDesktopPanel() {
        guard settings.desktopPanelEnabled else {
            panelWindow?.hide()
            return
        }
        if panelWindow == nil {
            panelWindow = DesktopPanelController()
        }
        panelWindow?.show()
    }

    /// 热键只在开关真的翻动时注册/注销。关掉却不注销的话，设置里明明写着不开启，
    /// ⌥⌘N 还是会弹便签；注册失败的原因留给设置页显示（多半是这组合键被别的程序占了）。
    @MainActor private func applyGlobalHotKey() {
        guard hotKeyWanted != settings.globalHotKeyEnabled else { return }
        hotKeyWanted = settings.globalHotKeyEnabled
        if hotKeyWanted {
            settings.globalHotKeyError = GlobalHotKeys.shared.enableNewNote()
        } else {
            GlobalHotKeys.shared.disableNewNote()
            settings.globalHotKeyError = nil
        }
    }

    /// force 给启动、App 被激活、屏幕参数变了这三种场合用：角落没变但辅助功能授权
    /// 可能是刚勾上的，得让 watcher 重新读一次授权状态。
    @MainActor private func applyHotCorner(force: Bool = false) {
        guard force || settings.hotCorner != hotCornerInstalled else { return }
        hotCornerInstalled = settings.hotCorner
        settings.hotCornerError = HotCornerWatcher.shared.apply(settings.hotCorner)
    }

    // MARK: - Windows

    @objc func showSettingsWindow() {
        mainWindow.showSettings()
    }

    @MainActor @objc func newStickyNote() {
        StickyWindowManager.shared.open(Store.shared.addNote())
    }

    /// 触发角弹出来的那张贴在那个角上，并且直接抢焦点——甩角落就是为了马上打字
    @MainActor func stickyNote(from corner: HotCorner) {
        // 学系统那张快速备忘录：甩多少次都只有一张草稿，写了字再甩才另起一张。
        // 不然连甩五下就是五张空便签（用户实测反馈）
        if let id = cornerDraftID, let note = Store.shared.note(id), note.isBlank {
            StickyWindowManager.shared.open(id, at: corner)
            return
        }
        let id = Store.shared.addNote()
        cornerDraftID = id
        StickyWindowManager.shared.open(id, at: corner)
    }

    /// 桌面面板点某一行：切到它所在的类别页、滚过去，并把主窗口拉到前面
    @MainActor func reveal(itemID: UUID) {
        guard let located = Store.shared.location(of: itemID) else { return }
        settings.section = .category(located.categoryID)
        Store.shared.revealRequest = itemID
        mainWindow.show()
    }

    @objc func toggleMainWindow() {
        if mainWindow.window.isVisible {
            mainWindow.window.orderOut(nil)
        } else {
            mainWindow.show()
        }
    }

    func hideMainWindow() {
        mainWindow.window.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 桌面组件常驻可见，所以要看主窗口本身而不是 flag
        if !mainWindow.window.isVisible { mainWindow.show() }
        return true
    }
}
