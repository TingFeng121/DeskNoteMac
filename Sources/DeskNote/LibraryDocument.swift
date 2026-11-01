import AppKit
import Observation

@Observable
final class LibraryDocument {
    static let shared = LibraryDocument()
    private(set) var url: URL?
    private(set) var root: URL?
    var text = ""
    private(set) var snapshot = LibraryFiles.Snapshot("")
    var error: String?
    var notice: String?
    /// 正文被换过几次。阅读层拿它当 `.task(id:)` 的一半：
    /// 直接拿 `text` 当 id，SwiftUI 每刷一帧都要整串比一遍，30 MB 的文档一帧付一次。
    private(set) var revision = 0
    /// 眼前这串正文的指纹。读到/写到的那一刻算得出，键盘改过就是 nil——
    /// 宁可让后台补算一次哈希，也不拿「上一版的指纹」去认现在这一串字。
    private(set) var contentHash: String?
    /// 大文档正在后台装载。装载期间磁盘基线还没到，键盘一律进不来（见 `edited()`）：
    /// 那几毫秒里写下去的是空正文，会把这篇的真内容顶掉。
    private(set) var loading = false
    /// 状态栏那两个数。存成一格而不是每帧现算：`text.count` 和数一遍换行都是 O(n)，
    /// 以前刷一帧付一次，连滚动都在扫整篇。打字时它跟着防抖那一拍更新——
    /// 那个定时器每次敲键都重新起算，所以只有停下来 0.6 秒才真扫一遍，慢半拍比卡半拍便宜。
    private(set) var charCount = 0
    private(set) var lineCount = 0
    /// 有没有没落盘的改动。同样存一格：以前每次问都要拿整串正文和磁盘那一份比一遍。
    private(set) var dirty = false
    /// 上一次真读过/写过的那份磁盘指纹。它和现在一模一样就说明磁盘上还是我们知道的字节，
    /// refresh() 于是可以一个字节都不读——不然「存盘 → 重扫 → 整篇再读一遍」这条尾巴
    /// 就留在打字的路径上，每 0.6 秒付一次。
    private var stamp: FileStamp?
    /// 自检用：存盘之后、重扫之后那两处「再读一整篇」的计数。
    /// 闸门有没有生效，从外面看是看不见的（读回来的字节一模一样），只有数着才对得上账。
    private(set) var rereads = 0
    /// 同上，数「大文档走后台装载」这条路走没走。
    private(set) var asyncLoads = 0
    private var timer: Timer?
    var mode = AppEnv.defaults.string(forKey: "libraryDocumentMode") ?? "read" {
        didSet { AppEnv.defaults.set(mode, forKey: "libraryDocumentMode") }
    }

