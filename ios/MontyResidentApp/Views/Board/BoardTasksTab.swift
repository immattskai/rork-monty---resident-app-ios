import SwiftUI

@MainActor
@Observable
final class BoardTasksViewModel {
    var tasks: [BoardTask] = []
    var loading: Bool = true
    var error: String?
    private var lastPropertyId: String?

    func load(propertyId: String, force: Bool = false) async {
        if !force, lastPropertyId == propertyId, !tasks.isEmpty {
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            tasks = try await MontyResidentAppService.fetchBoardTasks(propertyId: propertyId)
            lastPropertyId = propertyId
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    func updateStatus(_ id: String, status: String) async {
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].status = status
        }
        _ = try? await MontyResidentAppService.updateBoardTaskStatus(taskId: id, status: status)
    }

    func updatePriority(_ id: String, priority: String) async {
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            tasks[i].priority = priority
        }
        _ = try? await MontyResidentAppService.updateBoardTaskPriority(taskId: id, priority: priority)
    }

    func delete(_ id: String) async {
        tasks.removeAll { $0.id == id }
        try? await MontyResidentAppService.deleteBoardTask(taskId: id)
    }

    func create(propertyId: String, title: String, description: String?, priority: String, dueDate: String?) async {
        do {
            let row = try await MontyResidentAppService.createBoardTask(
                propertyId: propertyId,
                title: title,
                description: description,
                priority: priority,
                dueDate: dueDate
            )
            tasks.insert(row, at: 0)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private let kColumns: [(key: String, title: String)] = [
    ("backlog", "Backlog"),
    ("todo", "To Do"),
    ("in_progress", "In Progress"),
    ("done", "Done")
]

struct BoardTasksTab: View {
    let propertyId: String?
    @State private var vm = BoardTasksViewModel()
    @State private var showCreate = false
    @State private var selectedTask: BoardTask?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            createFAB
        }
        .task(id: propertyId) {
            guard let pid = propertyId, !pid.isEmpty else { return }
            await vm.load(propertyId: pid)
        }
        .sheet(isPresented: $showCreate) {
            CreateTaskSheet { title, desc, priority, due in
                guard let pid = propertyId else { return }
                Task { await vm.create(propertyId: pid, title: title, description: desc, priority: priority, dueDate: due) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedTask) { task in
            BoardTaskDetailSheet(task: task)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.tasks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if let err = vm.error, vm.tasks.isEmpty {
            VStack(spacing: 8) {
                Text("Couldn't load tasks").font(.system(size: 15, weight: .semibold))
                Text(err).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.chrome(0.55))
            }
            .padding(16)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(kColumns, id: \.key) { col in
                        column(key: col.key, title: col.title)
                            .frame(width: 280)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 380)
        }
    }

    @ViewBuilder
    private func column(key: String, title: String) -> some View {
        let items = vm.tasks.filter { ($0.status ?? "").lowercased() == key }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.chrome(0.55))
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.chrome(0.45))
                Spacer()
            }
            if items.isEmpty {
                Text("—")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.40))
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.chrome(0.08), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    )
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { t in
                        TaskCard(task: t)
                            .onTapGesture {
                                Haptics.tap()
                                selectedTask = t
                            }
                            .contextMenu {
                                ForEach(kColumns, id: \.key) { c in
                                    if c.key != (t.status ?? "") {
                                        Button("Move to \(c.title)") {
                                            Task { await vm.updateStatus(t.id, status: c.key) }
                                        }
                                    }
                                }
                                Divider()
                                Menu("Priority") {
                                    ForEach(["urgent", "high", "medium", "low"], id: \.self) { p in
                                        Button(p.capitalized) {
                                            Task { await vm.updatePriority(t.id, priority: p) }
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task { await vm.delete(t.id) }
                                }
                            }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.chrome(0.04))
        )
    }

    private var createFAB: some View {
        Button {
            Haptics.tap()
            showCreate = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.accentBlue))
                .shadow(color: Theme.accentBlue.opacity(0.45), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Task card

private struct TaskCard: View {
    let task: BoardTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(task.title?.isEmpty == false ? task.title! : "Untitled task")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                priorityPill
            }
            HStack(spacing: 8) {
                if let date = task.dueDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                        Text(Fmt.short(date))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(task.isOverdue ? Theme.danger : Color.chrome(0.55))
                }
                Spacer(minLength: 0)
                avatar
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard)
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6)
            }
        )
        .clipShape(.rect(cornerRadius: 14))
        .shadow(color: Theme.cardDropShadow, radius: 6, y: 2)
    }

    @ViewBuilder
    private var priorityPill: some View {
        let p = (task.priority ?? "medium").lowercased()
        let color: Color = {
            switch p {
            case "urgent": return Theme.danger
            case "high": return Theme.accentAmber
            case "medium": return Theme.accentBlue
            default: return Color.chrome(0.45)
            }
        }()
        Text(p.uppercased())
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    @ViewBuilder
    private var avatar: some View {
        if let a = task.assignee {
            Text(a.initials)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accentBlue.opacity(0.85)))
        }
    }
}

// MARK: - Create sheet

private struct CreateTaskSheet: View {
    var onCreate: (String, String?, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var desc: String = ""
    @State private var priority: String = "medium"
    @State private var dueDate: Date = Date()
    @State private var hasDueDate: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Approve Q4 vendor list", text: $title)
                }
                Section("Description") {
                    TextField("Optional", text: $desc, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("Priority") {
                    Picker("Priority", selection: $priority) {
                        Text("Urgent").tag("urgent")
                        Text("High").tag("high")
                        Text("Medium").tag("medium")
                        Text("Low").tag("low")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Due Date") {
                    Toggle("Set due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanedTitle.isEmpty else { return }
                        let f = DateFormatter()
                        f.calendar = Calendar(identifier: .iso8601)
                        f.locale = Locale(identifier: "en_US_POSIX")
                        f.dateFormat = "yyyy-MM-dd"
                        let due = hasDueDate ? f.string(from: dueDate) : nil
                        onCreate(cleanedTitle, desc.isEmpty ? nil : desc, priority, due)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Detail sheet

private struct BoardTaskDetailSheet: View {
    let task: BoardTask
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [BoardTaskComment] = []
    @State private var loading = true
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title ?? "Untitled task")
                            .font(.system(size: 20, weight: .bold))
                            .tracking(-0.4)
                        if let d = task.description, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.chrome(0.65))
                        }
                    }

                    HStack(spacing: 8) {
                        chip(task.status?.capitalized ?? "—", color: Theme.accentBlue)
                        chip((task.priority ?? "medium").capitalized, color: Theme.accentAmber)
                        if let due = task.dueDate {
                            chip("Due \(Fmt.short(due))", color: task.isOverdue ? Theme.danger : Color.chrome(0.55))
                        }
                    }

                    Divider().padding(.vertical, 4)

                    Text("COMMENTS")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.chrome(0.50))

                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if comments.isEmpty {
                        Text("No comments yet.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.50))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(comments) { c in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.author?.full_name ?? c.author?.email ?? "Board member")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(c.body ?? "")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.chrome(0.70))
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.chrome(0.05))
                                )
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Add a comment…", text: $draft)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.chrome(0.05)))
                        Button {
                            postComment()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(Theme.accentBlue)
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                comments = (try? await MontyResidentAppService.fetchBoardTaskComments(taskId: task.id)) ?? []
                loading = false
            }
        }
    }

    private func postComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            if let row = try? await MontyResidentAppService.postBoardTaskComment(taskId: task.id, body: text) {
                comments.append(row)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
