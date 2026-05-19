import SwiftUI

/// Steps in the resident pay flow.
enum PayFlowStep: Hashable {
    case amount
    case method
    case review
    case success
}

@MainActor
@Observable
final class PayFlowViewModel {
    // Inputs
    var charges: [CommonCharge]
    let propertyId: String?

    // State
    var path: [PayFlowStep] = []
    var amountCents: Int
    var selectedChargeId: String?

    /// When false (default), pay the full open balance — all charges in `charges`
    /// get allocated their full amount. When true, the user is splitting a custom
    /// amount across one or more charges and `allocations` drives per-charge values.
    var useCustom: Bool = false

    /// Per-charge allocation (only consulted in custom mode). Sum should equal
    /// `amountCents` before continue is enabled.
    var allocations: [String: Int] = [:]

    var methods: [MoovPaymentMethod] = []
    var loadingMethods: Bool = false
    var methodsError: String?

    var selectedMethod: MoovPaymentMethod?

    var preview: TransferPreview?
    var previewing: Bool = false
    var previewError: String?

    var submitting: Bool = false
    var submitError: String?

    var result: TransferResult?
    /// Aggregate total actually charged across multi-call submits.
    var aggregateTotalCents: Int = 0

    /// Whether to show "+ Add bank" / "+ Add card" sheets.
    var presentingAddBank: Bool = false
    var presentingAddCard: Bool = false

    var plaidLinkToken: String?
    var moovDropsToken: MoovDropsToken?
    var loadingAddFlow: Bool = false
    var addFlowError: String?

    init(charges: [CommonCharge], propertyId: String?) {
        self.charges = charges
        self.propertyId = propertyId
        // `amount` is already integer cents on the server (e.g. 500 = $5.00).
        let total = charges.reduce(0) { acc, c in
            acc + Int((c.amount ?? 0).rounded())
        }
        self.amountCents = total
        // Default to first charge so server can attribute the payment in
        // single-charge legacy paths (review/submit fallbacks).
        self.selectedChargeId = charges.first?.id
        // Seed full-balance allocations so submit can loop transparently.
        for c in charges {
            self.allocations[c.id] = Int((c.amount ?? 0).rounded())
        }
    }

    /// Sorted oldest-due first; used for split-evenly and apply-to-oldest helpers.
    var chargesOldestFirst: [CommonCharge] {
        charges.sorted { a, b in
            let da = Fmt.parseDay(a.due_date) ?? Fmt.parseDate(a.due_date) ?? .distantFuture
            let db = Fmt.parseDay(b.due_date) ?? Fmt.parseDate(b.due_date) ?? .distantFuture
            return da < db
        }
    }

    /// Charges that will actually be paid in this flow (allocation > 0).
    var activeAllocations: [(charge: CommonCharge, cents: Int)] {
        chargesOldestFirst.compactMap { c in
            let cents = allocations[c.id] ?? 0
            return cents > 0 ? (c, cents) : nil
        }
    }

    var allocatedTotalCents: Int {
        allocations.values.reduce(0, +)
    }

    var isAllocationBalanced: Bool {
        if !useCustom { return amountCents == totalBalanceCents }
        return allocatedTotalCents == amountCents && amountCents > 0
    }

    func resetToFullBalance() {
        useCustom = false
        amountCents = totalBalanceCents
        for c in charges {
            allocations[c.id] = Int((c.amount ?? 0).rounded())
        }
    }

    func splitEvenly() {
        guard !charges.isEmpty, amountCents > 0 else { return }
        let n = charges.count
        let base = amountCents / n
        var remainder = amountCents - base * n
        for c in chargesOldestFirst {
            let cap = Int((c.amount ?? 0).rounded())
            var v = min(base, cap)
            if remainder > 0 && v < cap {
                let add = min(remainder, cap - v)
                v += add
                remainder -= add
            }
            allocations[c.id] = v
        }
        // If caps absorbed less than amount, push leftover to first under-cap row.
        var leftover = amountCents - allocatedTotalCents
        if leftover > 0 {
            for c in chargesOldestFirst {
                let cap = Int((c.amount ?? 0).rounded())
                let cur = allocations[c.id] ?? 0
                let room = cap - cur
                if room > 0 {
                    let add = min(room, leftover)
                    allocations[c.id] = cur + add
                    leftover -= add
                    if leftover == 0 { break }
                }
            }
        }
    }

