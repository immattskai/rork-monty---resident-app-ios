import SwiftUI
import UserNotifications

struct RootView: View {
    @State private var app = AppState()
    @State private var appearance = AppearanceManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch app.authState {
            case .loading:
                ProgressView().tint(Theme.textSecondary)
            case .signedOut:
                LoginView()
                    .transition(.opacity)
            case .nonResidentBlocked:
                NonResidentBlockView()
                    .transition(.opacity)
            case .bootError(let message):
                BootErrorView(message: message)
                    .transition(.opacity)
            case .signedIn:
                SignedInRoot()
                    .transition(.opacity)
            }
        }
        .environment(app)
        .environment(appearance)
        .preferredColorScheme(appearance.mode.colorScheme)
        .animation(.easeInOut(duration: 0.25), value: app.authState)
        .task {
            await app.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await NotificationsManager.shared.refreshAuthorizationStatus()
                    if NotificationsManager.shared.authorizationStatus == .authorized
                        || NotificationsManager.shared.authorizationStatus == .provisional {
                        await NotificationsManager.shared.registerTokenWithBackend()
                    }
                }
            }
        }
    }
}

private struct SignedInRoot: View {
    @Environment(AppState.self) private var app
    @State private var path = NavigationPath()
    @State private var notifications = NotificationsManager.shared
    @State private var showOnboarding: Bool = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
        }
        .onChange(of: app.pendingTicketDetailId) { _, new in
            guard let id = new else { return }
            path.append(id)
            // Clear after consuming so subsequent submissions can re-trigger.
            DispatchQueue.main.async { app.pendingTicketDetailId = nil }
        }
        .onChange(of: app.pendingDeepLink) { _, new in
            guard let route = new else { return }
            path.append(route)
            DispatchQueue.main.async { app.pendingDeepLink = nil }
        }
        // Forward notification-manager deep links into AppState.
        .onChange(of: notifications.pendingTicketId) { _, new in
            guard let id = new else { return }
            app.pendingTicketDetailId = id
            DispatchQueue.main.async { notifications.pendingTicketId = nil }
        }
        .onChange(of: notifications.pendingDeepLink) { _, new in
            guard let route = new else { return }
            app.pendingDeepLink = route
            DispatchQueue.main.async { notifications.pendingDeepLink = nil }
        }
        .task {
            await notifications.refreshAuthorizationStatus()
            // Show the soft-ask once, only when iOS hasn't been asked yet.
            if !notifications.hasShownSoftAsk
                && notifications.authorizationStatus == .notDetermined {
                // Defer one tick so the dashboard renders behind the sheet.
                try? await Task.sleep(for: .milliseconds(450))
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            NotificationOnboardingView()
                .presentationDragIndicator(.hidden)
        }
    }
}

struct BootErrorView: View {
    @Environment(AppState.self) private var app
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text("Something went wrong")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await app.loadAfterAuth() }
                } label: {
                    Text("Try again")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.textPrimary)
                        .clipShape(.rect(cornerRadius: 12))
                }
                Button {
                    Task { await app.signOut() }
                } label: {
                    Text("Sign out")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
