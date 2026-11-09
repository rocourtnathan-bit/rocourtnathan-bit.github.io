import SwiftUI
import SwiftData

struct StatsView: View {
    @Query(sort: \Goal.sortOrder) private var goals: [Goal]

    var body: some View {
        NavigationStack {
            List {
                if goals.isEmpty {
                    ContentUnavailableView("Nothing to show yet",
                                           systemImage: "chart.bar",
                                           description: Text("Add a goal and check it off to see progress."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(goals) { goal in
                        GoalStatsCard(goal: goal)
                    }
                }
            }
            .navigationTitle("Progress")
        }
    }
}

private struct GoalStatsCard: View {
    let goal: Goal

    private var lastSevenDays: [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(goal.emoji) \(goal.title)").font(.headline)

            HStack(spacing: 8) {
                ForEach(lastSevenDays, id: \.self) { day in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(goal.isDone(on: day) ? Color.green : Color.gray.opacity(0.25))
                            .frame(width: 26, height: 26)
                            .overlay {
                                if goal.isDone(on: day) {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            HStack {
                stat("🔥 \(goal.currentStreak)", "Current streak")
                Spacer()
                stat("🏆 \(goal.bestStreak)", "Best streak")
                Spacer()
                stat("\(Int(goal.completionRate() * 100))%", "Last 30 days")
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
