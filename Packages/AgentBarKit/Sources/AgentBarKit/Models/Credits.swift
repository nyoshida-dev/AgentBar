import Foundation

/// What an agent's account holds against the moment its plan runs out: a balance of
/// prepaid credits, or an allowance that is simply unlimited.
///
/// This is not a window and has no reset, so it is never a usage row: it belongs beside
/// the agent's name, not among its meters. A balance that spends into a *limit* is a
/// window and comes back as a `UsageLimit` instead (Claude's extra usage, Cursor's
/// on-demand).
public struct Credits: Equatable, Codable, Sendable {
    /// The balance in whole currency units. Nil when the account reports none.
    public let balance: Double?
    /// ISO currency code; "USD" unless the account says otherwise.
    public let currency: String
    /// The account has an allowance with no ceiling, so a balance means nothing.
    public let isUnlimited: Bool
    /// The word after the amount: "credits" for a prepaid balance.
    public let noun: String
    /// The account reported a zero balance and its own dashboard still shows it.
    /// A missing balance stays hidden; a reported zero does not.
    public let showsZero: Bool

    public init(balance: Double?, currency: String = "USD", isUnlimited: Bool = false,
                noun: String = "credits", showsZero: Bool = false) {
        self.balance = balance
        self.currency = currency
        self.isUnlimited = isUnlimited
        self.noun = noun
        self.showsZero = showsZero
    }

    /// Nothing to say: no balance, and no unlimited allowance to mention.
    public var isEmpty: Bool { isUnlimited || showsZero ? false : (balance ?? 0) <= 0 }

    /// "$12.40 credits", or "unlimited credits". Nil when there is nothing to show.
    public var caption: String? {
        if isUnlimited { return "unlimited \(noun)" }
        guard let balance, balance > 0 || showsZero else { return nil }
        return "\(Format.money(max(0, balance), currency: currency)) \(noun)"
    }

    private enum CodingKeys: String, CodingKey {
        case balance, currency, isUnlimited, noun, showsZero
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        balance = try container.decodeIfPresent(Double.self, forKey: .balance)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
        isUnlimited = try container.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? false
        noun = try container.decodeIfPresent(String.self, forKey: .noun) ?? "credits"
        showsZero = try container.decodeIfPresent(Bool.self, forKey: .showsZero) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(balance, forKey: .balance)
        try container.encode(currency, forKey: .currency)
        try container.encode(isUnlimited, forKey: .isUnlimited)
        try container.encode(noun, forKey: .noun)
        try container.encode(showsZero, forKey: .showsZero)
    }
}
