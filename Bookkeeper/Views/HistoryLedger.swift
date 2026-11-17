import SwiftUI
import BookkeeperCore

/// **History** — what the portfolio was worth, on the days you said so.
///
/// The archive is hand-made. Nothing here fills itself in: a mark exists because the
/// button was pressed on that day, which is why the chart can be read as a record rather
/// than as a sampling artefact of when the app happened to be open.
///
/// Stacked by wallet, in the wallets' own colours, so the shape answers two questions at
/// once — how much, and which wallet moved. The baseline is ZERO, because a stack has to
/// stand on something: band thickness is the wallet's value, and a floor above zero would
/// leave the bottom band with nowhere to sit and slide it off the frame.
struct HistoryLedger: View {
    let store: PortfolioStore

    /// Seeded at init, not in `onAppear`.
    ///
    /// Loading it in `onAppear` meant the screen had no data until the view had been
    /// shown once — which is invisible in the running app and total in an offscreen
    /// render, where `content` is drawn without ever appearing. A screen that only has
    /// its data after an appearance callback is a screen that can't be rendered, and
    /// the render is how this gets reviewed.
    @State private var points: [HistoryStore.Point]

    /// `editing` and `confirmingColumn` exist for the offscreen render, which has no way
    /// to press the Edit button — the app always opens with them off.
    init(store: PortfolioStore, editing: Bool = false, confirmingColumn: String? = nil) {
        self.store = store
        let loaded = store.historyPoints()
        _points = State(initialValue: loaded)
        _editing = State(initialValue: editing)
        _confirmingColumn = State(initialValue: confirmingColumn)
        _columnWidths = State(initialValue: Self.naturalWidths(for: loaded))
        _tints = State(initialValue:
            store.walletTints(for: Set(loaded.flatMap { $0.breakdown.keys }).sorted()))
    }

    /// Reload after a change, and re-measure — a removed mark can be the one that was
    /// making a column wide.
    private func reload() {
        points = store.historyPoints()
        measureColumns()
        measureTints()
    }
    @State private var range: Range = .ninety
    @State private var mode: Mode = .value
    @State private var hovered: Int?
    @State private var hoveredRow: Date?
    @State private var confirmingRemoval: Date?
    /// Width per wallet column, measured from the widest thing that column holds.
    /// Cached rather than computed in `body`: it is a measurement per cell, and with a
    /// year of marks across a dozen wallets that is thousands of them every redraw.
    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var tints: [String: String] = [:]

    @State private var justArchived = false
    /// The index's Edit mode: every name the archive holds gets a column, current or not,
    /// each with an ✕ that strikes it out of the record.
    @State private var editing: Bool
    @State private var confirmingColumn: String?

