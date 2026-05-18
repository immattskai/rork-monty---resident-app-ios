import Foundation

/// All server interactions for Moov + Plaid payments.
///
/// Architecture (per PCI memo):
/// - Monty is the master Moov facilitator account.
/// - Each property is a child wallet.
/// - Residents are guests — they do not have their own Moov account; payment
///   methods are tokenized against the master account.
/// - Raw PAN / routing / account numbers NEVER touch our servers or this code.
///   Card capture is via Moov Drops (WKWebView, posts directly to Moov).
///   Bank linking is via the native Plaid Link iOS SDK; the public_token is
///   exchanged server-side for a Moov paymentMethodId.
///
/// All amounts are integer cents end-to-end.
@MainActor
enum MoovPaymentsService {
    // MARK: - Edge functions

    /// Saved payment methods for the resident. Mirrors web `useResidentPayments`.
    static func listPaymentMethods() async throws -> [MoovPaymentMethod] {
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-payment-methods",
            body: [:],
            timeout: 30
        )
        // Server returns either { paymentMethods: [...] } or a bare array.
        if let envelope = try? JSONDecoder().decode(PaymentMethodsEnvelope.self, from: data),
           let pms = envelope.paymentMethods {
            return pms
        }
        if let bare = try? JSONDecoder().decode([MoovPaymentMethod].self, from: data) {
            return bare
        }
        return []
    }

    /// Ensures the resident's Moov guest account exists and returns a short-lived
    /// OAuth token + accountId for the Moov Drops card-link web component.
    static func cardLinkToken() async throws -> MoovDropsToken {
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-token",
            body: ["scope": "card-link"],
            timeout: 30
        )
        return try decodeOrThrow(data, as: MoovDropsToken.self)
    }

    /// Fetch a Plaid Link token. The server creates a link_token via Plaid's
    /// `/link/token/create` endpoint with `processor_token: moov` capability.
    static func plaidLinkToken() async throws -> String {
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-plaid-link",
            body: ["action": "create_link_token"],
            timeout: 30
        )
        let resp = try decodeOrThrow(data, as: PlaidLinkTokenResponse.self)
        guard !resp.linkToken.isEmpty else {
            throw PaymentsError.server("Couldn't start Plaid Link. Please try again.")
        }
        return resp.linkToken
    }

    /// Exchanges Plaid `public_token` server-side for a Moov payment method.
    static func exchangePlaidPublicToken(
        publicToken: String,
        accountId: String?,
        metadata: [String: Any]?
    ) async throws -> MoovPaymentMethod {
        var body: [String: Any] = [
            "action": "exchange",
            "public_token": publicToken,
        ]
        if let accountId, !accountId.isEmpty { body["account_id"] = accountId }
        if let metadata { body["metadata"] = metadata }
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-plaid-link",
            body: body,
            timeout: 60
        )
        // Server may wrap in { paymentMethod: {...} } or return bare object.
        if let env = try? JSONDecoder().decode(SinglePaymentMethodEnvelope.self, from: data),
           let pm = env.paymentMethod {
            return pm
        }
        return try decodeOrThrow(data, as: MoovPaymentMethod.self)
    }

    /// Preview a charge — server computes the fee. NEVER compute fees locally.
    static func previewTransfer(
        chargeId: String?,
        paymentMethodId: String,
        amountCents: Int
    ) async throws -> TransferPreview {
        var body: [String: Any] = [
            "paymentMethodId": paymentMethodId,
            "amountCents": amountCents,
            "preview": true,
        ]
        if let chargeId, !chargeId.isEmpty { body["chargeId"] = chargeId }
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-transfers",
            body: body,
            timeout: 30
        )
        try throwIfCapabilityMissing(data)
        return try decodeOrThrow(data, as: TransferPreview.self)
    }

    /// Execute the charge. Returns the transfer group on success.
    static func processTransfer(
        chargeId: String?,
        paymentMethodId: String,
        amountCents: Int
    ) async throws -> TransferResult {
        var body: [String: Any] = [
            "paymentMethodId": paymentMethodId,
            "amountCents": amountCents,
        ]
        if let chargeId, !chargeId.isEmpty { body["chargeId"] = chargeId }
        let data = try await MontyResidentAppService.invokeFunction(
            name: "moov-transfers",
            body: body,
            timeout: 90
        )
        try throwIfCapabilityMissing(data)
        return try decodeOrThrow(data, as: TransferResult.self)
    }

    // MARK: - Helpers

    private nonisolated struct PaymentMethodsEnvelope: Decodable, Sendable {
        let paymentMethods: [MoovPaymentMethod]?

        enum CodingKeys: String, CodingKey {
            case paymentMethods, payment_methods
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.paymentMethods = (try? c.decodeIfPresent([MoovPaymentMethod].self, forKey: .paymentMethods))
                ?? (try? c.decodeIfPresent([MoovPaymentMethod].self, forKey: .payment_methods))
        }
    }

    private nonisolated struct SinglePaymentMethodEnvelope: Decodable, Sendable {
        let paymentMethod: MoovPaymentMethod?

        enum CodingKeys: String, CodingKey {
            case paymentMethod, payment_method
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.paymentMethod = (try? c.decodeIfPresent(MoovPaymentMethod.self, forKey: .paymentMethod))
                ?? (try? c.decodeIfPresent(MoovPaymentMethod.self, forKey: .payment_method))
        }
    }

    private nonisolated struct ServerError: Decodable, Sendable {
        let code: String?
        let message: String?
        let error: String?
    }

    /// If the response body contains `code: capability_missing`, surface the
    /// friendly capability error instead of decoding a transfer.
    private static func throwIfCapabilityMissing(_ data: Data) throws {
        if let err = try? JSONDecoder().decode(ServerError.self, from: data),
           (err.code ?? "").lowercased() == "capability_missing" {
            throw PaymentsError.capabilityMissing
        }
    }

    private static func decodeOrThrow<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        if let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        if let err = try? JSONDecoder().decode(ServerError.self, from: data) {
            if (err.code ?? "").lowercased() == "capability_missing" {
                throw PaymentsError.capabilityMissing
            }
            let msg = err.message ?? err.error ?? "Something went wrong."
            throw PaymentsError.server(msg)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw PaymentsError.server(raw.isEmpty ? "Unexpected response from server." : raw)
    }

    // MARK: - Error mapping

    /// Maps any thrown error from a payments call into the user-facing message.
    /// Special-cases `capability_missing` payloads buried inside SupabaseError.http.
    static func friendlyMessage(_ error: Error) -> String {
        if let p = error as? PaymentsError { return p.localizedDescription }
        if case let SupabaseError.http(_, body) = error {
            if body.lowercased().contains("capability_missing") {
                return PaymentsError.capabilityMissing.localizedDescription
            }
            // Try to pull a `message` field out of the body.
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let m = (obj["message"] as? String) ?? (obj["error"] as? String) {
                return m
            }
            return body.isEmpty ? "Payment failed. Please try again." : body
        }
        return error.localizedDescription
    }
}
