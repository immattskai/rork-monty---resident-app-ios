import Foundation

// MARK: - Moov / Plaid Payment Models
//
// Money is ALWAYS handled as integer cents end-to-end. Never multiply/divide
// for display until the very last step (`Fmt.currency(cents)`).

/// Tokenized payment method tied to the master Moov facilitator account.
/// We never see PAN / routing / account numbers — only this opaque
/// `paymentMethodId` token plus display hints.
nonisolated struct MoovPaymentMethod: Codable, Identifiable, Hashable, Sendable {
    /// Moov payment method id (token). The only thing we ever send back.
    let payment_method_id: String
    /// "card" | "ach"
    var method_type: String
    var brand: String?
    var last4: String?
    /// e.g. "Chase", "Bank of America" — populated for ACH only.
    var bank_name: String?
    var exp_month: Int?
    var exp_year: Int?
    var is_default: Bool?
    var created_at: String?

    var id: String { payment_method_id }

    var isCard: Bool { method_type.lowercased() == "card" }
    var isACH: Bool {
        let m = method_type.lowercased()
        return m == "ach" || m == "bank" || m == "bankaccount"
    }

    /// "Visa •••• 4242" or "Chase •••• 1234".
    var displayLabel: String {
        let name = isCard ? (brand ?? "Card") : (bank_name ?? "Bank")
        if let l4 = last4, !l4.isEmpty { return "\(name) •••• \(l4)" }
        return name
    }

    enum CodingKeys: String, CodingKey {
        case payment_method_id, paymentMethodId
        case method_type, methodType, type
        case brand, last4, bank_name, bankName
        case exp_month, expMonth, exp_year, expYear
        case is_default, isDefault
        case created_at, createdAt
    }

    init(
        payment_method_id: String,
        method_type: String,
        brand: String? = nil,
        last4: String? = nil,
        bank_name: String? = nil,
        exp_month: Int? = nil,
        exp_year: Int? = nil,
        is_default: Bool? = nil,
        created_at: String? = nil
    ) {
        self.payment_method_id = payment_method_id
        self.method_type = method_type
        self.brand = brand
        self.last4 = last4
        self.bank_name = bank_name
        self.exp_month = exp_month
        self.exp_year = exp_year
        self.is_default = is_default
        self.created_at = created_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pmid = (try? c.decodeIfPresent(String.self, forKey: .payment_method_id))
            ?? (try? c.decodeIfPresent(String.self, forKey: .paymentMethodId))
            ?? ""
        self.payment_method_id = pmid
        let mt = (try? c.decodeIfPresent(String.self, forKey: .method_type))
            ?? (try? c.decodeIfPresent(String.self, forKey: .methodType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .type))
            ?? "card"
        self.method_type = mt
        self.brand = (try? c.decodeIfPresent(String.self, forKey: .brand))
        self.last4 = (try? c.decodeIfPresent(String.self, forKey: .last4))
        self.bank_name = (try? c.decodeIfPresent(String.self, forKey: .bank_name))
            ?? (try? c.decodeIfPresent(String.self, forKey: .bankName))
        self.exp_month = (try? c.decodeIfPresent(Int.self, forKey: .exp_month))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .expMonth))
        self.exp_year = (try? c.decodeIfPresent(Int.self, forKey: .exp_year))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .expYear))
        self.is_default = (try? c.decodeIfPresent(Bool.self, forKey: .is_default))
            ?? (try? c.decodeIfPresent(Bool.self, forKey: .isDefault))
        self.created_at = (try? c.decodeIfPresent(String.self, forKey: .created_at))
            ?? (try? c.decodeIfPresent(String.self, forKey: .createdAt))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(payment_method_id, forKey: .payment_method_id)
        try c.encode(method_type, forKey: .method_type)
        try c.encodeIfPresent(brand, forKey: .brand)
        try c.encodeIfPresent(last4, forKey: .last4)
        try c.encodeIfPresent(bank_name, forKey: .bank_name)
        try c.encodeIfPresent(exp_month, forKey: .exp_month)
        try c.encodeIfPresent(exp_year, forKey: .exp_year)
        try c.encodeIfPresent(is_default, forKey: .is_default)
        try c.encodeIfPresent(created_at, forKey: .created_at)
    }
}

