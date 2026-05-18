import SwiftUI
import UserNotifications

struct NotificationOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    var onFinished: () -> Void = {}

    @State private var loading: Bool = false

    var body: some View {
        ZStack {
            backdropGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                bellArtwork
                    .padding(.bottom, 28)

                VStack(spacing: 12) {
                    Text("Stay in the loop")
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Get notified about packages, guests, new charges, autopay, ticket updates, amenity bookings, and community posts.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 28)
                }
                .padding(.bottom, 28)

                categoriesGrid
                    .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        Task { await enable() }
                    } label: {
                        HStack(spacing: 8) {
                            if loading { ProgressView().tint(.black) }
                            Text("Turn on notifications")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white)
                        .clipShape(.rect(cornerRadius: 14))
                    }
                    .disabled(loading)

                    Button {
                        finish()
                    } label: {
                        Text("Maybe later")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private var backdropGradient: some View {
        LinearGradient(
            colors: [Color(hex: 0x0E1014), Color(hex: 0x161A21)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var bellArtwork: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0xF59E0B).opacity(0.45), .clear],
                        center: .center, startRadius: 4, endRadius: 100
                    )
                )
                .frame(width: 220, height: 220)
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 130, height: 130)
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: 0xFFB452), Color(hex: 0xF26A1F)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: Color(hex: 0xF26A1F).opacity(0.45), radius: 18, y: 6)
        }
    }

    private var categoriesGrid: some View {
        let cats = NotificationCategory.allCases
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            ForEach(cats) { c in
                HStack(spacing: 10) {
                    Image(systemName: c.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.1))
                        .clipShape(.rect(cornerRadius: 8))
                    Text(c.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    private func enable() async {
        loading = true
        defer { loading = false }
        Haptics.mediumTap()
        _ = await NotificationsManager.shared.requestPermission()
        finish()
    }

    private func finish() {
        NotificationsManager.shared.hasShownSoftAsk = true
        onFinished()
        dismiss()
    }
}
