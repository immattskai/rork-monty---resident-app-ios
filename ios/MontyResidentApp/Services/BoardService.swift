import Foundation

@MainActor
extension MontyResidentAppService {
    // MARK: - Snapshot

    /// Loads the Snapshot dashboard data in parallel for the given range.
    /// `rangeDays` controls the time window for tickets (default 30).
    static func fetchBoardSnapshot(propertyId: String, rangeDays: Int = 30) async throws -> BoardSnapshotData {
        guard !propertyId.isEmpty else { return BoardSnapshotData() }
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let startDate = cal.date(byAdding: .day, value: -rangeDays, to: now) ?? now
        let prevStartDate = cal.date(byAdding: .day, value: -(rangeDays * 2), to: now) ?? now
        let startISO = Fmt.iso.string(from: startDate)
        let prevISO = Fmt.iso.string(from: prevStartDate)

        // Status enums in our schema (lowercase): 'open', 'in_progress', 'resolved',
        // 'closed', 'cancelled'. "Open" set = open + in_progress (NOT 'pending').
        let openStatusList = ["open", "in_progress"]

        // 6 parallel queries. Capture errors so we can surface real failures.
        async let unitsT: Result<[BoardSnapshotUnit], Error> = resultOf {
            try await api.from("property_units")
                .select("is_occupied")
                .eq("property_id", propertyId)
                .limit(5000)
                .execute(as: [BoardSnapshotUnit].self)
        }

        // Q2 — currently open tickets (no created_at filter). Drives KPI + priority donut.
        async let openTicketsT: Result<[BoardSnapshotTicket], Error> = resultOf {
            try await api.from("tickets")
                .select("id,status,priority,created_at,resolved_at")
                .eq("property_id", propertyId)
                .in("status", openStatusList)
                .limit(5000)
                .execute(as: [BoardSnapshotTicket].self)
        }

        // Q3 — prev-window snapshot for the open-tickets delta chip:
        // tickets created in the previous window that are still open today.
        async let openPrevT: Result<[BoardSnapshotTicket], Error> = resultOf {
            try await api.from("tickets")
                .select("id,status,priority,created_at,resolved_at")
                .eq("property_id", propertyId)
                .in("status", openStatusList)
                .gte("created_at", prevISO)
                .lt("created_at", startISO)
                .limit(5000)
                .execute(as: [BoardSnapshotTicket].self)
        }

        // Q4 — resolved-in-window: gate by resolved_at, NOT created_at.
        // Drives Avg Resolution KPI + resolution chart.
        async let resolvedT: Result<[BoardSnapshotTicket], Error> = resultOf {
            try await api.from("tickets")
                .select("id,status,priority,created_at,resolved_at")
                .eq("property_id", propertyId)
                .not("resolved_at", "is", "null")
                .gte("resolved_at", startISO)
                .limit(5000)
                .execute(as: [BoardSnapshotTicket].self)
        }

        // Q4b — previous resolved window, for the resolution delta chip.
        async let resolvedPrevT: Result<[BoardSnapshotTicket], Error> = resultOf {
            try await api.from("tickets")
                .select("id,status,priority,created_at,resolved_at")
                .eq("property_id", propertyId)
                .not("resolved_at", "is", "null")
                .gte("resolved_at", prevISO)
                .lt("resolved_at", startISO)
                .limit(5000)
                .execute(as: [BoardSnapshotTicket].self)
        }

        // Q5 — tickets created in window (for the volume chart only).
        async let createdInWindowT: Result<[BoardSnapshotTicket], Error> = resultOf {
            try await api.from("tickets")
                .select("id,status,priority,created_at,resolved_at")
                .eq("property_id", propertyId)
                .gte("created_at", startISO)
                .limit(5000)
                .execute(as: [BoardSnapshotTicket].self)
        }

        async let tasksT: Result<[BoardSnapshotTaskRow], Error> = resultOf {
            try await api.from("board_tasks")
                .select("id,status")
                .eq("property_id", propertyId)
                .limit(5000)
                .execute(as: [BoardSnapshotTaskRow].self)
        }

        let units = try (await unitsT).get()
        let openTickets = try (await openTicketsT).get()
        let openPrev = try (await openPrevT).get()
        let resolved = try (await resolvedT).get()
        let resolvedPrev = try (await resolvedPrevT).get()
        let createdInWindow = try (await createdInWindowT).get()
        let tasks = try (await tasksT).get()

        var data = BoardSnapshotData()
        data.totalUnits = units.count
        data.occupiedUnits = units.filter { $0.is_occupied == true }.count

        // Open Work Orders — currently open, regardless of age.
        data.openTickets = openTickets.count
        data.prevOpenTickets = openPrev.count
        data.urgentTickets = openTickets.filter { ($0.priority ?? "").lowercased() == "urgent" }.count
        data.highTickets = openTickets.filter { ($0.priority ?? "").lowercased() == "high" }.count

        // Avg resolution — averaged across tickets resolved in window.
        func avg(_ rows: [BoardSnapshotTicket]) -> Double {
            let hours = rows.compactMap { t -> Double? in
                guard let c = t.createdDate, let r = t.resolvedDate, r >= c else { return nil }
                return r.timeIntervalSince(c) / 3600.0
            }
            guard !hours.isEmpty else { return 0 }
            return hours.reduce(0, +) / Double(hours.count)
        }
        data.avgResolutionHours = avg(resolved)
        data.prevAvgResolutionHours = avg(resolvedPrev)

        // Open board tasks (anything that isn't done).
        let openTasks = tasks.filter { ($0.status ?? "").lowercased() != "done" }
        data.openBoardTasks = openTasks.count
        var byStatus: [String: Int] = [:]
        for t in openTasks {
            let key = (t.status ?? "todo").lowercased()
            byStatus[key, default: 0] += 1
        }
        data.taskByStatus = byStatus

        // Bucket charts by day when window < 14d, otherwise by week.
        let bucketUnit: Calendar.Component = rangeDays < 14 ? .day : .weekOfYear
        data.bucketUnit = bucketUnit
        let endOfNow = cal.startOfDay(for: now)
        let bucketCount = rangeDays < 14 ? rangeDays : min(8, max(4, Int(ceil(Double(rangeDays) / 7.0))))
        var bucketStarts: [Date] = []
        for i in stride(from: bucketCount - 1, through: 0, by: -1) {
            let anchor = cal.date(byAdding: bucketUnit, value: -i, to: endOfNow) ?? endOfNow
            let start: Date = {
                if bucketUnit == .weekOfYear {
                    return cal.dateInterval(of: .weekOfYear, for: anchor)?.start ?? cal.startOfDay(for: anchor)
                }
                return cal.startOfDay(for: anchor)
            }()
            bucketStarts.append(start)
        }

        var volume: [WeeklyTicketBucket] = []
        var resolution: [WeeklyAvgResolutionBucket] = []
        for (i, start) in bucketStarts.enumerated() {
            let end: Date = {
                if i + 1 < bucketStarts.count { return bucketStarts[i + 1] }
                let step = bucketUnit == .weekOfYear ? 7 : 1
                return cal.date(byAdding: .day, value: step, to: start) ?? start
            }()
            let created = createdInWindow.filter {
                guard let d = $0.createdDate else { return false }
                return d >= start && d < end
            }.count
            volume.append(WeeklyTicketBucket(weekStart: start, count: created))

            // Bucket by resolved_at (not created_at) using the resolved-in-window slice.
            let resolvedHours: [Double] = resolved.compactMap { t in
                guard let c = t.createdDate, let r = t.resolvedDate,
                      r >= c, r >= start, r < end else { return nil }
                return r.timeIntervalSince(c) / 3600.0
            }
            let avgH = resolvedHours.isEmpty ? 0 : resolvedHours.reduce(0, +) / Double(resolvedHours.count)
            resolution.append(WeeklyAvgResolutionBucket(weekStart: start, avgHours: avgH))
        }
        data.weeklyVolume = volume
        data.resolutionWeekly = resolution

        // Priority breakdown — currently open tickets, no time filter.
        // Drop priorities with 0 count.
        let priorities = ["urgent", "high", "medium", "low"]
        var pBuckets: [PriorityBucket] = []
        for p in priorities {
            let c = openTickets.filter { ($0.priority ?? "").lowercased() == p }.count
            if c > 0 { pBuckets.append(PriorityBucket(priority: p, count: c)) }
        }
        data.priorityBuckets = pBuckets

        return data
    }

    private static func resultOf<T>(_ op: @MainActor () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await op()) }
        catch { return .failure(error) }
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
        // Open AR = `common_charges` rows whose status is 'pending' or 'overdue'.
        // ('paid' rows are closed; 'partial' is not used in this schema.)
        async let chargesT: [FinancialCharge] = (try? await api.from("common_charges")
            .select("id, unit_id, amount, total_amount_cents, due_date, status")
            .eq("property_id", propertyId)
            .in("status", ["pending", "overdue"])
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
            let balance = c.balanceCents
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