    func applyToOldest() {
        guard amountCents > 0 else { return }
        var remaining = amountCents
        for c in chargesOldestFirst {
            let cap = Int((c.amount ?? 0).rounded())
            let take = min(cap, remaining)
            allocations[c.id] = take
            remaining -= take
        }
    }

    func setAllocation(chargeId: String, cents: Int) {
        let cap = Int(((charges.first { $0.id == chargeId }?.amount) ?? 0).rounded())
        allocations[chargeId] = max(0, min(cents, cap))
    }

    var totalBalanceCents: Int {
        charges.reduce(0) { acc, c in
            acc + Int((c.amount ?? 0).rounded())
        }
    }

    func loadMethods() async {
        loadingMethods = true
        methodsError = nil
        do {
            let pms = try await MoovPaymentsService.listPaymentMethods()
            self.methods = pms
            if selectedMethod == nil {
                self.selectedMethod = pms.first(where: { $0.is_default == true }) ?? pms.first
            }
        } catch {
            self.methodsError = MoovPaymentsService.friendlyMessage(error)
        }
        loadingMethods = false
    }

    func startAddBank() async {
        loadingAddFlow = true
        addFlowError = nil
        do {
            let token = try await MoovPaymentsService.plaidLinkToken()
            self.plaidLinkToken = token
            self.presentingAddBank = true
        } catch {
            self.addFlowError = MoovPaymentsService.friendlyMessage(error)
        }
        loadingAddFlow = false
    }

    func startAddCard() async {
        loadingAddFlow = true
        addFlowError = nil
        do {
            let drops = try await MoovPaymentsService.cardLinkToken()
            self.moovDropsToken = drops
            self.presentingAddCard = true
        } catch {
            self.addFlowError = MoovPaymentsService.friendlyMessage(error)
        }
        loadingAddFlow = false
    }

    func handlePlaidSuccess(publicToken: String, accountId: String?, metadata: [String: Any]) async {
        loadingAddFlow = true
        addFlowError = nil
        do {
            let pm = try await MoovPaymentsService.exchangePlaidPublicToken(
                publicToken: publicToken,
                accountId: accountId,
                metadata: metadata
            )
            // Prepend & auto-select.
            self.methods = [pm] + methods.filter { $0.payment_method_id != pm.payment_method_id }
            self.selectedMethod = pm
        } catch {
            self.addFlowError = MoovPaymentsService.friendlyMessage(error)
        }
        loadingAddFlow = false
    }

    func handleCardAdded(paymentMethodId: String, brand: String?, last4: String?) {
        // Optimistically prepend; refresh from server to fill in any missing fields.
        let optimistic = MoovPaymentMethod(
            payment_method_id: paymentMethodId,
            method_type: "card",
            brand: brand,
            last4: last4
        )
        methods = [optimistic] + methods.filter { $0.payment_method_id != paymentMethodId }
        selectedMethod = optimistic
        Task { await loadMethods() }
    }

    func loadPreview() async {
        guard let method = selectedMethod else { return }
        previewing = true
        previewError = nil
        preview = nil
        do {
            preview = try await MoovPaymentsService.previewTransfer(
                chargeId: selectedChargeId,
                paymentMethodId: method.payment_method_id,
                amountCents: amountCents
            )
        } catch {
            previewError = MoovPaymentsService.friendlyMessage(error)
        }
        previewing = false
    }

    func submit() async {
        guard let method = selectedMethod else { return }
        submitting = true
        submitError = nil
        // Build the actual list of (chargeId, amount) we need to submit.
        // - Full balance: one call per charge, full amount each.
        // - Custom: one call per non-zero allocation.
        // Legacy single-charge fallback: if we have exactly one entry, use
        // the existing single-call path (preserves the prior server behavior).
        let calls: [(chargeId: String?, cents: Int)] = {
            let active = activeAllocations
            if active.isEmpty {
                return [(selectedChargeId, amountCents)]
            }
            if active.count == 1 {
                return [(active[0].charge.id, active[0].cents)]
            }
            return active.map { ($0.charge.id, $0.cents) }
        }()
        do {
            var lastResult: TransferResult?
            var totalCharged = 0
            for call in calls {
                let r = try await MoovPaymentsService.processTransfer(
                    chargeId: call.chargeId,
                    paymentMethodId: method.payment_method_id,
                    amountCents: call.cents
                )
                lastResult = r
                totalCharged += r.totalCents
            }
            self.result = lastResult
            self.aggregateTotalCents = totalCharged
            path.append(.success)
        } catch {
            submitError = MoovPaymentsService.friendlyMessage(error)
        }
        submitting = false
    }
}

