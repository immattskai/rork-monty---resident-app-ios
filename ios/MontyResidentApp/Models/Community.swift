import Foundation

nonisolated struct ForumAuthor: Codable, Hashable {
    var full_name: String?
    var email: String?

    var displayName: String {
        if let n = full_name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        if let e = email?.split(separator: "@").first.map(String.init), !e.isEmpty {
            return e
        }
        return "Resident"
    }
}

nonisolated struct ForumRule: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var content: String?
    var sort_order: Int?
}

nonisolated struct ForumCategory: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var name: String?
    var description: String?
    var sort_order: Int?
}

nonisolated struct ForumPost: Codable, Identifiable, Hashable {
    let id: String
    var property_id: String?
    var category_id: String?
    var author_id: String?
    var title: String?
    var content: String?
    var is_pinned: Bool?
    var is_removed: Bool?
    var comment_count: Int?
    var show_unit: Bool?
    var unit_number: String?
    var image_urls: [String]?
    var link_url: String?
    var created_at: String?
    var author: ForumAuthor?
}

nonisolated struct ForumComment: Codable, Identifiable, Hashable {
    let id: String
    var post_id: String?
    var author_id: String?
    var content: String?
    var is_removed: Bool?
    var show_unit: Bool?
    var unit_number: String?
    var created_at: String?
    var author: ForumAuthor?
}
