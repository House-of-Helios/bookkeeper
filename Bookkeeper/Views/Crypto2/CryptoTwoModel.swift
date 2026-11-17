import SwiftUI
import BookkeeperCore

/// Crypto 2 — the crypto side laid out the way Banking is: a strip of what the holdings
/// were worth over time, a two-ring donut of what they are worth now, and a panel beside
/// it. Built beside the old Crypto screens, not over them, so the two can be compared in
/// use before either is shed.
///
/// The ring answers one question at a time, picked under it: which **tokens**, which
/// **wallets**, which **networks**. The inner ring is that split; the outer ring breaks
/// each slice into the other side of it (a token's wallets, a wallet's tokens, a
/// network's tokens). Biggest slice centred at 3 o'clock, the rest clockwise, smaller and
/// smaller back round to 12 — the same rule the Banking ring keeps.
@Observable
final class CryptoTwoModel {
    let store: PortfolioStore

    var lens: Lens = .token
    /// The zoomed slice, by `Slice.id`.
    var drill: String?
    /// Indices into `buckets`.
    var range: ClosedRange<Int> = 0...0
    var preset: Preset? = .threeMonths
    /// The leaderboard under the panel opened past its first five.
    var showAll = false
    /// The wallet whose editor window is open, by id.
    var editingWallet: String?
    /// The token or network whose colour drawer is open.
    var editingColor: ColorTarget?
    /// The new-wallet drawer is open.
    var addingWallet = false
    /// The token whose price window is open — clicked in a wallet's or a network's list.
    var pricing: Token?
    /// "Now" for the made-up history, fixed at open so its bars keep their identity.
    private let opened = Date()

    init(store: PortfolioStore) {
        self.store = store
        applyPreset(.threeMonths)
    }

