import SwiftUI
import BookkeeperCore

/// The top of Portfolio: what the holdings were worth over time, each wallet a band in its
/// colour stacked on the next — a stock that grows and shrinks, not Banking's month-by-month
/// flow, so a line, not bars. Months along the bottom; the right edge is today's live worth.
/// Hover to read a date (every wallet with its emoji); drag across to zoom into a stretch;
/// the presets above set the range. Zoomed into a wallet, just that wallet's band.
struct ValueChart: View {
    let model: CryptoTwoModel
    @Environment(\.ink) private var ink
    @State private var hover: (index: Int, x: CGFloat, y: CGFloat)?
    @State private var dragFrom: CGFloat?
    @State private var dragTo: CGFloat?

    static let height: CGFloat = 176
    private let top: CGFloat = 14, base: CGFloat = 148

    /// Bottom band first: every wallet in its colour, biggest at the bottom; then, in grey,
    /// any worth the history holds that no wallet now accounts for.
    private var bands: [(name: String?, color: Color)] {
        if let f = model.stripFocus { return [(f, Color(hex: hex(f)))] }
        return model.stripLead.map { ($0, Color(hex: hex($0))) } + [(nil, ink.track)]
    }

    private func hex(_ name: String) -> String {
        model.store.wallets.first { $0.nickname == name }.map(model.walletHex) ?? "#8C9196"
    }

    /// One sample's value per band, bottom up.
    private func layers(_ s: CryptoTwoModel.Bucket) -> [Double] {
        if let f = model.stripFocus { return [s.byWallet[f] ?? 0] }
        let lead = model.stripLead.map { s.byWallet[$0] ?? 0 }
        return lead + [max(0, s.total - lead.reduce(0, +))]
    }

