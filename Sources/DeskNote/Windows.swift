import AppKit
import SwiftUI

/// Rounded, title-bar-free window that can still become key (for text input).
final class FloatingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// AppKit 的窗口位置记忆走的是 `UserDefaults.standard`，演示实例一旦挂上 autosave，
/// 就会把用户自己摆好的窗口位置覆盖掉——所以 demo 下不挂，直接摆到屏幕中间。
func setWindowFrameAutosave(_ window: NSWindow, _ name: String) {
    guard AppEnv.demo else { window.setFrameAutosaveName(name); return }
    window.center()
}

private func makeFloatingWindow(size: NSSize, autosave: String, resizable: Bool = false,
                                trafficLights: Bool = false) -> FloatingWindow {
    var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    if resizable { mask.insert(.resizable) }
    let win = FloatingWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: mask,
        backing: .buffered, defer: false)
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    if trafficLights {
        // 绿键固定做「缩放」而不是进全屏空间：这窗口是半透明圆角面板，全屏了背景一片糊
        win.collectionBehavior = [.fullScreenNone]
        // 关掉只收不销毁（见 windowShouldClose），但真被 close 过时也不能 release，
        // 控制器里的 window 是 let，release 之后再 show 就是访问已回收的对象
        win.isReleasedWhenClosed = false
    } else {
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
    }
    win.isMovableByWindowBackground = true
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = true
    setWindowFrameAutosave(win, autosave)
    win.contentView?.wantsLayer = true
    win.contentView?.layer?.cornerRadius = 14
    win.contentView?.layer?.masksToBounds = true
    return win
}

/// autosave 可能记住一个比内容最小值还小的尺寸（默认值改过、或从别的机器同步过来）。
/// 左上角不动，只把窗口撑回最小值，否则底部那一行会被挤出窗口。
private func enforceContentMinSize(_ window: NSWindow, _ min: NSSize) {
    let frame = window.frame
    let content = window.contentRect(forFrameRect: frame).size
    guard content.width < min.width || content.height < min.height else { return }
    let grown = NSSize(width: max(content.width, min.width), height: max(content.height, min.height))
    var newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: grown))
    newFrame.origin = NSPoint(x: frame.minX, y: frame.maxY - newFrame.height)
    window.setFrame(newFrame, display: false)
}

/// 透明度每次都跟（那就是实时预览）；外观只在主题真的换了时才动。
/// 给窗口换 appearance 会让整棵视图树重算，拖一次不透明度滑块不该附带十几次全树重绘。
func applyNoteWindowTheme(_ window: NSWindow) {
    window.alphaValue = AppSettings.shared.opacity
    let want: NSAppearance.Name = AppSettings.shared.theme == .dark ? .darkAqua : .aqua
    guard window.appearance?.name != want else { return }
    window.appearance = NSAppearance(named: want)
}

/// 只有顶部标题条可以拖着窗口走，其余区域要让给列表里的拖拽排序。
final class NoteHostingView: NSHostingView<RootView> {
    private static let dragStrip: CGFloat = 54

    override var mouseDownCanMoveWindow: Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let distanceFromTop = isFlipped ? point.y : bounds.height - point.y
        return distanceFromTop < Self.dragStrip
    }
}

final class NoteWindowController: NSObject, NSWindowDelegate {
    let window: FloatingWindow

