import SwiftUI
import AppKit

struct LibraryView: View {
    @Environment(\.noteFontSize) private var fontSize
    /// 网页读者只认布尔和十六进制，拿不到 NSColor。主题（`settings.theme`）是通过
    /// `NSWindow.appearance` 落下去的，所以这一格读回来的就是窗口真正在用的那套外观。
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = LibraryModel.shared
    @State private var document = LibraryDocument.shared
    @State private var settings = AppSettings.shared
    @State private var tree = LibraryTreeState()
    @State private var action: FileAction?
    @State private var name = ""
    @State private var operationError: String?
    /// 搜索框那一头直连 `query`，每敲一个字都会变一次；过滤这条尾巴走的是这一格，
    /// 由 `.task(id: query)` 睡 0.2 秒之后才跟上。反抖用的是 task 的取消语义：
    /// 手还在动的时候，前一轮根本睡不到头。
    @State private var settledQuery = ""
    let query: String

    /// 收起状态记在设置里，而不是 @State：下次打开主窗口还是同一个样子。
    /// 这一格以前是「写了没人读」的死设置，出图时 library-wide 和 library-light 因此一模一样。
    private var treeHidden: Bool { settings.libraryDrawerCollapsed }

    private struct FileAction: Identifiable {
        var id = UUID()
        var title: String
        var parent: URL
        var directory: Bool
        var existing: URL?
    }
    init(query: String, tree: LibraryTreeState = LibraryTreeState()) {
        self.query = query
        _tree = State(initialValue: tree)
        _settledQuery = State(initialValue: query)
    }

