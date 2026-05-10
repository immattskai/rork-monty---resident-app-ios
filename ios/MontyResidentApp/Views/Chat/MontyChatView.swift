import SwiftUI
import UIKit

@MainActor
@Observable
final class MontyChatViewModel {
    var messages: [ChatMessage] = []
    var input: String = ""
    var isSending: Bool = false

    /// Server-side chat session id. Created lazily on the first send so the
    /// model can thread context across turns. Best-effort — we keep working
    /// without it if the table doesn't exist on this install.
    private var sessionId: String?
    private var sessionInflight: Task<String?, Never>?

    private var streamTask: Task<Void, Never>?
    private var ticketCreationTasks: [UUID: Task<Void, Never>] = [:]
    private var verifyTasks: [UUID: Task<Void, Never>] = [:]

    func send(propertyId: String, unitId: String?, text: String? = nil) {
        let raw = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !isSending else { return }
        input = ""
        let userMsg = ChatMessage(role: .user, content: raw)
        messages.append(userMsg)
        beginAssistantStream(propertyId: propertyId, unitId: unitId, sourceText: raw)
    }

    /// Re-runs the last user message after an in-bubble error.
    func retry(messageId: UUID, propertyId: String, unitId: String?) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let raw = messages[idx].sourceUserText ?? ""
        guard !raw.isEmpty else { return }
        messages.remove(at: idx)
        beginAssistantStream(propertyId: propertyId, unitId: unitId, sourceText: raw)
    }

    private func ensureSession(propertyId: String) async -> String? {
        if let s = sessionId { return s }
        if let t = sessionInflight { return await t.value }
        let task = Task { @MainActor [propertyId] in
            await MontyResidentAppService.createChatSession(propertyId: propertyId)
        }
        sessionInflight = task
        let s = await task.value
        sessionInflight = nil
        if let s { sessionId = s }
        return s
    }

    private func beginAssistantStream(propertyId: String, unitId: String?, sourceText: String) {
        let assistantId = UUID()
        messages.append(ChatMessage(
            id: assistantId,
            role: .assistant,
            content: "",
            isStreaming: true,
            sourceUserText: sourceText
        ))
        isSending = true

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            let session = await self.ensureSession(propertyId: propertyId)
            // Persist the user turn as soon as we have a session.
            if let session {
                Task { @MainActor in
                    await MontyResidentAppService.insertChatMessage(
                        sessionId: session,
                        role: "user",
                        content: sourceText,
                        auditId: nil,
                        proposedTicket: nil,
                        proposalStatus: nil
                    )
                }
            }

            var wasCancelled = false
            do {
                for try await event in MontyChatService.stream(
                    message: sourceText,
                    propertyId: propertyId,
                    sessionId: session,
                    history: self.messages
                ) {
                    switch event {
                    case .delta(let chunk):
                        self.appendDelta(chunk, to: assistantId)
                    case .auditId(let id):
                        self.update(assistantId) { $0.auditId = id }
                    case .proposedTicket(let pt):
                        self.mergeProposal(pt, into: assistantId)
                    case .meta, .done:
                        break
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                let friendly = ChatFriendlyError.map(error)
                self.update(assistantId) { $0.errorText = friendly.residentMessage }
            }

            // Final pass: sanitize text, extract any legacy inline action
            // blocks, and apply the proposal-only / empty-stream fallbacks.
            // Critically, the assistant bubble is NEVER removed — silent
            // failures used to vanish; now they always show a friendly
            // recovery message.
            self.finalizeAssistantBubble(assistantId, wasCancelled: wasCancelled)

            // Persist the assistant turn.
            if let session,
               let msg = self.messages.first(where: { $0.id == assistantId }) {
                let status: String? = msg.proposedTicket == nil ? nil : "pending"
                Task { @MainActor [content = msg.content, audit = msg.auditId, proposal = msg.proposedTicket] in
                    await MontyResidentAppService.insertChatMessage(
                        sessionId: session,
                        role: "assistant",
                        content: content,
                        auditId: audit,
                        proposedTicket: proposal,
                        proposalStatus: status
                    )
                }
            }

            self.isSending = false
        }
    }

    /// Final cleanup pass on a finished assistant bubble. Sanitizes the
    /// streamed text, promotes any legacy inline `create_ticket` JSON to a
    /// proper proposal, and fills in fallback copy so the user never sees
    /// just a dead "thinking" indicator.
    private func finalizeAssistantBubble(_ id: UUID, wasCancelled: Bool) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var msg = messages[idx]
        msg.isStreaming = false

        // 1) Strip inline action JSON / fences and promote a legacy
        //    create_ticket action to a proposal if no meta proposal arrived.
        if !msg.content.isEmpty {
            let extracted = ChatActionExtractor.extract(from: msg.content)
            if extracted.cleaned != msg.content {
                msg.content = extracted.cleaned
            }
            if msg.proposedTicket == nil {
                if let action = extracted.actions.first(where: { $0.name == "create_ticket" }) {
                    msg.proposedTicket = ChatProposedTicket(
                        title: action.payload["title"] as? String,
                        description: action.payload["description"] as? String,
                        category: action.payload["category"] as? String,
                        priority: action.payload["priority"] as? String,
                        issue_type: (action.payload["issue_type"] as? String)
                            ?? (action.payload["issueType"] as? String),
                        clarifying_question: nil
                    )
                }
            }
        }

        // 2) Sanitize premature "ticket opened" phrasing — the user hasn't
        //    confirmed anything yet, so claims like "I have opened a ticket"
        //    are misleading and contradict the Yes / Not now card.
        if !msg.content.isEmpty {
            msg.content = Self.sanitizePrematureClaims(msg.content)
        }

        // 3) Proposal-only / clarifying-question fallback text.
        if msg.content.isEmpty, let proposal = msg.proposedTicket {
            if let q = proposal.clarifying_question, !q.isEmpty {
                msg.content = q
            } else if proposal.hasDraftTicket {
                msg.content = "I've drafted a ticket for you — confirm below to send it to the building team."
            }
        }

        // 4) If we end up with no renderable content (no text, no proposal,
        //    no server error), surface a real error state — NOT an invented
        //    assistant turn. The client is not allowed to fabricate copy.
        //    The bubble stays so the user has a Retry action.
        if msg.content.isEmpty
            && msg.proposedTicket == nil
            && msg.errorText == nil {
            #if DEBUG
            print("[MontyChat] Empty assistant bubble id=\(id) cancelled=\(wasCancelled) — surfacing error state")
            #endif
            msg.errorText = "Couldn't reach Monty — tap to retry."
        }

        messages[idx] = msg
    }

    /// Strips claims that we've already opened a ticket. The proposal flow
    /// requires explicit user confirmation, so streamed "I've opened a
    /// ticket" / "our team will follow up" style copy is misleading.
    private static func sanitizePrematureClaims(_ text: String) -> String {
        let patterns: [String] = [
            #"(?i)i(?:'|’)?ve\s+opened\s+a\s+ticket[^.!?\n]*[.!?]?"#,
            #"(?i)i\s+have\s+opened\s+a\s+ticket[^.!?\n]*[.!?]?"#,
            #"(?i)i(?:'|’)?ve\s+(?:created|submitted|filed|logged)\s+(?:a\s+)?(?:maintenance\s+)?(?:ticket|request)[^.!?\n]*[.!?]?"#,
            #"(?i)i\s+(?:created|submitted|filed|logged)\s+(?:a\s+)?(?:maintenance\s+)?(?:ticket|request)[^.!?\n]*[.!?]?"#,
            #"(?i)(?:our|the)\s+team\s+will\s+follow\s+up[^.!?\n]*[.!?]?"#,
            #"(?i)the\s+building\s+team\s+will\s+follow\s+up[^.!?\n]*[.!?]?"#,
        ]
        var out = text
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p) {
                let ns = out as NSString
                out = rx.stringByReplacingMatches(
                    in: out,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: ""
                )
            }
        }
        if let rx = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            let ns = out as NSString
            out = rx.stringByReplacingMatches(
                in: out,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: "\n\n"
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merges incremental proposal frames so a clarifying question that lands
    /// before a draft (or vice-versa) doesn't overwrite earlier fields.
    private func mergeProposal(_ incoming: ChatProposedTicket, into id: UUID) {
        update(id) { msg in
            if var existing = msg.proposedTicket {
                if incoming.title?.isEmpty == false { existing.title = incoming.title }
                if incoming.description?.isEmpty == false { existing.description = incoming.description }
                if incoming.category?.isEmpty == false { existing.category = incoming.category }
                if incoming.priority?.isEmpty == false { existing.priority = incoming.priority }
                if incoming.issue_type?.isEmpty == false { existing.issue_type = incoming.issue_type }
                if incoming.clarifying_question?.isEmpty == false {
                    existing.clarifying_question = incoming.clarifying_question
                }
                msg.proposedTicket = existing
            } else {
                msg.proposedTicket = incoming
            }
        }
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
    }

    // MARK: - Proposal handling

    func confirmProposal(messageId: UUID, propertyId: String, unitId _: String?) {
        guard let residentId = MontyResidentAppService.currentUserId() else {
            update(messageId) { $0.errorText = ChatFriendlyError.auth.residentMessage }
            return
        }
        guard let proposal = messages.first(where: { $0.id == messageId })?.proposedTicket,
              proposal.hasDraftTicket,
              let title = proposal.title, !title.isEmpty else { return }
        let description = proposal.description ?? ""
        // Mark as in-flight (keeps the proposal card visible with a spinner).
        update(messageId) { $0.isCreatingTicket = true; $0.errorText = nil }

        ticketCreationTasks[messageId]?.cancel()
        ticketCreationTasks[messageId] = Task { [weak self] in
            guard let self else { return }
            defer { self.ticketCreationTasks[messageId] = nil }
            do {
                let result = try await MontyResidentAppService.createTicketFromChat(
                    title: title,
                    description: description,
                    category: proposal.category,
                    priority: proposal.priority,
                    issueType: proposal.issue_type,
                    propertyId: propertyId,
                    residentId: residentId
                )
                self.update(messageId) { msg in
                    msg.isCreatingTicket = false
                    msg.proposedTicket = nil
                    msg.createdTicket = ChatTicket(
                        id: result.ticket.id,
                        title: result.ticket.title ?? title,
                        status: result.ticket.status,
                        priority: result.ticket.priority
                    )
                    // Don't show vendor cards for inappropriate triage.
                    let intent = (result.triageIntent ?? "").lowercased()
                    if intent != "inappropriate" {
                        msg.recommendedVendors = result.recommendedVendors
                    }
                }
            } catch {
                let friendly = ChatFriendlyError.map(error)
                self.update(messageId) { msg in
                    msg.isCreatingTicket = false
                    msg.errorText = friendly.residentMessage
                }
            }
        }
    }

    func declineProposal(messageId: UUID) {
        update(messageId) { msg in
            msg.proposalDeclined = true
            msg.proposedTicket = nil
        }
    }

    // MARK: - Verify / Escalate (AI Trust Layer)

    func verify(messageId: UUID) {
        guard let auditId = messages.first(where: { $0.id == messageId })?.auditId else { return }
        update(messageId) { $0.verifyState = .verifying }
        verifyTasks[messageId]?.cancel()
        verifyTasks[messageId] = Task { [weak self] in
            guard let self else { return }
            defer { self.verifyTasks[messageId] = nil }
            do {
                _ = try await MontyResidentAppService.verifyAIResponse(auditId: auditId)
                self.update(messageId) { $0.verifyState = .verified }
            } catch {
                self.update(messageId) { $0.verifyState = .failed }
            }
        }
    }

    func escalate(messageId: UUID, reason: String? = nil) {
        guard let auditId = messages.first(where: { $0.id == messageId })?.auditId else { return }
        update(messageId) { $0.verifyState = .escalating }
        verifyTasks[messageId]?.cancel()
        verifyTasks[messageId] = Task { [weak self] in
            guard let self else { return }
            defer { self.verifyTasks[messageId] = nil }
            do {
                _ = try await MontyResidentAppService.escalateAIResponse(auditId: auditId, reason: reason)
                self.update(messageId) { $0.verifyState = .escalated }
            } catch {
                self.update(messageId) { $0.verifyState = .failed }
            }
        }
    }

    // MARK: - Helpers

    private func appendDelta(_ chunk: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += chunk
    }

    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[idx])
    }
}

