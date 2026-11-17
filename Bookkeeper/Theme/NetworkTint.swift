import SwiftUI
import BookkeeperCore

/// What a network looks like, everywhere in the app: it wears its token. Ethereum is ETH,
/// Bitcoin BTC, Solana SOL, Arbitrum ARB, HyperEVM HYPE. Its icon is that token's icon and
/// its colour that icon's dominant colour — so a network and its token's rows can never
/// disagree. The one other case: a network with no token of its own (Base) wears its
/// network logo. Every icon, token or network, comes out of `IconCache` (`<data>/icons/`).
@MainActor
enum NetworkTint {
    /// The token each network wears, by CoinGecko id. A network not listed wears the coin
    /// named after it when one is held there (Kaspa → `kaspa`).
    static let coinIds: [String: String] = [
        "Ethereum": "ethereum", "Linea": "linea", "Scroll": "scroll", "Blast": "blast", "zkSync": "zksync",
        "Arbitrum": "arbitrum", "Optimism": "optimism", "HyperEVM": "hyperliquid",
        "Polygon": "polygon-ecosystem-token", "BNB Chain": "binancecoin", "Avalanche": "avalanche-2",
        "Gnosis": "gnosis", "Mantle": "mantle", "Celo": "celo", "Fantom": "fantom",
        "Monero": "monero", "Bitcoin": "bitcoin", "Solana": "solana", "Litecoin": "litecoin",
        "Cardano": "cardano", "Tron": "tron", "Polkadot": "polkadot", "Cosmos": "cosmos",
        "Stellar": "stellar", "Near": "near", "Sui": "sui", "Aptos": "aptos", "Zcash": "zcash",
        "Dogecoin": "dogecoin", "Kaspa": "kaspa", "Siacoin": "siacoin", "Bitcoin Cash": "bitcoin-cash",
    ]

    nonisolated private static let symbols: [String: String] = [
        "ethereum": "ETH", "arbitrum": "ARB", "optimism": "OP", "hyperliquid": "HYPE",
        "polygon-ecosystem-token": "POL", "binancecoin": "BNB", "avalanche-2": "AVAX", "gnosis": "GNO",
        "mantle": "MNT", "celo": "CELO", "fantom": "FTM", "monero": "XMR", "bitcoin": "BTC",
        "solana": "SOL", "litecoin": "LTC", "cardano": "ADA", "tron": "TRX", "polkadot": "DOT",
        "cosmos": "ATOM", "stellar": "XLM", "near": "NEAR", "sui": "SUI", "aptos": "APT", "zcash": "ZEC",
        "dogecoin": "DOGE", "kaspa": "KAS", "siacoin": "SC", "bitcoin-cash": "BCH",
        "linea": "LINEA", "scroll": "SCR", "blast": "BLAST", "zksync": "ZK",
    ]

    /// The network's token: the very one held, when it is (so it IS the rows' token), else
    /// the coin by id. Nil only for a network with no token known at all.
    static func coin(for n: Network, among tokens: [Token] = []) -> Token? {
        let id = coinIds[n.name] ?? n.name.lowercased().replacingOccurrences(of: " ", with: "-")
        if let held = tokens.first(where: { $0.coingeckoId == id && $0.contractAddress == nil }) { return held }
        guard coinIds[n.name] != nil else { return nil }
        return Token(symbol: symbols[id] ?? id.uppercased(), name: n.name, decimals: 18,
                     chain: id == "ethereum" ? .ethereum : nil, contractAddress: nil,
                     coingeckoId: id, kind: .other, colorHex: n.colorHex)
    }

    /// The network's colour: its token's icon colour; a network with no token, its logo's;
    /// else its brand colour.
    static func hex(_ n: Network, among tokens: [Token] = []) -> String {
        let c = coin(for: n, among: tokens).map { IconCache.shared.tintRGB(for: $0) }
            ?? IconCache.shared.tintRGB(forNetwork: n)
        guard let c else { return n.colorHex }
        return String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
    }

    /// Networks with no token of their own — the ones whose logo has to be fetched.
    static func tokenless(_ networks: [Network]) -> [Network] { networks.filter { coin(for: $0) == nil } }

    /// The coin id a symbol names, for a native coin that arrived with no id.
    nonisolated static func coinId(forSymbol symbol: String) -> String? {
        symbols.first { $0.value == symbol.uppercased() }?.key
    }

    /// Every network's token, for `IconCache.prefetch`.
    static func coins(for networks: [Network]) -> [Token] { networks.compactMap { coin(for: $0) } }
}

/// A network's mark: its token's icon; with no token, its network logo; else a letter.
struct NetworkMark: View {
    let network: Network
    var among: [Token] = []
    var size: CGFloat
    var body: some View {
        if let coin = NetworkTint.coin(for: network, among: among) {
            TokenGlyph(token: coin, size: size)
        } else if let img = IconCache.shared.image(forNetwork: network) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Letter(name: network.name, hex: NetworkTint.hex(network), size: size)
        }
    }
}
