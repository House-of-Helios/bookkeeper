import Foundation

/// A holding the user entered by hand, tied to a named wallet.
///
/// The user supplies one thing — a contract address, or a coin's name — plus how much.
/// Everything else here was **discovered** by `TokenLocator` at add time, never chosen
/// from a menu: which network the address lives on, what the symbol is, how many
/// decimals it has. That's the whole point of the type; a `network` the user had to
/// pick would be a question they can't reliably answer and, for a coin like Monero
/// that is its own chain, a question with no valid answer on offer.
public struct ManualHolding: Sendable, Equatable {
    public let walletId: String
    public let symbol: String
    public let amount: Decimal

    /// DefiLlama chain key the address was found on ("base", "polygon"), or nil for a
    /// coin with no contract.
    public let network: String?
    public let contractAddress: String?
    /// CoinGecko id, for a coin priced by id rather than by contract (XMR, SC).
    public let coingeckoId: String?
    /// Human-readable network, for display: "Base", "Polygon", "Monero".
    public let networkName: String

    public init(walletId: String, symbol: String, amount: Decimal,
                network: String? = nil, contractAddress: String? = nil,
                coingeckoId: String? = nil, networkName: String = "") {
        self.walletId = walletId
        self.symbol = symbol
        self.amount = amount
        self.network = network
        self.contractAddress = contractAddress
        self.coingeckoId = coingeckoId
        self.networkName = networkName
    }

    /// True when this names an on-chain contract, so it prices and draws its icon
    /// through the same path as a scanned balance.
    public var isContractBased: Bool { network != nil && contractAddress != nil }
}
