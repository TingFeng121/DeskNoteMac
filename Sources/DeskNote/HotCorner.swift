import AppKit
import Carbon.HIToolbox

/// 触发角：鼠标甩到屏幕角落就地弹一张新便签，学系统的「快速备忘录」。
/// 系统那张触发角列表不给第三方 App 注册，只能自己盯鼠标。
///
/// 用分离式事件探针（listen-only `CGEventTap`）盯鼠标，不用定时器轮询：鼠标不动就一次都不醒。
/// 代价是要「辅助功能」权限。别改回 `NSEvent.addGlobalMonitorForEvents(.mouseMoved)`：
/// 它只转投别的 App 真正收到的事件，而桌面那一层根本不申请 mouseMoved，实测一次都不回调
/// （2026-10-04 就是这条让触发角「授权显示已授、甩角落没反应」）。
enum HotCorner: String, CaseIterable, Identifiable {
    case off, topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "关闭"
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }

    /// 便签贴在这个角上的落点。用 visibleFrame 而不是 frame：菜单栏和 Dock 那一条不能压。
    /// AppKit 的窗口 origin 是左下角，所以底部两个角要往下让出一个窗高。
    func origin(for size: NSSize, in visible: NSRect) -> NSPoint {
        let margin: CGFloat = 12
        let x = isLeft ? visible.minX + margin : visible.maxX - size.width - margin
        let y = isTop ? visible.maxY - size.height - margin : visible.minY + margin
        return NSPoint(x: x, y: y)
    }
}

/// 探针的状态。回调跑在主线程，`uninstall` 也在主线程拆，所以锁只为把「判断 + 消耗」
/// 合成一步：进过一次角落就熄火，指针退出解除范围才重新点亮，
/// 不然在角上抖两下鼠标能连开四五张便签。
private final class CornerProbe: @unchecked Sendable {
    let lock = NSLock()
    /// 触发方块和解除范围，都是 Quartz 全局坐标（原点在主屏左上角，y 向下）
    var trigger = NSRect.zero
    var release = NSRect.zero
    var corner: HotCorner = .off
    var tap: CFMachPort?
    var armed = true
    var enabled = false

    /// 返回 true 表示这一次该弹便签
    func handle(_ point: CGPoint) -> Bool {
        lock.withLock {
            guard enabled else { return false }
            if trigger.contains(point) {
                guard armed else { return false }
                armed = false
                return true
            }
            if !release.contains(point) { armed = true }
            return false
        }
    }
}

