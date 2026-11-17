import SwiftUI
import BookkeeperCore

/// The Spending screen's own state — which months, which view of the ring, which category
/// is in focus — and the figures every part of the screen reads, worked out from the
/// ledger in one place so the strip, the rings and the focus panel always agree.
///
/// Months are held as indices into `months` (the ledger's first to last month, gaps
/// included), the way the mockup's strip thinks: a drag is two bar indices.
@Observable
final class SpendingScreenModel {
    let store: SpendingStore

    var range: ClosedRange<Int> = 0...0
    var preset: Preset? = .sixMonths
    /// What the ring shows: everyday spend, spend with rent & bills, or money in.
    var lens: Lens = .everyday
    /// "+ rent & bills": fixed costs back on the ring.
    var withBills: Bool { lens == .all }
    var income: Bool { lens == .income }
    /// The zoomed category, if any.
    var drill: String?
    /// The category the focus panel shows when nothing is zoomed.
    var focus: String = "cafe"
    /// The category under the editor drawer.
    var editing: String?
    /// The transaction under the line-edit drawer (a "Latest · tap to edit" row).
    var editingLine: String?
    /// The line drawer was opened from a merchant row: it starts on "All like this".
    var editingMerchant = false
    /// The line drawer was opened from its history chart: it starts on the form.
    var editingOpensForm = false
    /// A "See all" window open over the screen: every merchant, or every line, of one category.
    var list: FocusList?

    init(store: SpendingStore) {
        self.store = store
        applyPreset(.sixMonths)
    }

    /// In the order the switch under the ring shows them.
    enum Lens: String, CaseIterable, Hashable {
        case income, everyday, all
    }

    enum Preset: String, CaseIterable, Identifiable {
        case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", yearToDate = "YTD", oneYear = "1Y", all = "All"
        var id: String { rawValue }
    }

    // MARK: - Months + range

    /// Every month from the first to the last in the ledger.
    var months: [Month] { store.monthlyTotals(everyday: false).map(\.month) }

    var rangeMonths: ClosedRange<Month>? {
        let m = months
        guard !m.isEmpty else { return nil }
        let r = clamped(range, count: m.count)
        return m[r.lowerBound]...m[r.upperBound]
    }

    /// The same number of months just before the range — nil when the ledger doesn't
    /// reach that far back, so no "vs before" is claimed on half a period.
    var previousMonths: ClosedRange<Month>? {
        let m = months
        let r = clamped(range, count: m.count)
        let length = r.count
        guard r.lowerBound - length >= 0 else { return nil }
        return m[r.lowerBound - length]...m[r.lowerBound - 1]
    }

    func applyPreset(_ p: Preset) {
        preset = p
        let n = months.count
        guard n > 0 else { range = 0...0; return }
        let last = n - 1
        let span: Int
        switch p {
        case .oneMonth: span = 1
        case .threeMonths: span = 3
        case .sixMonths: span = 6
        case .oneYear: span = 12
        case .all: span = n
        case .yearToDate: span = months[last].month
        }
        range = max(0, last - span + 1)...last
        keepDrill()
    }

    /// A zoomed category with nothing in the new range or ledger zooms back out, rather
    /// than leave an empty ring.
    private func keepDrill() {
        if let d = drill, !ringCategories.contains(where: { $0.category.id == d }) { drill = nil }
    }

    /// A drag on the strip.
    func select(_ a: Int, _ b: Int) {
        let r = min(a, b)...max(a, b)
        guard r != range else { return }
        preset = nil
        range = r
        keepDrill()
    }

    /// After an import the ledger may have grown: keep the preset's meaning, or the
    /// hand-picked range if it still fits.
    func ledgerChanged() {
        if let p = preset { applyPreset(p) } else { range = clamped(range, count: months.count); keepDrill() }
    }

    private func clamped(_ r: ClosedRange<Int>, count: Int) -> ClosedRange<Int> {
        guard count > 0 else { return 0...0 }
        let lo = min(max(0, r.lowerBound), count - 1), hi = min(max(lo, r.upperBound), count - 1)
        return lo...hi
    }

    // MARK: - Figures

    var everyday: Bool { lens == .everyday }

