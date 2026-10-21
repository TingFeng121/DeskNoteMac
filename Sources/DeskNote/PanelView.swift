import SwiftUI

/// 桌面待办面板，样式对齐滴答清单：圆形勾选框按紧急度着色，
/// 每条下面一行小灰字写「类别 › 项目」，右侧是相对时间，底部一条完成进度。
struct PanelView: View {
    private var store: Store { Store.shared }
    private var settings: AppSettings { .shared }
    private var fontSize: Double { settings.fontSize }

    @State private var draft = ""
    @FocusState private var adding: Bool

    /// 快速添加的落点：记住上次选的，那个项目被删了就退回第一个可用的
    private var target: (category: Category, project: Project)? {
        let saved = settings.quickAddProjectID.flatMap(UUID.init(uuidString:))
        return store.resolveProject(saved)
    }

    private var rows: [Store.Located] {
        Array(store.sortedItems(store.locatedItems.filter { !$0.item.done }).prefix(12))
    }

    private var total: Int { store.openCount + store.doneCount }

    private var overdueCount: Int {
        store.locatedItems.filter {
            guard !$0.item.done, let deadline = $0.item.deadline else { return false }
            return deadline <= Date()
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer().frame(height: 8)
            rule
            quickAdd
            Spacer().frame(height: 2)
            list
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        // 尺寸跟着窗口走，最小值交给 NSWindow.contentMinSize 兜底（同 RootView）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.noteFontSize, settings.fontSize)
        .background(settings.theme == .dark ? Color.panelDark : Color.panelLight)
        // 同便签浮窗：不忽略安全区的话 AppKit 会为标题栏让出顶部 28pt，
        // 360 高的内容被顶下去，底部那行完成进度就会被窗口裁掉
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: fontSize))
                .foregroundStyle(.tint)
            Text("待办")
                .font(.system(size: fontSize + 3, weight: .bold))
            Spacer()
            Text(Self.today.string(from: Date()))
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.secondary)
        }
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }

    /// 快速添加：不用回主窗口就能记一条。落点默认沿用上次的，右边小箭头可以换项目。
    private var quickAdd: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField(target.map { "添加到 \($0.category.name) › \($0.project.name)" }
                             ?? "先建一个项目",
                      text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(target == nil ? Color.secondary : Color.primary)
                .focused($adding)
                .onSubmit(submit)
                .help("回车添加，不用回主窗口")
            Menu {
                ForEach(store.data.categories) { category in
                    ForEach(category.projects) { project in
                        Button("\(category.name) › \(project.name)") {
                            settings.quickAddProjectID = project.id.uuidString
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: fontSize - 5, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            // borderlessButton 自己会带一个箭头，不藏掉就是两个叠在一起
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        guard let target else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addItem(categoryID: target.category.id, projectID: target.project.id, title: text)
        draft = ""
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    empty
                } else {
                    ForEach(rows) { row($0) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("全部完成，没有待办")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 46)
    }

    private func row(_ located: Store.Located) -> some View {
        let item = located.item
        let status = DeadlineStatus.of(item.deadline, done: false)
        return HStack(alignment: .top, spacing: 9) {
            check(item, tint: status == .none ? Color.secondary.opacity(0.55) : status.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(located.categoryName) › \(located.projectName)")
                        .font(.system(size: fontSize - 4))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let deadline = item.deadline {
                        Text(Self.stamp(deadline))
                            .font(.system(size: fontSize - 4))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 桌面面板上当快捷查看可以，真要改名字/排期还是得回主窗口：点一下直接跳过去
        .onTapGesture { AppDelegate.shared?.reveal(itemID: item.id) }
        .help("在主窗口打开")
    }

    /// 勾选圈：只描边，颜色跟着紧急度走
    private func check(_ item: DeskItem, tint: Color) -> some View {
        Button {
            store.toggleItem(item.id)
        } label: {
            Circle()
                .strokeBorder(tint, lineWidth: 1.5)
                .frame(width: fontSize + 3, height: fontSize + 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("标记为已完成")
    }

    private var footer: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(store.doneCount) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 3)
            HStack {
                Text("已完成 \(store.doneCount) / \(total)")
                Spacer()
                if overdueCount > 0 {
                    Text("\(overdueCount) 项逾期").foregroundStyle(.red)
                }
            }
            .font(.system(size: fontSize - 4))
            .foregroundStyle(.tertiary)
        }
    }

    private static let today: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    /// 逾期、今天、明天说人话，再远才给绝对日期
    static func stamp(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        if date <= now {
            let mins = max(1, Int(now.timeIntervalSince(date) / 60))
            if mins < 60 { return "逾期 \(mins) 分钟" }
            if mins < 60 * 24 { return "逾期 \(mins / 60) 小时" }
            return "逾期 \(mins / 1440) 天"
        }
        if cal.isDateInToday(date) { return "今天 \(clock.string(from: date))" }
        if cal.isDateInTomorrow(date) { return "明天 \(clock.string(from: date))" }
        return cal.isDate(date, equalTo: now, toGranularity: .year)
            ? monthDay.string(from: date) : DateFmt.short.string(from: date)
    }
}
