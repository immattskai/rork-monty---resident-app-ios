import Foundation

@MainActor
extension MontyResidentAppService {
    // MARK: - Snapshot

    /// Loads the 30-day Snapshot dashboard data in parallel.
    static func fetchBoardSnapshot(propertyId: String) async throws -> BoardSnapshotData {
        guard !propertyId.isEmpty else { return BoardSnapshotData() }
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let prevStartDate = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let startISO = Fmt.iso.string(from: startDate)
        let prevISO = Fmt.iso.string(from: prevStartDate)

        async let unitsT: [BoardSnapshotUnit] = (try? await api.from("property_units")
            .select("is_occupied")
            .eq("property_id", propertyId)
            .limit(2000)
            .execute(as: [BoardSnapshotUnit].self)) ?? []

        async let ticketsT: [BoardSnapshotTicket] = (try? await api.from("tickets")
            .select("id,status,priority,created_at,resolved_at")
            .eq("property_id", propertyId)
            .gte("created_at", startISO)
            .limit(2000)
            .execute(as: [BoardSnapshotTicket].self)) ?? []

        async let prevTicketsT: [BoardSnapshotTicket] = (try? await api.from("tickets")
            .select("id,status,priority,created_at,resolved_at")
            .eq("property_id", propertyId)
            .gte("created_at", prevISO)
            .lt("created_at", startISO)
            .limit(2000)
            .execute(as: [BoardSnapshotTicket].self)) ?? []

        async let tasksT: [BoardSnapshotTaskRow] = (try? await api.from("board_tasks")
            .select("id,status")
            .eq("property_id", propertyId)
            .limit(2000)
            .execute(as: [BoardSnapshotTaskRow].self)) ?? []

        let units = await unitsT
        let tickets = await ticketsT
        let prevTickets = await prevTicketsT
        let tasks = await tasksT

        var data = BoardSnapshotData()
        data.totalUnits = units.count
        data.occupiedUnits = units.filter { $0.is_occupied == true }.count

        let openStatuses: Set<String> = ["open", "in_progress"]
        data.openTickets = tickets.filter { openStatuses.contains(($0.status ?? "").lowercased()) }.count
        data.prevOpenTickets = prevTickets.filter { openStatuses.contains(($0.status ?? "").lowercased()) }.count

        // Avg resolution time in hours for resolved tickets in window.
        func avg(_ rows: [BoardSnapshotTicket]) -> Double {
            let resolved = rows.compactMap { t -> Double? in
                guard let c = t.createdDate, let r = t.resolvedDate, r >= c else { return nil }
                return r.timeIntervalSince(c) / 3600.0
            }
            guard !resolved.isEmpty else { return 0 }
            return resolved.reduce(0, +) / Double(resolved.count)
        }
        data.avgResolutionHours = avg(tickets)
        data.prevAvgResolutionHours = avg(prevTickets)

        // Tasks: open = anything that isn't done.
        let openTasks = tasks.filter { ($0.status ?? "").lowercased() != "done" }
        data.openBoardTasks = openTasks.count
        var byStatus: [String: Int] = [:]
        for t in openTasks {
            let key = (t.status ?? "todo").lowercased()
            byStatus[key, default: 0] += 1
        }
        data.taskByStatus = byStatus

        // Weekly volume (last 5 weeks). Week starts Sunday.
        let cal = Calendar(identifier: .gregorian)
        let endOfNow = cal.startOfDay(for: now)
        var weekStarts: [Date] = []
        for i in stride(from: 4, through: 0, by: -1) {
            if let monday = cal.date(byAdding: .weekOfYear, value: -i, to: endOfNow),
               let weekStart = cal.dateInterval(of: .weekOfYear, for: monday)?.start {
                weekStarts.append(weekStart)
            }
        }
        var weekly: [WeeklyTicketBucket] = []
        for (i, start) in weekStarts.enumerated() {
            let end = i + 1 < weekStarts.count ? weekStarts[i + 1] : (cal.date(byAdding: .day, value: 7, to: start) ?? start)
            let count = tickets.filter {
                guard let d = $0.createdDate else { return false }
                return d >= start && d < end
            }.count
            weekly.append(WeeklyTicketBucket(weekStart: start, count: count))
        }
        data.weeklyVolume = weekly

        // Priority buckets.
        let priorities = ["urgent", "high", "medium", "low"]
        var pBuckets: [PriorityBucket] = []
        for p in priorities {
            let c = tickets.filter { ($0.priority ?? "").lowercased() == p }.count
            pBuckets.append(PriorityBucket(priority: p, count: c))
        }
        data.priorityBuckets = pBuckets

        return data
    }