    override init() {
        window = makeFloatingWindow(size: NoteLayout.mainSize, autosave: "NoteMainWindow",
                                    resizable: true, trafficLights: true)
        super.init()
        window.delegate = self
        // contentMinSize 管的是内容区，用户拖边时 AppKit 拦的是 frame，两个都得设，
        // 否则能拖到比内容最小值还小，底部那一行会被挤到窗口外面去。
        window.contentMinSize = NoteLayout.mainMinSize
        window.minSize = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: NoteLayout.mainMinSize)).size
        widenForThreeColumnsOnce()
        enforceMinSize()
        let host = NoteHostingView(rootView: RootView())
        window.contentView?.addSubview(host)
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        applyNoteWindowTheme(window)
        NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            applyNoteWindowTheme(self.window)
        }
    }

    /// 红键的语义和 ⌘W、菜单栏「显示/隐藏便签」保持一致：收起来等唤回，不是销毁窗口，
    /// 也不是退出程序——退出走菜单栏或 ⌘Q。返回 false 让 AppKit 别再自己 close。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        return false
    }

    /// autosave 可能记住旧版 460 宽的窗口，三栏放不下；左上角不动，只把它撑到最小尺寸。
    private func enforceMinSize() {
        enforceContentMinSize(window, NoteLayout.mainMinSize)
    }

    /// 旧版本窗口根本拖不动边，autosave 里存的一定是那个 460 宽的默认值。升到三栏布局时撑开一次
    /// 默认宽度；只此一次，之后用户自己拖出来的尺寸照旧全部记住。
    private func widenForThreeColumnsOnce() {
        let key = "mainWindowWidenedForThreeColumns"
        guard !AppEnv.defaults.bool(forKey: key) else { return }
        AppEnv.defaults.set(true, forKey: key)
        guard window.frame.width < NoteLayout.mainSize.width else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.width = NoteLayout.mainSize.width
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: false)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private lazy var settingsWindow: SettingsWindowController = SettingsWindowController()

    func showSettings() {
        settingsWindow.showWindow()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var themeObserver: NSObjectProtocol?

    func showWindow() {
        if window == nil {
            // 可拖边 + 黄绿键：设置页内容一多，340x300 的固定窗只能靠滚，
            // 而且只有一个红键的窗口在 Mac 上看着像半成品
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "便签设置"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.contentMinSize = NSSize(width: 320, height: 260)
            win.isReleasedWhenClosed = false
            setWindowFrameAutosave(win, "NoteSettingsWindow")
            // autosave 里没有才居中，否则每次打开都跑回屏幕中间，用户摆的位置白记了
            if !win.setFrameUsingName("NoteSettingsWindow") { win.center() }
            window = win
            applyTheme(to: win)
            themeObserver = NotificationCenter.default.addObserver(
                forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.applyTheme(to: window)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// 外观跟主题，透明度不跟：这是张填表的窗，压成半透明只会看不清输入框。
    /// 走 NSWindow.appearance 而不是 SwiftUI 的 preferredColorScheme——后者和
    /// `.frame(maxWidth/maxHeight: .infinity)` 链在一起会让 SwiftUI 递归爆栈。
    private func applyTheme(to window: NSWindow) {
        let want: NSAppearance.Name = AppSettings.shared.theme == .dark ? .darkAqua : .aqua
        guard window.appearance?.name != want else { return }
        window.appearance = NSAppearance(named: want)
    }
}

/// Pinned to the desktop layer: stays below normal windows, above the wallpaper.
final class DesktopPanelController {
    let window: FloatingWindow

    init() {
        window = makeFloatingWindow(size: NoteLayout.panelSize, autosave: "NoteDesktopPanel",
                                    resizable: true)
        // 和主窗口一样：contentMinSize 管内容区，minSize 管 AppKit 拦拖边时的 frame，只设一个能拖穿
        window.contentMinSize = NoteLayout.panelMinSize
        window.minSize = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: NoteLayout.panelMinSize)).size
        enforceContentMinSize(window, NoteLayout.panelMinSize)
        window.level = NoteLayout.desktopLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: PanelView())
        window.contentView?.addSubview(host)
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        applyNoteWindowTheme(window)
        NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            applyNoteWindowTheme(self.window)
        }
    }

    func show() {
        // 已经可见就别再 orderFront：设置里每拖一格都会调一次，白让 WindowServer 重排一次桌面层
        guard !window.isVisible else { return }
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}
