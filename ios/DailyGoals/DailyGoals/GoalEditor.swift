import SwiftUI
import SwiftData

struct GoalEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let goal: Goal?
    let nextSortOrder: Int

    @State private var title = ""
    @State private var emoji = "🎯"
    @State private var deadline = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var remindersOn = true

    private let emojis = ["🎯", "💪", "📚", "🏃", "💧", "🧘", "😴", "🥗", "💻", "🎸", "🧹", "💰", "✍️", "🙏"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("What do you want to do?", text: $title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(emojis, id: \.self) { e in
                                Text(e)
                                    .font(.title)
                                    .padding(6)
                                    .background(e == emoji ? Color.accentColor.opacity(0.25) : .clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .onTapGesture { emoji = e }
                            }
                        }
                    }
                }
                Section {
                    DatePicker("Finish by", selection: $deadline, displayedComponents: .hourAndMinute)
                    Toggle("Remind me if not done", isOn: $remindersOn)
                } header: {
                    Text("Deadline")
                } footer: {
                    Text("If the goal isn't checked off by this time, you'll get a notification.")
                }
            }
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let goal else { return }
        title = goal.title
        emoji = goal.emoji
        remindersOn = goal.remindersOn
        deadline = Calendar.current.date(bySettingHour: goal.deadlineHour,
                                         minute: goal.deadlineMinute,
                                         second: 0,
                                         of: Date()) ?? Date()
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: deadline)
        let hour = comps.hour ?? 21
        let minute = comps.minute ?? 0
        let clean = title.trimmingCharacters(in: .whitespaces)

        if let goal {
            goal.title = clean
            goal.emoji = emoji
            goal.deadlineHour = hour
            goal.deadlineMinute = minute
            goal.remindersOn = remindersOn
        } else {
            context.insert(Goal(title: clean,
                                emoji: emoji,
                                deadlineHour: hour,
                                deadlineMinute: minute,
                                remindersOn: remindersOn,
                                sortOrder: nextSortOrder))
        }
        dismiss()
    }
}
