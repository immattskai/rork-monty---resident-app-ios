import SwiftUI
import UIKit

@MainActor
@Observable
final class TicketDetailViewModel {
    var ticket: Ticket?
    var messages: [TicketMessage] = []
    var loading = true
    var error: String?
    var replyText: String = ""
    var sending = false
    var vendorActionInflight: Set<String> = []  // message ids
    var vendorPickerForMessageId: String? = nil
    /// Vendors hydrated from `tickets.ai_recommended_vendor_ids`, rendered
    /// at the top of the conversation alongside `VendorOutreachPrompt`.
    var topVendors: [RecommendedVendor] = []

    func load(id: String) async {
        loading = true; error = nil
        do {
            async let tT = MontyResidentAppService.fetchTicket(id: id)
            async let mT = MontyResidentAppService.fetchTicketMessages(ticketId: id)
            let (t, m) = try await (tT, mT)
            self.ticket = t
            self.messages = m
            attachInflightPlaceholderIfNeeded(ticketId: id)
            await hydrateVendorsFromTicketIfNeeded(ticketId: id)
            attachVendorsToLatestAIMessage(ticketId: id)
            await hydrateTopVendors(ticketId: id)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Lightweight refetch used by the polling loop. Doesn't toggle `loading`
    /// or surface errors so the UI stays calm.
    func refresh(ticketId: String) async {
        guard let fresh = try? await MontyResidentAppService.fetchTicketMessages(ticketId: ticketId) else { return }
        let existingById = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var merged: [TicketMessage] = fresh.map { incoming in
            if var prior = existingById[incoming.id] {
                // Preserve in-memory display state (vendor cards, action taken).
                prior.body = incoming.body
                prior.content = incoming.content
                prior.is_ai_response = incoming.is_ai_response
                prior.is_internal_note = incoming.is_internal_note
                prior.created_at = incoming.created_at
                prior.attachments = incoming.attachments
                return prior
            }
            return incoming
        }
        // Drop any pending placeholder if a real AI message has arrived since.
        let store = TicketAIStore.shared
        let aiInflight = store.inflight.contains(ticketId)
        let pending = messages.first(where: { $0.isPending })
        if !aiInflight {
            // No more inflight — placeholder is stale.
        } else if pending != nil {
            // Still inflight: keep the placeholder bubble visible.
            merged.append(pending!)
        }
        self.messages = merged
        attachInflightPlaceholderIfNeeded(ticketId: ticketId)
        // Re-fetch the ticket so we pick up `ai_recommended_vendor_ids`
        // populated server-side by the edge function after the resident
        // submitted the ticket.
        if let fresh = try? await MontyResidentAppService.fetchTicket(id: ticketId) {
            self.ticket = fresh
        }
        await hydrateVendorsFromTicketIfNeeded(ticketId: ticketId)
        attachVendorsToLatestAIMessage(ticketId: ticketId)
        await hydrateTopVendors(ticketId: ticketId)
    }

    /// Loads the full vendor records corresponding to
    /// `tickets.ai_recommended_vendor_ids` so the new top-of-thread vendor
    /// section can render. Falls back to the in-memory `TicketAIStore`
    /// cache when the column is empty (e.g. transient refresh races).
    func hydrateTopVendors(ticketId: String) async {
        let ids = ticket?.ai_recommended_vendor_ids ?? []
        if !ids.isEmpty {
            if let vendors = try? await MontyResidentAppService.fetchVendorsByIds(ids), !vendors.isEmpty {
                self.topVendors = vendors
                return
            }
        }
        if let cached = TicketAIStore.shared.peekVendors(for: ticketId), !cached.isEmpty {
            self.topVendors = cached
        }
    }

    /// If the edge function payload didn't include vendor objects but did
    /// persist `tickets.ai_recommended_vendor_ids`, hydrate the full vendor
    /// records from the `vendors` table so the cards still render.
    func hydrateVendorsFromTicketIfNeeded(ticketId: String) async {
        let store = TicketAIStore.shared
        if let existing = store.peekVendors(for: ticketId), !existing.isEmpty { return }
        guard let ids = ticket?.ai_recommended_vendor_ids, !ids.isEmpty else { return }
        guard let vendors = try? await MontyResidentAppService.fetchVendorsByIds(ids), !vendors.isEmpty else { return }
        store.setVendors(vendors, for: ticketId)
    }

    func attachInflightPlaceholderIfNeeded(ticketId: String) {
        let store = TicketAIStore.shared
        guard store.inflight.contains(ticketId) else {
            messages.removeAll { $0.isPending }
            return
        }
        // Only show a placeholder if no AI message has arrived AFTER the most
        // recent user message.
        let lastUserAt = messages.last(where: { $0.is_ai_response != true })?.created_at
        let lastAIAt = messages.last(where: { $0.is_ai_response == true })?.created_at
        let needsPlaceholder: Bool = {
            if lastUserAt == nil { return true }
            guard let aiAt = lastAIAt else { return true }
            return (aiAt < (lastUserAt ?? "")) // string ISO compare works for same-format timestamps
        }()
        if needsPlaceholder, !messages.contains(where: { $0.isPending }) {
            let placeholder = TicketMessage(
                id: "pending-ai-\(UUID().uuidString)",
                ticket_id: ticketId,
                sender_id: nil,
                content: "",
                is_ai_response: true,
                is_internal_note: false,
                created_at: ISO8601DateFormatter().string(from: Date()),
                isPending: true
            )
            messages.append(placeholder)
        } else if !needsPlaceholder {
            messages.removeAll { $0.isPending }
        }
    }

    func attachVendorsToLatestAIMessage(ticketId: String) {
        let store = TicketAIStore.shared
        guard let vendors = store.peekVendors(for: ticketId), !vendors.isEmpty else { return }
        // Find the most recent real AI message and (re)attach vendors. We do
        // NOT consume from the store — keeping the cache alive means the cards
        // re-appear when the user navigates away and comes back during the
        // same session, even before `tickets.ai_recommended_vendor_ids` has
        // been hydrated from the server.
        if let idx = messages.lastIndex(where: { $0.is_ai_response == true && !$0.isPending }) {
            if (messages[idx].recommendedVendors?.isEmpty ?? true) {
                messages[idx].recommendedVendors = vendors
            }
        }
    }

    func send(ticketId: String) async {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let msg = try await MontyResidentAppService.postTicketMessage(ticketId: ticketId, body: text)
            messages.append(msg)
            replyText = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func contactVendor(messageId: String, ticketId: String, vendor: RecommendedVendor) async {
        guard !vendorActionInflight.contains(messageId) else { return }
        vendorActionInflight.insert(messageId)
        defer { vendorActionInflight.remove(messageId) }
        do {
            try await MontyResidentAppService.triggerVendorOutreach(ticketId: ticketId, vendor: vendor)
            TicketAIStore.shared.markActionTaken(messageId: messageId)
            if let idx = messages.firstIndex(where: { $0.id == messageId }) {
                messages[idx].vendorActionTaken = true
            }
            // Refresh to pick up the AI confirmation message we just inserted.
            await refresh(ticketId: ticketId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func dismissVendorActions(messageId: String) {
        TicketAIStore.shared.markActionTaken(messageId: messageId)
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            messages[idx].vendorActionTaken = true
        }
    }
}

struct TicketDetailView: View {
    let ticketId: String
    @State private var vm = TicketDetailViewModel()
    @State private var pollTask: Task<Void, Never>?
    @FocusState private var replyFocused: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                if vm.loading && vm.ticket == nil {
                    VStack(spacing: 12) {
                        SkeletonRow(height: 120)
                        SkeletonRow(height: 80)
                        SkeletonRow(height: 80)
                    }
                    .padding(.horizontal, Theme.Space.lg)
                } else if let err = vm.error, vm.ticket == nil {
                    ErrorState(message: err) { Task { await vm.load(id: ticketId) } }
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                                if let t = vm.ticket {
                                    header(t)
                                }
                                if let aiErr = TicketAIStore.shared.error(for: ticketId) {
                                    aiErrorBanner(aiErr)
                                }
                                if !vm.topVendors.isEmpty {
                                    topVendorSection
                                }
                                messageThread
                            }
                            .padding(.horizontal, Theme.Space.lg)
                            .padding(.top, Theme.Space.md)
                            .padding(.bottom, Theme.Space.lg)
                        }
                        .refreshable { await vm.load(id: ticketId) }

                        if canReply {
                            replyComposer
                        } else {
                            readOnlyFooter
                        }
                    }
                }
            }
        }
        .navigationTitle("Ticket")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(id: ticketId) }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .sheet(item: Binding(
            get: { vm.vendorPickerForMessageId.map { VendorPickerContext(messageId: $0) } },
            set: { vm.vendorPickerForMessageId = $0?.messageId }
        )) { ctx in
            VendorPickerSheet(
                organizationId: vm.ticket?.organization_id,
                onSelect: { vendor in
                    vm.vendorPickerForMessageId = nil
                    Task {
                        await vm.contactVendor(
                            messageId: ctx.messageId,
                            ticketId: ticketId,
                            vendor: vendor
                        )
                    }
                }
            )
        }
    }

    private func startPolling() {
        stopPolling()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await vm.refresh(ticketId: ticketId)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private var canReply: Bool {
        let s = (vm.ticket?.status ?? "").lowercased()
        return vm.ticket != nil && s != "closed"
    }

    private func header(_ t: Ticket) -> some View {
        let tone = TicketStatus.tone(for: t.status)
        let isUrgent = (t.ai_urgency_score ?? 0) >= 8
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusPill.ticketStatus(t.status)
                if (t.ticket_type ?? "").lowercased() == "management" {
                    StatusPill(text: "Building", tone: .info)
                }
                if t.is_ai_handled == true {
                    StatusPill(text: "AI", tone: .neutral)
                }
                if isUrgent {
                    Circle()
                        .fill(Theme.danger)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Urgent")
                }
                Spacer()
                Text(Fmt.short(Fmt.parseDate(t.created_at)))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            Text(t.title ?? "Maintenance request")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let d = t.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tone.color)
                .frame(width: 3)
                .clipShape(.rect(cornerRadius: 1.5))
                .padding(.vertical, 14)
                .padding(.leading, 0)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .clipShape(.rect(cornerRadius: 16))
    }

    private func aiErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text("Monty couldn’t reply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
                Button("Dismiss") {
                    TicketAIStore.shared.clearError(for: ticketId)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.danger.opacity(0.3), lineWidth: 0.5)
        )
    }

    private var messageThread: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionHeader(title: "Messages").padding(.horizontal, 0)
            // Backend pre-seeds the resident description + AI ack into
            // ticket_messages, so the empty state is intentionally omitted.
            ForEach(vm.messages) { m in
                messageBubble(m)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: vm.messages.map(\.id))
    }

    /// Recommended vendors block + Monty-on-your-behalf outreach prompt,
    /// rendered at the top of the conversation. Gated on
    /// `tickets.ai_recommended_vendor_ids.length > 0`. The outreach prompt
    /// auto-hides itself once `vendor_outreach_status` is `sent` /
    /// `declined` (server-driven).
    private var topVendorSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            SectionHeader(title: "Recommended vendors").padding(.horizontal, 0)
            VStack(spacing: 10) {
                ForEach(vm.topVendors) { v in
                    VendorCard(vendor: v)
                }
            }
            if let primary = vm.topVendors.first {
                VendorOutreachPrompt(ticketId: ticketId, vendor: primary)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ m: TicketMessage) -> some View {
        let myId = SupabaseAPI.shared.session?.user_id
        let isMine = m.sender_id != nil && m.sender_id == myId
        let isAI = m.is_ai_response ?? false
        let isStaff = !isMine
        let label = isMine ? "You" : (isAI ? "Monty AI" : "Building")
        HStack(alignment: .top, spacing: 10) {
            if isStaff {
                Avatar(name: label, size: 32)
            } else {
                Spacer(minLength: 36)
            }
            VStack(alignment: isStaff ? .leading : .trailing, spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                if m.isPending {
                    pendingBubble
                } else {
                    Text(m.displayBody)
                        .font(.system(size: 15))
                        .foregroundStyle(isMine ? ChatPalette.userText : Theme.textPrimary)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isMine ? ChatPalette.userBubble : Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isMine ? .clear : Theme.border, lineWidth: 0.5)
                        )
                }
                if let vendors = m.recommendedVendors, !vendors.isEmpty {
                    vendorCards(messageId: m.id, vendors: vendors)
                }
                if !m.isPending {
                    Text(Fmt.relative(Fmt.parseDate(m.created_at)))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: isStaff ? .leading : .trailing)
            if !isStaff {
                Avatar(name: label, size: 32)
            } else {
                Spacer(minLength: 36)
            }
        }
    }

    private var pendingBubble: some View {
        HStack(spacing: 8) {
            Text("Monty is thinking")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            ThinkingDots()
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

    @ViewBuilder
    private func vendorCards(messageId: String, vendors: [RecommendedVendor]) -> some View {
        let actionTaken = vm.messages.first(where: { $0.id == messageId })?.vendorActionTaken == true
            || TicketAIStore.shared.hasActionBeenTaken(messageId: messageId)
        let inflight = vm.vendorActionInflight.contains(messageId)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(vendors) { v in
                VendorCard(vendor: v)
            }
            if !actionTaken, let primary = vendors.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Need us to reach out?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("We can share your contact information with one of these service providers so they can reach out to you directly about your request.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                vendorActionRow(messageId: messageId, primary: primary, inflight: inflight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func vendorActionRow(messageId: String, primary: RecommendedVendor, inflight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    await vm.contactVendor(messageId: messageId, ticketId: ticketId, vendor: primary)
                }
            } label: {
                HStack(spacing: 8) {
                    if inflight {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(inflight ? "Reaching out…" : "Yes, contact \(primary.name)")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accent)
                )
            }
            .buttonStyle(.plain)
            .disabled(inflight)

            HStack(spacing: 8) {
                Button {
                    vm.vendorPickerForMessageId = messageId
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Choose different vendor")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
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

                Button {
                    vm.dismissVendorActions(messageId: messageId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                        Text("No thanks")
                            .font(.system(size: 13, weight: .medium))
                    }
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
        }
        .padding(.top, 4)
    }

    private var replyComposer: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.border)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write a reply…", text: $vm.replyText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )

                Button {
                    Task { await vm.send(ticketId: ticketId) }
                } label: {
                    ZStack {
                        Circle().fill(canSend ? Theme.accent : Theme.divider)
                        if vm.sending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(canSend ? .white : Theme.textMuted)
                        }
                    }
                    .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || vm.sending)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface)
        }
    }

    private var canSend: Bool {
        !vm.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var readOnlyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 12))
            Text("This ticket is closed.")
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.surface)
    }
}

