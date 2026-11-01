import Foundation

/// 阅读层的解析缓存：**内容哈希 → 解析结果**。
///
/// 键取内容哈希而不是路径，为的是那条免费收益——改名、移动、重开同一篇，字节没动过就不必再解析。
/// 哈希由「手上正拿着这批字节」的那一方算：`LibraryDocument` 读盘成功那一刻算一次
/// （那时整串已经在内存里，多走一趟 SHA-256 比之后再单独读一遍便宜），带进阅读层当键。
/// 键盘改过正文就把键置 nil，阅读层在后台自己补一次——绝不拿「上一版正文的哈希」去认现在这一串字。
///
/// 用 `NSCache` 不用 `Dictionary`：字典就是把 512 MB 的库变成常驻 RAM 的那只手。
/// 条目要能在系统认为吃紧时被丢掉，代价是「没命中」得是一条正常而便宜的路径。
enum ReaderCache {
    /// 磁盘上超过这个字节数的文档不在主线程整篇读：一次 30 MB 的同步读加解码，
    /// 够把界面钉住几百毫秒，而用户只是点了一下文件名。
    static let synchronousLoadLimit = 2 * 1024 * 1024

    /// 一条条目最多按这么多字节留在缓存里。
    ///
    /// 带 Base64 内嵌图的那类文档，解析结果里就装着整串码——存进缓存等于把这篇的字节
    /// 从「正文」搬到「缓存」，什么都没省下，一条还能顶满限额把别的都挤出去。
    /// 所以这种条目干脆不存：下次开照样重解析，也就是缓存出现之前的行为，不亏。
    /// 另一条路（再开一个缓存专门放那串码）更糟：它一旦被丢掉，那张内嵌图就永远画不出来了。
    static let maximumEntryBytes = 6 * 1024 * 1024

    /// 自检要能证明「重开同一篇真的没再解析」。命中和落空各数一笔。
    /// 这两格跨线程自增，数的是量级而不是精确值——自检里跑的都是顺序场景。
    private(set) nonisolated(unsafe) static var hits = 0
    private(set) nonisolated(unsafe) static var misses = 0

    nonisolated(unsafe) private static let parsed: NSCache<NSString, CachedReaderItems> = {
        let cache = NSCache<NSString, CachedReaderItems>()
        cache.countLimit = 24
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    /// 只给自检：把计数摆回零点，别让上一条断言的余量算到下一条头上。
    static func resetCounters() { hits = 0; misses = 0 }

    /// 视图那一头的入口：哈希、查缓存、必要时后台解析，一次await 到底。
    ///
    /// 旗子这一格不能省。`Task.detached` **不继承**取消：外层 `.task` 被 SwiftUI 掐掉时
    /// 后台那一轮照样跑到头，于是连打快键会同时跑着 N 份整篇解析。
    /// `withTaskCancellationHandler` 就是把「外面取消了」这句话递给里面。
    static func load(text: String, knownHash: String?) async -> [ReaderItem]? {
        let flag = ReaderStopFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                resolve(text: text, knownHash: knownHash, shouldStop: { flag.shouldStop || Task.isCancelled })
            }.value
        } onCancel: {
            flag.stop()
        }
    }

    /// 阅读层唯一的入口。`knownHash` 是调用方带来的正文指纹，nil 就在这儿补算一次
    /// ——反正在后台线程，不在主线程；`shouldStop` 每 256 行查一次，取消了的半截结果不入库。
    static func resolve(text: String, knownHash: String?, shouldStop: () -> Bool = { false }) -> [ReaderItem]? {
        let hash = knownHash ?? ReaderParse.digest(text)
        if let hit = parsed.object(forKey: hash as NSString) {
            hits += 1
            return hit.items
        }
        guard let items = ReaderParse.parse(text, shouldStop: shouldStop) else { return nil }
        misses += 1
        // 按正文字节数计成本：解析结果里的散文和图片路径都从那一串切出来，量级就是它。
        let retained = text.utf8.count
        if retained <= maximumEntryBytes {
            parsed.setObject(CachedReaderItems(items), forKey: hash as NSString, cost: max(retained, 1))
        }
        return items
    }
}

/// `NSCache` 的值必须是 class；解析结果是个数组，包一层才谈得上「按字节计成本」。
final class CachedReaderItems {
    let items: [ReaderItem]
    init(_ items: [ReaderItem]) { self.items = items }
}

/// 一根只往一个方向倒的旗子：主线程那边 `stop()`，后台每 256 行读一次。
/// 加了锁是因为它天生跨线程；一次读一个 bool，摊到 256 行里连噪声都算不上。
final class ReaderStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
