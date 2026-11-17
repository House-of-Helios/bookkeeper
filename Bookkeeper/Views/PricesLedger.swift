import SwiftUI
import BookkeeperCore

/// **Prices** — every held token, with where its price has been.
///
/// No curation step: whatever's visible on Portfolio/Wallets shows up here too, one card
/// per distinct token (summed across wallets) rather than one row per holding. History
/// comes from `PortfolioStore.priceHistory(for:days:)` — DefiLlama's keyless `/chart`
/// endpoint, the same provider and key scheme the app already prices spot quotes with.
struct PricesLedger: View {
    let store: PortfolioStore

    @State private var selected: Token?

    /// Grouped by symbol, not `token.id` — the same coin on two networks (ETH on
    /// Ethereum + Arbitrum, USDC on Ethereum + HyperEVM) is one price, shown once.
    private var rows: [PriceRow] {
        var totals: [String: Decimal] = [:]
        var tokens: [String: Token] = [:]
        var prices: [String: Decimal] = [:]
        for r in store.visiblePricedRows {
            let key = r.token.symbol.uppercased()
            if tokens[key] == nil { tokens[key] = r.token }
            totals[key, default: 0] += r.usdValue ?? 0
            if prices[key] == nil, case .priced(let usd) = r.price { prices[key] = usd }
        }
        return tokens.map { key, token in PriceRow(token: token, usdValue: totals[key], price: prices[key]) }
            .sorted { ($0.usdValue ?? 0) > ($1.usdValue ?? 0) }
    }

    private static let columns = [GridItem(.flexible(), spacing: 10),
                                   GridItem(.flexible(), spacing: 10),
                                   GridItem(.flexible(), spacing: 10)]

    /// Unwrapped, so it can be sized to its full height offscreen for a snapshot —
    /// same reason `HistoryLedger.content` stays bare and `RootView` supplies the
    /// `ScrollView` when the screen is actually shown.
    ///
    /// Tapping a card PROMOTES it: the detail panel takes the top of this same page,
    /// full width, pushing the grid down — not a centered modal. That inline-promotion
    /// shape (mockup: `#detail` sits above `.grid` in normal flow) is the actual design
    /// that got approved; a dimmed popup was never part of it.
    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("PRICES").eyebrowStyle()
            if let token = selected {
                // `.id` forces a fresh instance per token — without it SwiftUI reuses
                // the same `PriceChart`, and `.task(id: range)` only re-fires when the
                // RANGE changes, so switching tokens without touching the range left
                // the header updated (plain property) but the chart/price stuck on the
                // previous token's `@State private var points`.
                PriceChart(store: store, token: token) { selected = nil }
                    .id(token.id)
            }
            if rows.isEmpty {
                Text("Nothing priced yet.").font(AppFont.ui(12)).foregroundStyle(Palette.dim)
            } else {
                LazyVGrid(columns: Self.columns, spacing: 10) {
                    ForEach(rows) { row in
                        PriceCard(store: store, row: row) { selected = row.token }
                    }
                }
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(maxWidth: 1320)
        .frame(maxWidth: .infinity)
    }

    var body: some View { content }
}

private struct PriceRow: Identifiable {
    let token: Token
    let usdValue: Decimal?
    let price: Decimal?
    var id: String { token.id }
}

/// One card, one row: icon, symbol, price (colored by 24h direction), sparkline. No
/// network label, no held amount, no value — this tab answers one question only.
/// Background is the token's own identity colour washed into the surface, the same
/// source (`Token.colorHex`, via `Palette.token`) Portfolio/Wallets already tint with.
private struct PriceCard: View {
    let store: PortfolioStore
    let row: PriceRow
    var onTap: () -> Void

    @State private var points: [PricePoint] = []

