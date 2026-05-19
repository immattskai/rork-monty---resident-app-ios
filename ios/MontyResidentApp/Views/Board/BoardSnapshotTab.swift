import SwiftUI
import Charts

@MainActor
@Observable
final class BoardSnapshotViewModel {
    var data: BoardSnapshotData = BoardSnapshotData()
    var loading: Bool = true
    var error: String?
    private var lastPropertyId: String?

    func load(propertyId: String, force: Bool = false) async {
        if !force, lastPropertyId == propertyId, !loading { return }
        loading = true
        error = nil
        do {
            data = try await MontyResidentAppService.fetchBoardSnapshot(propertyId: propertyId)
            lastPropertyId = propertyId
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct BoardSnapshotTab: View {
    let propertyId: String?
    var onJumpToTab: (BoardTab) -> Void = { _ in }

    @State private var vm = BoardSnapshotViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if vm.loading && vm.data.totalUnits == 0 && vm.data.weeklyVolume.isEmpty {
                skeleton
            } else if let err = vm.error, vm.data.totalUnits == 0 {
                errorCard(err)
            } else {
                kpiGrid
                volumeChartCard
                priorityChartCard
            }
        }
        .task(id: propertyId) {
            guard let pid = propertyId, !pid.isEmpty else { return }
            await vm.load(propertyId: pid)
        }
    }

    // MARK: - KPIs

    private var kpiGrid: some View {
        let columns: [GridItem] = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            kpiCard(
                title: "Occupancy",
                value: vm.data.totalUnits == 0 ? "—" : "\(Int(vm.data.occupancyPct.rounded()))%",
                subtitle: vm.data.totalUnits == 0 ? "No units" : "\(vm.data.occupiedUnits)/\(vm.data.totalUnits) occupied",
                accent: Theme.accentBlue,
                delta: nil
            )
            kpiCard(
                title: "Open Tickets",
                value: "\(vm.data.openTickets)",
                subtitle: "Last 30 days",
                accent: Theme.accentAmber,
                delta: vm.data.openTicketsDelta,
                deltaInvert: true,
                onTap: { onJumpToTab(.snapshot) }
            )
            kpiCard(
                title: "Avg Resolution",
                value: vm.data.avgResolutionHours > 0 ? "\(formatHours(vm.data.avgResolutionHours))" : "—",
                subtitle: "Resolved tickets",
                accent: Theme.success,
                delta: nil,
                customSubline: resolutionDeltaText
            )
            kpiCard(
                title: "Board Tasks",
                value: "\(vm.data.openBoardTasks)",
                subtitle: tasksSubline,
                accent: Color(hex: 0xAF7DFF),
                delta: nil,
                onTap: { onJumpToTab(.tasks) }
            )
        }
    }

    private var tasksSubline: String {
        let b = vm.data.taskByStatus["backlog"] ?? 0
        let t = vm.data.taskByStatus["todo"] ?? 0
        let p = vm.data.taskByStatus["in_progress"] ?? 0
        if b + t + p == 0 { return "No open tasks" }
        return "\(b) backlog · \(t) todo · \(p) wip"
    }

    private var resolutionDeltaText: String? {
        let d = vm.data.resolutionDelta
        guard abs(d) >= 0.5 else { return nil }
        let prefix = d < 0 ? "↓" : "↑"
        return "\(prefix) \(formatHours(abs(d))) vs prev"
    }

    @ViewBuilder
    private func kpiCard(
        title: String,
        value: String,
        subtitle: String,
        accent: Color,
        delta: Int? = nil,
        deltaInvert: Bool = false,
        customSubline: String? = nil,
        onTap: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let onTap { Haptics.tap(); onTap() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(Color.chrome(0.50))
                Text(value)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(customSubline ?? subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .lineLimit(1)
                }
                if let delta, delta != 0 {
                    deltaPill(delta: delta, invert: deltaInvert)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard)
                    RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6)
                }
            )
            .clipShape(.rect(cornerRadius: 16))
            .shadow(color: Theme.cardDropShadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private func deltaPill(delta: Int, invert: Bool) -> some View {
        let isUp = delta > 0
        let bad = invert ? isUp : !isUp
        let color: Color = bad ? Theme.danger : Theme.success
        let arrow = isUp ? "arrow.up" : "arrow.down"
        return HStack(spacing: 4) {
            Image(systemName: arrow).font(.system(size: 9, weight: .heavy))
            Text("\(abs(delta)) vs prev 30d")
                .font(.system(size: 10.5, weight: .heavy))
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func formatHours(_ h: Double) -> String {
        if h < 1 { return String(format: "%.0fm", h * 60) }
        if h < 24 { return String(format: "%.1fh", h) }
        return String(format: "%.1fd", h / 24)
    }

    // MARK: - Charts

    private var volumeChartCard: some View {
        chartCard(title: "Weekly Ticket Volume") {
            if vm.data.weeklyVolume.allSatisfy({ $0.count == 0 }) {
                emptyChartLabel("No tickets in the last 5 weeks")
            } else {
                Chart(vm.data.weeklyVolume) { row in
                    BarMark(
                        x: .value("Week", row.weekStart, unit: .weekOfYear),
                        y: .value("Tickets", row.count)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(Theme.accentBlue.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear)) { value in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.chrome(0.08))
                        AxisValueLabel().font(.system(size: 9, weight: .medium))
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private var priorityChartCard: some View {
        chartCard(title: "Tickets by Priority") {
            if vm.data.priorityBuckets.allSatisfy({ $0.count == 0 }) {
                emptyChartLabel("No tickets in the last 30 days")
            } else {
                Chart(vm.data.priorityBuckets) { row in
                    BarMark(
                        x: .value("Count", row.count),
                        y: .value("Priority", row.priority.capitalized)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Priority", row.priority))
                    .annotation(position: .trailing, alignment: .leading) {
                        if row.count > 0 {
                            Text("\(row.count)")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Color.chrome(0.65))
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "urgent": Theme.danger,
                    "high": Theme.accentAmber,
                    "medium": Theme.accentBlue,
                    "low": Color.chrome(0.40)
                ])
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .frame(height: 140)
            }
        }
    }

    @ViewBuilder
    private func chartCard<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color.chrome(0.50))
            content()
        }
        .padding(14)
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

    private func emptyChartLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color.chrome(0.55))
            .frame(maxWidth: .infinity, minHeight: 100)
            .multilineTextAlignment(.center)
    }

    // MARK: - Skeleton / error

    private var skeleton: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                skeletonCell; skeletonCell
            }
            HStack(spacing: 10) {
                skeletonCell; skeletonCell
            }
            RoundedRectangle(cornerRadius: 18).fill(Color.chrome(0.05)).frame(height: 180)
            RoundedRectangle(cornerRadius: 18).fill(Color.chrome(0.05)).frame(height: 180)
        }
    }

    private var skeletonCell: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.chrome(0.05))
            .frame(height: 110)
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't load snapshot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(msg)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.chrome(0.55))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.premiumCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6)
        )
    }
}
