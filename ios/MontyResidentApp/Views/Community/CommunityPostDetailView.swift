import SwiftUI
import UIKit

@MainActor
@Observable
final class CommunityPostDetailViewModel {
    var post: ForumPost?
    var comments: [ForumComment] = []
    var loading = true
    var error: String?

    var commentDraft: String = ""
    var commentShowUnit: Bool = false
    var sending = false
    var sendError: String?

    func load(postId: String) async {
        loading = true; error = nil
        async let postT = try? await CommunityService.fetchPost(id: postId)
        async let commentsT = try? await CommunityService.fetchComments(postId: postId)
        let p = await postT ?? nil
        let c = await commentsT ?? []
        self.post = p
        self.comments = c
        if p == nil {
            self.error = "We couldn't load this post."
        }
        loading = false
    }

    func sendComment(postId: String, unitNumber: String?) async -> Bool {
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return false }
        sending = true; sendError = nil
        defer { sending = false }
        do {
            _ = try await CommunityService.createComment(
                postId: postId,
                content: text,
                showUnit: commentShowUnit,
                unitNumber: unitNumber
            )
            commentDraft = ""
            if let fresh = try? await CommunityService.fetchComments(postId: postId) {
                comments = fresh
            }
            return true
        } catch {
            sendError = "We couldn't post your reply. Try again."
            return false
        }
    }
}

struct CommunityPostDetailView: View {
    let postId: String

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CommunityPostDetailViewModel()
    @State private var imageViewer: ImageViewerState?
    @State private var confirmDelete = false
    @State private var deletingCommentId: String?
    @FocusState private var commentFocused: Bool

    private let horizontalPadding: CGFloat = 16

    private struct ImageViewerState: Identifiable {
        let id = UUID()
        let urls: [String]
        let startIndex: Int
    }