struct PayFlowView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var vm: PayFlowViewModel
    /// Called after a successful payment so the parent can invalidate caches.
    let onCompleted: () -> Void

    var body: some View {
        NavigationStack(path: $vm.path) {
            PayAmountStep(vm: vm) {
                // continue → method picker
                vm.path.append(.method)
            }
            .navigationDestination(for: PayFlowStep.self) { step in
                switch step {
                case .amount:   PayAmountStep(vm: vm) { vm.path.append(.method) }
                case .method:   PayMethodStep(vm: vm) { vm.path.append(.review) }
                case .review:   PayReviewStep(vm: vm)
                case .success:  PaySuccessStep(vm: vm) {
                    onCompleted()
                    dismiss()
                }
                }
            }
        }
        .interactiveDismissDisabled(vm.submitting)
    }
}

// MARK: - Step 1: Amount

private struct PayAmountStep: View {
    @Bindable var vm: PayFlowViewModel
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customAmountText: String = ""
    /// Per-charge editable text, kept in sync with `vm.allocations`.
    @State private var allocationTexts: [String: String] = [:]

    var body: some View {
        ZStack {
            AtmosphericBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleHeader
                    balanceCard
                    segmentedToggle

                    if vm.useCustom {
                        customAmountField
                        allocationToolbar
                        allocationProgress
                    }

                    if !vm.charges.isEmpty {
                        chargesSection
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 120)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.useCustom)
            }
            .safeAreaInset(edge: .bottom) {
                continueBar
            }
        }
        .onAppear { syncAllocationTexts() }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("Pay")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.chrome(0.75))
                }
                .accessibilityLabel("Close")
            }
        }
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Make a payment")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(Theme.textPrimary)
            Text("Choose how much you'd like to pay")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.chrome(0.55))
        }
        .padding(.top, 4)
    }

    private var balanceCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6)
            VStack(alignment: .leading, spacing: 8) {
                Text("CURRENT BALANCE")
                    .font(.system(size: 10.5, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.chrome(0.5))
                Text(Fmt.currency(vm.totalBalanceCents))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .tracking(-0.8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    /// Sliding pill segmented control that swaps between full balance and split.
    private var segmentedToggle: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let segW = (w - 8) / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.chrome(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.chrome(0.06), lineWidth: 0.6)
                    )
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.premiumCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.chrome(0.12), lineWidth: 0.7)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                    .frame(width: segW, height: 44)
                    .offset(x: vm.useCustom ? segW + 4 : 4)
                    .padding(.vertical, 4)
                HStack(spacing: 0) {
                    segmentLabel(title: "Full balance", subtitle: Fmt.currency(vm.totalBalanceCents), active: !vm.useCustom)
                        .frame(width: segW)
                        .contentShape(Rectangle())
                        .onTapGesture { selectFullBalance() }
                    segmentLabel(title: "Split", subtitle: vm.useCustom ? Fmt.currency(vm.amountCents) : "Custom amount", active: vm.useCustom)
                        .frame(width: segW)
                        .contentShape(Rectangle())
                        .onTapGesture { selectCustom() }
                }
                .padding(.horizontal, 4)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: vm.useCustom)
        }
        .frame(height: 52)
    }

    private func segmentLabel(title: String, subtitle: String, active: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(active ? Theme.textPrimary : Color.chrome(0.55))
            Text(subtitle)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.chrome(active ? 0.55 : 0.4))
                .lineLimit(1)
        }
    }

    private func selectFullBalance() {
        guard vm.useCustom else { return }
        Haptics.tap()
        vm.resetToFullBalance()
        customAmountText = ""
        syncAllocationTexts()
    }

    private func selectCustom() {
        guard !vm.useCustom else { return }
        Haptics.tap()
        vm.useCustom = true
        // Default custom amount to current balance unless user already had one.
        if vm.amountCents == 0 { vm.amountCents = vm.totalBalanceCents }
        vm.amountCents = min(vm.amountCents, vm.totalBalanceCents)
        customAmountText = formattedAmountText(cents: vm.amountCents)
        // Seed allocations with apply-to-oldest as a sensible default.
        vm.applyToOldest()
        syncAllocationTexts()
    }

    private var allocationToolbar: some View {
        HStack(spacing: 8) {
            shortcutButton(icon: "equal", label: "Split evenly") {
                Haptics.tap()
                vm.splitEvenly()
                syncAllocationTexts()
            }
            shortcutButton(icon: "calendar.badge.exclamationmark", label: "Oldest first") {
                Haptics.tap()
                vm.applyToOldest()
                syncAllocationTexts()
            }
        }
    }

    private func shortcutButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.chrome(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.premiumCard))
            .overlay(Capsule().stroke(Color.chrome(0.08), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private var allocationProgress: some View {
        let balanced = vm.allocatedTotalCents == vm.amountCents && vm.amountCents > 0
        let tint: Color = balanced ? Color(hex: 0x4CB58C) : Color(hex: 0xE8B454)
        return HStack(spacing: 8) {
            Image(systemName: balanced ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
            Text("Allocated \(Fmt.currency(vm.allocatedTotalCents)) of \(Fmt.currency(vm.amountCents))")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !balanced {
                let diff = vm.amountCents - vm.allocatedTotalCents
                Text(diff > 0 ? "+\(Fmt.currency(diff)) to go" : "\(Fmt.currency(-diff)) over")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: balanced)
    }

    private var customAmountField: some View {
        HStack(spacing: 10) {
            Text("PAY")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.chrome(0.45))
            Spacer()
            Text("$")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.chrome(0.45))
            TextField("0.00", text: $customAmountText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: customAmountText) { _, new in
                    vm.amountCents = parseCents(new, cap: vm.totalBalanceCents)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6))
    }

    private var chargesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("APPLIES TO")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.chrome(0.45))
                Text(vm.useCustom ? "· Split across" : "· All charges")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.chrome(0.4))
                Spacer()
            }
            .padding(.top, 4)
            VStack(spacing: 8) {
                ForEach(vm.chargesOldestFirst) { c in
                    chargeRow(c)
                }
            }
            if !vm.useCustom {
                Text("Applied to all \(vm.charges.count) charge\(vm.charges.count == 1 ? "" : "s") · \(Fmt.currency(vm.totalBalanceCents)) total")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.5))
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func chargeRow(_ c: CommonCharge) -> some View {
        let cents = Int((c.amount ?? 0).rounded())
        let due = Fmt.parseDay(c.due_date) ?? Fmt.parseDate(c.due_date)
        let overdue = (due.map { $0 < Date() } ?? false) && cents > 0
        let dotColor = categoryDotColor(for: c.description)
        let allocCents = vm.allocations[c.id] ?? 0
        let isInPlan = !vm.useCustom || allocCents > 0
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.chrome(0.1), lineWidth: 0.5))
                .opacity(isInPlan ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 4) {
                Text(c.description ?? "Common charge")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let dd = due {
                        Text("Due \(Fmt.short(dd))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.5))
                    }
                    if overdue {
                        Text("OVERDUE")
                            .font(.system(size: 9.5, weight: .heavy))
                            .tracking(0.7)
                            .foregroundStyle(Color(hex: 0xF26A6A))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(hex: 0xF26A6A).opacity(0.14)))
                    }
                }
            }
            Spacer(minLength: 8)
            if vm.useCustom {
                allocationField(for: c, cap: cents)
            } else {
                Text(Fmt.currency(cents))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.chrome(isInPlan ? 0.08 : 0.04), lineWidth: 0.6)
        )
        .opacity(isInPlan ? 1 : 0.6)
        .animation(.easeInOut(duration: 0.18), value: isInPlan)
    }

    private func allocationField(for c: CommonCharge, cap: Int) -> some View {
        let binding = Binding<String>(
            get: { allocationTexts[c.id] ?? formattedAmountText(cents: vm.allocations[c.id] ?? 0) },
            set: { new in
                allocationTexts[c.id] = new
                let cents = parseCents(new, cap: cap)
                vm.setAllocation(chargeId: c.id, cents: cents)
            }
        )
        return HStack(spacing: 2) {
            Text("$")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.chrome(0.4))
            TextField("0", text: binding)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 60, maxWidth: 92)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.chrome(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.chrome(0.08), lineWidth: 0.6)
        )
    }

    private func categoryDotColor(for description: String?) -> Color {
        let s = (description ?? "").lowercased()
        if s.contains("assessment") { return Color(hex: 0xC084FC) }
        if s.contains("monthly") || s.contains("common") { return Color(hex: 0xFF9A2F) }
        if s.contains("late") || s.contains("fee") { return Color(hex: 0xF26A6A) }
        return Color(hex: 0x4CB58C)
    }

    private func syncAllocationTexts() {
        var next: [String: String] = [:]
        for c in vm.charges {
            let cents = vm.allocations[c.id] ?? 0
            next[c.id] = formattedAmountText(cents: cents)
        }
        allocationTexts = next
    }

    private var continueBar: some View {
        let valid = vm.amountCents > 0 && vm.amountCents <= vm.totalBalanceCents && vm.isAllocationBalanced
        let chargeCount = vm.useCustom ? vm.activeAllocations.count : vm.charges.count
        return Button {
            Haptics.tap()
            onContinue()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue")
                        .font(.system(size: 16, weight: .semibold))
                    if chargeCount > 0 {
                        Text("Across \(chargeCount) charge\(chargeCount == 1 ? "" : "s")")
                            .font(.system(size: 10.5, weight: .medium))
                            .opacity(0.85)
                    }
                }
                Spacer()
                Text(Fmt.currency(vm.amountCents))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 14, y: 6)
            .opacity(valid ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!valid)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func parseCents(_ s: String, cap: Int) -> Int {
        let cleaned = s.filter { "0123456789.".contains($0) }
        guard let dollars = Double(cleaned) else { return 0 }
        let cents = Int((dollars * 100).rounded())
        return max(0, min(cents, cap))
    }

    private func formattedAmountText(cents: Int) -> String {
        guard cents > 0 else { return "" }
        return String(format: "%.2f", Double(cents) / 100.0)
    }
}

