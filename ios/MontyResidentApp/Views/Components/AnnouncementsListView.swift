import SwiftUI

struct AnnouncementsListView: View {
    @Environment(AppState.self) private var app
    @State private var items: [PropertyAnnouncement] = []
    @State private var loading = true
    @State private var selected: PropertyAnnouncement?
    @State private var realtime = AnnouncementsRealtime()

    var body: some View {
        ZStack {
            AtmosphericBackground().ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    if loading && items.isEmpty {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.chrome(0.04))
                                .frame(height: 84)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.chrome(0.05), lineWidth: 0.6)
                                )
                        }
                    } else if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "megaphone")
                                .font(.system(size: 26, weight: .light))
                                .foregroundStyle(Color.chrome(0.45))
                            Text("No announcements right now")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.chrome(0.55))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        ForEach(items) { ann in
                            Button {
                                selected = ann
                            } label: {
                                AnnouncementRow(ann: ann)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Announcements")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(item: $selected) { ann in
            AnnouncementDetailSheet(announcement: ann)
        }
        .task(id: app.activeUnit?.property_id) {
            await load()
            await subscribe()
        }
        .onDisappear { realtime.stop() }
    }

    private func load() async {
        guard let propertyId = app.activeUnit?.property_id else {
            loading = false
            return
        }
        loading = true
        if let res = try? await AnnouncementsService.fetchActive(propertyId: propertyId, limit: 100) {
            items = res
        }
        loading = false
    }

    private func subscribe() async {
        realtime.stop()
        guard
            let propertyId = app.activeUnit?.property_id,
            let token = SupabaseAPI.shared.session?.access_token
        else { return }
        realtime.onChange = {
            Task { @MainActor in await load() }
        }
        realtime.start(propertyId: propertyId, accessToken: token)
    }
}

private struct AnnouncementRow: View {
    let ann: PropertyAnnouncement

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.85),
                            Color(hex: 0x0E1A3A).opacity(0.95)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.premiumCard.opacity(0.55))
                )
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.chrome(0.05), lineWidth: 0.6)

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ann.title ?? "Announcement")
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .padding(.trailing, ann.isPinned ? 22 : 0)
                    if let body = ann.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.60))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(1)
                    }
                    if let d = ann.publishedDate {
                        Text(Fmt.relative(d))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.chrome(0.40))
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.chrome(0.36))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            if ann.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: 0xE7C27A))
                    .rotationEffect(.degrees(45))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color(hex: 0xE7C27A).opacity(0.12)))
                    .overlay(Circle().stroke(Color(hex: 0xE7C27A).opacity(0.30), lineWidth: 0.5))
                    .padding(10)
            }
        }
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 5)
    }
}
