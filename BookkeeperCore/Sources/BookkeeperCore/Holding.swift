import Foundation

public struct Wallet: Identifiable, Sendable {
    public let id: String
    public var nickname: String
    /// User-set network name for a manual (non-EVM) wallet, e.g. "Sia". Labels the
    /// manual holdings group instead of the generic "Manual".
    public var manualNetwork: String?

    public init(id: String, nickname: String, manualNetwork: String? = nil) {
        self.id = id
        self.nickname = nickname
        self.manualNetwork = manualNetwork
    }
}

public struct Holding: Sendable {
    public let walletId: String
    public let token: Token
    public var amount: Decimal

    public init(walletId: String, token: Token, amount: Decimal) {
        self.walletId = walletId
        self.token = token
        self.amount = amount
    }
}
