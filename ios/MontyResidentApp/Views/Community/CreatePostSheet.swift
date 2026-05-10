import SwiftUI
import PhotosUI

@MainActor
@Observable
final class CreatePostViewModel {
    var title: String = ""
    var content: String = ""
    var linkUrl: String = ""
    var photos: [PhotosPickerItem] = []
    var photoPreviews: [UIImage] = []
    var showUnit: Bool = false
    var submitting = false
    var error: String?
}

struct CreatePostSheet: View {
    let categoryId: String
    let categoryName: String
    var onCreated: () -> Void = {}

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = CreatePostViewModel()
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(categoryName.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textMuted)

                        section("Title") {
                            TextField("What's it about?", text: Bindable(vm).title)
                                .focused($titleFocused)
                                .font(.system(size: 16))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(field)
                        }

                        section("Body") {
                            TextField("Share details with your neighbors…",
                                      text: Bindable(vm).content,
                                      axis: .vertical)
                                .lineLimit(6...12)
                                .font(.system(size: 15))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(field)
                        }

                        section("Link (optional)") {
                            TextField("https://…", text: Bindable(vm).linkUrl)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .font(.system(size: 14))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(field)
                        }

                        section("Photos (optional)") {
                            photosSection
                        }

                        Toggle(isOn: Bindable(vm).showUnit) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show my unit number")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if let u = app.activeUnit?.unit_number, !u.isEmpty {
                                    Text("Will appear as Unit \(u)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                } else {
                                    Text("No unit number on file")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textMuted)
                                }
                            }
                        }
                        .tint(Theme.accent)
                        .padding(14)
                        .background(field)

                        if let err = vm.error {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.danger)
                        }

                        Spacer().frame(height: 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if vm.submitting {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Post")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(canSubmit ? Theme.accent : Theme.textMuted)
                        }
                    }
                    .disabled(!canSubmit || vm.submitting)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    private var canSubmit: Bool {
        let t = vm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = vm.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !c.isEmpty && app.activePropertyId != nil
    }

    private func submit() async {
        guard let propertyId = app.activePropertyId,
              let uid = SupabaseAPI.shared.session?.user_id else {
            vm.error = "We couldn't find your active building."
            return
        }
        vm.submitting = true
        vm.error = nil
        defer { vm.submitting = false }

        do {
            // Upload images first
            var uploadedURLs: [String] = []
            for img in vm.photoPreviews {
                let url = try await CommunityService.uploadForumImage(
                    image: img,
                    propertyId: propertyId,
                    userId: uid
                )
                uploadedURLs.append(url)
            }

            _ = try await CommunityService.createPost(
                propertyId: propertyId,
                categoryId: categoryId,
                title: vm.title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: vm.content.trimmingCharacters(in: .whitespacesAndNewlines),
                linkUrl: vm.linkUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                imageUrls: uploadedURLs,
                showUnit: vm.showUnit,
                unitNumber: app.activeUnit?.unit_number
            )
            onCreated()
            dismiss()
        } catch {
            vm.error = "We couldn't post that. Try again."
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textMuted)
            content()
        }
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }

    private var photosSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PhotosPicker(
                    selection: Bindable(vm).photos,
                    maxSelectionCount: 4,
                    matching: .images
                ) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 20, weight: .light))
                        Text("Add")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 76, height: 76)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.border, style: StrokeStyle(lineWidth: 0.8, dash: [4, 3]))
                    )
                }

                ForEach(Array(vm.photoPreviews.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 12))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .onChange(of: vm.photos) { _, items in
            Task { await loadPreviews(items) }
        }
    }

    private func loadPreviews(_ items: [PhotosPickerItem]) async {
        var previews: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                previews.append(img)
            }
        }
        vm.photoPreviews = previews
    }
}
