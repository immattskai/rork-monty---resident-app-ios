import SwiftUI

struct GlassCard<Content: View>: View {
    var padding: CGFloat = Theme.Space.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.surface)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.02), radius: 1, x: 0, y: 1)
    }
}

/// Apple Wallet / Health–style section header: sentence-case, prominent.
/// Optional `count` shows a soft pill, optional `action` shows a trailing button.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var count: Int? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    /// When true, omits horizontal padding so the header fits inside an already-padded container.
    var inline: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.textPrimary)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.divider))
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 6)
            if let action, let label = actionLabel {
                Button(label, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.horizontal, inline ? 0 : Theme.Space.lg)
    }
}
