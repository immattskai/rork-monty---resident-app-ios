import SwiftUI
import Foundation

struct EmptyState: View {
    let icon: String
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textMuted)
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            if let message {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
    }
}

struct ErrorState: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.danger)
            Text("Something went wrong")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().stroke(Theme.border, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

struct SkeletonRow: View {
    var height: CGFloat = 64
    @State private var phase: CGFloat = 0
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .fill(Theme.divider)
            .frame(height: height)
            .opacity(0.6 + Foundation.sin(Double(phase)) * 0.2)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(60))
                    phase += 0.12
                }
            }
    }
}
