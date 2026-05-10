import SwiftUI
import UserNotifications

@MainActor
@Observable
final class NotificationSettingsViewModel {
    var prefs: NotificationPreferences?
    var loading: Bool = true
    var saving: Bool = false
    var error: String?

    func load() async {
        loading = true
        defer { loading = false }
        do {
            if let p = try await NotificationPreferencesService.fetch() {
                prefs = p
            } else if let uid = SupabaseAPI.shared.session?.user_id {
                prefs = .defaults(userId: uid)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            if let uid = SupabaseAPI.shared.session?.user_id, prefs == nil {
                prefs = .defaults(userId: uid)
            }
        }
    }

    func toggle(_ category: NotificationCategory, enabled: Bool) async {
        guard let current = prefs else { return }
        let next = current.setting(category, enabled: enabled)
        prefs = next
        saving = true
        defer { saving = false }
        do {
            let saved = try await NotificationPreferencesService.upsert(next)
            prefs = saved
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct NotificationSettingsView: View {
    @State private var vm = NotificationSettingsViewModel()
    @State private var notifications = NotificationsManager.shared

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    masterCard
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, Theme.Space.md)

                    if let err = vm.error {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.lg)
                    }

                    SectionHeader(
                        title: "Categories",
                        action: nil,
                        actionLabel: vm.saving ? "Saving…" : nil
                    )

                    VStack(spacing: 8) {
                        ForEach(NotificationCategory.allCases) { c in
                            categoryRow(c)
                        }
                    }
                    .padding(.horizontal, Theme.Space.lg)

                    Text("You'll only receive a notification if you allow it here AND your iOS notification permission is on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.top, 4)
                        .padding(.bottom, Theme.Space.xxl)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notifications.refreshAuthorizationStatus()
            await vm.load()
        }
        .onChange(of: notifications.authorizationStatus) { _, newValue in
            if newValue == .authorized || newValue == .provisional {
                Task { await notifications.registerTokenWithBackend() }
            }
        }
    }

    // MARK: - Master row

    private var masterCard: some View {
        GlassCard(padding: Theme.Space.lg) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(masterIconBackground)
                    Image(systemName: masterStatusIcon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Push notifications")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(masterStatusLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                masterTrailing
            }
        }
    }

    private var masterIsOn: Bool {
        notifications.authorizationStatus == .authorized
            || notifications.authorizationStatus == .provisional
    }

    private var masterStatusLabel: String {
        switch notifications.authorizationStatus {
        case .authorized: "Allowed"
        case .provisional: "Quiet delivery"
        case .denied: "Off — open iOS Settings to allow"
        case .notDetermined: "Tap Allow to start receiving alerts"
        case .ephemeral: "Ephemeral"
        @unknown default: "Unknown"
        }
    }

    private var masterStatusIcon: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "bell.fill"
        case .denied: "bell.slash.fill"
        case .notDetermined: "bell"
        @unknown default: "bell"
        }
    }

    private var masterIconBackground: Color {
        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: Color(hex: 0x2E7D5B)
        case .denied: Color(hex: 0xB23B3B)
        case .notDetermined: Color(hex: 0x111418)
        @unknown default: Color(hex: 0x111418)
        }
    }

    @ViewBuilder
    private var masterTrailing: some View {
        switch notifications.authorizationStatus {
        case .notDetermined:
            Button {
                Task { await notifications.requestPermission() }
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent))
            }
        case .denied:
            Button {
                notifications.openSystemSettings()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.accent))
            }
        default:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.success)
                .padding(8)
                .background(Circle().fill(Theme.success.opacity(0.12)))
        }
    }

    // MARK: - Category row

    private func categoryRow(_ category: NotificationCategory) -> some View {
        let enabled = vm.prefs?.isEnabled(category) ?? true
        let interactive = masterIsOn && vm.prefs != nil
        let binding = Binding<Bool>(
            get: { enabled },
            set: { newValue in
                Task { await vm.toggle(category, enabled: newValue) }
            }
        )

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surfaceSunken)
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(category.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)

            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(!interactive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .opacity(interactive ? 1.0 : 0.55)
    }
}