// MARK: - Brand-safe chat colors
//
// Independent of the property's `--primary` so user bubbles never disappear
// on a dark white-label theme. Always white text on the user bubble.
enum ChatPalette {
    static let userBubble = Color.dynamic(light: 0x2563EB, dark: 0x3B82F6)
    static let userText = Color.white
}

struct MontyChatView: View {
    @Environment(AppState.self) private var app
    @State private var vm = MontyChatViewModel()
    @FocusState private var inputFocused: Bool

    var initialInput: String = ""
    @State private var didConsumeInitial = false

    private let suggestions = [
        "What are the quiet hours?",
        "How do I book an amenity?",
        "Pet policies?",
        "I have a maintenance issue",
    ]

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if vm.messages.isEmpty {
                                emptyState
                                    .padding(.top, 24)
                            }
                            ForEach(vm.messages) { msg in
                                MessageBubble(
                                    message: msg,
                                    onOpenTicket: { id in app.pendingTicketDetailId = id },
                                    onConfirmProposal: { confirmProposal(messageId: msg.id) },
                                    onDeclineProposal: { vm.declineProposal(messageId: msg.id) },
                                    onVerify: { vm.verify(messageId: msg.id) },
                                    onEscalate: { vm.escalate(messageId: msg.id) },
                                    onRetry: { retry(messageId: msg.id) }
                                )
                                .id(msg.id)
                            }
                            Color.clear.frame(height: 12).id("bottom")
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: vm.messages.last?.content) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }

                disclaimer
                composer
            }
        }
        .navigationTitle("Ask Monty AI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didConsumeInitial else { return }
            didConsumeInitial = true
            let trimmed = initialInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    send(trimmed)
                }
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(280))
                    inputFocused = true
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFF8A3D), Color(hex: 0xF26A1F)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                .shadow(color: Color(hex: 0xF26A1F).opacity(0.25), radius: 10, y: 4)

                Text("Hi, I'm Monty.")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                Text("Ask me about building policies, amenities, packages, or report a maintenance issue.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        send(s)
                    } label: {
                        HStack {
                            Text(s)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var disclaimer: some View {
        Text("AI can make mistakes. Always verify important information.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom) {
                TextField("Ask Monty AI…", text: Bindable(vm).input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            )

            Button {
                if vm.isSending { vm.cancel() } else { send() }
            } label: {
                ZStack {
                    Circle().fill(canSend || vm.isSending ? Theme.accent : Theme.divider)
                    Image(systemName: vm.isSending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend || vm.isSending ? .white : Theme.textMuted)
                }
                .frame(width: 40, height: 40)
            }
            .disabled(!canSend && !vm.isSending)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 4)
        .background(Theme.background)
    }

    private var canSend: Bool {
        !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String? = nil) {
        guard let propertyId = app.activePropertyId else {
            return
        }
        vm.send(propertyId: propertyId, unitId: app.activeUnitId, text: text)
        inputFocused = false
    }

    private func confirmProposal(messageId: UUID) {
        guard let propertyId = app.activePropertyId else { return }
        vm.confirmProposal(messageId: messageId, propertyId: propertyId, unitId: app.activeUnitId)
    }

    private func retry(messageId: UUID) {
        guard let propertyId = app.activePropertyId else { return }
        vm.retry(messageId: messageId, propertyId: propertyId, unitId: app.activeUnitId)
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let onOpenTicket: (String) -> Void
    let onConfirmProposal: () -> Void
    let onDeclineProposal: () -> Void
    let onVerify: () -> Void
    let onEscalate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundStyle(ChatPalette.userText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(ChatPalette.userBubble)
                    )
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0xFF8A3D), Color(hex: 0xF26A1F)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 8) {
                        if message.content.isEmpty
                            && message.isStreaming
                            && message.proposedTicket == nil
                            && message.errorText == nil {
                            thinkingBubble
                        } else if !message.content.isEmpty {
                            Text(renderedText)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                            if message.isStreaming {
                                Text("●")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Theme.textMuted)
                                    .opacity(0.6)
                            }
                        }

                        if let proposal = message.proposedTicket,
                           !message.proposalDeclined,
                           proposal.hasDraftTicket {
                            TicketProposalCard(
                                proposal: proposal,
                                isCreating: message.isCreatingTicket,
                                onConfirm: onConfirmProposal,
                                onDecline: onDeclineProposal
                            )
                            .padding(.top, 2)
                        }

                        if let t = message.createdTicket, let tid = t.id {
                            TicketCreatedCard(ticket: t, onTap: { onOpenTicket(tid) })
                                .padding(.top, 2)
                        }

                        if let vendors = message.recommendedVendors, !vendors.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(vendors) { v in
                                    ChatVendorCard(vendor: v)
                                }
                                if let tid = message.createdTicket?.id, let primary = vendors.first {
                                    VendorOutreachPrompt(ticketId: tid, vendor: primary)
                                }
                            }
                            .padding(.top, 2)
                        } else if message.createdTicket != nil {
                            // Empty vendor state — surfaced both here and on the
                            // ticket detail page for parity.
                            Text("No matching vendors are set up for this building yet — your team will follow up directly.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .padding(.top, 2)
                        }

                        if let err = message.errorText {
                            ChatErrorBubble(message: err, onRetry: message.sourceUserText == nil ? nil : onRetry)
                                .padding(.top, 2)
                        }

                        if message.auditId != nil
                            && message.errorText == nil
                            && !message.isStreaming
                            && !message.content.isEmpty {
                            AITrustBadge(state: message.verifyState, onVerify: onVerify, onEscalate: onEscalate)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var thinkingBubble: some View {
        HStack(spacing: 8) {
            Text("Monty is thinking")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            ChatThinkingDots()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var renderedText: AttributedString {
        if let attr = try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(message.content)
    }
}

// MARK: - Pieces

private struct ChatThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: false)) { ctx in
            let bucket = Int(ctx.date.timeIntervalSinceReferenceDate * 5) % 3
            HStack(spacing: 4) {
                dot(active: bucket == 0)
                dot(active: bucket == 1)
                dot(active: bucket == 2)
            }
        }
        .frame(width: 26, height: 8, alignment: .leading)
    }

    private func dot(active: Bool) -> some View {
        Circle()
            .fill(active ? Theme.textPrimary : Theme.textMuted.opacity(0.5))
            .frame(width: 6, height: 6)
            .scaleEffect(active ? 1.15 : 0.9)
            .animation(.easeInOut(duration: 0.18), value: active)
    }
}