// MARK: - Pieces

private struct VendorPickerContext: Identifiable {
    let messageId: String
    var id: String { messageId }
}

private struct ThinkingDots: View {
    @State private var phase: Int = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: false)) { ctx in
            let bucket = Int(ctx.date.timeIntervalSinceReferenceDate * 5) % 3
            HStack(spacing: 4) {
                dot(active: bucket == 0)
                dot(active: bucket == 1)
                dot(active: bucket == 2)
            }
            .onAppear { phase = bucket }
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

private struct VendorCard: View {
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

// MARK: - Vendor picker sheet

private struct VendorPickerSheet: View {
    let organizationId: String?
    let onSelect: (RecommendedVendor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var vendors: [VendorDirectoryEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var search: String = ""

    var filtered: [VendorDirectoryEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vendors }
        return vendors.filter {
            ($0.name ?? "").lowercased().contains(q)
                || ($0.category ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                Group {
                    if loading {
                        ProgressView().tint(Theme.accent)
                    } else if let err = error {
                        ErrorState(message: err) { Task { await load() } }
                    } else if vendors.isEmpty {
                        EmptyState(
                            icon: "person.2",
                            title: "No vendors yet",
                            message: "Your building hasn't published a vendor list."
                        )
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(filtered) { v in
                                    Button {
                                        onSelect(v.asRecommended)
                                    } label: {
                                        VendorCard(vendor: v.asRecommended)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, Theme.Space.lg)
                            .padding(.vertical, Theme.Space.md)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search vendors")
            .navigationTitle("Choose a vendor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        guard let org = organizationId, !org.isEmpty else {
            self.error = "No organization linked to this ticket."
            return
        }
        do {
            self.vendors = try await MontyResidentAppService.fetchVendorsForResidents(organizationId: org)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
