import Foundation

/// Seven push categories that mirror the web app exactly.
enum NotificationCategory: String, CaseIterable, Identifiable, Hashable {
    case packages
    case guests
    case tickets
    case chargesPosted = "charges_posted"
    case autopay
    case amenities
    case community

    var id: String { rawValue }

    var title: String {
        switch self {
        case .packages: "Packages"
        case .guests: "Guests"
        case .tickets: "Tickets"
        case .chargesPosted: "New charges"
        case .autopay: "Autopay"
        case .amenities: "Amenities"
        case .community: "Community"
        }
    }

    var subtitle: String {
        switch self {
        case .packages: "Deliveries logged or picked up"
        case .guests: "When your guest arrives at the building"
        case .tickets: "Replies and status changes on your tickets"
        case .chargesPosted: "A new charge is posted to your unit"
        case .autopay: "Autopay charged or needs attention"
        case .amenities: "Bookings approved, declined, or upcoming"
        case .community: "New posts in your building's forum"
        }
    }

    var icon: String {
        switch self {
        case .packages: "shippingbox.fill"
        case .guests: "person.wave.2.fill"
        case .tickets: "ticket.fill"
        case .chargesPosted: "dollarsign.circle.fill"
        case .autopay: "creditcard.fill"
        case .amenities: "calendar"
        case .community: "person.2.fill"
        }
    }

    var columnName: String {
        switch self {
        case .packages: "packages_enabled"
        case .guests: "guests_enabled"
        case .tickets: "tickets_enabled"
        case .chargesPosted: "charges_posted_enabled"
        case .autopay: "autopay_enabled"
        case .amenities: "amenities_enabled"
        case .community: "community_enabled"
        }
    }
}

nonisolated struct NotificationPreferences: Codable, Hashable, Sendable {
    var user_id: String
    var packages_enabled: Bool?
    var guests_enabled: Bool?
    var tickets_enabled: Bool?
    var charges_posted_enabled: Bool?
    var autopay_enabled: Bool?
    var amenities_enabled: Bool?
    var community_enabled: Bool?

    func isEnabled(_ category: NotificationCategory) -> Bool {
        switch category {
        case .packages: packages_enabled ?? true
        case .guests: guests_enabled ?? true
        case .tickets: tickets_enabled ?? true
        case .chargesPosted: charges_posted_enabled ?? true
        case .autopay: autopay_enabled ?? true
        case .amenities: amenities_enabled ?? true
        case .community: community_enabled ?? true
        }
    }

    func setting(_ category: NotificationCategory, enabled: Bool) -> NotificationPreferences {
        var copy = self
        switch category {
        case .packages: copy.packages_enabled = enabled
        case .guests: copy.guests_enabled = enabled
        case .tickets: copy.tickets_enabled = enabled
        case .chargesPosted: copy.charges_posted_enabled = enabled
        case .autopay: copy.autopay_enabled = enabled
        case .amenities: copy.amenities_enabled = enabled
        case .community: copy.community_enabled = enabled
        }
        return copy
    }

    static func defaults(userId: String) -> NotificationPreferences {
        NotificationPreferences(
            user_id: userId,
            packages_enabled: true,
            guests_enabled: true,
            tickets_enabled: true,
            charges_posted_enabled: true,
            autopay_enabled: true,
            amenities_enabled: true,
            community_enabled: true
        )
    }
}
