import SwiftUI
import SafariServices

struct LoginView: View {
    @Environment(AppState.self) private var app

    @State private var email = ""
    @State private var password = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showForgot = false
    @FocusState private var focused: Field?

    enum Field { case email, password }

    // Marketing palette
    private static let heroBackground = Color(hex: 0x09090B) // zinc-950
    private static let heroSubtle = Color.chrome(0.62)
    private static let heroMuted = Color.chrome(0.42)
    private static let gradientStart = Color(hex: 0xF59E0B) // amber-500
    private static let gradientEnd = Color(hex: 0xEA580C)   // orange-600
    private static let inputFill = Color(hex: 0xF4F4F5)     // zinc-100

    private var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Self.gradientStart, Self.gradientEnd],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Self.heroBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        hero
                            .padding(.top, max(geo.safeAreaInsets.top, 24) + 8)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 36)

                        formCard
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)

                        Text("© 2026 monty")
                            .font(.system(size: 12))
                            .foregroundStyle(Self.heroMuted)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .sheet(isPresented: $showForgot) {
            if let url = URL(string: "https://montyliving.com/forgot-password") {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("monty")
                .font(.system(size: 28, weight: .semibold, design: .default))
                .kerning(-0.7)
                .foregroundStyle(Theme.textPrimary)

            Spacer().frame(height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your building,")
                    .font(.system(size: 40, weight: .semibold, design: .default))
                    .kerning(-1.2)
                    .foregroundStyle(Theme.textPrimary)
                Text("in your pocket.")
                    .font(.system(size: 40, weight: .semibold, design: .default))
                    .kerning(-1.2)
                    .foregroundStyle(brandGradient)
            }

            Text("Access documents, submit requests, book amenities, and stay connected with your building — all in one place.")
                .font(.system(size: 15))
                .foregroundStyle(Self.heroSubtle)
                .lineSpacing(3)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Form card

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome back")
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .kerning(-0.4)
                    .foregroundStyle(Color(hex: 0x09090B))
                Text("Sign in to your resident account")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x71717A)) // zinc-500
            }

            VStack(spacing: 14) {
                field(title: "Email", text: $email, secure: false, content: .emailAddress)
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Password")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: 0x3F3F46))
                        Spacer()
                        Button("Forgot password?") { showForgot = true }
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x71717A))
                    }
                    inputBackground {
                        SecureField("", text: $password)
                            .textContentType(.password)
                    }
                }
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await signIn() } }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xB23B3B))
            }

            Button {
                Task { await signIn() }
            } label: {
                HStack(spacing: 8) {
                    if loading { ProgressView().tint(.white) }
                    Text(loading ? "Signing in…" : "Sign In")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(brandGradient)
                .clipShape(.rect(cornerRadius: 12))
                .opacity(canSubmit ? 1 : 0.55)
                .shadow(color: Self.gradientEnd.opacity(0.25), radius: 14, x: 0, y: 6)
            }
            .disabled(!canSubmit)

            VStack(spacing: 6) {
                Text("Don't have an account? Contact your building manager for access.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0x71717A))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .background(Color.white)
        .clipShape(.rect(cornerRadius: 24))
        .shadow(color: Theme.cardDropShadow, radius: 30, x: 0, y: 12)
    }

    // MARK: - Field helpers

    @ViewBuilder
    private func field(title: String, text: Binding<String>, secure: Bool, content: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: 0x3F3F46))
            inputBackground {
                if secure {
                    SecureField("", text: text)
                        .textContentType(content)
                } else {
                    TextField("", text: text)
                        .textContentType(content)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled(true)
                }
            }
        }
    }

    @ViewBuilder
    private func inputBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 16))
            .foregroundStyle(Color(hex: 0x09090B))
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Self.inputFill)
            .clipShape(.rect(cornerRadius: 10))
    }

    private var canSubmit: Bool {
        !loading && email.contains("@") && password.count >= 6
    }

    private func signIn() async {
        guard canSubmit else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            _ = try await SupabaseAPI.shared.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            await app.loadAfterAuth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