// MARK: - Ticket proposal card ("Open a ticket?")

private struct TicketProposalCard: View {
    let proposal: ChatProposedTicket
    let isCreating: Bool
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "ticket")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Open a ticket?")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.3)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(proposal.title ?? "Maintenance request")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let desc = proposal.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if let cat = proposal.category, !cat.isEmpty {
                    badge(cat.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                if let pri = proposal.priority, !pri.isEmpty {
                    badge(pri.capitalized, tone: priorityTone(pri))
                }
            }
            HStack(spacing: 8) {
                Button(action: onConfirm) {
                    HStack(spacing: 6) {
                        if isCreating {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text(isCreating ? "Opening…" : "Yes, open ticket")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: 0xF26A1F))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isCreating)

                Button(action: onDecline) {
                    Text("Not now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private func badge(_ text: String, tone: Color = Theme.textSecondary) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(tone.opacity(0.12))
            )
    }

    private func priorityTone(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "urgent": return Theme.danger
        case "high": return Theme.warning
        case "low": return Theme.textMuted
        default: return Theme.info
        }
    }
}

// MARK: - "Ticket created" card

private struct TicketCreatedCard: View {
    let ticket: ChatTicket
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.background)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ticket opened")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.textSecondary)
                    Text(ticket.title ?? "Maintenance request")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vendor outreach prompt

