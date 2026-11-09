import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Goal.sortOrder) private var goals: [Goal]

    @State private var showingNew = false
    @State private var editing: Goal?

    private var doneCount: Int { goals.filter { $0.isDoneToday }.count }

    var body: some View {
        NavigationStack {
            List {
                if goals.isEmpty {
                    ContentUnavailableView("No goals yet",
                                           systemImage: "target",
                                           description: Text("Tap + to add your first goal."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ProgressHeader(done: doneCount, total: goals.count)
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(goals) { goal in
                            GoalRow(goal: goal)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = goal }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle(Date().formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingNew) {
                GoalEditor(goal: nil, nextSortOrder: (goals.map(\.sortOrder).max() ?? -1) + 1)
            }
            .sheet(item: $editing) { goal in
                GoalEditor(goal: goal, nextSortOrder: goal.sortOrder)
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(goals[i]) }
    }
}

private struct ProgressHeader: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                    .stroke(.green, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: done)
                Text("\(done)/\(total)").font(.headline)
            }
            .frame(width: 80, height: 80)

            VStack(alignment: .leading, spacing: 4) {
                Text(done == total ? "All done today 🎉" : "\(total - done) left today")
                    .font(.title3.bold())
                Text(done == total ? "Nice work. See you tomorrow." : "Check them off as you go.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct GoalRow: View {
    @Bindable var goal: Goal

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { goal.toggle() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Image(systemName: goal.isDoneToday ? "checkmark.circle.fill" : "circle")
                    .font(.title)
                    .foregroundStyle(goal.isDoneToday ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(goal.emoji) \(goal.title)")
                    .strikethrough(goal.isDoneToday)
                    .foregroundStyle(goal.isDoneToday ? .secondary : .primary)
                HStack(spacing: 6) {
                    Label("by \(goal.deadlineText)", systemImage: goal.remindersOn ? "bell.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(goal.isOverdue ? .red : .secondary)
                    if goal.isOverdue {
                        Text("Overdue").font(.caption.bold()).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            if goal.currentStreak > 0 {
                Text("🔥 \(goal.currentStreak)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
