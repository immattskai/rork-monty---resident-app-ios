import Foundation
import UIKit

@MainActor
enum CommunityService {
    static var api: SupabaseAPI { SupabaseAPI.shared }

    // MARK: - Reads

    static func fetchRules(propertyId: String) async throws -> [ForumRule] {
        try await api.from("forum_rules")
            .select("id, property_id, content, sort_order")
            .eq("property_id", propertyId)
            .order("sort_order", ascending: true)
            .limit(100)
            .execute(as: [ForumRule].self)
    }

    static func fetchCategories(propertyId: String) async throws -> [ForumCategory] {
        try await api.from("forum_categories")
            .select("id, property_id, name, description, sort_order")
            .eq("property_id", propertyId)
            .order("sort_order", ascending: true)
            .limit(200)
            .execute(as: [ForumCategory].self)
    }

    private nonisolated struct PostCategoryRow: Decodable { let category_id: String? }

    static func fetchPostCounts(propertyId: String, categoryIds: [String]) async throws -> [String: Int] {
        let ids = categoryIds.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }
        let rows = try await api.from("forum_posts")
            .select("category_id")
            .eq("property_id", propertyId)
            .in("category_id", ids)
            .eq("is_removed", "false")
            .limit(2000)
            .execute(as: [PostCategoryRow].self)
        var counts: [String: Int] = [:]
        for r in rows {
            if let c = r.category_id { counts[c, default: 0] += 1 }
        }
        return counts
    }

    static func fetchRecentPosts(propertyId: String, limit: Int = 3) async throws -> [ForumPost] {
        let select = "id, property_id, category_id, author_id, title, content, is_pinned, is_removed, comment_count, show_unit, unit_number, image_urls, link_url, created_at, author:profiles!forum_posts_author_id_fkey(full_name,email)"
        return try await api.from("forum_posts")
            .select(select)
            .eq("property_id", propertyId)
            .eq("is_removed", "false")
            .order("created_at", ascending: false)
            .limit(limit)
            .execute(as: [ForumPost].self)
    }

    static func fetchPosts(propertyId: String, categoryId: String) async throws -> [ForumPost] {
        let select = "id, property_id, category_id, author_id, title, content, is_pinned, is_removed, comment_count, show_unit, unit_number, image_urls, link_url, created_at, author:profiles!forum_posts_author_id_fkey(full_name,email)"
        return try await api.from("forum_posts")
            .select(select)
            .eq("property_id", propertyId)
            .eq("category_id", categoryId)
            .order("created_at", ascending: false)
            .limit(200)
            .execute(as: [ForumPost].self)
    }

    static func fetchPost(id: String) async throws -> ForumPost? {
        let select = "id, property_id, category_id, author_id, title, content, is_pinned, is_removed, comment_count, show_unit, unit_number, image_urls, link_url, created_at, author:profiles!forum_posts_author_id_fkey(full_name,email)"
        return try await api.from("forum_posts")
            .select(select)
            .eq("id", id)
            .limit(1)
            .single()
            .executeOptional(as: ForumPost.self)
    }

    static func fetchComments(postId: String) async throws -> [ForumComment] {
        let select = "id, post_id, author_id, content, is_removed, show_unit, unit_number, created_at, author:profiles!forum_comments_author_id_fkey(full_name,email)"
        return try await api.from("forum_comments")
            .select(select)
            .eq("post_id", postId)
            .order("created_at", ascending: true)
            .limit(500)
            .execute(as: [ForumComment].self)
    }

    // MARK: - Writes

    @discardableResult
    static func createPost(
        propertyId: String,
        categoryId: String,
        title: String,
        content: String,
        linkUrl: String?,
        imageUrls: [String],
        showUnit: Bool,
        unitNumber: String?
    ) async throws -> ForumPost {
        guard let uid = api.session?.user_id else { throw SupabaseError.auth("Not signed in") }
        struct Payload: Encodable {
            let property_id: String
            let category_id: String
            let author_id: String
            let title: String
            let content: String
            let link_url: String?
            let image_urls: [String]?
            let show_unit: Bool
            let unit_number: String?
        }
        return try await api.insert(
            into: "forum_posts",
            body: Payload(
                property_id: propertyId,
                category_id: categoryId,
                author_id: uid,
                title: title,
                content: content,
                link_url: linkUrl?.isEmpty == false ? linkUrl : nil,
                image_urls: imageUrls.isEmpty ? nil : imageUrls,
                show_unit: showUnit,
                unit_number: showUnit ? unitNumber : nil
            ),
            returning: ForumPost.self
        )
    }

    @discardableResult
    static func createComment(
        postId: String,
        content: String,
        showUnit: Bool,
        unitNumber: String?
    ) async throws -> ForumComment {
        guard let uid = api.session?.user_id else { throw SupabaseError.auth("Not signed in") }
        struct Payload: Encodable {
            let post_id: String
            let author_id: String
            let content: String
            let show_unit: Bool
            let unit_number: String?
        }
        return try await api.insert(
            into: "forum_comments",
            body: Payload(
                post_id: postId,
                author_id: uid,
                content: content,
                show_unit: showUnit,
                unit_number: showUnit ? unitNumber : nil
            ),
            returning: ForumComment.self
        )
    }

    static func deletePost(id: String) async throws {
        try await deleteRow(table: "forum_posts", id: id)
    }

    static func deleteComment(id: String) async throws {
        try await deleteRow(table: "forum_comments", id: id)
    }

    private static func deleteRow(table: String, id: String) async throws {
        guard var comps = URLComponents(string: SupabaseConfig.url + "/rest/v1/" + table) else {
            throw SupabaseError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "id", value: "eq.\(id)")]
        guard let url = comps.url else { throw SupabaseError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await api.performData(req)
    }

    // MARK: - Storage

    /// Uploads a JPEG to the `forum-images` bucket and returns the public URL.
    static func uploadForumImage(image: UIImage, propertyId: String, userId: String) async throws -> String {
        let resized = image.resizedForUpload(maxDimension: 1600)
        guard let data = resized.jpegData(compressionQuality: 0.82) else {
            throw SupabaseError.network("Couldn't encode image")
        }
        let path = "\(propertyId)/\(userId)/\(UUID().uuidString).jpg"
        guard let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/forum-images/\(path)") else {
            throw SupabaseError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-upsert")
        req.httpBody = data
        _ = try await api.performData(req)
        return "\(SupabaseConfig.url)/storage/v1/object/public/forum-images/\(path)"
    }
}

private extension UIImage {
    func resizedForUpload(maxDimension: CGFloat) -> UIImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
