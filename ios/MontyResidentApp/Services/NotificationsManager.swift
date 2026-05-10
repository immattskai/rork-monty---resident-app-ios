import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Centralizes push permission state, APNs token registration,
/// foreground delivery, and tap → deep-link routing.
@MainActor
@Observable
final class NotificationsManager: NSObject {
    static let shared = NotificationsManager()

    // MARK: - Public state

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var deviceToken: String?
    var isRegistering: Bool = false
    var lastRegisterError: String?

    /// Set by tap handlers; consumed by `AppState`/`SignedInRoot`.
    var pendingDeepLink: HomeRoute?
    var pendingTicketId: String?

    /// Whether the soft-ask onboarding screen has already been shown.
    var hasShownSoftAsk: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.shownSoftAsk) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.shownSoftAsk) }
    }

    private enum Keys {
        static let shownSoftAsk = "monty.notifications.shownSoftAsk.v1"
        static let cachedToken = "monty.notifications.deviceToken.v1"
    }

    // MARK: - Lifecycle

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        if let cached = UserDefaults.standard.string(forKey: Keys.cachedToken) {
            self.deviceToken = cached
        }
    }

    /// Should be called whenever the app becomes active.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.authorizationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Soft-ask follow-through. Returns the resolved status.
    @discardableResult
    func requestPermission() async -> UNAuthorizationStatus {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            // Fall through; refresh below to capture whatever the system decided.
        }
        await refreshAuthorizationStatus()
        if authorizationStatus == .authorized || authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return authorizationStatus
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - APNs token

    func handleDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        UserDefaults.standard.set(token, forKey: Keys.cachedToken)
        Task { await registerTokenWithBackend() }
    }

    func handleRegistrationError(_ error: Error) {
        lastRegisterError = error.localizedDescription
    }

    /// Re-runs on each cold start once the user is signed in.
    func registerTokenWithBackend() async {
        guard SupabaseAPI.shared.session != nil else { return }
        guard let token = deviceToken, !token.isEmpty else { return }
        isRegistering = true
        defer { isRegistering = false }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "provider": "apns",
            "device_name": UIDevice.current.name,
            "app_version": appVersion,
            "device_info": [
                "model": UIDevice.current.model,
                "os_version": UIDevice.current.systemVersion,
                "name": UIDevice.current.name,
            ],
        ]
        do {
            _ = try await MontyResidentAppService.invokeFunction(
                name: "register-mobile-push-token",
                body: body,
                timeout: 20
            )
            lastRegisterError = nil
        } catch {
            // Edge function may not be deployed yet — keep silent in UI but record for debug.
            lastRegisterError = error.localizedDescription
            #if DEBUG
            print("[notifications] register failed: \(error)")
            #endif
        }
    }

    func revokeToken() async {
        guard let token = deviceToken, !token.isEmpty else { return }
        _ = try? await MontyResidentAppService.invokeFunction(
            name: "revoke-mobile-push-token",
            body: ["token": token, "platform": "ios", "provider": "apns"],
            timeout: 15
        )
        UserDefaults.standard.removeObject(forKey: Keys.cachedToken)
        self.deviceToken = nil
    }

    // MARK: - Deep links

    /// Maps a `data.url` path from the push payload into a navigation
    /// instruction. Ticket detail uses the existing `String` destination
    /// (so reply notifications open straight into the conversation).
    func enqueueDeepLink(url: String?, type: String?) {
        guard let url, !url.isEmpty else {
            // Fall back to category landing if only `type` is present.
            if let type, let route = Self.routeForType(type) {
                self.pendingDeepLink = route
            }
            return
        }
        // Strip query/fragment, normalize leading slash.
        var path = url
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[..<h]) }
        if !path.hasPrefix("/") { path = "/" + path }

        let parts = path.split(separator: "/").map(String.init)
        guard let head = parts.first else { return }

        switch head {
        case "packages": pendingDeepLink = .packages
        case "guests": pendingDeepLink = .guests
        case "payments": pendingDeepLink = .payments
        case "amenities": pendingDeepLink = .amenities
        case "tickets":
            if parts.count >= 2 {
                pendingTicketId = parts[1]
            } else {
                pendingDeepLink = .tickets
            }
        case "community":
            if parts.count >= 2 {
                pendingDeepLink = .communityPost(postId: parts[1])
            } else {
                pendingDeepLink = .community
            }
        case "documents": pendingDeepLink = .documents
        case "contacts": pendingDeepLink = .contacts
        default:
            break
        }
    }

    private static func routeForType(_ type: String) -> HomeRoute? {
        switch type {
        case "packages": return .packages
        case "guests": return .guests
        case "tickets": return .tickets
        case "charges_posted", "autopay": return .payments
        case "amenities": return .amenities
        case "community": return .community
        default: return nil
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationsManager: @preconcurrency UNUserNotificationCenterDelegate {
    /// Foreground delivery: show a banner and play sound by default.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// Tap-to-open: extract `data.url` / `data.type` and queue the deep link.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let payload = (info["data"] as? [AnyHashable: Any]) ?? info
        let url = payload["url"] as? String
        let type = payload["type"] as? String
        enqueueDeepLink(url: url, type: type)
        completionHandler()
    }
}

// MARK: - AppDelegate

final class MontyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor in
            await NotificationsManager.shared.refreshAuthorizationStatus()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            NotificationsManager.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            NotificationsManager.shared.handleRegistrationError(error)
        }
    }
}