// MARK: - Step 2: Method picker

private struct PayMethodStep: View {
    @Bindable var vm: PayFlowViewModel
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            AtmosphericBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pay with")
                            .font(.system(size: 24, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Choose a saved method or add a new one")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                    .padding(.top, 4)

                    if vm.loadingMethods && vm.methods.isEmpty {
                        loadingCard
                    } else if let err = vm.methodsError, vm.methods.isEmpty {
                        errorCard(err) { Task { await vm.loadMethods() } }
                    }

                    if !vm.methods.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(vm.methods) { methodRow($0) }
                        }
                    }

                    VStack(spacing: 10) {
                        addMethodButton(
                            icon: "building.columns",
                            title: "Add bank account",
                            subtitle: "Pay with ACH — usually cheaper",
                            loading: vm.loadingAddFlow && vm.presentingAddBank == false && vm.plaidLinkToken == nil
                        ) {
                            Haptics.tap()
                            Task { await vm.startAddBank() }
                        }
                        addMethodButton(
                            icon: "creditcard",
                            title: "Add debit or credit card",
                            subtitle: "Tap to enter card details securely",
                            loading: vm.loadingAddFlow && vm.presentingAddCard == false && vm.moovDropsToken == nil
                        ) {
                            Haptics.tap()
                            Task { await vm.startAddCard() }
                        }
                    }

