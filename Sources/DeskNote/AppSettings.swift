import Foundation
import Observation

extension Notification.Name {
    /// 外观/窗口层面要跟着变（透明度、主题、面板开关、全局热键、触发角）
    static let settingsChanged = Notification.Name("desknote.settingsChanged")
    /// 只有备份相关的设置变了，需要重挂定时器
    static let backupSettingsChanged = Notification.Name("desknote.backupSettingsChanged")
}

enum NoteTheme: String, CaseIterable, Codable, Identifiable {
    case dark, light
    var id: String { rawValue }
    var label: String { self == .dark ? "深色" : "浅色" }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = AppEnv.defaults

    // 每个键只写自己：整表 persist 的话，拖一次透明度滑块就是上百次多余写入。
    // 也只有真的需要 AppKit 侧（窗口透明度、外观、面板开关）响应的键才发通知。
    var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity"); post(.settingsChanged) } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var theme: NoteTheme { didSet { defaults.set(theme.rawValue, forKey: "theme"); post(.settingsChanged) } }
    var desktopPanelEnabled: Bool { didSet {
        defaults.set(desktopPanelEnabled, forKey: "desktopPanelEnabled"); post(.settingsChanged)
    } }
    /// 不在前台也能按 ⌥⌘N 建便签。注册/注销由 AppDelegate 响应 .settingsChanged 来做
    var globalHotKeyEnabled: Bool { didSet {
        defaults.set(globalHotKeyEnabled, forKey: "globalHotKeyEnabled"); post(.settingsChanged)
    } }
    /// 热键注册失败的原因，只给设置页看，不落盘
    var globalHotKeyError: String?
    /// 触发角挂不上（没授权、探针创建失败）的原因，同样只给设置页看
    var hotCornerError: String?
    /// 触发角新建便签。默认关闭：要生效得先有辅助功能权限，不适合没打招呼就开口要
    var hotCorner: HotCorner { didSet {
        defaults.set(hotCorner.rawValue, forKey: "hotCorner"); post(.settingsChanged)
    } }
    var section: NoteSection { didSet { defaults.set(section.rawValue, forKey: "section") } }
    var sidebarCollapsed: Bool { didSet { defaults.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }
    /// 便签页中间栏：false = 备忘录式列表 + 正文，true = 等高卡片画廊
    var notesGallery: Bool { didSet { defaults.set(notesGallery, forKey: "notesGallery") } }
    /// 便签页中间的便签列表栏：true = 收起，正文栏占满
    var notesListCollapsed: Bool { didSet {
        defaults.set(notesListCollapsed, forKey: "notesListCollapsed")
    } }
    /// 桌面面板快速添加的落点，选过一次就记住
    var quickAddProjectID: String? { didSet {
        defaults.set(quickAddProjectID, forKey: "quickAddProjectID")
    } }

    // WebDAV 备份：密码不在这里，见 webdavPassword
    var webdavServer: String { didSet { defaults.set(webdavServer, forKey: "webdavServer") } }
    var webdavFolder: String { didSet { defaults.set(webdavFolder, forKey: "webdavFolder") } }
    var webdavUser: String { didSet { defaults.set(webdavUser, forKey: "webdavUser") } }
    var webdavAutoBackup: Bool { didSet {
        defaults.set(webdavAutoBackup, forKey: "webdavAutoBackup"); post(.backupSettingsChanged)
    } }
    var webdavKeepCount: Int { didSet { defaults.set(webdavKeepCount, forKey: "webdavKeepCount") } }

    /// 计算属性：读写都直接落到钥匙串，避免明文进 UserDefaults
    var webdavPassword: String {
        get { SecretStore.read() }
        set { SecretStore.write(newValue) }
    }

    private init() {
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.92
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        theme = NoteTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        desktopPanelEnabled = defaults.object(forKey: "desktopPanelEnabled") as? Bool ?? true
        globalHotKeyEnabled = defaults.object(forKey: "globalHotKeyEnabled") as? Bool ?? false
        hotCorner = HotCorner(rawValue: defaults.string(forKey: "hotCorner") ?? "") ?? .off
        section = NoteSection(rawValue: defaults.string(forKey: "section") ?? "all") ?? .all
        // 三栏吃宽度，老窗口第一次升级时先收起类别栏，想展开点一下左上角就行
        sidebarCollapsed = defaults.object(forKey: "sidebarCollapsed") as? Bool ?? true
        notesGallery = defaults.bool(forKey: "notesGallery")
        notesListCollapsed = defaults.bool(forKey: "notesListCollapsed")
        webdavServer = defaults.string(forKey: "webdavServer") ?? ""
        webdavFolder = defaults.string(forKey: "webdavFolder") ?? "DeskNote"
        webdavUser = defaults.string(forKey: "webdavUser") ?? ""
        webdavAutoBackup = defaults.object(forKey: "webdavAutoBackup") as? Bool ?? false
        webdavKeepCount = defaults.object(forKey: "webdavKeepCount") as? Int ?? 20
        quickAddProjectID = defaults.string(forKey: "quickAddProjectID")
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
