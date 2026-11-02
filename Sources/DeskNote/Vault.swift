import Foundation
import CryptoKit

/// Markdown 文件库（vault）。磁盘上就是一堆普通 .md，Obsidian/Typora 能直接打开：
///
///     <vault>/notes/<首行>.md             一张便签一个文件（统一收进 notes/，和库里真文档分干净，文件名不带哈希）
///     <vault>/<类别>/<项目>.md           待办板，一个项目一个文件，事项就是 `- [ ] 标题`
///     <vault>/.desknote/                  排序、窗口位置这类本地状态（可重建，不是真相）
///
/// 身份只认 frontmatter 里的 `desknote.id`，不认文件名：用户在 Finder 或 Obsidian 里改名、
/// 挪目录之后，只有 id 能把文件重新对回那张便签。
enum Vault {
    static let formatVersion = 1
    static let hiddenDir = ".desknote"

    // MARK: 文件命名

    /// 路径分隔、Windows 保留符号、控制字符一律不许进文件名。
    /// 库目录随时可能被丢进 iCloud Drive（会同步到 Windows），所以按最严的那套来。
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
    private static let windowsReserved: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// 标题 → 文件名主干。截断按 Character 而不是字节，中文标题六个字就占 18 字节。
    /// 中间的点留着（`v1.2` 是好名字），只有首尾的点必须去掉——开头是隐藏文件，结尾 Windows 吃掉。
    static func slug(_ title: String, maxChars: Int = 24) -> String {
        let flattened = title
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let kept = String(flattened.unicodeScalars.filter { scalar in
            scalar >= " " && !illegal.contains(scalar) && !scalar.properties.isDefaultIgnorableCodePoint
        }.prefix(400))
        var out = String(kept.prefix(maxChars)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if out.isEmpty || windowsReserved.contains(out.uppercased()) { out = "无标题" }
        return out
    }

    /// 便签文件路径。便签统一收进 `<vault>/notes/` 子文件夹——和库里真正的文档分干净，
    /// 又能在文件树里以一个普通文件夹的方式原样展示。文件夹名用 ASCII「notes」，任何地方
    /// 都不会被百分号编码（用户要的"不需要编码"）。文件名只用标题（`slug` 后的干净名），
    /// 不带任何哈希——身份靠 frontmatter 里的 `desknote.id` 认，不靠文件名。同名撞车时
    /// （两张便签首行一样）加数字序号 `-2`、`-3`——绝不能让一张便签把另一张覆盖掉。
    static func noteURL(_ root: URL, title: String, id: UUID, taken: Set<String> = []) -> URL {
        let dir = root.appendingPathComponent("notes", isDirectory: true)
        let stem = slug(title)
        var name = "\(stem).md"
        var n = 2
        while taken.contains(name) {
            name = "\(stem)-\(n).md"
            n += 1
        }
        return dir.appendingPathComponent(name)
    }

    static func projectURL(_ root: URL, category: String, project: String, id: UUID) -> URL {
        root.appendingPathComponent(slug(category))
            .appendingPathComponent("\(slug(project)).md")
    }

    /// 冲突文件：两边都改过又不肯互相覆盖时，磁盘那份另存一份，谁都不许悄悄丢。
    static func conflictURL(_ url: URL) -> URL {
        url.deletingPathExtension()
            .appendingPathExtension("\(conflictMarker)\(conflictStamp.string(from: Date()))")
            .appendingPathExtension("md")
    }

    /// 冲突副本的识别标记。副本带的是同一个 `desknote.id`，同步层要把它排除掉，
    /// 否则下一轮认身份时副本会盖住正文那一份，两边来回打架。
    static let conflictMarker = "冲突 "
    static func isConflict(_ url: URL) -> Bool { url.lastPathComponent.contains(conflictMarker) }

    /// 时间戳里的冒号在 Windows 是非法字符，用点分
    private static let conflictStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: frontmatter

    /// frontmatter 分成「我们那段」和「原样透传的其他行」。透传行一个字都不改，
    /// 这样在 Obsidian 里加的 tags/aliases 被 DeskNote 写一次不会蒸发。
    struct Frontmatter: Equatable {
        var passthrough: [String] = []
        var values: [String: String] = [:]

        subscript(key: String) -> String? {
            get { values[key] }
            set {
                if let newValue { values[key] = newValue } else { values.removeValue(forKey: key) }
            }
        }

        var uuid: UUID? { values["id"].flatMap(UUID.init) }
        func intValue(_ key: String) -> Int? { values[key].flatMap(Int.init) }
        func dateValue(_ key: String) -> Date? { values[key].flatMap(Vault.dateValue) }
    }

    /// 手改 frontmatter 时人只会打 `2026-11-01`，别让「解析失败」把字段整个吃掉
    static func dateValue(_ text: String) -> Date? {
        if let d = iso.date(from: text) { return d }
        return dayOnly.date(from: text)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func stamp(_ date: Date) -> String { iso.string(from: date) }

    /// 📅 日期的读写共用这一个格式化器：外部编辑器写的 `2026-11-02` 要能原样读回同一天。
    /// 历法必须钉死公历——系统语言设成中文时 `Locale.current` 的 calendar 可能是佛历，
    /// 年份会整整差 543 年；`en_US_POSIX` 只锁了数字形式，不锁历法。
    static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 只认「第一行正好是 ---」的块；没闭合的 --- 当整个文件都是正文——
    /// 半截文件不该把用户的正文吞进元数据里。没有块的普通 md 也照样返回空 frontmatter，
    /// 调用方拿到的永远是「元数据 + 正文」两段，不必各自再判一次 nil。
    static func split(_ raw: String) -> (front: Frontmatter, body: String) {
        let lines = raw.components(separatedBy: "\n")
        var first = lines.first ?? ""
        if first.hasPrefix("\u{FEFF}") { first.removeFirst() }
        guard first == "---",
              let end = (1..<lines.count).first(where: { lines[$0] == "---" || lines[$0] == "..." }) else {
            return (Frontmatter(), takeBody(lines.joined(separator: "\n"), afterFence: false))
        }
        var front = Frontmatter()
        var mine = false
        for line in lines[1..<end] {
            if line.hasPrefix("desknote:") { mine = true; continue }
            // 只吃两格缩进的那层；三格往上属于别人家的嵌套结构，原样透传
            if mine, line.hasPrefix("  "), !line.hasPrefix("   ") {
                let pair = String(line.dropFirst(2))
                if let colon = pair.firstIndex(of: ":") {
                    let key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { front.values[key] = value }
                }
                continue
            }
            mine = false
            front.passthrough.append(line)
        }
        return (front, takeBody(lines[(end + 1)...].joined(separator: "\n"), afterFence: true))
    }

    /// render 在闭合的 --- 之后多打了一个空行，读回来就恰好摘掉这一个（外加文件末尾那个换行）。
    /// 多一个都不能剥：正文里用户自己的空行一旦丢了，往返一次文件字节就变了，
    /// 外部同步会把它当成「外面又改了一遍」。
    private static func takeBody(_ joined: String, afterFence: Bool) -> String {
        var body = joined
        if afterFence, body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        return body
    }

    /// 键顺序固定：内容没变时字节也得没变，不然「按哈希判断自身写入」永远判不中
    private static let orderedKeys = ["id", "version", "color", "remind", "created", "updated", "category"]

    /// 项目文件由我们维护的那几个键，合并旧 frontmatter 时以新值为准
    private static let managedProjectKeys: Set<String> = ["id", "version", "category"]

    static func render(front: Frontmatter, body: String) -> String {
        // 正文进文件之前统一成 LF：外部编辑器（尤其从 Windows 同步回来的）常带 \r\n，
        // 留着它每次往返哈希都不同，会被同步器误判成「外部又改了一遍」
        let body = normalize(body)
        var out = "---\n"
        for line in front.passthrough { out += line + "\n" }
        if !front.values.isEmpty {
            out += "desknote:\n"
            for key in orderedKeys where front.values[key] != nil { out += "  \(key): \(front.values[key]!)\n" }
            for (key, value) in front.values.sorted(by: { $0.key < $1.key })
            where !orderedKeys.contains(key) { out += "  \(key): \(value)\n" }
        }
        out += "---\n"
        return body.isEmpty ? out : out + "\n" + body + "\n"
    }

    /// 读文件统一成 LF、去掉 BOM：外部编辑器（尤其从 Windows 同步回来的）常写 CRLF，
    /// 留着它每次往返都会把整篇哈希改掉，看着像「外面又改了一次」。
    static func normalize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: 便签文件

    static func writeNote(_ note: StickyNote, to url: URL) throws {
        var front = readFrontmatter(at: url) ?? Frontmatter()
        front["id"] = note.id.uuidString
        front["version"] = String(formatVersion)
        front["color"] = String(note.colorIndex)
        front["remind"] = note.remindAt.map(stamp)
        front["created"] = stamp(note.createdAt)
        front["updated"] = stamp(note.updatedAt)
        try write(render(front: front, body: note.text), to: url)
    }

    /// 只读 frontmatter，正文丢掉。改一张便签时要把用户自己写的属性带回去，不能整块重写。
    ///
    /// 只读文件头，不整篇读：frontmatter 一定在最前面，而真实库里正文塞了几 MB Base64 的便签很常见。
    /// 整篇读进来还要跑三遍全串替换（normalize 去 BOM / CRLF / CR），200 个文件一轮就是几十 MB 的
    /// 拷贝，而且这一轮跑在主线程上——这就是「库页点什么都卡」的直接原因。
    static func readFrontmatter(at url: URL) -> Frontmatter? {
        guard let head = readHead(of: url) else { return nil }
        let normalized = normalize(head)
        var first = normalized.components(separatedBy: "\n").first ?? ""
        if first.hasPrefix("\u{FEFF}") { first.removeFirst() }
        guard first == "---" else { return nil }   // 开头不是栅栏，后面再长也没有我们的属性
        let closed = normalized.components(separatedBy: "\n").dropFirst()
            .contains { $0 == "---" || $0 == "..." }
        guard closed else {
            // 64 KB 还没收尾 = 这份的 frontmatter 长得离谱。退回整篇读，别拿半截属性当准。
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return split(normalize(raw)).front
        }
        return split(normalized).front
    }

    /// 读文件头最多 `limit` 字节。截断可能落在一个 UTF-8 标量中间，所以从尾部最多退 3 个字节再试。
    static func readHead(of url: URL, limit: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), data.count > 0 else { return nil }
        for trim in 0...min(3, data.count) {
            if let text = String(data: data.prefix(data.count - trim), encoding: .utf8) { return text }
        }
        return nil
    }

    struct ParsedNote: Equatable {
        var id: UUID
        var note: StickyNote
        /// 陌生文件（没有 desknote.id）的身份是合成的，得靠路径记在 sidecar 里才认得回来
        var synthesizedID: Bool
    }

    static func readNote(at url: URL) -> ParsedNote? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = (try? String(contentsOf: url, encoding: .utf8)).map(normalize) ?? ""
        let parts = split(raw)
        let found = parts.front.uuid
        var front = parts.front
        let id = found ?? UUID()
        let fallback = fileMTime(url) ?? Date()
        var note = StickyNote(text: parts.body,
                              colorIndex: max(0, front.intValue("color") ?? 0),
                              remindAt: front.dateValue("remind"),
                              createdAt: front.dateValue("created") ?? fallback,
                              updatedAt: front.dateValue("updated") ?? fallback)
        note.id = id
        front["id"] = id.uuidString
        return ParsedNote(id: id, note: note, synthesizedID: found == nil)
    }