    enum Lens: String, CaseIterable, Hashable {
        case token, wallet, network
        var title: String {
            switch self {
            case .token: return "Tokens"
            case .wallet: return "Wallets"
            case .network: return "Networks"
            }
        }
        var emoji: String {
            switch self {
            case .token: return "coin"
            case .wallet: return "purse"
            case .network: return "globe_with_meridians"
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", yearToDate = "YTD", oneYear = "1Y", all = "All"
        var id: String { rawValue }
        var days: Int? {
            switch self {
            case .oneMonth: return 31
            case .threeMonths: return 92
            case .sixMonths: return 183
            case .oneYear: return 366
            case .yearToDate, .all: return nil
            }
        }
    }

    // MARK: - Now: the ring

    /// One holding row: a token in one wallet, valued.
    struct Row {
        let token: Token
        let wallet: Wallet
        let amount: Double
        let value: Double
        let price: Decimal?
    }

    var rows: [Row] {
        let byId = Dictionary(store.wallets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return store.visiblePricedRows.compactMap { r in
            guard let v = r.usdValue, v > 0,
                  let wid = r.id.split(separator: "#").last.map(String.init),
                  let w = byId[wid] else { return nil }
            var price: Decimal?
            if case .priced(let usd) = r.price { price = usd }
            return Row(token: r.token, wallet: w, amount: r.amount.double, value: v.double, price: price)
        }
    }

    /// One slice of the inner ring, and the outer-ring parts that make it up.
    struct Slice: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let value: Double
        /// A token slice draws its logo; wallets and networks a lettered disc.
        let token: Token?
        let parts: [Part]
        /// Token slices: units held, and the price of one. Nil otherwise.
        let amount: Double?
        var price: Decimal? = nil
        /// A network slice's mark: its own coin's logo (ETH on Ethereum, HYPE on HyperEVM).
        var mark: Token? = nil
        /// A wallet slice's emoji.
        var emoji: String? = nil
        /// A network slice's network — it wears that network's own logo.
        var network: Network? = nil
    }

    struct Part: Identifiable {
        var id: String { name }
        let name: String
        let colorHex: String
        let value: Double
        let token: Token?
        /// A token's wallet, split by the networks it holds the token on — the zoomed
        /// token's outer ring, drawn only when the token sits on more than one network.
        var networks: [(name: String, colorHex: String, value: Double)] = []
    }

    var slices: [Slice] {
        let rs = rows
        switch lens {
        case .token:
            return group(rs, key: { $0.token.symbol }) { sym, rows in
                let t = rows.max { $0.value < $1.value }!.token
                var ps = parts(rows, by: { $0.wallet.nickname }, color: { self.walletHex($0.wallet) })
                if Set(rows.map { Network.of($0.token).name }).count > 1 {
                    for i in ps.indices {
                        let mine = rows.filter { $0.wallet.nickname == ps[i].name }
                        ps[i].networks = Dictionary(grouping: mine, by: { Network.of($0.token).name })
                            .map { name, rs in (name, networkHex(Network.of(rs[0].token), rs[0].token), rs.sum) }
                            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
                    }
                }
                return Slice(id: "t:\(sym)", name: sym, colorHex: tokenHex(t), value: rows.sum,
                             token: t, parts: ps,
                             amount: rows.reduce(0) { $0 + $1.amount }, price: rows.first { $0.price != nil }?.price)
            }
        case .wallet:
            return group(rs, key: { $0.wallet.nickname }) { name, rows in
                Slice(id: "w:\(name)", name: name, colorHex: walletHex(rows[0].wallet), value: rows.sum, token: nil,
                      parts: parts(rows, by: { $0.token.symbol }, color: { self.tokenHex($0.token) }), amount: nil,
                      emoji: walletEmoji(name))
            }
        case .network:
            return group(rs, key: { Network.of($0.token).name }) { name, rows in
                let lead = rows.max { $0.value < $1.value }!
                // The network wears its own coin (`NetworkTint`) — ETH, BTC, SOL, ARB.
                let net = Network.of(lead.token)
                let held = self.rows.map(\.token)
                let mark = MainActor.assumeIsolated { NetworkTint.coin(for: net, among: held) }
                return Slice(id: "n:\(name)", name: name, colorHex: networkHex(net, lead.token),
                             value: rows.sum, token: nil,
                             parts: parts(rows, by: { $0.token.symbol }, color: { self.tokenHex($0.token) }), amount: nil,
                             mark: mark, network: net)
            }
        }
    }

    private func group(_ rows: [Row], key: (Row) -> String, make: (String, [Row]) -> Slice) -> [Slice] {
        Dictionary(grouping: rows, by: key).map { make($0.key, $0.value) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
    }

    private func parts(_ rows: [Row], by key: (Row) -> String, color: (Row) -> String) -> [Part] {
        Dictionary(grouping: rows, by: key).map { k, rs in
            let lead = rs.max { $0.value < $1.value }!
            return Part(name: k, colorHex: color(lead), value: rs.sum, token: lead.token)
        }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }
    }

    /// Each wallet's emoji, the way each Banking category has one. Picked from the pool by
    /// the name, and never the same as an earlier wallet's, so a wallet keeps its mark as
    /// others are added after it.
    func walletEmoji(_ nickname: String) -> String {
        if let picked = MainActor.assumeIsolated({ WalletEmojis.shared.chosen[nickname] }) { return picked }
        let pool = Self.walletEmojis
        var used = Set<String>()
        for w in store.wallets {
            var i = Self.stableHash(w.nickname) % pool.count
            var tries = 0
            while used.contains(pool[i]) && tries < pool.count { i = (i + 1) % pool.count; tries += 1 }
            used.insert(pool[i])
            if w.nickname == nickname { return pool[i] }
        }
        return pool[Self.stableHash(nickname) % pool.count]
    }

    static let walletEmojis = ["locked", "rocket", "crystal_ball", "seedling", "fox", "owl", "dragon", "cactus",
                               "mushroom", "octopus", "gem_stone", "money_bag", "crescent_moon", "sun", "light_bulb",
                               "wrapped_gift"]

    /// The same number for the same name on every launch (`hashValue` is seeded per run).
    private static func stableHash(_ s: String) -> Int {
        s.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fff_ffff }
    }

    /// A network's colour as its tab wears it, in Crypto 1 and in the token rows.
    func networkHex(_ n: Network, _ t: Token) -> String {
        let held = rows.map(\.token)
        return MainActor.assumeIsolated { NetworkTint.hex(n, among: held) }
    }

    func walletHex(_ w: Wallet) -> String {
        if let hex = store.walletColorHex(w.nickname) { return hex }
        let i = store.wallets.firstIndex { $0.id == w.id } ?? 0
        return PortfolioStore.walletColors[i % PortfolioStore.walletColors.count].hex
    }

    /// A token's colour is its logo's main colour, the way Crypto 1 colours its rows —
    /// the token's stored colour only until the logo has loaded.
    func tokenHex(_ t: Token) -> String {
        MainActor.assumeIsolated {
            guard let c = IconCache.shared.tintRGB(for: t) else { return t.colorHex }
            return String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
        }
    }

