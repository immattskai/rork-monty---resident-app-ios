import Foundation

@MainActor
enum MontyResidentAppService {
    static var api: SupabaseAPI { SupabaseAPI.shared }

    // MARK: - Profile / Roles

    static func currentUserId() -> String? { api.session?.user_id }

    static func fetchProfile() async throws -> Profile? {
        guard let uid = currentUserId() else { return nil }
        return try await api.from("profiles")
            .select("id, full_name, email, phone, unit_number, property_id")
            .eq("id", uid)
            .limit(1)
            .single()
            .executeOptional(as: Profile.self)
    }

    static func fetchAllRoles() async throws -> [UserRoleRow] {
        guard let uid = currentUserId() else { return [] }
        return try await api.from("user_roles")
            .select("user_id, role")
            .eq("user_id", uid)
            .limit(50)
            .execute(as: [UserRoleRow].self)
    }

    /// True only if every role for this user is "resident".
    /// No role rows + has unit membership → treated as resident (matches web app).
    static func isResidentOnly(_ roles: [UserRoleRow]) -> Bool {
        guard !roles.isEmpty else { return true }
        return roles.allSatisfy { $0.role.lowercased() == "resident" }
    }

    // MARK: - Units

    static func fetchUnits() async throws -> [Unit] {
        guard let uid = currentUserId() else { return [] }
        // First try the embedded query with explicit FK hints.
        // Keep the membership column list MINIMAL — extra columns that don't
        // exist or are RLS-blocked turn the whole select into a 4xx and break
        // unit loading entirely.
        let select = "unit_id,property_id,profile_id,role,is_primary," +
            "unit:property_units!unit_people_unit_id_fkey(id,property_id,unit_number,floor,bedrooms,bathrooms," +
            "property:properties!property_units_property_id_fkey(id,name,address,logo_path,photos))"
        if let rows = try? await api.from("unit_people")
            .select(select)
            .eq("profile_id", uid)
            .limit(50)
            .execute(as: [UnitPerson].self) {
            let units = rows.compactMap { $0.unit }.filter { !$0.property_id.isEmpty }
            if !units.isEmpty { return units }
        }
        // Fallback: fetch memberships, units, and properties in 3 separate queries
        // and stitch them together. Resilient to FK-name / embed-shape changes.
        let memberships = try await api.from("unit_people")
            .select("unit_id, property_id, profile_id, role, is_primary")
            .eq("profile_id", uid)
            .limit(50)
            .execute(as: [UnitPerson].self)
        let unitIds = Array(Set(memberships.map { $0.unit_id })).filter { !$0.isEmpty }
        guard !unitIds.isEmpty else { return [] }
        let propertyUnits = try await api.from("property_units")
            .select("id, property_id, unit_number, floor, bedrooms, bathrooms")
            .in("id", unitIds)
            .limit(100)
            .execute(as: [Unit].self)
        let propertyIds = Array(Set(propertyUnits.map { $0.property_id })).filter { !$0.isEmpty }
        var properties: [String: Property] = [:]
        if !propertyIds.isEmpty {
            let props = (try? await api.from("properties")
                .select("id, name, address, logo_path, photos")
                .in("id", propertyIds)
                .limit(100)
                .execute(as: [Property].self)) ?? []
            for p in props { properties[p.id] = p }
        }
        return propertyUnits.map { u in
            var copy = u
            copy.property = properties[u.property_id]
            return copy
        }
    }

    static func fetchUnitMemberships() async throws -> [UnitPerson] {
        guard let uid = currentUserId() else { return [] }
        // Try with balance columns; fall back to the minimal set if those
        // columns aren't present on this MontyResidentApp install.
        if let rows = try? await api.from("unit_people")
            .select("unit_id,property_id,profile_id,role,is_primary,outstanding_balance,past_due_balance")
            .eq("profile_id", uid)
            .limit(50)
            .execute(as: [UnitPerson].self) {
            return rows
        }
        return try await api.from("unit_people")
            .select("unit_id,property_id,profile_id,role,is_primary")
            .eq("profile_id", uid)
            .limit(50)
            .execute(as: [UnitPerson].self)
    }

    // MARK: - Chat sessions / messages

    private nonisolated struct ChatSessionRow: Decodable, Sendable {
        let id: String
    }

    /// Creates a row in `chat_sessions` for a fresh Ask Monty conversation.
    /// Best-effort: returns nil if the table is absent or RLS rejects the insert
    /// — the chat keeps working, it just won't be threaded server-side.
    static func createChatSession(propertyId: String) async -> String? {
        guard let uid = currentUserId() else { return nil }
        struct Payload: Encodable {
            let user_id: String
            let property_id: String
        }
        let row: ChatSessionRow? = try? await api.insert(
            into: "chat_sessions",
            body: Payload(user_id: uid, property_id: propertyId),
            returning: ChatSessionRow.self
        )
        return row?.id
    }

    /// Persists a single chat turn. Best-effort — silently no-ops if the table
    /// or columns are missing on this install.
    static func insertChatMessage(
        sessionId: String,
        role: String,
        content: String,
        auditId: String?,
        proposedTicket: ChatProposedTicket?,
        proposalStatus: String?
    ) async {
        struct Payload: Encodable {
            let session_id: String
            let role: String
            let content: String
            let ai_audit_id: String?
            let proposed_ticket: ChatProposedTicket?
            let proposal_status: String?
        }
        struct EmptyResp: Decodable {}
        _ = try? await api.insert(
            into: "chat_messages",
            body: Payload(
                session_id: sessionId,
                role: role,
                content: content,
                ai_audit_id: auditId,
                proposed_ticket: proposedTicket,
                proposal_status: proposalStatus
            ),
            returning: EmptyResp.self
        )
    }

