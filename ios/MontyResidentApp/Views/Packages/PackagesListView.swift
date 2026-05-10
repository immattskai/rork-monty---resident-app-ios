import SwiftUI
import UIKit

@MainActor
@Observable
final class PackagesListViewModel {
    var packages: [Package] = []
    var moveInDate: Date?
    var loading = true
    var error: String?
    var filter: PackageFilter = .awaiting

    var awaitingPickup: [Package] {
        packages.filter { p in
            guard !p.isOutgoing else { return false }
            let s = (p.status ?? "").lowercased()
            return s == "received" || s == "notified"
        }
    }

    var outgoing: [Package] {
        packages.filter { $0.isOutgoing }
    }

    var pickedUp: [Package] {
        packages.filter { $0.isPickedUp && !$0.isOutgoing }
    }

    var filtered: [Package] {
        switch filter {
        case .awaiting: return awaitingPickup
        case .outgoing: return outgoing
        case .pickedUp: return pickedUp
        }
    }

    func count(for f: PackageFilter) -> Int {
        switch f {
        case .awaiting: return awaitingPickup.count
        case .outgoing: return outgoing.count
        case .pickedUp: return pickedUp.count
        }
    }

    var isActivated: Bool {
        guard let d = moveInDate else { return true }
        return d <= Date()
    }

    func load(unitId: String, propertyId: String, unitNumber: String?) async {
        loading = true; error = nil
        guard let unitNumber, !unitNumber.isEmpty else {
            packages = []; loading = false; return
        }
        do {
            async let pkgsT = MontyResidentAppService.fetchPackages(propertyId: propertyId, unitNumber: unitNumber)
            async let moveInT = MontyResidentAppService.fetchUnitMoveInDate(unitId: unitId)
            let (pkgs, moveIn) = try await (pkgsT, moveInT)
            self.packages = pkgs
            if let moveIn { self.moveInDate = Fmt.parseDay(moveIn) ?? Fmt.parseDate(moveIn) }
            else { self.moveInDate = nil }
        } catch {
            self.error = "We couldn't load your packages. Pull to refresh."
        }
        loading = false
    }
}

enum PackageFilter: String, CaseIterable, Hashable {
    case awaiting, outgoing, pickedUp

    var label: String {
        switch self {
        case .awaiting: return "Awaiting"
        case .outgoing: return "Outgoing"
        case .pickedUp: return "Picked up"
        }
    }
}

struct PackagesListView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = PackagesListViewModel()

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.packages.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    filterBar.padding(.bottom, 4)
                    skeletonRow
                    skeletonRow
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.packages.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header
                ErrorState(message: err) { Task { await reload() } }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
        } else if !vm.isActivated {
            VStack(alignment: .leading, spacing: 12) {
                header
                preActivationCard
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                    header
                    filterBar.padding(.bottom, 4)

                    if vm.filtered.isEmpty {
                        emptyCard
                    } else {
                        ForEach(vm.filtered) { p in
                            PackageDarkCard(package: p)
                        }
                    }

                    infoFooter.padding(.top, 8)
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Packages")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Deliveries waiting for you")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
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

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(PackageFilter.allCases, id: \.self) { f in
                filterPill(f)
            }
            Spacer(minLength: 0)
        }
    }

    private func filterPill(_ f: PackageFilter) -> some View {
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
                                isActive ? Color.chrome(0.22) : Color.chrome(0.08)
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

    private var emptyCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: emptyIcon)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text(emptyTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(emptySubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 12)
    }

    private var emptyIcon: String {
        switch vm.filter {
        case .awaiting: return "shippingbox"
        case .outgoing: return "paperplane"
        case .pickedUp: return "checkmark.circle"
        }
    }

    private var emptyTitle: String {
        switch vm.filter {
        case .awaiting: return "All caught up"
        case .outgoing: return "No outgoing packages"
        case .pickedUp: return "No pickup history yet"
        }
    }

    private var emptySubtitle: String {
        switch vm.filter {
        case .awaiting: return "No packages waiting for pickup."
        case .outgoing: return "Outgoing shipments will appear here."
        case .pickedUp: return "Once you pick up a package, you'll see it here."
        }
    }

    private var preActivationCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "shippingbox")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 64, height: 64)
                VStack(spacing: 4) {
                    Text("Not yet activated")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your packages will appear here once you've moved in.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 16)
    }

    private var infoFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.chrome(0.45))
                .padding(.top, 1)
            Text("When you receive a delivery, building staff will log it here and you'll be notified. Questions about a package? Use the AI Assistant or contact the front desk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.chrome(0.5))
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
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func premiumCardBackground(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12).fill(Color.chrome(0.05))
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 180, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 220, alignment: .leading)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 96)
    }

    private func reload() async {
        guard let unit = app.activeUnit else {
            vm.loading = false
            return
        }
        await vm.load(
            unitId: unit.id,
            propertyId: unit.property_id,
            unitNumber: unit.unit_number
        )
    }
}