    enum Range: String, CaseIterable, Identifiable {
        case thirty = "30D", ninety = "90D", year = "1Y", all = "ALL"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .thirty: return 30
            case .ninety: return 90
            case .year:   return 365
            case .all:    return nil
            }
        }
    }

    /// Dollars, or each wallet's share of the day.
    ///
    /// The same bands answering a different question: value asks "am I up", share asks
    /// "is one wallet taking over". A toggle rather than a second chart — it is one set
    /// of numbers, and two charts of one thing is two places to look.
    enum Mode: String, CaseIterable, Identifiable {
        case value = "VALUE", share = "SHARE"
        var id: String { rawValue }
    }

    // MARK: - Data

    /// One point per day, latest wins.
    ///
    /// The archive is a diary of days, but the file predates that: earlier versions
    /// recorded a snapshot on every refresh, so a day the app was open a lot carries a
    /// dozen marks and a day it wasn't carries none. Left alone those clusters bunch the
    /// chart around whenever the app happened to be running. Collapsing by day makes
    /// every day count once, which is what the button records from here on.
    private var daily: [HistoryStore.Point] {
        var byDay: [Date: HistoryStore.Point] = [:]
        let cal = Calendar.current
        for p in points {
            let key = cal.startOfDay(for: p.date)
            if let existing = byDay[key], existing.date >= p.date { continue }
            byDay[key] = p
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    private var shown: [HistoryStore.Point] {
        let all = daily
        guard let days = range.days else { return all }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let inRange = all.filter { $0.date >= cutoff }
        // A range with one mark in it can't be drawn as a shape; fall back to everything
        // rather than showing an empty frame that looks like lost data.
        return inRange.count >= 2 ? inRange : all
    }

    /// Names that are wallets today. The archive also remembers names that no longer are
    /// — renamed before renames reached it, or removed — and those don't get a band or a
    /// column of their own as if they were still here.
    ///
    /// Read once per pass and handed down: it comes off the wallet file, and the band
    /// loops ask per point.
    private var live: Set<String> { Set(store.orderedWalletNames) }

    /// Wallet names in the order they stack, biggest at the bottom.
    ///
    /// Fixed across the whole range from the LAST mark, not recomputed per day — a band
    /// that swaps places mid-chart reads as a crossing line rather than as one wallet.
    private func names(live: Set<String>) -> [String] {
        let last = shown.last?.breakdown ?? [:]
        let all = Set(shown.flatMap { $0.breakdown.keys }).intersection(live)
        return all.sorted { (last[$0] ?? 0, $1) > (last[$1] ?? 0, $0) }
    }

    /// What a mark credits to names that are no longer wallets.
    private func retiredValue(_ p: HistoryStore.Point, live: Set<String>) -> Decimal {
        p.breakdown.filter { !live.contains($0.key) }.values.reduce(0, +)
    }

    /// Colours for every name the archive mentions, resolved as one set so two bands can
    /// never come out the same. Cached: it walks the palette, and `body` asks per band.
    private func colour(_ name: String) -> Color {
        Color(hex: tints[name] ?? store.walletTintHex(name))
    }

    private func measureTints() {
        let everyName = Set(points.flatMap { $0.breakdown.keys }).sorted()
        tints = store.walletTints(for: everyName)
    }

    /// What a day's bands add up to. A mark made before breakdowns existed has none, so
    /// its total is carried as one unattributed band rather than the day vanishing; money
    /// under names that are no longer wallets is carried as one "old wallets" band.
    private func bands(_ p: HistoryStore.Point, live: Set<String>) -> [String: Decimal] {
        guard !p.breakdown.isEmpty else { return [Ledger.unattributed: p.total] }
        var out = p.breakdown.filter { live.contains($0.key) }
        let retired = retiredValue(p, live: live)
        if retired > 0 { out[Ledger.retired] = retired }
        return out
    }

    private func stackNames(live: Set<String>) -> [String] {
        var out = names(live: live)
        if shown.contains(where: { retiredValue($0, live: live) > 0 }) { out.append(Ledger.retired) }
        if shown.contains(where: { $0.breakdown.isEmpty }) { out.append(Ledger.unattributed) }
        return out
    }

    /// The two bands that aren't a wallet — neither wears a wallet's colour.
    private func fill(_ name: String) -> Color {
        switch name {
        case Ledger.unattributed: return Palette.ink.opacity(0.14)
        case Ledger.retired:      return Palette.ink.opacity(0.26)
        default:                  return colour(name)
        }
    }

    private var ceiling: Double {
        let top = shown.map { NSDecimalNumber(decimal: $0.total).doubleValue }.max() ?? 1
        return max(top * 1.06, 1)
    }

    // MARK: - Header

    private var latest: HistoryStore.Point? { shown.last }

    private var changePercent: Double? {
        guard let first = shown.first, let last = shown.last, first.total > 0,
              shown.count >= 2 else { return nil }
        let a = NSDecimalNumber(decimal: first.total).doubleValue
        let b = NSDecimalNumber(decimal: last.total).doubleValue
        return (b - a) / a * 100
    }

    private var hero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Money.usd(latest?.total ?? store.totalUSD))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-1.2)
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.4).lineLimit(1)
                HStack(spacing: 8) {
                    if let c = changePercent {
                        HStack(spacing: 4) {
                            Image(systemName: c >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            Text(String(format: "%.1f%%", abs(c)))
                        }
                        .foregroundStyle(c >= 0 ? Theme.positive : Theme.negative)
                    }
                    Text(marksLabel)
                        .foregroundStyle(Palette.ink.opacity(0.45))
                }
                .font(Ledger.mono(11))
            }
            Spacer(minLength: 16)
            archiveButton
        }
    }

    private var marksLabel: String {
        let n = shown.count
        guard n > 0 else { return "nothing archived yet" }
        let word = n == 1 ? "mark" : "marks"
        return range == .all ? "\(n) \(word)" : "\(n) \(word) in \(range.rawValue)"
    }

    private var archiveButton: some View {
        let done = store.archivedToday
        return Button {
            if store.archiveToday() {
                reload()
                withAnimation(.easeOut(duration: 0.2)) { justArchived = true }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(done ? Theme.positive : Palette.ink.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text(done ? "Archived today" : "Archive today").font(Ledger.mono(11.5))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 15).padding(.vertical, 10)
            .background(justArchived ? Look.shared.ink.track : Ledger.wash(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pressing again on the same day replaces the mark rather than adding one, so
        // the button stays live: today's figure can be corrected after a refresh.
        .help(done ? "Replace today's mark with the current total" : "Record today's total")
    }

    // MARK: - Chart

    /// X is placed by DATE, not by position in the list.
    ///
    /// Index spacing would draw a week of daily marks and a week with one mark as the
    /// same width, so a gap in the record would vanish instead of showing as a gap. The
    /// archive is allowed to have holes — it is made by hand — and the chart has to admit
    /// where they are.
    private func geometry(_ size: CGSize) -> (x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        let left: CGFloat = 58, right: CGFloat = 10, top: CGFloat = 14, bottom: CGFloat = 26
        let list = shown
        let start = list.first?.date.timeIntervalSince1970 ?? 0
        let end = list.last?.date.timeIntervalSince1970 ?? start
        let span = max(end - start, 1)
        let x = { (i: Int) -> CGFloat in
            guard list.indices.contains(i) else { return left }
            let t = (list[i].date.timeIntervalSince1970 - start) / span
            return left + CGFloat(t) * (size.width - left - right)
        }
        let y = { (v: Double) -> CGFloat in
            let frac = mode == .share ? v : v / self.ceiling
            return top + (1 - CGFloat(min(max(frac, 0), 1))) * (size.height - top - bottom)
        }
        return (x, y)
    }

    /// Each wallet's band as a closed shape: up along its own top edge, back along the
    /// running total beneath it.
    private func bandPaths(_ size: CGSize) -> [(name: String, path: Path)] {
        guard shown.count >= 2 else { return [] }
        let g = geometry(size)
        let live = self.live
        let perPoint = shown.map { bands($0, live: live) }
        var running = [Double](repeating: 0, count: shown.count)
        var out: [(String, Path)] = []

        for name in stackNames(live: live) {
            var tops = [Double](repeating: 0, count: shown.count)
            for (i, point) in shown.enumerated() {
                let value = perPoint[i][name] ?? 0
                var v = NSDecimalNumber(decimal: value).doubleValue
                if mode == .share {
                    let total = NSDecimalNumber(decimal: point.total).doubleValue
                    v = total > 0 ? v / total : 0
                }
                tops[i] = running[i] + v
            }
            var path = Path()
            path.move(to: CGPoint(x: g.x(0), y: g.y(tops[0])))
            for i in 1..<shown.count { path.addLine(to: CGPoint(x: g.x(i), y: g.y(tops[i]))) }
            for i in stride(from: shown.count - 1, through: 0, by: -1) {
                path.addLine(to: CGPoint(x: g.x(i), y: g.y(running[i])))
            }
            path.closeSubpath()
            out.append((name, path))
            running = tops
        }
        return out
    }

    /// The total, as one clean edge over the bands.
    private func topEdge(_ size: CGSize) -> Path {
        guard shown.count >= 2 else { return Path() }
        let g = geometry(size)
        var path = Path()
        for (i, point) in shown.enumerated() {
            let v = mode == .share ? 1 : NSDecimalNumber(decimal: point.total).doubleValue
            let p = CGPoint(x: g.x(i), y: g.y(v))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }

    private func gridlines(_ size: CGSize) -> some View {
        let g = geometry(size)
        return ZStack(alignment: .topLeading) {
            ForEach(0...4, id: \.self) { step in
                let frac = Double(step) / 4
                let value = mode == .share ? frac : frac * ceiling
                let y = g.y(value)
                Path { p in
                    p.move(to: CGPoint(x: 58, y: y))
                    p.addLine(to: CGPoint(x: size.width - 10, y: y))
                }
                .stroke(Palette.ink.opacity(0.12), lineWidth: 1)

                Text(mode == .share ? "\(Int(frac * 100))%" : Self.axisLabel(value))
                    .font(Ledger.mono(9.5))
                    .foregroundStyle(Look.shared.ink.faint)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .trailing)
                    .offset(x: 0, y: y - 7)
            }
        }
    }

    /// An axis label has one line and about six characters. The table's own formatter
    /// only abbreviates above 100k, so a portfolio at $98,386.40 printed in full and
    /// wrapped onto two lines in the gutter — which read as a broken label, not a number.
    static func axisLabel(_ value: Double) -> String {
        switch abs(value) {
        case 0..<1:            return "$0"
        case 1..<1_000:        return "$" + String(Int(value.rounded()))
        case 1_000..<1_000_000:
            let k = value / 1_000
            return "$" + (k < 10 ? String(format: "%.1f", k) : String(Int(k.rounded()))) + "k"
        default:
            let m = value / 1_000_000
            return "$" + String(format: "%.1f", m) + "m"
        }
    }

    private func dateAxis(_ size: CGSize) -> some View {
        let g = geometry(size)
        let marks = axisIndices
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { i in
                Text(Self.dayFormatter.string(from: shown[i].date))
                    .font(Ledger.mono(9.5))
                    .foregroundStyle(Look.shared.ink.faint)
                    .fixedSize()
                    .offset(x: g.x(i) - (i == 0 ? 0 : i == shown.count - 1 ? 46 : 23),
                            y: size.height - 18)
            }
        }
    }

    /// Up to four dates across the axis, always including the ends.
    private var axisIndices: [Int] {
        let n = shown.count
        guard n > 1 else { return n == 1 ? [0] : [] }
        if n <= 4 { return Array(0..<n) }
        return [0, n / 3, 2 * n / 3, n - 1]
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var chart: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                gridlines(size)
                ForEach(bandPaths(size), id: \.name) { band in
                    band.path
                        .fill(fill(band.name).opacity(0.94))
                }
                topEdge(size).stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
                if let last = shown.indices.last, shown.count >= 2 {
                    let g = geometry(size)
                    let v = mode == .share ? 1 : NSDecimalNumber(decimal: shown[last].total).doubleValue
                    Circle().fill(Palette.ink)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 2))
                        .offset(x: g.x(last) - 4, y: g.y(v) - 4)
                }
                dateAxis(size)
            }
        }
        .frame(height: 300)
        .animation(.easeOut(duration: 0.22), value: mode)
        .animation(.easeOut(duration: 0.22), value: range)
    }

    // MARK: - Legend + controls

    /// Swatch and name only.
    ///
    /// It used to carry each wallet's latest value too, which put a figure a long way
    /// from the date it belonged to and read as three unrelated things in a row. The
    /// legend's whole job is to say which colour is which wallet; every number lives in
    /// the index below, next to the day it was recorded on.
    private var legend: some View {
        FlowRow(spacing: 16, lineSpacing: 8) {
            ForEach(stackNames(live: live), id: \.self) { name in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill(name))
                        .frame(width: 9, height: 9)
                    Text(name).font(Ledger.mono(10.5)).foregroundStyle(Palette.ink.opacity(0.6))
                }
            }
        }
    }

    private func pill<T: Identifiable & Equatable>(_ items: [T], selected: T,
                                                   label: @escaping (T) -> String,
                                                   pick: @escaping (T) -> Void) -> some View {
        HStack(spacing: Ledger.gutter) {
            ForEach(items) { item in
                let on = item == selected
                Text(label(item))
                    .font(Ledger.mono(10.5))
                    .foregroundStyle(on ? Palette.ink : Palette.ink.opacity(0.4))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? Look.shared.ink.track : Look.shared.ink.rule)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { pick(item) }
            }
        }
    }

    // MARK: - The index

    /// Every mark as a line item: the day it was made, the total, the move since the
    /// mark before it, and what each wallet held.
    ///
    /// This is where the numbers live. The chart shows shape — where the value went —
    /// and a shape can't be read to the dollar; the index is the record itself, and it
    /// grows by one line every time the button is pressed.
    private enum Col {
        static let date: CGFloat = 84
        static let total: CGFloat = 108
        static let delta: CGFloat = 62
        /// Fallback only — a wallet column is measured from what it holds.
        static let wallet: CGFloat = 98
        static let minWallet: CGFloat = 58
        static let maxWallet: CGFloat = 150
        static let remove: CGFloat = 88
    }

    /// Newest at the top: the mark just made is the one being looked for.
    private var indexRows: [HistoryStore.Point] { daily.reversed() }

    /// Columns for the index, from EVERY mark rather than from the visible range — the
    /// range pill moves the chart, and a table whose columns appeared and vanished with
    /// it would be unreadable.
    ///
    /// Current wallets only, until Edit: then every name the archive holds shows, so an
    /// old one can be seen and struck out. Old names sit after the current ones.
    private var indexNames: [String] {
        let last = daily.last?.breakdown ?? [:]
        let live = self.live
        let all = Set(daily.flatMap { $0.breakdown.keys })
        let byValue = { (a: String, b: String) in (last[a] ?? 0, b) > (last[b] ?? 0, a) }
        let current = all.intersection(live).sorted(by: byValue)
        return editing ? current + all.subtracting(live).sorted(by: byValue) : current
    }

    /// What each column needs: wide enough for its title or its widest figure.
    ///
    /// Pure, so the first paint is measured too — a table that only sizes itself after an
    /// appearance callback renders at its fallback width offscreen, which is exactly
    /// where it gets reviewed.
    static func naturalWidths(for points: [HistoryStore.Point]) -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        for name in Set(points.flatMap { $0.breakdown.keys }) {
            let header = Ledger.width(name.uppercased(), size: 9, tracking: 0.6) + 12
            var widest: CGFloat = 0
            for point in points {
                let text = point.breakdown.isEmpty
                    ? "—" : "$" + Ledger.value(point.breakdown[name] ?? 0)
                widest = max(widest, Ledger.width(text, size: 10.5) + 14)
            }
            out[name] = max(header, widest, Col.minWallet)
        }
        return out
    }

    private func measureColumns() { columnWidths = Self.naturalWidths(for: points) }

    /// Natural widths, then stretched or squeezed to land exactly on the width available.
    ///
    /// The table used to scroll sideways instead. A scrollbar under a chart that fits is
    /// a second way to move around one screen, and it hid columns behind a gesture. So
    /// the columns share whatever room is left after the fixed ones: extra space is
    /// handed out in proportion, and when there isn't enough they shrink together down
    /// to a floor. Only past that floor — far more wallets than fit legibly — does
    /// anything scroll.
    private func laidOutWidths(in available: CGFloat, names: [String]) -> [String: CGFloat] {
        guard !names.isEmpty else { return [:] }
        let gutters = Ledger.gutter * CGFloat(names.count + 3)
        let fixed = Col.date + Col.total + Col.delta + Col.remove + gutters
        let room = available - fixed
        let natural = names.map { columnWidths[$0] ?? Col.wallet }
        let total = natural.reduce(0, +)
        guard total > 0, room > 0 else {
            return Dictionary(uniqueKeysWithValues: zip(names, natural))
        }
        let scale = room / total
        var out: [String: CGFloat] = [:]
        for (name, width) in zip(names, natural) {
            // Never below the floor, and never so stretched that two wallets take a
            // whole window each.
            out[name] = min(max(width * scale, Col.minWallet), Col.maxWallet)
        }
        return out
    }



    /// The move against the mark before it, in chronological order.
    private func moveSincePrevious(_ point: HistoryStore.Point) -> Double? {
        let chronological = daily
        guard let i = chronological.firstIndex(where: { $0.date == point.date }), i > 0 else { return nil }
        let before = NSDecimalNumber(decimal: chronological[i - 1].total).doubleValue
        guard before > 0 else { return nil }
        let now = NSDecimalNumber(decimal: point.total).doubleValue
        return (now - before) / before * 100
    }

    private func indexHeader(_ names: [String], _ widths: [String: CGFloat]) -> some View {
        let live = self.live
        return HStack(spacing: Ledger.gutter) {
            Text("DATE").frame(width: Col.date, alignment: .leading)
            Text("TOTAL").frame(width: Col.total, alignment: .trailing)
            Text("MOVE").frame(width: Col.delta, alignment: .trailing)
            ForEach(names, id: \.self) { name in
                // The wallet's own colour names its column, the way the network tab
                // names its rows — so the index and the chart are read with one key.
                let ink = Ledger.ink(on: colour(name))
                let marked = confirmingColumn == name
                LedgerBlock(fill: marked ? Theme.negative : colour(name), height: 18) {
                    HStack(spacing: 3) {
                        Text(name.uppercased())
                            .font(Ledger.mono(9)).tracking(0.6)
                            .foregroundStyle(marked ? .white : ink)
                            .lineLimit(1).minimumScaleFactor(0.55)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if editing {
                            Button { confirmingColumn = name } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle((marked ? .white : ink).opacity(0.75))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(name) from every mark")
                        }
                    }
                    .padding(.horizontal, 6)
                }
                // An old name reads as one: same colour, knocked back, so what is a
                // wallet today and what is only in the record can be told apart.
                // The one pending removal stays full strength whatever it is.
                .opacity(live.contains(name) || marked ? 1 : 0.55)
                .frame(width: widths[name] ?? Col.wallet)
            }
            Color.clear.frame(width: Col.remove, height: 1)   // room for the remove control
        }
        .font(Ledger.mono(9)).tracking(1.4)
        .foregroundStyle(Palette.ink.opacity(0.4))
    }

    private func indexRow(_ point: HistoryStore.Point, _ names: [String],
                          _ widths: [String: CGFloat]) -> some View {
        let move = moveSincePrevious(point)
        return HStack(spacing: Ledger.gutter) {
            Text(Self.rowDateFormatter.string(from: point.date))
                .font(Ledger.mono(11)).foregroundStyle(Palette.ink.opacity(0.75))
                .frame(width: Col.date, alignment: .leading)

            LedgerBlock(fill: Look.shared.ink.track, height: 22) {
                HStack(spacing: 0) {
                    Text("$").font(Ledger.mono(10.5)).foregroundStyle(Palette.ink.opacity(0.5))
                        .padding(.leading, 7)
                    Spacer(minLength: 2)
                    Text(Ledger.value(point.total))
                        .font(Ledger.mono(11)).foregroundStyle(Palette.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.trailing, 7)
                }
            }
            .frame(width: Col.total)

            Text(move.map { String(format: "%+.1f%%", $0) } ?? "—")
                .font(Ledger.mono(10.5))
                .foregroundStyle(move == nil ? Palette.ink.opacity(0.25)
                                 : (move! >= 0 ? Theme.positive : Theme.negative))
                .frame(width: Col.delta, alignment: .trailing)

            ForEach(names, id: \.self) { name in
                LedgerBlock(fill: Look.shared.ink.rule, height: 22) {
                    // A mark made before breakdowns existed has no split to show. An em
                    // dash says "not recorded"; a zero would say "held nothing", which
                    // is a different and untrue claim.
                    Text(point.breakdown.isEmpty ? "—"
                         : "$" + Ledger.value(point.breakdown[name] ?? 0))
                        .font(Ledger.mono(10.5))
                        .foregroundStyle(point.breakdown.isEmpty
                                         ? Palette.ink.opacity(0.25) : Palette.ink.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: widths[name] ?? Col.wallet)
            }

            removeControl(point)
        }
        .onHover { hoveredRow = $0 ? point.date : nil }
    }

    /// Removing a mark asks first.
    ///
    /// A past day cannot be re-made: the prices that produced it are gone, so a mis-click
    /// on a bare ✕ destroys a number that can never be recovered. The confirm is inline
    /// rather than a sheet — it costs one more click and no modal, and the row stays put
    /// so it is obvious which day is about to go.
    @ViewBuilder private func removeControl(_ point: HistoryStore.Point) -> some View {
        if confirmingRemoval == point.date {
            HStack(spacing: Ledger.gutter) {
                Text("DELETE?").font(Ledger.mono(9)).tracking(1)
                    .foregroundStyle(Palette.ink.opacity(0.5))
                Button {
                    store.removeArchive(on: point.date)
                    points = store.historyPoints()
                    measureColumns()
                    confirmingRemoval = nil
                } label: {
                    Text("YES").font(Ledger.mono(9)).tracking(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.negative)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                Button { confirmingRemoval = nil } label: {
                    Text("NO").font(Ledger.mono(9)).tracking(1)
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Look.shared.ink.track)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .frame(width: Col.remove, alignment: .leading)
        } else {
            Button { confirmingRemoval = point.date } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 9))
                    Text("REMOVE").font(Ledger.mono(9)).tracking(1)
                }
                // Always legible, not a secret revealed by hovering — but quiet enough
                // that a column of them doesn't compete with the figures.
                .foregroundStyle(Palette.ink.opacity(hoveredRow == point.date ? 0.85 : 0.3))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Col.remove, alignment: .leading)
            .help("Remove this mark")
        }
    }

    /// One switch for the whole table, top right, rather than a pencil per column — the
    /// clean-up is occasional, and a row of controls on every header would be read on
    /// every visit to use once in a while.
    private var editButton: some View {
        Button {
            editing.toggle()
            confirmingColumn = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: editing ? "checkmark" : "pencil").font(.system(size: 9))
                Text(editing ? "DONE" : "EDIT").font(Ledger.mono(9)).tracking(1)
            }
            .foregroundStyle(Palette.ink.opacity(editing ? 0.9 : 0.5))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(editing ? Look.shared.ink.track : Look.shared.ink.rule)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(editing ? "Stop editing" : "Edit the wallets in the history")
    }

    /// Striking a wallet out asks first, and says what it costs: every mark loses that
    /// column AND those dollars from its total — which is the point for a duplicate left
    /// by a rename, and not undoable for anything else.
    private func columnConfirm(_ name: String) -> some View {
        HStack(spacing: Ledger.gutter) {
            Text("REMOVE \(name.uppercased()) FROM EVERY MARK AND ITS TOTAL?")
                .font(Ledger.mono(9)).tracking(1)
                .foregroundStyle(Palette.ink.opacity(0.6))
                .lineLimit(1)
            Button {
                store.removeArchivedWallet(name)
                confirmingColumn = nil
                reload()
            } label: {
                Text("YES").font(Ledger.mono(9)).tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.negative)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            Button { confirmingColumn = nil } label: {
                Text("NO").font(Ledger.mono(9)).tracking(1)
                    .foregroundStyle(Palette.ink.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Look.shared.ink.track)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }

    private var index: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("INDEX").font(Ledger.mono(10)).tracking(1.6)
                    .foregroundStyle(Palette.ink.opacity(0.5))
                Spacer(minLength: 0)
                if let name = confirmingColumn { columnConfirm(name) }
                editButton
            }
            // The width is read DURING layout, not reported back afterwards. A
            // preference callback never fires in an offscreen render, so the table
            // there kept its natural widths and stopped short of the chart above it —
            // and a layout that only settles once the view has appeared is a layout
            // that can't be reviewed. The height is computed rather than measured,
            // since a GeometryReader would otherwise claim the rest of the screen.
            GeometryReader { proxy in
                indexTable(fitting: proxy.size.width)
            }
            .frame(height: tableHeight)
        }
    }

    /// Header, then a row per mark. Deterministic, so the frame above can be sized to it.
    private var tableHeight: CGFloat {
        18 + Ledger.gutter + CGFloat(indexRows.count) * (22 + Ledger.gutter) + 4
    }

    private func indexTable(fitting width: CGFloat) -> some View {
        let names = indexNames
        let widths = laidOutWidths(in: width, names: names)
        return VStack(alignment: .leading, spacing: Ledger.gutter) {
            indexHeader(names, widths)
            ForEach(indexRows, id: \.date) { indexRow($0, names, widths) }
        }
        .padding(.bottom, 4)
    }

    static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // MARK: - Empty state

    private var empty: some View {
        VStack(spacing: 14) {
            Text("NOTHING ARCHIVED YET")
                .font(Ledger.mono(11)).tracking(2)
                .foregroundStyle(Palette.ink.opacity(0.5))
            Text("The archive is made by hand. Press Archive today and this becomes\nthe first mark — one per day, each one because you said so.")
                .font(Ledger.mono(11))
                .foregroundStyle(Palette.ink.opacity(0.35))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            archiveButton.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    /// One mark is a value, not yet a shape.
    private var single: some View {
        VStack(spacing: 12) {
            Text("ONE MARK SO FAR")
                .font(Ledger.mono(11)).tracking(2)
                .foregroundStyle(Palette.ink.opacity(0.5))
            Text("A line needs two days. Come back tomorrow and press it again.")
                .font(Ledger.mono(11)).foregroundStyle(Palette.ink.opacity(0.35))
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            if points.isEmpty {
                empty
            } else {
                // The chart needs two days to be a shape; the index needs one mark to be
                // a record. They appear independently, so the very first archive is
                // visible as a line with its date and total rather than as a message
                // saying to come back tomorrow.
                if shown.count < 2 {
                    single
                } else {
                    chart
                    legend
                    HStack(spacing: 10) {
                        pill(Range.allCases, selected: range, label: \.rawValue) { range = $0 }
                        Spacer(minLength: 0)
                        pill(Mode.allCases, selected: mode, label: \.rawValue) { mode = $0 }
                    }
                }
                index.padding(.top, 8)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        // Same measure and the same centring as the Portfolio page — the two screens sit
        // next to each other in the rail and a different width on each reads as one of
        // them being broken.
        .frame(maxWidth: 1320)
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        content
            .onAppear { reload() }
    }
}

