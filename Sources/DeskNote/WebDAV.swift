import Foundation
import Security
import Observation

// MARK: - 钥匙串

/// WebDAV 密码只进系统钥匙串，不落 UserDefaults。
enum SecretStore {
    private static let service = "local.desknote.app"
    private static let account = "webdav"

    /// 一个进程只敲一次钥匙串。每敲一次都可能弹一次授权框，
    /// 而 `AppSettings.webdavPassword` 是计算属性，挂在视图上会被刷新放大成连弹好几个密码框。
    private static var cache: String?

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String {
        if let cache { return cache }
        // 演示实例不敲钥匙串：一个授权框就能把整轮后台截图卡死
        if AppEnv.demo { return "" }
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        var value = ""
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data {
            value = String(data: data, encoding: .utf8) ?? ""
        }
        // 取不到也记下结果：这一轮授权已经被拒了，再敲一次只会再弹一个框
        cache = value
        return value
    }

    static func write(_ value: String) {
        cache = value
        guard !AppEnv.demo else { return }
        if value.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let payload = [kSecValueData as String: Data(value.utf8)]
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, payload as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// 已经是中文结论，直接显示给用户
struct WebDAVFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RemoteBackup: Identifiable, Equatable {
    let name: String
    let modified: Date?
    let size: Int
    var id: String { name }

    var timeLabel: String {
        modified.map { DateFmt.backup.string(from: $0) } ?? "时间未知"
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - 客户端

/// 一次请求一次响应的轻量 WebDAV。目录里放的就是一个个带时间戳的 data.json 副本。
@MainActor
struct WebDAVClient {
    let folderURL: URL
    let user: String
    let password: String

    init?(settings: AppSettings) {
        let server = settings.webdavServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !settings.webdavUser.isEmpty,
              let url = WebDAVClient.endpoint(server: server, folder: settings.webdavFolder)
        else { return nil }
        folderURL = url
        user = settings.webdavUser.trimmingCharacters(in: .whitespacesAndNewlines)
        password = settings.webdavPassword
    }

    /// 服务器地址 + 备份目录 → 带尾斜杠的目录 URL
    static func endpoint(server: String, folder: String) -> URL? {
        var base = server
        if !base.contains("://") { base = "https://" + base }
        if !base.hasSuffix("/") { base += "/" }
        let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !trimmed.isEmpty else { return URL(string: base) }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: base + encoded + "/")
    }

    private static let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop>
        <d:getlastmodified/><d:getcontentlength/><d:resourcetype/>
        </d:prop></d:propfind>
        """

    private func request(
        _ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:]
    ) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let credential = Data("\(user):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        req.httpBody = body
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVFailure("服务器没回 HTTP 状态，检查一下地址是不是 WebDAV 端口")
        }
        return (data, http)
    }

    private static func explain(_ status: Int) -> String {
        switch status {
        case 401: return "账号或密码不对（坚果云要用「应用密码」，不是登录密码）"
        case 403: return "服务器拒绝访问这个目录"
        case 404: return "找不到这个目录"
        case 405: return "这个地址不接受该操作，确认填的是 WebDAV 地址"
        case 409: return "上级目录不存在"
        case 501: return "服务器不支持这个 WebDAV 操作"
        default: return "服务器返回 HTTP \(status)"
        }
    }

    private static func ok(_ status: Int) -> Bool { (200...299).contains(status) }

    /// 探测地址与认证是否可用，返回一句给人看的结论
    func check() async throws -> String {
        let status = try await send(request(
            "PROPFIND", folderURL,
            body: Data(Self.propfindBody.utf8),
            headers: ["Depth": "0", "Content-Type": "text/xml; charset=utf-8"])).1.statusCode
        if Self.ok(status) { return "连接成功，备份目录可用" }
        if status == 404 { return "地址和认证都对，目录还不存在（首次备份会自动建）" }
        throw WebDAVFailure(Self.explain(status))
    }

    /// 坚果云这类服务器不会自动建目录：409/404 时补一次 MKCOL 再重试
    private func makeFolder() async throws {
        let status = try await send(request("MKCOL", folderURL)).1.statusCode
        guard Self.ok(status) || status == 405 || status == 102 else {
            throw WebDAVFailure(Self.explain(status))
        }
    }

    func upload(name: String, data: Data) async throws {
        let url = folderURL.appendingPathComponent(name)
        let req = request("PUT", url, body: data,
                          headers: ["Content-Type": "application/json"])
        var status = try await send(req).1.statusCode
        if status == 409 || status == 404 {
            try await makeFolder()
            status = try await send(req).1.statusCode
        }
        guard Self.ok(status) else { throw WebDAVFailure(Self.explain(status)) }
    }

    func list() async throws -> [RemoteBackup] {
        let req = request("PROPFIND", folderURL,
                          body: Data(Self.propfindBody.utf8),
                          headers: ["Depth": "1", "Content-Type": "text/xml; charset=utf-8"])
        let (body, http) = try await send(req)
        if http.statusCode == 404 { return [] }
        guard Self.ok(http.statusCode) else { throw WebDAVFailure(Self.explain(http.statusCode)) }
        return PropfindReader.parse(body)
            .filter { $0.name.hasPrefix(BackupManager.prefix) && $0.name.hasSuffix(".json") }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    func download(name: String) async throws -> Data {
        let (data, http) = try await send(request("GET", folderURL.appendingPathComponent(name)))
        guard Self.ok(http.statusCode) else { throw WebDAVFailure(Self.explain(http.statusCode)) }
        return data
    }

    private func remove(name: String) async throws {
        _ = try await send(request("DELETE", folderURL.appendingPathComponent(name)))
    }

    /// 只留最近 keep 份，超出的从最旧开始删
    func prune(keep: Int) async throws {
        guard keep > 0 else { return }
        for extra in try await list().dropFirst(keep) {
            try? await remove(name: extra.name)
        }
    }
}

/// PROPFIND 的 207 multistatus 里每个 propstat 是一条资源
private final class PropfindReader: NSObject, XMLParserDelegate {
    private var entries: [RemoteBackup] = []
    private var text = ""
    private var href = ""
    private var modified: String?
    private var length: Int?

    static func parse(_ data: Data) -> [RemoteBackup] {
        let reader = PropfindReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        return parser.parse() ? reader.entries : []
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        text = ""
        // href 是 response 的直接子元素，排在 propstat 前面，所以状态只能在 response 开始时清
        if elementName == "response" {
            href = ""
            modified = nil
            length = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    /// 注意：XMLParserDelegate 的 didEndElement 没有 attributes 参数，带上就变成另一个
    /// 永远不被调用的重载，列表会静默变空。
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": href = value
        case "getlastmodified": modified = value
        case "getcontentlength": length = Int(value)
        case "response": record()
        default: break
        }
    }

    private func record() {
        guard !href.isEmpty else { return }
        let path = href.removingPercentEncoding ?? href
        guard let name = path.split(separator: "/").last, name.hasSuffix(".json") else { return }
        entries.append(RemoteBackup(
            name: String(name), modified: modified.flatMap(DateFmt.httpDate.date(from:)),
            size: length ?? 0))
    }
}

// MARK: - 备份调度

@MainActor
@Observable
final class BackupManager {
    static let shared = BackupManager()

    static let prefix = "DeskNote-"
    static let jianguoyun = "https://dav.jianguoyun.com/dav/"
    /// 最近一次成功备份时的改动流水号：之后一格没动就没必要再传一遍
    static let revisionKey = "webdavBackedUpRevision"

    /// 非空表示正在跑网络操作，值就是当前动作文案
    private(set) var busy: String?
    private(set) var status = "还没备份过"
    private(set) var failed = false
    private(set) var backups: [RemoteBackup] = []

    private var timer: Timer?
    /// 这一轮改动起算的时刻；nil = 没有等着传的改动，也就没有表
    private var pendingSince: Date?
    /// 静置多久之后传：给连续写作留窗口，不至于每改一次就上一版
    private static let quietPeriod: TimeInterval = 60
    private let settings = AppSettings.shared

    private init() {
        status = lastBackupStatus()
        // 存盘流水号每动一次都 +1，这里就是备份唯一的起表入口
        NotificationCenter.default.addObserver(
            forName: .storeDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteChanged() }
        }
    }

    private func lastBackupStatus() -> String {
        guard let at = AppEnv.defaults.object(forKey: "webdavLastBackupAt") as? TimeInterval else {
            return "还没备份过"
        }
        return "上次备份 \(DateFmt.relative(Date(timeIntervalSince1970: at)))"
    }

    var isReady: Bool {
        !settings.webdavServer.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.webdavUser.trimmingCharacters(in: .whitespaces).isEmpty
            && !settings.webdavPassword.isEmpty
    }

    private func client() throws -> WebDAVClient {
        guard let client = WebDAVClient(settings: settings) else {
            throw WebDAVFailure("先填好服务器地址、账号和应用密码")
        }
        return client
    }

    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(prefix)\(f.string(from: date)).json"
    }

    /// 记下「远端已经有这一份内容了」。恢复完也要记，否则这一份会被当成"新改动"再推一遍
    private func markBackedUp(revision: Int) {
        AppEnv.defaults.set(revision, forKey: Self.revisionKey)
    }

    /// 自上次成功备份以来到底改没改。没备过（键不存在）一律算"有改动"。
    private var hasChanges: Bool {
        let last = AppEnv.defaults.object(forKey: Self.revisionKey) as? Int
        return last == nil || last! != Store.shared.revision
    }

    // MARK: 动作

    func test() async {
        await running("正在连接…") {
            status = try await client().check()
            failed = false
        }
    }

    func refresh() async {
        await running("正在读取远端列表…") {
            backups = try await client().list()
            failed = false
            if backups.isEmpty { status = "目录里还没有备份文件" }
        }
    }

    func backupNow() async { await backup(silent: false) }

    /// - Returns: 这一轮有没有真的传上去（没填完、失败、或撞上手动操作都算没有）
    @discardableResult
    func backup(silent: Bool) async -> Bool {
        guard isReady else {
            if !silent { report("还没填完服务器、账号和应用密码", error: true) }
            return false
        }
        var uploaded = false
        await running("正在备份…", silent: silent) {
            Store.shared.save()
            // 先取号再上传：网络这一秒里用户可能又动了数据，取晚了会把没传出去的那格也记成已备份
            let revision = Store.shared.revision
            guard let raw = try? Data(contentsOf: Store.fileURL) else {
                throw WebDAVFailure("读不到本地数据文件")
            }
            let client = try self.client()
            let name = Self.fileName(Date())
            try await client.upload(name: name, data: raw)
            markBackedUp(revision: revision)
            AppEnv.defaults.set(Date().timeIntervalSince1970, forKey: "webdavLastBackupAt")
            // 先按保留份数清理再列目录，否则界面会留着几行点一下就 404 的副本
            try? await client.prune(keep: settings.webdavKeepCount)
            backups = (try? await client.list()) ?? backups
            failed = false
            status = "上次备份 \(DateFmt.backup.string(from: Date()))"
            if !silent { report("已上传 \(name)", error: false) }
            uploaded = true
        }
        return uploaded
    }

    func restore(_ backup: RemoteBackup) async {
        await running("正在恢复…") {
            let raw = try await client().download(name: backup.name)
            guard let incoming = try? JSONDecoder().decode(BoardData.self, from: raw) else {
                throw WebDAVFailure("这份备份不是本应用的数据文件")
            }
            Store.shared.replaceAll(incoming)
            // 这份内容远端本来就有，别再让改动起表把它当"新改动"推上去
            markBackedUp(revision: Store.shared.revision)
            Notifier.sync(Store.shared)
            let items = incoming.categories.flatMap { $0.projects.flatMap { $0.items } }.count
            report("已恢复 \(backup.name)：\(items) 个事项 / \(incoming.notes.count) 张便签", error: false)
            StickyWindowManager.shared.syncPinned()
        }
    }

    // MARK: 定时

    /// 备份只有一个触发条件：有还没传上去的改动。改动之后静置 1 分钟传一次。
    /// 已经在计时就不往后推（到点传的是那一刻最新的版本），否则连续打字会把这一轮
    /// 一直悬着，永远传不出去。
    func noteChanged() {
        guard settings.webdavAutoBackup, pendingSince == nil else { return }
        pendingSince = Date()
        arm()
    }

    /// 开关变了要重算：关掉彻底撤表；打开时若还有没传出去的改动，补一轮
    /// （启动时也走这里，所以关机前最后那几笔改动不会一直躺在本地）。
    func reschedule() {
        timer?.invalidate()
        timer = nil
        pendingSince = nil
        guard settings.webdavAutoBackup, hasChanges else { return }
        pendingSince = Date()
        arm()
    }

    private func arm() {
        timer?.invalidate()
        timer = nil
        guard let since = pendingSince else { return }
        let t = Timer(fire: since.addingTimeInterval(Self.quietPeriod),
                      interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.firePendingBackup() }
        }
        // 差 10 秒无感，给系统一次把它和别的定时工作合并进同一轮唤醒的机会。
        // .common 而不是默认的 .default：拖窗口、滚列表时这张表不会被挂起。
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func firePendingBackup() async {
        timer = nil
        pendingSince = nil
        // 手动操作（测连接、刷新列表）正占着网络：让路，一分钟后再来
        guard busy == nil else { noteChanged(); return }
        // 低电量不为备份叫醒网卡。这只是本地判断，不碰网络也不敲钥匙串
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            if status != Self.lowPowerNote { status = Self.lowPowerNote }
            noteChanged()
            return
        }
        // 中途被「立即备份」抢先传掉了，这一轮就不用再动
        guard hasChanges else { return }
        // 传失败不自动重试：断网时每分钟敲一次坚果云没有意义，错误已经写在状态里，
        // 下一次改动会重新起表。只有传成功、而这一分钟里用户又动了，才接着排下一轮。
        if await backup(silent: true), hasChanges { noteChanged() }
    }

    private static let lowPowerNote = "低电量模式，自动备份已顺延"

    // MARK: 状态

    private func running(_ label: String, silent: Bool = false, _ work: () async throws -> Void) async {
        guard busy == nil else { return }   // 定时器撞上手动操作时直接放弃这一轮
        busy = label
        defer { busy = nil }
        do {
            try await work()
        } catch {
            let reason = error.localizedDescription
            if silent {
                report("自动备份失败：\(reason)", error: true)
            } else {
                report(reason, error: true)
            }
        }
    }

    private func report(_ text: String, error: Bool) {
        status = text
        failed = error
    }
}
