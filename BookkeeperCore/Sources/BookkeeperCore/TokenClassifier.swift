import Foundation

/// Decides whether a token is ETH, a stablecoin, or something else.
///
/// This drives the BY TYPE breakdown, which is really a liquidity question: how much of
/// the portfolio is ETH exposure, how much is dollars, how much is everything else. A
/// liquid staking token IS ETH exposure — rETH rises and falls with ether and redeems
/// for it — so counting it as "other" understates ETH badly. Held wrong, a portfolio
/// that is 60% ETH reads as 20%.
///
/// Matching is done on a normalised symbol rather than the raw one, because the symbol
/// a price source hands back is not the clean ticker:
///   - case varies: `rETH`, `stETH`, `ETHx`, `sfrxETH`
///   - vendors prefix their own: `rock.reth`
///   - wrappers stack: `aEthLidowstETH` is Aave's receipt for Lido's wstETH
/// So the symbol is upper-cased, stripped to letters and digits, and then matched by
/// SUFFIX — which is what survives all three of those.
public enum TokenClassifier {

    /// Upper-case, letters and digits only. "rock.reth" → "ROCKRETH".
    public static func normalize(_ symbol: String) -> String {
        symbol.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Liquid staking and restaking tokens, verified against live DefiLlama symbols.
    /// Every one of these tracks the price of ether.
    ///
    /// Matched as suffixes, so any wrapper or vendor prefix in front of them still lands
    /// here: `ROCKRETH` ends with `RETH`, `AETHLIDOWSTETH` ends with `WSTETH`.
    static let ethSuffixes = [
        "WSTETH", "SFRXETH", "AMPHRETH", "ANKRETH", "RSWETH", "UNIETH", "WBETH",
        "PUFETH", "WEETH", "EZETH", "RSETH", "FRXETH", "CBETH", "SWETH", "OSETH",
        "LSETH", "RETH", "STETH", "OETH", "METH", "EETH", "ETHX"
    ]

    /// Plain ether and its direct wrappers — exact matches only. A bare "ETH" suffix
    /// rule would drag in anything whose ticker happens to end in those three letters.
    static let ethExact: Set<String> = ["ETH", "WETH", "ETH2"]

    /// Dollar stablecoins, including the yield-bearing wrappers.
    ///
    /// Note `sDAI` trades around $1.18 and `sUSDe` above $1: a wrapper accrues the yield
    /// into its price, so "is it a stablecoin" can't be decided by asking whether it
    /// costs a dollar. What makes it stable-family is what it redeems for.
    static let stableSuffixes = [
        "CRVUSD", "PYUSD", "FDUSD", "RLUSD", "DEUSD", "ALUSD", "LUSD", "TUSD",
        "USDC", "USDT", "USDE", "USDS", "USDP", "USDX", "USDY", "USDM", "USDA",
        "USND", "USD0", "SUSD", "FRAX", "DOLA", "BOLD", "GHO", "DAI", "MIM"
    ]

    public static func kind(for symbol: String) -> TokenKind {
        let s = normalize(symbol)
        guard !s.isEmpty else { return .other }
        if ethExact.contains(s) { return .ethFamily }
        if ethSuffixes.contains(where: { s.hasSuffix($0) }) { return .ethFamily }
        if stableSuffixes.contains(where: { s.hasSuffix($0) }) { return .stablecoin }
        return .other
    }
}
