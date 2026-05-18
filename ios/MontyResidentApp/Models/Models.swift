import Foundation

// MARK: - User / Profile / Roles

nonisolated struct Profile: Codable, Identifiable, Hashable {
    let id: String
    var full_name: String?
    var email: String?
    var phone: String?
    var unit_number: String?
    var property_id: String?
}

nonisolated struct UserRoleRow: Codable, Hashable {
    let user_id: String
    let role: String
}

// MARK: - Property / Unit

nonisolated struct Property: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    var address: String?
    var logo_path: String?
    var photos: [String]?

    /// First building photo path (storage path inside the `property-assets` bucket).
    var heroPhotoPath: String? {
        photos?.first(where: { !$0.isEmpty })
    }

    /// Public URL for a storage path inside the `property-assets` bucket.
    static func publicAssetURL(_ path: String?) -> URL? {
        guard let p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        // If a full URL was stored, just use it.
        if p.hasPrefix("http://") || p.hasPrefix("https://") { return URL(string: p) }
        let cleaned = p.hasPrefix("/") ? String(p.dropFirst()) : p
        let encoded = cleaned
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(SupabaseConfig.url)/storage/v1/object/public/property-assets/\(encoded)")
    }

    var heroPhotoURL: URL? { Property.publicAssetURL(heroPhotoPath) }
    var logoURL: URL? { Property.publicAssetURL(logo_path) }
}

nonisolated struct Unit: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String
    var unit_number: String?
    var floor: String?
    var bedrooms: Int?
    var bathrooms: Double?
    var property: Property?

    enum CodingKeys: String, CodingKey {
        case id, property_id, unit_number, floor, bedrooms, bathrooms, property
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        property_id = try c.decode(String.self, forKey: .property_id)
        unit_number = try c.decodeIfPresent(String.self, forKey: .unit_number)
        if let s = try? c.decodeIfPresent(String.self, forKey: .floor) {
            floor = s
        } else if let i = try c.decodeIfPresent(Int.self, forKey: .floor) {
            floor = String(i)
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .floor) ?? nil {
            floor = String(d)
        } else {
            floor = nil
        }
        bedrooms = try c.decodeIfPresent(Int.self, forKey: .bedrooms)
        bathrooms = try c.decodeIfPresent(Double.self, forKey: .bathrooms)
        property = try c.decodeIfPresent(Property.self, forKey: .property)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(property_id, forKey: .property_id)
        try c.encodeIfPresent(unit_number, forKey: .unit_number)
        try c.encodeIfPresent(floor, forKey: .floor)
        try c.encodeIfPresent(bedrooms, forKey: .bedrooms)
        try c.encodeIfPresent(bathrooms, forKey: .bathrooms)
        try c.encodeIfPresent(property, forKey: .property)
    }

    /// Display label like "Unit 4B" — falls back to property name or address.
    var displayLabel: String {
        if let u = unit_number, !u.isEmpty { return "Unit \(u)" }
        if let n = property?.name, !n.isEmpty { return n }
        return "Unit"
    }

    var displayAddress: String? { property?.address }
}

nonisolated struct UnitPerson: Codable, Hashable {
    let unit_id: String
    var property_id: String?
    let profile_id: String
    var role: String?
    var is_primary: Bool?
    var outstanding_balance: Double?
    var past_due_balance: Double?
    var unit: Unit?
}

// MARK: - Tickets

nonisolated struct Ticket: Codable, Identifiable, Hashable {
    let id: String
    var unit_id: String?
    var resident_id: String?
    var property_id: String?
    var organization_id: String?
    var title: String?
    var description: String?
    var category: String?
    var status: String?
    var priority: String?
    var ticket_type: String?
    var is_ai_handled: Bool?
    var ai_urgency_score: Double?
    var attachment_urls: [String]?
    var ai_recommended_vendor_ids: [String]?
    var vendor_outreach_status: String?
    var vendor_outreach_vendor_id: String?
    var vendor_outreach_sent_at: String?
    var created_at: String?
    var updated_at: String?
}

