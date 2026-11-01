import SwiftUI
import AppKit

/// This view owns the observation of disclosure/selection state. Its document sibling does
/// not observe that state, so folding a folder never reparses or reloads Markdown/images.
struct LibraryFileTree: View {
    @Environment(\.noteFontSize) private var fontSize
    @Bindable var tree: LibraryTreeState
    @Binding var filter: LibraryFilter
    let selectedURL: URL?
    let query: String
    let counts: [LibraryFilter: Int]
    let scanning: Bool
    /// 深搜（读正文深处）那三格：只在搜索框有字的时候露出来，平时不给它占地方。
    let deepSearching: Bool
    let deepHits: Int
    /// 这一份文件深处捞到的第一段上下文，拿来当悬停说明；没有就 nil。
    var deepExcerpt: (URL) -> String?
    var onDeepSearch: () -> Void
    var onDeepClear: () -> Void
    var onOpen: (URL) -> Void
    var onCreate: (URL, Bool) -> Void
    var onRename: (LibraryTreeIndex.Entry) -> Void
    var onExternalOpen: (URL) -> Void
    /// 右键「移到废纸篓」。走 Finder 的逻辑（NSWorkspace.recycle），删到废纸篓而不是真删。
    var onDelete: (URL) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(LibraryFilter.allCases) { item in
                        Button("\(item.label) · \(counts[item] ?? 0)") { filter = item }
                    }
                } label: { Text(filter == .all ? "文件" : filter.label) }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text("\(tree.fileCount)").monospacedDigit().foregroundStyle(Color.metaInk)
            }.font(.system(size: fontSize - 2)).padding(.horizontal, 10).frame(height: 30)
            // 近文搜只看正文开头那一段（见 `LibraryRow.head`）。搜不到不等于库里没有：
            // 这一条把「还要不要往深处读盘」这个决定交给人，而不是每敲一个字替他把全库读一遍。
            if !query.isEmpty {
                HStack(spacing: 5) {
                    if deepSearching {
                        ProgressView().controlSize(.mini)
                        Text("正在读正文深处…")
                    } else if deepHits > 0 {
                        Image(systemName: "text.magnifyingglass")
                        Text("正文深处另有 \(deepHits) 份")
                        Button("清除") { onDeepClear() }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    } else {
                        Button { onDeepSearch() } label: { Text("搜正文深处") }
                            .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: fontSize - 3)).foregroundStyle(Color.metaInk)
                .padding(.horizontal, 10).frame(height: 20)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(tree.visibleEntries) { entry in row(entry) }
                        if tree.visibleEntries.isEmpty {
                            Text(query.isEmpty ? "还没有 Markdown 文件" : "没有找到匹配文件")
                                .font(.system(size: fontSize - 2)).foregroundStyle(Color.metaInk).padding(12)
                        }
                    }.padding(.vertical, 4).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedURL) { _, url in if let url { proxy.scrollTo(url.path) } }
                .focusable().focused($focused).onMoveCommand(perform: move)
            }
            HStack {
                Button("库根目录") { tree.selectedFolder = nil }
                    .buttonStyle(.plain).help("在库根目录新建文件")
                Spacer(minLength: 0)
                if scanning { ProgressView().controlSize(.mini) }
            }.font(.system(size: fontSize - 3)).foregroundStyle(Color.metaInk)
                .padding(.horizontal, 10).frame(height: 26)
                .overlay(alignment: .top) { Divider().opacity(0.4) }
        }.background(Color.primary.opacity(0.025))
    }

    private func row(_ entry: LibraryTreeIndex.Entry) -> some View {
        let selected = entry.directory ? tree.selectedFolder == entry.url : selectedURL == entry.url
        return Button {
            if entry.directory {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { tree.toggle(entry.url) }
            } else { onOpen(entry.url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: entry.directory ? (tree.expanded.contains(entry.id) ? "chevron.down" : "chevron.right") : "doc.text")
                    .font(.system(size: fontSize - 4)).frame(width: 12)
                    .foregroundStyle(selected ? Color.accentColor : Color.metaInk)
                if entry.directory { Image(systemName: "folder").foregroundStyle(Color.metaInk) }
                Text(entry.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.conflict {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.warnInk).help("冲突副本")
                }
            }.font(.system(size: fontSize - 1))
                .padding(.leading, CGFloat(entry.depth) * 14 + 10).padding(.trailing, 8)
                .frame(height: 29).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.13) : Color.clear)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            // 深处捞到的那一段挂在同一句悬停说明里：文件树这么窄，再加一行就没地方放正文了。
            .help(entry.relativePath + (entry.directory ? ""
                : deepExcerpt(entry.url).map { "\n正文深处：\($0)" } ?? ""))
            .contextMenu {
                if entry.directory {
                    Button("新建 Markdown") { onCreate(entry.url, false) }
                    Button("新建文件夹") { onCreate(entry.url, true) }
                } else {
                    Button("打开") { onOpen(entry.url) }
                    Button("在外部编辑器打开") { onExternalOpen(entry.url) }
                }
                Button("重命名…") { onRename(entry) }
                Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Divider()
                Button("移到废纸篓") { onDelete(entry.url) }
                    .foregroundStyle(Color.warnInk)
            }
    }
    private func move(_ direction: MoveCommandDirection) {
        let files = tree.visibleEntries.filter { !$0.directory }
        guard !files.isEmpty else { return }
        let current = files.firstIndex(where: { $0.url == selectedURL }) ?? -1
        if direction == .down { onOpen(files[min(current + 1, files.count - 1)].url) }
        if direction == .up { onOpen(files[max(current - 1, 0)].url) }
    }
}