struct VendorOutreachPrompt: View {
    let ticketId: String
    let vendor: RecommendedVendor

    @State private var status: VendorOutreachState?
    @State private var inflight: Bool = false
    @State private var localResolved: Bool = false
    @State private var errorText: String?

    private var isResolved: Bool {
        localResolved || (status?.isResolved ?? false)
    }

    var body: some View {
        Group {
            if isResolved {
                resolvedRow
            } else {
                actionsRow
            }
        }
        .task { await refresh() }
    }

    private var resolvedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "envelope.badge.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Text(resolvedLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 4)
    }

    private var resolvedLabel: String {
        let s = (status?.vendor_outreach_status ?? "").lowercased()
        if s == "sent" { return "Email sent to \(vendor.name)." }
        if s == "declined" { return "You declined to contact \(vendor.name)." }
        return "Done."
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Have Monty email \(vendor.name)?")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("We'll share your request and contact details on your behalf.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await contact() }
                } label: {
                    HStack(spacing: 6) {
                        if inflight {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(inflight ? "Sending…" : "Yes, email them")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: 0xF26A1F))
                    )
                }
                .buttonStyle(.plain)
                .disabled(inflight)

                Button {
                    localResolved = true
                } label: {
                    Text("No thanks")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.border, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(inflight)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.top, 4)
    }

    private func contact() async {
        guard !inflight else { return }
        inflight = true
        errorText = nil
        defer { inflight = false }
        do {
            _ = try await MontyResidentAppService.contactVendorForTicket(
                ticketId: ticketId,
                vendorId: vendor.vendorId
            )
            localResolved = true
            await refresh()
        } catch {
            errorText = ChatFriendlyError.map(error).residentMessage
        }
    }

    private func refresh() async {
        if let s = try? await MontyResidentAppService.fetchVendorOutreachState(ticketId: ticketId) {
            status = s
        }
    }
}