nonisolated struct TicketMessage: Codable, Identifiable, Hashable {
    let id: String
    var ticket_id: String
    var sender_id: String?
    var body: String?
    /// Legacy column name on some installs.
    var content: String?
    var is_ai_response: Bool?
    var is_internal_note: Bool?
    var created_at: String?
    var attachments: [String]?

    // In-memory only — never persisted/decoded.
    var isPending: Bool = false
    var recommendedVendors: [RecommendedVendor]? = nil
    var vendorActionTaken: Bool = false

    var displayBody: String { body ?? content ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, ticket_id, sender_id, body, content, is_ai_response, is_internal_note, created_at, attachments
    }

    init(
        id: String,
        ticket_id: String,
        sender_id: String? = nil,
        body: String? = nil,
        content: String? = nil,
        is_ai_response: Bool? = nil,
        is_internal_note: Bool? = nil,
        created_at: String? = nil,
        attachments: [String]? = nil,
        isPending: Bool = false,
        recommendedVendors: [RecommendedVendor]? = nil,
        vendorActionTaken: Bool = false
    ) {
        self.id = id
        self.ticket_id = ticket_id
        self.sender_id = sender_id
        self.body = body
        self.content = content
        self.is_ai_response = is_ai_response
        self.is_internal_note = is_internal_note
        self.created_at = created_at
        self.attachments = attachments
        self.isPending = isPending
        self.recommendedVendors = recommendedVendors
        self.vendorActionTaken = vendorActionTaken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.ticket_id = try c.decode(String.self, forKey: .ticket_id)
        self.sender_id = try c.decodeIfPresent(String.self, forKey: .sender_id)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        self.is_ai_response = try c.decodeIfPresent(Bool.self, forKey: .is_ai_response)
        self.is_internal_note = try c.decodeIfPresent(Bool.self, forKey: .is_internal_note)
        self.created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        self.attachments = try c.decodeIfPresent([String].self, forKey: .attachments)
        self.isPending = false
        self.recommendedVendors = nil
        self.vendorActionTaken = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(ticket_id, forKey: .ticket_id)
        try c.encodeIfPresent(sender_id, forKey: .sender_id)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(is_ai_response, forKey: .is_ai_response)
        try c.encodeIfPresent(is_internal_note, forKey: .is_internal_note)
        try c.encodeIfPresent(created_at, forKey: .created_at)
        try c.encodeIfPresent(attachments, forKey: .attachments)
    }
}

// MARK: - Vendors

nonisolated struct RecommendedVendor: Codable, Identifiable, Hashable {
    let vendorId: String
    var name: String
    var category: String?
    var contactName: String?
    var phone: String?
    var email: String?

    var id: String { vendorId }

    enum CodingKeys: String, CodingKey {
        case vendorId, vendor_id, id
        case name, vendorName, vendor_name
        case category
        case contactName, contact_name
        case phone
        case email
        case contacts
    }

    nonisolated struct VendorContact: Codable, Hashable {
        var contact_name: String?
        var contactName: String?
        var email: String?
        var phone: String?
        var is_primary: Bool?
        var isPrimary: Bool?

        var displayName: String? { contactName ?? contact_name }
        var primary: Bool { (isPrimary ?? is_primary) ?? false }
    }

    init(
        vendorId: String,
        name: String,
        category: String? = nil,
        contactName: String? = nil,
        phone: String? = nil,
        email: String? = nil
    ) {
        self.vendorId = vendorId
        self.name = name
        self.category = category
        self.contactName = contactName
        self.phone = phone
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Accept any of `vendorId`, `vendor_id`, or `id`.
        let vid = try c.decodeIfPresent(String.self, forKey: .vendorId)
            ?? c.decodeIfPresent(String.self, forKey: .vendor_id)
            ?? c.decodeIfPresent(String.self, forKey: .id)
        guard let vid else {
            throw DecodingError.dataCorruptedError(
                forKey: .vendorId, in: c,
                debugDescription: "Vendor missing vendorId/vendor_id/id"
            )
        }
        self.vendorId = vid
        let resolvedName = (try? c.decodeIfPresent(String.self, forKey: .vendorName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .vendor_name))
            ?? (try? c.decodeIfPresent(String.self, forKey: .name))
        self.name = (resolvedName?.isEmpty == false ? resolvedName! : "Vendor")
        self.category = try? c.decodeIfPresent(String.self, forKey: .category)

        // Top-level contact fields take priority; otherwise pull from `contacts[]`
        // preferring the primary contact, then falling back to the first.
        var topContactName = (try? c.decodeIfPresent(String.self, forKey: .contactName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .contact_name))
        var topPhone = try? c.decodeIfPresent(String.self, forKey: .phone)
        var topEmail = try? c.decodeIfPresent(String.self, forKey: .email)

        if topContactName == nil && topPhone == nil && topEmail == nil,
           let contacts = try? c.decodeIfPresent([VendorContact].self, forKey: .contacts),
           let pick = contacts.first(where: { $0.primary }) ?? contacts.first {
            topContactName = pick.displayName
            topPhone = pick.phone
            topEmail = pick.email
        }
        self.contactName = topContactName
        self.phone = topPhone
        self.email = topEmail
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vendorId, forKey: .vendorId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(contactName, forKey: .contactName)
        try c.encodeIfPresent(phone, forKey: .phone)
        try c.encodeIfPresent(email, forKey: .email)
    }
}

