import SwiftUI
import SwiftData

@main
struct DailyGoalsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: Goal.self)
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Goal.sortOrder) private var goals: [Goal]

    /// Changes whenever something that affects reminders changes.
    private var reminderSignature: [String] {
        goals.map { "\($0.id)|\($0.completedDays.count)|\($0.deadlineHour):\($0.deadlineMinute)|\($0.remindersOn)|\($0.title)" }
    }

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "checklist") }
            StatsView()
                .tabItem { Label("Progress", systemImage: "chart.bar.fill") }
        }
        .task {
            _ = await NotificationManager.shared.requestAuthorization()
            await NotificationManager.shared.reschedule(goals: goals)
        }
        .onChange(of: reminderSignature) {
            Task { await NotificationManager.shared.reschedule(goals: goals) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await NotificationManager.shared.reschedule(goals: goals) }
            }
        }
    }
}
