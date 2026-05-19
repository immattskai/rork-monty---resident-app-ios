import SwiftUI
import Charts

@MainActor
@Observable
final class BoardSnapshotViewModel {
    var data: BoardSnapshotData = BoardSnapshotData()
    var loading: Bool = true
    var error: String?
    var rangeDays: Int = 30
    private var lastKey: String?

    func load(propertyId: String, rangeDays: Int, force: Bool = false) async {
        let key = "\(propertyId)|\(rangeDays)"
        if !force, lastKey == key, !loading { return }
        self.rangeDays = rangeDays
        loading = true
        error = nil
        do {
            data = try await MontyResidentAppService.fetchBoardSnapshot(propertyId: propertyId, rangeDays: rangeDays)
            lastKey = key
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
    @State private var rangeDays: Int = 30

    private static let ranges: [Int] = [7, 30, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rangeSelector
            if vm.loading && vm.data.totalUnits == 0 && vm.data.weeklyVolume.isEmpty {
                skeleton
            } else {
                if let err = vm.error {
                    errorBanner(err)
                }
                kpiGrid
                volumeChartCard
                resolutionChartCard
                priorityDonutCard
            }
        }
        .task(id: propertyId) {
            guard let pid = propertyId, !pid.isEmpty else { return }
            await vm.load(propertyId: pid, rangeDays: rangeDays)
        }
        .task(id: rangeDays) {
            guard let pid = propertyId, !pid.isEmpty else { return }
            await vm.load(propertyId: pid, rangeDays: rangeDays)
        }
    }

    // MARK: - Range selector

    private var rangeSelector: some View {
        HStack(spacing: 6) {
            ForEach(Self.ranges, id: \.self) { d in
                let active = d == rangeDays
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.18)) { rangeDays = d }
                } label: {
                    Text("\(d)d")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(active ? Theme.accentBlue : Color.chrome(0.06))
                        )
                        .overlay(
                            Capsule().stroke(active ? Color.clear : Color.chrome(0.08), lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if vm.loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.chrome(0.55))
            }
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
                title: "Open Work Orders",
                value: "\(vm.data.openTickets)",
                subtitle: workOrdersSubline,
                accent: Theme.accentAmber,
                delta: vm.data.openTicketsDelta,
                deltaInvert: true
            )
            kpiCard(
                title: "Avg Resolution",
                value: vm.data.avgResolutionHours > 0 ? formatHours(vm.data.avgResolutionHours) : "N/A",
                subtitle: "Resolved · last \(rangeDays)d",
                accent: Theme.success,
                delta: nil,
                customSubline: resolutionDeltaText
            )
            kpiCard(
                title: "Board Tasks",
                value: "\(vm.data.openBoardTasks)",
                subtitle: "Open action items",
                accent: Color(hex: 0xAF7DFF),
                delta: nil,
                onTap: { onJumpToTab(.tasks) }
            )
        }
    }

    private var workOrdersSubline: String {
        let u = vm.data.urgentTickets
        let h = vm.data.highTickets
        if u == 0 && h == 0 { return "Last \(rangeDays) days" }
        return "\(u) urgent · \(h) high"
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
            Text("\(abs(delta)) vs prev \(rangeDays)d")
                .font(.system(size: 10.5, weight: .heavy))
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func formatHours(_ h: Double) -> String {
        if h <= 0 { return "N/A" }
        if h < 1 { return String(format: "%.0fm", h * 60) }
        if h < 24 { return String(format: "%.1fh", h) }
        let days = Int(h / 24)
        let rem = Int(h.truncatingRemainder(dividingBy: 24).rounded())
        return rem == 0 ? "\(days)d" : "\(days)d \(rem)h"
    }

    // MARK: - Charts

    private var volumeChartCard: some View {
        chartCard(title: "Ticket Volume") {
            if vm.data.weeklyVolume.allSatisfy({ $0.count == 0 }) {
                emptyChartLabel("No tickets in the last \(rangeDays) days")
            } else {
                Chart(vm.data.weeklyVolume) { row in
                    BarMark(
                        x: .value("Bucket", row.weekStart, unit: vm.data.bucketUnit),
                        y: .value("Tickets", row.count)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(Theme.accentBlue.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: vm.data.bucketUnit)) { _ in
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
                .frame(height: 150)
            }
        }
    }

    private var resolutionChartCard: some View {
        chartCard(title: "Avg Resolution Time") {
            let nonZero = vm.data.resolutionWeekly.filter { $0.avgHours > 0 }
            if nonZero.isEmpty {
                emptyChartLabel("No resolved tickets in the last \(rangeDays) days")
            } else {
                Chart(vm.data.resolutionWeekly) { row in
                    LineMark(
                        x: .value("Bucket", row.weekStart, unit: vm.data.bucketUnit),
                        y: .value("Hours", row.avgHours)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.success.gradient)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    AreaMark(
                        x: .value("Bucket", row.weekStart, unit: vm.data.bucketUnit),
                        y: .value("Hours", row.avgHours)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.success.opacity(0.22), Theme.success.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    PointMark(
                        x: .value("Bucket", row.weekStart, unit: vm.data.bucketUnit),
                        y: .value("Hours", row.avgHours)
                    )
                    .symbolSize(28)
                    .foregroundStyle(Theme.success)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: vm.data.bucketUnit)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(Color.chrome(0.08))
                        AxisValueLabel(format: Decimal.FormatStyle.number.precision(.fractionLength(0)))
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .frame(height: 150)
            }
        }
    }

    private var priorityDonutCard: some View {
        chartCard(title: "Work Orders by Priority") {
            let total = vm.data.priorityBuckets.reduce(0) { $0 + $1.count }
            if total == 0 {
                emptyChartLabel("No open tickets in the last \(rangeDays) days")
            } else {
                HStack(alignment: .center, spacing: 18) {
                    Chart(vm.data.priorityBuckets) { row in
                        SectorMark(
                            angle: .value("Count", row.count),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("Priority", row.priority))
                    }
                    .chartForegroundStyleScale([
                        "urgent": Theme.danger,
                        "high": Theme.accentAmber,
                        "medium": Theme.accentBlue,
                        "low": Color.chrome(0.40)
                    ])
                    .chartLegend(.hidden)
                    .frame(width: 130, height: 130)
                    .overlay {
                        VStack(spacing: 2) {
                            Text("\(total)")
                                .font(.system(size: 22, weight: .bold))
                                .tracking(-0.5)
                                .foregroundStyle(Theme.textPrimary)
                            Text("open")
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(1.0)
                                .foregroundStyle(Color.chrome(0.50))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.data.priorityBuckets) { b in
                            legendRow(priority: b.priority, count: b.count, total: total)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func legendRow(priority: String, count: Int, total: Int) -> some View {
        let color: Color = {
            switch priority {
            case "urgent": return Theme.danger
            case "high": return Theme.accentAmber
            case "medium": return Theme.accentBlue
            default: return Color.chrome(0.40)
            }
        }()
        let pct = total > 0 ? Int((Double(count) / Double(total) * 100).rounded()) : 0
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(priority.capitalized)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Text("\(pct)%")
                .font(.system(size: 10.5, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(Color.chrome(0.50))
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
            RoundedRectangle(cornerRadius: 18).fill(Color.chrome(0.05)).frame(height: 180)
        }
        .redacted(reason: .placeholder)
    }

    private var skeletonCell: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.chrome(0.05))
            .frame(height: 110)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't load some data")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(msg)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.55))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.danger.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.danger.opacity(0.25), lineWidth: 0.6)
        )
    }
}
