import SwiftUI
import UIKit

// Tokens automatically adapt to light/dark via UIColor dynamicProvider.
// Dark = default app aesthetic. Light retains the original off-white/Wallet feel.
enum Theme {
    // Backgrounds — warm neutral "premium parchment" in light, atmospheric midnight in dark.
    static let background = Color.dynamic(light: 0xF7F5F1, dark: 0x030406)
    static let surface = Color.dynamic(light: 0xFCFBF8, dark: 0x111114)
    static let surfaceElevated = Color.dynamic(light: 0xFCFBF8, dark: 0x14151A)
    static let surfaceSunken = Color.dynamic(light: 0xF1EEE8, dark: 0x0B0C10)

    // Card gradient stops (used by montyCard).
    static let cardTop = Color.dynamic(light: 0xFCFBF8, dark: 0x16161A)
    static let cardBottom = Color.dynamic(light: 0xF7F4EE, dark: 0x101013)

    // Premium near-black card surface used on Home (Ask Monty, tiles, announcements,
    // notifications banner). Adapts to a warm off-white card in light mode.
    static let premiumDark = Color.dynamic(light: 0xFCFBF8, dark: 0x121317)
    // Slightly sunken premium surface (icon chips, board tile background, search inputs).
    static let premiumDarkInset = Color.dynamic(light: 0xF1EEE8, dark: 0x111418)
    // Premium card surface used on secondary screens (Tickets, Payments, Packages, etc).
    static let premiumCard = Color.dynamic(light: 0xFCFBF8, dark: 0x121317)

    // Adaptive drop shadow used under premium cards. Soft & subtle in light,
    // moody/atmospheric in dark.
    static let cardDropShadow = Color.dynamic(light: 0x000000, lightAlpha: 0.05,
                                              dark: 0x000000, darkAlpha: 0.24)
    // Hero photo base (behind AsyncImage).
    static let heroBase = Color.dynamic(light: 0xE8E2D6, dark: 0x05080F)

    // Text — softer, warm-neutral contrast in light.
    static let textPrimary = Color.dynamic(light: 0x151515, dark: 0xF4F4F6)
    static let textSecondary = Color.dynamic(light: 0x66625C,
                                              dark: 0xFFFFFF, darkAlpha: 0.68)
    static let textMuted = Color.dynamic(light: 0x908B84, dark: 0x6E7079)

    // Borders / dividers — barely-there edge highlights, neutral-warm tint in light.
    static let border = Color.dynamic(light: 0x141414, lightAlpha: 0.06,
                                       dark: 0xFFFFFF, darkAlpha: 0.05)
    static let divider = Color.dynamic(light: 0x141414, lightAlpha: 0.05,
                                        dark: 0x1A1B20, darkAlpha: 1.0)

    // Soft, blue-tinted ambient shadow.
    static let cardShadow = Color.dynamic(light: 0x000000, lightAlpha: 0.04,
                                          dark: 0x5078FF, darkAlpha: 0.10)

    // Accent (graphite in light, near-white in dark)
    static let accent = Color.dynamic(light: 0x151515, dark: 0xF4F4F6)

    // Brand accents — slightly deeper, less peachy orange in light mode.
    static let accentBlue = Color(hex: 0x4DA3FF)
    static let accentAmber = Color.dynamic(light: 0xC9864A, dark: 0xFF8A1F)

    // Status — slightly brighter in dark for AA contrast.
    static let success = Color.dynamic(light: 0x2E7D5B, dark: 0x42C18A)
    static let warning = Color.dynamic(light: 0xB8862C, dark: 0xE8B454)
    static let danger = Color.dynamic(light: 0xB23B3B, dark: 0xF26A6A)
    static let info = Color.dynamic(light: 0x365A80, dark: 0x6FA8E0)

