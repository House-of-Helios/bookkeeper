import SwiftUI
import BookkeeperCore

/// **Ledger** — built to the reference sheets.
///
/// Helios's own spreadsheet language, taken literally: a black field, saturated blocks
/// with black gutters between them, mono type throughout, the token's logo riding
/// outside its cell, the share sitting outside the table on the right, and a network
/// named once by a letter tab running down the side of the rows it owns.
///
/// The ring is annotated the way a sheet annotates a chart — callout lines out to
/// labels in each slice's own colour — rather than with a legend underneath.
struct PortfolioLedger: View {
    let store: PortfolioStore
    var onSelect: (Token) -> Void

    private var rows: [PricedHolding] {
        store.dashboardRows.sorted { ($0.usdValue ?? -1) > ($1.usdValue ?? -1) }
    }

    /// Rows grouped by network, most valuable first, each getting its own tab.
    private var groups: [(network: Network, rows: [PricedHolding])] {
        PortfolioStore.grouped(rows)
    }

    // MARK: Table — shared cell vocabulary, so this and the wallet modules line up.

    private var totalRow: some View {
        HStack(spacing: Ledger.gutter) {
            Color.clear.frame(width: LedgerCol.tab, height: 1)
            Text("TOT").font(Ledger.mono(13)).foregroundStyle(Palette.ink)
                .frame(width: LedgerCol.icon + LedgerCol.symbol + Ledger.gutter)
            LedgerBlock(fill: Ledger.wash(0.29)) {
                HStack(spacing: 0) {
                    Text("$").font(Ledger.mono(14)).foregroundStyle(Palette.ink)
                        .padding(.leading, 12)
                    Spacer(minLength: 0)
                    Text(Ledger.value(store.totalUSD))
                        .font(Ledger.mono(13)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.trailing, 8)
                }
            }
            .frame(width: LedgerCol.amount + LedgerCol.value)
            Text("100%").font(Ledger.mono(11)).italic().foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: LedgerCol.pct, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 16) {
            LedgerHeader()
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                LedgerNetworkGroup(network: g.network, rows: g.rows, onSelect: onSelect)
            }
            totalRow
            // No add control here. A token belongs to a wallet, and the portfolio is the
            // roll-up of every wallet — adding one from this page would have to guess
            // which wallet it landed in. The Wallets tab asks that question properly.
        }
        .frame(width: LedgerCol.tableWidth)
    }

    // MARK: Breakdown figures — a ring, then its own short sheet

    private func breakdown(_ title: String, _ slices: [BreakdownRing.Slice],
                           sheet: [MetricStyle.Slice]) -> some View {
        VStack(spacing: 12) {
            Text(title.uppercased()).font(Ledger.mono(10)).tracking(1.6)
                .foregroundStyle(Palette.ink.opacity(0.6))

            BreakdownRing(slices: slices, diameter: 142, thickness: 38)

            // A compact sheet, sized to its content. "Total Value" was a heading wide
            // enough to hold the words, which left the value column padded out with
            // empty space and wider than the ring above it.
            VStack(spacing: Ledger.gutter) {
                ForEach(sheet) { s in
                    HStack(spacing: Ledger.gutter) {
                        LedgerBlock(fill: s.color, height: 22) {
                            Text(s.label).font(Ledger.mono(10.5))
                                .foregroundStyle(Ledger.ink(on: s.color))
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 76)

                        LedgerBlock(fill: Ledger.wash(0.14), height: 22) {
                            HStack(spacing: 0) {
                                Text("$").font(Ledger.mono(10.5))
                                    .foregroundStyle(Palette.ink.opacity(0.6))
                                    .padding(.leading, 6)
                                Spacer(minLength: 2)
                                Text(Ledger.value(Decimal(s.usd)))
                                    .font(Ledger.mono(10.5)).foregroundStyle(Palette.ink)
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                    .padding(.trailing, 6)
                            }
                        }
                        .frame(width: 78)

                        Text(String(format: "%.0f%%", s.pct))
                            .font(Ledger.mono(10.5)).italic().foregroundStyle(Palette.ink)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
            .frame(width: 76 + 78 + 32 + Ledger.gutter * 2)
        }
    }

    /// By the chain the value actually settles on.
    ///
    /// Arbitrum and Base are Ethereum rollups — holding USDC on Base is holding it on
    /// Ethereum, so splitting them into separate slices answers a question nobody asked
    /// and hides how much is really on Ethereum. A coin that is its own chain (Monero,
    /// Siacoin) gets its own slice under its own name, rather than all of them being
    /// lumped together as "Manual".
    private var chainSlices: [MetricStyle.Slice] {
        var order: [String] = []
        var sums: [String: Double] = [:]
        var colors: [String: Color] = [:]

        for r in store.visiblePricedRows {
            guard let v = r.usdValue else { continue }
            // Named by its own network. This used to file every chain-backed token under
            // "Ethereum", so a Base holding and an Arbitrum one were one slice.
            let net = Network.of(r.token)
            let name = net.name
            let color = net.isNamed ? MetricStyle.networkColor(net) : Ledger.fill(for: r.token)
            if sums[name] == nil { order.append(name); colors[name] = color }
            sums[name, default: 0] += NSDecimalNumber(decimal: v).doubleValue
        }

        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return order
            .map { MetricStyle.Slice(label: $0, pct: sums[$0]! / total * 100,
                                     usd: sums[$0]!, color: colors[$0]!) }
            .sorted { $0.usd > $1.usd }
    }

    /// The network's OWN logo — not a token that happens to live on it. Picking a
    /// "representative" token was the earlier bug: Base showed a bridged-ETH holding's
    /// icon (reads as "this is Ethereum"), Arbitrum showed whatever token sorted first.
    /// The mark is the network's token (`NetworkTint`) — ETH, ARB, HYPE — out of the one
    /// icon store, `IconCache`. Falls back to the letter badge when no token is known.
    private func chainMark(_ label: String) -> BreakdownRing.Mark {
        .network(Network(name: label))
    }

    private var chainMarks: [BreakdownRing.Slice] {
        chainSlices.map {
            BreakdownRing.Slice(id: $0.label, label: $0.label, value: $0.usd,
                                color: $0.color, mark: chainMark($0.label))
        }
    }

    private var typeSlices: [MetricStyle.Slice] { MetricStyle.typeSlices(store.visiblePricedRows) }

    /// ETH and stablecoins have obvious marks. "Tokens" is a category with no coin of
    /// its own, so it takes a generic one rather than borrowing some arbitrary holding's
    /// logo and implying the slice is only that token.
    private var typeMarks: [BreakdownRing.Slice] {
        typeSlices.map { s in
            let mark: BreakdownRing.Mark
            switch s.label {
            case MetricStyle.bucketTitle(.ethFamily):  mark = .asset("token-eth")
            case MetricStyle.bucketTitle(.stablecoin): mark = .asset("token-usdc")
            default:                                   mark = .system("circle.hexagongrid.fill")
            }
            return BreakdownRing.Slice(id: s.label, label: s.label, value: s.usd,
                                       color: s.color, mark: mark)
        }
    }

    /// Wallets keep their names — a wallet has no logo, and its name is the whole point.
    private var walletMarks: [BreakdownRing.Slice] {
        walletSlices.map {
            BreakdownRing.Slice(id: $0.label, label: $0.label, value: $0.usd, color: $0.color)
        }
    }

    private var walletSlices: [MetricStyle.Slice] {
        let shares = store.walletShares
        let total = shares.reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.usd).doubleValue }
        guard total > 0 else { return [] }
        // The wallet's own colour, the one its module wears on the Wallets tab — the same
        // wallet wearing two different colours on two screens is just confusing. Asked of
        // the store rather than defaulted here: this list is sorted by value and skips
        // empty wallets, so counting through it picked a different palette entry than the
        // modules did.
        return shares.map { s in
            let v = NSDecimalNumber(decimal: s.usd).doubleValue
            return MetricStyle.Slice(label: s.nickname, pct: v / total * 100, usd: v,
                                     color: Color(hex: store.walletTintHex(s.nickname)))
        }
    }

    /// The total, at a size nothing else competes with. Rounded rather than mono: this
    /// is one number to be read at a glance, not a column to be scanned down, and the
    /// mono's fixed advances make a big figure sprawl.
    private var hero: some View {
        VStack(spacing: 6) {
            Text(Money.usd(store.totalUSD))
                .font(.system(size: 68, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(-1.5)
                .foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.4).lineLimit(1)
            if let c = store.portfolio24hChange {
                HStack(spacing: 5) {
                    Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                    Text(String(format: "%.2f%% today", abs(c)))
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(c >= 0 ? Theme.positive : Theme.negative)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// The allocation ring with its three breakdowns beneath it, sharing a centre line.
    private var charts: some View {
        VStack(spacing: 44) {
            AllocationRing(rows: rows, diameter: 330, thickness: 82)
            HStack(alignment: .top, spacing: 14) {
                breakdown("By network", chainMarks, sheet: chainSlices)
                breakdown("By type", typeMarks, sheet: typeSlices)
                breakdown("By wallet", walletMarks, sheet: walletSlices)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 38) {
            // No banner. A screen labelled PORTFOLIO on the portfolio tab tells nobody
            // anything; the figure is the headline and it can carry the page alone.
            hero

            // A plain row, not a ViewThatFits. The fallback stacked the charts under the
            // table whenever they were a few points too wide, which looks like a layout
            // that broke itself — and it did exactly that twice, silently, after a
            // label change nudged the width. The window's minimum guarantees the room.
            HStack(alignment: .top, spacing: 48) {
                table
                charts
                Spacer(minLength: 0)
            }

        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(maxWidth: 1320)
        .frame(maxWidth: .infinity)
        .task(id: chainSlices.map(\.label)) {
            let nets = chainSlices.map { Network(name: $0.label) }
            await IconCache.shared.prefetch(NetworkTint.coins(for: nets))
            await IconCache.shared.prefetchNetworks(NetworkTint.tokenless(nets))
        }
    }
}
