import Foundation

@MainActor
enum NotificationPreferencesService {
    static var api: SupabaseAPI { SupabaseAPI.shared }

    private static let columns =
        "user_id, packages_enabled, guests_enabled, tickets_enabled, " +
        "charges_posted_enabled, autopay_enabled, amenities_enabled, community_enabled"

    static func fetch() async throws -> NotificationPreferences? {
        guard let uid = api.session?.user_id else { return nil }
        return try await api.from("notification_preferences")
            .select(columns)
            .eq("user_id", uid)
            .limit(1)
            .single()
            .executeOptional(as: NotificationPreferences.self)
    }

    /// Upsert on `user_id`. RLS scopes the row to the calling user.
    @discardableResult
    static func upsert(_ prefs: NotificationPreferences) async throws -> NotificationPreferences {
        guard let url = URL(string: SupabaseConfig.url + "/rest/v1/notification_preferences?on_conflict=user_id") else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(prefs)
        let data = try await api.performData(req)
        let rows = try JSONDecoder().decode([NotificationPreferences].self, from: data)
        return rows.first ?? prefs
    }
}
