import SwiftUI
import BookkeeperCore

/// Shared colours + labels for the By-Chain / By-Type metric donuts, so the dashboard
/// and per-wallet views read identically (one design decision, applied everywhere).
enum MetricStyle {
    struct Slice: Identifiable {
        let id = UUID()
        let label: String
        let pct: Double
        let usd: Double
        let color: Color
        var network: Network? = nil   // the network this slice stands for
        var iconToken: Token? = nil   // a token-backed slice → show this token's icon
    }

    /// A network's colour — the one place it is chosen, so the tab beside a group and
    /// the slice in the ring are never two different colours for the same network.
    static func networkColor(_ n: Network) -> Color { Color(hex: n.colorHex) }

    /// The colour for a slice. A network the app can name wears its brand; a network it
    /// cannot falls back to the token's own systemwide tint, so re-theming a token
    /// recolours every ring at once instead of per-item hardcoding.
    @MainActor
    static func color(network: Network, token: Token?) -> Color {
        if network.isNamed { return networkColor(network) }
        if let token { return IconCache.shared.tint(for: token) ?? Color(hex: token.colorHex) }
        return networkColor(network)
    }

    static func bucketColor(_ k: TokenKind) -> Color {
        switch k {
        case .stablecoin: return Color(hex: "#7FBF6B")
        case .ethFamily:  return Color(hex: "#6B7BE8")
        case .other:      return Color(hex: "#FF6600")
        }
    }
    static func bucketTitle(_ k: TokenKind) -> String {
        switch k {
        case .stablecoin: return "Stables"   // liquid — movable
        case .ethFamily:  return "ETH"
        case .other:      return "Tokens"
        }
    }

    /// By-Network slices, sorted by value. Each slice carries the network it stands for
    /// and, for one the colour table can't name, the predominant token so the legend can
    /// show that token's icon.
    @MainActor
    static func chainSlices(_ rows: [PricedHolding]) -> [Slice] {
        var sums: [Network: Double] = [:]
        var rep: [Network: Token] = [:]
        var repVal: [Network: Double] = [:]
        for r in rows {
            guard let v = r.usdValue else { continue }
            let d = NSDecimalNumber(decimal: v).doubleValue
            let n = Network.of(r.token)
            sums[n, default: 0] += d
            if d > (repVal[n] ?? -1) { repVal[n] = d; rep[n] = r.token }
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums.map { (n, usd) in
            let named = n.isNamed
            let repToken = named ? nil : rep[n]
            return Slice(label: n.name, pct: usd / total * 100, usd: usd,
                         color: color(network: n, token: repToken),
                         network: n, iconToken: repToken)
        }
        .sorted { $0.usd > $1.usd }
    }

    /// By-Type slices, sorted by value. No icons (types aren't tokens) — coloured dots.
    static func typeSlices(_ rows: [PricedHolding]) -> [Slice] {
        var sums: [TokenKind: Double] = [:]
        for r in rows {
            guard let v = r.usdValue else { continue }
            sums[r.token.kind, default: 0] += NSDecimalNumber(decimal: v).doubleValue
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return sums.map { Slice(label: bucketTitle($0.key), pct: $0.value / total * 100,
                                usd: $0.value, color: bucketColor($0.key)) }
            .sorted { $0.usd > $1.usd }
    }
}
