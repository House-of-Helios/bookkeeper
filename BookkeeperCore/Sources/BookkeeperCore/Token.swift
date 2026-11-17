import Foundation

public enum TokenKind: String, Codable, Sendable {
    case stablecoin
    case ethFamily
    case other
}

public struct Token: Identifiable, Hashable, Sendable {
    /// Identity is the contract address (auto) or CoinGecko id (manual) — never the name.
    public var id: String {
        if let ca = contractAddress, let chain { return "\(ca)@\(chain.rawValue)" }
        if let ca = contractAddress, let net = llamaNetwork { return "\(ca)@\(net)" }
        // The network is part of the identity: the same coin held on two chains is two
        // holdings, and without this they collapse into one row that double-counts.
        if let cg = coingeckoId { return "\(cg)@\(manualNetwork ?? "manual")" }
        return "\(symbol)@unknown"
    }

    public let symbol: String
    public let name: String
    public let decimals: Int
    public let chain: Chain?
    public let contractAddress: String?
    public let coingeckoId: String?
    public let kind: TokenKind
    public let colorHex: String
    /// Network label shown in the UI (e.g. "Polygon", "Monero"). Set for anything the
    /// app doesn't scan balances on, so a By-Chain slice names the real network rather
    /// than lumping everything under "Manual".
    public let manualNetwork: String?

    /// DefiLlama chain key (e.g. "polygon") for a token on a chain the app prices but
    /// doesn't scan. Together with `contractAddress` it gives the token a price key and
    /// an icon URL through exactly the same path a scanned holding uses.
    public let llamaNetwork: String?

    public init(symbol: String, name: String, decimals: Int, chain: Chain?,
                contractAddress: String?, coingeckoId: String?,
                kind: TokenKind, colorHex: String, manualNetwork: String? = nil,
                llamaNetwork: String? = nil) {
        self.symbol = symbol
        self.name = name
        self.decimals = decimals
        self.chain = chain
        self.contractAddress = contractAddress
        self.coingeckoId = coingeckoId
        self.kind = kind
        self.colorHex = colorHex
        self.manualNetwork = manualNetwork
        self.llamaNetwork = llamaNetwork
    }
}
