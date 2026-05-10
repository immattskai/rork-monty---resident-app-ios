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
    /// Server audit id for this assistant reply (links the escalation ticket
    /// back to the original AI exchange for staff context).
    var auditId: String?
    /// State of the resident's "talk to a human" escalation control.
    var verifyState: AIVerifyState
    /// Ticket id created when the resident asked to talk to a human (so the
    /// confirmation row can deep-link into it).
    var escalationTicketId: String?
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

    /// Lifecycle of the escalation control. (`verifying` / `verified` are
    /// retained for source/binary compatibility with persisted history but
    /// are no longer surfaced in the resident app UI.)
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
        escalationTicketId: String? = nil,
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
        self.escalationTicketId = escalationTicketId
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
    var title: String?
    var description: String?
    var category: String?
    var priority: String?
    var issue_type: String?
    /// Backend may emit a follow-up question instead of (or alongside) a draft
    /// ticket. The chat surface renders this as the assistant text bubble when
    /// no `title` is present (matches the web behaviour).
    var clarifying_question: String?

    /// True if the proposal carries enough info to render a confirmable ticket
    /// card. A clarifying-only proposal returns false — we surface the question
    /// in the bubble text instead.
    var hasDraftTicket: Bool {
        (title?.isEmpty == false)
    }
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

// MARK: - Buffered SSE parser
//
// The `chat-with-ai` edge function emits events separated by `\n\n` (or
// `\r\n\r\n`). `URLSession.AsyncBytes.lines` splits on single `\n` and will
// hand back partial `data:` lines mid-frame — those then fail JSON parsing
// and get silently dropped, which is exactly the bug we hit. This parser
// accumulates bytes until a full frame is in hand, then yields it.
//
// Pure / nonisolated so it's testable without spinning up the network.
nonisolated struct SSEFrameBuffer {
    private var buffer = Data()

    /// Append a new chunk of bytes and return any complete frames now in the
    /// buffer (each as a UTF-8 string, with the trailing separator stripped).
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        return drain()
    }

    /// Returns any remaining buffered content as a single "frame" (used on
    /// stream end so trailing data without a final `\n\n` isn't lost).
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let s = String(data: buffer, encoding: .utf8)
        buffer.removeAll(keepingCapacity: false)
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private mutating func drain() -> [String] {
        var frames: [String] = []
        // Search for \n\n or \r\n\r\n. We scan over Data for byte patterns.
        while let range = nextSeparator(in: buffer) {
            let frameData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            if let s = String(data: frameData, encoding: .utf8), !s.isEmpty {
                frames.append(s)
            }
        }
        return frames
    }

    private func nextSeparator(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            // \n\n
            if bytes[i] == 0x0A, i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                return i..<(i + 2)
            }
            // \r\n\r\n
            if bytes[i] == 0x0D,
               i + 3 < bytes.count,
               bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D,
               bytes[i + 3] == 0x0A {
                return i..<(i + 4)
            }
            i += 1
        }
        return nil
    }
}

/// Parses a single fully-assembled SSE frame into zero or more stream events.
/// Per the SSE spec, a frame may contain multiple `data:` lines whose values
/// are joined with `\n`. Returns the resulting event list (or empty if the
/// frame had no `data:` lines, e.g. a `: comment` keepalive).
nonisolated func parseSSEFrame(_ frame: String) -> [ChatStreamEvent] {
    var dataLines: [String] = []
    for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
        if line.hasPrefix("data:") {
            let payload = String(line.dropFirst("data:".count))
            // Per spec, strip a single leading space if present.
            dataLines.append(payload.hasPrefix(" ") ? String(payload.dropFirst()) : payload)
        }
        // Ignore `event:`, `id:`, `retry:`, comments. Server doesn't use them.
    }
    guard !dataLines.isEmpty else { return [] }
    let payload = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if payload.isEmpty { return [] }
    if payload == "[DONE]" { return [.done] }

    guard let bytes = payload.data(using: .utf8) else { return [] }
    guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        #if DEBUG
        let preview = String(payload.prefix(200))
        print("[MontyChat][SSE] Unparseable fully-assembled frame: \(preview)")
        #endif
        return []
    }

    #if DEBUG
    print("[MontyChat][SSE] frame keys=\(Array(json.keys))")
    #endif

    var events: [ChatStreamEvent] = []

    if let auditId = json["auditId"] as? String, !auditId.isEmpty {
        events.append(.auditId(auditId))
    }
    if let proposed = json["proposedTicket"] as? [String: Any] {
        if let pt = decodeProposedTicket(proposed) {
            events.append(.proposedTicket(pt))
        }
    }
    if let type = json["type"] as? String, type == "meta" {
        events.append(.meta(complexity: json["complexity"] as? String))
    }
    if let complexity = json["complexity"] as? String,
       json["type"] == nil,
       json["choices"] == nil {
        // First frame from chat-with-ai: bare {"complexity":"simple"}.
        events.append(.meta(complexity: complexity))
    }
    if let choices = json["choices"] as? [[String: Any]],
       let delta = choices.first?["delta"] as? [String: Any] {
        #if DEBUG
        let deltaKeys = Array(delta.keys)
        let hasContent = (delta["content"] as? String).map { !$0.isEmpty } ?? false
        let toolCalls = delta["tool_calls"] as? [[String: Any]]
        let hasToolCalls = (toolCalls?.isEmpty == false)
        if hasToolCalls {
            for tc in toolCalls ?? [] {
                let fn = tc["function"] as? [String: Any]
                let name = fn?["name"] as? String
                let args = fn?["arguments"] as? String
                let argsPreview = args.map { String($0.prefix(200)) } ?? ""
                print("[MontyChat][SSE] delta keys=\(deltaKeys) hasContent=\(hasContent) toolCall name=\(name ?? "nil") argsChunk=\(argsPreview)")
            }
        } else {
            print("[MontyChat][SSE] delta keys=\(deltaKeys) hasContent=\(hasContent) toolCalls=false")
        }
        #endif
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(.delta(content))
        }
    }
    return events
}

