import SwiftUI

/// 便签页。工具栏下面两种模式：列表 = 备忘录式「日期分组列表｜正文」，画廊 = 等高卡片墙。
struct NotesBrowserView: View {
    @Environment(\.noteFontSize) private var fontSize
    @State private var store = Store.shared
    @State private var settings = AppSettings.shared
    @State private var selected: UUID?

    let query: String

    private var shown: [StickyNote] {
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// 分组标题本身就要求按编辑时间倒序
    private var sorted: [StickyNote] { shown.sorted { $0.updatedAt > $1.updatedAt } }

    /// 选中的便签被删掉时退回第一条，正文栏不会突然空白
    private var current: StickyNote? {
        if let id = selected, let note = store.note(id) { return note }
        return sorted.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            if settings.notesGallery {
                gallery
            } else {
                HStack(spacing: 0) {
                    if !settings.notesListCollapsed {
                        listColumn
                        Divider().opacity(0.4)
                    }
                    detailColumn
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { settings.notesGallery.toggle() } label: {
                Image(systemName: settings.notesGallery ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: fontSize - 2))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(settings.notesGallery ? "换成列表" : "换成画廊")

            if !settings.notesGallery {
                // 箭头指向列表要去的方向：展开时朝左（收进去），收起时朝右（拉出来）
                Button { settings.notesListCollapsed.toggle() } label: {
                    Image(systemName: settings.notesListCollapsed ? "chevron.right" : "chevron.left")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(settings.notesListCollapsed ? "展开便签列表" : "收起便签列表")
            }

            // 标题栏已经写着「便签」，这里只报张数，不要再叠一层同名标题
            let pinned = store.notes.filter(\.pinnedToDesktop).count
            Text("\(store.notes.count) 张" + (pinned > 0 ? " · \(pinned) 张钉在桌面" : ""))
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                // 和 ⌘N（菜单栏「新建便签」）走同一条路：建完直接开浮窗。之前这里只把
                // 新便签选进正文栏，tooltip 却写着 ⌘N，两个入口做出来的事不一样。
                StickyWindowManager.shared.open(store.addNote())
            } label: {
                Label("新建便签", systemImage: "plus")
                    .font(.system(size: fontSize - 2))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("新建便签（⌘N）")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var gallery: some View {
        ScrollView {
            if shown.isEmpty {
                emptyHint
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity)
            } else {
                NotesWallView(query: query)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "还没有便签，点右上角新建或按 ⌘N。" : "没有匹配的便签。")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 中间列表

    private var listColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { group in
                    Text(group.title)
                        .font(.system(size: fontSize - 3, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 3)
                    ForEach(group.notes) { note in row(note) }
                }
            }
            .padding(.bottom, 8)
            // 宽度要同时定在内容和 ScrollView 上：只定内容，ScrollView 自己还是会跟正文栏平分窗口
            .frame(width: NoteLayout.notesListWidth, alignment: .leading)
        }
        .frame(width: NoteLayout.notesListWidth)
    }

    private var groups: [(title: String, notes: [StickyNote])] {
        var out: [(title: String, notes: [StickyNote])] = []
        for note in sorted {
            let title = DateFmt.group(note.updatedAt)
            if out.last?.title == title { out[out.count - 1].notes.append(note) }
            else { out.append((title, [note])) }
        }
        return out
    }

    private func row(_ note: StickyNote) -> some View {
        let on = current?.id == note.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.pinnedToDesktop {
                    Image(systemName: "pin.fill")
                        .font(.system(size: fontSize - 5))
                        .foregroundStyle(.tint)
                }
                Text(note.firstLine.isEmpty ? "空便签" : note.firstLine)
                    .font(.system(size: fontSize - 1, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Text(DateFmt.listStamp(note.updatedAt))
                    .font(.system(size: fontSize - 3, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(note.preview)
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(on ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { selected = note.id }
        .help(note.text)
    }

    // MARK: - 右侧正文

    @ViewBuilder
    private var detailColumn: some View {
        if let note = current {
            // 换一张便签要把编辑态一起换掉，所以用 id 重建
            NoteDetailView(note: note).id(note.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(query.isEmpty ? "还没有便签，点右上角新建或按 ⌘N。" : "没有匹配的便签。")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 正文栏：预览/编辑切换 + 这张便签的操作，渲染和桌面浮窗共用同一套。
private struct NoteDetailView: View {
    @Environment(\.noteFontSize) private var fontSize
    @State private var store = Store.shared
    @State private var editing = false

    let note: StickyNote

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().opacity(0.4)
            content
            Divider().opacity(0.4)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { editing.toggle() } label: {
                Image(systemName: editing ? "eye" : "square.and.pencil")
            }
            .help(editing ? "看渲染效果" : "编辑正文")

            Menu {
                ForEach(MarkdownText.reminderPresets()) { preset in
                    Button(preset.title) { store.mutateNote(note.id) { $0.remindAt = preset.date } }
                }
                Divider()
                Button("清除提醒") { store.mutateNote(note.id) { $0.remindAt = nil } }
                    .disabled(note.remindAt == nil)
            } label: {
                Image(systemName: note.remindAt == nil ? "bell" : "bell.fill")
            }
            .help(note.remindAt.map { "提醒：\(DateFmt.short.string(from: $0))" } ?? "设置提醒")

            Button {
                store.mutateNote(note.id) { $0.pinnedToDesktop.toggle() }
                StickyWindowManager.shared.applyPinnedState(note.id)
            } label: {
                Image(systemName: note.pinnedToDesktop ? "pin.fill" : "pin")
            }
            .help(note.pinnedToDesktop ? "取消钉到桌面" : "钉到桌面")

            Menu {
                ForEach(0..<NotePalette.count, id: \.self) { index in
                    Button {
                        store.mutateNote(note.id) { $0.colorIndex = index }
                    } label: {
                        if note.colorIndex == index {
                            Label("颜色 \(index + 1)", systemImage: "checkmark")
                        } else {
                            Text("颜色 \(index + 1)")
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .help("便签底色")

            Spacer()

            Button { StickyWindowManager.shared.open(note.id) } label: {
                Image(systemName: "uiwindow.split.2x1")
            }
            .help("在桌面打开这张便签")

            Button { copyToPasteboard(note.text) } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制正文")

            Button {
                let head = note.firstLine
                guard confirmDelete("这张便签", detail: head.isEmpty
                    ? "便签是空的。"
                    : "「\(String(head.prefix(20)))」共 \(note.text.count) 个字。") else { return }
                store.removeNote(note.id)
                StickyWindowManager.shared.close(note.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("删除这张便签")
        }
        .buttonStyle(.plain)
        .font(.system(size: fontSize - 1))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if editing {
            MarkdownEditor(text: noteText, fontSize: fontSize, autoFocus: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                NoteBodyView(text: note.text, fontSize: fontSize, interactive: true) { line, done in
                    store.toggleNoteCheckbox(note.id, line: line, to: done)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(DateFmt.relative(note.updatedAt))
            if let remindAt = note.remindAt {
                Text("· 提醒 \(DateFmt.short.string(from: remindAt))")
            }
            Spacer()
            Text("\(note.text.count) 字")
        }
        .font(.system(size: fontSize - 4))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var noteText: Binding<String> {
        Binding(get: { note.text }, set: { value in
            store.mutateNote(note.id) { $0.text = value }
        })
    }
}
