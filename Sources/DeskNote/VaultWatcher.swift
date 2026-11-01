import Foundation
import CoreServices

/// 库目录的文件事件。用户在 Typora / Obsidian 里存一次盘，FSEvents 能报四五条
/// （写临时文件、rename、改属性），所以事件本身只负责「有事发生」，真正扫盘等 0.5 秒防抖。
///
/// 这一层故意单独成文件：`VaultSync.swift` 要保持只有 Foundation，
/// 这样同步引擎能在不带 SwiftUI、不带 AppKit 的测试里整条跑一遍。
@MainActor
final class VaultWatcher {
    static let shared = VaultWatcher()

    private var stream: FSEventStreamRef?
    private var debounce: Timer?
    private(set) var watching: URL?
    /// 13 之后 `FSEventStreamScheduleWithRunLoop` 已废弃，改用派发队列。
    /// 回调只负责「有事发生」，真正的活立刻 hop 回主 actor，所以这条队列不需要参与任何状态。
    private let queue = DispatchQueue(label: "local.desknote.app.vault-watcher", qos: .utility)

    /// 建库之后、换库目录之后都要重新挂一次
    func restart() {
        stop()
        guard let root = VaultSync.activeRoot() else { return }
        watching = root
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let paths = [root.path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, vaultWatcherCallback, &context, paths,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                0.2, flags) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        debounce?.invalidate()
        debounce = nil
        pending = []
        missedEvents = false
        // 换库、停监听之后账就作废：留着下一轮会拿上一个库的 stat 判断新库的文件
        VaultSync.index.reset()
        guard let stream else { watching = nil; return }
        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watching = nil
    }

    /// 事件落在 `queue` 上，这里第一件事就是 hop 回主 actor，所以下面这几只笔（防抖、
    /// 路径缓冲、漏事件标记）都只有一只手在写。
    ///
    /// `paths` 是这一批事件涉及的文件。库内那两个点目录要剔掉：`.desknote/state.json` 是我们
    /// 自己每轮同步写出来的，`.obsidian/` 是 Obsidian 自己的记账（在它的窗口里点一下就会写），
    /// 而 `Vault.markdownFiles` 带 `.skipsHiddenFiles`，压根不扫这两处。留着它们，DeskNote
    /// 就是在追自己的尾巴：实测约 5 秒一圈，主线程整圈占在同步上。
    ///
    /// 剩下的路径原样交给同步层：它们是这一轮的「磁盘上哪儿变了」清单，
    /// 有了这份清单，同步就不必每 0.5 秒把整个库重走一遍。
    fileprivate func fired(paths: [String], forced: Bool) {
        let root = watching ?? URL(fileURLWithPath: "/")
        let useful = paths.filter { !VaultSync.isBookkeeping($0, root: root) }
        if forced {
            missedEvents = true
        } else if useful.isEmpty {
            return
        }
        pending.append(contentsOf: useful)
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in VaultWatcher.shared.consume() }
        }
    }

    /// 系统说过「事件我可能漏了，你自己补扫」——那一次的 stat 账就不能再信。
    private var missedEvents = false
    /// 防抖窗口里攒下来的事件路径
    private var pending: [String] = []

    private func consume() {
        guard let root = watching, VaultSync.activeRoot() == root else {
            pending = []
            missedEvents = false
            return
        }
        let paths = pending
        pending = []
        let full = missedEvents
        missedEvents = false
        // 我们自己写盘也会触发事件：那一轮 pull 里没有任何改动，report 就是 nil，界面不该闪。
        // 但「库里那份纯 Markdown 被 Finder 删了/移了」这一类的变动 pull 不会认（它只管 Store 记账），
        // 不能因为它返回 nil 就跳过 rescan——否则删掉的文件还挂在文件树里，对标 Obsidian 的实时性就破了。
        let report = Store.shared.pullFromVault(diskPaths: full ? nil : paths)
        LibraryModel.shared.rescan()
        if let report { LibraryModel.shared.notice = VaultSync.words(report) }
    }
}

private func vaultWatcherCallback(proxy: ConstFSEventStreamRef, contextInfo: UnsafeMutableRawPointer?,
                                  numEvents: Int, eventPaths: UnsafeMutableRawPointer,
                                  eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                                  eventIds: UnsafePointer<FSEventStreamEventId>) {
    guard let contextInfo else { return }
    let watcher = Unmanaged<VaultWatcher>.fromOpaque(contextInfo).takeUnretainedValue()
    // 建流时带了 kFSEventStreamCreateFlagUseCFTypes，所以 eventPaths 是一个 CFArray<CFString>；
    // 这里就地桥成 [String]，数组本身只在回调期间有效。
    let bridged = Unmanaged<AnyObject>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
    // 系统让我们自己补扫一次（漏事件、卷卸载重挂）时，路径列表可能是空的或没意义，必须放行
    var forced = false
    for index in 0..<numEvents where eventFlags[index] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
        forced = true
    }
    Task { @MainActor in watcher.fired(paths: bridged, forced: forced) }
}
