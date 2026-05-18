import SwiftUI
import UIKit

enum CommunityDateFilter: String, CaseIterable, Hashable {
    case all, day, week, month

    var label: String {
        switch self {
        case .all: return "All"
        case .day: return "24h"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    func cutoff() -> Date? {
        let now = Date()
        switch self {
        case .all: return nil
        case .day: return now.addingTimeInterval(-86_400)
        case .week: return now.addingTimeInterval(-7 * 86_400)
        case .month: return now.addingTimeInterval(-30 * 86_400)
        }
    }
}

@MainActor
@Observable
final class CommunityPostsViewModel {
    var posts: [ForumPost] = []
    var search: String = ""
    var dateFilter: CommunityDateFilter = .all
    var loading = true
    var error: String?

    func load(propertyId: String, categoryId: String) async {
        loading = true; error = nil
        do {
            posts = try await CommunityService.fetchPosts(propertyId: propertyId, categoryId: categoryId)
        } catch {
            self.error = "We couldn't load posts. Pull to retry."
        }
        loading = false
    }

    var filtered: [ForumPost] {
        let cutoff = dateFilter.cutoff()
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return posts
            .filter { p in
                if let cutoff, let d = Fmt.parseDate(p.created_at), d < cutoff { return false }
                if !q.isEmpty {
                    let hay = ((p.title ?? "") + " " + (p.content ?? "")).lowercased()
                    if !hay.contains(q) { return false }
                }
                return true
            }
            .sorted { (a, b) in
                let da = Fmt.parseDate(a.created_at) ?? .distantPast
                let db = Fmt.parseDate(b.created_at) ?? .distantPast
                return da > db
            }
    }

    func count(for f: CommunityDateFilter) -> Int {
        let cutoff = f.cutoff()
        return posts.filter { p in
            if let cutoff, let d = Fmt.parseDate(p.created_at), d < cutoff { return false }
            return true
        }.count
    }
}

struct CommunityPostsView: View {
    let categoryId: String
    let categoryName: String

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CommunityPostsViewModel()
    @State private var showCreate = false

    private let horizontalPadding: CGFloat = 16

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showCreate) {
            CreatePostSheet(categoryId: categoryId, categoryName: categoryName) {
                Task { await reload() }
            }
        }
        .task(id: app.activeUnitId) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.posts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    searchField
                    filterBar
                    ForEach(0..<5, id: \.self) { _ in skeletonRow }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
        } else if let err = vm.error, vm.posts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ZStack {
                        premiumCardBackground(radius: 18)
                        ErrorState(message: err) { Task { await reload() } }
                            .padding(.vertical, 8)
                    }
                    .clipShape(.rect(cornerRadius: 18))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
            }
            .refreshable { await reload() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    searchField
                    filterBar.padding(.bottom, 4)

                    if vm.filtered.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(vm.filtered, id: \.id) { post in
                                if post.is_removed == true {
                                    removedRow
                                } else {
                                    NavigationLink(value: HomeRoute.communityPost(postId: post.id)) {
                                        postRow(post)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                    .simultaneousGesture(TapGesture().onEnded {
                                        Haptics.tap()
                                    })
                                }
                            }
                        }
                    }
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
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(categoryName)
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("Community · \(app.activeUnit?.property?.name ?? "Your building")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                newPostButton
                    .padding(.bottom, 2)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    private var backButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("Community")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.premiumCard))
            .overlay(Capsule().stroke(Color.chrome(0.08), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private var newPostButton: some View {
        Button {
            Haptics.tap()
            showCreate = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                Text("New")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.premiumCard))
            .overlay(Capsule().stroke(Color.chrome(0.10), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search & filter

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.chrome(0.45))
            TextField("", text: Bindable(vm).search, prompt: Text("Search posts").foregroundStyle(Color.chrome(0.4)))
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .tint(Color(hex: 0xFF9A2F))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !vm.search.isEmpty {
                Button {
                    vm.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.chrome(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.premiumCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.chrome(0.06), lineWidth: 0.6)
        )
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CommunityDateFilter.allCases, id: \.self) { f in
                    filterPill(f)
                }
            }
        }
    }

    private func filterPill(_ f: CommunityDateFilter) -> some View {
        let isActive = vm.dateFilter == f
        return Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                vm.dateFilter = f
            }
        } label: {
            Text(filterLongLabel(f))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? .white : Color.chrome(0.62))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    ZStack {
                        if isActive {
                            Capsule().fill(Color.chrome(0.10))
                        } else {
                            Capsule().fill(Theme.premiumCard)
                        }
                    }
                )
                .overlay(
                    Capsule().stroke(
                        isActive ? Color.chrome(0.16) : Color.chrome(0.08),
                        lineWidth: 0.6
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func filterLongLabel(_ f: CommunityDateFilter) -> String {
        switch f {
        case .all: return "All time"
        case .day: return "Last 24h"
        case .week: return "Last week"
        case .month: return "Last month"
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            premiumCardBackground(radius: 18)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.chrome(0.04))
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Color.chrome(0.62))
                }
                .frame(width: 56, height: 56)

                VStack(spacing: 4) {
                    Text("No posts yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Be the first to start a conversation here.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                Button {
                    Haptics.tap()
                    showCreate = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("New post")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                    )
                    .shadow(color: Color(hex: 0xFF6A00).opacity(0.4), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity)
        }
        .clipShape(.rect(cornerRadius: 18))
        .padding(.top, 12)
    }

    // MARK: - Rows

    private var removedRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.chrome(0.45))
                Text("[Removed by staff]")
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(Color.chrome(0.45))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .clipShape(.rect(cornerRadius: 16))
    }

    private func postRow(_ p: ForumPost) -> some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(alignment: .top, spacing: 12) {
                avatar(for: p.author?.displayName, size: 36)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    if p.is_pinned == true {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: 0xD9A441))
                                .frame(width: 5, height: 5)
                            Text("PINNED")
                                .font(.system(size: 9.5, weight: .heavy))
                                .tracking(0.9)
                                .foregroundStyle(Color(hex: 0xD9A441))
                        }
                    }

                    Text(p.title ?? "Post")
                        .font(.system(size: 15.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let c = p.content, !c.isEmpty {
                        Text(c)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.chrome(0.55))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let urls = p.image_urls, !urls.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { _, s in
                                thumb(s)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 4)
                    }

                    metaRow(p).padding(.top, 4)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.chrome(0.32))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    private func metaRow(_ p: ForumPost) -> some View {
        HStack(spacing: 6) {
            Text(p.author?.displayName ?? "Resident")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.chrome(0.7))
                .lineLimit(1)
            if p.show_unit == true, let u = p.unit_number, !u.isEmpty {
                bullet
                Text("Unit \(u)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.chrome(0.45))
                    .lineLimit(1)
            }
            bullet
            Text(Fmt.relative(Fmt.parseDate(p.created_at)))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.chrome(0.45))
                .lineLimit(1)
            bullet
            Image(systemName: "bubble.right")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.chrome(0.45))
            Text("\(p.comment_count ?? 0)")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.chrome(0.55))
            Spacer(minLength: 0)
        }
    }

    private var bullet: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(Color.chrome(0.35))
    }

    private func thumb(_ urlString: String) -> some View {
        Color.chrome(0.04)
            .frame(width: 56, height: 56)
            .overlay {
                if let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.chrome(0.35))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.chrome(0.06), lineWidth: 0.6)
            )
    }

    private func avatar(for name: String?, size: CGFloat) -> some View {
        let initials: String = {
            let comps = (name ?? "").split(separator: " ").prefix(2)
            let s = comps.compactMap { $0.first.map(String.init) }.joined()
            return s.isEmpty ? "•" : s.uppercased()
        }()
        return ZStack {
            Circle().fill(Color.chrome(0.08))
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Skeleton

    private var skeletonRow: some View {
        ZStack {
            premiumCardBackground(radius: 16)
            HStack(spacing: 12) {
                Circle().fill(Color.chrome(0.05))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.08))
                        .frame(height: 12).frame(maxWidth: 200, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.05))
                        .frame(height: 10).frame(maxWidth: 240, alignment: .leading)
                    RoundedRectangle(cornerRadius: 4).fill(Color.chrome(0.04))
                        .frame(height: 8).frame(maxWidth: 140, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .frame(height: 110)
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

    private func reload() async {
        guard let pid = app.activePropertyId else {
            vm.loading = false
            return
        }
        await vm.load(propertyId: pid, categoryId: categoryId)
    }
}
