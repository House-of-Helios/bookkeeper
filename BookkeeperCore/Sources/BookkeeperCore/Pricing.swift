import Foundation

public enum PriceState: Equatable, Sendable {
    case priced(usd: Decimal)
    case unpriced
}

public struct PricedHolding: Identifiable, Sendable {
    public let id: String
    public let token: Token
    public var amount: Decimal
    public var price: PriceState
    public var usdValue: Decimal?
    public var pct: Decimal?

    public init(id: String, token: Token, amount: Decimal, price: PriceState,
                usdValue: Decimal?, pct: Decimal?) {
        self.id = id
        self.token = token
        self.amount = amount
        self.price = price
        self.usdValue = usdValue
        self.pct = pct
    }
}