                    if let err = vm.addFlowError {
                        Text(err)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.danger)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .safeAreaInset(edge: .bottom) { continueBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if vm.methods.isEmpty { await vm.loadMethods() } }
        .sheet(isPresented: $vm.presentingAddBank) {
            if let token = vm.plaidLinkToken {
                PlaidLinkView(
                    linkToken: token,
                    onSuccess: { pub, acc, meta in
                        vm.presentingAddBank = false
                        Task { await vm.handlePlaidSuccess(publicToken: pub, accountId: acc, metadata: meta) }
                    },
                    onExit: { err in
                        vm.presentingAddBank = false
                        if let err { vm.addFlowError = err }
                    }
                )
                .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $vm.presentingAddCard) {
            if let drops = vm.moovDropsToken {
                MoovDropsView(
                    oauthToken: drops.token,
                    accountId: drops.accountId,
                    onSuccess: { pmid, brand, last4 in
                        vm.presentingAddCard = false
                        vm.handleCardAdded(paymentMethodId: pmid, brand: brand, last4: last4)
                    },
                    onCancel: { vm.presentingAddCard = false },
                    onError: { msg in
                        vm.presentingAddCard = false
                        vm.addFlowError = msg
                    }
                )
            }
        }
    }

    private func methodRow(_ m: MoovPaymentMethod) -> some View {
        let selected = (vm.selectedMethod?.payment_method_id == m.payment_method_id)
        return Button {
            Haptics.tap()
            vm.selectedMethod = m
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.chrome(0.06))
                    Image(systemName: m.isCard ? "creditcard.fill" : "building.columns.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.displayLabel)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(m.isCard ? "Card" : "Bank account · ACH")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.chrome(0.5))
                }
                Spacer()
                ZStack {
                    Circle().stroke(Color.chrome(0.2), lineWidth: 1.4)
                    if selected {
                        Circle().fill(Theme.textPrimary).frame(width: 10, height: 10)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.textPrimary.opacity(0.5) : Color.chrome(0.06), lineWidth: selected ? 1.0 : 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    private func addMethodButton(icon: String, title: String, subtitle: String, loading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.chrome(0.05))
                    if loading {
                        ProgressView().scaleEffect(0.7).tint(Theme.textPrimary)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.chrome(0.5))
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.chrome(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private var continueBar: some View {
        Button {
            Haptics.tap()
            onContinue()
        } label: {
            HStack {
                Text("Review payment")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 14, y: 6)
            .opacity(vm.selectedMethod == nil ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(vm.selectedMethod == nil)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.textPrimary)
            Text("Loading your payment methods…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.chrome(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
    }

    private func errorCard(_ msg: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(msg)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.danger)
            Button("Try again") { Haptics.tap(); retry() }
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
    }
}

// MARK: - Step 3: Review

private struct PayReviewStep: View {
    @Bindable var vm: PayFlowViewModel

    var body: some View {
        ZStack {
            AtmosphericBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review")
                            .font(.system(size: 24, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Confirm before we charge your method")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                    .padding(.top, 4)

                    methodCard

                    breakdownCard

                    if let err = vm.previewError {
                        Text(err)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.danger)
                    }
                    if let err = vm.submitError {
                        Text(err)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.danger)
                    }

                    if vm.preview?.sandbox == true {
                        sandboxBadge
                    }

                    Spacer(minLength: 100)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .safeAreaInset(edge: .bottom) { payBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadPreview() }
    }

    private var methodCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.chrome(0.06))
                Image(systemName: (vm.selectedMethod?.isCard ?? true) ? "creditcard.fill" : "building.columns.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.selectedMethod?.displayLabel ?? "—")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text((vm.selectedMethod?.isCard ?? true) ? "Card" : "Bank account · ACH")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6))
    }

    private var breakdownCard: some View {
        VStack(spacing: 12) {
            breakdownRow("Amount", value: Fmt.currency(vm.preview?.baseCents ?? vm.amountCents))
            breakdownRow("Processing fee", value: vm.previewing ? "…" : Fmt.currency(vm.preview?.feeCents ?? 0))
            Divider().background(Color.chrome(0.08))
            HStack {
                Text("Total")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if vm.previewing {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text(Fmt.currency(vm.preview?.totalCents ?? vm.amountCents))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.chrome(0.06), lineWidth: 0.6))
    }

    private func breakdownRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.chrome(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var sandboxBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "testtube.2")
                .font(.system(size: 11, weight: .bold))
            Text("Sandbox mode")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.6)
        }
        .foregroundStyle(Theme.warning)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.warning.opacity(0.14)))
    }

    private var payBar: some View {
        let total = vm.preview?.totalCents ?? vm.amountCents
        let disabled = vm.previewing || vm.submitting || vm.selectedMethod == nil
        return Button {
            Haptics.tap()
            Task { await vm.submit() }
        } label: {
            HStack {
                if vm.submitting {
                    ProgressView().tint(.white)
                } else {
                    Text("Pay \(Fmt.currency(total))")
                        .font(.system(size: 16, weight: .semibold))
                }
                Spacer()
                if !vm.submitting {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 14, y: 6)
            .opacity(disabled ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - Step 4: Success

private struct PaySuccessStep: View {
    let vm: PayFlowViewModel
    let onDone: () -> Void

    var body: some View {
        ZStack {
            AtmosphericBackground()
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle().fill(Theme.success.opacity(0.16)).frame(width: 92, height: 92)
                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Theme.success)
                }
                Text("Payment sent")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                Text(Fmt.currency(vm.aggregateTotalCents > 0 ? vm.aggregateTotalCents : (vm.result?.totalCents ?? vm.amountCents)))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .tracking(-0.8)
                if let id = vm.result?.groupId, !id.isEmpty {
                    Text("Confirmation #\(String(id.prefix(8)).uppercased())")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .textSelection(.enabled)
                }
                Text(vm.selectedMethod?.isACH == true
                     ? "Bank transfers usually settle in 1–3 business days."
                     : "Your card was charged successfully.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                Spacer()
                Button {
                    Haptics.tap()
                    onDone()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Capsule().fill(Theme.textPrimary)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}
