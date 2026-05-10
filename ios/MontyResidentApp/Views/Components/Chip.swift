import SwiftUI

/// Small informational chip — replaces the half-dozen inline pill implementations.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var tone: Tone = .neutral

    enum Tone {
        case neutral, info, success, warning, danger, brand
        case custom(Color)

        var color: Color {
            switch self {
            case .neutral: return Theme.textSecondary
            case .info:    return Theme.info
            case .success: return Theme.success
            case .warning: return Theme.warning
            case .danger:  return Theme.danger
            case .brand:   return Color(hex: 0xF26A1F)
            case .custom(let c): return c
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(tone.color.opacity(0.12)))
    }
}

/// Standard selectable filter chip — replaces inline filter-pill implementations.
struct FilterChip: View {
    let label: String
    let isSelected: Bool
    var count: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? Color.chrome(0.22) : Theme.divider)
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? Theme.accent : Theme.surface)
            )
            .overlay(
                Capsule().stroke(isSelected ? .clear : Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
