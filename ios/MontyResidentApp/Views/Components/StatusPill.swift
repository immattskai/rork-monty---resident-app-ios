import SwiftUI

struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone: Hashable {
        case neutral, success, warning, danger, info
        case custom(Color)
    }

    private var fg: Color {
        switch tone {
        case .neutral: return Theme.textSecondary
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .danger: return Theme.danger
        case .info: return Theme.info
        case .custom(let c): return c
        }
    }

    private var bg: Color { fg.opacity(0.12) }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous).fill(bg)
            )
    }
}

extension StatusPill {
    static func ticket(_ status: String?) -> StatusPill {
        switch (status ?? "").lowercased() {
        case "open", "new": return StatusPill(text: status ?? "Open", tone: .info)
        case "in_progress", "in-progress", "pending": return StatusPill(text: status ?? "Pending", tone: .warning)
        case "resolved", "closed", "completed": return StatusPill(text: status ?? "Closed", tone: .success)
        case "urgent", "high": return StatusPill(text: status ?? "Urgent", tone: .danger)
        default: return StatusPill(text: status ?? "—", tone: .neutral)
        }
    }

    static func package(_ status: String?) -> StatusPill {
        switch (status ?? "").lowercased() {
        case "received", "available": return StatusPill(text: status ?? "Ready", tone: .info)
        case "picked_up", "delivered": return StatusPill(text: status ?? "Picked up", tone: .success)
        default: return StatusPill(text: status ?? "—", tone: .neutral)
        }
    }
}
