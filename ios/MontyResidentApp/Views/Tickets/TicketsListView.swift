import SwiftUI
import UIKit

@MainActor
@Observable
final class TicketsListViewModel {
    var tickets: [Ticket] = []
    var loading = true
    var error: String?
    var filter: TicketFilter = .active

    func load(propertyId: String?) async {
        loading = true; error = nil
        do {
            tickets = try await MontyResidentAppService.fetchTickets(propertyId: propertyId)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    var filtered: [Ticket] {
        let allowed = filter.statuses
        return tickets.filter { allowed.contains(($0.status ?? "").lowercased()) }
    }

    func count(for f: TicketFilter) -> Int {
        let allowed = f.statuses
        return tickets.filter { allowed.contains(($0.status ?? "").lowercased()) }.count
    }
}

enum TicketFilter: String, CaseIterable, Hashable {
    case active, completed

    var label: String {
        switch self {
        case .active: return "Active"
        case .completed: return "Completed"
        }
    }

    var statuses: Set<String> {
        switch self {
        case .active: return ["open", "in_progress", "waiting_on_resident"]
        case .completed: return ["resolved", "closed"]
        }
    }
}

struct TicketsListView: View {
    @Environment(AppState.self) private var app
    @State private var vm = TicketsListViewModel()
    @State private var showNewTicket = false

    private let horizontalPadding: CGFloat = 16

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in
            TicketDetailView(ticketId: id)
        }
        .sheet(isPresented: $showNewTicket) {
            NewTicketView { _ in
                Task { await reload() }
            }
        }
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.tickets.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    filterBar.padding(.bottom, 4)
                    ForEach(0..<6, id: \.self) { _ in
                        skeletonRow
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error {
            ErrorState(message: err) { Task { await reload() } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    filterBar.padding(.bottom, 4)

                    if vm.filtered.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.filtered) { t in
                            NavigationLink(value: t.id) { row(t) }
                                .buttonStyle(PressableCardStyle())
                                .simultaneousGesture(TapGesture().onEnded {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                })
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                backButton
                Spacer()
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tickets")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Requests for your home and building")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                Spacer(minLength: 12)
                newTicketButton
                    .padding(.bottom, 2)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var backButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Theme.premiumCard)
                )
                .overlay(
                    Circle().stroke(Color.chrome(0.08), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }

    private var newTicketButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showNewTicket = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("New")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                Capsule().stroke(Color.chrome(0.18), lineWidth: 0.6)
            )
            .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(TicketFilter.allCases, id: \.self) { f in
                filterPill(f)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterPill(_ f: TicketFilter) -> some View {
        let isActive = vm.filter == f
        let count = vm.count(for: f)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                vm.filter = f
            }
        } label: {
            HStack(spacing: 7) {
                Text(f.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? .white : Color.chrome(0.62))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(isActive ? .white : Color.chrome(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                isActive
                                    ? Color.chrome(0.22)
                                    : Color.chrome(0.08)
                            )
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isActive {
                        Capsule().fill(Color.chrome(0.10))
                    } else {
                        Capsule().fill(Theme.premiumCard)
                    }
                }
            )
            .overlay(
                Capsule().stroke(
                    isActive ? Color.chrome(0.16) : Color.chrome(0.08),
                    lineWidth: 0.6
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "tray")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("No \(vm.filter.label.lowercased()) tickets")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Submit a request and your building team will get back to you here.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showNewTicket = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("New ticket")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    )
                    .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 20)
    }

    private func reload() async {
        await vm.load(propertyId: app.activeUnit?.property_id)
    }

    // MARK: - Row