    private var change: Double? { store.change24h[row.token.id] }
    private var tint: Color {
        guard let c = change else { return Palette.ink }
        return Ledger.change(c >= 0)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                TokenGlyph(token: row.token, size: 34)
                Text(row.token.symbol).font(AppFont.ui(13, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer(minLength: 4)
                Text(row.price.map { Money.priceFull($0) } ?? "—")
                    .font(AppFont.num(17)).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Sparkline(points: points, color: tint)
                    .frame(width: 56, height: 24)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                ZStack {
                    Palette.surface
                    Palette.token(row.token.colorHex).opacity(0.14)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: row.token.id) {
            points = await store.priceHistory(for: row.token, days: 7)
        }
    }
}

/// A bare line, no axes — the row already carries the number, the sparkline just
/// carries the shape.
private struct Sparkline: View {
    let points: [PricePoint]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if points.count >= 2 {
                let values = points.map { NSDecimalNumber(decimal: $0.price).doubleValue }
                let lo = values.min() ?? 0
                let span = max((values.max() ?? 1) - lo, 0.000_001)
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The expanded detail: name, symbol, price, 24h change, a real chart with gridlines,
/// dates and a hover scrub, and a range rail beside it — 7D/30D/90D/ALL. Nothing else;
/// no network pills, no held amount, no value. Deliberately reads close to a CoinGecko
/// token page rather than a portfolio row.
private struct PriceChart: View {
    let store: PortfolioStore
    let token: Token
    var onClose: () -> Void

    enum Range: String, CaseIterable, Identifiable {
        case seven = "7D", thirty = "30D", ninety = "90D", all = "ALL"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .seven: return 7
            case .thirty: return 30
            case .ninety: return 90
            case .all: return 1825   // 5 years, weekly — see HistoricalPriceService
            }
        }
    }

    @State private var range: Range = .thirty
    @State private var points: [PricePoint] = []
    @State private var loading = false
    @State private var hoverIndex: Int?

    private func load() async {
        loading = true
        points = await store.priceHistory(for: token, days: range.days)
        loading = false
    }

    private struct Geometry {
        let x: (Int) -> CGFloat
        let y: (Double) -> CGFloat
        let left: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        let yLo: Double
        let yHi: Double
    }

    private func geometry(_ size: CGSize, _ values: [Double]) -> Geometry {
        let left: CGFloat = 54, right: CGFloat = 10, top: CGFloat = 10, bottom: CGFloat = 22
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.08, hi * 0.02)
        let yLo = lo - pad, yHi = hi + pad
        let x: (Int) -> CGFloat = { i in
            guard values.count > 1 else { return left }
            return left + CGFloat(i) / CGFloat(values.count - 1) * (size.width - left - right)
        }
        let y: (Double) -> CGFloat = { v in
            top + (1 - CGFloat((v - yLo) / max(yHi - yLo, 0.000_001))) * (size.height - top - bottom)
        }
        return Geometry(x: x, y: y, left: left, top: top, bottom: bottom, yLo: yLo, yHi: yHi)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                TokenGlyph(token: token, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(token.name).font(AppFont.ui(17, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(token.symbol).font(AppFont.ui(11)).foregroundStyle(Palette.dim)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.dim)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var priceLine: some View {
        if let first = points.first, let last = points.last {
            let a = NSDecimalNumber(decimal: first.price).doubleValue
            let b = NSDecimalNumber(decimal: last.price).doubleValue
            let pct = a > 0 ? (b - a) / a * 100 : 0
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Money.priceFull(last.price)).font(AppFont.num(26)).foregroundStyle(Palette.ink)
                Text(String(format: "%+.2f%% · \(range.rawValue)", pct))
                    .font(AppFont.ui(12))
                    .foregroundStyle(Ledger.change(pct >= 0))
            }
        }
    }

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func axisLabel(_ v: Double) -> String {
        switch abs(v) {
        case 0..<10:            return "$" + String(format: "%.2f", v)
        case 10..<1_000:        return "$" + String(Int(v.rounded()))
        case 1_000..<1_000_000:
            let k = v / 1_000
            return "$" + (k < 10 ? String(format: "%.1f", k) : String(Int(k.rounded()))) + "k"
        default:
            let m = v / 1_000_000
            return "$" + String(format: "%.1f", m) + "m"
        }
    }

    /// Up to four dates across the axis, always including the ends — same rule
    /// `HistoryLedger.axisIndices` uses.
    private func axisIndices(_ n: Int) -> [Int] {
        guard n > 1 else { return n == 1 ? [0] : [] }
        if n <= 4 { return Array(0..<n) }
        return [0, n / 3, 2 * n / 3, n - 1]
    }

    private func scrubTooltip(_ i: Int) -> some View {
        VStack(spacing: 2) {
            Text(Money.priceFull(points[i].price)).font(Ledger.mono(11)).foregroundStyle(Palette.ink)
            Text(Self.axisFormatter.string(from: points[i].date)).font(Ledger.mono(9)).foregroundStyle(Palette.ink.opacity(0.5))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Look.shared.ink.pill)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var chartArea: some View {
        GeometryReader { geo in
            let size = geo.size
            let values = points.map { NSDecimalNumber(decimal: $0.price).doubleValue }
            if points.count >= 2 {
                let g = geometry(size, values)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<5) { step in
                        let v = g.yLo + (g.yHi - g.yLo) * Double(step) / 4
                        let yy = g.y(v)
                        Path { p in
                            p.move(to: CGPoint(x: g.left, y: yy))
                            p.addLine(to: CGPoint(x: size.width - 10, y: yy))
                        }
                        .stroke(Palette.ink.opacity(0.08), lineWidth: 1)
                        Text(axisLabel(v))
                            .font(Ledger.mono(9.5)).foregroundStyle(Look.shared.ink.faint)
                            .frame(width: g.left - 8, alignment: .trailing)
                            .offset(x: 0, y: yy - 7)
                    }

                    Path { path in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: g.x(i), y: g.y(v))
                            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                        }
                    }
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))

                    ForEach(axisIndices(points.count), id: \.self) { i in
                        Text(Self.axisFormatter.string(from: points[i].date))
                            .font(Ledger.mono(9.5)).foregroundStyle(Look.shared.ink.faint)
                            .fixedSize()
                            .offset(x: g.x(i) - (i == 0 ? 0 : i == points.count - 1 ? 40 : 20),
                                    y: size.height - 16)
                    }

                    if let hi = hoverIndex, points.indices.contains(hi) {
                        let cx = g.x(hi), cy = g.y(values[hi])
                        Path { p in
                            p.move(to: CGPoint(x: cx, y: g.top))
                            p.addLine(to: CGPoint(x: cx, y: size.height - g.bottom))
                        }
                        .stroke(Palette.dim, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Circle().fill(Palette.ink).frame(width: 6, height: 6).position(x: cx, y: cy)
                        scrubTooltip(hi).position(x: min(max(cx, 44), size.width - 44), y: max(cy - 24, 14))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        let frac = (loc.x - g.left) / max(size.width - g.left - 10, 1)
                        let idx = Int((frac * CGFloat(points.count - 1)).rounded())
                        hoverIndex = min(max(idx, 0), points.count - 1)
                    case .ended:
                        hoverIndex = nil
                    }
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No history available")
                    .font(AppFont.ui(11)).foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 220)
    }

    private var rangeRail: some View {
        VStack(spacing: 6) {
            ForEach(Range.allCases) { r in
                let on = r == range
                Text(r.rawValue).font(AppFont.mono(10.5))
                    .foregroundStyle(on ? Palette.ink : Palette.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(on ? Palette.surface : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { range = r }
            }
        }
        .frame(width: 56)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            priceLine
            HStack(alignment: .top, spacing: 14) {
                chartArea
                rangeRail
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
        .task(id: range) { await load() }
    }
}
