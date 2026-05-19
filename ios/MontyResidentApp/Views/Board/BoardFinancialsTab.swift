import SwiftUI

@MainActor
@Observable
final class BoardFinancialsViewModel {
    var totals: ArAgingTotals = ArAgingTotals()
    var units: [ArAgingUnit] = []
    var loading: Bool = true
    var error: String?
    private var lastPropertyId: String?

    func load(propertyId: String, force: Bool = false) async {
        if !force, lastPropertyId == propertyId, !units.isEmpty {
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            let result = try await MontyResidentAppService.fetchBoardArAging(propertyId: propertyId)
            totals = result.totals
            units = result.units
            lastPropertyId = propertyId
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct BoardFinancialsTab: View {
    let propertyId: String?
    @State private var vm = BoardFinancialsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.loading && vm.units.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if let err = vm.error, vm.units.isEmpty {
                errorCard(err)
            } else {
                summaryCard
                kpiChips
                unitsList
            }
        }
        .task(id: propertyId) {
            guard let pid = propertyId, !pid.isEmpty else { return }
            await vm.load(propertyId: pid)
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AR AGING")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.chrome(0.50))
                Spacer()
                Text(Fmt.currency(vm.totals.grand))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
            }
            bucketRow("Current", cents: vm.totals.current, accent: Theme.success)
            bucketRow("1–30 days", cents: vm.totals.bucket1to30, accent: Theme.accentBlue)
            bucketRow("31–60 days", cents: vm.totals.bucket31to60, accent: Theme.accentAmber)
            bucketRow("61–90 days", cents: vm.totals.bucket61to90, accent: Color(hex: 0xE76F51))
            bucketRow("90+ days", cents: vm.totals.bucket90plus, accent: Theme.danger)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.premiumCard)
                RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6)
            }
        )
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: Theme.cardDropShadow, radius: 10, y: 4)
    }

    private func bucketRow(_ label: String, cents: Int, accent: Color) -> some View {
        let pct: Double = vm.totals.grand > 0 ? Double(cents) / Double(vm.totals.grand) : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7)
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Text(Fmt.currency(cents))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.chrome(0.06))
                    RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.75))
                        .frame(width: max(2, geo.size.width * pct))
                }
            }
            .frame(height: 5)
        }
    }

    // MARK: - KPI chips

    private var kpiChips: some View {
        HStack(spacing: 10) {
            kpiChip("In Arrears", value: "\(vm.totals.unitsInArrears)", color: Theme.accentBlue)
            kpiChip("Severe", value: "\(vm.totals.severeUnits)", color: Theme.accentAmber)
            kpiChip("Lien Eligible", value: "\(vm.totals.lienEligibleCount)", color: Theme.danger)
        }
    }

    private func kpiChip(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .heavy))
                .tracking(1.0)
                .foregroundStyle(Color.chrome(0.55))
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.18), lineWidth: 0.8)
        )
    }

    // MARK: - Per-unit list

    @ViewBuilder
    private var unitsList: some View {
        if vm.units.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.success)
                Text("No outstanding balances")
                    .font(.system(size: 15, weight: .semibold))
                Text("All units are current.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
            }
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard)
            )
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("UNITS IN ARREARS")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color.chrome(0.50))
                    Spacer()
                    Text("\(vm.units.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.chrome(0.45))
                }
                VStack(spacing: 8) {
                    ForEach(vm.units) { u in
                        unitRow(u)
                    }
                }
            }
        }
    }

    private func unitRow(_ u: ArAgingUnit) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(u.unitLabel.hasPrefix("Unit") ? u.unitLabel : "Unit \(u.unitLabel)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if u.isLienEligible {
                        Text("LIEN ELIGIBLE")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.danger.opacity(0.14)))
                    }
                }
                if u.daysOverdue > 0 {
                    Text("\(u.daysOverdue) days overdue")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.currency(u.total))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                if u.bucket90plus > 0 {
                    Text("\(Fmt.currency(u.bucket90plus)) 90+")
                        .font(.system(size: 10.5, weight: .heavy))
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(u.isLienEligible ? Theme.danger.opacity(0.30) : Color.chrome(0.06), lineWidth: 0.8)
            }
        )
        .clipShape(.rect(cornerRadius: 14))
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't load financials")
                .font(.system(size: 15, weight: .semibold))
            Text(msg)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.chrome(0.55))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6))
    }
}