/// Decodes a `proposedTicket` payload. Accepts the frame as long as ANY
/// meaningful field is present — the backend may emit a clarifying-only
/// proposal (no title yet) when it needs one more detail before drafting.
nonisolated func decodeProposedTicket(_ dict: [String: Any]) -> ChatProposedTicket? {
    let title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let description = (dict["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let category = dict["category"] as? String
    let priority = dict["priority"] as? String
    let issueType = (dict["issue_type"] as? String) ?? (dict["issueType"] as? String)
    let clarifying = (dict["clarifying_question"] as? String) ?? (dict["clarifyingQuestion"] as? String)

    let hasAny = [title, description, category, priority, issueType, clarifying]
        .contains { ($0?.isEmpty == false) }
    guard hasAny else { return nil }

    return ChatProposedTicket(
        title: title,
        description: description,
        category: category,
        priority: priority,
        issue_type: issueType,
        clarifying_question: clarifying
    )
}

@MainActor
enum MontyChatService {
    /// Streams Monty AI responses from the `chat-with-ai` Supabase edge function.
    static func stream(
        message: String,
        propertyId: String,
        sessionId: String?,
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

                    var body: [String: Any] = [
                        "message": message,
                        "propertyId": propertyId,
                        "contextLevel": "full",
                    ]
                    if let sessionId, !sessionId.isEmpty {
                        body["sessionId"] = sessionId
                    }
                    _ = history // we persist turns explicitly via chat_messages

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

                    // Diagnostics: track the full shape of what we received so
                    // future silent drops are easy to spot in logs.
                    var totalBytes = 0
                    var frameCount = 0
                    var deltaCount = 0
                    var sawProposal = false
                    var sawAudit = false
                    var sawDone = false

                    var buffer = SSEFrameBuffer()
                    // We accumulate single bytes into small chunks before
                    // feeding them to the buffer for efficiency.
                    var pending = Data()
                    pending.reserveCapacity(1024)

                    func drainFrames(_ frames: [String]) throws {
                        for frame in frames {
                            frameCount += 1
                            #if DEBUG
                            let preview = String(frame.prefix(200))
                            print("[MontyChat][SSE] raw frame (#\(frameCount)): \(preview)")
                            #endif
                            let events = parseSSEFrame(frame)
                            for event in events {
                                switch event {
                                case .delta: deltaCount += 1
                                case .proposedTicket: sawProposal = true
                                case .auditId: sawAudit = true
                                case .done:
                                    sawDone = true
                                    #if DEBUG
                                    print("[MontyChat][SSE] saw [DONE] — continuing to drain trailing frames")
                                    #endif
                                case .meta: break
                                }
                                continuation.yield(event)
                                // Note: we intentionally do NOT exit on .done.
                                // The backend may emit proposedTicket / auditId
                                // frames AFTER [DONE] (upstream OpenRouter
                                // forwards its [DONE] before the server flushes
                                // its post-processed meta). Keep reading until
                                // the HTTP stream actually closes.
                            }
                            try Task.checkCancellation()
                        }
                    }

                    for try await byte in bytes {
                        try Task.checkCancellation()
                        totalBytes += 1
                        pending.append(byte)
                        // Flush in modest chunks. The cheap heuristic: flush on
                        // every newline so frame boundaries land promptly.
                        if byte == 0x0A || pending.count >= 1024 {
                            let frames = buffer.append(pending)
                            pending.removeAll(keepingCapacity: true)
                            try drainFrames(frames)
                            // Keep reading past [DONE] until the HTTP body
                            // actually closes — see drainFrames note.
                        }
                    }
                    // End-of-stream flush.
                    if !pending.isEmpty {
                        let frames = buffer.append(pending)
                        try drainFrames(frames)
                    }
                    if let trailing = buffer.flush() {
                        #if DEBUG
                        print("[MontyChat][SSE] trailing un-terminated frame on stream end")
                        #endif
                        try drainFrames([trailing])
                    }

                    #if DEBUG
                    print("[MontyChat][SSE] stream end: bytes=\(totalBytes) frames=\(frameCount) deltas=\(deltaCount) proposal=\(sawProposal) audit=\(sawAudit) done=\(sawDone)")
                    #endif

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ChatFriendlyError.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
