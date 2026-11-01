import SwiftUI

/// 左侧窄边条：全部 / 已完成 / 各个类别（小方块），下方紧跟新建类别
struct SidebarView: View {
    @Environment(\.noteFontSize) private var fontSize
    @Binding var section: NoteSection
    private var store: Store { Store.shared }
    private var library: LibraryModel { LibraryModel.shared }

    @State private var dropTarget: UUID?
    @State private var hoveredChip: NoteSection?

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.62, blue: 0.55),
        Color(red: 0.72, green: 0.60, blue: 0.42),
        Color(red: 0.62, green: 0.45, blue: 0.58),
        Color(red: 0.42, green: 0.53, blue: 0.72),
        Color(red: 0.70, green: 0.45, blue: 0.42),
        Color(red: 0.48, green: 0.56, blue: 0.64),
    ]

    var body: some View {
        VStack(spacing: 6) {
            // 软件自己的数据：便签 + 事项（全部/完成是事项的快捷视图）。和磁盘上的「库」分开成两层。
            chip("全部", count: store.openCount, tint: Color.accentColor, target: .all)
            chip("完成", count: store.doneCount, tint: .secondary, target: .done, symbol: "checkmark")
            chip("便签", count: store.notes.count, tint: NotePalette.color(0), target: .notes,
                 symbol: "note.text")

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(store.data.categories.enumerated()), id: \.element.id) { index, category in
                        chip(shortName(category.name), count: store.count(in: category),
                             tint: Self.palette[index % Self.palette.count],
                             target: .category(category.id), full: category.name)
                            .frame(height: 41)
                            .overlay(alignment: .center) {
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .frame(width: 54, height: 34)
                                    .opacity(dropTarget == category.id ? 1 : 0)
                            }
                            .draggable(DragPayload.category(category.id))
                            .contextMenu { categoryMenu(category) }
                            .dropDestination(for: String.self) { payloads, _ in
                                guard let id = payloads.compactMap(DragPayload.categoryID).first,
                                      id != category.id else { return false }
                                store.moveCategory(id, onto: category.id)
                                dropTarget = nil
                                return true
                            } isTargeted: { hot in
                                if hot { dropTarget = category.id }
                                else if dropTarget == category.id { dropTarget = nil }
                            }
                    }

                    Button {
                        // 建完立刻进就地改名：先占一个默认名，用户直接打字覆盖。
                        // 顺手切到这个类别，保证接收改名请求的那块一定在屏幕上（不然
                        // 在便签页点 + 的话，请求会一直悬着，等下次进事项页才突然弹输入框）
                        let id = store.addCategory(named: "新类别")
                        section = .category(id)
                        store.renaming = .init(id: id, blank: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .frame(width: 54, height: 34)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("新建类别")
                    .padding(.top, 4)
                }
                .padding(.top, 2)
            }
            .frame(maxHeight: .infinity)
            // 方块下方的空白 = 放到最后
            .dropDestination(for: String.self) { payloads, _ in
                guard let id = payloads.compactMap(DragPayload.categoryID).first else { return false }
                store.moveCategoryToLast(id)
                dropTarget = nil
                return true
            }

            Divider().opacity(0.5)

            // 库 = 磁盘上那一堆 .md，独立一层，不和便签/事项混在一起
            chip("库", count: library.rows.count, tint: Self.palette[0], target: .library,
                 symbol: "folder")
                .help("库：磁盘上那一堆 .md 文件，Typora 和 Obsidian 也能直接改（⌘4）")
        }
        .padding(9)
        .frame(width: 72)
        .background(.primary.opacity(0.05))
    }

    private func shortName(_ name: String) -> String {
        name.count <= 3 ? name : String(name.prefix(3))
    }

    private func chip(_ title: String, count: Int, tint: Color, target: NoteSection,
                      full: String? = nil, symbol: String? = nil) -> some View {
        let selected = section == target
        // 用点击手势而不是 Button：Button 会吃掉 mouseDown，类别方块上的 .draggable 就永远起不来。
        return VStack(spacing: 1) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: fontSize - 3, weight: .semibold))
            } else {
                Text(title)
                    .font(.system(size: fontSize - 3, weight: selected ? .bold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("\(count)").font(.system(size: fontSize - 5).monospacedDigit())
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(width: 54, height: 34)
        .background(
            selected ? AnyShapeStyle(tint)
                     : AnyShapeStyle(tint.opacity(hoveredChip == target ? 0.36 : 0.22)),
            in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.primary.opacity(0.35) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { section = target }
        // 用 onHover 不用 hoverEffect：这一格要能拖放，包一层 Button 会把 mouseDown 吃掉
        .onHover { inside in
            hoveredChip = inside ? target : (hoveredChip == target ? nil : hoveredChip)
        }
        .help(full ?? title)
    }

    @ViewBuilder
    private func categoryMenu(_ category: Category) -> some View {
        Button("新建项目") {
            section = .category(category.id)
            if let id = store.addProject(to: category.id) {
                store.renaming = .init(id: id, blank: true)
            }
        }
        Button("重命名…") {
            section = .category(category.id)
            store.renaming = .init(id: category.id)
        }
        Divider()
        Button("删除类别", role: .destructive) { confirmAndRemoveCategory(category) }
    }
}