    var body: some View {
        ZStack {
            AtmosphericBackground()
            content
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Delete this post?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deletePost() }
            }
        } message: {
            Text("This can't be undone.")
        }
        .fullScreenCover(item: $imageViewer) { state in
            ImageGalleryView(urls: state.urls, startIndex: state.startIndex)
        }
        .task { await vm.load(postId: postId) }
    }

    @ViewBuilder
    private var content: some View {
        if vm.loading && vm.post == nil {
            VStack(spacing: 12) {
                header(title: "Post", subline: "Loading…", canDelete: false)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                Spacer()
                ProgressView().tint(.white.opacity(0.7))
                Spacer()
            }
        } else if let err = vm.error, vm.post == nil {
            VStack(spacing: 12) {
                header(title: "Post", subline: nil, canDelete: false)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                ZStack {
                    premiumCardBackground(radius: 18)
                    ErrorState(message: err) { Task { await vm.load(postId: postId) } }
                        .padding(.vertical, 8)
                }
                .clipShape(.rect(cornerRadius: 18))
                .padding(.horizontal, horizontalPadding)
                Spacer()
            }
        } else if let post = vm.post {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(
                            title: post.title ?? "Post",
                            subline: postSubline(post),
                            canDelete: post.author_id == SupabaseAPI.shared.session?.user_id && post.is_removed != true
                        )

                        postBodyCard(post)

                        commentsSection
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                composer(post: post)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(title: String, subline: String?, canDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                backButton
                Spacer()
                if canDelete {
                    Menu {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete post", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.premiumCard))
                            .overlay(Circle().stroke(Color.chrome(0.08), lineWidth: 0.6))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let s = subline, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .lineLimit(1)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func postSubline(_ p: ForumPost) -> String {
        var parts: [String] = []
        parts.append(p.author?.displayName ?? "Resident")
        if p.show_unit == true, let u = p.unit_number, !u.isEmpty {
            parts.append("Unit \(u)")
        }
        parts.append(Fmt.relative(Fmt.parseDate(p.created_at)))
        return parts.joined(separator: " · ")
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

    // MARK: - Body card

    private func postBodyCard(_ p: ForumPost) -> some View {
        ZStack(alignment: .topLeading) {
            premiumCardBackground(radius: 18)
            VStack(alignment: .leading, spacing: 14) {
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

                if p.is_removed == true {
                    Text("[Removed by staff]")
                        .font(.system(size: 14))
                        .italic()
                        .foregroundStyle(Color.chrome(0.45))
                } else {
                    if let c = p.content, !c.isEmpty {
                        Text(c)
                            .font(.system(size: 15.5))
                            .lineSpacing(5)
                            .foregroundStyle(Color.chrome(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    if let urls = p.image_urls, !urls.isEmpty {
                        imagesGrid(urls)
                    }
                    if let link = p.link_url, !link.isEmpty, let u = URL(string: link) {
                        Link(destination: u) {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(link)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(Color(hex: 0x6FA8E0))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.chrome(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.chrome(0.06), lineWidth: 0.6)
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: Theme.cardDropShadow, radius: 14, x: 0, y: 6)
    }

    // MARK: - Comments

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("COMMENTS")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.chrome(0.45))
                Text("\(vm.comments.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.chrome(0.45))
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            if vm.comments.isEmpty {
                ZStack {
                    premiumCardBackground(radius: 14)
                    Text("No comments yet. Start the conversation.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity)
                }
                .clipShape(.rect(cornerRadius: 14))
            } else {
                ZStack {
                    premiumCardBackground(radius: 16)
                    VStack(spacing: 0) {
                        ForEach(Array(vm.comments.enumerated()), id: \.element.id) { idx, comment in
                            commentRow(comment)
                            if idx < vm.comments.count - 1 {
                                Divider()
                                    .background(Color.chrome(0.05))
                                    .padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: Theme.cardDropShadow, radius: 12, x: 0, y: 4)
            }
        }
    }

    private func imagesGrid(_ urls: [String]) -> some View {
        let cols = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(Array(urls.enumerated()), id: \.offset) { idx, s in
                Button {
                    imageViewer = ImageViewerState(urls: urls, startIndex: idx)
                } label: {
                    Color.chrome(0.04)
                        .frame(height: 140)
                        .overlay {
                            if let u = URL(string: s) {
                                AsyncImage(url: u) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Image(systemName: "photo")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.chrome(0.4))
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.chrome(0.06), lineWidth: 0.6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func commentRow(_ c: ForumComment) -> some View {
        let isMine = c.author_id != nil && c.author_id == SupabaseAPI.shared.session?.user_id
        return HStack(alignment: .top, spacing: 12) {
            avatar(for: c.author?.displayName, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.author?.displayName ?? "Resident")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if c.show_unit == true, let u = c.unit_number, !u.isEmpty {
                        Text("Unit \(u)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.chrome(0.45))
                    }
                    bullet
                    Text(Fmt.relative(Fmt.parseDate(c.created_at)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.chrome(0.45))
                    Spacer(minLength: 0)
                }
                if c.is_removed == true {
                    Text("[Removed by staff]")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(Color.chrome(0.45))
                } else {
                    Text(c.content ?? "")
                        .font(.system(size: 14))
                        .lineSpacing(2)
                        .foregroundStyle(Color.chrome(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if isMine, c.is_removed != true {
                    Button(role: .destructive) {
                        Task { await deleteComment(id: c.id) }
                    } label: {
                        Text(deletingCommentId == c.id ? "Deleting…" : "Delete")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF26A6A))
                    }
                    .buttonStyle(.plain)
                    .disabled(deletingCommentId == c.id)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bullet: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(Color.chrome(0.35))
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

    // MARK: - Composer

    private func composer(post: ForumPost) -> some View {
        VStack(spacing: 0) {
            if let err = vm.sendError {
                Text(err)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xF26A6A))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField(
                            "",
                            text: Bindable(vm).commentDraft,
                            prompt: Text("Write a reply…").foregroundStyle(Color.chrome(0.4)),
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .tint(Color(hex: 0xFF9A2F))
                        .lineLimit(1...5)
                        .focused($commentFocused)
                        .padding(.leading, 14)
                        .padding(.vertical, 10)

                        Button {
                            Task {
                                let ok = await vm.sendComment(postId: post.id, unitNumber: app.activeUnit?.unit_number)
                                if ok { commentFocused = false }
                            }
                        } label: {
                            ZStack {
                                if canSend {
                                    Circle().fill(
                                        LinearGradient(
                                            colors: [Color(hex: 0xFFB15E), Color(hex: 0xFF6A00)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing
                                        )
                                    )
                                } else {
                                    Circle().fill(Color.chrome(0.08))
                                }
                                if vm.sending {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(canSend ? .white : Color.chrome(0.4))
                                }
                            }
                            .frame(width: 32, height: 32)
                            .shadow(
                                color: canSend ? Color(hex: 0xFF6A00).opacity(0.4) : .clear,
                                radius: 8, y: 3
                            )
                        }
                        .disabled(!canSend || vm.sending)
                        .buttonStyle(.plain)
                        .padding(.trailing, 5)
                        .padding(.bottom, 5)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Theme.premiumCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.chrome(0.08), lineWidth: 0.6)
                    )
                }
                Toggle(isOn: Bindable(vm).commentShowUnit) {
                    Text("Show my unit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.chrome(0.55))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Color(hex: 0xFF9A2F))
                .padding(.leading, 4)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
    }

    private var canSend: Bool {
        !vm.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func deletePost() async {
        do {
            try await CommunityService.deletePost(id: postId)
            dismiss()
        } catch {
            vm.sendError = "We couldn't delete this post. Try again."
        }
    }

    private func deleteComment(id: String) async {
        deletingCommentId = id
        defer { deletingCommentId = nil }
        do {
            try await CommunityService.deleteComment(id: id)
            if let fresh = try? await CommunityService.fetchComments(postId: postId) {
                vm.comments = fresh
            }
        } catch {
            vm.sendError = "We couldn't delete the comment. Try again."
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
}

// MARK: - Image Viewer

private struct ImageGalleryView: View {
    let urls: [String]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, s in
                    if let u = URL(string: s) {
                        AsyncImage(url: u) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fit)
                            default:
                                ProgressView().tint(.white)
                            }
                        }
                        .tag(idx)
                    }
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(10)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .padding(16)
                }
                Spacer()
            }
        }
        .onAppear { index = startIndex }
    }
}
