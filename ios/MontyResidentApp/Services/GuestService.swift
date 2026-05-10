import Foundation

@MainActor
enum GuestService {
    static var api: SupabaseAPI { SupabaseAPI.shared }

    private static let columns =
        "id, property_id, resident_id, unit_number, guest_name, guest_phone, guest_email, " +
        "relationship, access_start, access_end, is_recurring, recurring_days, status, notes, " +
        "created_at, updated_at, revoked_at, revoked_by"

    static func fetchGuests(propertyId: String, unitNumber: String) async throws -> [GuestAccess] {
        try await api.from("guest_access")
            .select(columns)
            .eq("property_id", propertyId)
            .eq("unit_number", unitNumber)
            .order("access_start", ascending: false)
            .limit(200)
            .execute(as: [GuestAccess].self)
    }

    @discardableResult
    static func createGuest(_ input: GuestInput, propertyId: String, unitNumber: String) async throws -> GuestAccess {
        guard let uid = api.session?.user_id else { throw SupabaseError.auth("Not signed in") }
        let payload = CreatePayload(
            property_id: propertyId,
            resident_id: uid,
            unit_number: unitNumber,
            guest_name: input.guestName,
            guest_phone: input.guestPhone.nilIfEmpty,
            guest_email: input.guestEmail.nilIfEmpty,
            relationship: input.relationship.nilIfEmpty,
            access_start: Self.iso(input.accessStart),
            access_end: Self.iso(input.accessEnd),
            is_recurring: input.isRecurring,
            recurring_days: input.isRecurring ? input.recurringDays.sorted() : nil,
            status: "active",
            notes: input.notes.nilIfEmpty
        )
        return try await api.insert(into: "guest_access", body: payload, returning: GuestAccess.self)
    }

    @discardableResult
    static func updateGuest(id: String, _ input: GuestInput) async throws -> GuestAccess {
        let payload = UpdatePayload(
            guest_name: input.guestName,
            guest_phone: input.guestPhone.nilIfEmpty,
            guest_email: input.guestEmail.nilIfEmpty,
            relationship: input.relationship.nilIfEmpty,
            access_start: Self.iso(input.accessStart),
            access_end: Self.iso(input.accessEnd),
            is_recurring: input.isRecurring,
            recurring_days: input.isRecurring ? input.recurringDays.sorted() : [],
            notes: input.notes.nilIfEmpty
        )
        return try await api.update(table: "guest_access", id: id, body: payload, returning: GuestAccess.self)
    }

    @discardableResult
    static func revokeGuest(id: String) async throws -> GuestAccess {
        guard let uid = api.session?.user_id else { throw SupabaseError.auth("Not signed in") }
        let payload = RevokePayload(
            status: "revoked",
            revoked_at: Self.iso(Date()),
            revoked_by: uid
        )
        return try await api.update(table: "guest_access", id: id, body: payload, returning: GuestAccess.self)
    }

    // MARK: - Encodable payloads

    private struct CreatePayload: Encodable {
        let property_id: String
        let resident_id: String
        let unit_number: String
        let guest_name: String
        let guest_phone: String?
        let guest_email: String?
        let relationship: String?
        let access_start: String
        let access_end: String
        let is_recurring: Bool
        let recurring_days: [Int]?
        let status: String
        let notes: String?
    }

    private struct UpdatePayload: Encodable {
        let guest_name: String
        let guest_phone: String?
        let guest_email: String?
        let relationship: String?
        let access_start: String
        let access_end: String
        let is_recurring: Bool
        let recurring_days: [Int]
        let notes: String?
    }

    private struct RevokePayload: Encodable {
        let status: String
        let revoked_at: String
        let revoked_by: String
    }

    private static func iso(_ date: Date) -> String {
        Fmt.iso.string(from: date)
    }
}

/// Mutable form input shared by Create / Edit / Add-Again.
struct GuestInput {
    var guestName: String = ""
    var guestPhone: String = ""
    var guestEmail: String = ""
    var relationship: String = ""
    var accessStart: Date = Date()
    var accessEnd: Date = Date().addingTimeInterval(60 * 60 * 24)
    var isRecurring: Bool = false
    var recurringDays: Set<Int> = []
    var notes: String = ""

    static func from(_ g: GuestAccess) -> GuestInput {
        var input = GuestInput()
        input.guestName = g.guest_name ?? ""
        input.guestPhone = g.guest_phone ?? ""
        input.guestEmail = g.guest_email ?? ""
        input.relationship = g.relationship ?? ""
        if let s = g.startDate { input.accessStart = s }
        if let e = g.endDate { input.accessEnd = e }
        input.isRecurring = g.is_recurring ?? false
        input.recurringDays = Set(g.recurring_days ?? [])
        input.notes = g.notes ?? ""
        return input
    }

    var validationError: String? {
        if guestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Please enter a name for your guest."
        }
        if accessEnd <= accessStart {
            return "End time must be after start time."
        }
        if isRecurring && recurringDays.isEmpty {
            return "Pick at least one day for recurring access."
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
