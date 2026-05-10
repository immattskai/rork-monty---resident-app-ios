import SwiftUI

@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    private static let key = "monty.appearance.mode.v1"

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let m = Mode(rawValue: raw) {
            self.mode = m
        } else {
            // Dark by default per spec.
            self.mode = .dark
        }
    }
}
