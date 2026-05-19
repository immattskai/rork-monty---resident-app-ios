import Foundation

// MARK: - Tasks

nonisolated struct BoardTask: Codable, Identifiable, Hashable {
    let id: String
    var organization_id: String?
    var property_id: String?
    var title: String?
    var description: String?
    var status: String?         // backlog | todo | in_progress | done
    var priority: String?       // urgent | high | medium | low
    var due_date: String?
    var assigned_to: String?
    var created_by: String?
    var sort_order: Int?
    var source: String?
    var created_at: String?
    var updated_at: String?
    var assignee: BoardTaskAssignee?

    var dueDate: Date? { Fmt.parseDay(due_date) ?? Fmt.parseDate(due_date) }
    var isOverdue: Bool {
        guard let d = dueDate, (status ?? "").lowercased() != "done" else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }
}

nonisolated struct BoardTaskAssignee: Codable, Hashable {
    var full_name: String?
    var email: String?

    var initials: String {
        let src = (full_name?.isEmpty == false ? full_name! : (email ?? "")).trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty else { return "?" }
        let parts = src.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first }.map { String($0).uppercased() }
        return chars.joined()
    }
}

nonisolated struct BoardTaskComment: Codable, Identifiable, Hashable {
    let id: String
    var task_id: String?
    var author_id: String?
    var body: String?
    var created_at: String?
    var author: BoardTaskAssignee?
}

// MARK: - Meeting detail

nonisolated struct BoardMeetingFull: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var title: String?
    var description: String?
    var scheduled_at: String?
    var location: String?
    var status: String?
    var created_at: String?

    var scheduledDate: Date? { Fmt.parseDate(scheduled_at) }
}

nonisolated struct BoardAgendaItem: Codable, Identifiable, Hashable {
    let id: String
    var meeting_id: String?
    var title: String?
    var description: String?
    var sort_order: Int?
    var duration_minutes: Int?
}

nonisolated struct BoardMeetingNote: Codable, Identifiable, Hashable {
    let id: String
    var meeting_id: String?
    var author_id: String?
    var content: String?
    var created_at: String?
    var author: BoardTaskAssignee?
}

nonisolated struct BoardVote: Codable, Identifiable, Hashable {
    let id: String
    var meeting_id: String?
    var title: String?
    var description: String?
    var status: String?   // passed | failed | pending
    var yes_count: Int?
    var no_count: Int?
    var abstain_count: Int?
    var created_at: String?
}

nonisolated struct BoardMeetingMinutes: Codable, Identifiable, Hashable {
    let id: String
    var meeting_id: String?
    var content: String?
    var approved: Bool?
    var created_at: String?
}

nonisolated struct BoardMeetingAttendee: Codable, Identifiable, Hashable {
    let id: String
    var meeting_id: String?
    var unit_person_id: String?
    var board_member_id: String?
    var rsvp_status: String?  // attending | not_attending | tentative
}

// MARK: - Snapshot

nonisolated struct BoardSnapshotUnit: Codable, Hashable {
    var is_occupied: Bool?
}

nonisolated struct BoardSnapshotTicket: Codable, Identifiable, Hashable {
    let id: String
    var status: String?
    var priority: String?
    var created_at: String?
    var resolved_at: String?

    var createdDate: Date? { Fmt.parseDate(created_at) }
    var resolvedDate: Date? { Fmt.parseDate(resolved_at) }
}

nonisolated struct BoardSnapshotTaskRow: Codable, Identifiable, Hashable {
    let id: String
    var status: String?
}

/// Aggregated KPIs + chart series for the Snapshot tab.
struct BoardSnapshotData: Hashable {
    var occupiedUnits: Int = 0
    var totalUnits: Int = 0
    var openTickets: Int = 0
    var prevOpenTickets: Int = 0
    var urgentTickets: Int = 0
    var highTickets: Int = 0
    var avgResolutionHours: Double = 0
    var prevAvgResolutionHours: Double = 0
    var openBoardTasks: Int = 0
    var taskByStatus: [String: Int] = [:] // backlog/todo/in_progress
    var weeklyVolume: [WeeklyTicketBucket] = []
    var resolutionWeekly: [WeeklyAvgResolutionBucket] = []
    var priorityBuckets: [PriorityBucket] = []
    var bucketUnit: Calendar.Component = .weekOfYear

    var occupancyPct: Double {
        guard totalUnits > 0 else { return 0 }
        return Double(occupiedUnits) / Double(totalUnits) * 100
    }

    var openTicketsDelta: Int { openTickets - prevOpenTickets }
    var resolutionDelta: Double { avgResolutionHours - prevAvgResolutionHours }
}

struct WeeklyTicketBucket: Hashable, Identifiable {
    let id = UUID()
    var weekStart: Date
    var count: Int
}

struct WeeklyAvgResolutionBucket: Hashable, Identifiable {
    let id = UUID()
    var weekStart: Date
    var avgHours: Double
}

struct PriorityBucket: Hashable, Identifiable {
    let id = UUID()
    var priority: String
    var count: Int
}

// MARK: - Financials (AR aging)

/// Row from `common_charges`. `amount` is integer dollars (numeric); when present,
/// `total_amount_cents` is authoritative cents. Open balance = full row amount
/// because paid rows flip `status` → 'paid' (no partial paid_cents tracked).
nonisolated struct FinancialCharge: Codable, Identifiable, Hashable {
    let id: String
    var unit_id: String?
    var amount: Double?
    var total_amount_cents: Int?
    var due_date: String?
    var status: String?

    /// Open balance in cents. Prefer `total_amount_cents`, fall back to `amount * 100`.
    var balanceCents: Int {
        if let c = total_amount_cents { return max(0, c) }
        return max(0, Int(((amount ?? 0) * 100).rounded()))
    }
}

nonisolated struct PropertyUnitLite: Codable, Identifiable, Hashable {
    let id: String
    var unit_number: String?
}

/// Per-unit aging row used by the Financials tab.
struct ArAgingUnit: Hashable, Identifiable {
    var id: String { unitId }
    let unitId: String
    var unitLabel: String
    var current: Int
    var bucket1to30: Int
    var bucket31to60: Int
    var bucket61to90: Int
    var bucket90plus: Int
    var oldestDueDate: Date?

    var total: Int { current + bucket1to30 + bucket31to60 + bucket61to90 + bucket90plus }
    var daysOverdue: Int {
        guard let d = oldestDueDate else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return max(0, days)
    }
    var isLienEligible: Bool { bucket90plus >= ArAging.lienThresholdCents }
    var isSevere: Bool { (bucket61to90 + bucket90plus) > 0 }
}

enum ArAging {
    static let lienThresholdCents: Int = 250_000 // $2,500
}

struct ArAgingTotals: Hashable {
    var current: Int = 0
    var bucket1to30: Int = 0
    var bucket31to60: Int = 0
    var bucket61to90: Int = 0
    var bucket90plus: Int = 0
    var unitsInArrears: Int = 0
    var severeUnits: Int = 0
    var lienEligibleCount: Int = 0

    var grand: Int { current + bucket1to30 + bucket31to60 + bucket61to90 + bucket90plus }
}