// MARK: - Dark Package Card

private struct PackageDarkCard: View {
    let package: Package

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)

            HStack(alignment: .top, spacing: 12) {
                iconTile

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        if let carrier = package.carrier, !carrier.isEmpty {
                            CarrierBadge(carrier: carrier)
                        }
                        Spacer(minLength: 4)
                        statusBadge
                    }

                    if let received = package.receivedDate {
                        Text("Received \(Fmt.relative(received))")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.6))
                    }
                    if let t = package.tracking_number, !t.isEmpty {
                        Text(t)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.chrome(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let d = package.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.5))
                            .lineLimit(1)
                    }
                }

                if package.isPending {
                    PulsingDot(color: pulsingDotColor)
                        .padding(.top, 6)
                }
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if package.isOutgoing {
            badge(text: "Outgoing", icon: "paperplane.fill", tint: Color(hex: 0x6FA8E0))
        } else {
            switch (package.status ?? "").lowercased() {
            case "received":
                badge(text: "Ready for pickup", icon: "clock.fill", tint: Color(hex: 0x8DA0B8))
            case "notified":
                badge(text: "Notified", icon: "bell.fill", tint: Color(hex: 0xE8B454))
            case "picked_up":
                let when = package.pickedUpDate.map { dateShort($0) } ?? ""
                badge(
                    text: when.isEmpty ? "Picked up" : "Picked up \(when)",
                    icon: "checkmark.circle.fill",
                    tint: Color(hex: 0x4CB58C)
                )
            default:
                badge(text: (package.status ?? "—").capitalized, icon: nil, tint: Color(hex: 0x8DA0B8))
            }
        }
    }

    private func badge(text: String, icon: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .heavy))
                .tracking(0.9)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
    }

    private var iconTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.chrome(0.05))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.chrome(0.7))
                }
            if let badge = sizeBadge {
                Text(badge)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 18, minHeight: 18)
                    .padding(.horizontal, 4)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(Circle().stroke(Theme.premiumCard, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var sizeBadge: String? {
        guard let s = package.package_size?.lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "small", "s": return "S"
        case "medium", "m": return "M"
        case "large", "l": return "L"
        case "xlarge", "extra_large", "extra-large", "xl": return "XL"
        default: return String(s.prefix(2)).uppercased()
        }
    }

    private var pulsingDotColor: Color {
        switch (package.status ?? "").lowercased() {
        case "notified": return Color(hex: 0xE8B454)
        default: return Color(hex: 0x6FA8E0)
        }
    }

    private func dateShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Carrier badge

private struct CarrierBadge: View {
    let carrier: String

    var body: some View {
        Text(displayName.uppercased())
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(textColor)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(brandColor))
    }

    private var key: String {
        carrier.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private var displayName: String {
        switch key {
        case "ups": return "UPS"
        case "fedex": return "FedEx"
        case "usps": return "USPS"
        case "amazon", "amzn": return "Amazon"
        case "dhl": return "DHL"
        default: return carrier
        }
    }

    private var brandColor: Color {
        switch key {
        case "ups": return Color(hex: 0x8A6B3F)
        case "fedex": return Color(hex: 0x4D148C)
        case "usps": return Color(hex: 0x004B87)
        case "amazon", "amzn": return Color(hex: 0xFF9900)
        case "dhl": return Color(hex: 0xFFCC00)
        default: return Color.chrome(0.10)
        }
    }

    private var textColor: Color {
        switch key {
        case "dhl", "amazon", "amzn": return Color.black
        case "ups", "fedex", "usps": return Color.white
        default: return Color.chrome(0.85)
        }
    }
}

// MARK: - Pulsing dot

private struct PulsingDot: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 16, height: 16)
                .scaleEffect(animate ? 1.6 : 0.8)
                .opacity(animate ? 0 : 0.7)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}