// MARK: - Resident-facing Vendor Directory

nonisolated struct ResidentVendorContact: Codable, Hashable {
    var contact_name: String?
    var email: String?
    var phone: String?
    var is_primary: Bool?
}

nonisolated struct ResidentVendor: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    var category: String?
    var description: String?
    var vendor_contacts: [ResidentVendorContact]?

    /// Picks the contact flagged `is_primary`, else the first contact.
    var primaryContact: ResidentVendorContact? {
        guard let cs = vendor_contacts, !cs.isEmpty else { return nil }
        return cs.first(where: { $0.is_primary == true }) ?? cs.first
    }
}

nonisolated struct VendorRecommendation: Codable, Identifiable, Hashable {
    let vendor_id: String
    var name: String
    var category: String?
    var description: String?
    var reasoning: String
    var contacts: [ResidentVendorContact]?

    var id: String { vendor_id }

    var primaryContact: ResidentVendorContact? {
        guard let cs = contacts, !cs.isEmpty else { return nil }
        return cs.first(where: { $0.is_primary == true }) ?? cs.first
    }
}

nonisolated struct VendorDirectoryEntry: Codable, Identifiable, Hashable {
    let id: String
    var name: String?
    var category: String?
    var contact_name: String?
    var phone: String?
    var email: String?
    var organization_id: String?
    var is_visible_to_residents: Bool?

    var asRecommended: RecommendedVendor {
        RecommendedVendor(
            vendorId: id,
            name: name ?? "Vendor",
            category: category,
            contactName: contact_name,
            phone: phone,
            email: email
        )
    }
}

// MARK: - Packages

nonisolated struct Package: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var resident_id: String?
    var recipient_name: String?
    var unit_number: String?
    var carrier: String?
    var tracking_number: String?
    var photo_url: String?
    var status: String?
    var notes: String?
    var received_at: String?
    var picked_up_at: String?
    // Extended (web parity)
    var package_size: String?
    var description: String?
    var direction: String?
    var notified_at: String?
    var notification_count: Int?
    var picked_up_by: String?
    var pickup_notes: String?
    var recipient_address: String?
    var sent_at: String?
    var created_at: String?

    var receivedDate: Date? { Fmt.parseDate(received_at) }
    var pickedUpDate: Date? { Fmt.parseDate(picked_up_at) }
    var isOutgoing: Bool { (direction ?? "").lowercased() == "outgoing" }
    var isPickedUp: Bool { (status ?? "").lowercased() == "picked_up" }
    var isPending: Bool {
        let s = (status ?? "").lowercased()
        return !isOutgoing && (s == "received" || s == "notified")
    }
}

// MARK: - Amenities

nonisolated struct Amenity: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String
    var name: String?
    var description: String?
    var image_url: String?
    var availability_hours_text: String?
    var is_24_7: Bool?
    var requires_booking: Bool?
    var booking_config: AmenityBookingConfig?
    var created_at: String?

    enum CodingKeys: String, CodingKey {
        case id, property_id, name, description, image_url
        case availability_hours, is_24_7, requires_booking, booking_config, created_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.property_id = try c.decode(String.self, forKey: .property_id)
        self.name = try? c.decodeIfPresent(String.self, forKey: .name)
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.image_url = try? c.decodeIfPresent(String.self, forKey: .image_url)
        // availability_hours can be a string or a json object — accept either.
        if let s = try? c.decodeIfPresent(String.self, forKey: .availability_hours) {
            self.availability_hours_text = s
        } else if let dict = try? c.decodeIfPresent([String: String].self, forKey: .availability_hours), !dict.isEmpty {
            self.availability_hours_text = dict
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key.capitalized): \($0.value)" }
                .joined(separator: " · ")
        } else {
            self.availability_hours_text = nil
        }
        self.is_24_7 = try? c.decodeIfPresent(Bool.self, forKey: .is_24_7)
        self.requires_booking = try? c.decodeIfPresent(Bool.self, forKey: .requires_booking)
        self.booking_config = try? c.decodeIfPresent(AmenityBookingConfig.self, forKey: .booking_config)
        self.created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(property_id, forKey: .property_id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(image_url, forKey: .image_url)
        try c.encodeIfPresent(availability_hours_text, forKey: .availability_hours)
        try c.encodeIfPresent(is_24_7, forKey: .is_24_7)
        try c.encodeIfPresent(requires_booking, forKey: .requires_booking)
        try c.encodeIfPresent(booking_config, forKey: .booking_config)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }

    /// Friendly hours/availability string for badges.
    var hoursDisplay: String? {
        if is_24_7 == true { return "Open 24/7" }
        if let h = availability_hours_text, !h.isEmpty { return h }
        return nil
    }
}

