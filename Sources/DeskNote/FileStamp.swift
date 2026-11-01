import Foundation

/// 文件除正文以外的全部：改期、字节数、creation 时间。
///
/// 判「这个文件我要不要再读一遍」用这三格就够了。读一遍是 O(文件大小)，stat 是 O(1)。
///
/// 单独一个文件是因为它有**两个**用户：同步层（`VaultSync.VaultIndex`）和库页扫描
/// （`LibraryScan`）。合在 `VaultSync.swift` 里，库页那一层就跟着 `AppEnv` 一起出不去，
/// 回归测试跑不动——而它俩必须用同一个口径，一个库不该记两本 stat。
///
/// `created` 这一格的作用要说准：`String.write(atomically: true)` 确实换 inode（同步层 §23 量的），
/// 但它把原文件的出生时间一并贴回去了，于是这一格在那种存盘上什么也没记到。
/// 真正只剩「mtime + size」两格在用，`created` 防的是**不带属性拷贝**的那类改名/替换
/// （`mv`、`rsync` 换文件、别的库同步下来的那份）。
/// 两种都盖不住的是「等长覆写 + 把 mtime 贴回原样」：三格全不动而正文动了。
/// 这一层不试图靠猜补上——漏事件时由 `sync(diskPaths: nil)` 整库重读一遍哈希兜住，
/// 那条路是 O(全库)，所以它只在系统自己说「我可能漏了」的时候走。
///
/// 时间只取到整毫秒。`timeIntervalSinceReferenceDate` 是 Double，放到今天这个量级上，
/// 一次「贴回原时间再读出来」的往返（`touch -r`、rsync、`setAttributes`）就会在第 7 位
/// 小数上对不上。拿它当相等判据，等于把没动的文件读成动了的，闸门白装——
/// Obsidian 的 `Math.round(e.mtimeMs)` 是同一个取舍：文件系统给不了比毫秒更细的承诺。
struct FileStamp: Codable, Equatable {
    var modified: Double
    var size: Int
    var created: Double

    init?(_ url: URL) {
        // 不走 `url.resourceValues(forKeys:)`：那个结果缓存在 NSURL 实例上。
        // 库文档把 URL 存在 `document.url` 里、每次存盘都拿同一个对象来问指纹，
        // 于是问回来的还是第一次那一份字节数——闸门永远「没变」，整篇永远不重读。
        // `stat` 一次系统调用，没有缓存，也不用起 CF 那套属性字典。
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ rep in rep != nil && stat(rep, &info) == 0 }) else {
            return nil
        }
        size = Int(info.st_size)
        modified = FileStamp.ms(FileStamp.epoch(info.st_mtimespec))
        created = FileStamp.ms(FileStamp.epoch(info.st_birthtimespec))
    }

    /// `timespec` 是「公元」秒；换成这个项目的统一坐标（参考日期、整毫秒）。
    private static func epoch(_ time: timespec) -> Double {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
            .timeIntervalSinceReferenceDate
    }

    /// 演示和回归测试要能凭空造一个「上一次看到的样子」。`created` 不参与库页扫描的变更判定，
    /// 给 0 就行；两个时间都走同一个整毫秒闸门，免得凭空造的跟真读出来的对不上。
    init(modified: Double, size: Int, created: Double = 0) {
        self.modified = FileStamp.ms(modified)
        self.size = size
        self.created = FileStamp.ms(created)
    }

    /// 「更新」那一列要的日期，从同一个字段来，不再另算一份。
    var date: Date { Date(timeIntervalSinceReferenceDate: modified) }

    /// 库页扫描的闸门：只比 mtime + size。`created` 是同步层用来认「原子写换了 inode」的，
    /// 而演示摆的基线和冷启动第一次见到的那份都没有可靠的历史 ctime 可比——
    /// 拿整份 `==` 去判，第一次开库就满屏标成「磁盘改动」。
    func contentMatches(_ other: FileStamp) -> Bool {
        modified == other.modified && size == other.size
    }

    private static func ms(_ time: Double) -> Double { (time * 1000).rounded() / 1000 }
}