    @discardableResult
    func open(_ url: URL, root: URL) -> Bool {
        if self.url == url { refresh(); return true }
        guard save() else { return false }
        do {
            try LibraryFiles.validate(url, root: root)
            self.root = root
            self.url = url
            self.error = nil
            // 整篇进内存之前先问一次 stat：它超过同步限额就别在主线程读了。
            // 这一格从 0 起也算一次「换正文」：上一版画面不该留在这一篇上。
            if let size = FileStamp(url)?.size, size > ReaderCache.synchronousLoadLimit {
                loadAsync(url: url)
                return true
            }
            let raw = try String(contentsOf: url, encoding: .utf8)
            loading = false
            snapshot = LibraryFiles.Snapshot(raw)
            replace(with: snapshot.body, hash: ReaderParse.digest(snapshot.body))
            stamp = FileStamp(url)
            return true
        } catch { self.error = "无法打开：\(error.localizedDescription)"; return false }
    }
    func edited(_ value: String) {
        guard !loading else { return }
        text = value
        contentHash = nil
        revision += 1
        markDirty()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            // 停手之后才扫这一遍整串：字数/行数慢半拍，换界面每一帧都不再扫。
            self?.recount()
            _ = self?.save()
        }
    }
    @discardableResult
    func save() -> Bool {
        timer?.invalidate()
        timer = nil
        // 装载中的那串空正文不是用户的编辑，写下去就是把这篇抹了。
        guard !loading, dirty, let url, let root else { return true }
        // Flush pending sticky-note edits before comparing the disk baseline.
        Store.shared.flush()
        do {
            let outcome = try LibraryFiles.save(body: text, snapshot: snapshot, url: url, root: root)
            switch outcome {
            case .original:
                snapshot = LibraryFiles.Snapshot(snapshot.prefix + text)
                // 只报刚写的这一条路径。默认那个 nil 是「整库重走」，留给冷启动、换库和漏事件；
                // 用户在编辑器里每 0.6 秒存一次盘，每次都走一遍全库就是「还是好卡」。
                let report = Store.shared.pullFromVault(diskPaths: [url.path])
                // 同步可能把托管元数据规范化写回磁盘；只有它真的动过笔，才值得再读一整篇回来。
                if let report, report.written > 0,
                   let raw = try? String(contentsOf: url, encoding: .utf8),
                   LibraryFiles.Snapshot(raw).body == text {
                    rereads += 1
                    snapshot = LibraryFiles.Snapshot(raw)
                }
            case .conflict(let copy):
                self.url = copy
                snapshot = LibraryFiles.Snapshot(snapshot.prefix + text)
                notice = "检测到外部改动，你的编辑已另存为「\(copy.lastPathComponent)」，原文件保留。"
            }
            stamp = self.url.flatMap(FileStamp.init)
            error = nil
            markDirty()
            LibraryModel.shared.rescan()
            return true
        } catch {
            self.error = "保存失败，编辑仍保留在这里：\(error.localizedDescription)"
            return false
        }
    }
    func refresh() {
        guard !loading, !dirty, let url else { return }
        let now = FileStamp(url)
        if now != nil, now == stamp { return }
        do {
            rereads += 1
            let raw = try String(contentsOf: url, encoding: .utf8)
            if raw != snapshot.raw {
                snapshot = LibraryFiles.Snapshot(raw)
                replace(with: snapshot.body, hash: ReaderParse.digest(snapshot.body))
            }
            stamp = now
            error = nil
        } catch { self.error = "文件已移动或暂时无法读取；当前内容仍保留，可修改后另存副本。" }
    }
    func relocated(from old: URL, to new: URL) {
        guard let current = url else { return }
        let resolved: URL
        if current == old {
            resolved = new
        } else if current.path.hasPrefix(old.path + "/") {
            resolved = new.appendingPathComponent(String(current.path.dropFirst(old.path.count + 1)))
        } else { return }
        self.url = resolved
        // 改名/挪目录保留 mtime 和大小，指纹照搬即可；不重记一次的话，
        // 下一轮 refresh() 会拿旧路径的 stat 去比新路径，白读一整篇。
        stamp = FileStamp(resolved)
        // 正文没动，contentHash 也就没动：它是「这串字」的指纹，跟路径无关。
        // 阅读层因此只是换了个 task id 重启一轮，回来在缓存里命中，一个字节都不重解析。
        if loading { loadAsync(url: resolved) }
    }

    /// 关掉当前文档（删文件/文件夹前调用）：清掉 url/text 等状态。
    /// 之后 `editorArea` 的守卫（url 不在 model.rows 里）会自动把编辑器收起来，
    /// 模型重扫后 `onChange(of: model.lastScan)` 会按上次的文档或第一篇重新选一篇。
    func close() {
        timer?.invalidate(); timer = nil
        url = nil; root = nil
        text = ""; snapshot = LibraryFiles.Snapshot("")
        contentHash = nil; revision += 1
        charCount = 0; lineCount = 0; dirty = false
        loading = false; error = nil; notice = nil
    }

    /// 换正文只有一个入口：版本号、计数、脏判定在这儿一起动。
    /// 少一格的话，症状是阅读层拿着旧画面不撒手，或者状态栏说「已保存」而其实没有。
    private func replace(with body: String, hash: String?) {
        text = body
        contentHash = hash
        revision += 1
        recount()
        markDirty()
    }

    private func recount() {
        charCount = text.count
        var lines = 1
        for byte in text.utf8 where byte == 0x0A { lines += 1 }
        lineCount = lines
    }

    private func markDirty() {
        dirty = text != snapshot.body
    }

    /// 大文档的装载：字节、切好的前后缀、指纹都在后台那一轮取，回到主线程只做赋值。
    /// `Snapshot` 的构造要把整串切成 `[UInt8]` 走一遍 frontmatter，30 MB 上那是实打实的一趟拷贝，
    /// 所以只算一次、直接带回来，不在主线程再拆一遍。
    /// 中途换了文档/改了路径就由 `url == target` 这道闸判掉，慢一步回来的那一份不会覆盖眼前这篇。
    private func loadAsync(url target: URL) {
        loading = true
        asyncLoads += 1
        snapshot = LibraryFiles.Snapshot("")
        replace(with: "", hash: nil)
        Task.detached(priority: .userInitiated) {
            let loaded = (try? String(contentsOf: target, encoding: .utf8)).map(LibraryFiles.Snapshot.init)
            let hash = loaded.map { ReaderParse.digest($0.body) }
            await MainActor.run {
                guard self.loading, self.url == target else { return }
                // 读不上来也要把装载这一格放掉，不然界面永远停在「正在装载」，编辑器也开不出来。
                guard let loaded else {
                    self.loading = false
                    self.error = "文件已移动或暂时无法读取；当前内容仍保留，可修改后另存副本。"
                    return
                }
                self.loading = false
                self.snapshot = loaded
                self.replace(with: loaded.body, hash: hash)
                self.stamp = FileStamp(target)
                self.error = nil
            }
        }
    }
}
