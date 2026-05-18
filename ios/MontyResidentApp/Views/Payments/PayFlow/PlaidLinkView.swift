import SwiftUI
import LinkKit

/// Presents Plaid Link iOS natively. On success returns the `public_token`
/// (and selected account_id, if any) via `onSuccess`. The caller is
/// responsible for exchanging the public_token via the edge function.
///
/// Uses the LinkKit 6.x `Plaid.create(_:)` UIViewController API and wraps it
/// in a `UIViewControllerRepresentable`. We present it as a fullscreen cover.
struct PlaidLinkView: UIViewControllerRepresentable {
    let linkToken: String
    /// Called with `public_token` and the first selected `account_id` (nilable).
    /// `metadata` is the raw event metadata if the server wants it.
    let onSuccess: (_ publicToken: String, _ accountId: String?, _ metadata: [String: Any]) -> Void
    let onExit: (_ error: String?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        var config = LinkTokenConfiguration(token: linkToken) { success in
            // success.publicToken, success.metadata.accounts[0].id
            let pub = success.publicToken
            let accountId = success.metadata.accounts.first?.id
            var meta: [String: Any] = [
                "institution_id": success.metadata.institution.id,
                "institution_name": success.metadata.institution.name,
            ]
            if let acc = success.metadata.accounts.first {
                meta["account_id"] = acc.id
                meta["account_name"] = acc.name
                meta["account_mask"] = acc.mask ?? ""
                meta["account_subtype"] = acc.subtype.description
            }
            onSuccess(pub, accountId, meta)
        }
        config.onExit = { exit in
            onExit(exit.error?.errorMessage)
        }
        let result = Plaid.create(config)
        switch result {
        case .success(let handler):
            // Stash the handler in the coordinator so it isn't deallocated
            // before the user finishes / cancels.
            context.coordinator.handler = handler
            let container = UIViewController()
            container.view.backgroundColor = .clear
            // Present once the container is attached to the window.
            DispatchQueue.main.async { [weak container] in
                guard let container else { return }
                handler.open(presentUsing: .viewController(container))
            }
            return container
        case .failure(let error):
            // Surface immediately and dismiss.
            DispatchQueue.main.async {
                onExit(error.localizedDescription)
            }
            return UIViewController()
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var handler: Handler?
    }
}