    private func row(_ t: Ticket) -> some View {
        let style = TicketRowStyle.style(for: t.status)
        let isUrgent = (t.ai_urgency_score ?? 0) >= 8
        let title = t.title ?? "Maintenance request"
        let subtitle = t.description ?? ""

        return ZStack {
            premiumCardBackground(radius: 16)

            HStack(alignment: .top, spacing: 12) {
                // Status icon tile
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style.tint.opacity(0.12))
                    Image(systemName: style.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(style.tint)
                }
                .frame(width: 42, height: 42)
                .padding(.top, 1)

                // Middle content
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        statusBadge(style)
                        if (t.ticket_type ?? "").lowercased() == "management" {
                            metaBadge(text: "Building", color: Color(hex: 0x6FA8DC))
                        }
                        if t.is_ai_handled == true {
                            metaBadge(text: "AI", color: Color(hex: 0xFF9A2F))
                        }
                        if isUrgent {
                            Circle()
                                .fill(Theme.danger)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel("Urgent")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right column
                VStack(alignment: .trailing, spacing: 10) {
                    Text(Fmt.relative(Fmt.parseDate(t.updated_at ?? t.created_at)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.chrome(0.45))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.chrome(0.32))
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    private func statusBadge(_ style: TicketRowStyle) -> some View {
        Text(style.label.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.9)
            .foregroundStyle(style.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(style.tint.opacity(0.14)))
    }

    private func metaBadge(text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.9)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.chrome(0.05))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.chrome(0.08))
                        .frame(height: 12)
                        .frame(maxWidth: 180, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.chrome(0.05))
                        .frame(height: 10)
                        .frame(maxWidth: 240, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 86)
    }

    // MARK: - Card background

    @ViewBuilder
    private func premiumCardBackground(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }
}

// MARK: - Row style mapping

private struct TicketRowStyle {
    let icon: String
    let tint: Color
    let label: String

    static func style(for status: String?) -> TicketRowStyle {
        switch (status ?? "").lowercased() {
        case "open", "new":
            return TicketRowStyle(icon: "wrench.and.screwdriver",
                                  tint: Color(hex: 0xFF9A2F),
                                  label: "Open")
        case "in_progress", "in-progress", "pending":
            return TicketRowStyle(icon: "clock",
                                  tint: Color(hex: 0xF2A93B),
                                  label: "In progress")
        case "waiting_on_resident":
            return TicketRowStyle(icon: "hourglass",
                                  tint: Color(hex: 0x6FA8DC),
                                  label: "Waiting on you")
        case "resolved", "completed":
            return TicketRowStyle(icon: "checkmark.circle",
                                  tint: Color(hex: 0x4CB58C),
                                  label: "Resolved")
        case "closed":
            return TicketRowStyle(icon: "checkmark.seal",
                                  tint: Color(hex: 0x8DA0B8),
                                  label: "Closed")
        default:
            return TicketRowStyle(icon: "wrench.and.screwdriver",
                                  tint: Color(hex: 0x8DA0B8),
                                  label: status ?? "—")
        }
    }
}

// MARK: - Shared status / category metadata

enum TicketStatus {
    struct Tone {
        let color: Color
        let label: String
    }

    static func tone(for status: String?) -> Tone {
        switch (status ?? "").lowercased() {
        case "open":
            return Tone(color: Color(hex: 0xFF9A2F), label: "Open")
        case "in_progress":
            return Tone(color: Color(hex: 0xF2A93B), label: "In Progress")
        case "waiting_on_resident":
            return Tone(color: Color(hex: 0x6FA8DC), label: "Waiting on you")
        case "resolved":
            return Tone(color: Color(hex: 0x4CB58C), label: "Resolved")
        case "closed":
            return Tone(color: Color(hex: 0x8DA0B8), label: "Closed")
        default:
            return Tone(color: Theme.textMuted, label: status ?? "—")
        }
    }
}

enum TicketCategory {
    static let all: [(key: String, label: String, icon: String)] = [
        ("maintenance", "Maintenance", "wrench.and.screwdriver"),
        ("noise", "Noise", "speaker.wave.2"),
        ("package", "Package", "shippingbox"),
        ("amenity", "Amenity", "calendar"),
        ("billing", "Billing", "creditcard"),
        ("general", "General", "bubble.left"),
        ("other", "Other", "ellipsis.circle"),
    ]

    static func label(for key: String) -> String {
        all.first(where: { $0.key == key.lowercased() })?.label ?? key.capitalized
    }

    static func icon(for key: String) -> String {
        all.first(where: { $0.key == key.lowercased() })?.icon ?? "tag"
    }
}

extension StatusPill {
    static func ticketStatus(_ status: String?) -> StatusPill {
        let t = TicketStatus.tone(for: status)
        return StatusPill(text: t.label, tone: .custom(t.color))
    }
}
