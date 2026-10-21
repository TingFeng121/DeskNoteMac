import Foundation

struct DeskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var done = false
    var deadline: Date? = nil
    var createdAt = Date()
}

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var collapsed = false
    var items: [DeskItem] = []
}

struct Category: Identifiable, Codable {
    var id = UUID()
    var name: String
    var collapsed = false
    var projects: [Project] = [Project(name: "默认项目")]
}

/// 便签：正文为主，Markdown 纯文本存储，渲染时才解析
struct StickyNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var colorIndex = 0
    var pinnedToDesktop = false
    var collapsed = false
    /// 折叠前的窗口高度，展开时还原；不存的话折叠一次就把用户拖出来的尺寸弄丢了
    var expandedHeight: Double? = nil
    var remindAt: Date? = nil
    var createdAt = Date()
    var updatedAt = Date()

    var firstLine: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map {
            String($0).replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        } ?? ""
    }

    /// 一个字都没写过（只剩空白和换行）。触发角复用草稿、关窗时顺手删掉都看这个
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 列表页标题下面的那一行预览：第一行之后的正文，换行压成空格
    var preview: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            .joined(separator: " ")
    }
}

extension StickyNote {
    private enum CodingKeys: String, CodingKey {
        case id, text, colorIndex, pinnedToDesktop, collapsed, expandedHeight, remindAt, createdAt, updatedAt
    }

    /// 合成的解码对缺字段直接抛错，旧 data.json 里没有 collapsed / expandedHeight，
    /// 逐字段 decodeIfPresent 才不会让整批便签读不出来。写在 extension 里，成员初始化器还在。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex) ?? 0
        pinnedToDesktop = try c.decodeIfPresent(Bool.self, forKey: .pinnedToDesktop) ?? false
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        expandedHeight = try c.decodeIfPresent(Double.self, forKey: .expandedHeight)
        remindAt = try c.decodeIfPresent(Date.self, forKey: .remindAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct BoardData: Codable {
    var categories: [Category] = []
    var notes: [StickyNote] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case categories
        case notes
    }

    /// 旧版本 data.json 里没有 notes，缺字段时要能正常读出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent([Category].self, forKey: .categories) ?? []
        notes = try container.decodeIfPresent([StickyNote].self, forKey: .notes) ?? []
    }
}

/// 左侧导航选中的分区
enum NoteSection: Hashable {
    case all
    case done
    case notes
    case category(UUID)

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .done: return "done"
        case .notes: return "notes"
        case .category(let id): return "category:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "all" { self = .all; return }
        if rawValue == "done" { self = .done; return }
        if rawValue == "notes" { self = .notes; return }
        let prefix = "category:"
        guard rawValue.hasPrefix(prefix),
              let id = UUID(uuidString: String(rawValue.dropFirst(prefix.count))) else { return nil }
        self = .category(id)
    }
}
