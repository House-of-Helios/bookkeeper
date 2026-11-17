import Foundation

public enum MockData {
    // Palette echoing the reference images.
    private static let ethColor    = "#6B7BE8"
    private static let rethColor    = "#F4A07A"
    private static let usdcColor    = "#3B82C4"
    private static let boldColor    = "#7FBF6B"
    private static let usndColor    = "#D8F0C0"
    private static let xmrColor    = "#FF6600"
    private static let hypeColor    = "#6BD6BF"
    private static let mysteryColor = "#888888"

    static func t(_ symbol: String, _ name: String, _ kind: TokenKind,
                  chain: Chain?, ca: String?, cg: String?, color: String,
                  decimals: Int = 18, network: String? = nil,
                  llama: String? = nil) -> Token {
        Token(symbol: symbol, name: name, decimals: decimals, chain: chain,
              contractAddress: ca, coingeckoId: cg, kind: kind, colorHex: color,
              manualNetwork: network, llamaNetwork: llama)
    }

    public static let wallets: [Wallet] = [
        Wallet(id: "w1", nickname: "Cold Vault"),
        Wallet(id: "w2", nickname: "Daily"),
    ]

    // tokens
    static let eth     = t("ETH",  "Ether",          .ethFamily,  chain: .ethereum, ca: "0xeee", cg: nil, color: ethColor)
    static let reth    = t("rETH", "Rocket Pool ETH",.ethFamily,  chain: .ethereum, ca: "0xae78736cd615f374d3085123a210448e74fc6393", cg: nil, color: rethColor)
    static let usdc    = t("USDC", "USD Coin",       .stablecoin, chain: .ethereum, ca: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", cg: nil, color: usdcColor, decimals: 6)
    static let bold    = t("BOLD", "Liquity BOLD",   .stablecoin, chain: .ethereum, ca: "0x6440f144b7e50d6a8439336510312d2f54beb01d", cg: nil, color: boldColor)
    static let arbEth  = t("ETH",  "Ether",          .ethFamily,  chain: .arbitrum, ca: "0xfff", cg: nil, color: ethColor)
    static let mystery = t("PEAR", "Pear (unlisted)",.other,      chain: .arbitrum, ca: "0x999", cg: nil, color: mysteryColor)
    // The two networks the app has no `Chain` for. Named, because a real holding added
    // through the app is named — an unnamed one would make the demo show "MANUAL" for a
    // tab the running app draws as MONERO.
    static let xmr     = t("XMR",  "Monero",         .other,      chain: nil,       ca: nil,    cg: "monero", color: xmrColor, decimals: 12, network: "Monero")
    static let hype    = t("HYPE", "Hyperliquid",    .other,      chain: nil,       ca: nil,    cg: "hyperliquid", color: hypeColor, network: "HyperEVM")
    static let hyUsdc  = t("USDC", "USD Coin",       .stablecoin, chain: nil,       ca: "0xb88339cb7199b77e23db6e890353e22632ba630f", cg: nil, color: usdcColor, decimals: 6, network: "HyperEVM", llama: "hyperliquid")

    public static let holdings: [Holding] = [
        Holding(walletId: "w1", token: eth,     amount: 2.40),
        Holding(walletId: "w1", token: reth,    amount: 3.50),
        Holding(walletId: "w1", token: usdc,    amount: 5200.0),
        Holding(walletId: "w1", token: bold,    amount: 2750.0),
        Holding(walletId: "w1", token: mystery, amount: 1200),     // unpriced
        Holding(walletId: "w2", token: arbEth,  amount: 0.80),
        Holding(walletId: "w2", token: xmr,     amount: 9.0),
        Holding(walletId: "w2", token: hype,    amount: 60.0),
        Holding(walletId: "w2", token: hyUsdc,  amount: 1500.0),
    ]

    public static let prices: [String: PriceState] = [
        eth.id:    .priced(usd: 1581),
        reth.id:   .priced(usd: 1828),
        usdc.id:   .priced(usd: 1.0),
        bold.id:   .priced(usd: 1.0),
        arbEth.id: .priced(usd: 1581),
        xmr.id:    .priced(usd: 165),
        hype.id:   .priced(usd: 77.54),
        hyUsdc.id: .priced(usd: 1.0),
        mystery.id: .unpriced,
    ]
}

extension MockData {

    /// USDC's real chain list, as CoinGecko reports it — ordered the way TokenLocator now
    /// orders it: home first, then the networks the app can name, then the rest. Fixture
    /// for the snapshot that proves the picker wraps instead of crushing its own labels.
    public static let usdcNetworks: [String] = [
        "Ethereum", "HyperEVM", "Base", "Arbitrum", "Optimism", "Polygon", "Avalanche",
        "Celo", "Linea", "Gnosis", "Algorand", "Aptos", "Arc", "Cronos",
        "Hedera Hashgraph", "Hyperliquid", "Near Protocol", "Noble", "Polkadot",
        "Sei Network", "Solana", "Stellar", "Sui", "Ton", "Tron", "Unichain", "Xdc Network",
        "Zksync", "Flow", "Kava", "Moonbeam", "Osmosis", "Provenance", "Radix", "Sonic",
        "World Chain"
    ]
    /// Sixty days of fabricated marks, so the History tab has a shape to draw in a
    /// snapshot render. Fixture data, like everything else here — never the user's.
    public static func seedArchive(into history: HistoryStore) {
        // Six, not two: the index has a column per wallet, and a two-column fixture
        // proves nothing about whether a real wallet list still fits the width.
        let wallets: [(String, Decimal, Double)] = [
            ("Cold Vault", 54_000, 0.0021),
            ("Daily",      31_000, 0.0006),
            ("Farm",       22_400, 0.0041),
            ("Testing",    14_200, -0.0018),
            ("Spare",       7_100, 0.0009),
            ("Long Term",  18_600, 0.0015)
        ]
        let day = TimeInterval(86_400)
        for i in 0..<60 {
            let date = Date().addingTimeInterval(-Double(59 - i) * day)
            var breakdown: [String: Decimal] = [:]
            var total: Decimal = 0
            for (name, start, drift) in wallets {
                // Deterministic wobble — a fixture that changes every launch makes a
                // rendered screen impossible to compare against the last one.
                let wobble = sin(Double(i) / 7 + Double(name.count)) * 0.02
                let growth = 1 + drift * Double(i) + wobble
                let value = start * Decimal(growth)
                breakdown[name] = value
                total += value
            }
            history.archive(total: total, breakdown: breakdown, on: date)
        }
    }
}