    // Modal backdrop
    static let backdrop = Color.black.opacity(0.30)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let card: CGFloat = 18
    }

    enum Shadow {
        static let card: (color: Color, radius: CGFloat, y: CGFloat) = (Theme.cardShadow, 10, 3)
        static let elevated: (color: Color, radius: CGFloat, y: CGFloat) =
            (Color.dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0x000000, darkAlpha: 0.55), 18, 8)
        static let subtle: (color: Color, radius: CGFloat, y: CGFloat) =
            (Color.dynamic(light: 0x000000, lightAlpha: 0.03, dark: 0x000000, darkAlpha: 0.30), 4, 1)
    }

    enum Motion {
        // Liquid, restrained — Apple Wallet / Linear feel. No bouncy springs.
        static let snap: Animation = .easeOut(duration: 0.22)
        static let smooth: Animation = .easeInOut(duration: 0.32)
        static let bouncy: Animation = .spring(response: 0.42, dampingFraction: 0.92)
    }
}

// MARK: - Atmospheric background

/// Layered "midnight luxury" background — base + navy gradient + radial blue glow + vignette.
/// Reduces to flat `Theme.background` in light mode.
struct AtmosphericBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.background
            if scheme == .dark {
                // Multi-stop wash: navy lifts off the top, easing through midnight
                // tones into deep space. Eliminates the hard seam where a 2-stop
                // gradient used to cut from blue to black.
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x0A1230).opacity(0.98), location: 0.00),
                        .init(color: Color(hex: 0x080F26).opacity(0.96), location: 0.18),
                        .init(color: Color(hex: 0x060A1C).opacity(0.94), location: 0.34),
                        .init(color: Color(hex: 0x040713).opacity(0.96), location: 0.52),
                        .init(color: Color(hex: 0x03050C), location: 0.72),
                        .init(color: Color(hex: 0x020308), location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                // Soft upper glow — wider, lower opacity so it melts into the
                // gradient instead of stamping a halo on top.
                RadialGradient(
                    colors: [Color(hex: 0x4DA3FF).opacity(0.04), .clear],
                    center: .init(x: 0.5, y: -0.05),
                    startRadius: 0, endRadius: 520
                )
                .blendMode(.screen)
                RadialGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    center: .center,
                    startRadius: 200, endRadius: 720
                )
                .blendMode(.multiply)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Card chrome modifier

struct MontyCardModifier: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = Theme.Radius.card
    var elevated: Bool = false

    func body(content: Content) -> some View {
        let s = elevated ? Theme.Shadow.elevated : Theme.Shadow.card
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.cardTop, Theme.cardBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                // Edge highlight + soft border.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.02),
                                Color.black.opacity(0.20)
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
            )
            .shadow(color: s.color, radius: s.radius * 1.6, y: s.y + 2)
    }
}

extension View {
    func montyCard(padding: CGFloat = 14, radius: CGFloat = Theme.Radius.card, elevated: Bool = false) -> some View {
        modifier(MontyCardModifier(padding: padding, radius: radius, elevated: elevated))
    }
}

extension Color {
    /// Adaptive chrome tint: white@opacity in dark mode, black@opacity in light mode.
    /// Use this anywhere we previously wrote `Color.white.opacity(x)` for UI chrome
    /// (fills, strokes, secondary text, chips, dividers, skeletons).
    static func chrome(_ opacity: Double) -> Color {
        Color(uiColor: UIColor { trait in
            switch trait.userInterfaceStyle {
            case .dark: return UIColor(white: 1.0, alpha: CGFloat(opacity))
            default:    return UIColor(white: 0.0, alpha: CGFloat(opacity))
            }
        })
    }

    /// Adaptive inverse chrome: black@opacity in dark, white@opacity in light.
    /// Useful for text/elements that sit on top of the hero photo wash.
    static func chromeInverse(_ opacity: Double) -> Color {
        Color(uiColor: UIColor { trait in
            switch trait.userInterfaceStyle {
            case .dark: return UIColor(white: 0.0, alpha: CGFloat(opacity))
            default:    return UIColor(white: 1.0, alpha: CGFloat(opacity))
            }
        })
    }

    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Dynamic color that resolves to `light` in light mode and `dark` in dark mode.
    static func dynamic(light: UInt32, lightAlpha: Double = 1.0,
                        dark: UInt32, darkAlpha: Double = 1.0) -> Color {
        Color(uiColor: UIColor { trait in
            switch trait.userInterfaceStyle {
            case .dark: return UIColor(rgb: dark, alpha: darkAlpha)
            default:    return UIColor(rgb: light, alpha: lightAlpha)
            }
        })
    }
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32, alpha: Double = 1.0) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}
