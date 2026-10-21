import SwiftUI
import AppKit

/// 删类别是整块整块地删，侧栏右键和类别块的 ⋯ 都有入口，确认逻辑放一处
@MainActor
func confirmAndRemoveCategory(_ category: Category) {
    let projects = category.projects.count
    let items = category.projects.flatMap(\.items).count
    guard confirmDelete("类别「\(category.name)」",
                        detail: "下面 \(projects) 个项目、\(items) 个事项会一起删掉。") else { return }
    let settings = AppSettings.shared
    if settings.section == .category(category.id) { settings.section = .all }
    Store.shared.removeCategory(category.id)
}

struct RootView: View {
    @State private var store = Store.shared
    @State private var settings = AppSettings.shared
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    // 类别详情页顶部的就地改名：这一页不用 CategoryBlock，认领信号得自己接
    @State private var editingCategoryID: UUID?
    @State private var categoryDraft = ""
    @FocusState private var categoryNameField: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                if !settings.sidebarCollapsed {
                    SidebarView(section: sectionBinding)
                    Divider().opacity(0.4)
                }
                VStack(spacing: 0) {
                    searchBar
                    Divider().opacity(0.4)
                    if settings.section == .notes {
                        NotesBrowserView(query: query)
                    } else {
                        contentScroll
                    }
                }
            }
        }
        .environment(\.noteFontSize, settings.fontSize)
        // 最小尺寸交给 NSWindow.contentMinSize 兜底：这里再写一遍 minHeight，
        // 窗口一旦比它小，SwiftUI 会按自己的最小高度画出去，底部那一行就被裁掉。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 头部要和红绿灯同一行，就得让整棵视图伸进 titlebar 那条安全区（28pt）
        .ignoresSafeArea(.all, edges: .top)
        .background(settings.theme == .dark ? Color.panelDark : Color.panelLight)
        .background(shortcutLayer)
    }

    /// 快捷键没有原生承载点，只能挂在真的 Button 上；藏起来不吃布局、不参与 Tab
    private var shortcutLayer: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("f")
            Button("") { settings.section = .all }.keyboardShortcut("1")
            Button("") { settings.section = .done }.keyboardShortcut("2")
            Button("") { settings.section = .notes }.keyboardShortcut("3")
            Button("") { AppDelegate.shared?.hideMainWindow() }.keyboardShortcut("w")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var contentScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    detail
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 桌面面板点了某一行：等这一页画出来再滚过去，高亮留 1.4 秒
            .onChange(of: store.revealRequest) { _, target in
                guard let target else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo(target, anchor: .center)
                    try? await Task.sleep(for: .seconds(1.4))
                    if store.revealRequest == target { store.revealRequest = nil }
                }
            }
        }
    }

    private var sectionBinding: Binding<NoteSection> {
        Binding(get: { settings.section }, set: { settings.section = $0 })
    }

    @ViewBuilder
    private var detail: some View {
        if !query.isEmpty {
            searchResults
        } else {
            switch settings.section {
            case .all:
                ForEach(store.data.categories) { category in
                    CategoryBlock(category: category)
                }
            case .done:
                doneList
            case .notes:
                EmptyView()
            case .category(let id):
                if let category = store.category(id) {
                    categoryDetail(category)
                } else {
                    Text("这个类别已经被删除了")
                        .font(.system(size: fontSize - 1))
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
    }

    private func categoryDetail(_ category: Category) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if editingCategoryID == category.id {
                    TextField("类别名称", text: $categoryDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize + 1, weight: .bold))
                        .frame(maxWidth: 200)
                        .focused($categoryNameField)
                        .onSubmit { commitCategoryName(category) }
                        // 点别处就该当作改完了，不然输入框会一直悬在那儿
                        .onChange(of: categoryNameField) { _, hot in
                            if !hot, editingCategoryID == category.id { commitCategoryName(category) }
                        }
                } else {
                    Text(category.name)
                        .font(.system(size: fontSize + 1, weight: .bold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { beginCategoryRename(category, keep: true) }
                }
                Text("\(store.count(in: category)) 项")
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let id = store.addProject(to: category.id) {
                        store.renaming = .init(id: id, blank: true)
                    }
                } label: {
                    Label("新建项目", systemImage: "plus")
                        .font(.system(size: fontSize - 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("建完直接打字起名")
            }

            ForEach(category.projects) { project in
                ProjectBlock(categoryID: category.id, project: project)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }

            if category.projects.isEmpty {
                Text("还没有项目，点右上角「新建项目」。")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { claimCategoryRename(category) }
        .onChange(of: store.renaming) { _, _ in claimCategoryRename(category) }
    }

    private func claimCategoryRename(_ category: Category) {
        guard let request = store.renaming, request.id == category.id else { return }
        store.renaming = nil
        beginCategoryRename(category, keep: !request.blank)
    }

    /// keep = false 用于新建：默认名不塞进输入框，直接打字就行
    private func beginCategoryRename(_ category: Category, keep: Bool) {
        categoryDraft = keep ? category.name : ""
        editingCategoryID = category.id
        DispatchQueue.main.async { categoryNameField = true }
    }

    private func commitCategoryName(_ category: Category) {
        if !categoryDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            store.renameCategory(category.id, to: categoryDraft)
        }
        editingCategoryID = nil
    }

    private var doneList: some View {
        let done = store.doneItems
        return VStack(alignment: .leading, spacing: 6) {
            if done.isEmpty {
                Text("还没有已完成的事项。")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(done) { located in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(located.categoryName) › \(located.projectName)")
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(.tertiary)
                    ItemRow(item: located.item)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var fontSize: Double { settings.fontSize }

    private var header: some View {
        HStack(spacing: 8) {
            headerSymbol(settings.sidebarCollapsed ? "sidebar.left" : "sidebar.leading",
                         settings.sidebarCollapsed ? "展开类别栏" : "收起类别栏") {
                settings.sidebarCollapsed.toggle()
            }
            Image(systemName: "note.text")
                .foregroundStyle(.tint)
            Text("便签").font(.system(size: fontSize + 1, weight: .bold))
            // 事项计数在便签页里对不上号，张数由下面的工具栏报
            if settings.section != .notes {
                Text("\(store.openCount) 待完成 · \(store.doneCount) 已完成")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            headerSymbol("gearshape", "便签设置") { AppDelegate.shared?.showSettingsWindow() }
        }
        // 红绿灯实测占窗口 x 6…62、y 6…22（中心 14），左边让开它、上边按中心对齐
        .padding(.trailing, 14)
        .padding(.leading, 70)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // SF Symbol 字形（尤其 minus）几乎是一条线，必须显式撑出可点击的方块。
    private func headerSymbol(_ name: String, _ help: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: fontSize - 2))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.secondary)
            TextField(settings.section == .notes ? "搜索便签内容" : "搜索事项、项目名称", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize - 1))
                .focused($searchFocused)
                .onExitCommand {
                    // Esc：有内容先清空，已经空了就退出搜索框
                    if query.isEmpty { searchFocused = false } else { query = "" }
                }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchResults: some View {
        let q = query.lowercased()
        let hits = store.locatedItems.filter { $0.item.title.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 6) {
            if hits.isEmpty {
                Text("没有匹配的事项")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            ForEach(hits) { located in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(located.categoryName) › \(located.projectName)")
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(.tertiary)
                    ItemRow(item: located.item)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct CategoryBlock: View {
    @Environment(\.noteFontSize) private var fontSize
    private var store: Store { Store.shared }
    let category: Category

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    store.toggleCategoryCollapsed(category.id)
                } label: {
                    Image(systemName: category.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: fontSize - 3, weight: .semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                if editing {
                    TextField("类别名称", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize, weight: .bold))
                        .frame(maxWidth: 160)
                        .focused($nameField)
                        .onSubmit { commit() }
                        // 点别处就该当作改完了，不然输入框会一直悬在那儿
                        .onChange(of: nameField) { _, hot in if !hot, editing { commit() } }
                } else {
                    Text(category.name)
                        .font(.system(size: fontSize, weight: .bold))
                        .onTapGesture(count: 2) { beginRename(keep: true) }
                }

                Spacer()
                Text("\(store.count(in: category)) 项")
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("新建项目") {
                        if let id = store.addProject(to: category.id) {
                            store.renaming = .init(id: id, blank: true)
                        }
                    }
                    Button("重命名") { beginRename(keep: true) }
                    Divider()
                    Button("删除类别", role: .destructive) { confirmAndRemoveCategory(category) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: fontSize - 2))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
            }

            if !category.collapsed {
                ForEach(category.projects) { project in
                    ProjectBlock(categoryID: category.id, project: project)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { claimRename() }
        .onChange(of: store.renaming) { _, _ in claimRename() }
    }

    /// 改名请求由类别块自己认领：新建要空着输入框，从侧栏点「重命名」要带着现名
    private func claimRename() {
        guard let request = store.renaming, request.id == category.id else { return }
        store.renaming = nil
        beginRename(keep: !request.blank)
    }

    /// keep = false 用于新建：默认名（「新类别」）不塞进输入框，直接打字就行
    private func beginRename(keep: Bool) {
        draft = keep ? category.name : ""
        editing = true
        DispatchQueue.main.async { nameField = true }
    }

    private func commit() {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            store.renameCategory(category.id, to: draft)
        }
        editing = false
    }
}

struct ProjectBlock: View {
    @Environment(\.noteFontSize) private var fontSize
    private var store: Store { Store.shared }
    let categoryID: UUID
    let project: Project

    @State private var newTitle = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var dropOn: UUID?
    @State private var dropAtEnd = false
    @FocusState private var nameField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: project.collapsed ? "circle" : "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.tertiary)
                    .onTapGesture { store.toggleProjectCollapsed(categoryID: categoryID, projectID: project.id) }
                if editing {
                    TextField("项目名称", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .frame(maxWidth: 160)
                        .focused($nameField)
                        .onSubmit { commit() }
                        .onChange(of: nameField) { _, hot in if !hot, editing { commit() } }
                } else {
                    Text(project.name)
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .onTapGesture(count: 2) { beginRename(keep: true) }
                }
                Spacer()
                Menu {
                    Button("重命名") { beginRename(keep: true) }
                    Divider()
                    Button("删除项目", role: .destructive) { confirmRemove() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: fontSize - 3))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
            .foregroundStyle(.secondary)

            if !project.collapsed {
                ForEach(project.items) { item in
                    ItemRow(item: item)
                        .background(Color.accentColor.opacity(dropOn == item.id ? 0.25 : 0),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                .opacity(dropOn == item.id ? 1 : 0))
                        .draggable(DragPayload.item(item.id))
                        .dropDestination(for: String.self) { payloads, _ in
                            guard let id = payloads.compactMap(DragPayload.itemID).first,
                                  id != item.id else { return false }
                            store.moveItem(id, onto: item.id)
                            dropOn = nil
                            return true
                        } isTargeted: { hot in
                            if hot { dropOn = item.id }
                            else if dropOn == item.id { dropOn = nil }
                        }
                }
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: fontSize - 3))
                        .foregroundStyle(.tertiary)
                    TextField("添加事项，回车确认", text: $newTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize - 1))
                        .onSubmit {
                            store.addItem(categoryID: categoryID, projectID: project.id, title: newTitle)
                            newTitle = ""
                        }
                }
                .padding(.top, 2)
                .background(Color.accentColor.opacity(dropAtEnd ? 0.25 : 0),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .opacity(dropAtEnd ? 1 : 0))
                .dropDestination(for: String.self) { payloads, _ in
                    guard let id = payloads.compactMap(DragPayload.itemID).first else { return false }
                    store.moveItem(id, toEndOfProject: project.id)
                    dropAtEnd = false
                    return true
                } isTargeted: { hot in
                    dropAtEnd = hot
                }
            }
        }
        .padding(.leading, 14)
        .onAppear { claimRename() }
        .onChange(of: store.renaming) { _, _ in claimRename() }
    }

    private func claimRename() {
        guard let request = store.renaming, request.id == project.id else { return }
        store.renaming = nil
        beginRename(keep: !request.blank)
    }

    /// keep = false 用于新建：默认名「新项目」不塞进输入框，直接打字就行
    private func beginRename(keep: Bool) {
        draft = keep ? project.name : ""
        editing = true
        DispatchQueue.main.async { nameField = true }
    }

    private func commit() {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            store.renameProject(categoryID: categoryID, projectID: project.id, to: draft)
        }
        editing = false
    }

    private func confirmRemove() {
        let items = project.items.count
        guard confirmDelete("项目「\(project.name)」",
                            detail: "下面 \(items) 个事项会一起删掉。") else { return }
        store.removeProject(categoryID: categoryID, projectID: project.id)
    }
}

struct ItemRow: View {
    @Environment(\.noteFontSize) private var fontSize
    private var store: Store { Store.shared }
    let item: DeskItem

    @State private var showPicker = false
    @State private var pickerDate = Date().addingTimeInterval(3600)
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameField: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.toggleItem(item.id)
            } label: {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: fontSize + 1))
                    .foregroundStyle(item.done ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            if editing {
                TextField("事项内容", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .focused($nameField)
                    .onSubmit { commit() }
                    .onChange(of: nameField) { _, hot in if !hot, editing { commit() } }
            } else {
                Text(item.title)
                    .font(.system(size: fontSize))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .lineLimit(2)
                    // 类别、项目都能双击改名，唯独事项不能，之前只能删了重建。
                    // 整行挂了 .draggable，父层的拖拽会把普通 onTapGesture 吃掉，
                    // 必须用 highPriorityGesture 让双击赢过拖拽。
                    .highPriorityGesture(TapGesture(count: 2).onEnded { beginRename() })
            }

            Spacer(minLength: 4)

            if let deadline = item.deadline {
                let status = DeadlineStatus.of(deadline, done: item.done)
                Text(DateFmt.short.string(from: deadline))
                    .font(.system(size: fontSize - 3).monospacedDigit())
                    .foregroundStyle(item.done ? AnyShapeStyle(.tertiary) : AnyShapeStyle(status.color))
            }

            Menu {
                Button("重命名") { beginRename() }
                Button("设置 Deadline…") {
                    pickerDate = item.deadline ?? Date().addingTimeInterval(3600)
                    showPicker = true
                }
                if item.deadline != nil {
                    Button("清除 Deadline") { store.setDeadline(item.id, to: nil) }
                }
                Divider()
                Button("删除", role: .destructive) { store.removeItem(item.id) }
            } label: {
                Image(systemName: "clock").font(.system(size: fontSize - 2))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                DeadlineEditor(
                    date: $pickerDate,
                    onOK: {
                        store.setDeadline(item.id, to: pickerDate)
                        showPicker = false
                    },
                    onClear: {
                        store.setDeadline(item.id, to: nil)
                        showPicker = false
                    },
                    onCancel: { showPicker = false }
                )
            }
        }
        .padding(.vertical, 1)
        // 从桌面面板跳过来时闪一下，不然滚过来了也不知道是哪条。
        // 窗口本身有 24% 透明度，纯底色几乎看不出来，所以和拖放目标一样再描一圈边。
        .background(Color.accentColor.opacity(store.revealRequest == item.id ? 0.28 : 0),
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .opacity(store.revealRequest == item.id ? 1 : 0))
        .id(item.id)
    }

    private func beginRename() {
        draft = item.title
        editing = true
        DispatchQueue.main.async { nameField = true }
    }

    private func commit() {
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
            store.mutateItem(item.id) { $0.title = draft }
        }
        editing = false
    }
}