    /// Categories on the ring over the range, in ring order, positive totals only. On
    /// Income, the kinds of money in.
    var ringCategories: [CategorySpend] {
        guard let r = rangeMonths else { return [] }
        if income {
            return store.income(byCategoryIn: r)
                .map { CategorySpend(category: $0.category, total: $0.total, count: $0.count) }
                .filter { $0.total > 0 }
        }
        return store.spend(byCategoryIn: r, everyday: everyday).filter { $0.total > 0 }
    }

    func category(_ id: String) -> SpendingCategory? { store.categories.category(id) }

    func merchants(_ categoryId: String) -> [MerchantSpend] {
        (income ? store.payers(in: categoryId, range: rangeMonths) : store.merchants(in: categoryId, range: rangeMonths))
            .filter { $0.total > 0 }
    }

    /// The range's spend (or income), or one category's — counted as the ring draws it:
    /// only what nets above zero (a category, or one category's merchants), so the centre,
    /// the panel and "vs before" all say the same number.
    func total(_ categoryId: String? = nil, in months: ClosedRange<Month>?) -> Double {
        guard let months else { return 0 }
        if let id = categoryId {
            let ms = income ? store.payers(in: id, range: months) : store.merchants(in: id, range: months)
            return ms.filter { $0.total > 0 }.reduce(0) { $0 + $1.total.double }
        }
        let rows = income ? store.income(byCategoryIn: months).map(\.total)
            : store.spend(byCategoryIn: months, everyday: everyday).map(\.total)
        return rows.filter { $0 > 0 }.reduce(0) { $0 + $1.double }
    }

    /// Percent change against the period before, if there is one — day for day: when the
    /// ledger stops on Oct 12, October so far is set against Sep 1–12, not all September.
    func delta(_ categoryId: String? = nil) -> Double? {
        guard let r = rangeMonths, previousMonths != nil, let last = store.transactions.last?.date else { return nil }
        let k = range.count
        let end = min(last, Self.day(r.upperBound, 31))
        let before = windowTotal(categoryId, from: Self.day(Self.back(r.lowerBound, k), 1),
                                 through: Self.day(Self.back(r.upperBound, k), end.day))
        guard before > 0 else { return nil }
        let now = windowTotal(categoryId, from: Self.day(r.lowerBound, 1), through: end)
        return (now - before) / before * 100
    }

    /// As `total`: only what nets above zero, fixed costs aside on Everyday.
    private func windowTotal(_ categoryId: String?, from: Day, through: Day) -> Double {
        let w = store.totals(from: from, through: through, income: income)
        func net(_ ms: [String: Decimal]) -> [Decimal] { ms.values.filter { $0 > 0 } }
        if let id = categoryId { return net(w[id] ?? [:]).reduce(0) { $0 + $1.double } }
        return w.filter { id, _ in !(everyday && (category(id)?.fixed ?? false)) }
            .map { $0.value.values.reduce(0, +) }.filter { $0 > 0 }.reduce(0) { $0 + $1.double }
    }

    /// That day of the month, or the month's last if it has fewer.
    private static func day(_ m: Month, _ d: Int) -> Day {
        var d = d
        while d > 28, Day(year: m.year, month: m.month, day: d) == nil { d -= 1 }
        return Day(m.year, m.month, d)
    }

    private static func back(_ m: Month, _ k: Int) -> Month {
        (0..<k).reduce(m) { m, _ in m.previous }
    }

    struct StripPart: Hashable {
        var name: String
        var icon: String
        /// Nil = the grey rest.
        var colorHex: String?
        var value: Double
    }

    /// Each month's stacked parts — that month's own three biggest categories in colour,
    /// biggest at the bottom, the grey rest on top — so a bar reads the same whichever
    /// range is chosen; and, for the hover card, every category that month, most first.
    /// Zoomed into a category, that category alone.
    var stripMonths: [(month: Month, parts: [StripPart], total: Double, detail: [StripPart])] {
        let rows = income ? store.monthlyIncome(category: drill)
            : store.monthlyTotals(category: drill, everyday: drill == nil ? everyday : false)
        return rows.map { m in
            let detail = m.byCategory.compactMap { id, v -> StripPart? in
                guard let c = category(id), v > 0 else { return nil }
                return StripPart(name: c.name, icon: c.icon, colorHex: c.colorHex, value: v.double)
            }.sorted { $0.value > $1.value }
            var parts: [StripPart]
            if let d = drill {
                let c = category(d)
                parts = [StripPart(name: c?.name ?? "", icon: c?.icon ?? "package", colorHex: c?.colorHex,
                                   value: max(0, (m.byCategory[d] ?? 0).double))]
            } else {
                parts = Array(detail.prefix(3))
                let all = m.byCategory.values.reduce(0) { $0 + $1.double }
                // Not "Other": that is a category of its own, and may be one of the three.
                parts.append(StripPart(name: "The rest", icon: "package", colorHex: nil,
                                       value: max(0, all - parts.reduce(0) { $0 + $1.value })))
            }
            return (m.month, parts, parts.reduce(0) { $0 + $1.value }, detail)
        }
    }

