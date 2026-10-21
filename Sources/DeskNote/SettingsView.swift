import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var manager = BackupManager.shared
    @State private var notifStatus = "检查中…"
    @State private var pendingRestore: RemoteBackup?
    @State private var loginItemError: String?
    /// 只在设置页开着的时候读，授权回来靠 didBecomeActive 刷新
    @State private var axTrusted = Accessibility.isTrusted

    /// 登录项的真开关在系统那边（用户也能在「系统设置 → 通用 → 登录项」里动），
    /// 所以这里直接读 SMAppService 的状态，不在本地再存一份、免得两边打架
    private var loginItem: Binding<Bool> {
        Binding(get: { LoginItem.isEnabled }, set: { loginItemError = LoginItem.set($0) })
    }

    var body: some View {
        Form {
            Picker("主题", selection: $settings.theme) {
                ForEach(NoteTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading) {
                Text("透明度 \(Int(settings.opacity * 100))%")
                Slider(value: $settings.opacity, in: 0.55...1.0)
            }

            Stepper("字号 \(Int(settings.fontSize)) pt", value: $settings.fontSize, in: 11...20)

            Toggle("桌面组件（钉在桌面）", isOn: $settings.desktopPanelEnabled)

            Toggle("开机自动启动", isOn: loginItem)
            Toggle("全局热键 ⌥⌘N 新建便签", isOn: $settings.globalHotKeyEnabled)
            if let reason = settings.globalHotKeyError {
                Text(reason).font(.system(size: 11)).foregroundStyle(.red)
            }
            if let reason = loginItemError {
                Text(reason).font(.system(size: 11)).foregroundStyle(.red)
            }

            Picker("触发角新建便签", selection: $settings.hotCorner) {
                ForEach(HotCorner.allCases) { corner in
                    Text(corner.label).tag(corner)
                }
            }
            if settings.hotCorner != .off {
                LabeledContent("辅助功能授权") {
                    HStack {
                        Text(axTrusted ? "已授权" : "未授权")
                            .foregroundStyle(axTrusted ? Color.green : Color.secondary)
                        Button("打开系统设置…") { Accessibility.openSettings() }
                    }
                }
                // 授权显示已授也可能挂不上（探针创建失败），失败原因必须露出来，
                // 不然用户只能看到「甩了没反应」这一件事
                if let reason = settings.hotCornerError {
                    Text(reason).font(.system(size: 11)).foregroundStyle(.red)
                }
                Text("鼠标甩到\(settings.hotCorner.label)就新建一张便签，和系统的快速备忘录一样。没有授权时看不见别的 App 里的鼠标移动，甩过去不会响。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Deadline 通知") {
                HStack {
                    Text(notifStatus)
                        .foregroundStyle(notifStatus == "已允许" ? Color.green : Color.secondary)
                    Button("系统通知设置…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                }
            }

            Section {
                connection()
                controls()
                remoteList()
            } header: {
                Text("WebDAV 备份")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每次备份把整个数据文件按时间戳存成一份副本；恢复时选一份覆盖本地，本地这份会先留成 data.json.bak。")
                    Text("坚果云：网页端「我的账户 → 安全选项 → 添加应用」生成应用密码，地址 \(BackupManager.jianguoyun)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                // Form 里默认会继承成右对齐，说明文字必须左对齐
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        // 尺寸交给窗口（可拖边 + autosave）。外观也走 NSWindow.appearance，不在这里用
        // preferredColorScheme：它和撑满式的 frame 链在一起会让 SwiftUI 递归爆栈。
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // 被系统弹窗带去勾完辅助功能再切回来，这一跳就把状态刷成「已授权」
            axTrusted = Accessibility.isTrusted
        }
        .task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            switch s.authorizationStatus {
            case .authorized, .provisional: notifStatus = "已允许"
            case .denied: notifStatus = "已拒绝"
            default: notifStatus = "未决定"
            }
        }
        .confirmationDialog(
            "恢复会用 \(pendingRestore?.name ?? "") 覆盖本地数据。",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible
        ) {
            Button("仍然恢复", role: .destructive) {
                if let item = pendingRestore {
                    Task { await manager.restore(item) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 连接

    @ViewBuilder
    private func connection() -> some View {
        HStack {
            TextField("服务器", text: $settings.webdavServer,
                      prompt: Text(BackupManager.jianguoyun))
            Button("坚果云") { settings.webdavServer = BackupManager.jianguoyun }
        }
        TextField("账号", text: $settings.webdavUser, prompt: Text("网盘登录邮箱"))
        SecureField("应用密码", text: $settings.webdavPassword)
        TextField("备份目录", text: $settings.webdavFolder, prompt: Text("DeskNote"))
    }

    // MARK: - 操作

    @ViewBuilder
    private func controls() -> some View {
        Toggle("自动备份", isOn: $settings.webdavAutoBackup)
        if settings.webdavAutoBackup {
            Text("有改动 1 分钟后自动备份")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Stepper("保留 \(settings.webdavKeepCount) 份",
                    value: $settings.webdavKeepCount, in: 1...100)
        }

        LabeledContent("状态") {
            if let busy = manager.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            } else {
                Text(manager.status)
                    .font(.system(size: 11))
                    .foregroundStyle(manager.failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }

        HStack(spacing: 8) {
            Button("测试连接") { Task { await manager.test() } }
            Button("立即备份") { Task { await manager.backupNow() } }
            Button("刷新列表") { Task { await manager.refresh() } }
        }
        .disabled(manager.busy != nil)
    }

    // MARK: - 远端副本

    @ViewBuilder
    private func remoteList() -> some View {
        if manager.backups.isEmpty {
            Text("还没有读到远端列表，点「刷新列表」看看。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            ForEach(manager.backups) { item in
                HStack {
                    Text(item.timeLabel)
                    Spacer()
                    Text(item.sizeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("恢复") { pendingRestore = item }
                        .disabled(manager.busy != nil)
                }
            }
        }
    }
}