nonisolated struct AmenityBookingConfig: Codable, Hashable {
    var slot_duration_minutes: Int?
    var max_slots_per_day: Int?
    var min_advance_days: Int?
    var bookable_hours: Hours?
    var available_days: [Int]?
    var blackout_dates: [String]?
    var booking_fee: Fee?
    var security_deposit: Fee?

    nonisolated struct Hours: Codable, Hashable {
        var start: String?
        var end: String?
    }

    nonisolated struct Fee: Codable, Hashable {
        var amount: Double?
        var description: String?
        var refund_policy: String?
    }
}

nonisolated struct AmenityBooking: Codable, Identifiable, Hashable {
    let id: String
    var amenity_id: String
    var amenity: AmenityRef?
    var property_id: String?
    var user_id: String?
    var booking_date: String?
    var start_time: String?
    var end_time: String?
    var status: String?
    var notes: String?
    var created_at: String?
    var cancelled_at: String?
    var rejection_reason: String?
    var payment_verified: Bool?

    var amenityName: String? { amenity?.name }
    var amenityImageURL: String? { amenity?.image_url }
}

nonisolated struct AmenityRef: Codable, Hashable {
    var id: String?
    var name: String?
    var image_url: String?
}

// MARK: - Payments / Balance

/// Maps MontyResidentApp's `balance_cache` table.
nonisolated struct AccountBalance: Codable, Hashable {
    var unit_id: String
    var balance_cents: Int
    var past_due_cents: Int?
    var fetched_at: String?
    var expires_at: String?
}

/// Maps `payments` table. RLS scopes by `resident_id = auth.uid()`.
/// `total_amount` is decimal dollars; `payment_method` is an enum cast to text on read.
/// Description is joined from `common_charges` via `charge_id`.
nonisolated struct PaymentRecord: Codable, Identifiable, Hashable {
    let id: String
    var charge_id: String?
    var resident_id: String?
    var amount: Double?
    var processing_fee: Double?
    var total_amount: Double?
    var payment_method: String?
    var status: String?
    var failure_reason: String?
    var paid_at: String?
    var created_at: String?
    var charge: ChargeRef?

    var description: String? { charge?.description }
    var amountCents: Int { Int(((total_amount ?? amount ?? 0) * 100).rounded()) }
}

nonisolated struct ChargeRef: Codable, Hashable {
    var description: String?
    var due_date: String?
}

/// `common_charges` row for the resident. RLS scopes by `resident_id = auth.uid()`.
nonisolated struct CommonCharge: Codable, Identifiable, Hashable {
    let id: String
    var resident_id: String?
    var unit_id: String?
    var amount: Double?
    var description: String?
    var due_date: String?
    var status: String?
    var validation_status: String?
    var validation_reason_message: String?
    var created_at: String?
}

// MARK: - Documents

nonisolated struct DocumentItem: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var name: String?
    var file_path: String?
    var file_type: String?
    var file_size: Int?
    var category: String?
    var expiry_date: String?
    var created_at: String?
}

// MARK: - Guests

nonisolated struct GuestAccess: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var resident_id: String?
    var unit_number: String?
    var guest_name: String?
    var guest_phone: String?
    var guest_email: String?
    var relationship: String?
    var access_start: String?
    var access_end: String?
    var is_recurring: Bool?
    var recurring_days: [Int]?
    var status: String?
    var notes: String?
    var created_at: String?
    var updated_at: String?
    var revoked_at: String?
    var revoked_by: String?

    var startDate: Date? { Fmt.parseDate(access_start) }
    var endDate: Date? { Fmt.parseDate(access_end) }

    /// Active = explicit "active" status AND end date in the future.
    var isCurrentlyActive: Bool {
        guard (status ?? "active").lowercased() == "active" else { return false }
        if let end = endDate { return end > Date() }
        return true
    }
}

// MARK: - Contacts

nonisolated struct StaffContact: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var name: String?
    var title: String?
    var role: String?
    var phone: String?
    var email: String?
    var photo_url: String?

    var displayRole: String? { title ?? role }
    var avatarURL: String? { photo_url }
}
