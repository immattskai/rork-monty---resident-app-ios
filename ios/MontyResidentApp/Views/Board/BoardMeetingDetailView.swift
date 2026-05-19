import SwiftUI

@MainActor
@Observable
final class BoardMeetingDetailViewModel {
    var meeting: BoardMeetingFull?
    var agenda: [BoardAgendaItem] = []
    var notes: [BoardMeetingNote] = []
    var votes: [BoardVote] = []
    var minutes: BoardMeetingMinutes?
    var myAttendance: BoardMeetingAttendee?
    var loading: Bool = true
    var error: String?

    func load(meetingId: String) async {
        loading = true
        error = nil
        async let mT = try? await MontyResidentAppService.fetchBoardMeetingFull(id: meetingId)
        async let aT = (try? await MontyResidentAppService.fetchBoardAgenda(meetingId: meetingId)) ?? []
        async let nT = (try? await MontyResidentAppService.fetchBoardMeetingNotes(meetingId: meetingId)) ?? []
        async let vT = (try? await MontyResidentAppService.fetchBoardVotes(meetingId: meetingId)) ?? []
        async let minT = try? await MontyResidentAppService.fetchBoardMinutes(meetingId: meetingId)
        async let attT = try? await MontyResidentAppService.fetchMyMeetingAttendance(meetingId: meetingId)

        meeting = await mT ?? nil
        agenda = await aT
        notes = await nT
        votes = await vT
        minutes = await minT ?? nil
        myAttendance = await attT ?? nil
        loading = false
    }

    func setRSVP(meetingId: String, status: String) async {
        do {
            let row = try await MontyResidentAppService.upsertRSVP(meetingId: meetingId, status: status)
            myAttendance = row
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum MeetingSubTab: String, CaseIterable, Hashable {
    case agenda, notes, votes, minutes
    var title: String {
        switch self {
        case .agenda: return "Agenda"
        case .notes: return "Notes"
        case .votes: return "Votes"
        case .minutes: return "Minutes"
        }
    }
}

struct BoardMeetingDetailView: View {
    let meetingId: String
    let initialTitle: String?

    @State private var vm = BoardMeetingDetailViewModel()
    @State private var sub: MeetingSubTab = .agenda
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AtmosphericBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    rsvpBar
                    subTabs
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 60)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task { await vm.load(meetingId: meetingId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
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
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.meeting?.title ?? initialTitle ?? "Meeting")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                if let d = vm.meeting?.scheduledDate {
                    Text(Fmt.dateTime(d))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.60))
                }
                if let loc = vm.meeting?.location, !loc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11, weight: .semibold))
                        Text(loc).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.chrome(0.55))
                }
            }
        }
        .padding(.top, 4)
    }

    private var rsvpBar: some View {
        HStack(spacing: 8) {
            rsvpButton("Attending", status: "attending", color: Theme.success)
            rsvpButton("Tentative", status: "tentative", color: Theme.accentAmber)
            rsvpButton("Decline", status: "not_attending", color: Theme.danger)
        }
    }

    private func rsvpButton(_ label: String, status: String, color: Color) -> some View {
        let active = vm.myAttendance?.rsvp_status == status
        return Button {
            Haptics.tap()
            Task { await vm.setRSVP(meetingId: meetingId, status: status) }
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? Color.white : color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(active ? color : color.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    private var subTabs: some View {
        HStack(spacing: 6) {
            ForEach(MeetingSubTab.allCases, id: \.self) { t in
                let active = sub == t
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.22)) { sub = t }
                } label: {
                    Text(t.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(active ? Color.white : Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(active ? Theme.accentBlue : Color.chrome(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else {
            switch sub {
            case .agenda: agendaTab
            case .notes: notesTab
            case .votes: votesTab
            case .minutes: minutesTab
            }
        }
    }

    private var agendaTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.agenda.isEmpty {
                emptyState("No agenda items yet.")
            } else {
                ForEach(Array(vm.agenda.enumerated()), id: \.element.id) { idx, item in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.accentBlue))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title ?? "Agenda item")
                                .font(.system(size: 14, weight: .semibold))
                            if let d = item.description, !d.isEmpty {
                                Text(d)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.chrome(0.60))
                            }
                            if let m = item.duration_minutes, m > 0 {
                                Text("\(m) min")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(Color.chrome(0.50))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground())
                }
            }
        }
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.notes.isEmpty {
                emptyState("No notes yet.")
            } else {
                ForEach(vm.notes) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.author?.full_name ?? n.author?.email ?? "Board member")
                            .font(.system(size: 12, weight: .semibold))
                        Text(n.content ?? "")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.72))
                        if let c = Fmt.parseDate(n.created_at) {
                            Text(Fmt.relative(c))
                                .font(.system(size: 10.5, weight: .heavy))
                                .foregroundStyle(Color.chrome(0.45))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground())
                }
            }
        }
    }

    private var votesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.votes.isEmpty {
                emptyState("No votes recorded.")
            } else {
                ForEach(vm.votes) { v in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(v.title ?? "Vote")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            voteStatusPill(v.status ?? "pending")
                        }
                        if let d = v.description, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.chrome(0.60))
                        }
                        HStack(spacing: 10) {
                            voteCount("Yes", count: v.yes_count ?? 0, color: Theme.success)
                            voteCount("No", count: v.no_count ?? 0, color: Theme.danger)
                            voteCount("Abstain", count: v.abstain_count ?? 0, color: Color.chrome(0.50))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground())
                }
            }
        }
    }

    private func voteCount(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.chrome(0.65))
        }
    }

    private func voteStatusPill(_ s: String) -> some View {
        let color: Color = {
            switch s.lowercased() {
            case "passed": return Theme.success
            case "failed": return Theme.danger
            default: return Theme.accentAmber
            }
        }()
        return Text(s.capitalized)
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    @ViewBuilder
    private var minutesTab: some View {
        if let m = vm.minutes {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(m.approved == true ? "APPROVED" : "DRAFT")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(0.8)
                        .foregroundStyle(m.approved == true ? Theme.success : Theme.accentAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill((m.approved == true ? Theme.success : Theme.accentAmber).opacity(0.14)))
                    Spacer()
                }
                Text(m.content ?? "")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.72))
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground())
        } else {
            emptyState("Minutes haven't been published yet.")
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.chrome(0.55))
            .frame(maxWidth: .infinity, minHeight: 100)
            .multilineTextAlignment(.center)
            .padding(.vertical, 16)
            .background(cardBackground())
    }

    private func cardBackground() -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.premiumCard)
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.chrome(0.05), lineWidth: 0.6)
        }
    }
}