    private static func fileMTime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
    }

    // MARK: 项目文件（待办板）

    enum Line: Equatable {
        case item(DeskItem)
        /// 用户在 Obsidian 里往项目文件里加的说明、表头、空行——原样留着，不许当垃圾丢掉
        case text(String)
    }

    /// 事项行：`- [ ] 标题 📅 2026-11-02 <!-- id:6C1A2B3D-... -->`。
    /// 日期只到「天」是 Obsidian Tasks 的约定，具体时刻另存 sidecar，别在行里塞 ISO 串碍眼。
    /// 事项身份（item.id）放在行尾的 HTML 注释里——Obsidian 阅读模式不渲染 HTML 注释，
    /// 所以用户看不到这串 UUID；正则同时兼容旧的 `^UUID` 块引用写法，旧文件也能照常读回。
    private static let itemPattern = try! NSRegularExpression(
        pattern: #"^(\s*)-\s\[( |x|X)\]\s*(.*?)(?:\s*📅\s*(\d{4}-\d{2}-\d{2}))?(?:\s*(?:\^([0-9a-zA-Z-]{4,})|<!--\s*id:([0-9A-Fa-f-]{36})\s*-->))?\s*$"#)

    static func renderProject(id: UUID, category: String, lines: [Line]) -> String {
        var front = Frontmatter()
        front["id"] = id.uuidString
        front["version"] = String(formatVersion)
        front["category"] = category
        var body = ""
        for line in lines {
            switch line {
            case let .text(text): body += text + "\n"
            case let .item(item):
                // 标题里不许有换行：一行就是一个事项，漏个换行会把一条拆成两条，身份全丢
                let title = item.title
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                var out = "- [\(item.done ? "x" : " ")] \(title)"
                if let deadline = item.deadline { out += " 📅 \(dayOnly.string(from: deadline))" }
                out += " <!-- id:\(item.id.uuidString) -->"
                body += out + "\n"
            }
        }
        return render(front: front, body: body.isEmpty ? "" : String(body.dropLast()))
    }

    static func writeProject(id: UUID, category: String, lines: [Line], to url: URL) throws {
        let rendered = split(normalize(renderProject(id: id, category: category, lines: lines)))
        var front = rendered.front
        // 用户在 Obsidian 里往项目文件加的自有属性带回去；但我们管的几个键不许被旧值盖回来——
        // 项目换了类别，写出去还写着老类别，下次扫描就找不回它了。
        if let existing = readFrontmatter(at: url) {
            for (key, value) in existing.values where !managedProjectKeys.contains(key) { front[key] = value }
            front.passthrough = existing.passthrough
        }
        try write(render(front: front, body: rendered.body), to: url)
    }

    static func readProject(at url: URL) -> (id: UUID, category: String, lines: [Line])? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = split(normalize(raw))
        let front = parts.front
        guard let id = front.uuid else { return nil }
        var lines: [Line] = []
        for line in parts.body.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = itemPattern.firstMatch(in: line, range: range),
                  let title = group(3, of: line, in: match) else {
                lines.append(.text(line))
                continue
            }
            var item = DeskItem(title: title)
            item.done = (group(2, of: line, in: match) ?? " ").lowercased() == "x"
            if let day = group(4, of: line, in: match) { item.deadline = dayOnly.date(from: day) }
            if let anchor = (group(5, of: line, in: match) ?? group(6, of: line, in: match)), let uuid = UUID(uuidString: anchor) { item.id = uuid }
            lines.append(.item(item))
        }
        return (id, front["category"] ?? "", lines)
    }

    private static func group(_ n: Int, of line: String, in match: NSTextCheckingResult) -> String? {
        guard let r = Range(match.range(at: n), in: line) else { return nil }
        return String(line[r])
    }

    // MARK: 双链

    /// `[[目标]]`、`[[目标|显示名]]`、`[[目标#小节]]` 都认；`[[#小节]]`（同篇内跳）不认，
    /// 因为它不指向别的文件，算进反向链接会把一张便签变成自己的引用方。
    private static let wikiPattern = try! NSRegularExpression(
        pattern: #"\[\[([^\]\|#]+)(?:#[^\]\|]*)?(?:\|[^\]]*)?\]\]"#)

    struct WikiLink: Equatable {
        /// 原样写下的目标，显示与解析都从它来
        var raw: String
        /// 比对用的主干：去掉路径与 .md、忽略大小写
        var stem: String
        var range: NSRange
    }

    /// 逐个文件名的比对口径：`[[2026-10-28 设计评审]]` 要能对上
    /// `会议记录/2026-10-28 设计评审.md`，所以只认末段且不吃扩展名。
    static func stem(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        return ((base as NSString).deletingPathExtension).lowercased()
    }

    /// ``` 围栏之内不认双链：那是别人家的代码，不是本库的链接。
    static func wikiLinks(_ body: String) -> [WikiLink] {
        var out: [WikiLink] = []
        var insideFence = false
        var offset = 0
        for line in body.components(separatedBy: "\n") {
            let ns = line as NSString
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
            } else if !insideFence {
                let hits = wikiPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
                for m in hits {
                    let raw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    if raw.isEmpty { continue }
                    out.append(WikiLink(raw: raw, stem: stem(raw),
                                        range: NSRange(location: offset + m.range.location,
                                                       length: m.range.length)))
                }
            }
            offset += ns.length + 1
        }
        return out
    }

    /// 正文里第一个非空、非标题、不是列表行的段落，拿来做表格的预览与搜索命中行。
    static func excerpt(_ body: String, maxChars: Int = 90) -> String {
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("```") { continue }
            let clean = line
                .replacingOccurrences(of: #"^\s*[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\s*\d+\.\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "[[|]]", with: "", options: [.regularExpression, .caseInsensitive])
            if clean.isEmpty { continue }
            return clean.count <= maxChars ? clean : String(clean.prefix(maxChars)) + "…"
        }
        return ""
    }

    // MARK: 扫描与哈希

    /// 便签统一收进 notes/ 子文件夹，所以库里真正的文档（在类别文件夹里）和便签分得清清楚楚。
    /// 这里保留 "notes" 是为了让待办板的扫描（`scanProjects`）别把 notes/ 误认成一个「类别」；
    /// 文件树（`inventory`）和库页枚举（`markdownFiles`）都不套用 skipFolders，所以 notes/
    /// 会照常以一个普通文件夹出现在文件树里——这正是用户要的"单独一个文件夹展示"。
    static let skipFolders: Set<String> = [".desknote", ".git", ".obsidian", ".trash", "notes", "node_modules"]

    /// 文件 frontmatter 里有没有 DeskNote 的身份块——这是「这张 .md 是便签」的标记。
    /// 实际写法是 YAML 嵌套块（`desknote:` 顶层键，其下缩进的 `  id:` 才是 UUID），
    /// 不是字面的 `desknote.id:`。这个块是 DeskNote 写文件时特有的，用户真文档不会冒出来。
    /// 只在前 2048 字符（覆盖 frontmatter 足够）里找，避免整篇扫。
    static func hasNoteID(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---") else { return false }
        let head = String(text.prefix(2048))
        guard let end = head.range(of: "\n---") else { return false }
        let front = head[...end.lowerBound]
        return front.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "desknote:" })
    }

    /// 一次性迁移：把库根那一层的便签 .md（带 `desknote.id` frontmatter 的）搬进 notes/ 子文件夹。
    /// 幂等：库根没有便签文件时直接返回；搬完即空，不重复搬。只搬带 desknote.id 的，
    /// 绝不把用户真正的文档搬走。调用方随后跑一次全量对账（`VaultSync.sync(diskPaths:nil)`）
    /// 把 state.json 旧路径更正、索引重建。
    static func migrateNotesToFolder(_ root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let notes = items.filter { $0.pathExtension.lowercased() == "md" && !isHidden($0) && hasNoteID($0) }
        guard !notes.isEmpty else { return }
        let dir = root.appendingPathComponent("notes", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for item in notes {
            var target = dir.appendingPathComponent(item.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = dir.appendingPathComponent("\(item.deletingPathExtension().lastPathComponent)-\(n).md")
                n += 1
            }
            try? fm.moveItem(at: item, to: target)
        }
    }

    /// 便签收在 notes/ 子文件夹；这一份扫的就是 notes/ 里的 .md（不再铺在库根）。
    static func scanNotes(_ root: URL) -> [URL] {
        let dir = root.appendingPathComponent("notes", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "md" && !isHidden($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func scanProjects(_ root: URL) -> [URL] {
        let cats = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var out: [URL] = []
        for cat in cats.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cat.path, isDirectory: &isDir), isDir.boolValue,
                  !skipFolders.contains(cat.lastPathComponent) else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(at: cat, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "md" && !isHidden($0) } ?? []
            out += files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return out
    }

    static func isHidden(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix(".") }

    /// 库页的枚举：整个目录树里的 .md，一个不落（含 notes/ 里的便签）。
    /// 身份按 frontmatter 的 `desknote.id` 认成「便签」类型；
    /// 只躲开点开头的工作目录和 node_modules。
    static func markdownFiles(_ root: URL) -> [URL] {
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == "node_modules" {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 文件内容指纹。三方比对靠它判断「磁盘这份到底动没动」；
    /// 光看 mtime 不行：拷贝、iCloud 落盘、git checkout 都会改时间戳却不动内容。
    static func hash(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return hash(data)
    }

    static func hash(_ data: Data) -> String {
        // 逐字节 String(format: "%02x") 看着无害，实测占了这份哈希里九成多的时间：
        // 一次哈希 32 个字节、32 次格式调用，整库重读时这几千次调用就是几十毫秒。
        let digest = SHA256.hash(data: data)
        var out = ""
        out.reserveCapacity(64)          // SHA-256：32 字节，每字节两个十六进制位
        for byte in digest {
            out.append(hexChars[Int(byte) >> 4])
            out.append(hexChars[Int(byte) & 0x0f])
        }
        return out
    }

    private static let hexChars = Array("0123456789abcdef")

    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}
