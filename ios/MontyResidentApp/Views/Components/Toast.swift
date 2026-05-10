import SwiftUI

/// Unified toast for the whole app. Replaces MontyToast / ToastBanner duplicates.
struct Toast: View {
    let text: String
    var icon: String? = nil
    var tone: Tone = .neutral

    enum Tone { case neutral, success, danger, warning }

    private var bg: Color {
        switch tone {
        case .neutral: return Theme.accent
        case .success: return Theme.success
        case .danger:  return Theme.danger
        case .warning: return Theme.warning
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule(style: .continuous).fill(bg))
        .shadow(color: Theme.cardDropShadow, radius: 14, y: 6)
        .padding(.horizontal, 24)
    }
}

/// View modifier — bind a `String?`; the toast appears at the bottom and auto-dismisses.
struct MontyToastModifier: ViewModifier {
    @Binding var message: String?
    var icon: String?
    var tone: Toast.Tone
    var seconds: Double

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let m = message {
                    Toast(text: m, icon: icon, tone: tone)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(seconds))
                            withAnimation(Theme.Motion.smooth) { message = nil }
                        }
                }
            }
            .animation(Theme.Motion.smooth, value: message)
    }
}

extension View {
    /// Show a toast at the bottom whenever `message` is non-nil; auto-dismisses.
    func montyToast(_ message: Binding<String?>, icon: String? = nil, tone: Toast.Tone = .neutral, seconds: Double = 2.4) -> some View {
        modifier(MontyToastModifier(message: message, icon: icon, tone: tone, seconds: seconds))
    }
}
