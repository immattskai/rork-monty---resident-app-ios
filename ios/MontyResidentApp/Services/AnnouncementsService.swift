import Foundation

@MainActor
enum AnnouncementsService {
    static var api: SupabaseAPI { SupabaseAPI.shared }

    /// Fetches the most recent active announcements for a property.
    /// Mirrors the web app's filter:
    ///   published_at <= now() AND (expires_at IS NULL OR expires_at > now())
    /// Sort: pinned DESC, published_at DESC. Server-side limit.
    static func fetchActive(propertyId: String, limit: Int = 3) async throws -> [PropertyAnnouncement] {
        let now = Fmt.iso.string(from: Date())
        let select = "id, title, body, pinned, published_at, expires_at, property_id"
        return try await api.from("property_announcements")
            .select(select)
            .eq("property_id", propertyId)
            .lte("published_at", now)
            .or("expires_at.is.null,expires_at.gt.\(now)")
            // Combined ordering: PostgREST parses comma-separated items.
            // Produces ?order=pinned.desc,published_at.desc
            .order("pinned.desc,published_at", ascending: false)
            .limit(limit)
            .execute(as: [PropertyAnnouncement].self)
    }
}
