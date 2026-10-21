import Foundation
import UserNotifications

enum Notifier {
    private static let presenter = ForegroundPresenter()

    /// 一条待排通知的可比较内容：时间、标题、正文任一变了才值得重新排
    private struct Pending: Hashable {
        let fire: Date
        let title: String
        let body: String
    }

    /// 上一次真正交给系统的集合。存盘防抖会反复调 sync，没有这份缓存就等于
    /// 每敲一个字停顿都给 usernoted 发一轮 XPC。
    private static var scheduled: [String: Pending] = [:]

    static func setup() {
        guard !AppEnv.demo else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 每个 Deadline 只排一条通知：到点那一分钟提醒，不再提前、也不再过期补发。
    static func sync(_ store: Store) {
        guard !AppEnv.demo else { return }
        let wanted = desired(store)
        let center = UNUserNotificationCenter.current()
        let stale = scheduled.keys.filter { wanted[$0] == nil }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        for (id, pending) in wanted where scheduled[id] != pending {
            let content = UNMutableNotificationContent()
            content.title = pending.title
            content.body = pending.body
            content.sound = .default
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: pending.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        scheduled = wanted
    }

    /// 已经过期的不排：系统会立刻补一条，用户要的是「到点响一次」而不是「打开就炸一串」
    private static func desired(_ store: Store) -> [String: Pending] {
        let now = Date()
        var out: [String: Pending] = [:]
        for item in store.allItems {
            guard !item.done, let deadline = item.deadline else { continue }
            let fire = nearestMinute(deadline)
            guard fire > now else { continue }
            out[item.id.uuidString] = Pending(
                fire: fire, title: "Deadline 到了",
                body: "「\(item.title)」· \(DateFmt.short.string(from: deadline))")
        }
        for note in store.notes {
            guard let remindAt = note.remindAt else { continue }
            let fire = nearestMinute(remindAt)
            guard fire > now else { continue }
            let head = note.firstLine
            out["note:\(note.id.uuidString)"] = Pending(
                fire: fire, title: "便签提醒",
                body: (head.isEmpty ? "有张便签到点了" : "「\(head)」")
                    + " · \(DateFmt.short.string(from: remindAt))")
        }
        return out
    }

    /// 日历触发器精度只到分钟，四舍五入避免设 23:33:40 却在 23:33:00 就响。
    private static func nearestMinute(_ date: Date) -> Date {
        let cal = Calendar.current
        let minuteStart = cal.date(
            from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
        return cal.component(.second, from: date) >= 30 ? minuteStart.addingTimeInterval(60) : minuteStart
    }
}

/// 系统默认在前台应用是自己时不弹横幅，这里显式要求仍然弹。
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler:
                                   @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