    var total: Double { rows.sum }

    func slice(_ id: String?) -> Slice? { id.flatMap { i in slices.first { $0.id == i } } }

    /// 24h change of one slice, weighted by what each of its holdings is worth now.
    func change24h(_ slice: Slice? = nil) -> Double? {
        let rs = slice.map { s in rows.filter { lensKey($0) == s.id } } ?? rows
        var now = 0.0, prior = 0.0
        for r in rs {
            guard let c = store.change24h[r.token.id] else { continue }
            now += r.value; prior += r.value / (1 + c / 100)
        }
        return prior > 0 ? (now - prior) / prior * 100 : nil
    }

    private func lensKey(_ r: Row) -> String {
        switch lens {
        case .token: return "t:\(r.token.symbol)"
        case .wallet: return "w:\(r.wallet.nickname)"
        case .network: return "n:\(Network.of(r.token).name)"
        }
    }

    // MARK: - Over time: the strip

    struct Bucket: Identifiable {
        var id: Date { date }
        let date: Date
        let label: String
        let total: Double
        let byWallet: [String: Double]
    }

    /// The archive's marks, or — with no wallets of the user's own yet — a made-up six
    /// months grown from today's demo holdings, so the strip has something to show. Held
    /// in memory only; nothing is written to the archive.
    var points: [HistoryStore.Point] {
        let real = store.historyPoints()
        // Still the demo — never adopted, or adopted by an edit (same two wallets) with no
        // archive of its own yet.
        let demo = !store.hasRealWallets
            || Set(store.wallets.map(\.nickname)) == Set(MockData.wallets.map(\.nickname))
        if real.count >= 2 || !demo { return real }
        return Self.demoHistory(now: Dictionary(rows.map { ($0.wallet.nickname, $0.value) }, uniquingKeysWith: +),
                                at: opened)
    }

    static func demoHistory(now: [String: Double], at today: Date) -> [HistoryStore.Point] {
        let day = 86_400.0
        return (0..<183).map { i in
            let back = Double(182 - i)
            var split: [String: Decimal] = [:]
            for (n, (name, v)) in now.sorted(by: { $0.key < $1.key }).enumerated() {
                // Deterministic: the same picture every launch, so renders compare.
                let drift = 1 - back / 182 * (0.18 + 0.06 * Double(n))
                let wobble = sin(back / 9 + Double(n * 2)) * 0.05 + sin(back / 23) * 0.04
                split[name] = Decimal(max(0, v * (drift + wobble)))
            }
            return HistoryStore.Point(date: today.addingTimeInterval(-back * day),
                                      total: split.values.reduce(0, +), breakdown: split)
        }
    }

    /// What `buckets` last worked out, and from what — the archive's stamp and the
    /// holdings the made-up history grows from.
    @ObservationIgnored private var bucketMemo: (key: String, value: [Bucket])?

    /// End-of-week marks when the archive is short, end-of-month once it is long. Read
    /// from disk only when the archive (or, for the made-up history, the holdings) moved.
    var buckets: [Bucket] {
        let key = "\(store.historyStamp?.timeIntervalSince1970 ?? 0)|\(store.hasRealWallets)|\(store.wallets.map(\.nickname))|\(total)"
        if let m = bucketMemo, m.key == key { return m.value }
        let value = makeBuckets()
        bucketMemo = (key, value)
        return value
    }

    /// Every mark, oldest first, then now: today's live worth, wallet by wallet — so the
    /// chart's right edge is what the ring and the lists say, not the last recorded day.
    private var pointsToNow: [HistoryStore.Point] {
        var ps = points.sorted { $0.date < $1.date }
        if !ps.isEmpty {
            let live = Dictionary(rows.map { ($0.wallet.nickname, Decimal($0.value)) }, uniquingKeysWith: +)
            ps.append(HistoryStore.Point(date: max(Date(), ps.last!.date), total: live.values.reduce(0, +), breakdown: live))
        }
        return ps
    }

    @ObservationIgnored private var sampleMemo: (key: String, value: [Bucket])?

    /// Every mark to now, for the value chart — the buckets' fine grain.
    var samples: [Bucket] {
        let key = "\(store.historyStamp?.timeIntervalSince1970 ?? 0)|\(store.hasRealWallets)|\(store.wallets.map(\.nickname))|\(total)"
        if let m = sampleMemo, m.key == key { return m.value }
        let value = pointsToNow.map {
            Bucket(date: $0.date, label: "", total: $0.total.double, byWallet: $0.breakdown.mapValues(\.double))
        }
        sampleMemo = (key, value)
        return value
    }

