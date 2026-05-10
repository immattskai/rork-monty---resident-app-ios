import Foundation

nonisolated struct SupabaseSession: Codable, Sendable {
    var access_token: String
    var refresh_token: String
    var expires_at: Int? // unix seconds
    var token_type: String?
    var user_id: String?
    var email: String?

    var expiresDate: Date? {
        guard let expires_at else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expires_at))
    }

    var isExpired: Bool {
        guard let d = expiresDate else { return false }
        return d.timeIntervalSinceNow < 30
    }
}

nonisolated enum SessionStore {
    static let key = "monty.supabase.session.v1"

    static func save(_ s: SupabaseSession?) {
        if let s, let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func load() -> SupabaseSession? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

nonisolated enum ActiveUnitStore {
    static let key = "monty.activeUnitId.v1"
    static func save(_ id: String?) {
        if let id { UserDefaults.standard.set(id, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    static func load() -> String? { UserDefaults.standard.string(forKey: key) }
}