    var body: some View {
        let data = model.samplesInRange
        GeometryReader { geo in
            let w = geo.size.width
            let t0 = data.first?.date.timeIntervalSince1970 ?? 0
            let t1 = max(t0 + 1, data.last?.date.timeIntervalSince1970 ?? 1)
            let peak = max(1, data.map { layers($0).reduce(0, +) }.max() ?? 1) * 1.08
            let x: (Date) -> CGFloat = { CGFloat(($0.timeIntervalSince1970 - t0) / (t1 - t0)) * w }
            let y: (Double) -> CGFloat = { base - CGFloat($0 / peak) * (base - top) }

            Canvas { ctx, _ in
                guard data.count >= 2 else { return }
                // Stacked bands, top of the stack drawn last so its edge sits clean.
                var floor = Array(repeating: 0.0, count: data.count)
                for (bi, band) in bands.enumerated() {
                    let ceil = data.indices.map { floor[$0] + layers(data[$0])[bi] }
                    var area = Path()
                    area.move(to: CGPoint(x: x(data[0].date), y: y(ceil[0])))
                    for i in data.indices.dropFirst() { area.addLine(to: CGPoint(x: x(data[i].date), y: y(ceil[i]))) }
                    for i in data.indices.reversed() { area.addLine(to: CGPoint(x: x(data[i].date), y: y(floor[i]))) }
                    area.closeSubpath()
                    ctx.fill(area, with: .color(band.color.opacity(band.name == nil ? 0.55 : 0.88)))
                    var edge = Path()
                    edge.move(to: CGPoint(x: x(data[0].date), y: y(ceil[0])))
                    for i in data.indices.dropFirst() { edge.addLine(to: CGPoint(x: x(data[i].date), y: y(ceil[i]))) }
                    ctx.stroke(edge, with: .color(ink.ground.opacity(0.6)), lineWidth: 1)
                    floor = ceil
                }
                // Month names under the first sample of each month.
                var lastMonth = -1
                for s in data {
                    let m = Calendar.current.component(.month, from: s.date)
                    guard m != lastMonth else { continue }
                    lastMonth = m
                    let px = x(s.date)
                    guard px < w - 24 || s.date == data.last?.date else { continue }
                    ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: base)); $0.addLine(to: CGPoint(x: px, y: base + 5)) },
                               with: .color(ink.rule), lineWidth: 1)
                    let t = ctx.resolve(Text(Fmt.monthNames[m - 1]).font(HouseFont.jost(11.5)).foregroundStyle(ink.muted))
                    ctx.draw(t, at: CGPoint(x: min(max(px, 14), w - 14), y: Self.height - 3), anchor: .bottom)
                }
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: base)); $0.addLine(to: CGPoint(x: w, y: base)) },
                           with: .color(ink.rule), lineWidth: 1)
                // Hover: a line down the date, a dot on the top of the stack.
                if let h = hover, data.indices.contains(h.index) {
                    let px = x(data[h.index].date)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: top)); $0.addLine(to: CGPoint(x: px, y: base)) },
                               with: .color(ink.text.opacity(0.5)), lineWidth: 1)
                    let dot = CGRect(x: px - 4, y: y(layers(data[h.index]).reduce(0, +)) - 4, width: 8, height: 8)
                    ctx.fill(Path(ellipseIn: dot), with: .color(ink.text))
                }
                // A drag in progress: the stretch it would zoom into.
                if let a = dragFrom, let b = dragTo {
                    let r = CGRect(x: min(a, b), y: top, width: abs(b - a), height: base - top)
                    ctx.fill(Path(r), with: .color(ink.text.opacity(0.08)))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let p) = phase, dragFrom == nil, !data.isEmpty else { hover = nil; return }
                let t = t0 + Double(p.x / max(w, 1)) * (t1 - t0)
                let i = data.indices.min { abs(data[$0].date.timeIntervalSince1970 - t) < abs(data[$1].date.timeIntervalSince1970 - t) } ?? 0
                hover = (i, p.x, p.y)
            }
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { g in dragFrom = g.startLocation.x; dragTo = g.location.x; hover = nil }
                .onEnded { _ in
                    defer { dragFrom = nil; dragTo = nil }
                    guard let a = dragFrom, let b = dragTo, abs(b - a) > 12 else { return }
                    let date: (CGFloat) -> Date = { Date(timeIntervalSince1970: t0 + Double($0 / max(w, 1)) * (t1 - t0)) }
                    model.select(model.bucketIndex(for: date(min(a, b))), model.bucketIndex(for: date(max(a, b))))
                })
            .overlay(alignment: .topLeading) {
                if let h = hover, data.indices.contains(h.index) {
                    card(data[h.index])
                        .fixedSize()
                        .offset(x: min(h.x + 14, w - 230), y: 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.height)
    }

    private func card(_ s: CryptoTwoModel.Bucket) -> some View {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        let isNow = s.date >= (model.samples.last?.date ?? .distantFuture)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(isNow ? "Now" : f.string(from: s.date)) · \(Fmt.usd(model.stripFocus.map { s.byWallet[$0] ?? 0 } ?? s.total))")
                .font(HouseFont.jost(12.5, 600)).foregroundStyle(ink.text)
            ForEach(s.byWallet.sorted { $0.value > $1.value }.filter { model.stripFocus == nil || $0.key == model.stripFocus },
                    id: \.key) { k, v in
                HStack(spacing: 8) {
                    Emoji(name: model.walletEmoji(k), size: 16)
                    Text(k)
                    Spacer(minLength: 12)
                    Text(Fmt.usd(v)).monospacedDigit()
                }
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.text)
            }
        }
        .frame(minWidth: 190, alignment: .leading)
        .modifier(FloatingCard())
    }
}

/// A token's price over time, beside what's held of it — the price section of a token's
/// panel. 24 H · 1 M · 3 M · 1 Y; hover to read a date's price. Prices come through the
/// same keyless source as every other price (through Tor), cached so reopening is instant.
struct TokenPriceSection: View {
    let store: PortfolioStore
    let token: Token
    let amount: Double
    let price: Decimal?
    let hex: String
    @Environment(\.ink) private var ink
    @State private var span: Span = .month
    @State private var points: [PricePoint] = []
    @State private var loading = true
    @State private var hover: Int?