/// Deadline picker: editable date/time fields plus quick presets.
struct DeadlineEditor: View {
    @Binding var date: Date
    var onOK: () -> Void
    var onClear: () -> Void
    var onCancel: () -> Void

    private static let fullFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .labelsHidden()
                .controlSize(.large)

            Text(Self.fullFmt.string(from: date))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                presetButton("1小时后") { Date().addingTimeInterval(3600) }
                presetButton("今晚 20:00") {
                    let cal = Calendar.current
                    let now = Date()
                    var comps = cal.dateComponents([.year, .month, .day], from: now)
                    comps.hour = 20
                    let tonight = cal.date(from: comps) ?? now
                    return tonight > now ? tonight : tonight.addingTimeInterval(86400)
                }
                presetButton("明早 9:00") {
                    let cal = Calendar.current
                    var comps = cal.dateComponents([.year, .month, .day], from: Date())
                    comps.hour = 9
                    comps.day = (comps.day ?? 1) + 1
                    return cal.date(from: comps) ?? Date().addingTimeInterval(86400)
                }
            }

            Divider()

            HStack {
                Button("清除", action: onClear)
                Spacer()
                Button("取消", action: onCancel)
                Button("确定", action: onOK).keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func presetButton(_ label: String, _ make: @escaping () -> Date) -> some View {
        Button(label) { date = make() }
            .controlSize(.small)
    }
}