    // MARK: - Tickets

    /// Resident tickets:
    /// - tickets the resident submitted (resident_id = uid), AND
    /// - management tickets (ticket_type = management) for their property.
    /// RLS enforces that staff-only tickets stay hidden.
    static func fetchTickets(unitId: String? = nil, propertyId: String? = nil) async throws -> [Ticket] {
        guard let uid = currentUserId() else { return [] }
        let select = "id, title, description, status, is_ai_handled, ai_urgency_score, created_at, updated_at, resident_id, property_id, ticket_type, unit_id"
        if let pid = propertyId, !pid.isEmpty {
            return try await api.from("tickets")
                .select(select)
                .eq("property_id", pid)
                .or("resident_id.eq.\(uid),ticket_type.eq.management")
                .order("created_at", ascending: false)
                .limit(100)
                .execute(as: [Ticket].self)
        }
        return try await api.from("tickets")
            .select(select)
            .eq("resident_id", uid)
            .order("created_at", ascending: false)
            .limit(100)
            .execute(as: [Ticket].self)
    }

    static func fetchTicket(id: String) async throws -> Ticket? {
        // Try with `ai_recommended_vendor_ids`; fall back if column is absent.
        let withVendors = "id, unit_id, resident_id, property_id, organization_id, title, description, status, ticket_type, is_ai_handled, ai_urgency_score, attachment_urls, ai_recommended_vendor_ids, created_at, updated_at"
        if let t = try? await api.from("tickets")
            .select(withVendors)
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: Ticket.self) {
            return t
        }
        return try await api.from("tickets")
            .select("id, unit_id, resident_id, property_id, organization_id, title, description, status, ticket_type, is_ai_handled, ai_urgency_score, attachment_urls, created_at, updated_at")
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: Ticket.self)
    }

    static func fetchTicketMessages(ticketId: String) async throws -> [TicketMessage] {
        // Spec uses `content`. Fall back to legacy `body` column if needed.
        let primary = "id, ticket_id, sender_id, content, is_ai_response, is_internal_note, created_at"
        if let rows = try? await api.from("ticket_messages")
            .select(primary)
            .eq("ticket_id", ticketId)
            .eq("is_internal_note", "false")
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [TicketMessage].self) {
            return rows
        }
        let rows = try await api.from("ticket_messages")
            .select("id, ticket_id, sender_id, body, is_ai_response, is_internal_note, created_at, attachments")
            .eq("ticket_id", ticketId)
            .order("created_at", ascending: true)
            .limit(200)
            .execute(as: [TicketMessage].self)
        return rows.filter { !($0.is_internal_note ?? false) }
    }

    @discardableResult
    static func postTicketMessage(ticketId: String, body text: String) async throws -> TicketMessage {
        guard let uid = currentUserId() else {
            throw SupabaseError.auth("Not signed in")
        }
        struct Payload: Encodable {
            let ticket_id: String
            let sender_id: String
            let content: String
            let is_ai_response: Bool
            let is_internal_note: Bool
        }
        do {
            return try await api.insert(
                into: "ticket_messages",
                body: Payload(ticket_id: ticketId, sender_id: uid, content: text, is_ai_response: false, is_internal_note: false),
                returning: TicketMessage.self
            )
        } catch {
            // Legacy installs that use `body` instead of `content`.
            struct LegacyPayload: Encodable {
                let ticket_id: String
                let sender_id: String
                let body: String
            }
            return try await api.insert(
                into: "ticket_messages",
                body: LegacyPayload(ticket_id: ticketId, sender_id: uid, body: text),
                returning: TicketMessage.self
            )
        }
    }

    @discardableResult
    static func createTicket(
        title: String,
        description: String,
        propertyId: String,
        unitId: String?,
        attachmentPaths: [String] = []
    ) async throws -> Ticket {
        guard let uid = currentUserId() else {
            throw SupabaseError.auth("Not signed in")
        }
        // Resolve organization_id from the property (required by the spec).
        struct PropOrg: Codable { let organization_id: String? }
        let prop: PropOrg? = try? await api.from("properties")
            .select("organization_id")
            .eq("id", propertyId)
            .limit(1)
            .single()
            .executeOptional(as: PropOrg.self)

        struct Payload: Encodable {
            let title: String
            let description: String
            let category: String
            let priority: String
            let status: String
            let resident_id: String
            let property_id: String
            let organization_id: String?
            let unit_id: String?
            let ticket_type: String
            let attachment_urls: [String]?
        }
        let ticket = try await api.insert(
            into: "tickets",
            body: Payload(
                title: title,
                description: description,
                category: "general", // placeholder; AI re-classifies
                priority: "medium",  // placeholder; AI re-scores
                status: "open",
                resident_id: uid,
                property_id: propertyId,
                organization_id: prop?.organization_id,
                unit_id: unitId,
                ticket_type: "resident",
                attachment_urls: attachmentPaths.isEmpty ? nil : attachmentPaths
            ),
            returning: Ticket.self
        )

        // Invoke ticket-response edge function and persist the AI reply ourselves.
        // The edge function only returns the text — it does NOT write to ticket_messages.
        TicketAIStore.shared.markInflight(ticket.id)
        TicketAIStore.shared.clearError(for: ticket.id)
        Task { [ticket] in
            defer { TicketAIStore.shared.clearInflight(ticket.id) }
            do {
                try await Self.requestAIResponse(
                    ticketId: ticket.id,
                    title: title,
                    description: description,
                    propertyId: propertyId,
                    attachmentCount: attachmentPaths.count
                )
            } catch {
                TicketAIStore.shared.setError(
                    error.localizedDescription,
                    for: ticket.id
                )
            }
        }

        return ticket
    }

    /// Server-driven ticket creation from Ask Monty.
    ///
    /// POSTs to `/functions/v1/create-ticket-from-chat`, which atomically:
    ///   1. inserts the ticket row with org/property/resident wiring,
    ///   2. runs AI triage to classify intent,
    ///   3. runs vendor matching (writes `ai_recommended_vendor_ids`),
    ///   4. seeds the resident description + AI acknowledgement into
    ///      `ticket_messages`,
    ///   5. emails the resident + logs ai_usage_logs.
    ///
    /// The client must NOT also POST to `/rest/v1/tickets` or
    /// `/functions/v1/triage-ticket` — both are now handled server-side.
    static func createTicketFromChat(
        title: String,
        description: String,
        category: String?,
        priority: String?,
        issueType: String?,
        propertyId: String,
        residentId: String,
        auditId: String? = nil
    ) async throws -> CreateTicketFromChatResult {
        var ticketBody: [String: Any] = [
            "title": title,
            "description": description,
            "category": (category?.isEmpty == false ? category! : "general"),
            "priority": (priority?.isEmpty == false ? priority! : "medium"),
        ]
        if let issueType, !issueType.isEmpty {
            ticketBody["issue_type"] = issueType
        }
        if let auditId, !auditId.isEmpty {
            // Server uses this to thread the resident's escalation back to the
            // original AI exchange in the admin audit page.
            ticketBody["ai_audit_id"] = auditId
        }
        var body: [String: Any] = [
            "ticket": ticketBody,
            "propertyId": propertyId,
            "residentId": residentId,
        ]
        if let auditId, !auditId.isEmpty {
            body["auditId"] = auditId
        }

        let data = try await invokeFunctionWithRetry(
            name: "create-ticket-from-chat",
            body: body,
            timeout: 45
        )

        let decoder = JSONDecoder()
        do {
            let resp = try decoder.decode(CreateTicketFromChatResponse.self, from: data)
            guard let ticket = resp.ticket else {
                throw SupabaseError.decoding("Missing ticket in response")
            }
            return CreateTicketFromChatResult(
                ticket: ticket,
                recommendedVendors: Self.normalizeVendors(resp.recommendedVendors),
                triageIntent: resp.triageIntent
            )
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// Asks Monty to email the recommended vendor on the resident's behalf.
    /// Server decides whether to send directly or queue a pending_action,
    /// based on `tickets.approve_ai_vendor_email` permissions.
    @discardableResult
    static func contactVendorForTicket(
        ticketId: String,
        vendorId: String
    ) async throws -> Data {
        try await invokeFunctionWithRetry(
            name: "contact-vendor-for-ticket",
            body: [
                "ticketId": ticketId,
                "vendorId": vendorId,
            ],
            timeout: 45
        )
    }

    /// Fetches the latest vendor outreach state for a ticket (used to hide
    /// the outreach prompt once it's been sent or declined).
    static func fetchVendorOutreachState(ticketId: String) async throws -> VendorOutreachState? {
        try await api.from("tickets")
            .select("vendor_outreach_status, vendor_outreach_vendor_id, vendor_outreach_sent_at, ai_recommended_vendor_ids")
            .eq("id", ticketId)
            .limit(1)
            .single()
            .executeOptional(as: VendorOutreachState.self)
    }

    // MARK: - AI Trust Layer

    /// Marks an AI response as verified by the resident.
    @discardableResult
    static func verifyAIResponse(auditId: String) async throws -> Data {
        try await callRPC(name: "verify_ai_response", params: ["p_audit_id": auditId])
    }

    /// Escalates an AI response for human review.
    @discardableResult
    static func escalateAIResponse(auditId: String, reason: String?) async throws -> Data {
        var params: [String: Any] = ["p_audit_id": auditId]
        if let reason, !reason.isEmpty { params["p_reason"] = reason }
        return try await callRPC(name: "escalate_ai_response", params: params)
    }

    private static func callRPC(name: String, params: [String: Any]) async throws -> Data {
        guard let url = URL(string: "\(SupabaseConfig.url)/rest/v1/rpc/\(name)") else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        return try await api.performData(req)
    }

    /// Edge-function invoke with one exponential-backoff retry on 5xx /
    /// transport errors. 4xx errors are surfaced immediately so the UI can
    /// map them to a friendly message.
    private static func invokeFunctionWithRetry(
        name: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> Data {
        do {
            return try await invokeFunction(name: name, body: body, timeout: timeout)
        } catch let SupabaseError.http(status, _) where status >= 500 {
            try? await Task.sleep(for: .milliseconds(600))
            return try await invokeFunction(name: name, body: body, timeout: timeout)
        } catch SupabaseError.network {
            try? await Task.sleep(for: .milliseconds(600))
            return try await invokeFunction(name: name, body: body, timeout: timeout)
        }
    }

    private static func normalizeVendors(_ raw: [JSONValue]?) -> [RecommendedVendor] {
        guard let raw, !raw.isEmpty else { return [] }
        guard let data = try? JSONEncoder().encode(raw) else { return [] }
        if let camel = try? JSONDecoder().decode([RecommendedVendor].self, from: data) {
            return camel
        }
        let snake = JSONDecoder()
        snake.keyDecodingStrategy = .convertFromSnakeCase
        return (try? snake.decode([RecommendedVendor].self, from: data)) ?? []
    }

    /// Calls the `ticket-response` edge function and inserts the returned
    /// text into `ticket_messages` as an AI message (sender_id: null).
    static func requestAIResponse(
        ticketId: String,
        title: String,
        description: String,
        propertyId: String,
        attachmentCount: Int
    ) async throws {
        let data = try await invokeFunction(
            name: "ticket-response",
            body: [
                "ticketId": ticketId,
                "title": title,
                "description": description,
                "category": "general",
                "propertyId": propertyId,
                "attachmentCount": attachmentCount,
            ],
            timeout: 45
        )

        let rawBody = String(data: data, encoding: .utf8) ?? ""

        // Debug: surface the raw edge-function payload so we can verify
        // whether `recommendedVendors` is present, snake_case, or missing.
        #if DEBUG
        print("[ticket-response] ticket=\(ticketId) raw=\(rawBody)")
        #endif
        TicketAIStore.shared.setDebug(rawBody, for: ticketId)

        // Parse defensively — the edge function payload mixes well-typed
        // fields (`response`, `skipped`) with a vendor array whose shape can
        // drift (snake_case keys, nulls, extra fields). A single failed
        // vendor decode must NOT swallow the AI reply, so we extract the
        // text from a raw JSON dict and try vendors independently.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let replyText = (json?["response"] as? String)
            ?? (json?["message"] as? String)
            ?? (json?["text"] as? String)
        let skipped = (json?["skipped"] as? Bool) ?? false

        // Best-effort vendor decoding — try camelCase first, then snake_case.
        if let vendorsRaw = json?["recommendedVendors"] ?? json?["recommended_vendors"],
           let vendorsData = try? JSONSerialization.data(withJSONObject: vendorsRaw) {
            var vendors: [RecommendedVendor] = []
            if let camel = try? JSONDecoder().decode([RecommendedVendor].self, from: vendorsData) {
                vendors = camel
            } else {
                let snake = JSONDecoder()
                snake.keyDecodingStrategy = .convertFromSnakeCase
                if let s = try? snake.decode([RecommendedVendor].self, from: vendorsData) {
                    vendors = s
                }
            }
            if !vendors.isEmpty {
                TicketAIStore.shared.setVendors(vendors, for: ticketId)
            }
        }

        guard let text = replyText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            if skipped { return }
            // Edge function returned no usable text — surface so the UI doesn't
            // hang on "Monty is thinking" forever.
            let snippet = String(rawBody.prefix(160))
            throw SupabaseError.decoding("AI response empty: \(snippet)")
        }

        do {
            _ = try await api.insert(
                into: "ticket_messages",
                body: AIMessagePayload(
                    ticket_id: ticketId,
                    content: text,
                    is_ai_response: true,
                    is_internal_note: false
                ),
                returning: TicketMessage.self
            )
        } catch {
            // Legacy schema fallback (`body` instead of `content`).
            _ = try await api.insert(
                into: "ticket_messages",
                body: LegacyAIPayload(
                    ticket_id: ticketId,
                    body: text,
                    is_ai_response: true
                ),
                returning: TicketMessage.self
            )
        }
    }

    // MARK: - AI message payloads

    /// Encodable payload for an AI-authored ticket_messages insert.
    /// Explicitly encodes `sender_id` as JSON `null` (Swift's default
    /// Codable would omit the field entirely, which some RLS policies and
    /// `NOT NULL`-default schemas reject — leaving the placeholder bubble
    /// stuck on "Monty is thinking" forever).
    private struct AIMessagePayload: Encodable {
        let ticket_id: String
        let content: String
        let is_ai_response: Bool
        let is_internal_note: Bool

        enum CodingKeys: String, CodingKey {
            case ticket_id, sender_id, content, is_ai_response, is_internal_note
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ticket_id, forKey: .ticket_id)
            try c.encodeNil(forKey: .sender_id)
            try c.encode(content, forKey: .content)
            try c.encode(is_ai_response, forKey: .is_ai_response)
            try c.encode(is_internal_note, forKey: .is_internal_note)
        }
    }

    private struct LegacyAIPayload: Encodable {
        let ticket_id: String
        let body: String
        let is_ai_response: Bool

        enum CodingKeys: String, CodingKey {
            case ticket_id, sender_id, body, is_ai_response
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ticket_id, forKey: .ticket_id)
            try c.encodeNil(forKey: .sender_id)
            try c.encode(body, forKey: .body)
            try c.encode(is_ai_response, forKey: .is_ai_response)
        }
    }

    // MARK: - Vendors

    /// Hydrate full vendor records from a list of vendor UUIDs. Used as a
    /// fallback when `ticket-response` returned vendor IDs in
    /// `tickets.ai_recommended_vendor_ids` but didn't include the full
    /// vendor objects in its JSON payload.
    static func fetchVendorsByIds(_ ids: [String]) async throws -> [RecommendedVendor] {
        let ids = ids.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        let rows = try await api.from("vendors")
            .select("id, name, category, contact_name, phone, email")
            .in("id", ids)
            .limit(50)
            .execute(as: [VendorDirectoryEntry].self)
        // Preserve the original ordering of `ids`.
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ids.compactMap { byId[$0]?.asRecommended }
    }

    /// Vendors visible to residents for a given organization. Used by the
    /// "Choose a different vendor" picker on the ticket detail screen.
    static func fetchVendorsForResidents(organizationId: String) async throws -> [VendorDirectoryEntry] {
        // Try with the resident-visibility flag; fall back if the column
        // doesn't exist on this install.
        if let rows = try? await api.from("vendors")
            .select("id, name, category, contact_name, phone, email, organization_id, is_visible_to_residents")
            .eq("organization_id", organizationId)
            .eq("is_visible_to_residents", "true")
            .order("name", ascending: true)
            .limit(200)
            .execute(as: [VendorDirectoryEntry].self) {
            return rows
        }
        return try await api.from("vendors")
            .select("id, name, category, contact_name, phone, email, organization_id")
            .eq("organization_id", organizationId)
            .order("name", ascending: true)
            .limit(200)
            .execute(as: [VendorDirectoryEntry].self)
    }

    // MARK: - Resident Vendor Directory

    private nonisolated struct PropertyVendorAssignmentRow: Decodable, Sendable {
        let vendor_id: String
    }

    private nonisolated struct RecommendVendorsResponse: Decodable, Sendable {
        let recommendations: [VendorRecommendation]
    }

    /// Preferred vendors for the resident's property, with embedded contacts.
    /// Mirrors the web `usePropertyVendors` hook 1:1:
    ///   1. read `property_vendor_assignments` (property_id, is_enabled=true)
    ///   2. read `vendors` with embedded `vendor_contacts` for those ids
    /// RLS scopes both reads — no extra filters needed.
    static func fetchPropertyVendorsForResident(propertyId: String) async throws -> [ResidentVendor] {
        let assignments = try await api.from("property_vendor_assignments")
            .select("vendor_id")
            .eq("property_id", propertyId)
            .eq("is_enabled", "true")
            .limit(500)
            .execute(as: [PropertyVendorAssignmentRow].self)
        let ids = Array(Set(assignments.map { $0.vendor_id })).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        return try await api.from("vendors")
            .select("id, name, category, description, vendor_contacts(contact_name, email, phone, is_primary)")
            .in("id", ids)
            .order("name", ascending: true)
            .limit(500)
            .execute(as: [ResidentVendor].self)
    }

    /// Calls the `recommend-vendors` edge function. Bearer token is attached
    /// automatically by `performData` — without it the function returns 401.
    static func recommendVendors(description: String, propertyId: String) async throws -> [VendorRecommendation] {
        let data = try await invokeFunction(
            name: "recommend-vendors",
            body: [
                "description": description,
                "property_id": propertyId,
            ],
            timeout: 45
        )
        do {
            return try JSONDecoder().decode(RecommendVendorsResponse.self, from: data).recommendations
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// Fires the `ticket-vendor-outreach` edge function and writes a
    /// confirmation AI message into the thread.
    static func triggerVendorOutreach(
        ticketId: String,
        vendor: RecommendedVendor
    ) async throws {
        _ = try await invokeFunction(
            name: "ticket-vendor-outreach",
            body: [
                "ticketId": ticketId,
                "vendorId": vendor.vendorId,
            ],
            timeout: 45
        )

        // Confirmation message in the thread, attributed to Monty AI.
        let confirm = "Reaching out to \(vendor.name) now…"
        do {
            _ = try await api.insert(
                into: "ticket_messages",
                body: AIMessagePayload(
                    ticket_id: ticketId,
                    content: confirm,
                    is_ai_response: true,
                    is_internal_note: false
                ),
                returning: TicketMessage.self
            )
        } catch {
            _ = try? await api.insert(
                into: "ticket_messages",
                body: LegacyAIPayload(
                    ticket_id: ticketId,
                    body: confirm,
                    is_ai_response: true
                ),
                returning: TicketMessage.self
            )
        }
    }

    // MARK: - Edge Functions

    @discardableResult
    static func invokeFunction(name: String, body: [String: Any], timeout: TimeInterval = 45) async throws -> Data {
        guard let url = URL(string: "\(SupabaseConfig.url)/functions/v1/\(name)") else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await api.performData(req)
    }

    // MARK: - Packages
    // Web filters by property_id + unit_number (resident_id is often null).

    static func fetchPackages(propertyId: String, unitNumber: String) async throws -> [Package] {
        let select = "id, property_id, resident_id, recipient_name, unit_number, carrier, tracking_number, photo_url, status, notes, received_at, picked_up_at, package_size, description, direction, notified_at, notification_count, picked_up_by, pickup_notes, recipient_address, sent_at, created_at"
        if let rows = try? await api.from("packages")
            .select(select)
            .eq("property_id", propertyId)
            .eq("unit_number", unitNumber)
            .order("received_at", ascending: false)
            .limit(100)
            .execute(as: [Package].self) {
            return rows
        }
        // Fallback: if any of the extended columns are missing on this install,
        // fall back to the original minimal selection.
        return try await api.from("packages")
            .select("id, property_id, resident_id, recipient_name, unit_number, carrier, tracking_number, photo_url, status, notes, received_at, picked_up_at")
            .eq("property_id", propertyId)
            .eq("unit_number", unitNumber)
            .order("received_at", ascending: false)
            .limit(100)
            .execute(as: [Package].self)
    }

    static func fetchPackage(id: String) async throws -> Package? {
        try await api.from("packages")
            .select("id, property_id, resident_id, recipient_name, unit_number, carrier, tracking_number, photo_url, status, notes, received_at, picked_up_at")
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: Package.self)
    }

    // MARK: - Amenities
    // Table is `property_amenities`. Bookings use booking_date + start_time + end_time
    // and have no unit_id (filter by user_id).

    static func fetchAmenities(propertyId: String) async throws -> [Amenity] {
        // Try the full spec first; fall back to a minimal column set if any
        // of the new columns aren't present on this install.
        let full = "id, property_id, name, description, image_url, availability_hours, booking_config, is_24_7, requires_booking, created_at"
        if let rows = try? await api.from("property_amenities")
            .select(full)
            .eq("property_id", propertyId)
            .order("name", ascending: true)
            .limit(50)
            .execute(as: [Amenity].self) {
            return rows
        }
        return try await api.from("property_amenities")
            .select("id, property_id, name, description, image_url")
            .eq("property_id", propertyId)
            .order("name", ascending: true)
            .limit(50)
            .execute(as: [Amenity].self)
    }

    static func fetchAmenity(id: String) async throws -> Amenity? {
        let full = "id, property_id, name, description, image_url, availability_hours, booking_config, is_24_7, requires_booking, created_at"
        if let row = try? await api.from("property_amenities")
            .select(full)
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: Amenity.self) {
            return row
        }
        return try await api.from("property_amenities")
            .select("id, property_id, name, description, image_url")
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: Amenity.self)
    }

    static func fetchUpcomingBookings() async throws -> [AmenityBooking] {
        guard let uid = currentUserId() else { return [] }
        let today = ISO8601DateFormatter.dateOnly.string(from: Date())
        return try await api.from("amenity_bookings")
            .select("id, amenity_id, amenity:property_amenities(id, name, image_url), property_id, user_id, booking_date, start_time, end_time, status")
            .eq("user_id", uid)
            .gte("booking_date", today)
            .neq("status", "cancelled")
            .order("booking_date", ascending: true)
            .order("start_time", ascending: true)
            .limit(50)
            .execute(as: [AmenityBooking].self)
    }

    /// All non-cancelled bookings the resident owns at this property, including
    /// past ones (used by My Bookings list).
    static func fetchMyBookings(propertyId: String) async throws -> [AmenityBooking] {
        guard let uid = currentUserId() else { return [] }
        let select = "id, amenity_id, amenity:property_amenities(id, name, image_url), property_id, user_id, booking_date, start_time, end_time, status, notes, created_at, cancelled_at, rejection_reason, payment_verified"
        if let rows = try? await api.from("amenity_bookings")
            .select(select)
            .eq("property_id", propertyId)
            .eq("user_id", uid)
            .neq("status", "cancelled")
            .order("booking_date", ascending: true)
            .order("start_time", ascending: true)
            .limit(100)
            .execute(as: [AmenityBooking].self) {
            return rows
        }
        // Fallback without optional columns (cancelled_at, rejection_reason, payment_verified)
        return try await api.from("amenity_bookings")
            .select("id, amenity_id, amenity:property_amenities(id, name, image_url), property_id, user_id, booking_date, start_time, end_time, status, notes, created_at")
            .eq("property_id", propertyId)
            .eq("user_id", uid)
            .neq("status", "cancelled")
            .order("booking_date", ascending: true)
            .order("start_time", ascending: true)
            .limit(100)
            .execute(as: [AmenityBooking].self)
    }

    /// Existing non-cancelled bookings for an amenity on a given day.
    /// Used to mark slots as taken.
    static func fetchBookedSlots(amenityId: String, date: String) async throws -> [AmenityBooking] {
        try await api.from("amenity_bookings")
            .select("id, amenity_id, start_time, end_time, status")
            .eq("amenity_id", amenityId)
            .eq("booking_date", date)
            .neq("status", "cancelled")
            .limit(200)
            .execute(as: [AmenityBooking].self)
    }

    @discardableResult
    static func createAmenityBooking(
        amenityId: String,
        propertyId: String,
        date: String,
        start: String,
        end: String,
        notes: String?
    ) async throws -> AmenityBooking {
        guard let uid = currentUserId() else {
            throw SupabaseError.auth("Not signed in")
        }
        struct Payload: Encodable {
            let amenity_id: String
            let property_id: String
            let user_id: String
            let booking_date: String
            let start_time: String
            let end_time: String
            let notes: String?
        }
        return try await api.insert(
            into: "amenity_bookings",
            body: Payload(
                amenity_id: amenityId,
                property_id: propertyId,
                user_id: uid,
                booking_date: date,
                start_time: start,
                end_time: end,
                notes: (notes?.isEmpty == false) ? notes : nil
            ),
            returning: AmenityBooking.self
        )
    }

    @discardableResult
    static func cancelAmenityBooking(id: String) async throws -> AmenityBooking {
        struct Payload: Encodable {
            let status: String
            let cancelled_at: String
        }
        let now = Fmt.iso.string(from: Date())
        // Try with cancelled_at, fall back to status-only if column absent.
        do {
            return try await api.update(
                table: "amenity_bookings",
                id: id,
                body: Payload(status: "cancelled", cancelled_at: now),
                returning: AmenityBooking.self
            )
        } catch {
            struct Minimal: Encodable { let status: String }
            return try await api.update(
                table: "amenity_bookings",
                id: id,
                body: Minimal(status: "cancelled"),
                returning: AmenityBooking.self
            )
        }
    }

    // MARK: - Payments

    /// Reads `balance_cache` first, then falls back to `unit_people.outstanding_balance`
    /// (web fallback). Returns nil only if neither source has data.
    static func fetchBalance(unitId: String) async throws -> AccountBalance? {
        let cached: AccountBalance?? = try? await api.from("balance_cache")
            .select("unit_id, balance_cents, past_due_cents, fetched_at, expires_at")
            .eq("unit_id", unitId)
            .limit(1)
            .single()
            .executeOptional(as: AccountBalance.self)
        if let value = cached.flatMap({ $0 }) { return value }
        // Fallback: unit_people.outstanding_balance / past_due_balance (decimal dollars).
        // Wrapped in try? so a missing column on this install doesn't break Home.
        guard let uid = currentUserId() else { return nil }
        let memberships = (try? await api.from("unit_people")
            .select("unit_id, outstanding_balance, past_due_balance")
            .eq("profile_id", uid)
            .eq("unit_id", unitId)
            .limit(1)
            .execute(as: [UnitPerson].self)) ?? []
        guard let m = memberships.first else { return nil }
        let bal = Int(((m.outstanding_balance ?? 0) * 100).rounded())
        let due = Int(((m.past_due_balance ?? 0) * 100).rounded())
        return AccountBalance(unit_id: unitId, balance_cents: bal, past_due_cents: due, fetched_at: nil, expires_at: nil)
    }

    /// Recent payments for the logged-in resident. RLS scopes by `resident_id = auth.uid()`.
    /// `total_amount` is the paid amount (decimal dollars). Description is joined from
    /// `common_charges` via `charge_id`. `payment_method` is an enum cast to text on read.
    static func fetchPayments() async throws -> [PaymentRecord] {
        guard let uid = currentUserId() else { return [] }
        return try await api.from("payments")
            .select("id, charge_id, resident_id, amount, processing_fee, total_amount, payment_method, status, failure_reason, paid_at, created_at, charge:common_charges!payments_charge_id_fkey(description, due_date)")
            .eq("resident_id", uid)
            .order("created_at", ascending: false)
            .limit(10)
            .execute(as: [PaymentRecord].self)
    }

    /// Pending common charges for the logged-in resident. RLS scopes by `resident_id = auth.uid()`.
    /// Sum of `amount` is the resident's current balance; earliest `due_date` is the next due date.
    static func fetchPendingCharges() async throws -> [CommonCharge] {
        guard let uid = currentUserId() else { return [] }
        return try await api.from("common_charges")
            .select("id, resident_id, unit_id, amount, description, due_date, status, validation_status, validation_reason_message, created_at")
            .eq("resident_id", uid)
            .eq("status", "pending")
            .order("due_date", ascending: true)
            .limit(200)
            .execute(as: [CommonCharge].self)
    }

    /// Resident's move-in date for the active unit (used to derive activation).
    /// Returns nil if the column doesn't exist on this install or RLS blocks it.
    static func fetchUnitMoveInDate(unitId: String) async throws -> String? {
        guard let uid = currentUserId() else { return nil }
        struct Row: Codable { var move_in_date: String? }
        let rows = (try? await api.from("unit_people")
            .select("move_in_date")
            .eq("profile_id", uid)
            .eq("unit_id", unitId)
            .limit(1)
            .execute(as: [Row].self)) ?? []
        return rows.first?.move_in_date
    }

    // MARK: - Documents

    /// Resident-visible, current-version documents for a property.
    /// RLS already enforces this — we double-filter as a belt-and-suspenders
    /// guard so a flipped-visibility doc never accidentally leaks.
    static func fetchResidentDocuments(propertyId: String) async throws -> [DocumentItem] {
        try await api.from("property_documents")
            .select("id, property_id, name, file_path, file_type, file_size, category, expiry_date, created_at")
            .eq("property_id", propertyId)
            .eq("visible_to_residents", "true")
            .eq("is_current_version", "true")
            .order("created_at", ascending: false)
            .limit(300)
            .execute(as: [DocumentItem].self)
    }

    /// Generates a 1-hour signed URL for a private `property-documents` object.
    /// Always re-call on tap — never cache the resulting URL.
    static func signedURL(forDocumentPath path: String, expiresIn: Int = 3600) async throws -> URL {
        let cleaned = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let encoded = cleaned
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        guard let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/sign/property-documents/\(encoded)") else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": expiresIn])
        let data = try await api.performData(req)
        struct Resp: Decodable { let signedURL: String? }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let raw = resp.signedURL, !raw.isEmpty else {
            throw SupabaseError.decoding("Missing signedURL in response")
        }
        // The endpoint returns a path relative to /storage/v1 (e.g.
        // "/object/sign/property-documents/...?token=..."). Resolve to absolute.
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw) ?? url
        }
        let base = "\(SupabaseConfig.url)/storage/v1"
        let joined = raw.hasPrefix("/") ? base + raw : base + "/" + raw
        guard let abs = URL(string: joined) else { throw SupabaseError.badURL }
        return abs
    }

    // Legacy alias kept for any callers still using the old name.
    static func fetchDocuments(propertyId: String) async throws -> [DocumentItem] {
        try await fetchResidentDocuments(propertyId: propertyId)
    }

    // MARK: - Board

    private nonisolated struct BoardMemberRow: Decodable { let id: String }
    private nonisolated struct UnitPersonProfileRow: Decodable { let profile_id: String? }

    /// Returns true if the current user — OR any resident sharing their active
    /// unit — is an active board member for this property. Mirrors the web
    /// `unit-board-membership` query so co-residents of a board member also
    /// see the Board tile.
    static func fetchIsBoardMember(propertyId: String, unitId: String? = nil) async throws -> Bool {
        guard let uid = currentUserId(), !propertyId.isEmpty else { return false }

        // A. Direct check — is the current user themselves a board member?
        let direct = (try? await api.from("board_members")
            .select("id")
            .eq("profile_id", uid)
            .eq("property_id", propertyId)
            .limit(1)
            .execute(as: [BoardMemberRow].self)) ?? []
        if !direct.isEmpty {
            print("[board-check] unitId=\(unitId ?? "nil") propertyId=\(propertyId) directMatch=true isBoardMember=true")
            return true
        }

        // B. Unit-based check — is any resident on the active unit a board member?
        guard let unitId, !unitId.isEmpty else {
            print("[board-check] unitId=nil propertyId=\(propertyId) directMatch=false isBoardMember=false")
            return false
        }
        let people = (try? await api.from("unit_people")
            .select("profile_id")
            .eq("unit_id", unitId)
            .limit(50)
            .execute(as: [UnitPersonProfileRow].self)) ?? []
        let ids = Array(Set(people.compactMap { $0.profile_id })).filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            print("[board-check] unitId=\(unitId) propertyId=\(propertyId) coResidentProfileIds=[] isBoardMember=false")
            return false
        }
        let shared = (try? await api.from("board_members")
            .select("id")
            .eq("property_id", propertyId)
            .in("profile_id", ids)
            .limit(1)
            .execute(as: [BoardMemberRow].self)) ?? []
        let isMember = !shared.isEmpty
        print("[board-check] unitId=\(unitId) propertyId=\(propertyId) coResidentProfileIds=\(ids) boardMatchCount=\(shared.count) isBoardMember=\(isMember)")
        return isMember
    }

    /// Upcoming + recent board meetings for the resident's property. RLS scopes
    /// the read; we only need to filter by property + visible statuses.
    static func fetchBoardMeetings(propertyId: String) async throws -> [BoardMeeting] {
        guard !propertyId.isEmpty else { return [] }
        return try await api.from("board_meetings")
            .select("id, title, scheduled_at, status, property_id")
            .eq("property_id", propertyId)
            .in("status", ["scheduled", "in_progress", "completed"])
            .order("scheduled_at", ascending: false)
            .limit(50)
            .execute(as: [BoardMeeting].self)
    }

    // MARK: - Contacts

    static func fetchContacts(propertyId: String) async throws -> [StaffContact] {
        try await api.from("property_staff")
            .select("*")
            .eq("property_id", propertyId)
            .order("name", ascending: true)
            .limit(50)
            .execute(as: [StaffContact].self)
    }
}

