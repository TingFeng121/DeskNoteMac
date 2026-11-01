import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

/// 阅读模式里那几篇「原生读者做不到」的文档：Mermaid、公式、脚注、`~~~` 围栏、原始 HTML、callout。
/// 它们交给本地打包好的 markdown-it + DOMPurify + highlight.js + KaTeX + mermaid 渲染。
///
/// 只读，只走 `file://` 和自定义 scheme：一次网络请求都不发，断网时和联网时一样。
/// 编辑与分屏不进这里——那两个模式下用户在打字。跨进程送一整篇正文、再挂起一个
/// WebContent 进程去重排，代价全落在「还是好卡」那本账上。
struct LibraryRichReader: View {
    let text: String
    /// 正文被换过几次（`LibraryDocument.revision`）。网页那侧靠它判「这一版送过没有」：
    /// 送一次要跨进程搬整篇正文，拿整串文本当比较键就是每帧搬一次。
    let revision: Int
    let fileURL: URL
    let rootURL: URL
    let fontSize: Double
    let dark: Bool
    let onOpen: (String) -> Void

    var body: some View {
        if RendererLocations.current == nil {
            // 资源没跟着装过来：退回原生读者，而不是一个白框。
            LibraryReader(text: text, revision: revision, fileURL: fileURL, rootURL: rootURL,
                          fontSize: fontSize, onOpen: onOpen)
        } else {
            RichReaderWebView(text: text, revision: revision, fileURL: fileURL, rootURL: rootURL,
                              fontSize: fontSize, dark: dark, onOpen: onOpen)
        }
    }

    // MARK: 这一篇要不要用网页读者

    /// 自检用：真跑了多少趟逐行扫描。这个判断挂在 `body` 上，闸门没生效就是界面每刷一帧扫一遍。
    @MainActor static private(set) var scans = 0

    /// 逐行扫一遍，命中任意一条就换网页读者。
    ///
    /// 不用七条正则：一篇 30 MB 的正文在正则上来回七趟是几百毫秒，而这个判断在 SwiftUI
    /// 的 body 里，界面刷一帧就付一次。判定写得比 `ReaderParse` 的真实能力**宽**一点：
    /// 多开一个网页进程是一次的开销，把 `$$x$$` 原样印在屏幕上是用户看得见的错。
    @MainActor static func isNeeded(_ text: String) -> Bool {
        scans += 1
        var fence: UInt8?
        for line in text.split(whereSeparator: \.isNewline) {
            let bytes = [UInt8](line.utf8)
            if let mark = fence {
                // 围栏里的那几行什么都不算；同字符的整行收尾。
                if let open = fenceMark(bytes), open.info.isEmpty, open.mark == mark { fence = nil }
                continue
            }
            if let open = fenceMark(bytes) {
                if open.mark == tilde { return true }              // 原生只认 ```
                if open.isMermaid { return true }
                fence = open.mark
                continue
            }
            if !hasAnyMarker(bytes) { continue }
            if firstIndex(bytes, dollar, dollar) != nil { return true }
            if inlineMath(bytes) { return true }
            if isHTMLBlock(bytes) { return true }
            if footnote(bytes) { return true }
            if callout(bytes) { return true }
        }
        return false
    }

    /// 绝大多数行什么标记都没有：一趟字节扫描把它们全挡掉，命中就早退。
    private static func hasAnyMarker(_ bytes: [UInt8]) -> Bool {
        for byte in bytes where byte == dollar || byte == lessThan || byte == caret || byte == bracket {
            return true
        }
        return false
    }

    /// 同一篇正文的同一版只扫一遍：`model.lastScan` 一变整个库页就重算，那时正文没动，
    /// 判断也不该跟着重算第二次。
    @MainActor private static var memo: (key: String, rich: Bool)?
    @MainActor static func isNeeded(text: String, revision: Int, path: String) -> Bool {
        let key = "\(path)#\(revision)"
        if let memo, memo.key == key { return memo.rich }
        let value = isNeeded(text)
        memo = (key, value)
        return value
    }

    private static let backtick: UInt8 = 0x60
    private static let tilde: UInt8 = 0x7E
    private static let dollar: UInt8 = 0x24
    private static let lessThan: UInt8 = 0x3C
    private static let caret: UInt8 = 0x5E
    private static let bracket: UInt8 = 0x5B
    private static let closeBracket: UInt8 = 0x5D
    private static let space: UInt8 = 0x20

