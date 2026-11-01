import SwiftUI
import AppKit
import ImageIO

/// The read-only renderer for a Markdown file in the library.
struct LibraryReader: View {
    let text: String
    /// 正文被换过几次（`LibraryDocument.revision`）。`.task(id:)` 用它，不用整串 `text`：
    /// 拿文本当 id，SwiftUI 每刷一帧都要做一遍整串比较——一篇 30 MB 的文档就是每帧比一次。
    let revision: Int
    /// 这一串正文的内容指纹，由拿着这批字节的那一方算好带过来（`ReaderCache` 的键）。
    /// nil 表示键盘改过、还没人哈希，那就轮到后台那一轮自己补一次。
    let contentHash: String?
    let fileURL: URL
    let rootURL: URL
    let fontSize: Double
    var onOpen: (String) -> Void
    @State private var readerSnapshot: ReaderSnapshot?

    /// 在飞的解析数。出图和自检要能等到「真的解析完了」再截：
    /// 占位画面当验收图，等于那张图什么都没测。
    @MainActor static private(set) var parsing = 0

    /// 单调计数：每开一篇文档（换文档或换正文）就 +1，后台解析完不回退。
    /// `parsing` 会增减、被取消后还可能留非零，拿它当「这一篇解析过几次」的标尺会说谎；
    /// 这一格只增不减，自检才能把「没解析」和「解析完了」两件事分清楚——
    /// 重开同一篇（path + revision 没变，`.task` 不重跑）增量停在 0，正是 A6 的 L2 真命中。
    @MainActor static private(set) var parseStarted = 0

    init(text: String, revision: Int = 0, contentHash: String? = nil, fileURL: URL, rootURL: URL,
         fontSize: Double, onOpen: @escaping (String) -> Void) {
        self.text = text
        self.revision = revision
        self.contentHash = contentHash
        self.fileURL = fileURL
        self.rootURL = rootURL
        self.fontSize = fontSize
        self.onOpen = onOpen
        _readerSnapshot = State(initialValue: nil)
    }

