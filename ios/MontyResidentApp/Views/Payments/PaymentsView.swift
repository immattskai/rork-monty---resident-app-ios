import SwiftUI
import UIKit

@MainActor
@Observable
final class PaymentsViewModel {
    var pendingCharges: [CommonCharge] = []
    var payments: [PaymentRecord] = []
    var moveInDate: Date?
    var loading = true
    var error: String?

    var totalBalanceCents: Int {
        let dollars = pendingCharges.reduce(0.0) { $0 + ($1.amount ?? 0) }
        return Int((dollars * 100).rounded())
    }

    var nextDueDate: Date? {
        pendingCharges
            .compactMap { Fmt.parseDay($0.due_date) ?? Fmt.parseDate($0.due_date) }
            .min()
    }

    var isActivated: Bool {
        guard let d = moveInDate else { return true }
        return d <= Date()
    }

    /// Loads each source independently so a single failure (e.g. missing
    /// `move_in_date` or empty `payments`) renders partial UI instead of failing
    /// the whole page. RLS scopes both `common_charges` and `payments` by
    /// `resident_id = auth.uid()`, so we no longer pass `unitId` to those.
    func load(unitId: String) async {
        loading = true; error = nil
        async let chargesT: [CommonCharge]? = try? await MontyResidentAppService.fetchPendingCharges()
        async let paymentsT: [PaymentRecord]? = try? await MontyResidentAppService.fetchPayments()
        async let moveInT: String? = try? await MontyResidentAppService.fetchUnitMoveInDate(unitId: unitId)
        let (charges, pays, moveIn) = await (chargesT, paymentsT, moveInT)
        self.pendingCharges = charges ?? []
        self.payments = pays ?? []
        if let moveIn { self.moveInDate = Fmt.parseDay(moveIn) ?? Fmt.parseDate(moveIn) }
        else { self.moveInDate = nil }
        // Only surface a hard error if BOTH primary sources failed.
        if charges == nil && pays == nil {
            self.error = "We couldn't load your balance. Pull to refresh."
        }
        loading = false
    }
}