    /// 行首的 ``` 或 ~~~：返回标记字符、信息串。信息串里带同一个字符的（```` 那种
    /// 加长闭合栏）也算整行闭合，不当开头看。
    private static func fenceMark(_ bytes: [UInt8]) -> (mark: UInt8, info: [UInt8], isMermaid: Bool)? {
        var index = 0
        while index < 3, index < bytes.count, bytes[index] == space { index += 1 }
        guard index < bytes.count, bytes[index] == backtick || bytes[index] == tilde else { return nil }
        let mark = bytes[index]
        var count = 0
        while index < bytes.count, bytes[index] == mark { index += 1; count += 1 }
        guard count >= 3 else { return nil }
        var info = Array(bytes[index...])
        while let last = info.last, last == space || last == 0x09 || last == 0x0D { info.removeLast() }
        if info.contains(mark) { return (mark, [], false) }
        let language = String(bytes: info.prefix { $0 != space && $0 != 0x09 }, encoding: .utf8) ?? ""
        return (mark, info, language.lowercased() == "mermaid")
    }

    /// 同一行里出现相邻的两个 `$$`：块级公式的开头，或单行写的 `$$x$$`。
    private static func firstIndex(_ bytes: [UInt8], _ first: UInt8, _ second: UInt8) -> Int? {
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == first, bytes[index + 1] == second { return index }
            index += 1
        }
        return nil
    }

    /// `$…$` 才算公式：开的 `$` 后面紧跟非空白，闭的 `$` 前面是非空白、后面不能是数字或 `$`。
    /// 「价格 $5 和 $10」靠这条留在原生读者——obsidian 也是这么判的。
    private static func inlineMath(_ bytes: [UInt8]) -> Bool {
        var index = 1
        while index < bytes.count {
            guard bytes[index] == dollar else { index += 1; continue }
            if bytes[index - 1] == 0x5C || bytes[index - 1] == dollar { index += 1; continue }
            guard index + 1 < bytes.count, !isHorizontalSpace(bytes[index + 1]) else {
                index += 2
                continue
            }
            var close = index + 2
            while close < bytes.count, bytes[close] != dollar { close += 1 }
            guard close < bytes.count else { return false }
            let before = bytes[close - 1]
            let after = close + 1 < bytes.count ? bytes[close + 1] : nil
            if !isHorizontalSpace(before), before != 0x5C, before != dollar,
               after != dollar, after.map({ !isDigit($0) }) ?? true {
                return true
            }
            index = close + 1
        }
        return false
    }

    private static func isHorizontalSpace(_ byte: UInt8) -> Bool {
        byte == space || byte == 0x09 || byte == 0x0B || byte == 0x0C
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static let htmlTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "details",
        "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "iframe", "legend", "li", "main",
        "menu", "nav", "ol", "p", "pre", "script", "section", "summary", "table", "tbody", "td",
        "th", "thead", "tr", "ul"
    ]

    /// 行首（缩进三格以内）的原始 HTML 块。原生读者会把 `<div>` 当普通字印出来。
    private static func isHTMLBlock(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < 3, index < bytes.count, bytes[index] == space { index += 1 }
        guard index < bytes.count, bytes[index] == lessThan else { return false }
        if bytes.count > index + 3, bytes[index + 1] == 0x21,
           bytes[index + 2] == 0x2D, bytes[index + 3] == 0x2D { return true }   // <!--
        var cursor = index + 1
        if cursor < bytes.count, bytes[cursor] == 0x2F { cursor += 1 }          // </div>
        let start = cursor
        while cursor < bytes.count, isLetter(bytes[cursor]) { cursor += 1 }
        guard cursor > start else { return false }
        let name = String(bytes: bytes[start..<cursor], encoding: .utf8)?.lowercased() ?? ""
        return htmlTags.contains(name)
    }

    /// `[^引用]` 或 `[^定义]:`。原生读者两条都不认，会印成方括号字面量。
    private static func footnote(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index + 1 < bytes.count {
            if bytes[index] == bracket, bytes[index + 1] == caret {
                var cursor = index + 2
                while cursor < bytes.count, bytes[cursor] != closeBracket, bytes[cursor] != 0x0A { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == closeBracket { return true }
            }
            index += 1
        }
        return false
    }

    /// `> [!类型]` / `> [!类型]+` / `> [!类型]-`。和 renderer.js 的 `CALLOUT_RE` 同口径：
    /// 类型是字母，可折叠标记紧贴右括号，然后由空白或右括号收口。
    private static func callout(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < 3, index < bytes.count, bytes[index] == space { index += 1 }
        guard index < bytes.count, bytes[index] == 0x3E else { return false }
        index += 1
        while index < bytes.count, bytes[index] == space || bytes[index] == 0x09 { index += 1 }
        guard index + 1 < bytes.count, bytes[index] == bracket, bytes[index + 1] == 0x21 else { return false }
        index += 2
        let start = index
        while index < bytes.count, isLetter(bytes[index]) { index += 1 }
        guard index > start else { return false }
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        return index >= bytes.count || bytes[index] == closeBracket || bytes[index] == space || bytes[index] == 0x09
    }
}

