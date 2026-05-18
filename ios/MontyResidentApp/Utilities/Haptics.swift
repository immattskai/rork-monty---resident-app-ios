import UIKit

/// Pre-warmed haptic generators. Reuse a single instance per style and call
/// `prepare()` so the taptic engine is already spun up by the time the user
/// taps. Significantly improves perceived responsiveness vs. creating a fresh
/// `UIImpactFeedbackGenerator` on each tap.
@MainActor
enum Haptics {
    private static let light: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()

    private static let medium: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium)
        g.prepare()
        return g
    }()

    private static let soft: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        return g
    }()

    static func tap() {
        light.impactOccurred()
        // Re-prepare so the next tap is also instant.
        light.prepare()
    }

    static func mediumTap() {
        medium.impactOccurred()
        medium.prepare()
    }

    static func softTap() {
        soft.impactOccurred()
        soft.prepare()
    }
}
