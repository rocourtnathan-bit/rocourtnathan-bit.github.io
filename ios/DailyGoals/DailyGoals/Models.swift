import Foundation
import SwiftData

@Model
final class Goal {
    var id: UUID
    var title: String
    var emoji: String
    var createdAt: Date
    var deadlineHour: Int
    var deadlineMinute: Int
    var remindersOn: Bool
    /// Each entry is the start-of-day of a day this goal was completed.
    var completedDays: [Date]
    var sortOrder: Int

    init(title: String,
         emoji: String = "🎯",
         deadlineHour: Int = 21,
         deadlineMinute: Int = 0,
         remindersOn: Bool = true,
         sortOrder: Int = 0) {
        self.id = UUID()
        self.title = title
        self.emoji = emoji
        self.createdAt = Date()
        self.deadlineHour = deadlineHour
        self.deadlineMinute = deadlineMinute
        self.remindersOn = remindersOn
        self.completedDays = []
        self.sortOrder = sortOrder
    }
}

extension Goal {
    private var cal: Calendar { Calendar.current }

    func isDone(on day: Date) -> Bool {
        completedDays.contains(cal.startOfDay(for: day))
    }

    var isDoneToday: Bool { isDone(on: Date()) }

    func toggle(on day: Date = Date()) {
        let d = cal.startOfDay(for: day)
        if let i = completedDays.firstIndex(of: d) {
            completedDays.remove(at: i)
        } else {
            completedDays.append(d)
        }
    }

    /// Consecutive completed days ending today (or yesterday if today isn't done yet).
    var currentStreak: Int {
        let set = Set(completedDays)
        var day = cal.startOfDay(for: Date())
        if !set.contains(day) {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var count = 0
        while set.contains(day) {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    var bestStreak: Int {
        let days = Set(completedDays).sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for d in days {
            if let p = previous, cal.date(byAdding: .day, value: 1, to: p) == d {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = d
        }
        return best
    }

    /// Fraction of the last `days` days (since the goal was created) that were completed.
    func completionRate(lastDays days: Int = 30) -> Double {
        let today = cal.startOfDay(for: Date())
        let created = cal.startOfDay(for: createdAt)
        let set = Set(completedDays)
        var total = 0
        var done = 0
        for offset in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today), d >= created else { continue }
            total += 1
            if set.contains(d) { done += 1 }
        }
        return total == 0 ? 0 : Double(done) / Double(total)
    }

    var deadlineDate: Date {
        cal.date(bySettingHour: deadlineHour, minute: deadlineMinute, second: 0, of: Date()) ?? Date()
    }

    /// True if it's past today's deadline and the goal isn't done.
    var isOverdue: Bool {
        !isDoneToday && Date() > deadlineDate
    }

    var deadlineText: String {
        deadlineDate.formatted(date: .omitted, time: .shortened)
    }
}
