import SwiftUI

enum GuestSheetMode: Equatable {
    case create
    case edit(id: String)

    var title: String {
        switch self {
        case .create: return "Add Guest"
        case .edit: return "Edit Guest"
        }
    }

    var primaryLabel: String {
        switch self {
        case .create: return "Save"
        case .edit: return "Update"
        }
    }
}

private let RELATIONSHIP_QUICK_PICKS = [
    "Family", "Friend", "Cleaner", "Dog Walker", "Contractor", "Delivery", "Other",
]

struct AddGuestSheet: View {
    let mode: GuestSheetMode
    let initial: GuestInput
    let onDone: (String) -> Void

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var input: GuestInput
    @State private var submitting = false
    @State private var errorMessage: String?

    init(mode: GuestSheetMode, initial: GuestInput, onDone: @escaping (String) -> Void) {
        self.mode = mode
        self.initial = initial
        self.onDone = onDone
        _input = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        section("Name") {
                            field {
                                TextField("Guest's full name", text: $input.guestName)
                                    .textContentType(.name)
                                    .autocorrectionDisabled()
                            }
                        }

                        section("Phone") {
                            field {
                                ZStack(alignment: .leading) {
                                    if input.guestPhone.isEmpty {
                                        Text("(555) 123-4567")
                                            .foregroundStyle(Theme.textMuted)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $input.guestPhone)
                                        .keyboardType(.phonePad)
                                        .textContentType(.none)
                                        .autocorrectionDisabled()
                                }
                            }
                        }

                        section("Email") {
                            field {
                                ZStack(alignment: .leading) {
                                    if input.guestEmail.isEmpty {
                                        Text(verbatim: "guest\u{200B}@example.com")
                                            .foregroundStyle(Theme.textMuted)
                                            .tint(Theme.textMuted)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $input.guestEmail)
                                        .keyboardType(.emailAddress)
                                        .textInputAutocapitalization(.never)
                                        .textContentType(.none)
                                        .autocorrectionDisabled()
                                }
                            }
                        }

                        section("Relationship") {
                            VStack(alignment: .leading, spacing: 8) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(RELATIONSHIP_QUICK_PICKS, id: \.self) { tag in
                                            relationshipChip(tag)
                                        }
                                    }
                                }
                                .scrollClipDisabled()
                                field {
                                    TextField("e.g. Family", text: $input.relationship)
                                        .autocorrectionDisabled()
                                }
                            }
                        }

                        section("Access Window") {
                            VStack(spacing: 0) {
                                datePickerRow(label: "Starts", date: $input.accessStart)
                                Divider().background(Theme.border)
                                datePickerRow(label: "Ends", date: $input.accessEnd)
                            }
                            .background(field)
                        }

                        section("Repeat") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: $input.isRecurring.animation(.spring(response: 0.3, dampingFraction: 0.85))) {
                                    Text("Recurring access")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                }
                                .tint(Theme.accent)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(field)

                                if input.isRecurring {
                                    HStack(spacing: 6) {
                                        ForEach(0..<7) { d in
                                            dayChip(d)
                                        }
                                    }
                                }
                            }
                        }

                        section("Notes") {
                            field {
                                TextField(
                                    "Anything staff should know (optional)",
                                    text: $input.notes,
                                    axis: .vertical
                                )
                                .lineLimit(3...6)
                            }
                        }

                        if let err = errorMessage {
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
            .navigationTitle(mode.title)
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
                        if submitting {
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text(mode.primaryLabel)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .disabled(submitting)
                }
            }
        }
    }

    // MARK: - Pieces

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

    @ViewBuilder
    private func field<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(field)
    }

    private var field: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }

    private func relationshipChip(_ tag: String) -> some View {
        let isSelected = input.relationship.caseInsensitiveCompare(tag) == .orderedSame
        return Button {
            Haptics.tap()
            input.relationship = isSelected ? "" : tag
        } label: {
            Text(tag)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(isSelected ? Theme.accent : Theme.surface))
                .overlay(Capsule().stroke(isSelected ? .clear : Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func dayChip(_ day: Int) -> some View {
        let isSelected = input.recurringDays.contains(day)
        return Button {
            Haptics.tap()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                if isSelected { input.recurringDays.remove(day) }
                else { input.recurringDays.insert(day) }
            }
        } label: {
            Text(GuestsCopy.dayShort(day))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Theme.accent : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? .clear : Theme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func datePickerRow(label: String, date: Binding<Date>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Submit

    private func submit() async {
        if let v = input.validationError {
            errorMessage = v
            return
        }
        guard let unit = app.activeUnit,
              let unitNumber = unit.unit_number, !unitNumber.isEmpty else {
            errorMessage = "We couldn't find your unit. Try again."
            return
        }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            switch mode {
            case .create:
                _ = try await GuestService.createGuest(
                    input,
                    propertyId: unit.property_id,
                    unitNumber: unitNumber
                )
                onDone("Guest added.")
            case .edit(let id):
                _ = try await GuestService.updateGuest(id: id, input)
                onDone("Guest updated.")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = "We couldn't save your guest. Try again."
        }
    }
}
