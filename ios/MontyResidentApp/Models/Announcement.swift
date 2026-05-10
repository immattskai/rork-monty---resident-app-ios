import Foundation

nonisolated struct PropertyAnnouncement: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let body: String?
    let pinned: Bool?
    let published_at: String?
    let expires_at: String?
    let property_id: String?

    var isPinned: Bool { pinned ?? false }
    var publishedDate: Date? { Fmt.parseDate(published_at) }
}