    // MARK: - Meeting detail

    static func fetchBoardMeetingFull(id: String) async throws -> BoardMeetingFull? {
        try await api.from("board_meetings")
            .select("id, title, description, scheduled_at, location, status, property_id, created_at")
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: BoardMeetingFull.self)
    }

    static func fetchBoardAgenda(meetingId: String) async throws -> [BoardAgendaItem] {
        try await api.from("board_agenda_items")
            .select("id, meeting_id, title, description, sort_order, duration_minutes")
            .eq("meeting_id", meetingId)
            .order("sort_order", ascending: true)
            .limit(200)
            .execute(as: [BoardAgendaItem].self)
    }

    static func fetchBoardMeetingNotes(meetingId: String) async throws -> [BoardMeetingNote] {
        let withAuthor = "id, meeting_id, author_id, content, created_at, author:profiles!board_meeting_notes_author_id_fkey(full_name, email)"
        if let rows = try? await api.from("board_meeting_notes")
            .select(withAuthor)
            .eq("meeting_id", meetingId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [BoardMeetingNote].self) {
            return rows
        }
        return try await api.from("board_meeting_notes")
            .select("id, meeting_id, author_id, content, created_at")
            .eq("meeting_id", meetingId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [BoardMeetingNote].self)
    }

    static func fetchBoardVotes(meetingId: String) async throws -> [BoardVote] {
        try await api.from("board_votes")
            .select("id, meeting_id, title, description, status, yes_count, no_count, abstain_count, created_at")
            .eq("meeting_id", meetingId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [BoardVote].self)
    }

    static func fetchBoardMinutes(meetingId: String) async throws -> BoardMeetingMinutes? {
        try await api.from("board_meeting_minutes")
            .select("id, meeting_id, content, approved, created_at")
            .eq("meeting_id", meetingId)
            .order("created_at", ascending: false)
            .limit(1)
            .single()
            .executeOptional(as: BoardMeetingMinutes.self)
    }

    static func fetchMyMeetingAttendance(meetingId: String) async throws -> BoardMeetingAttendee? {
        guard let uid = currentUserId() else { return nil }
        // Find current user's unit_person rows, then look up attendance.
        struct UPRow: Decodable { let id: String? }
        let upRows = (try? await api.from("unit_people")
            .select("unit_id")
            .eq("profile_id", uid)
            .limit(50)
            .execute(as: [UnitPerson].self)) ?? []
        let myUnitIds = Array(Set(upRows.map { $0.unit_id })).filter { !$0.isEmpty }
        // Match on board_member rows tied to this profile too.
        struct BMRow: Decodable { let id: String }
        let bm = (try? await api.from("board_members")
            .select("id")
            .eq("profile_id", uid)
            .limit(10)
            .execute(as: [BMRow].self)) ?? []
        let bmIds = bm.map { $0.id }

        var attendees: [BoardMeetingAttendee] = []
        if !bmIds.isEmpty {
            attendees = (try? await api.from("board_meeting_attendees")
                .select("id, meeting_id, board_member_id, unit_person_id, rsvp_status")
                .eq("meeting_id", meetingId)
                .in("board_member_id", bmIds)
                .limit(10)
                .execute(as: [BoardMeetingAttendee].self)) ?? []
        }
        if attendees.isEmpty, !myUnitIds.isEmpty {
            attendees = (try? await api.from("board_meeting_attendees")
                .select("id, meeting_id, board_member_id, unit_person_id, rsvp_status")
                .eq("meeting_id", meetingId)
                .limit(50)
                .execute(as: [BoardMeetingAttendee].self)) ?? []
        }
        return attendees.first
    }

    /// Upserts the resident's RSVP for a meeting. Returns the resolved row.
    @discardableResult
    static func upsertRSVP(meetingId: String, status: String) async throws -> BoardMeetingAttendee {
        guard let uid = currentUserId() else { throw SupabaseError.auth("Not signed in") }
        // Resolve a board_member_id for this user (preferred FK on attendees).
        struct BMRow: Decodable { let id: String }
        let bm = try? await api.from("board_members")
            .select("id")
            .eq("profile_id", uid)
            .limit(1)
            .execute(as: [BMRow].self)
        let memberId = bm?.first?.id

        struct UpsertPayload: Encodable {
            let meeting_id: String
            let rsvp_status: String
            let board_member_id: String?
        }
        let payload = UpsertPayload(
            meeting_id: meetingId,
            rsvp_status: status,
            board_member_id: memberId
        )
        return try await api.upsert(
            into: "board_meeting_attendees",
            body: payload,
            onConflict: "meeting_id,board_member_id",
            returning: BoardMeetingAttendee.self
        )
    }

    // MARK: - Tasks

    static func fetchBoardTasks(propertyId: String) async throws -> [BoardTask] {
        guard !propertyId.isEmpty else { return [] }
        let withAssignee = "id, organization_id, property_id, title, description, status, priority, due_date, assigned_to, created_by, sort_order, source, created_at, updated_at, assignee:profiles!board_tasks_assigned_to_fkey(full_name, email)"
        if let rows = try? await api.from("board_tasks")
            .select(withAssignee)
            .eq("property_id", propertyId)
            .order("sort_order", ascending: true)
            .limit(500)
            .execute(as: [BoardTask].self) {
            return rows
        }
        return try await api.from("board_tasks")
            .select("id, organization_id, property_id, title, description, status, priority, due_date, assigned_to, created_by, sort_order, source, created_at, updated_at")
            .eq("property_id", propertyId)
            .order("sort_order", ascending: true)
            .limit(500)
            .execute(as: [BoardTask].self)
    }

    @discardableResult
    static func updateBoardTaskStatus(taskId: String, status: String) async throws -> BoardTask {
        struct Payload: Encodable { let status: String }
        return try await api.update(table: "board_tasks", id: taskId, body: Payload(status: status), returning: BoardTask.self)
    }

    @discardableResult
    static func updateBoardTaskPriority(taskId: String, priority: String) async throws -> BoardTask {
        struct Payload: Encodable { let priority: String }
        return try await api.update(table: "board_tasks", id: taskId, body: Payload(priority: priority), returning: BoardTask.self)
    }

    static func deleteBoardTask(taskId: String) async throws {
        try await api.delete(table: "board_tasks", id: taskId)
    }

    @discardableResult
    static func createBoardTask(
        propertyId: String,
        title: String,
        description: String?,
        priority: String,
        dueDate: String?
    ) async throws -> BoardTask {
        guard let uid = currentUserId() else { throw SupabaseError.auth("Not signed in") }
        // Resolve organization_id from property.
        struct OrgRow: Codable { let organization_id: String? }
        let org: OrgRow? = try? await api.from("properties")
            .select("organization_id")
            .eq("id", propertyId)
            .limit(1)
            .single()
            .executeOptional(as: OrgRow.self)
        struct Payload: Encodable {
            let property_id: String
            let organization_id: String?
            let title: String
            let description: String?
            let status: String
            let priority: String
            let due_date: String?
            let created_by: String
            let source: String
        }
        return try await api.insert(
            into: "board_tasks",
            body: Payload(
                property_id: propertyId,
                organization_id: org?.organization_id,
                title: title,
                description: (description?.isEmpty == false) ? description : nil,
                status: "todo",
                priority: priority,
                due_date: (dueDate?.isEmpty == false) ? dueDate : nil,
                created_by: uid,
                source: "manual"
            ),
            returning: BoardTask.self
        )
    }

    static func fetchBoardTaskComments(taskId: String) async throws -> [BoardTaskComment] {
        let withAuthor = "id, task_id, author_id, body, created_at, author:profiles!board_task_comments_author_id_fkey(full_name, email)"
        if let rows = try? await api.from("board_task_comments")
            .select(withAuthor)
            .eq("task_id", taskId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [BoardTaskComment].self) {
            return rows
        }
        return try await api.from("board_task_comments")
            .select("id, task_id, author_id, body, created_at")
            .eq("task_id", taskId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [BoardTaskComment].self)
    }

    @discardableResult
    static func postBoardTaskComment(taskId: String, body text: String) async throws -> BoardTaskComment {
        guard let uid = currentUserId() else { throw SupabaseError.auth("Not signed in") }
        struct Payload: Encodable {
            let task_id: String
            let author_id: String
            let body: String
        }
        return try await api.insert(
            into: "board_task_comments",
            body: Payload(task_id: taskId, author_id: uid, body: text),
            returning: BoardTaskComment.self
        )
    }

    // MARK: - Financials

    /// Aggregated AR aging per unit. PII-free (no resident names).
    static func fetchBoardArAging(propertyId: String) async throws -> (totals: ArAgingTotals, units: [ArAgingUnit]) {
        guard !propertyId.isEmpty else { return (ArAgingTotals(), []) }
        async let chargesT: [FinancialCharge] = (try? await api.from("financial_charges")
            .select("id, unit_id, amount_cents, paid_cents, due_date, status")
            .eq("property_id", propertyId)
            .in("status", ["open", "partial"])
            .limit(5000)
            .execute(as: [FinancialCharge].self)) ?? []

        async let unitsT: [PropertyUnitLite] = (try? await api.from("property_units")
            .select("id, unit_number")
            .eq("property_id", propertyId)
            .limit(2000)
            .execute(as: [PropertyUnitLite].self)) ?? []

        let charges = await chargesT
        let units = await unitsT
        let unitLabelById = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0.unit_number ?? "Unit") })

        // Group charges by unit.
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        var byUnit: [String: ArAgingUnit] = [:]
        for c in charges {
            let unitId = c.unit_id ?? "unassigned"
            let due = Fmt.parseDay(c.due_date) ?? Fmt.parseDate(c.due_date)
            let balance = max(0, (c.amount_cents ?? 0) - (c.paid_cents ?? 0))
            guard balance > 0 else { continue }
            let daysOver: Int = {
                guard let d = due else { return 0 }
                return cal.dateComponents([.day], from: cal.startOfDay(for: d), to: today).day ?? 0
            }()
            var row = byUnit[unitId] ?? ArAgingUnit(
                unitId: unitId,
                unitLabel: unitLabelById[unitId] ?? "Unassigned",
                current: 0, bucket1to30: 0, bucket31to60: 0, bucket61to90: 0, bucket90plus: 0,
                oldestDueDate: nil
            )
            switch daysOver {
            case ..<1: row.current += balance
            case 1...30: row.bucket1to30 += balance
            case 31...60: row.bucket31to60 += balance
            case 61...90: row.bucket61to90 += balance
            default: row.bucket90plus += balance
            }
            if let d = due {
                if let existing = row.oldestDueDate {
                    if d < existing { row.oldestDueDate = d }
                } else {
                    row.oldestDueDate = d
                }
            }
            byUnit[unitId] = row
        }

        let unitsList = Array(byUnit.values).filter { $0.total > 0 }
        var totals = ArAgingTotals()
        for u in unitsList {
            totals.current += u.current
            totals.bucket1to30 += u.bucket1to30
            totals.bucket31to60 += u.bucket31to60
            totals.bucket61to90 += u.bucket61to90
            totals.bucket90plus += u.bucket90plus
            if u.total > 0 { totals.unitsInArrears += 1 }
            if u.isSevere { totals.severeUnits += 1 }
            if u.isLienEligible { totals.lienEligibleCount += 1 }
        }

        // Sort: lien-eligible first, then 90+ desc, then total desc.
        let sorted = unitsList.sorted { a, b in
            if a.isLienEligible != b.isLienEligible { return a.isLienEligible && !b.isLienEligible }
            if a.bucket90plus != b.bucket90plus { return a.bucket90plus > b.bucket90plus }
            return a.total > b.total
        }
        return (totals, sorted)
    }
}
