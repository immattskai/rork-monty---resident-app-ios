import SwiftUI

@MainActor
@Observable
final class BoardViewModel {
    var meetings: [BoardMeeting] = []
    var loading: Bool = true
    var error: String?

    private var lastLoadedPropertyId: String?

    func load(propertyId: String, force: Bool = false) async {
        if !force, lastLoadedPropertyId == propertyId, !meetings.isEmpty {
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            meetings = try await MontyResidentAppService.fetchBoardMeetings(propertyId: propertyId)
            lastLoadedPropertyId = propertyId
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

enum BoardTab: String, CaseIterable, Hashable {
    case snapshot, meetings, tasks, financials

    var title: String {
        switch self {
        case .snapshot: return "Snapshot"
        case .meetings: return "Meetings"
        case .tasks: return "Tasks"
        case .financials: return "Financials"
        }
    }

    var icon: String {
        switch self {
        case .snapshot: return "chart.bar.xaxis"
        case .meetings: return "calendar"
        case .tasks: return "checklist"
        case .financials: return "dollarsign.circle"
        }
    }

}

struct BoardView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = BoardViewModel()
    @State private var tab: BoardTab = .snapshot
    @State private var selectedMeeting: BoardMeeting?

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: app.activeUnit?.property_id) { await reload() }
        .sheet(item: $selectedMeeting) { meeting in
            NavigationStack {
                BoardMeetingDetailView(meetingId: meeting.id, initialTitle: meeting.title)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header
                tabStrip
                tabContent
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 4)
            .padding(.bottom, 110)
        }
        .refreshable { await reload(force: true) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { backButton; Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.accentBlue.opacity(0.14))
                        Image(systemName: "building.columns")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accentBlue)
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Board")
                            .font(.system(size: 28, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Governance & oversight")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var backButton: some View {
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
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BoardTab.allCases, id: \.self) { t in
                    tabPill(t)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func tabPill(_ t: BoardTab) -> some View {
        let active = tab == t
        Button {
            Haptics.tap()
            withAnimation(.easeOut(duration: 0.22)) { tab = t }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(t.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(active ? Color.white : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? Theme.accentBlue : Color.chrome(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(active ? Color.clear : Color.chrome(0.08), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .snapshot:
            BoardSnapshotTab(propertyId: app.activePropertyId) { jumpTo in
                withAnimation(.easeOut(duration: 0.22)) { tab = jumpTo }
            }
        case .meetings:
            meetingsTab
        case .tasks:
            BoardTasksTab(propertyId: app.activePropertyId)
        case .financials:
            BoardFinancialsTab(propertyId: app.activePropertyId)
        }
    }

    // MARK: - Meetings

    @ViewBuilder
    private var meetingsTab: some View {
        if vm.loading && vm.meetings.isEmpty {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in meetingSkeleton }
            }
        } else if let err = vm.error, vm.meetings.isEmpty {
            ZStack {
                premiumCard(radius: 18)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't load meetings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(err)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(.rect(cornerRadius: 18))
        } else if vm.meetings.isEmpty {
            emptyMeetingsCard
        } else {
            let split = splitMeetings(vm.meetings)
            VStack(alignment: .leading, spacing: 18) {
                if !split.upcoming.isEmpty {
                    section("UPCOMING", count: split.upcoming.count) {
                        VStack(spacing: 10) {
                            ForEach(split.upcoming) { m in
                                MeetingRow(meeting: m)
                                    .onTapGesture {
                                        Haptics.tap()
                                        selectedMeeting = m
                                    }
                            }
                        }
                    }
                }
                if !split.past.isEmpty {
                    section("PAST", count: split.past.count) {
                        VStack(spacing: 10) {
                            ForEach(split.past) { m in
                                MeetingRow(meeting: m)
                                    .onTapGesture {
                                        Haptics.tap()
                                        selectedMeeting = m
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    private func splitMeetings(_ rows: [BoardMeeting]) -> (upcoming: [BoardMeeting], past: [BoardMeeting]) {
        let now = Date()
        var upcoming: [BoardMeeting] = []
        var past: [BoardMeeting] = []
        for m in rows {
            let status = (m.status ?? "").lowercased()
            if status == "completed" {
                past.append(m)
            } else if let d = m.scheduledDate, d < now, status != "in_progress" {
                past.append(m)
            } else {
                upcoming.append(m)
            }
        }
        upcoming.sort { (a, b) in (a.scheduledDate ?? .distantFuture) < (b.scheduledDate ?? .distantFuture) }
        past.sort { (a, b) in (a.scheduledDate ?? .distantPast) > (b.scheduledDate ?? .distantPast) }
        return (upcoming, past)
    }

    private var emptyMeetingsCard: some View {
        ZStack {
            premiumCard(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "calendar")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text("No meetings scheduled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Board meetings for your building will appear here.")
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

    private var meetingSkeleton: some View {
        ZStack {
            premiumCard(radius: 16)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10).fill(Color.chrome(0.05))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 200, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 130, alignment: .leading)
                }
                Spacer()
            }
            .padding(14)
        }
        .frame(height: 78)
    }

    // MARK: - Shared

    @ViewBuilder
    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
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
            content()
        }
    }

    @ViewBuilder
    private func premiumCard(radius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }

    private func reload(force: Bool = false) async {
        guard let pid = app.activePropertyId else {
            vm.loading = false
            return
        }
        await vm.load(propertyId: pid, force: force)
    }
}

// MARK: - Meeting row

private struct MeetingRow: View {
    let meeting: BoardMeeting

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)

            HStack(alignment: .top, spacing: 14) {
                dateBlock
                VStack(alignment: .leading, spacing: 6) {
                    Text((meeting.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Board meeting")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    if let d = meeting.scheduledDate {
                        Text(Fmt.dateTime(d))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.58))
                    }
                    statusBadge
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.chrome(0.35))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 10, x: 0, y: 4)
        .contentShape(Rectangle())
    }

    private var dateBlock: some View {
        VStack(spacing: 2) {
            Text(monthString)
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.0)
                .foregroundStyle(Theme.accentBlue)
            Text(dayString)
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: 48, height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accentBlue.opacity(0.10))
        )
    }

    private var monthString: String {
        guard let d = meeting.scheduledDate else { return "TBD" }
        return d.formatted(.dateTime.month(.abbreviated)).uppercased()
    }

    private var dayString: String {
        guard let d = meeting.scheduledDate else { return "—" }
        return d.formatted(.dateTime.day())
    }

    private var statusBadge: some View {
        let s = (meeting.status ?? "").lowercased()
        let (label, color): (String, Color) = {
            switch s {
            case "scheduled":   return ("Scheduled", Theme.accentBlue)
            case "in_progress": return ("In progress", Theme.accentAmber)
            case "completed":   return ("Completed", Theme.success)
            default:            return (s.isEmpty ? "—" : s.capitalized, Color.chrome(0.50))
            }
        }()
        return Text(label)
            .font(.system(size: 10.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