// MARK: - AI Trust Badge (Verify / Escalate)

private struct AITrustBadge: View {
    let state: ChatMessage.AIVerifyState
    let onVerify: () -> Void
    let onEscalate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("AI answer", systemImage: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            switch state {
            case .verified:
                badge("Verified", icon: "checkmark.seal.fill", color: Theme.success)
            case .escalated:
                badge("Escalated", icon: "person.fill.questionmark", color: Theme.info)
            case .verifying, .escalating:
                ProgressView().controlSize(.mini).tint(Theme.textSecondary)
            case .idle, .failed:
                Button(action: onVerify) {
                    badge("Verify", icon: "checkmark", color: Theme.textSecondary, filled: false)
                }
                .buttonStyle(.plain)
                Button(action: onEscalate) {
                    badge("Escalate", icon: "person.fill.questionmark", color: Theme.textSecondary, filled: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func badge(_ label: String, icon: String, color: Color, filled: Bool = true) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(filled ? color : Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(filled ? color.opacity(0.14) : Theme.surface)
        )
        .overlay(
            Capsule().stroke(filled ? Color.clear : Theme.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Friendly error bubble

private struct ChatErrorBubble: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                if let onRetry {
                    Button(action: onRetry) {
                        Text("Retry")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.danger.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Vendor card (chat)

private struct ChatVendorCard: View {
    let vendor: RecommendedVendor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(vendor.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let cat = vendor.category, !cat.isEmpty {
                    Text(cat)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            if let contact = vendor.contactName, !contact.isEmpty {
                row(icon: "person", text: contact)
            }
            if let phone = vendor.phone, !phone.isEmpty {
                Button {
                    open(scheme: "tel:", value: phone)
                } label: {
                    row(icon: "phone", text: phone, link: true)
                }
                .buttonStyle(.plain)
            }
            if let email = vendor.email, !email.isEmpty {
                Button {
                    open(scheme: "mailto:", value: email)
                } label: {
                    row(icon: "envelope", text: email, link: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private func row(icon: String, text: String, link: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(link ? Theme.info : Theme.textSecondary)
                .underline(link, color: Theme.info.opacity(0.4))
        }
    }

    private func open(scheme: String, value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.urlQueryAllowed
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? cleaned
        guard let url = URL(string: scheme + encoded) else { return }
        UIApplication.shared.open(url)
    }
}
