import SwiftUI
import UIKit

@MainActor
@Observable
final class AmenityDetailViewModel {
    var amenity: Amenity
    var selectedDate: Date = Date()
    var bookedSlots: [AmenityBooking] = []
    var selectedSlot: TimeSlot?
    var notes: String = ""
    var loadingSlots = false
    var submitting = false
    var error: String?
    var toast: String?

    init(amenity: Amenity) {
        self.amenity = amenity
        let earliest = Self.firstSelectableDate(for: amenity)
        self.selectedDate = earliest
    }

    var config: AmenityBookingConfig { amenity.booking_config ?? AmenityBookingConfig() }
    var slotMinutes: Int { max(15, config.slot_duration_minutes ?? 60) }

    var availableDays: Set<Int> {
        if let d = config.available_days, !d.isEmpty { return Set(d) }
        return Set(0...6)
    }

    var blackoutDates: Set<String> { Set(config.blackout_dates ?? []) }

    static func firstSelectableDate(for amenity: Amenity) -> Date {
        let cfg = amenity.booking_config ?? AmenityBookingConfig()
        let advance = max(0, cfg.min_advance_days ?? 0)
        return Calendar.current.date(byAdding: .day, value: advance, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    var minSelectableDate: Date { Self.firstSelectableDate(for: amenity) }
    var maxSelectableDate: Date { Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date() }

    var dateUnavailableReason: String? {
        let cal = Calendar.current
        let day = cal.component(.weekday, from: selectedDate) - 1
        if !availableDays.contains(day) { return "Closed on \(weekdayName(day))" }
        let dayString = Self.dateString(selectedDate)
        if blackoutDates.contains(dayString) { return "Unavailable on this date" }
        if cal.startOfDay(for: selectedDate) < cal.startOfDay(for: minSelectableDate) {
            let advance = max(0, config.min_advance_days ?? 0)
            return advance > 0 ? "Requires \(advance)-day advance booking" : "Date in the past"
        }
        return nil
    }

    func slotsForSelectedDate() -> [TimeSlot] {
        let h = config.bookable_hours
        let startStr = h?.start ?? "08:00"
        let endStr = h?.end ?? "20:00"
        guard let startMin = Self.parseHM(startStr),
              let endMin = Self.parseHM(endStr),
              endMin > startMin else { return [] }
        var slots: [TimeSlot] = []
        var t = startMin
        while t + slotMinutes <= endMin {
            let s = Self.formatHM(t)
            let e = Self.formatHM(t + slotMinutes)
            slots.append(TimeSlot(start: s, end: e))
            t += slotMinutes
        }
        return slots
    }

    func isSlotBooked(_ slot: TimeSlot) -> Bool {
        let target = slot.start + ":00"
        return bookedSlots.contains { ($0.start_time ?? "") == target }
    }

    @MainActor
    func loadSlots() async {
        loadingSlots = true
        defer { loadingSlots = false }
        let date = Self.dateString(selectedDate)
        let rows = (try? await MontyResidentAppService.fetchBookedSlots(amenityId: amenity.id, date: date)) ?? []
        self.bookedSlots = rows
        if let chosen = selectedSlot, isSlotBooked(chosen) {
            selectedSlot = nil
        }
    }

    @MainActor
    func submit(propertyId: String) async -> Bool {
        guard let slot = selectedSlot else {
            error = "Pick a time slot to continue."
            return false
        }
        if let reason = dateUnavailableReason {
            error = reason
            return false
        }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            _ = try await MontyResidentAppService.createAmenityBooking(
                amenityId: amenity.id,
                propertyId: propertyId,
                date: Self.dateString(selectedDate),
                start: slot.start,
                end: slot.end,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            toast = "Request submitted! Pending approval."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await loadSlots()
            selectedSlot = nil
            notes = ""
            return true
        } catch {
            self.error = "We couldn't submit your booking. Try again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    // MARK: - Helpers

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func parseHM(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    static func formatHM(_ minutes: Int) -> String {
        let h = (minutes / 60) % 24
        let m = minutes % 60
        return String(format: "%02d:%02d", h, m)
    }

    private func weekdayName(_ day: Int) -> String {
        let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
        return names[max(0, min(6, day))]
    }

    nonisolated struct TimeSlot: Hashable, Identifiable {
        let start: String
        let end: String
        var id: String { start }
        var displayLabel: String { Fmt.formatTime(start) }
    }
}

struct AmenityDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm: AmenityDetailViewModel

    private let horizontalPadding: CGFloat = 16

    init(amenity: Amenity) {
        _vm = State(initialValue: AmenityDetailViewModel(amenity: amenity))
    }

    var body: some View {
        ZStack {
            AtmosphericBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headerBar
                    hero
                    headerInfo
                    if vm.amenity.requires_booking != false {
                        dateSection
                        slotsSection
                        notesSection
                        feeSection
                    } else {
                        noBookingNeeded
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 130)
            }
            VStack {
                Spacer()
                bookingBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await vm.loadSlots() }
        .onChange(of: vm.selectedDate) { _, _ in
            vm.selectedSlot = nil
            Task { await vm.loadSlots() }
        }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Toast(text: t, icon: "checkmark.circle.fill", tone: .success)
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.0))
                        withAnimation(Theme.Motion.smooth) { vm.toast = nil }
                        try? await Task.sleep(for: .milliseconds(300))
                        dismiss()
                    }
            }
        }
        .animation(Theme.Motion.smooth, value: vm.toast)
    }

    // MARK: - Header bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tap()
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
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Hero (desaturated)

    private var hero: some View {
        let style = AmenityStyle.style(for: vm.amenity.name)
        return ZStack {
            // Desaturated luxury gradient — consistent with the rest of the app.
            LinearGradient(
                colors: [Color(hex: 0x1B2230), Color(hex: 0x0E121A)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Subtle ornament rings
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .stroke(Color.chrome(0.08), lineWidth: 1)
                        .frame(width: 240, height: 240)
                        .position(x: geo.size.width - 30, y: 40)
                    Circle()
                        .stroke(Color.chrome(0.05), lineWidth: 1)
                        .frame(width: 360, height: 360)
                        .position(x: geo.size.width - 30, y: 40)
                    Circle()
                        .fill(Color.chrome(0.04))
                        .frame(width: 140, height: 140)
                        .position(x: 30, y: geo.size.height - 20)
                }
            }
            // Faint blue glow
            RadialGradient(
                colors: [Color(hex: 0x4DA3FF).opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 0, endRadius: 280
            )
            VStack {
                HStack {
                    Image(systemName: style.icon)
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .shadow(color: Theme.cardDropShadow, radius: 8, y: 4)
                    Spacer()
                }
                .padding(24)
                Spacer()
            }
        }
        .frame(height: 200)
        .clipShape(.rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.chrome(0.06), lineWidth: 0.6)
        )
        .shadow(color: Theme.cardDropShadow, radius: 18, x: 0, y: 8)
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.amenity.name ?? "Amenity")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.textPrimary)
            if let d = vm.amenity.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.chrome(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let h = vm.amenity.hoursDisplay {
                HStack(spacing: 5) {
                    Image(systemName: vm.amenity.is_24_7 == true ? "clock.fill" : "clock")
                        .font(.system(size: 11, weight: .semibold))
                    Text(h).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.chrome(0.78))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.chrome(0.06)))
                .overlay(Capsule().stroke(Color.chrome(0.10), lineWidth: 0.6))
            }
        }
    }

    // MARK: - Date

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("PICK A DATE")
            ZStack {
                premiumCardBackground(radius: 18)
                DatePicker(
                    "Date",
                    selection: $vm.selectedDate,
                    in: vm.minSelectableDate...vm.maxSelectableDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .tint(Color(hex: 0xFF8A1F))
                .colorScheme(.dark)
                .padding(10)
            }
            .clipShape(.rect(cornerRadius: 18))
            if let reason = vm.dateUnavailableReason {
                inlineNotice(icon: "exclamationmark.triangle.fill", text: reason, color: Color(hex: 0xE8B454))
            }
        }
    }

    // MARK: - Slots

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("AVAILABLE TIMES")
            if vm.dateUnavailableReason != nil {
                Text("Choose another date to see available times.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
                    .padding(.vertical, 8)
            } else if vm.loadingSlots && vm.bookedSlots.isEmpty {
                HStack {
                    ProgressView().tint(Color.chrome(0.7))
                    Text("Loading times…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                .padding(.vertical, 8)
            } else {
                let slots = vm.slotsForSelectedDate()
                if slots.isEmpty {
                    Text("No bookable times configured.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .padding(.vertical, 8)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(slots) { slot in
                            slotChip(slot)
                        }
                    }
                }
            }
        }
    }

    private func slotChip(_ slot: AmenityDetailViewModel.TimeSlot) -> some View {
        let booked = vm.isSlotBooked(slot)
        let selected = vm.selectedSlot == slot
        return Button {
            guard !booked else { return }
            Haptics.tap()
            vm.selectedSlot = selected ? nil : slot
        } label: {
            Text(slot.displayLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    booked ? Color.chrome(0.30)
                    : (selected ? .white : Color.chrome(0.85))
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    ZStack {
                        if selected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Theme.premiumCard)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            selected ? .clear : Color.chrome(booked ? 0.04 : 0.08),
                            lineWidth: 0.6
                        )
                )
                .shadow(color: selected ? Color(hex: 0xFF6A00).opacity(0.35) : .clear,
                        radius: selected ? 12 : 0, y: selected ? 5 : 0)
                .opacity(booked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(booked)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("NOTES (OPTIONAL)")
            ZStack(alignment: .topLeading) {
                premiumCardBackground(radius: 16)
                TextField(
                    "",
                    text: $vm.notes,
                    prompt: Text("Anything staff should know")
                        .foregroundStyle(Color.chrome(0.40)),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .tint(Color(hex: 0xFF8A1F))
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    // MARK: - Fees

    @ViewBuilder
    private var feeSection: some View {
        if vm.config.booking_fee != nil || vm.config.security_deposit != nil {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("FEES")
                VStack(spacing: 8) {
                    if let fee = vm.config.booking_fee {
                        feeRow(title: "Booking fee", amount: fee.amount, subtitle: fee.description)
                    }
                    if let dep = vm.config.security_deposit {
                        feeRow(title: "Security deposit", amount: dep.amount, subtitle: dep.description ?? dep.refund_policy)
                    }
                }
            }
        }
    }

    private func feeRow(title: String, amount: Double?, subtitle: String?) -> some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let s = subtitle, !s.isEmpty {
                        Text(s)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(formatDollars(amount))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
    }

    private func formatDollars(_ amount: Double?) -> String {
        let v = amount ?? 0
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f.string(from: NSNumber(value: v)) ?? "$0.00"
    }

    // MARK: - No booking needed

    private var noBookingNeeded: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x42C18A))
                Text("This amenity is open access — no booking required. Just stop by during the listed hours.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .clipShape(.rect(cornerRadius: 16))
    }

    // MARK: - Sticky booking bar

    @ViewBuilder
    private var bookingBar: some View {
        if vm.amenity.requires_booking != false {
            VStack(spacing: 8) {
                if let err = vm.error {
                    Text(err)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xF26A6A))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    guard let pid = app.activePropertyId else { return }
                    Task { _ = await vm.submit(propertyId: pid) }
                } label: {
                    HStack {
                        if vm.submitting {
                            ProgressView().tint(.white)
                        } else {
                            Text(submitLabel)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                submitEnabled
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.chrome(0.10))
                            )
                    )
                    .shadow(color: submitEnabled ? Color(hex: 0xFF6A00).opacity(0.35) : .clear,
                            radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .disabled(!submitEnabled || vm.submitting)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x030406).opacity(0), Color(hex: 0x030406)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private var submitEnabled: Bool {
        vm.selectedSlot != nil && vm.dateUnavailableReason == nil
    }

    private var submitLabel: String {
        guard let slot = vm.selectedSlot else { return "Pick a time to continue" }
        return "Request \(slot.displayLabel)"
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.chrome(0.45))
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func inlineNotice(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 0.6)
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
}
