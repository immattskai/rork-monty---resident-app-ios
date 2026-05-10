import SwiftUI
import UIKit

@MainActor
@Observable
final class AmenitiesViewModel {
    var amenities: [Amenity] = []
    var bookings: [AmenityBooking] = []
    var loading = true
    var error: String?
    var toast: String?

    func load(propertyId: String) async {
        loading = true; error = nil
        async let aT: [Amenity]? = try? MontyResidentAppService.fetchAmenities(propertyId: propertyId)
        async let bT: [AmenityBooking]? = try? MontyResidentAppService.fetchMyBookings(propertyId: propertyId)
        amenities = await aT ?? []
        bookings = await bT ?? []
        loading = false
    }

    func cancel(bookingId: String, propertyId: String) async {
        do {
            _ = try await MontyResidentAppService.cancelAmenityBooking(id: bookingId)
            bookings.removeAll { $0.id == bookingId }
            toast = "Booking cancelled."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            toast = "Couldn't cancel. Try again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct AmenitiesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = AmenitiesViewModel()

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.activeUnitId) { await reload() }
        .montyToast(Binding(get: { vm.toast }, set: { vm.toast = $0 }))
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.amenities.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    VStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in skeletonRow }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.amenities.isEmpty {
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if !vm.bookings.isEmpty {
                        myBookingsSection
                    }
                    amenitiesSection
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
                Text("Amenities")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Book and manage shared spaces")
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

    // MARK: - My bookings

    private var myBookingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("MY BOOKINGS", count: vm.bookings.count)
            VStack(spacing: 10) {
                ForEach(vm.bookings) { b in
                    bookingCard(b)
                }
            }
        }
    }

    private func bookingCard(_ b: AmenityBooking) -> some View {
        let canCancel = ["pending", "confirmed", "awaiting_payment"].contains((b.status ?? "").lowercased())
        return ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chrome(0.05))
                    if let s = b.amenityImageURL, let url = URL(string: s) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.chrome(0.55))
                            }
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .allowsHitTesting(false)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(b.amenityName ?? "Amenity")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                    Text(Fmt.bookingWhen(b))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                    if let r = b.rejection_reason, !r.isEmpty,
                       (b.status ?? "").lowercased() == "rejected" {
                        Text(r)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0xF26A6A))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    bookingStatusBadge(b.status)
                    if canCancel {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            guard let pid = app.activePropertyId else { return }
                            Task { await vm.cancel(bookingId: b.id, propertyId: pid) }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xF26A6A))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color(hex: 0xF26A6A).opacity(0.10)))
                                .overlay(Capsule().stroke(Color(hex: 0xF26A6A).opacity(0.30), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    @ViewBuilder
    private func bookingStatusBadge(_ status: String?) -> some View {
        let s = (status ?? "").lowercased()
        switch s {
        case "pending":
            statusBadge("PENDING", color: Color(hex: 0xE8B454))
        case "confirmed":
            statusBadge("CONFIRMED", color: Color(hex: 0x42C18A))
        case "awaiting_payment":
            statusBadge("AWAITING PAY", color: Color(hex: 0xE8B454))
        case "rejected":
            statusBadge("REJECTED", color: Color(hex: 0xF26A6A))
        case "completed":
            statusBadge("COMPLETED", color: Color(hex: 0x8DA0B8))
        case "cancelled":
            statusBadge("CANCELLED", color: Color(hex: 0x8DA0B8))
        default:
            statusBadge((status ?? "—").uppercased(), color: Color(hex: 0x8DA0B8))
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.9)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    // MARK: - Amenities list

    private var amenitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("AVAILABLE AMENITIES", count: vm.amenities.count)
            if vm.amenities.isEmpty {
                emptyAmenitiesCard
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.amenities) { a in
                        NavigationLink(value: HomeRoute.amenityDetail(a)) {
                            AmenityCardView(amenity: a)
                        }
                        .buttonStyle(PressableCardStyle())
                        .simultaneousGesture(TapGesture().onEnded {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        })
                    }
                }
            }
        }
    }

    private var emptyAmenitiesCard: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("No amenities listed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Your building hasn't added any amenities yet. Check back soon.")
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
        .clipShape(.rect(cornerRadius: 18))
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14).fill(Color.chrome(0.05))
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 14).frame(maxWidth: 200, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 11).frame(maxWidth: 240, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 11).frame(maxWidth: 120, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 110)
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

    private func reload() async {
        guard let u = app.activeUnit else { return }
        await vm.load(propertyId: u.property_id)
    }
}

// MARK: - Amenity card

private struct AmenityCardView: View {
    let amenity: Amenity

