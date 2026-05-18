import SwiftUI
@preconcurrency import WebKit

/// Hosts the Moov Drops `<moov-card-link>` web component inside a WKWebView.
///
/// Architecture (PCI SAQ-A):
/// - Raw PAN / CVV are entered into the Moov-hosted iframe and posted directly
///   from there to Moov. They NEVER touch our app or our servers.
/// - The page emits a JS bridge message (`window.webkit.messageHandlers.moov.postMessage({...})`)
///   when the card is successfully tokenized. We pull the `paymentMethodID`
///   from that message and hand it back to the flow.
struct MoovDropsView: View {
    let oauthToken: String
    let accountId: String
    let onSuccess: (_ paymentMethodId: String, _ brand: String?, _ last4: String?) -> Void
    let onCancel: () -> Void
    let onError: (_ message: String) -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            DropsWebView(
                html: Self.cardLinkHTML(token: oauthToken, accountId: accountId),
                onSuccess: onSuccess,
                onError: onError
            )
            VStack {
                HStack {
                    Button {
                        Haptics.tap()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.premiumCard))
                            .overlay(Circle().stroke(Color.chrome(0.08), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Add card")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    // Spacer of equal width for visual symmetry.
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
    }

    /// HTML shell that loads Moov.js and renders the hosted card-link component.
    /// PAN/CVV are typed into Moov's iframe inside this page — the iframe posts
    /// the tokenized card directly to Moov, then JS calls back with the
    /// `paymentMethodID`. We forward that to native via the message bridge.
    private static func cardLinkHTML(token: String, accountId: String) -> String {
        // Escape the token/account safely (they're short opaque IDs but be defensive).
        let safeToken = token.replacingOccurrences(of: "\"", with: "\\\"")
        let safeAccount = accountId.replacingOccurrences(of: "\"", with: "\\\"")
        return #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Add Card</title>
  <script src="https://js.moov.io/v1"></script>
  <style>
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    body { padding: 60px 20px 24px; }
    moov-card-link { display: block; min-height: 440px; }
  </style>
</head>
<body>
  <moov-card-link
    oauth-token="\#(safeToken)"
    account-id="\#(safeAccount)"
    id="cardLink"
  ></moov-card-link>
  <script>
    function post(msg) {
      try { window.webkit.messageHandlers.moov.postMessage(msg); } catch (e) {}
    }
    const el = document.getElementById('cardLink');
    el.addEventListener('success', (e) => {
      const d = (e && e.detail) || {};
      post({
        type: 'success',
        paymentMethodID: d.paymentMethodID || d.paymentMethodId || d.id || '',
        brand: (d.card && d.card.brand) || d.brand || '',
        last4: (d.card && d.card.lastFourCardNumber) || d.last4 || ''
      });
    });
    el.addEventListener('error', (e) => {
      const d = (e && e.detail) || {};
      post({ type: 'error', message: (d.error && d.error.message) || d.message || 'Card linking failed' });
    });
  </script>
</body>
</html>
"""#
    }
}

private struct DropsWebView: UIViewRepresentable {
    let html: String
    let onSuccess: (_ paymentMethodId: String, _ brand: String?, _ last4: String?) -> Void
    let onError: (_ message: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "moov")
        cfg.userContentController = ucc
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.loadHTMLString(html, baseURL: URL(string: "https://montyliving.com"))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onSuccess: (_ paymentMethodId: String, _ brand: String?, _ last4: String?) -> Void
        let onError: (_ message: String) -> Void

        init(
            onSuccess: @escaping (_ paymentMethodId: String, _ brand: String?, _ last4: String?) -> Void,
            onError: @escaping (_ message: String) -> Void
        ) {
            self.onSuccess = onSuccess
            self.onError = onError
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any] else { return }
            let type = (dict["type"] as? String) ?? ""
            switch type {
            case "success":
                let pmid = (dict["paymentMethodID"] as? String) ?? ""
                let brand = (dict["brand"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let last4 = (dict["last4"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard !pmid.isEmpty else {
                    onError("Card linked but no token returned.")
                    return
                }
                Task { @MainActor in onSuccess(pmid, brand, last4) }
            case "error":
                let msg = (dict["message"] as? String) ?? "Card linking failed."
                Task { @MainActor in onError(msg) }
            default:
                break
            }
        }
    }
}