struct PaymentsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var vm = PaymentsViewModel()

    private let horizontalPadding: CGFloat = 16
    private static let webPaymentsURL = URL(string: "https://montyliving.com/payments")!

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
        if vm.loading && vm.pendingCharges.isEmpty && vm.payments.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    skeletonHero
                    skeletonRow
                    skeletonRow
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.pendingCharges.isEmpty, vm.payments.isEmpty {
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
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !vm.isActivated {
                        preActivationCard
                    } else {
                        balanceHero
                        if !vm.pendingCharges.isEmpty {
                            outstandingSection
                        }
                        historySection
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        guard let unitId = app.activeUnit?.id else { return }
        await vm.load(unitId: unitId)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                backButton
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Payments")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                Text("Your balance and recent activity")
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
                .background(
                    Circle().fill(Theme.premiumCard)
                )
                .overlay(
                    Circle().stroke(Color.chrome(0.08), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Balance hero

    private var balanceHero: some View {
        let cents = vm.totalBalanceCents
        let isClear = vm.pendingCharges.isEmpty
        return ZStack {
            premiumCardBackground(radius: 22)
            // Warm glow corner
            RadialGradient(
                colors: [Color(hex: 0xFF6A00).opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 0, endRadius: 260
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("CURRENT BALANCE")
                        .font(.system(size: 10.5, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.chrome(0.5))
                    Spacer()
                    if isClear {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("All clear")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.3)
                        }
                        .foregroundStyle(Color(hex: 0x4CB58C))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color(hex: 0x4CB58C).opacity(0.14)))
                    }
                }

                Text(Fmt.currency(cents))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .tracking(-1.0)

                HStack(spacing: 6) {
                    if isClear {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.chrome(0.55))
                        Text("You're all caught up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    } else if let next = vm.nextDueDate {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.chrome(0.55))
                        Text("Next due \(Fmt.short(next))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    } else {
                        Text("No charges due")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                }

                if !isClear {
                    payOnWebButton
                        .padding(.top, 4)
                }

                Text("In-app payments are coming soon — for now, pay your balance securely on montyliving.com.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .clipShape(.rect(cornerRadius: 22))
        .shadow(color: Theme.cardDropShadow, radius: 18, x: 0, y: 8)
    }

    private var payOnWebButton: some View {
        Button {
            openURL(Self.webPaymentsURL)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 8) {
                Text("Pay on the Web")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
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
            .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pre-activation

    private var preActivationCard: some View {
        let dateLabel: String = {
            if let d = vm.moveInDate { return Fmt.short(d) }
            return "soon"
        }()
        return ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("Payments activate \(dateLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Until then, no charges or payments are due.")
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

    // MARK: - Outstanding

    private var outstandingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("OUTSTANDING")
            VStack(spacing: 10) {
                ForEach(vm.pendingCharges) { chargeRow($0) }
            }
        }
    }

    private func chargeRow(_ c: CommonCharge) -> some View {
        let cents = Int(((c.amount ?? 0) * 100).rounded())
        let due = Fmt.parseDay(c.due_date) ?? Fmt.parseDate(c.due_date)
        let needsAttention = (c.validation_status?.lowercased() == "invalid")
        let tint = needsAttention ? Color(hex: 0xE8B454) : Color(hex: 0xFF9A2F)
        return ZStack {
            premiumCardBackground(radius: 16)
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(tint.opacity(0.12))
                        Image(systemName: needsAttention ? "exclamationmark.triangle" : "doc.text")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.description ?? "Common charge")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Text(due.map { "Due \(Fmt.short($0))" } ?? "Pending")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.currency(cents))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }

                if needsAttention {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Autopay needs attention — pay on the web to update your method.")
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color(hex: 0xE8B454))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: 0xE8B454).opacity(0.10))
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("RECENT PAYMENTS")
            if vm.payments.isEmpty {
                emptyHistoryCard
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.payments) { paymentRow($0) }
                }
            }
        }
    }

    private func paymentRow(_ p: PaymentRecord) -> some View {
        let date = Fmt.parseDate(p.paid_at) ?? Fmt.parseDate(p.created_at)
        let style = paymentStyle(for: p.status ?? "")
        return ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style.tint.opacity(0.12))
                    Image(systemName: style.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(style.tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(p.description ?? "Payment")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(Fmt.short(date))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.chrome(0.5))
                        Text(style.label.uppercased())
                            .font(.system(size: 9.5, weight: .heavy))
                            .tracking(0.9)
                            .foregroundStyle(style.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(style.tint.opacity(0.14)))
                    }
                }
                Spacer(minLength: 8)
                Text(Fmt.currency(p.amountCents))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    private var emptyHistoryCard: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "creditcard")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Color.chrome(0.55))
                }
                .frame(width: 50, height: 50)
                Text("No payment history")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Payments you've made will show up here.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.5))
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(Color.chrome(0.45))
            .padding(.top, 4)
    }

    private struct PaymentStyle {
        let icon: String
        let tint: Color
        let label: String
    }

    private func paymentStyle(for status: String) -> PaymentStyle {
        switch status.lowercased() {
        case "succeeded", "paid", "completed":
            return PaymentStyle(icon: "checkmark.circle.fill", tint: Color(hex: 0x4CB58C), label: "Paid")
        case "failed":
            return PaymentStyle(icon: "xmark.circle.fill", tint: Color(hex: 0xF26A6A), label: "Failed")
        case "canceled", "cancelled":
            return PaymentStyle(icon: "xmark.circle", tint: Color(hex: 0x8DA0B8), label: "Canceled")
        default:
            return PaymentStyle(icon: "clock", tint: Color(hex: 0xE8B454), label: status.isEmpty ? "Pending" : status.capitalized)
        }
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

    // MARK: - Skeletons

    private var skeletonHero: some View {
        ZStack {
            premiumCardBackground(radius: 22)
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.06))
                    .frame(width: 130, height: 10)
                RoundedRectangle(cornerRadius: 6).fill(Color.chrome(0.08))
                    .frame(width: 200, height: 40)
                RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                    .frame(width: 160, height: 10)
            }
            .padding(20)
        }
        .frame(height: 180)
    }

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12).fill(Color.chrome(0.05))
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 180, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 220, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 78)
    }
}