/// Response from `moov-transfers` with `preview: true`. Mirrors web `usePaymentPreview`.
/// All amounts are integer cents — DO NOT compute fees client-side.
nonisolated struct TransferPreview: Codable, Hashable, Sendable {
    let baseCents: Int
    let feeCents: Int
    let totalCents: Int
    let methodType: String
    var sandbox: Bool?

    enum CodingKeys: String, CodingKey {
        case baseCents, base_cents
        case feeCents, fee_cents, nFee, n_fee
        case totalCents, total_cents
        case methodType, method_type
        case sandbox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.baseCents = (try? c.decodeIfPresent(Int.self, forKey: .baseCents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .base_cents))
            ?? 0
        self.feeCents = (try? c.decodeIfPresent(Int.self, forKey: .feeCents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .fee_cents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .nFee))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .n_fee))
            ?? 0
        self.totalCents = (try? c.decodeIfPresent(Int.self, forKey: .totalCents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .total_cents))
            ?? (self.baseCents + self.feeCents)
        self.methodType = (try? c.decodeIfPresent(String.self, forKey: .methodType))
            ?? (try? c.decodeIfPresent(String.self, forKey: .method_type))
            ?? ""
        self.sandbox = (try? c.decodeIfPresent(Bool.self, forKey: .sandbox))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseCents, forKey: .baseCents)
        try c.encode(feeCents, forKey: .feeCents)
        try c.encode(totalCents, forKey: .totalCents)
        try c.encode(methodType, forKey: .methodType)
        try c.encodeIfPresent(sandbox, forKey: .sandbox)
    }
}

/// Response from `moov-transfers` without preview flag — successful payment.
nonisolated struct TransferResult: Codable, Hashable, Sendable {
    let groupId: String
    let baseTransferId: String?
    let totalCents: Int

    enum CodingKeys: String, CodingKey {
        case groupId, group_id
        case baseTransferId, base_transfer_id
        case totalCents, total_cents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = (try? c.decodeIfPresent(String.self, forKey: .groupId))
            ?? (try? c.decodeIfPresent(String.self, forKey: .group_id))
            ?? ""
        self.baseTransferId = (try? c.decodeIfPresent(String.self, forKey: .baseTransferId))
            ?? (try? c.decodeIfPresent(String.self, forKey: .base_transfer_id))
        self.totalCents = (try? c.decodeIfPresent(Int.self, forKey: .totalCents))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .total_cents))
            ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groupId, forKey: .groupId)
        try c.encodeIfPresent(baseTransferId, forKey: .baseTransferId)
        try c.encode(totalCents, forKey: .totalCents)
    }
}

/// Short-lived OAuth token + Moov accountId for the Drops web component.
nonisolated struct MoovDropsToken: Codable, Hashable, Sendable {
    let token: String
    let accountId: String
    var expiresOn: String?

    enum CodingKeys: String, CodingKey {
        case token, oauthToken, oauth_token, accessToken, access_token
        case accountId, account_id, moovAccountId, moov_account_id
        case expiresOn, expires_on, expires_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = (try? c.decodeIfPresent(String.self, forKey: .token))
            ?? (try? c.decodeIfPresent(String.self, forKey: .oauthToken))
            ?? (try? c.decodeIfPresent(String.self, forKey: .oauth_token))
            ?? (try? c.decodeIfPresent(String.self, forKey: .accessToken))
            ?? (try? c.decodeIfPresent(String.self, forKey: .access_token))
            ?? ""
        self.accountId = (try? c.decodeIfPresent(String.self, forKey: .accountId))
            ?? (try? c.decodeIfPresent(String.self, forKey: .account_id))
            ?? (try? c.decodeIfPresent(String.self, forKey: .moovAccountId))
            ?? (try? c.decodeIfPresent(String.self, forKey: .moov_account_id))
            ?? ""
        self.expiresOn = (try? c.decodeIfPresent(String.self, forKey: .expiresOn))
            ?? (try? c.decodeIfPresent(String.self, forKey: .expires_on))
            ?? (try? c.decodeIfPresent(String.self, forKey: .expires_at))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(token, forKey: .token)
        try c.encode(accountId, forKey: .accountId)
        try c.encodeIfPresent(expiresOn, forKey: .expiresOn)
    }
}

/// Plaid Link token returned by our edge function. Pass `linkToken` to LinkKit.
nonisolated struct PlaidLinkTokenResponse: Codable, Hashable, Sendable {
    let linkToken: String

    enum CodingKeys: String, CodingKey {
        case linkToken, link_token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.linkToken = (try? c.decodeIfPresent(String.self, forKey: .linkToken))
            ?? (try? c.decodeIfPresent(String.self, forKey: .link_token))
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(linkToken, forKey: .linkToken)
    }
}

/// Surfaced when the server returns `code: capability_missing` — the property's
/// Moov org isn't set up to receive payments yet. Maps to the friendly copy
/// the web app shows.
nonisolated enum PaymentsError: LocalizedError {
    case capabilityMissing
    case server(String)

    var errorDescription: String? {
        switch self {
        case .capabilityMissing:
            return "Your property hasn't finished payment setup. Please contact your manager."
        case .server(let m):
            return m
        }
    }
}
