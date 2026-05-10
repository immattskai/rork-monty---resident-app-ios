import Foundation

/// Tracks AI generation in-flight per ticket and any vendor recommendations
/// returned by the `ticket-response` edge function. Allows the detail view to
/// (a) show a "Monty is thinking" placeholder while the call is in flight, and
/// (b) attach vendor cards to the resulting AI message once it arrives.
@MainActor
@Observable
final class TicketAIStore {
    static let shared = TicketAIStore()

    private(set) var inflight: Set<String> = []
    private(set) var vendors: [String: [RecommendedVendor]] = [:]
    /// Last AI error per-ticket. Surfaced in the detail view so silent
    /// edge-function or insert failures don't leave the user staring at
    /// "No messages yet." forever.
    private(set) var errors: [String: String] = [:]
    /// Tracks per-message ids that already had a vendor action chosen (so the
    /// action row hides). Persisted in-memory only.
    private(set) var actionTakenMessageIds: Set<String> = []
    /// Last raw `ticket-response` payload per-ticket. Surfaced in the detail
    /// view (debug-only) so we can copy/paste the exact JSON when vendor cards
    /// don't show up.
    private(set) var debugPayloads: [String: String] = [:]
    /// Bumped any time the store changes so views can react via `.onChange`.
    private(set) var revision: Int = 0

    private init() {}

    func markInflight(_ ticketId: String) {
        inflight.insert(ticketId)
        revision &+= 1
    }

    func clearInflight(_ ticketId: String) {
        inflight.remove(ticketId)
        revision &+= 1
    }

    func setError(_ message: String, for ticketId: String) {
        errors[ticketId] = message
        revision &+= 1
    }

    func clearError(for ticketId: String) {
        errors.removeValue(forKey: ticketId)
        revision &+= 1
    }

    func error(for ticketId: String) -> String? { errors[ticketId] }

    func setVendors(_ vendors: [RecommendedVendor], for ticketId: String) {
        guard !vendors.isEmpty else { return }
        self.vendors[ticketId] = vendors
        revision &+= 1
    }

    func consumeVendors(for ticketId: String) -> [RecommendedVendor]? {
        guard let v = vendors[ticketId] else { return nil }
        vendors.removeValue(forKey: ticketId)
        revision &+= 1
        return v
    }

    func peekVendors(for ticketId: String) -> [RecommendedVendor]? {
        vendors[ticketId]
    }

    func markActionTaken(messageId: String) {
        actionTakenMessageIds.insert(messageId)
        revision &+= 1
    }

    func hasActionBeenTaken(messageId: String) -> Bool {
        actionTakenMessageIds.contains(messageId)
    }

    func setDebug(_ raw: String, for ticketId: String) {
        debugPayloads[ticketId] = raw
        revision &+= 1
    }

    func debug(for ticketId: String) -> String? { debugPayloads[ticketId] }
}