    var body: some View {
        Group {
            if let root = model.rootURL {
                workspace(root)
            } else { setup }
        }
        .onAppear { refreshTree(); restoreSelection() }
        .onDisappear { document.save() }
        .onChange(of: model.lastScan) { _, _ in
            refreshTree()
            // A selected file may have moved in Finder or another editor.
            if let current = model.rows.first(where: { $0.id == model.selected }),
               let old = document.url, old != current.url,
               !FileManager.default.fileExists(atPath: old.path) {
                document.relocated(from: old, to: current.url)
            }
            if document.root != model.rootURL || document.url == nil { restoreSelection() }
            document.refresh()
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            // 深搜的结果只在它那一刻的词上成立：词一换就作废，不然列表里会留着上一句的命中。
            if settledQuery != query { model.clearDeepSearch(); settledQuery = query }
            refreshTree()
        }
        .onChange(of: model.deepHits.count) { _, _ in refreshTree() }
        .onChange(of: settings.libraryFilter) { _, _ in refreshTree() }
        .onChange(of: model.selected) { _, id in
            guard let row = model.rows.first(where: { $0.id == id }), let root = model.rootURL else { return }
            _ = document.open(row.url, root: root)
        }
        .sheet(item: $action) { item in namingSheet(item) }
        .background {
            Group {
                Button("") { document.save() }.keyboardShortcut("s")
                Button("") { document.mode = document.mode == "read" ? "edit" : "read" }.keyboardShortcut("e")
                Button("") { beginCreate(directory: false) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    private func workspace(_ root: URL) -> some View {
        VStack(spacing: 0) {
            toolbar(root)
            if let error = document.error ?? operationError ?? model.message ?? model.lastSync?.problem {
                banner(error, warning: true)
            }
            if let notice = document.notice { banner(notice, warning: false) }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if !treeHidden {
                        fileTree(root)
                            .frame(width: geometry.size.width < 560 ? 164 : 210)
                        Divider().opacity(0.4)
                    }
                    editorArea(root, width: geometry.size.width - (treeHidden ? 0 : geometry.size.width < 560 ? 165 : 211))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    private func toolbar(_ root: URL) -> some View {
        HStack(spacing: 8) {
            icon(treeHidden ? "sidebar.left" : "sidebar.leading", "显示或收起文件树") {
                settings.libraryDrawerCollapsed.toggle()
            }
            Text(root.lastPathComponent).font(.system(size: fontSize - 1, weight: .semibold)).lineLimit(1)
                .help(root.path)
            Spacer(minLength: 0)
            icon("doc.badge.plus", "新建 Markdown（⇧⌘N）") { beginCreate(directory: false) }
            icon("folder.badge.plus", "新建文件夹") { beginCreate(directory: true) }
            icon("arrow.clockwise", "刷新文件树") { model.rescan() }
            Menu {
                Button("在 Finder 打开库") { model.revealRoot() }
                Button("选择其他文件夹…") {
                    guard document.save() else { return }
                    model.chooseDirectory(); tree.selectedFolder = nil; refreshTree()
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).fixedSize().help("库选项")
        }
        .padding(.horizontal, 10).frame(height: 36)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
    private func banner(_ text: String, warning: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle" : "doc.on.doc")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !warning { icon("xmark", "关闭提示") { document.notice = nil } }
        }
        .font(.system(size: fontSize - 2))
        .foregroundStyle(warning ? Color.warnInk : Color.metaInk)
        .padding(8).background((warning ? Color.warnInk : Color.primary).opacity(0.07))
    }
    private func fileTree(_ root: URL) -> some View {
        LibraryFileTree(tree: tree, filter: $settings.libraryFilter,
                        selectedURL: document.url, query: query, counts: model.counts,
                        scanning: model.scanning,
                        deepSearching: model.deepSearching,
                        deepHits: model.deepQuery == settledQuery ? model.deepHits.count : 0,
                        deepExcerpt: { model.deepHit(for: $0)?.excerpts.first },
                        onDeepSearch: { model.deepSearch(query: settledQuery, in: settings.libraryFilter) },
                        onDeepClear: { model.clearDeepSearch(); refreshTree() },
                        onOpen: open,
                        onCreate: { folder, directory in
                            tree.selectedFolder = folder
                            beginCreate(directory: directory)
                        },
                        onRename: { entry in
                            name = entry.directory ? entry.url.lastPathComponent : entry.url.deletingPathExtension().lastPathComponent
                            action = FileAction(title: "重命名", parent: entry.url.deletingLastPathComponent(),
                                                directory: entry.directory, existing: entry.url)
                        },
                        onExternalOpen: { url in
                            if let row = model.rows.first(where: { $0.url == url }) { model.openInEditor(row) }
                        },
                        onDelete: trash)
    }

    @ViewBuilder private func editorArea(_ root: URL, width: CGFloat) -> some View {
        if let url = document.url, document.root == root,
           model.rows.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent).font(.system(size: fontSize - 1, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(relative(url, root))
                    Spacer(minLength: 2)
                    ForEach([("read", "阅读"), ("edit", "编辑"), ("split", "分屏")], id: \.0) { mode, label in
                        Button(label) { document.mode = mode }
                            .buttonStyle(.plain).font(.system(size: fontSize - 2))
                            .padding(.horizontal, 7).frame(height: 24)
                            .background(document.mode == mode ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(document.mode == mode ? Color.accentColor : Color.metaInk)
                    }
                }.padding(.horizontal, 10).frame(height: 36)
                    .overlay(alignment: .bottom) { Divider().opacity(0.4) }
                if document.loading {
                    // 大文档的字节还在后台：磁盘基线没到之前不把编辑器摆上来，
                    // 那几毫秒里敲下去的会是空正文。
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("这篇比较大，正在后台读它……读完再编辑")
                            .font(.system(size: fontSize - 1)).foregroundStyle(Color.metaInk)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if document.mode == "read" {
                    if LibraryRichReader.isNeeded(text: document.text, revision: document.revision, path: url.path) {
                        richReading(url, root)
                    } else { reading(url, root) }
                }
                else if document.mode == "split" {
                    if width >= 640 {
                        HSplitView {
                            source.frame(minWidth: 240, idealWidth: width * 0.5, maxWidth: .infinity)
                            reading(url, root).frame(minWidth: 240, idealWidth: width * 0.5, maxWidth: .infinity)
                        }
                    } else {
                        VSplitView { source.frame(minHeight: 110); reading(url, root).frame(minHeight: 110) }
                    }
                } else {
                    VStack(spacing: 0) {
                        if !document.snapshot.prefix.isEmpty {
                            frontmatterBlock
                                .padding(.horizontal, 10).padding(.top, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        source
                    }
                }
                HStack(spacing: 8) {
                    Text(document.loading ? "正在装载…"
                         : document.error != nil ? "保存失败" : document.dirty ? "等待保存…" : "已保存")
                        .foregroundStyle(document.error != nil ? Color.warnInk : Color.metaInk)
                    Spacer(minLength: 4)
                    Text("\(document.charCount) 字 · \(document.lineCount) 行").monospacedDigit()
                        .help(document.dirty ? "字数在停手 0.6 秒后跟一次" : "字数与磁盘那一份同步")
                    Button("保存") { document.save() }.buttonStyle(.plain).foregroundStyle(Color.accentColor).help("保存（⌘S）")
                }.font(.system(size: fontSize - 3)).foregroundStyle(Color.metaInk)
                    .padding(.horizontal, 12).frame(height: 27)
                    .overlay(alignment: .top) { Divider().opacity(0.4) }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text").font(.system(size: fontSize + 16)).foregroundStyle(Color.metaInk)
                Text("打开一篇 Markdown").font(.system(size: fontSize + 2, weight: .semibold))
                Text("从文件树选择，或新建一篇开始写。")
                    .font(.system(size: fontSize - 1)).foregroundStyle(Color.metaInk)
                Button("新建 Markdown") { beginCreate(directory: false) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var source: some View {
        MarkdownEditor(text: Binding(get: { document.text }, set: { document.edited($0) }), fontSize: fontSize)
            .id(document.url).frame(minWidth: 130, maxWidth: .infinity, maxHeight: .infinity)
    }
    private func reading(_ url: URL, _ root: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !document.snapshot.prefix.isEmpty { frontmatterBlock }
                LibraryReader(text: document.text, revision: document.revision, contentHash: document.contentHash,
                              fileURL: url, rootURL: root, fontSize: fontSize, onOpen: openLink)
                if let row = model.rows.first(where: { $0.url == url }) {
                    let backlinks = model.backlinks(of: row)
                    if !backlinks.isEmpty {
                        Divider().opacity(0.4)
                        Text("反向链接 · \(backlinks.count)").font(.system(size: fontSize - 2, weight: .semibold)).foregroundStyle(Color.metaInk)
                        ForEach(backlinks) { other in
                            Button(other.name) { open(other.url) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }.textSelection(.enabled)
    }

    /// 只有阅读模式换网页读者。编辑和分屏不动：那两个模式下用户在打字，正文每 0.6 秒存一次盘，
    /// 每存一次就要跨进程搬一整篇、再让 WebContent 重排一遍——代价全落在「还是好卡」那条路上。
    /// 网页那一侧自己滚动，所以文档属性和反向链接改挂在它上下两条，不再嵌进同一个 ScrollView。
    @ViewBuilder
    private func richReading(_ url: URL, _ root: URL) -> some View {
        VStack(spacing: 0) {
            if !document.snapshot.prefix.isEmpty {
                frontmatterBlock.padding(.horizontal, 18).padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LibraryRichReader(text: document.text, revision: document.revision, fileURL: url, rootURL: root,
                              fontSize: fontSize, dark: colorScheme == .dark, onOpen: openLink)
            if let row = model.rows.first(where: { $0.url == url }) {
                let backlinks = model.backlinks(of: row)
                if !backlinks.isEmpty {
                    Divider().opacity(0.4)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            Text("反向链接 · \(backlinks.count)").foregroundStyle(Color.metaInk)
                            ForEach(backlinks) { other in
                                Button(other.name) { open(other.url) }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                            }
                        }.padding(.horizontal, 18).padding(.vertical, 8)
                    }
                    .font(.system(size: fontSize - 2))
                }
            }
        }
    }

    @ViewBuilder private var frontmatterBlock: some View {
        DisclosureGroup("文档属性") {
            Text(document.snapshot.prefix).font(.system(size: fontSize - 2, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }.font(.system(size: fontSize - 2)).foregroundStyle(Color.metaInk)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("把文件夹变成你的库").font(.system(size: fontSize + 5, weight: .bold))
            Text("在文件树里整理 Markdown，随时阅读、编辑或分屏预览。文件直接保存在本地，也能用 Obsidian 或 Typora 打开。")
                .font(.system(size: fontSize)).foregroundStyle(Color.metaInk).fixedSize(horizontal: false, vertical: true)
            Button("从便签和待办建立库") { model.createLibrary() }
            Button("打开已有文件夹…") { model.chooseDirectory() }
            if let error = model.message { Text(error).foregroundStyle(Color.warnInk) }
        }.padding(24).frame(maxWidth: 500, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func namingSheet(_ item: FileAction) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(.system(size: fontSize + 2, weight: .semibold))
            TextField(item.directory ? "文件夹名称" : "文件名称", text: $name).textFieldStyle(.roundedBorder).onSubmit { perform(item) }
            Text(LibraryModel.tilde(item.parent.path)).font(.system(size: fontSize - 2)).foregroundStyle(Color.metaInk).lineLimit(2)
            if let error = operationError { Text(error).font(.system(size: fontSize - 1)).foregroundStyle(Color.warnInk) }
            HStack { Spacer(); Button("取消") { action = nil; operationError = nil }.keyboardShortcut(.cancelAction)
                Button(item.existing == nil ? "创建" : "重命名") { perform(item) }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 340)
    }
    private func perform(_ item: FileAction) {
        guard let root = model.rootURL, document.save() else { return }
        do {
            let url: URL
            if let existing = item.existing {
                if name == (item.directory ? existing.lastPathComponent : existing.deletingPathExtension().lastPathComponent) { action = nil; return }
                url = try LibraryFiles.rename(existing, to: name, directory: item.directory, root: root)
                document.relocated(from: existing, to: url)
                // 一旧一新两条都报上去：旧路径不在了要掉账（连带它下面的整层），新路径要认回身份。
                Store.shared.pullFromVault(diskPaths: [existing.path, url.path])
            } else { url = try LibraryFiles.create(name: name, folder: item.parent, directory: item.directory, root: root) }
            operationError = nil; action = nil
            if item.directory { tree.selectFolder(url) }
            else { document.mode = "edit"; open(url) }
            model.rescan(); refreshTree()
        } catch { operationError = error.localizedDescription }
    }
    private func beginCreate(directory: Bool) {
        guard let root = model.rootURL else { return }
        name = ""; operationError = nil
        let parent = tree.selectedFolder ?? document.url?.deletingLastPathComponent() ?? root
        action = FileAction(title: directory ? "新建文件夹" : "新建 Markdown", parent: parent, directory: directory)
    }
    private func open(_ url: URL) {
        guard let root = model.rootURL, document.open(url, root: root) else { return }
        tree.reveal(url)
        model.selected = model.rows.first(where: { $0.url == url })?.id
        AppEnv.defaults.set(relative(url, root), forKey: "libraryLastDocument")
    }
    private func openLink(_ target: String) {
        guard let root = model.rootURL else { return }
        let target = target.removingPercentEncoding ?? target
        let path = target.components(separatedBy: "#").first ?? target
        let local = (document.url?.deletingLastPathComponent() ?? root).appendingPathComponent(path)
        let targetStem = Vault.stem(path)
        if let row = model.rows.first(where: { $0.url.standardizedFileURL == local.standardizedFileURL || relative($0.url, root) == path || relative($0.url.deletingPathExtension(), root) == path })
            ?? model.rows.first(where: { Vault.stem($0.url.lastPathComponent) == targetStem || Vault.stem($0.name) == targetStem }) {
            open(row.url)
        } else { operationError = "找不到链接的文件「\(target)」。" }
    }
    /// 右键「移到废纸篓」：和 Finder 把文件拖进废纸篓是同一套逻辑——NSWorkspace.recycle
    /// 会把文件/文件夹送进废纸篓、自动处理重名、可恢复。这里不做二次确认：Finder 移废纸篓
    /// 本身也不确认，且废纸篓里能还原。删完若正打开的就是它（或它在被删的文件夹里），关掉文档。
    private func trash(_ url: URL) {
        let wasOpen = document.url.map {
            $0.standardizedFileURL == url.standardizedFileURL
            || $0.path.hasPrefix(url.standardizedFileURL.path + "/")
        } ?? false
        NSWorkspace.shared.recycle([url]) { _, error in
            if let error {
                Task { @MainActor in operationError = "移入废纸篓失败：\(error.localizedDescription)" }
                return
            }
            Task { @MainActor in
                if wasOpen { document.close() }
                model.rescan()
            }
        }
    }
    private func refreshTree() {
        let rows = model.rows(in: settings.libraryFilter, query: settledQuery)
        let filtering = !settledQuery.isEmpty || settings.libraryFilter != .all
        tree.update(index: model.treeIndex,
                    matchingPaths: filtering ? Set(rows.map { $0.url.path }) : nil,
                    fileCount: rows.count)
    }
    private func restoreSelection() {
        guard let root = model.rootURL else { return }
        if document.root == root, document.url != nil { return }
        if let last = AppEnv.defaults.string(forKey: "libraryLastDocument") {
            let url = root.appendingPathComponent(last)
            if FileManager.default.fileExists(atPath: url.path) { open(url); return }
        }
        if let row = model.rows.first { open(row.url) }
    }
    private func relative(_ url: URL, _ root: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }
    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: fontSize - 1)).frame(width: 24, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Color.metaInk).help(help)
    }
}
