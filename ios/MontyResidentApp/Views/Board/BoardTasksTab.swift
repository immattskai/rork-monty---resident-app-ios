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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                tasks[i].status = status
            }
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
        withAnimation(.easeOut(duration: 0.22)) {
            tasks.removeAll { $0.id == id }
        }
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
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                tasks.insert(row, at: 0)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TaskColumn: Identifiable, Hashable {
    let id: String
    let title: String
    let accent: Color
    let emptyLine: String
}

private let kTaskColumns: [TaskColumn] = [
    .init(id: "backlog",     title: "Backlog",     accent: Color.chrome(0.45),       emptyLine: "Nothing in Backlog"),
    .init(id: "todo",        title: "To Do",       accent: Theme.accentBlue,         emptyLine: "Nothing to do — yet"),
    .init(id: "in_progress", title: "In Progress", accent: Theme.accentAmber,        emptyLine: "Nothing in progress"),
    .init(id: "done",        title: "Done",        accent: Theme.success,            emptyLine: "Nothing completed yet")
]

struct BoardTasksTab: View {
    let propertyId: String?
    @State private var vm = BoardTasksViewModel()
    @State private var showCreate = false
    @State private var selectedTask: BoardTask?
    @State private var currentColumnId: String? = "backlog"

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
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if let err = vm.error, vm.tasks.isEmpty {
            VStack(spacing: 8) {
                Text("Couldn't load tasks").font(.system(size: 15, weight: .semibold))
                Text(err).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.chrome(0.55))
            }
            .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                kanban
                pageIndicator
            }
        }
    }

    // MARK: - Kanban (paging)

    private var kanban: some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(kTaskColumns) { col in
                        ColumnPage(
                            column: col,
                            tasks: vm.tasks.filter { ($0.status ?? "").lowercased() == col.id },
                            onTap: { task in
                                Haptics.tap()
                                selectedTask = task
                            },
                            onMove: { task, newStatus in
                                Task { await vm.updateStatus(task.id, status: newStatus) }
                            },
                            onPriority: { task, p in
                                Task { await vm.updatePriority(task.id, priority: p) }
                            },
                            onDelete: { task in
                                Task { await vm.delete(task.id) }
                            }
                        )
                        .frame(width: columnWidth)
                        .id(col.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentColumnId)
            .onChange(of: currentColumnId) { _, _ in
                Haptics.tap()
            }
        }
        .frame(minHeight: 380)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(kTaskColumns) { col in
                let active = currentColumnId == col.id
                Capsule()
                    .fill(active ? col.accent : Color.chrome(0.14))
                    .frame(width: active ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentColumnId)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                .shadow(color: Theme.accentBlue.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Column page

private struct ColumnPage: View {
    let column: TaskColumn
    let tasks: [BoardTask]
    let onTap: (BoardTask) -> Void
    let onMove: (BoardTask, String) -> Void
    let onPriority: (BoardTask, String) -> Void
    let onDelete: (BoardTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if tasks.isEmpty {
                Text(column.emptyLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.42))
                    .padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, t in
                        TaskRow(task: t, accent: column.accent)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onTap(t)
                            }
                            .contextMenu {
                                ForEach(kTaskColumns) { c in
                                    if c.id != column.id {
                                        Button("Move to \(c.title)") {
                                            onMove(t, c.id)
                                        }
                                    }
                                }
                                Divider()
                                Menu("Priority") {
                                    ForEach(["urgent", "high", "medium", "low"], id: \.self) { p in
                                        Button(p.capitalized) { onPriority(t, p) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { onDelete(t) }
                            }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                        if idx < tasks.count - 1 {
                            Divider()
                                .background(Color.chrome(0.06))
                                .padding(.leading, 28)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6)
                )
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: Theme.cardDropShadow, radius: 8, y: 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(column.title.uppercased())
                    .font(.system(size: 11.5, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(tasks.count)")
                    .font(.system(size: 10.5, weight: .heavy, design: .monospaced))
                    .foregroundStyle(column.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(column.accent.opacity(0.14)))
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [column.accent.opacity(0.85), column.accent.opacity(0.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1.5)
        }
    }
}

// MARK: - Compact task row

private struct TaskRow: View {
    let task: BoardTask
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(priorityColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle().stroke(priorityColor.opacity(0.35), lineWidth: 3)
                        .scaleEffect(1.0)
                )
                .frame(width: 14, height: 14)
            Text(task.title?.isEmpty == false ? task.title! : "Untitled task")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let date = task.dueDate {
                Text(Fmt.short(date))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(task.isOverdue ? Theme.danger : Color.chrome(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(task.isOverdue ? Theme.danger.opacity(0.12) : Color.chrome(0.05))
                    )
            }
            if let a = task.assignee {
                Text(a.initials)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(accent.opacity(0.9)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priorityColor: Color {
        switch (task.priority ?? "medium").lowercased() {
        case "urgent": return Theme.danger
        case "high":   return Theme.accentAmber
        case "medium": return Theme.accentBlue
        default:       return Color.chrome(0.45)
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
