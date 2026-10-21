import AppKit
import SwiftUI

/// 每张便签一个浮动窗口。钉到桌面时降到桌面图标层级，并跟随所有 Space。
@MainActor
final class StickyWindowManager {
    static let shared = StickyWindowManager()

    private var windows: [UUID: StickyNoteWindowController] = [:]

    /// `corner` 只给第一次开窗用（触发角）：便签贴在那个角上，而不是甩到屏幕正中。
    func open(_ id: UUID, focus: Bool = true, at corner: HotCorner? = nil) {
        if let existing = windows[id] {
            if focus {
                existing.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        guard Store.shared.note(id) != nil else { return }
        let controller = StickyNoteWindowController(noteID: id)
        windows[id] = controller
        controller.show(focus: focus, at: corner)
    }

    func close(_ id: UUID) {
        windows[id]?.window.performClose(nil)
    }

    /// 窗口自己关掉了（点红叉、⌘W），只回收引用
    func forget(_ id: UUID) {
        windows[id] = nil
    }

    /// 让浮动窗口跟上数据：收掉便签已经不存在的窗口（恢复备份之后会用到），再补开钉住的便签。
    func syncPinned() {
        let orphaned = windows.keys.filter { Store.shared.note($0) == nil }
        for id in orphaned {
            windows[id]?.window.orderOut(nil)
            forget(id)
        }
        // 补齐窗口时别把焦点从用户手上抢走
        for note in Store.shared.notes where note.pinnedToDesktop { open(note.id, focus: false) }
    }

    /// 钉住状态变了以后要顺带管窗口：便签可能压根还没开过浮动窗口（在列表里直接钉），
    /// 这时候只改数据不补窗，用户看到的就是"图标变了、桌面上什么都没有"。
    /// 反过来取消钉住要把窗口收掉：这张窗是"钉到桌面"才铺出来的，留着就成了
    /// "已经取消钉住了、桌面上还摆着一张"。
    func applyPinnedState(_ id: UUID) {
        guard let note = Store.shared.note(id) else { return }
        guard let controller = windows[id] else {
            if note.pinnedToDesktop { open(id, focus: false) }
            return
        }
        guard note.pinnedToDesktop else {
            close(id)
            return
        }
        controller.apply(pinned: true)
    }

    func toggleCollapsed(_ id: UUID) {
        guard let note = Store.shared.note(id) else { return }
        setCollapsed(id, collapsed: !note.collapsed)
    }

    /// 折叠状态进数据，窗口高度由对应的浮动窗口去改。
    func setCollapsed(_ id: UUID, collapsed: Bool) {
        guard let note = Store.shared.note(id), note.collapsed != collapsed else { return }
        if collapsed {
            let fallback = note.expandedHeight.map { CGFloat($0) } ?? NoteLayout.stickySize.height
            let height = windows[id]?.window.frame.height ?? fallback
            Store.shared.setNoteCollapsed(id, collapsed: true, expandedHeight: Double(height))
        } else {
            Store.shared.setNoteCollapsed(id, collapsed: false, expandedHeight: note.expandedHeight)
        }
        windows[id]?.syncFrame()
    }
}

/// 顶部工具条的空档处可以拖着窗口走，其余区域要让给文字选中和 onTapGesture。
final class StickyHostingView: NSHostingView<StickyNoteView> {
    // 一律 false：窗口拖动交给 WindowDragStrip，否则热区里的点击会被"拖窗口"吃掉
    override var mouseDownCanMoveWindow: Bool { false }

    // 桌面层的窗口平时不是活跃应用，第一击要直接落进正文，不能只拿来激活窗口
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 一块只用来拖窗口的透明视图。isMovableByWindowBackground 配合
/// mouseDownCanMoveWindow 才会真正生效，而 SwiftUI 侧的点击不受影响。
private final class WindowDragStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragStripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class StickyNoteWindowController: NSObject, NSWindowDelegate {
    let noteID: UUID
    let window: FloatingWindow
    private var settingsObserver: NSObjectProtocol?

    init(noteID: UUID) {
        self.noteID = noteID
        window = FloatingWindow(
            contentRect: NSRect(origin: .zero, size: NoteLayout.stickySize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 200, height: NoteLayout.stickyMinHeight)
        window.setFrameAutosaveName("StickyNote-\(noteID.uuidString)")
        window.titlebarSeparatorStyle = .none
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 14
        window.contentView?.layer?.masksToBounds = true

        apply(pinned: Store.shared.note(noteID)?.pinnedToDesktop ?? false)

        let host = StickyHostingView(rootView: StickyNoteView(noteID: noteID))
        window.contentView?.addSubview(host)
        host.frame = window.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        applyNoteWindowTheme(window)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            applyNoteWindowTheme(self.window)
        }
    }

    deinit {
        // 便签窗口会随开随关（forget 掉就释放），观察者不摘就会一次泄漏一个闭包
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func apply(pinned: Bool) {
        if pinned {
            window.level = NoteLayout.desktopLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        } else {
            window.level = .floating
            window.collectionBehavior = [.fullScreenAuxiliary]
        }
        // 不抢焦点，只把自己排回同层最前
        window.orderFrontRegardless()
    }

    /// 折叠只压高度、宽度不动，顶边留在原地，不然折一下窗口就往屏幕上头跳。
    func syncFrame(animated: Bool = true) {
        guard let note = Store.shared.note(noteID) else { return }
        let folded = note.collapsed
        window.contentMinSize = NSSize(
            width: 200,
            height: folded ? NoteLayout.collapsedBarHeight : NoteLayout.stickyMinHeight)
        let target: CGFloat = folded
            ? NoteLayout.collapsedBarHeight
            : (note.expandedHeight.map { CGFloat($0) } ?? max(window.frame.height, NoteLayout.stickyMinHeight))
        guard abs(window.frame.height - target) > 0.5 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target
        window.setFrame(frame, display: true, animate: animated)
    }

    func show(focus: Bool = true, at corner: HotCorner? = nil) {
        // 没存过位置时窗口的 origin 还停在 0,0（屏幕左下角外），给个可见落点
        if window.frame.origin == .zero {
            window.setContentSize(NoteLayout.stickySize)
            // 触发角来的贴到那个角上：按窗口真实外框算落点（titled 窗口比内容高出一截，
            // 用 stickySize 算会把顶边压进菜单栏），甩角落却弹出屏幕正中就没意义了
            if let corner, let screen = NSScreen.screens.first {
                window.setFrameOrigin(corner.origin(for: window.frame.size, in: screen.visibleFrame))
            } else {
                window.center()
            }
        }
        syncFrame(animated: false)
        guard focus else {
            window.orderFront(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 关掉一张钉在桌面的便签就等于取消钉住。不清标记的话卡片墙的图钉还亮着、桌面上却
    /// 什么都没有，要等下次启动 `syncPinned` 才把它冒出来——正是"图标变了桌面没变"那个反馈。
    /// 顺手把没写过字的便签删掉：触发角甩多了会攒出一串「空便签」，留着就是垃圾。
    func windowWillClose(_ notification: Notification) {
        if let note = Store.shared.note(noteID) {
            if note.pinnedToDesktop {
                Store.shared.mutateNote(noteID) { $0.pinnedToDesktop = false }
            }
            // 设了提醒的空白便签是有内容的，不能跟着正文一起扔
            let discard = note.isBlank && note.remindAt == nil
            StickyWindowManager.shared.forget(noteID)
            if discard {
                // 排到下一轮再删：正在关闭的这张窗就是它的数据被显示着，当场抽走不安全
                let id = noteID
                DispatchQueue.main.async { Store.shared.removeNote(id, keepUndo: false) }
            }
            return
        }
        StickyWindowManager.shared.forget(noteID)
    }

    /// 用户拖边框调出来的高度要落进数据：`show()` 每次开窗都按 `expandedHeight` 复位高度，
    /// 不记下来就是"拖高了、关掉再打开又缩回去"（宽度由 setFrameAutosaveName 自己存着）。
    /// 只认鼠标拖拽这一种事件——折叠/展开走的也是 setFrame，回调进来会和 expandedHeight 打架。
    func windowDidResize(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .leftMouseDragged else { return }
        guard let note = Store.shared.note(noteID), !note.collapsed else { return }
        let height = window.frame.height
        guard abs(height - (note.expandedHeight ?? 0)) > 0.5 else { return }
        Store.shared.mutateNote(noteID) { $0.expandedHeight = Double(height) }
    }
}

struct StickyNoteView: View {
    @State private var store = Store.shared
    @State private var settings = AppSettings.shared
    @State private var preview = false

    let noteID: UUID

    var body: some View {
        Group {
            if let note = store.note(noteID) {
                VStack(spacing: 0) {
                    toolbar(note)
                    if !note.collapsed {
                        Divider().opacity(0.35)
                        editor(note)
                        footer(note)
                    }
                }
                // 窗口底色是透明的，必须先铺一层不透明面板色，否则便签色会变成半透明、桌面会透上来
                .background(
                    ZStack {
                        settings.theme == .dark ? Color.panelDark : Color.panelLight
                        NotePalette.color(note.colorIndex).opacity(0.20)
                    })
            } else {
                Text("这张便签已经被删除了")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 不忽略的话 AppKit 会为标题栏留出安全区，窗口顶部出现一条透明带
        .ignoresSafeArea()
    }

    // MARK: - 工具条

    private func toolbar(_ note: StickyNote) -> some View {
        let folded = note.collapsed
        return HStack(spacing: 6) {
            if !folded {
                ForEach(0..<NotePalette.count, id: \.self) { index in
                    Circle()
                        .fill(NotePalette.color(index))
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().strokeBorder(
                                note.colorIndex == index ? Color.primary.opacity(0.65) : .clear,
                                lineWidth: 1.5))
                        .contentShape(Circle())
                        .onTapGesture { store.mutateNote(noteID) { $0.colorIndex = index } }
                        .help("便签颜色")
                }
            }

            if folded {
                collapsedTitle(note)
            } else {
                WindowDragStrip()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .help("按住空白处拖动窗口")
            }

            if !folded {
                Button {
                    preview.toggle()
                } label: {
                    Image(systemName: preview ? "square.and.pencil" : "eye")
                }
                .buttonStyle(.plain)
                .help(preview ? "回到编辑" : "预览渲染效果")
            }

            Menu {
                ForEach(MarkdownText.reminderPresets()) { preset in
                    Button(preset.title) { store.mutateNote(noteID) { $0.remindAt = preset.date } }
                }
                Divider()
                Button("清除提醒") { store.mutateNote(noteID) { $0.remindAt = nil } }
                    .disabled(note.remindAt == nil)
            } label: {
                Image(systemName: note.remindAt == nil ? "bell" : "bell.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(note.remindAt.map { "提醒：\(DateFmt.short.string(from: $0))" } ?? "设置提醒")

            Button {
                store.mutateNote(noteID) { $0.pinnedToDesktop.toggle() }
                StickyWindowManager.shared.applyPinnedState(noteID)
            } label: {
                Image(systemName: note.pinnedToDesktop ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .help(note.pinnedToDesktop ? "取消钉到桌面" : "钉到桌面（常驻壁纸之上）")

            Button {
                preview = false
                StickyWindowManager.shared.toggleCollapsed(noteID)
            } label: {
                // 箭头指向上一步动作的结果：折叠=内容收上去，展开=内容放下来
                Image(systemName: note.collapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.plain)
            .help(note.collapsed ? "展开便签" : "折叠成一条")

            Button {
                StickyWindowManager.shared.close(noteID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭这张便签")
        }
        .font(.system(size: settings.fontSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: NoteLayout.collapsedBarHeight)
    }

    /// 折叠态下标题占掉工具条中间的空档；字压在拖动条上且不接管点击，空白处照样能拖窗口。
    private func collapsedTitle(_ note: StickyNote) -> some View {
        WindowDragStrip()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Text(note.firstLine.isEmpty ? "空便签" : note.firstLine)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsHitTesting(false)
                    .padding(.leading, 4)
            }
            .help("按住空白处拖动窗口")
    }

    // MARK: - 正文

    @ViewBuilder
    private func editor(_ note: StickyNote) -> some View {
        if preview {
            ScrollView {
                NoteBodyView(text: note.text, fontSize: settings.fontSize, interactive: true) { line, done in
                    store.toggleNoteCheckbox(noteID, line: line, to: done)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MarkdownEditor(text: noteText(note), fontSize: settings.fontSize, autoFocus: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
    }

    private func noteText(_ note: StickyNote) -> Binding<String> {
        Binding(get: { note.text }, set: { value in
            store.mutateNote(noteID) { $0.text = value }
        })
    }

    private func footer(_ note: StickyNote) -> some View {
        HStack {
            Text(DateFmt.relative(note.updatedAt))
            if let remindAt = note.remindAt {
                Text("· 提醒 \(DateFmt.short.string(from: remindAt))")
            }
            Spacer()
            Text("\(note.text.count) 字")
        }
        .font(.system(size: max(9, settings.fontSize - 4)))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
