import Foundation
import UserNotifications

/// Schedules "you haven't done this yet" reminders at each goal's deadline.
///
/// iOS can't run code at the deadline to check whether you finished, so instead we
/// pre-schedule one-off notifications for the next few days and rebuild them whenever
/// goals change or the app opens. If a goal is already done today, today's reminder
/// is simply not scheduled.
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    func reschedule(goals: [Goal]) async {
        center.removeAllPendingNotificationRequests()

        let active = goals.filter { $0.remindersOn }
        guard !active.isEmpty else { return }

        // iOS allows 64 pending notifications; stay under it.
        let daysAhead = min(7, max(1, 60 / active.count))
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = Date()

        for goal in active {
            for offset in 0..<daysAhead {
                guard let day = cal.date(byAdding: .day, value: offset, to: today),
                      let fire = cal.date(bySettingHour: goal.deadlineHour,
                                          minute: goal.deadlineMinute,
                                          second: 0,
                                          of: day),
                      fire > now else { continue }
                if offset == 0 && goal.isDoneToday { continue }

                let content = UNMutableNotificationContent()
                content.title = "\(goal.emoji) \(goal.title)"
                content.body = "Not done yet. Knock it out before the day ends."
                content.sound = .default

                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let request = UNNotificationRequest(identifier: "\(goal.id.uuidString)-\(offset)",
                                                    content: content,
                                                    trigger: trigger)
                try? await center.add(request)
            }
        }
    }
}