    var body: some View {
        let style = AmenityStyle.style(for: amenity.name)
        return ZStack {
            cardBackground
            HStack(alignment: .top, spacing: 14) {
                // Muted neutral icon tile (left)
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.chrome(0.05))
                    Image(systemName: style.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.chrome(0.82))
                }
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.chrome(0.08), lineWidth: 0.6)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(amenity.name ?? "Amenity")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let d = amenity.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        if amenity.is_24_7 == true {
                            infoChip(icon: "clock.fill", text: "24/7")
                        } else if let h = amenity.hoursDisplay {
                            infoChip(icon: "clock", text: h)
                        }
                        if amenity.requires_booking == true {
                            infoChip(icon: "calendar", text: "Booking")
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.chrome(0.40))
                    .padding(.top, 6)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private func infoChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.chrome(0.62))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.chrome(0.05)))
        .overlay(Capsule().stroke(Color.chrome(0.08), lineWidth: 0.5))
        .lineLimit(1)
    }
}

// MARK: - Amenity styling (icon + gradient by name)

struct AmenityStyle {
    let icon: String
    let gradient: [Color]
    let accent: Color

    static func style(for name: String?) -> AmenityStyle {
        let n = (name ?? "").lowercased()
        // Muted blue-gray family for the redesigned palette.
        // Gradient kept around because the detail hero still uses it (desaturated).
        let neutralGradient = [Color(hex: 0x1B2230), Color(hex: 0x2A3344)]
        let neutralAccent = Color(hex: 0x8DA0B8)
        switch true {
        case n.contains("gym"), n.contains("fitness"), n.contains("weight"):
            return .init(icon: "dumbbell.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("pool"), n.contains("swim"):
            return .init(icon: "figure.pool.swim", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("sauna"), n.contains("steam"), n.contains("spa"):
            return .init(icon: "flame.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("yoga"), n.contains("meditation"), n.contains("pilates"):
            return .init(icon: "figure.mind.and.body", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("roof"), n.contains("terrace"), n.contains("deck"), n.contains("sky"):
            return .init(icon: "sun.max.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("lounge"), n.contains("club"), n.contains("social"):
            return .init(icon: "sofa.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("bbq"), n.contains("grill"), n.contains("barbecue"):
            return .init(icon: "flame.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("theater"), n.contains("cinema"), n.contains("movie"), n.contains("screening"):
            return .init(icon: "film.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("work"), n.contains("office"), n.contains("co-work"), n.contains("coworking"), n.contains("study"):
            return .init(icon: "laptopcomputer", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("conference"), n.contains("meeting"), n.contains("board"):
            return .init(icon: "person.3.sequence.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("game"), n.contains("arcade"), n.contains("billiards"), n.contains("pool table"):
            return .init(icon: "gamecontroller.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("pet"), n.contains("dog"):
            return .init(icon: "pawprint.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("bike"), n.contains("bicycle"):
            return .init(icon: "bicycle", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("park"), n.contains("garden"), n.contains("green"):
            return .init(icon: "leaf.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("laundry"):
            return .init(icon: "washer.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("kitchen"), n.contains("dining"), n.contains("chef"):
            return .init(icon: "fork.knife", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("bar"), n.contains("wine"), n.contains("cocktail"):
            return .init(icon: "wineglass.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("basketball"), n.contains("sport"), n.contains("court"):
            return .init(icon: "basketball.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("tennis"), n.contains("pickleball"):
            return .init(icon: "tennis.racket", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("golf"):
            return .init(icon: "figure.golf", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("music"), n.contains("piano"), n.contains("studio"):
            return .init(icon: "music.note", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("library"), n.contains("reading"), n.contains("book"):
            return .init(icon: "books.vertical.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("kids"), n.contains("children"), n.contains("playroom"):
            return .init(icon: "figure.and.child.holdinghands", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("package"), n.contains("mail"), n.contains("parcel"):
            return .init(icon: "shippingbox.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("parking"), n.contains("garage"), n.contains("valet"), n.contains("car"):
            return .init(icon: "car.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("storage"):
            return .init(icon: "archivebox.fill", gradient: neutralGradient, accent: neutralAccent)
        case n.contains("event"), n.contains("hall"), n.contains("ballroom"):
            return .init(icon: "sparkles", gradient: neutralGradient, accent: neutralAccent)
        default:
            return .init(icon: "sparkles", gradient: neutralGradient, accent: neutralAccent)
        }
    }
}

// MARK: - Badge tone (shared)

enum MontyBadgeTone {
    case neutral, info, warning, success, danger
    var color: Color {
        switch self {
        case .neutral: return Theme.textSecondary
        case .info: return Theme.info
        case .warning: return Theme.warning
        case .success: return Theme.success
        case .danger: return Theme.danger
        }
    }
}
