import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

/// 开机自动启动。真开关在系统那边（用户也能在「系统设置 → 通用 → 登录项」里关掉），
/// 所以只读 SMAppService 的状态、不在 UserDefaults 再存一份，免得两处显示打架。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// - Returns: nil 表示成功，否则是给用户看的原因（未签名/被系统拒绝时不会是 nil）
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "登录项没设上：\(error.localizedDescription)"
        }
    }
}

/// 触发角靠全局鼠标事件，这一项要辅助功能授权
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统那句「想要控制这台电脑」，同时把本 App 列进辅助功能清单
    static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// 破坏性删除前问一句。撤销只保一步，「一次吃掉整个类别」这种事不该靠记住 ⌘⌥Z。
/// 回车留给「取消」——手滑按 Return 不应该删掉东西。
@MainActor
func confirmDelete(_ what: String, detail: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "删除\(what)？"
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    alert.buttons.last?.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
}

extension Color {
    static let panelDark = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let panelLight = Color(red: 0.97, green: 0.97, blue: 0.96)
}

/// 内容帧尺寸：SwiftUI 根视图与 NSWindow 必须一致，否则 autosave 记住的旧尺寸会裁掉内容。
enum NoteLayout {
    /// 默认宽度要能同时放下「类别｜便签列表｜正文」三栏
    static let mainSize = NSSize(width: 760, height: 540)
    static let mainMinSize = NSSize(width: 520, height: 360)
    static let notesListWidth: CGFloat = 216
    /// 编辑器自己的留白（SwiftUI 那层的 padding 已经管外圈，这里只留一点给光标和勾选圈）
    static let editorInset = NSSize(width: 3, height: 4)
    static let panelSize = NSSize(width: 300, height: 360)
    /// 面板可以拖边，但要留得下「表头一行 + 快速添加 + 一条事项 + 底部进度」
    static let panelMinSize = NSSize(width: 200, height: 186)
    static let stickySize = NSSize(width: 300, height: 260)
    /// 折叠后只剩工具条那一行
    static let collapsedBarHeight: CGFloat = 36
    static let stickyMinHeight: CGFloat = 140
    /// 桌面层窗口要压着桌面图标层「一级」，不能正好相等：Finder 的全屏桌面窗口就在
    /// desktopIconWindow 这一层，同层只看排位，它排到我们前面时便签就再也收不到鼠标事件。
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
}

enum DateFmt {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    /// 备份列表里同一分钟可能有多份，必须带到秒才分得清
    static let backup: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// WebDAV 的 getlastmodified 是 RFC1123，必须按英文星期解析
    static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86400: return "\(Int(seconds / 3600)) 小时前"
        case ..<604800: return "\(Int(seconds / 86400)) 天前"
        default: return short.string(from: date)
        }
    }

    /// 便签列表里每一行的日期
    static let noteDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 分组标题已经写了「今天」，今天那一摞再重复日期没意义，跟备忘录一样退化成时间
    static func listStamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? time.string(from: date) : noteDate.string(from: date)
    }

    /// 便签列表分组标题，越旧越粗：今天 / 昨天 / 星期X / M月 / yyyy年
    static func group(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: Date())).day ?? 0
        if days == 0 { return "今天" }
        if days == 1 { return "昨天" }
        if days < 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        return cal.isDate(date, equalTo: Date(), toGranularity: .year) ? month.string(from: date) : year.string(from: date)
    }

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月"
        return f
    }()

    private static let year: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年"
        return f
    }()
}

/// 便签底色：沿用边条色块的低饱和做法，深浅色主题下都能压住正文
enum NotePalette {
    static let colors: [Color] = [
        Color(red: 0.85, green: 0.76, blue: 0.42),
        Color(red: 0.55, green: 0.76, blue: 0.55),
        Color(red: 0.48, green: 0.68, blue: 0.85),
        Color(red: 0.85, green: 0.58, blue: 0.62),
        Color(red: 0.68, green: 0.58, blue: 0.85),
        Color(red: 0.62, green: 0.70, blue: 0.74),
    ]

    static var count: Int { colors.count }

    static func color(_ index: Int) -> Color {
        colors[abs(index) % colors.count]
    }
}

/// 拖拽负载：用带前缀的字符串。自定义 UTType + CodableRepresentation 在 SwiftUI 里投放端匹配不上，
/// 只能靠 String 传递，再在前缀里区分是事项、类别还是便签。
enum DragPayload {
    static func item(_ id: UUID) -> String { "item:\(id.uuidString)" }
    static func category(_ id: UUID) -> String { "cat:\(id.uuidString)" }
    static func note(_ id: UUID) -> String { "note:\(id.uuidString)" }

    static func itemID(_ text: String) -> UUID? {
        guard text.hasPrefix("item:") else { return nil }
        return UUID(uuidString: String(text.dropFirst(5)))
    }

    static func categoryID(_ text: String) -> UUID? {
        guard text.hasPrefix("cat:") else { return nil }
        return UUID(uuidString: String(text.dropFirst(4)))
    }

    static func noteID(_ text: String) -> UUID? {
        guard text.hasPrefix("note:") else { return nil }
        return UUID(uuidString: String(text.dropFirst(5)))
    }
}

enum DeadlineStatus: Equatable {
    case none, future, soon, overdue

    static func of(_ date: Date?, done: Bool) -> DeadlineStatus {
        guard let date, !done else { return date == nil ? .none : .future }
        let now = Date()
        if date <= now { return .overdue }
        if date.timeIntervalSince(now) < 3600 * 24 { return .soon }
        return .future
    }

    var color: Color {
        switch self {
        case .none: return .secondary
        case .future: return .secondary
        case .soon: return .orange
        case .overdue: return .red
        }
    }
}

private struct FontSizeKey: EnvironmentKey {
    static let defaultValue: Double = 13
}

extension EnvironmentValues {
    var noteFontSize: Double {
        get { self[FontSizeKey.self] }
        set { self[FontSizeKey.self] = newValue }
    }
}
