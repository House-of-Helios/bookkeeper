import Foundation

public enum Aggregation {

    public static func price(_ holdings: [Holding],
                             with prices: [String: PriceState]) -> [PricedHolding] {
        holdings.map { h in
            let state = prices[h.token.id] ?? .unpriced
            let value: Decimal?
            switch state {
            case .priced(let usd): value = h.amount * usd
            case .unpriced:        value = nil          // never fabricate
            }
            return PricedHolding(id: h.token.id + "#" + h.walletId,
                                 token: h.token, amount: h.amount,
                                 price: state, usdValue: value, pct: nil)
        }
    }

    public static func total(_ priced: [PricedHolding]) -> Decimal {
        priced.reduce(0) { $0 + ($1.usdValue ?? 0) }
    }

    public static func withPercentages(_ priced: [PricedHolding]) -> [PricedHolding] {
        let sum = total(priced)
        guard sum > 0 else { return priced }
        return priced.map { row in
            var r = row
            if let v = row.usdValue { r.pct = (v / sum) * 100 }
            return r
        }
    }

    public static func collapseByToken(_ priced: [PricedHolding]) -> [PricedHolding] {
        var order: [String] = []
        var merged: [String: PricedHolding] = [:]
        for row in priced {
            let key = row.token.id
            if var existing = merged[key] {
                existing.amount += row.amount
                // Same token.id always carries the same PriceState (price() keys by
                // token.id), so rows are both-priced or both-unpriced. Sum when both
                // priced; otherwise stay nil — never inject a value onto an unpriced row.
                if let a = existing.usdValue, let b = row.usdValue { existing.usdValue = a + b }
                else { existing.usdValue = nil }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = PricedHolding(id: key, token: row.token, amount: row.amount,
                                            price: row.price, usdValue: row.usdValue, pct: nil)
            }
        }
        // Merge-and-sum only; callers stamp percentages with withPercentages.
        return order.compactMap { merged[$0] }
    }

    /// Merge holdings by SYMBOL **within a network**, for the aggregate dashboard: the
    /// same asset held in several wallets on the same network becomes one row, and the
    /// same asset on two networks stays two rows.
    ///
    /// This used to key on the symbol alone, so every USDC anywhere merged into one row
    /// and the merged row wore the network of whichever holding the loop happened to
    /// reach first. That made the portfolio file HyperEVM USDC under Ethereum — a
    /// network no wallet held it on — and it quietly did the same to ETH across
    /// Ethereum and Arbitrum. The network is a fact about where the coins are, so it
    /// cannot be an artifact of iteration order: it belongs in the key.
    ///
    /// Percentages are NOT stamped here — callers apply withPercentages.
    public static func collapseBySymbolPerNetwork(_ priced: [PricedHolding]) -> [PricedHolding] {
        var order: [String] = []
        var merged: [String: PricedHolding] = [:]
        for row in priced {
            let key = row.token.symbol.uppercased() + "@" + Network.of(row.token).name
            if var existing = merged[key] {
                existing.amount += row.amount
                if let a = existing.usdValue, let b = row.usdValue { existing.usdValue = a + b }
                else if existing.usdValue == nil { existing.usdValue = row.usdValue }
                merged[key] = existing
            } else {
                order.append(key)
                merged[key] = PricedHolding(id: key, token: row.token, amount: row.amount,
                                            price: row.price, usdValue: row.usdValue, pct: nil)
            }
        }
        return order.compactMap { merged[$0] }
    }

    public static func bucketShares(_ priced: [PricedHolding]) -> [(TokenKind, Decimal)] {
        var order: [TokenKind] = []
        var sums: [TokenKind: Decimal] = [:]
        for row in priced {
            guard let v = row.usdValue else { continue }   // unpriced excluded
            let k = row.token.kind
            if sums[k] == nil { order.append(k) }
            sums[k, default: 0] += v
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return order.map { ($0, (sums[$0]! / total) * 100) }
    }
}