/// 网页读者那些文件在哪儿。`.app` 里是 `Contents/Resources/MarkdownRenderer`；
/// 直接跑 `.build/debug/DeskNote`（自检、出图）时那里没有，得回到仓库根。
enum RendererLocations {
    /// 只算一次：找目录是磁盘操作，界面每刷一帧找一遍不划算。
    static let current: URL? = find()

    static let missingMessage = "MarkdownRenderer/ 不在位：富渲染的资源没跟着装过来。"

    private static func find() -> URL? {
        if let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownRenderer"),
           isComplete(index.deletingLastPathComponent()) { return index.deletingLastPathComponent() }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("MarkdownRenderer", isDirectory: true),
           isComplete(bundled) { return bundled }
        #if DEBUG
        // 这个文件在 Sources/DeskNote/ 下，上跳三级才是仓库根。草稿那版只跳了两级，
        // 停在 Sources/，于是裸二进制跑自检时永远找不到资源。
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources/DeskNote
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("MarkdownRenderer", isDirectory: true)
        if isComplete(repository) { return repository }
        #endif
        return nil
    }

    /// 缺一个文件就整个不用：宁可退回原生读者，也不要页面渲染到一半停在白框上。
    static let requiredFiles = [
        "index.html", "renderer.js", "renderer.css",
        "vendor/markdown-it.min.js", "vendor/markdown-it-footnote.min.js", "vendor/purify.min.js",
        "vendor/highlight.min.js", "vendor/katex/katex.min.js", "vendor/katex/katex.min.css",
        "vendor/katex/contrib/auto-render.min.js", "vendor/mermaid/mermaid.min.js"
    ]

    /// 不在 `private` 是因为自检要能直接打一枪：装漏一个文件的那个目录，判出来的必须是 false。
    static func isComplete(_ directory: URL) -> Bool {
        let disk = FileManager.default
        return requiredFiles.allSatisfy { disk.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }
}

private struct RichReaderWebView: NSViewRepresentable {
    let text: String
    let revision: Int
    let fileURL: URL
    let rootURL: URL
    let fontSize: Double
    let dark: Bool
    let onOpen: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(LocalImageSchemeHandler(rootURL: rootURL),
                                          forURLScheme: LocalImageSchemeHandler.scheme)
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: Coordinator.messageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 背景由 renderer.css 的 --panel 管。不去碰 `drawsBackground` 那种私有 KVC；
        // macOS 的 WKWebView 也没有 `scrollView` 可调，草稿里那三行抄的是 iOS 的写法。
        webView.underPageBackgroundColor = dark ? .desknotePanelDark : .desknotePanelLight