    enum Span: String, CaseIterable, Identifiable {
        case day = "24H", month = "1M", quarter = "3M", year = "1Y"
        var id: String { rawValue }
        var days: Int { switch self { case .day: 1; case .month: 30; case .quarter: 90; case .year: 365 } }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                figure("Total", "\(amount.formatted(.number.precision(.significantDigits(1...6)))) \(token.symbol)")
                figure("Current price", price.map(Money.price) ?? "—")
                if let c = change {
                    Text("\(c >= 0 ? "▲" : "▼") \(Fmt.percent(abs(c), digits: 1)) · \(span.rawValue)")
                        .font(HouseFont.jost(13, 500)).foregroundStyle(c >= 0 ? ink.up : ink.warm)
                }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(Span.allCases) { s in
                        Button { span = s } label: {
                            Text(s.rawValue).font(HouseFont.jost(12))
                                .foregroundStyle(span == s ? ink.text : ink.muted)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(span == s ? ink.pill : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                chart.frame(height: 120)
            }
        }
        .padding(.vertical, 6)
        .task(id: "\(token.id)|\(span.rawValue)") {
            loading = true
            points = await store.priceHistory(for: token, days: span.days)
            loading = false
        }
    }

    /// Start of the span to now.
    private var change: Double? {
        guard let a = points.first?.price.double, let z = points.last?.price.double, a > 0 else { return nil }
        return (z - a) / a * 100
    }

    private var chart: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let vals = points.map(\.price.double)
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            let pad = max((hi - lo) * 0.08, hi * 0.001)
            let y: (Double) -> CGFloat = { h - 18 - CGFloat(($0 - (lo - pad)) / max(hi - lo + 2 * pad, 1e-12)) * (h - 26) }
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(max(1, vals.count - 1)) * w }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    guard vals.count >= 2 else { return }
                    var line = Path()
                    line.move(to: CGPoint(x: x(0), y: y(vals[0])))
                    for i in vals.indices.dropFirst() { line.addLine(to: CGPoint(x: x(i), y: y(vals[i]))) }
                    ctx.stroke(line, with: .color(Color(hex: hex)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let i = hover, vals.indices.contains(i) {
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x(i), y: 0)); $0.addLine(to: CGPoint(x: x(i), y: h - 18)) },
                                   with: .color(ink.text.opacity(0.4)), lineWidth: 1)
                        ctx.fill(Path(ellipseIn: CGRect(x: x(i) - 4, y: y(vals[i]) - 4, width: 8, height: 8)),
                                 with: .color(Color(hex: hex)))
                    }
                }
                if loading && points.isEmpty {
                    Text("Fetching prices…").font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if points.count < 2 {
                    Text("No price history for this token.").font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let i = hover, points.indices.contains(i) {
                    Text("\(label(points[i].date)) · \(Money.price(points[i].price))")
                        .font(HouseFont.jost(12, 500)).foregroundStyle(ink.text)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(ink.card, in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(0, x(i) - 70), w - 160), y: h - 16)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let p) = phase, vals.count >= 2 else { hover = nil; return }
                hover = min(vals.count - 1, max(0, Int((p.x / max(w, 1) * CGFloat(vals.count - 1)).rounded())))
            }
        }
    }

    private func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = span == .day ? "h a" : "MMM d"
        return f.string(from: d)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            Text(value).font(HouseFont.jost(16, 500)).monospacedDigit().foregroundStyle(ink.text)
        }
    }
}

/// A token's price section in a window over the screen — opened from a wallet's or a
/// network's token list, where there's no token panel to zoom into. Same figures and chart
/// as the token panel; what's held is across every wallet, as the Tokens tab counts it.
struct TokenPriceModal: View {
    let model: CryptoTwoModel
    let token: Token
    var close: () -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        let rows = model.rows.filter { $0.token.symbol == token.symbol }
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TokenGlyph(token: token, size: Look.panelCap)
                Text(token.symbol).font(HouseFont.jost(22, 500)).foregroundStyle(ink.text)
                Spacer()
                Button(action: close) {
                    Text("Close").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(ink.pill, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            TokenPriceSection(store: model.store, token: token, amount: rows.reduce(0) { $0 + $1.amount },
                              price: rows.first { $0.price != nil }?.price, hex: model.tokenHex(token))
        }
        .padding(24)
        .frame(width: 600)
        .background(ink.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.rule, lineWidth: 1))
        .shadow(color: ink.shadow, radius: 24, y: 10)
    }
}
