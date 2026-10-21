import AppKit
import SwiftUI

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// 便签画廊：等高卡片墙。点卡片正文就地编辑，右上角铅笔开独立窗口，卡片可拖拽排序、右键操作。
/// 标题/计数/新建在 NotesBrowserView 的工具栏里，这里只画卡片。
struct NotesWallView: View {
    @Environment(\.noteFontSize) private var fontSize
    @State private var store = Store.shared
    let query: String

    @State private var dropOn: UUID?
    @State private var editing: UUID?

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// 苹果备忘录画廊那样：卡片是等高缩略图，正文超出就裁掉，不让一条长便签把整屏撑没。
    private let tileHeight: CGFloat = 152

    /// 上下内边距 20 + 徽标行 13 + 日期行 12 + 两段间距 12，剩下的才是正文预览的高度。
    private var bodyHeight: CGFloat { tileHeight - 20 - 13 - 12 - 12 }

    private var shown: [StickyNote] {
        guard !query.isEmpty else { return store.notes }
        return store.notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(shown) { note in
                card(note)
            }
        }
    }

    private func card(_ note: StickyNote) -> some View {
        let tint = NotePalette.color(note.colorIndex)
        let isEditing = editing == note.id
        return VStack(alignment: .leading, spacing: 6) {
            cardBadges(note, tint: tint)
            cardBody(note, isEditing: isEditing)
                .frame(maxWidth: .infinity, minHeight: bodyHeight, maxHeight: bodyHeight,
                       alignment: .topLeading)
                .clipped()
            Spacer(minLength: 0)
            Text(DateFmt.relative(note.updatedAt))
                .font(.system(size: fontSize - 4))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        // 只兜底不小于 tileHeight：字号调大时整墙一起变高，卡片仍然彼此等高
        .frame(maxWidth: .infinity, minHeight: tileHeight, alignment: .topLeading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        // 兜底：正文字号调大时也不许画到圆角外面
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(isEditing ? 0.9 : 0.5),
                              lineWidth: isEditing ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            Button {
                if isEditing { editing = nil } else { StickyWindowManager.shared.open(note.id) }
            } label: {
                Image(systemName: isEditing ? "checkmark.circle" : "square.and.pencil")
                    .font(.system(size: fontSize - 3))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .padding(3)
            .help(isEditing ? "完成编辑" : "在桌面打开这张便签")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(dropOn == note.id ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 就地编辑时双击是选词，别再弹一个窗口出来
            if !isEditing { StickyWindowManager.shared.open(note.id) }
        }
        .draggable(DragPayload.note(note.id))
        .contextMenu { menu(note) }
        .dropDestination(for: String.self) { payloads, _ in
            guard let id = payloads.compactMap(DragPayload.noteID).first, id != note.id else { return false }
            store.moveNote(id, onto: note.id)
            dropOn = nil
            return true
        } isTargeted: { hot in
            if hot { dropOn = note.id }
            else if dropOn == note.id { dropOn = nil }
        }
    }

    private func cardBadges(_ note: StickyNote, tint: Color) -> some View {
        HStack(spacing: 4) {
            if note.pinnedToDesktop {
                badge("pin.fill", tint, "已钉在桌面")
            }
            if note.collapsed {
                badge("rectangle.compress.vertical", .secondary, "已折叠成一条")
            }
            if let remindAt = note.remindAt {
                badge(remindAt < Date() ? "bell.slash.fill" : "bell.fill",
                      remindAt < Date() ? .red : .secondary,
                      "提醒 \(DateFmt.short.string(from: remindAt))")
            }
            Spacer(minLength: 18)
        }
    }

    @ViewBuilder
    private func cardBody(_ note: StickyNote, isEditing: Bool) -> some View {
        if isEditing {
            MarkdownEditor(text: noteText(note), fontSize: fontSize - 1, autoFocus: true)
        } else {
            NoteBodyView(text: note.text, fontSize: fontSize - 1)
                .contentShape(Rectangle())
                .onTapGesture { startEditing(note.id) }
                .help("点击直接编辑")
        }
    }

    /// 点一下就变成可打字的编辑态，编辑器自己抢焦点。
    private func startEditing(_ id: UUID) {
        editing = id
    }

    private func noteText(_ note: StickyNote) -> Binding<String> {
        Binding(get: { note.text }, set: { value in
            store.mutateNote(note.id) { $0.text = value }
        })
    }

    private func badge(_ symbol: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: fontSize - 4))
            .foregroundStyle(color)
            .help(help)
    }

    @ViewBuilder
    private func menu(_ note: StickyNote) -> some View {
        Button("打开编辑") { StickyWindowManager.shared.open(note.id) }
        Button(note.pinnedToDesktop ? "取消钉到桌面" : "钉到桌面") {
            store.mutateNote(note.id) { $0.pinnedToDesktop.toggle() }
            StickyWindowManager.shared.applyPinnedState(note.id)
        }
        Button(note.collapsed ? "展开便签" : "折叠成一条") {
            StickyWindowManager.shared.toggleCollapsed(note.id)
        }
        Menu("颜色") {
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
        }
        Divider()
        Button("复制正文") { copyToPasteboard(note.text) }
        Button("创建副本") { store.duplicateNote(note.id) }
        Button("删除便签", role: .destructive) {
            let head = note.firstLine
            guard confirmDelete("这张便签", detail: head.isEmpty
                ? "便签是空的。"
                : "「\(String(head.prefix(20)))」共 \(note.text.count) 个字。") else { return }
            StickyWindowManager.shared.close(note.id)
            store.removeNote(note.id)
        }
    }
}