    /// Rent & bills the Everyday view set aside.
    var setAside: Double { store.fixedSpend(in: rangeMonths).double }

    /// Money that left as a card payment or a move between accounts — never spending.
    var transfersLeftOut: Double {
        guard let r = rangeMonths else { return 0 }
        return store.transactions(TransactionFilter(range: r, kind: .transfer))
            .filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount.double }
    }

    /// Newest first.
    func latestLines(_ categoryId: String, limit: Int = 5) -> [BankTransaction] {
        guard let r = rangeMonths else { return [] }
        if income { return Array(store.incomeLines(in: categoryId, range: r).reversed().prefix(limit)) }
        return Array(store.spendLines(in: categoryId, range: r).reversed().prefix(limit))
    }

    func lineCount(_ categoryId: String) -> Int {
        ringCategories.first { $0.category.id == categoryId }?.count
            ?? store.spend(byCategoryIn: rangeMonths, everyday: false).first { $0.category.id == categoryId }?.count ?? 0
    }

    /// Every line on the ring over the range, newest first — the overview's Latest.
    func latestAll(limit: Int = 5) -> [BankTransaction] {
        guard let r = rangeMonths else { return [] }
        let rows = store.transactions(TransactionFilter(range: r, kind: income ? .income : .spend))
            .filter { everyday ? !(category($0.effectiveCategoryId)?.fixed ?? false) : true }
        return Array(rows.reversed().prefix(limit))
    }

    /// A merchant row → its newest line in the range, the one its drawer opens on.
    func newestLine(merchant: String, in categoryId: String) -> BankTransaction? {
        latestLines(categoryId, limit: .max).first { $0.displayName == merchant }
    }

    /// As many as Latest's "See all" lists.
    var lineCountAll: Int { latestAll(limit: .max).count }

    /// A rise is good news on Income and bad news on spending.
    func deltaIsGood(_ d: Double) -> Bool { income ? d > 0 : d < 0 }

    /// The category the focus panel shows: the zoomed one, else the chosen focus — or the
    /// biggest on the ring if the focus has fallen off it (rent in Everyday).
    var focusId: String {
        if let d = drill { return d }
        if ringCategories.contains(where: { $0.category.id == focus }) { return focus }
        return ringCategories.max { $0.total < $1.total }?.category.id ?? focus
    }
}

extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// The Spending screens' number and date formats.
enum Fmt {
    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal
        f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        return f
    }()
    private static let cents: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal
        f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f
    }()

    /// `$1,021` — exact whole dollars, never `$1.0k`.
    static func usd(_ v: Double) -> String { "$" + (whole.string(from: NSNumber(value: abs(v).rounded())) ?? "0") }
    static func usdCents(_ v: Double) -> String { "$" + (cents.string(from: NSNumber(value: abs(v))) ?? "0.00") }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static func monthShort(_ m: Month) -> String { monthNames[m.month - 1] }
    static func monthYear(_ m: Month) -> String { "\(monthShort(m)) \(m.year)" }
    static func dayShort(_ d: Day) -> String { "\(monthNames[d.month - 1]) \(d.day)" }

    static func percent(_ v: Double, digits: Int = 0) -> String { String(format: "%.\(digits)f%%", v) }
}

/// What a "See all" window lists.
enum FocusList: Hashable, Identifiable {
    case merchants(String), lines(String), everything, categories
    var id: Self { self }
    var categoryId: String? {
        switch self {
        case .merchants(let c), .lines(let c): return c
        case .everything, .categories: return nil
        }
    }
}
