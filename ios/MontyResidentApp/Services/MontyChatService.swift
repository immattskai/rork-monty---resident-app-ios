import Foundation

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    /// Vendor cards (populated after a ticket is created from a proposal).
    var recommendedVendors: [RecommendedVendor]?
    /// Ticket created from a confirmed proposal.
    var createdTicket: ChatTicket?
    /// Pending ticket proposal awaiting Yes / Not now.
    var proposedTicket: ChatProposedTicket?
    /// True after the user dismissed the proposal with "Not now".
    var proposalDeclined: Bool
    /// Server audit id for this assistant reply (Verify / Escalate).
    var auditId: String?
    /// Verify/escalate state for the trust badge.
    var verifyState: AIVerifyState
    /// True while we're processing the proposal confirmation.
    var isCreatingTicket: Bool
    /// User-facing error string (shown in-bubble with a Retry).
    var errorText: String?
    /// Sticky raw user input that produced this assistant reply (so Retry can resend).
    var sourceUserText: String?

    enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }

    enum AIVerifyState: String, Sendable, Hashable {
        case idle
        case verifying
        case verified
        case escalating
        case escalated
        case failed
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        isStreaming: Bool = false,
        recommendedVendors: [RecommendedVendor]? = nil,
        createdTicket: ChatTicket? = nil,
        proposedTicket: ChatProposedTicket? = nil,
        proposalDeclined: Bool = false,
        auditId: String? = nil,
        verifyState: AIVerifyState = .idle,
        isCreatingTicket: Bool = false,
        errorText: String? = nil,
        sourceUserText: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.recommendedVendors = recommendedVendors
        self.createdTicket = createdTicket
        self.proposedTicket = proposedTicket
        self.proposalDeclined = proposalDeclined
        self.auditId = auditId
        self.verifyState = verifyState
        self.isCreatingTicket = isCreatingTicket
        self.errorText = errorText
        self.sourceUserText = sourceUserText
    }
}

nonisolated struct ChatTicket: Codable, Hashable, Sendable {
    var id: String?
    var title: String?
    var status: String?
    var priority: String?
}

/// Proposed ticket payload emitted by the backend on the chat-with-ai SSE
/// stream. Confirmed by the user via the TicketProposalCard.
nonisolated struct ChatProposedTicket: Codable, Hashable, Sendable {
    var title: String
    var description: String
    var category: String?
    var priority: String?
    var issue_type: String?
}

nonisolated enum ChatStreamEvent: Sendable {
    case meta(complexity: String?)
    case auditId(String)
    case proposedTicket(ChatProposedTicket)
    case delta(String)
    case done
}

/// Resident-facing error categories returned by the chat / ticket pipeline.
nonisolated enum ChatFriendlyError: Error, Sendable {
    case auth          // 401 / 403
    case notFound      // 404 / NOT_FOUND
    case rateLimited   // 429
    case server        // 5xx
    case network       // URL / transport errors
    case unknown(String?)

    var residentMessage: String {
        switch self {
        case .auth:
            return "Please sign in again."
        case .notFound:
            return "Monty isn't set up for this building yet."
        case .rateLimited:
            return "You've sent a lot of messages — try again in a bit."
        case .server, .network:
            return "Couldn't reach Monty. Tap retry."
        case .unknown:
            return "Something went wrong. Please try again."
        }
    }

    static func map(status: Int, raw: String) -> ChatFriendlyError {
        if status == 401 || status == 403 { return .auth }
        if status == 404 || raw.contains("\"NOT_FOUND\"") { return .notFound }
        if status == 429 { return .rateLimited }
        if status >= 500 { return .server }
        return .unknown(raw.isEmpty ? nil : raw)
    }

    static func map(_ error: Error) -> ChatFriendlyError {
        if let f = error as? ChatFriendlyError { return f }
        if let s = error as? SupabaseError {
            switch s {
            case .auth: return .auth
            case .network: return .network
            case .http(let status, let message): return .map(status: status, raw: message)
            case .badURL, .decoding: return .unknown(s.errorDescription)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .network }
        return .unknown(error.localizedDescription)
    }
}

@MainActor
enum MontyChatService {
    /// Streams Monty AI responses from the `chat-with-ai` Supabase edge function.
    static func stream(
        message: String,
        propertyId: String,
        history: [ChatMessage]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await SupabaseAPI.shared.refreshIfNeeded()
                    guard let token = SupabaseAPI.shared.session?.access_token else {
                        throw ChatFriendlyError.auth
                    }
                    guard let url = URL(string: "\(SupabaseConfig.url)/functions/v1/chat-with-ai") else {
                        throw SupabaseError.badURL
                    }

                    let body: [String: Any] = [
                        "message": message,
                        "propertyId": propertyId,
                        "contextLevel": "full",
                    ]
                    _ = history // server-side session manages history

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatFriendlyError.network
                    }
                    if !(200...299).contains(http.statusCode) {
                        var collected = Data()
                        for try await b in bytes { collected.append(b) }
                        let raw = String(data: collected, encoding: .utf8) ?? ""
                        throw ChatFriendlyError.map(status: http.statusCode, raw: raw)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line
                            .dropFirst("data:".count)
                            .trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" {
                            continuation.yield(.done)
                            break
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        Self.dispatch(json: json, continuation: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ChatFriendlyError.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Routes a single SSE JSON frame to the correct event case. Critically,
    /// any frame that ISN'T an OpenAI-style `choices` delta is treated as a
    /// meta frame — never short-circuit out of the loop on unknown shapes,
    /// otherwise tool-only replies (zero text + meta) silently disappear.
    private static func dispatch(
        json: [String: Any],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) {
        // Standalone meta frames (no `choices` field).
        if let auditId = json["auditId"] as? String, !auditId.isEmpty {
            continuation.yield(.auditId(auditId))
        }
        if let proposed = json["proposedTicket"] as? [String: Any] {
            if let pt = Self.decodeProposedTicket(proposed) {
                continuation.yield(.proposedTicket(pt))
            }
        }
        // Legacy `type: meta` frames carry `complexity` (and historically auditId).
        if let type = json["type"] as? String, type == "meta" {
            continuation.yield(.meta(complexity: json["complexity"] as? String))
        }

        // OpenAI-style delta — text content for the assistant bubble.
        if let choices = json["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            continuation.yield(.delta(content))
        }
    }

    private static func decodeProposedTicket(_ dict: [String: Any]) -> ChatProposedTicket? {
        guard let title = dict["title"] as? String, !title.isEmpty,
              let description = dict["description"] as? String else {
            return nil
        }
        return ChatProposedTicket(
            title: title,
            description: description,
            category: dict["category"] as? String,
            priority: dict["priority"] as? String,
            issue_type: dict["issue_type"] as? String ?? dict["issueType"] as? String
        )
    }
}