/// 系统只调这一个 C 回调：矩形比较留在这里，建窗口绕回主线程
private func cornerCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let probe = Unmanaged<CornerProbe>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .mouseMoved:
        // 按着左键甩到角落是在拖窗口（系统那套贴边平铺），不是要建便签
        if probe.handle(event.location), NSEvent.pressedMouseButtons & 1 == 0 {
            let corner = probe.corner
            DispatchQueue.main.async { AppDelegate.shared?.stickyNote(from: corner) }
        }
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        // 系统嫌回调慢会把探针关掉。这里只有一次矩形比较，正常走不到，被关了就叫回来
        if let tap = probe.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default: break
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class HotCornerWatcher {
    static let shared = HotCornerWatcher()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var probe: CornerProbe?

    /// 上一次挂载对应的角落和授权状态。两者都没变就不重装——每次 App 被激活、
    /// 每次拖透明度滑块都会重新算一遍，拆了重装会漏掉中间的移动。
    private var installedCorner: HotCorner = .off
    private var installedTrusted = false

    /// 触发方块的边长：指针得真顶到角上才算「甩」，6pt 和系统触发角的手感一致
    private static let triggerSize: CGFloat = 6
    /// 退出这个范围才重新武装
    private static let releaseSize: CGFloat = 60

    /// 上一次挂载的结果：nil = 挂上了，否则是失败原因。状态没变时原样返回它，
    /// 免得每次 App 被激活都把「还没授权」那行红字抹掉
    private var lastError: String?

    private init() {}

    /// - Returns: nil 表示已经挂上，否则是给用户看的失败原因（设置页那行红字）
    func apply(_ corner: HotCorner) -> String? {
        let trusted = Accessibility.isTrusted
        guard corner != installedCorner || trusted != installedTrusted else { return lastError }
        uninstall()
        installedCorner = corner
        installedTrusted = trusted
        lastError = corner == .off ? nil : install(corner, trusted: trusted)
        return lastError
    }

    func remove() {
        installedCorner = .off
        installedTrusted = false
        uninstall()
    }

    private func install(_ corner: HotCorner, trusted: Bool) -> String? {
        guard trusted else {
            // 没授权时探针根本创建不出来。先把系统弹窗推出去，原因写在设置页上
            Accessibility.requestPrompt()
            return "还没拿到辅助功能授权，甩角落不会响应"
        }
        // 只认主屏（screens.first 就是带菜单栏那块），多显示器时甩副屏角落不该有反应
        let screen = NSScreen.screens.first
        let width = screen?.frame.width ?? 0
        let height = screen?.frame.height ?? 0
        let box = CornerProbe()
        box.corner = corner
        box.trigger = NSRect(
            x: corner.isLeft ? 0 : width - Self.triggerSize,
            // Quartz 的 y 从上往下数，所以「上角」是 y≈0、「下角」是 y≈屏高
            y: corner.isTop ? 0 : height - Self.triggerSize,
            width: Self.triggerSize, height: Self.triggerSize)
        box.release = box.trigger.insetBy(dx: -Self.releaseSize, dy: -Self.releaseSize)
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: cornerCallback,
            userInfo: Unmanaged.passUnretained(box).toOpaque()) else {
            return "事件探针没挂上，重启一次桌面便签再试"
        }
        // 探针的回调由这个 runloop source 驱动，和定时器一样要 .common：
        // 拖窗口、滚列表的那段时间也得看得见鼠标
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        box.enabled = true
        box.tap = created
        tap = created
        source = src
        probe = box
        return nil
    }

    /// 先摘 source 再 invalidate：这两步之后回调不可能再进来，refcon 那个未持有指针才安全
    private func uninstall() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        probe?.enabled = false
        probe?.tap = nil
        source = nil
        tap = nil
        probe = nil
    }
}

/// 全局热键 ⌥⌘N 新建便签。走 Carbon 的 RegisterEventHotKey：不需要辅助功能权限，
/// 也不管谁在前台（`addGlobalMonitorForEvents` 收键盘事件要授权，那个门槛留给触发角用）。
@MainActor
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    private static let newNoteID: UInt32 = 1
    /// 'DNHk'：热键归属标记，只要在本 App 内唯一就行
    private static let signature = OSType(0x444E_486B)

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// - Returns: nil 表示注册上了，否则是给用户看的失败原因（多半是这组合键被别的程序占了）
    func enableNewNote() -> String? {
        installHandlerIfNeeded()
        guard ref == nil else { return nil }
        var created: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.newNoteID)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N), UInt32(optionKey | cmdKey), id,
            GetApplicationEventTarget(), 0, &created)
        guard status == noErr, let created else {
            return "⌥N 没注册上（OSStatus \(status)），可能被别的程序占了"
        }
        ref = created
        return nil
    }

    func disableNewNote() {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        self.ref = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // 回调是 C 函数指针、不能捕获 self，所以传本进程单例的固定指针进去
        InstallEventHandler(
            GetApplicationEventTarget(), hotKeyCallback, 1, &type,
            Unmanaged.passUnretained(GlobalHotKeys.shared).toOpaque(), &handler)
    }

    fileprivate func handle(_ id: UInt32) {
        guard id == Self.newNoteID else { return }
        AppDelegate.shared?.newStickyNote()
    }
}

/// 系统只调这一个 C 回调：取出热键号，再回主线程分发
private func hotKeyCallback(
    _ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var id = EventHotKeyID()
    GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    let me = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in me.handle(id.id) }
    return noErr
}