    var body: some View {
        // 重解析期间继续画上一版，不再整页闪成占位。换文档（路径不同）不画别人家的内容，
        // 那比转个圈更糟，所以只有同一篇的新版本才留着旧画面。
        let shown = readerSnapshot.flatMap { $0.path == fileURL.path ? $0 : nil }
        VStack(alignment: .leading, spacing: fontSize * 0.45) {
            // 空判用 allSatisfy：它遇到第一个非空白字符就退出，正常文档只走一格。
            // 以前这里是整串 trimmingCharacters，每帧一次，为的是省一次解析——省错了地方。
            if text.allSatisfy({ $0.isWhitespace }) {
                Text("这篇文档还是空的")
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.metaInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let shown {
                ForEach(shown.items) { item in
                    switch item.content {
                    case .markdown(let source):
                        NoteBodyView(text: source, fontSize: fontSize)
                    case .table(let rows, let alignments):
                        table(rows, alignments: alignments)
                    case .image(let alt, let destination, let width, let dataCacheKey):
                        image(alt: alt, destination: destination, width: width, dataCacheKey: dataCacheKey)
                    }
                }
            } else {
                Text("正在读取文档…")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(Color.metaInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme?.lowercased() == "desknote" {
                guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
                      query.hasPrefix("target=") else { return .discarded }
                // The workspace resolver decodes this once; retain percent escapes here so a
                // literal percent sequence in a filename is not decoded twice.
                onOpen(String(query.dropFirst("target=".count)))
                return .handled
            }
            if let target = relativeMarkdownTarget(url) {
                onOpen(target)
                return .handled
            }
            if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
                return .systemAction
            }
            return .systemAction
        })
        .task(id: ReaderTaskKey(path: fileURL.path, revision: revision)) {
            let source = text
            let knownHash = contentHash
            // 进后台之前先记一笔：这篇文档「被请求解析」过。只增不减，于是即便后台那一轮
            // 被取消、parsing 没归零，这一格也照实说——A8 自检靠它区分「没解析」和「解析完」。
            Self.parseStarted += 1
            Self.parsing += 1
            defer { Self.parsing -= 1 }
            let items = await ReaderCache.load(text: source, knownHash: knownHash)
            // 被下一轮取消的那次不画：留在屏幕上的得是完整的一版。
            guard !Task.isCancelled, let items else { return }
            readerSnapshot = ReaderSnapshot(path: fileURL.path, revision: revision, items: items)
        }
    }

    @ViewBuilder
    private func table(_ rows: [[String]], alignments: [CellAlignment]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: fontSize * 0.9, verticalSpacing: fontSize * 0.45) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                            Text(MarkdownText.inline(ReaderParse.wikiLinks(in: cell)))
                                .font(.system(size: fontSize, weight: rowIndex == 0 ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: alignments[safe: columnIndex]?.swiftUI ?? .leading)
                                .padding(.vertical, rowIndex == 0 ? 5 : 2)
                                .overlay(alignment: .bottom) {
                                    if rowIndex == 0 { Divider().opacity(0.55) }
                                }
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 3)
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder
    private func image(alt: String, destination: String, width: Int?, dataCacheKey: String?) -> some View {
        if let url = remoteURL(destination) {
            remoteImage(url: url, alt: alt, width: width)
        } else if let image = cachedImage(at: destination, dataCacheKey: dataCacheKey) {
            VStack(alignment: .leading, spacing: 4) {
                renderedImage(image, requestedWidth: width)
                if !alt.isEmpty {
                    Text(alt).font(.system(size: fontSize - 2)).foregroundStyle(Color.metaInk).lineLimit(2)
                }
            }
        } else {
            Label("图片无法显示", systemImage: "photo")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(Color.metaInk)
        }
    }

    /// 外链（http/https）图片：原生阅读器直接下载并显示，而不是只摆一条链接。
    /// 这是「允许外链图显示」方案在原生物理上的落点——WebView 富阅读器走 CSP 放行，
    /// 原生阅读器（本函数）走真实下载，两条路径都覆盖。
    /// 用带超时的 `URLSession` 下载，避免 `AsyncImage` 在 CDN 慢 / 被墙 / 断网时无限转圈；
    /// 失败或超时退回可点击链接，行为不比之前差。
    @ViewBuilder
    private func remoteImage(url: URL, alt: String, width: Int?) -> some View {
        let initial = width.map { CGFloat(min(max($0, 60), 720)) } ?? 480
        VStack(alignment: .leading, spacing: 4) {
            ResizableImageFrame(initialWidth: initial) {
                RemoteImageView(url: url, fontSize: fontSize)
            }
            if !alt.isEmpty {
                Text(alt).font(.system(size: fontSize - 2)).foregroundStyle(Color.metaInk).lineLimit(2)
            }
        }
    }

    /// 外链图片下载器：带请求/资源超时，失败或超时回退为可点击链接。
    /// 解码在后台线程做（不挡主线程），完成后再切回主线程更新 @State；
    /// `URLCache` 复用系统 HTTP 缓存，翻回同一篇不重复搬。
    private struct RemoteImageView: View {
        let url: URL
        let fontSize: Double
        @State private var phase: Phase = .loading
        private enum Phase { case loading, image(NSImage), failed }

        private static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
            config.requestCachePolicy = .returnCacheDataElseLoad
            return URLSession(configuration: config)
        }()

        private static let maximumBytes = 32 * 1024 * 1024

        var body: some View {
            Group {
                switch phase {
                case .loading:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                case .image(let img):
                    Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 520)
                case .failed:
                    Link(url.absoluteString, destination: url)
                        .font(.system(size: fontSize - 1))
                        .foregroundStyle(Color.metaInk)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .task { start() }
        }

        private func start() {
            guard case .loading = phase else { return }
            let task = Self.session.dataTask(with: url) { data, _, error in
                guard case .loading = self.phase else { return }
                if let data, data.count <= Self.maximumBytes, error == nil, let img = NSImage(data: data) {
                    Task { @MainActor in self.phase = .image(img) }
                } else {
                    Task { @MainActor in self.phase = .failed }
                }
            }
            task.resume()
        }
    }

    @ViewBuilder
    private func renderedImage(_ nsImage: NSImage, requestedWidth: Int?) -> some View {
        let initial = requestedWidth.map { CGFloat(min(max($0, 60), 720)) } ?? 480
        ResizableImageFrame(initialWidth: initial) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 520)
        }
    }

    private func remoteURL(_ destination: String) -> URL? {
        if destination.hasPrefix("//") { return URL(string: "https:\(destination)") }
        guard let url = URL(string: destination),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func cachedImage(at destination: String, dataCacheKey: String?) -> NSImage? {
        let isDataURI = destination.lowercased().hasPrefix("data:")
        let localURL = isDataURI ? nil : safeLocalImageURL(destination)
        guard isDataURI || localURL != nil else { return nil }

        let key: String
        if isDataURI {
            // The digest is computed once while parsing, rather than re-hashing base64 on redraw.
            guard destination.utf8.count <= ReaderParse.maximumDataURIBytes, let dataCacheKey else { return nil }
            key = "data:\(dataCacheKey)"
        } else if let localURL {
            let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            key = "file:\(localURL.path)|\(size)|\(modified)"
        } else {
            return nil
        }
        let cacheKey = key as NSString
        if let cached = ReaderImageCache.images.object(forKey: cacheKey) { return cached.image }

        let image: NSImage?
        if isDataURI {
            image = Self.decodeDataURI(destination)
        } else if let localURL {
            image = Self.decodeLocalImage(localURL)
        } else {
            image = nil
        }
        let entry = CachedReaderImage(image: image)
        let cost = image.map { Int(min($0.size.width * $0.size.height * 4, CGFloat(Int.max))) } ?? 1
        ReaderImageCache.images.setObject(entry, forKey: cacheKey, cost: cost)
        return image
    }

    /// Resolve a relative image and reject paths (including symlinks) that leave the library.
    func safeLocalImageURL(_ destination: String) -> URL? {
        guard !destination.isEmpty,
              !destination.hasPrefix("/"), !destination.hasPrefix("\\"),
              destination.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil else { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let documentFolder = fileURL.deletingLastPathComponent()
        return checkedLibraryImageURL(decoded, relativeTo: documentFolder, root: root)
            ?? checkedLibraryImageURL(decoded, relativeTo: root, root: root)
    }

    private func checkedLibraryImageURL(_ path: String, relativeTo folder: URL, root: URL) -> URL? {
        let candidate = folder.appendingPathComponent(path)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static let maximumImageFileBytes = 48 * 1024 * 1024

    private static func decodeDataURI(_ uri: String) -> NSImage? {
        guard uri.utf8.count <= ReaderParse.maximumDataURIBytes,
              let comma = uri.firstIndex(of: ",") else { return nil }
        let metadata = uri[..<comma].lowercased()
        let allowedMIMEs: Set<String> = ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"]
        guard allowedMIMEs.contains(metadata) else { return nil }
        let payload = uri[uri.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload)), data.count <= 24 * 1024 * 1024 else { return nil }
        return thumbnailImage(from: data)
    }

    private static func decodeLocalImage(_ url: URL) -> NSImage? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumImageFileBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return thumbnailImage(from: data)
    }

    private static func thumbnailImage(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 50_000, height <= 50_000,
              width * height <= 48_000_000 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 解析本身搬到了 `ReaderParse`（那个文件不带 SwiftUI/AppKit，回归测试层才链得进去）。
    /// 这层留一个同名转发：断言写在视图文件这一头，改解析的人第一眼就会碰到。
    nonisolated static func parse(_ text: String) -> [ReaderItem] {
        ReaderParse.parse(text) ?? []
    }

    private func relativeMarkdownTarget(_ url: URL) -> String? {
        guard url.scheme == nil, url.pathExtension.lowercased() == "md",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.percentEncodedPath
        // Markdown destinations are relative to this document. A leading slash in the URL
        // representation is a URL path marker, not a request to open from the filesystem root.
        if path.hasPrefix("/") { path.removeFirst() }
        if let fragment = components.percentEncodedFragment {
            path += "#\(fragment)"
        }
        return path
    }
}

extension CellAlignment {
    var swiftUI: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// 画在屏幕上的那一版。记的是「哪一篇、第几版正文」，不是整串文本：
/// 比整串是每帧一次的 O(n)，而这两格就够判「手上有的是不是眼前这篇的当前正文」。
private struct ReaderSnapshot: Sendable {
    let path: String
    let revision: Int
    let items: [ReaderItem]
}

/// `.task(id:)` 的键：换文档或换正文都会让它变，其余的刷新都不会。
private struct ReaderTaskKey: Equatable {
    let path: String
    let revision: Int
}

private final class CachedReaderImage: NSObject {
    let image: NSImage?
    init(image: NSImage?) { self.image = image }
}

private enum ReaderImageCache {
    static let images: NSCache<NSString, CachedReaderImage> = {
        let cache = NSCache<NSString, CachedReaderImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 预览里图片可拖右下角手柄缩放宽度（临时，不写回 Markdown 源）。
/// 外框宽度由 @State 维护：拖右下角手柄时按水平位移调整；重新渲染该图时回到默认宽度。
/// 图片按 `scaledToFit` 随宽度等比缩放，高度封顶 maxHeight（在内容闭包里定）。
private struct ResizableImageFrame<Content: View>: View {
    @State private var width: CGFloat
    private let minWidth: CGFloat = 60
    private let maxWidth: CGFloat = 720
    @State private var hovered = false
    @ViewBuilder private let content: () -> Content

    init(initialWidth: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        _width = State(initialValue: initialWidth)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .opacity(hovered ? 1 : 0.55)
                    .help("拖拽右下角缩放图片宽度")
                    .gesture(DragGesture().onChanged { value in
                        width = min(maxWidth, max(minWidth, width + value.translation.width))
                    })
            }
            .frame(width: min(maxWidth, max(minWidth, width)))
        }
        .frame(width: min(maxWidth, max(minWidth, width)), alignment: .leading)
        .onHover { hovered = $0 }
    }
}