// MARK: - create-ticket-from-chat response shapes

nonisolated struct CreateTicketFromChatResult: Sendable {
    let ticket: Ticket
    let recommendedVendors: [RecommendedVendor]
    let triageIntent: String?
}

nonisolated struct CreateTicketFromChatResponse: Decodable, Sendable {
    let success: Bool?
    let ticket: Ticket?
    let recommendedVendors: [JSONValue]?
    let triageIntent: String?

    enum CodingKeys: String, CodingKey {
        case success, ticket
        case recommendedVendors
        case recommended_vendors
        case triageIntent
        case triage_intent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeIfPresent(Bool.self, forKey: .success)
        ticket = try c.decodeIfPresent(Ticket.self, forKey: .ticket)
        let v1 = try c.decodeIfPresent([JSONValue].self, forKey: .recommendedVendors)
        let v2 = try c.decodeIfPresent([JSONValue].self, forKey: .recommended_vendors)
        recommendedVendors = v1 ?? v2
        let t1 = try c.decodeIfPresent(String.self, forKey: .triageIntent)
        let t2 = try c.decodeIfPresent(String.self, forKey: .triage_intent)
        triageIntent = t1 ?? t2
    }
}

nonisolated struct VendorOutreachState: Decodable, Sendable, Hashable {
    let vendor_outreach_status: String?
    let vendor_outreach_vendor_id: String?
    let vendor_outreach_sent_at: String?
    let ai_recommended_vendor_ids: [String]?

    /// True if the prompt should be hidden (already sent or declined).
    var isResolved: Bool {
        let s = (vendor_outreach_status ?? "").lowercased()
        return s == "sent" || s == "declined"
    }
}

/// Lightweight any-JSON wrapper so we can pass-through edge function payload
/// shape variants (camelCase vs snake_case vendor objects) without locking
/// in a brittle schema.
nonisolated enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

nonisolated extension ISO8601DateFormatter {
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
