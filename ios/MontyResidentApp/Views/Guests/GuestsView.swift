import SwiftUI
import UIKit

@MainActor
@Observable
final class GuestsViewModel {
    var guests: [GuestAccess] = []
    var loading = true
    var error: String?

    func load(propertyId: String, unitNumber: String) async {
        loading = true; error = nil
        do {
            guests = try await GuestService.fetchGuests(propertyId: propertyId, unitNumber: unitNumber)
        } catch {
            self.error = "We couldn't load your guests. Try again."
        }
        loading = false
    }

    var active: [GuestAccess] { guests.filter { $0.isCurrentlyActive } }
    var past: [GuestAccess] { guests.filter { !$0.isCurrentlyActive } }
}

struct GuestsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = GuestsViewModel()
    @State private var showAdd = false
    @State private var addPrefill: GuestInput? = nil
    @State private var editTarget: GuestAccess? = nil
    @State private var revokeTarget: GuestAccess? = nil
    @State private var revokingId: String? = nil
    @State private var toast: String? = nil

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .montyToast($toast)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAdd) {
            AddGuestSheet(
                mode: .create,
                initial: addPrefill ?? GuestInput(),
                onDone: { msg in
                    showAdd = false
                    showToast(msg)
                    Task { await reload() }
                }
            )
        }
        .sheet(item: $editTarget) { target in
            AddGuestSheet(
                mode: .edit(id: target.id),
                initial: GuestInput.from(target),
                onDone: { msg in
                    editTarget = nil
                    showToast(msg)
                    Task { await reload() }
                }
            )
        }
        .alert("Revoke Guest Access?", isPresented: Binding(
            get: { revokeTarget != nil },
            set: { if !$0 { revokeTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { revokeTarget = nil }
            Button("Revoke", role: .destructive) {
                if let g = revokeTarget { Task { await revoke(g) } }
                revokeTarget = nil
            }
        } message: {
            Text("This will immediately remove access for \(revokeTarget?.guest_name ?? "this guest").")
        }
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.guests.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    skeletonRow
                    skeletonRow
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.guests.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ZStack {
                        premiumCardBackground(radius: 18)
                        ErrorState(message: err) { Task { await reload() } }
                            .padding(.vertical, 8)
                    }
                    .clipShape(.rect(cornerRadius: 18))
                    .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    header
                    activeSection
                    pastSection
                    infoCard
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                backButton
                Spacer()
            }
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Guests")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Active access for your unit")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                Spacer(minLength: 12)
                addGuestButton
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
                .background(Circle().fill(Theme.premiumCard))
                .overlay(Circle().stroke(Color.chrome(0.08), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private var addGuestButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            addPrefill = nil
            editTarget = nil
            showAdd = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("Add Guest")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.premiumCard))
            .overlay(Capsule().stroke(Color.chrome(0.10), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    @ViewBuilder
    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("CURRENTLY ACTIVE", count: vm.active.count)
            if vm.active.isEmpty {
                emptyActiveCard
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.active) { g in
                        GuestCard(
                            guest: g,
                            isActive: true,
                            isWorking: revokingId == g.id,
                            onEdit: { editTarget = g },
                            onRevoke: { revokeTarget = g },
                            onAddAgain: nil
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pastSection: some View {
        if !vm.past.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("PAST GUESTS", count: vm.past.count)
                VStack(spacing: 10) {
                    ForEach(vm.past) { g in
                        GuestCard(
                            guest: g,
                            isActive: false,
                            isWorking: false,
                            onEdit: nil,
                            onRevoke: nil,
                            onAddAgain: {
                                var prefill = GuestInput.from(g)
                                prefill.accessStart = Date()
                                prefill.accessEnd = Date().addingTimeInterval(60 * 60 * 24)
                                addPrefill = prefill
                                showAdd = true
                            }
                        )
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.chrome(0.45))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.chrome(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var emptyActiveCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("No active guests")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Add a guest so building staff can verify them when they arrive.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    addPrefill = nil
                    showAdd = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Add guest")
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
        .clipShape(.rect(cornerRadius: 18))
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.chrome(0.55))
                .padding(.top, 1)
            Text("When you add a guest, building staff can verify their access when they arrive.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.chrome(0.55))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.chrome(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.chrome(0.06), lineWidth: 0.6)
        )
        .padding(.top, 4)
    }

    private func reload() async {
        guard let unit = app.activeUnit,
              let unitNumber = unit.unit_number, !unitNumber.isEmpty else {
            vm.loading = false
            return
        }
        await vm.load(propertyId: unit.property_id, unitNumber: unitNumber)
    }

    private func revoke(_ g: GuestAccess) async {
        revokingId = g.id
        if let idx = vm.guests.firstIndex(where: { $0.id == g.id }) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                vm.guests[idx].status = "revoked"
                vm.guests[idx].revoked_at = Fmt.iso.string(from: Date())
            }
        }
        do {
            _ = try await GuestService.revokeGuest(id: g.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("Guest access revoked.")
        } catch {
            await reload()
            showToast("We couldn't revoke that guest. Try again.")
        }
        revokingId = nil
    }

    private func showToast(_ text: String) {
        withAnimation(Theme.Motion.smooth) { toast = text }
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                Circle().fill(Color.chrome(0.05))
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 160, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 200, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 92)
    }

    @ViewBuilder
    fileprivate func premiumCardBackground(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }
}

// MARK: - Guest card

private struct GuestCard: View {
    let guest: GuestAccess
    let isActive: Bool
    let isWorking: Bool
    let onEdit: (() -> Void)?
    let onRevoke: (() -> Void)?
    let onAddAgain: (() -> Void)?

    var body: some View {
        ZStack {
            cardBackground
            VStack(alignment: .leading, spacing: 12) {
                header
                if let when = formattedRange {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                        Text(when)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                if guest.is_recurring == true, let days = guest.recurring_days, !days.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(days.sorted(), id: \.self) { d in
                            Text(GuestsCopy.dayShort(d))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.chrome(0.08)))
                                .overlay(Capsule().stroke(Color.chrome(0.10), lineWidth: 0.5))
                        }
                    }
                }
                actions
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(isActive ? 0.24 : 0.14), radius: 14, x: 0, y: 6)
        .opacity(isActive ? 1 : 0.85)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let baseFill = Theme.premiumCard
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(baseFill)
            if isActive {
                RadialGradient(
                    colors: [Color(hex: 0x42C18A).opacity(0.10), .clear],
                    center: .topTrailing,
                    startRadius: 0, endRadius: 220
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(isActive ? 0.06 : 0.04), lineWidth: 0.6)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.chrome(0.06))
                Text(initials)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(guest.guest_name ?? "Guest")
                    .font(.system(size: 15.5, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let rel = guest.relationship, !rel.isEmpty {
                    Text(rel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .lineLimit(1)
                }
                if let phone = guest.guest_phone, !phone.isEmpty {
                    Button {
                        if let url = URL(string: "tel:\(phone.filter { "+0123456789".contains($0) })") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(phone)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.chrome(0.78))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 4)
            statusBadge
        }
    }

    private var initials: String {
        let comps = (guest.guest_name ?? "").split(separator: " ").prefix(2)
        let s = comps.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "•" : s.uppercased()
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isActive {
            badge(text: "ACTIVE", color: Color(hex: 0x42C18A))
        } else {
            let label = (guest.status?.lowercased() == "revoked") ? "REVOKED" : "EXPIRED"
            badge(text: label, color: Color(hex: 0x8DA0B8))
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.9)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    @ViewBuilder
    private var actions: some View {
        if isActive {
            HStack(spacing: 8) {
                if let onEdit {
                    Button(action: onEdit) {
                        actionLabel(text: "Edit", systemImage: "pencil", style: .neutral)
                    }
                    .buttonStyle(.plain)
                }
                if let onRevoke {
                    Button(action: onRevoke) {
                        if isWorking {
                            ProgressView().controlSize(.small)
                                .tint(Color(hex: 0xF26A6A))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color(hex: 0xF26A6A).opacity(0.10)))
                                .overlay(Capsule().stroke(Color(hex: 0xF26A6A).opacity(0.25), lineWidth: 0.6))
                        } else {
                            actionLabel(text: "Revoke", systemImage: "xmark.circle", style: .danger)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
            }
            .padding(.top, 2)
        } else if let onAddAgain {
            Button(action: onAddAgain) {
                actionLabel(text: "Add again", systemImage: "arrow.clockwise", style: .neutral)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private enum ActionStyle { case neutral, danger }

    private func actionLabel(text: String, systemImage: String, style: ActionStyle) -> some View {
        let fg: Color = (style == .danger) ? Color(hex: 0xF26A6A) : .white
        let bg: Color = (style == .danger) ? Color(hex: 0xF26A6A).opacity(0.10) : Color.chrome(0.08)
        let stroke: Color = (style == .danger) ? Color(hex: 0xF26A6A).opacity(0.25) : Color.chrome(0.10)
        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(fg)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Capsule().fill(bg))
        .overlay(Capsule().stroke(stroke, lineWidth: 0.6))
    }

    private var formattedRange: String? {
        guard let start = guest.startDate else { return nil }
        let end = guest.endDate
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, h:mm a"
        let startStr = f.string(from: start)
        guard let end else { return startStr }
        let cal = Calendar.current
        if cal.isDate(start, inSameDayAs: end) {
            let timeOnly = DateFormatter()
            timeOnly.locale = Locale.current
            timeOnly.dateFormat = "h:mm a"
            return "\(startStr) – \(timeOnly.string(from: end))"
        }
        return "\(startStr) – \(f.string(from: end))"
    }
}

// MARK: - Day labels

enum GuestsCopy {
    static func dayShort(_ d: Int) -> String {
        switch d {
        case 0: return "Sun"
        case 1: return "Mon"
        case 2: return "Tue"
        case 3: return "Wed"
        case 4: return "Thu"
        case 5: return "Fri"
        case 6: return "Sat"
        default: return "?"
        }
    }
}
