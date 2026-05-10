import SwiftUI

struct NonResidentBlockView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.lg) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text("Use the MontyResidentApp web app")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Please use the MontyResidentApp web app at montyliving.com.\nThis iOS app is for residents only.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.xl)
                Button {
                    Task { await app.signOut() }
                } label: {
                    Text("Back to sign in")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Capsule().fill(Theme.accent))
                }
                .padding(.top, Theme.Space.md)
            }
            .padding(Theme.Space.xl)
        }
    }
}
