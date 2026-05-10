import SwiftUI
import PhotosUI

@MainActor
@Observable
final class NewTicketViewModel {
    var title: String = ""
    var description: String = ""
    var photos: [PhotosPickerItem] = []
    var photoPreviews: [UIImage] = []
    var submitting = false
    var error: String?
}

struct NewTicketView: View {
    var onCreated: (Ticket) -> Void = { _ in }

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm = NewTicketViewModel()
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        section("Title") {
                            TextField("e.g. Leaky faucet in kitchen", text: $vm.title)
                                .focused($titleFocused)
                                .font(.system(size: 16))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(field)
                        }

                        section("Describe the issue") {
                            TextField(
                                "Add details — when it started, what you've tried, etc.",
                                text: $vm.description,
                                axis: .vertical
                            )
                            .lineLimit(5...10)
                            .font(.system(size: 15))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(field)
                        }

                        section("Photos (optional)") {
                            photosSection
                        }

                        Text("Our team — and Monty AI — will read this and route it to the right person automatically.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)

                        if let err = vm.error {
                            Text(err)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.danger)
                        }

                        Spacer().frame(height: 12)
                    }
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, Theme.Space.xxl)
                }
            }
            .navigationTitle("New ticket")
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
                            Text("Submit")
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
        let d = vm.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !d.isEmpty && app.activeUnit != nil
    }

    private func submit() async {
        guard let unit = app.activeUnit else {
            vm.error = "No active unit. Choose a unit first."
            return
        }
        vm.submitting = true
        vm.error = nil
        defer { vm.submitting = false }
        do {
            let ticket = try await MontyResidentAppService.createTicket(
                title: vm.title.trimmingCharacters(in: .whitespacesAndNewlines),
                description: vm.description.trimmingCharacters(in: .whitespacesAndNewlines),
                propertyId: unit.property_id,
                unitId: unit.id
            )
            onCreated(ticket)
            dismiss()
            // Push the ticket detail screen so the resident sees Monty
            // respond live instead of having to find the new ticket in the list.
            app.pendingTicketDetailId = ticket.id
        } catch {
            vm.error = error.localizedDescription
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
                    selection: $vm.photos,
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