    /// The samples inside the chosen range: after the bucket before it, up to its last.
    var samplesInRange: [Bucket] {
        let b = buckets, s = samples
        guard !b.isEmpty, range.upperBound < b.count else { return s }
        let from = range.lowerBound > 0 ? b[range.lowerBound - 1].date : .distantPast
        let to = b[range.upperBound].date
        return s.filter { $0.date > from && $0.date <= to }
    }

    /// The bucket a date falls in — a drag on the chart becomes a range of buckets.
    func bucketIndex(for date: Date) -> Int {
        let b = buckets
        return b.firstIndex { $0.date >= date } ?? max(0, b.count - 1)
    }

    private func makeBuckets() -> [Bucket] {
        let ps = pointsToNow
        guard let first = ps.first, let last = ps.last else { return [] }
        let cal = Calendar.current
        let weekly = last.date.timeIntervalSince(first.date) < 200 * 86_400
        var out: [Bucket] = []
        var lastKey: DateComponents?
        for p in ps {
            let key = weekly ? cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: p.date)
                             : cal.dateComponents([.year, .month], from: p.date)
            let b = Bucket(date: p.date, label: label(p.date, weekly: weekly), total: p.total.double,
                           byWallet: p.breakdown.mapValues(\.double))
            if key == lastKey { out[out.count - 1] = b } else { out.append(b) }
            lastKey = key
        }
        return out
    }

    private func label(_ d: Date, weekly: Bool) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        let m = Fmt.monthNames[(c.month ?? 1) - 1]
        return weekly ? "\(m) \(c.day ?? 1)" : m
    }

    /// The wallet the strip narrows to: the zoomed one, the way Banking's strip narrows to
    /// a zoomed category. History is kept per wallet, so a zoomed token or network leaves
    /// the strip on the whole.
    var stripFocus: String? { lens == .wallet ? slice(drill)?.name : nil }

    /// One bar's figure: the focused wallet's, else the whole.
    func stripValue(_ b: Bucket) -> Double { stripFocus.map { b.byWallet[$0] ?? 0 } ?? b.total }

    /// "Weekly" while the archive is short, "Monthly" once it's long — as `buckets` cuts it.
    var cadence: String {
        let b = buckets
        guard let a = b.first?.date, let z = b.last?.date else { return "Weekly" }
        return z.timeIntervalSince(a) < 200 * 86_400 ? "Weekly" : "Monthly"
    }

    /// The wallets the strip colours, one band each, biggest at the range's end first.
    /// Zoomed into a wallet, just that one.
    var stripLead: [String] {
        if let f = stripFocus { return [f] }
        let b = buckets
        guard !b.isEmpty else { return [] }
        // Every wallet seen anywhere in the range, most valuable at its end first (one
        // that's since emptied still has its band back when it held something).
        let end = b[min(range.upperBound, b.count - 1)]
        var peak: [String: Double] = [:]
        for s in b[max(0, range.lowerBound)...min(range.upperBound, b.count - 1)] {
            for (k, v) in s.byWallet { peak[k] = max(peak[k] ?? 0, v) }
        }
        return peak.keys.sorted {
            let a = end.byWallet[$0] ?? 0, z = end.byWallet[$1] ?? 0
            if a != z { return a > z }
            if peak[$0] != peak[$1] { return peak[$0]! > peak[$1]! }
            return $0 < $1
        }
    }

    func applyPreset(_ p: Preset) {
        preset = p
        let b = buckets
        guard let last = b.last else { range = 0...0; return }
        if p == .yearToDate {
            let jan1 = Calendar.current.date(from: Calendar.current.dateComponents([.year], from: last.date)) ?? last.date
            range = (b.firstIndex { $0.date >= jan1 } ?? 0)...(b.count - 1)
            return
        }
        guard let days = p.days else { range = 0...(b.count - 1); return }
        let cutoff = last.date.addingTimeInterval(-Double(days) * 86_400)
        let lo = b.firstIndex { $0.date >= cutoff } ?? 0
        range = lo...(b.count - 1)
    }

    func select(_ a: Int, _ b: Int) {
        let r = min(a, b)...max(a, b)
        guard r != range else { return }
        preset = nil
        range = r
    }
}

private extension Array where Element == CryptoTwoModel.Row {
    var sum: Double { reduce(0) { $0 + $1.value } }
}