        context.coordinator.attach(webView: webView, onOpen: onOpen)
        if let directory = RendererLocations.current {
            context.coordinator.rendererDirectory = directory
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        } else {
            context.coordinator.fail(RendererLocations.missingMessage)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = dark ? .desknotePanelDark : .desknotePanelLight
        context.coordinator.attach(webView: webView, onOpen: onOpen)
        context.coordinator.update(text: text, revision: revision, fileURL: fileURL, rootURL: rootURL,
                                   fontSize: fontSize, dark: dark)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let messageName = "deskNoteReader"

        private weak var webView: WKWebView?
        private var onOpen: ((String) -> Void)?
        fileprivate var rendererDirectory: URL?
        /// 页面里那段脚本自己报的「桥通了」。没收到它就送正文，送出去的对象还是 undefined，
        /// 画面会一直白着——所以这一格只能由 `{action:'ready'}` 置位。
        private var rendererReady = false
        private var failed = false

        private var latestText = ""
        private var latestRevision = 0
        private var latestNotePath = ""
        private var latestFontSize = 14.0
        private var latestDark = false
        /// 已经送到网页那侧的是「哪一篇、第几版」。跨进程搬整篇正文不便宜，
        /// 这个比较必须是 O(1)：拿整串正文当键就是每帧搬一次。
        private var sentKey: String?
        private var sentFontSize = 0.0
        private var sentDark = false
        private var sentPalette: [String: String] = [:]

        func attach(webView: WKWebView, onOpen: @escaping (String) -> Void) {
            self.webView = webView
            self.onOpen = onOpen
        }

        func detach() {
            webView = nil
            onOpen = nil
            sentKey = nil
            rendererReady = false
        }

        func update(text: String, revision: Int, fileURL: URL, rootURL: URL, fontSize: Double, dark: Bool) {
            latestText = text
            latestRevision = revision
            latestNotePath = Self.relativePath(fileURL: fileURL, rootURL: rootURL)
            latestFontSize = min(max(fontSize, 8), 48)
            latestDark = dark
            flushPendingUpdate()
        }

        /// 装载途中出的事：给一句实话，不留白框。资源整份缺失是另一条路——
        /// 那条在 `body` 上就分流回原生读者了，走不到这儿。
        func fail(_ message: String) {
            guard !failed, let webView else { return }
            failed = true
            let escaped = message.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            webView.loadHTMLString("""
                <!doctype html><meta charset="utf-8">
                <style>body{font:13px -apple-system,sans-serif;padding:18px;color:#6C2525;background:#FFF7F7;overflow-wrap:anywhere}</style>
                <strong>DeskNote 阅读模式</strong><p>\(escaped)</p>
                """, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if rendererReady || failed { flushPendingUpdate(); return }
            // 脚本没报 ready（被 CSP 拦了、文件被改坏了）：探一次再决定，别一直白着。
            webView.evaluateJavaScript("typeof window.deskNoteRender === 'function'") { [weak self] value, _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.rendererReady, !self.failed else { return }
                    if (value as? Bool) == true {
                        self.rendererReady = true
                        self.flushPendingUpdate()
                    } else {
                        self.fail("渲染脚本没有起来：MarkdownRenderer/renderer.js 可能被改坏了。")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail("页面加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail("页面加载失败：\(error.localizedDescription)")
        }

        private func flushPendingUpdate() {
            guard !failed, rendererReady, let webView else { return }
            let palette = Self.palette(dark: latestDark, appearance: webView.effectiveAppearance)
            let key = "\(latestNotePath)#\(latestRevision)"
            if sentKey != key {
                sentKey = key
                sentFontSize = latestFontSize
                sentDark = latestDark
                sentPalette = palette
                webView.callAsyncJavaScript("window.deskNoteRender(payload)", arguments: [
                    "payload": [
                        "text": latestText,
                        "notePath": latestNotePath,
                        "revision": latestRevision,
                        "fontSize": latestFontSize,
                        "dark": latestDark,
                        "palette": palette
                    ]
                ], in: nil, in: .page)
                return
            }
            if sentFontSize != latestFontSize || sentDark != latestDark || sentPalette != palette {
                sentFontSize = latestFontSize
                sentDark = latestDark
                sentPalette = palette
                webView.callAsyncJavaScript("window.deskNoteSetOptions(options)", arguments: [
                    "options": [
                        "fontSize": latestFontSize,
                        "dark": latestDark,
                        "palette": palette
                    ] as [String: Any]
                ], in: nil, in: .page)
            }
        }

        /// 网页那侧不吃 NSColor，得给十六进制。四支颜色按当前外观解一遍，
        /// 和 SwiftUI 用的 `panelDark` / `metaInk` 是同一批数出来的，不会出现两种深色。
        private static func palette(dark: Bool, appearance: NSAppearance) -> [String: String] {
            var colors: [NSColor] = []
            appearance.performAsCurrentDrawingAppearance {
                colors = [
                    dark ? .desknotePanelDark : .desknotePanelLight,
                    .labelColor,
                    .desknoteMetaInk,
                    .controlAccentColor
                ]
            }
            guard colors.count == 4 else { return [:] }
            return ["panel": hex(colors[0]), "ink": hex(colors[1]),
                    "meta": hex(colors[2]), "accent": hex(colors[3])]
        }

        private static func hex(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
            func byte(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
            return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        }

        private static func relativePath(fileURL: URL, rootURL: URL) -> String {
            let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let file = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path + "/") else { return "" }
            return String(file.path.dropFirst(root.path.count + 1))
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "ready":
                rendererReady = true
                flushPendingUpdate()
            case "open":
                guard let target = body["target"] as? String, !target.isEmpty else { return }
                // 送出去的是**一次**百分号编码后的原文，`openLink` 只解一次——
                // 和原生读者那条 `desknote://open?target=` 完全同口径。
                onOpen?(target)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL, let directory = rendererDirectory,
               url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") {
                decisionHandler(.allow)
                return
            }
            if ["about", "blob", LocalImageSchemeHandler.scheme].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.allow)
                return
            }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            // 其余一律拦下：正文里手写的 `<img src="https://…">` 不该变成一次外联。
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}

/// 库内图片的路径解析。网页 scheme 和自检共用这一份：它是「跳出库外」的唯一入口，
/// `..`、绝对路径、带协议的、软链都得在这儿挡住。口径和 `LibraryReader.safeLocalImageURL`
/// 一致——先按这篇文档所在的目录找，再按库根找。
enum RichReaderImages {
    /// `note` 是库内的相对路径，空串表示这篇文档不在库里（那就只按库根找）。
    /// `target` 是 markdown 原文里写的那个目标，**没有**解过转义。
    static func url(root: URL, note: String, target: String) -> URL? {
        guard isRelative(target) else { return nil }
        // 解这一次是**故意的**：JS 那侧保留了 markdown 原文里的转义，作者写 `a%20b.png`
        // 指的就是 `a b.png`，原生读者也正是这样解的，两边得一样。
        let decoded = target.removingPercentEncoding ?? target
        guard isRelative(decoded) else { return nil }
        let library = root.resolvingSymlinksInPath().standardizedFileURL
        var folders: [URL] = []
        if isRelative(note) {
            let noteURL = library.appendingPathComponent(note)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard noteURL.path.hasPrefix(library.path + "/") else { return nil }
            folders.append(noteURL.deletingLastPathComponent())
        }
        folders.append(library)
        for folder in folders {
            let file = folder.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path == library.path || file.path.hasPrefix(library.path + "/") else { continue }
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// 绝对路径、反斜杠开头、带协议的、页内锚点都不是库内图片；空串也不是。
    static func isRelative(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("\\"), !value.hasPrefix("#") else { return false }
        return value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil
    }
}

/// 只读的自定义 scheme：只暴露库根底下的图片，软链先解开再判包含。
/// 口径跟 `LibraryReader.safeLocalImageURL` 一致——先按这篇文档所在的目录找，再按库根找。
private final class LocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "desknote-image"
    static let maximumFileBytes = 48 * 1024 * 1024

    private let rootURL: URL
    private let lock = NSLock()
    private var activeTasks = Set<ObjectIdentifier>()

    init(rootURL: URL) { self.rootURL = rootURL }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        activeTasks.insert(taskID)
        lock.unlock()

        let requestURL = urlSchemeTask.request.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak urlSchemeTask] in
            guard let self, let urlSchemeTask else { return }
            guard let requestURL, let data = self.imageData(for: requestURL),
                  let mimeType = Self.mimeType(for: requestURL) else {
                self.finishFailure(taskID: taskID, task: urlSchemeTask, code: 404)
                return
            }
            DispatchQueue.main.async { [weak self, weak urlSchemeTask] in
                guard let self, let task = urlSchemeTask, self.isActive(taskID) else { return }
                task.didReceive(URLResponse(url: requestURL, mimeType: mimeType,
                                            expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
                self.remove(taskID)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        remove(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func imageData(for url: URL) -> Data? {
        guard url.scheme == Self.scheme, url.host == "local",
              let file = imageURL(for: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= Self.maximumFileBytes,
              let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .image), type.identifier != "public.svg-image" else { return nil }
        return try? Data(contentsOf: file, options: [.mappedIfSafe])
    }

    /// `note` 和 `target` 到这儿都已经被 `URLComponents` 解过一次——那是 JS 那侧
    /// `encodeURIComponent` 的逆运算。所以 `note` 不再解第二次：它是我们自己送出去的
    /// 路径，再解一次会把目录名里真实存在的 `%20` 读成空格。
    private func imageURL(for url: URL) -> URL? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return RichReaderImages.url(root: rootURL,
                                    note: value("note", in: items) ?? "",
                                    target: value("target", in: items) ?? "")
    }

    private func value(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }

    private static func mimeType(for url: URL) -> String? {
        guard url.scheme == scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = items.first(where: { $0.name == "target" })?.value,
              let type = UTType(filenameExtension: URL(fileURLWithPath: target).pathExtension),
              type.conforms(to: .image), type.identifier != "public.svg-image" else { return nil }
        return type.preferredMIMEType
    }

    private func isActive(_ taskID: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeTasks.contains(taskID)
    }

    private func remove(_ taskID: ObjectIdentifier) {
        lock.lock()
        activeTasks.remove(taskID)
        lock.unlock()
    }

    private func finishFailure(taskID: ObjectIdentifier, task: WKURLSchemeTask?, code: Int) {
        DispatchQueue.main.async { [weak self, weak task] in
            guard let self, let task, self.isActive(taskID) else { return }
            task.didFailWithError(NSError(domain: "DeskNote.LocalImage", code: code,
                                          userInfo: [NSLocalizedDescriptionKey: "图片不在库里，或者已经不在"]))
            self.remove(taskID)
        }
    }
}
