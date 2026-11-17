import Foundation

/// The archive: what the portfolio was worth on a given day, and how that total was
/// split across wallets.
///
/// One line per mark in `history.csv`, tab-separated:
///
///     unixSeconds <TAB> total [<TAB> {"Cold Vault":"54000.12", …}]
///
/// The third field is optional and carries the per-wallet breakdown as JSON. Lines
/// written before the breakdown existed have two fields and still load — they simply
/// have nothing to stack, which the chart draws as a single unattributed band rather
/// than dropping the day. JSON rather than more tab-separated pairs because a wallet
/// nickname is user-typed: it can hold commas and colons, and only JSON escapes them
/// without inventing a second quoting rule. It cannot hold a tab (the wallet file is
/// tab-delimited too), so the outer split stays safe.
public final class HistoryStore: Sendable {
    private let fileURL: URL
    /// Where this store writes. Exposed so anything else that caches alongside it lands
    /// in the same place — one injection point isolates the whole store, instead of each
    /// cache needing to be remembered separately.
    public let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? DataRoot.url
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        fileURL = base.appendingPathComponent("history.csv")
    }

    public struct Point: Sendable, Equatable, Codable {
        public let date: Date
        public let total: Decimal
        /// Value per wallet nickname. Empty for a mark recorded before breakdowns existed.
        public let breakdown: [String: Decimal]

        public init(date: Date, total: Decimal, breakdown: [String: Decimal] = [:]) {
            self.date = date
            self.total = total
            self.breakdown = breakdown
        }
    }

    // MARK: - Reading

    /// When the archive last changed — a screen keeps what it read until this moves,
    /// instead of reading the file on every redraw. Nil while there is no file.
    public var stamp: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    public func load() -> [Point] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .compactMap(Self.parse)
            .sorted { $0.date < $1.date }
    }

    static func parse(_ line: Substring) -> Point? {
        let p = line.components(separatedBy: "\t")
        guard p.count >= 2, let ts = Double(p[0]), let v = decimal(p[1]) else { return nil }
        var breakdown: [String: Decimal] = [:]
        if p.count >= 3, !p[2].isEmpty,
           let data = p[2].data(using: .utf8),
           let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            for (name, amount) in raw {
                if let d = decimal(amount) { breakdown[name] = d }
            }
        }
        return Point(date: Date(timeIntervalSince1970: ts), total: v, breakdown: breakdown)
    }

    private static func decimal(_ s: String) -> Decimal? {
        Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func string(_ d: Decimal) -> String {
        NSDecimalNumber(decimal: d).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - When to record

    /// How often the app records a mark on its own. Manual: only the Archive button.
    public enum Cadence: String, CaseIterable, Sendable {
        case monthly, twiceMonthly, manual
    }

    /// Whether a mark is due: none yet in this month (monthly), or in this half of it —
    /// the 1st to the 15th, the 16th on (twice a month). Never for manual.
    public static func isDue(_ cadence: Cadence, marks: [Date], now: Date = Date(),
                             calendar: Calendar = .current) -> Bool {
        func period(_ d: Date) -> [Int] {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            let half = cadence == .twiceMonthly ? ((c.day ?? 1) <= 15 ? 0 : 1) : 0
            return [c.year ?? 0, c.month ?? 0, half]
        }
        guard cadence != .manual else { return false }
        let current = period(now)
        return !marks.contains { period($0) == current }
    }

    // MARK: - Writing

    /// Mark today's value, replacing any mark already made today.
    ///
    /// One mark per day, not one per press: the archive is a diary of days, and pressing
    /// the button twice in an afternoon means "no, THIS is today's figure" rather than
    /// "here is a second today". The replaced line is dropped, so the file stays one row
    /// per day however often the button is used.
    @discardableResult
    public func archive(total: Decimal, breakdown: [String: Decimal] = [:],
                        on date: Date = Date(),
                        calendar: Calendar = .current) -> Bool {
        guard total > 0 else { return false }
        let kept = load().filter { !calendar.isDate($0.date, inSameDayAs: date) }
        write(kept + [Point(date: date, total: total, breakdown: breakdown)])
        return true
    }

    /// Whether today already carries a mark — the button says "Archived today" rather
    /// than inviting a press that would only overwrite what is already right.
    public func hasMark(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        load().contains { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// Remove the mark for a day. The archive is hand-made, so a wrong entry has to be
    /// removable — otherwise one bad afternoon is in the chart forever.
    public func removeMark(on date: Date, calendar: Calendar = .current) {
        write(load().filter { !calendar.isDate($0.date, inSameDayAs: date) })
    }

    /// Carry a wallet's rename back through every mark.
    ///
    /// The breakdown is keyed by nickname, so renaming a wallet without this left the old
    /// name in the archive as a column of its own and started a second one under the new
    /// name — one wallet, split in two at the day it was renamed. Totals don't move: the
    /// money is the same, only its label changes. If a mark somehow already holds both
    /// names, the two are added rather than one overwriting the other.
    public func renameWallet(from old: String, to new: String) {
        guard old != new else { return }
        let points = load()
        guard points.contains(where: { $0.breakdown[old] != nil }) else { return }
        write(points.map { p in
            guard let value = p.breakdown[old] else { return p }
            var b = p.breakdown
            b[old] = nil
            b[new, default: 0] += value
            return Point(date: p.date, total: p.total, breakdown: b)
        })
    }

    /// Strike a wallet out of the archive entirely: its column goes, and so do its
    /// dollars from each day's total.
    ///
    /// For a wallet that should never have been counted — a duplicate left behind by a
    /// rename, a test wallet. Subtracting is the point: a column removed but still summed
    /// into the total would leave the chart standing on money nothing accounts for. A
    /// mark left with nothing in it is dropped rather than kept as a $0 day.
    public func removeWallet(_ name: String) {
        let points = load()
        guard points.contains(where: { $0.breakdown[name] != nil }) else { return }
        write(points.compactMap { p in
            guard let value = p.breakdown[name] else { return p }
            var b = p.breakdown
            b[name] = nil
            let total = p.total - value
            guard total > 0 else { return nil }
            return Point(date: p.date, total: total, breakdown: b)
        })
    }

    private func write(_ points: [Point]) {
        let body = points
            .sorted { $0.date < $1.date }
            .map { p -> String in
                var line = "\(p.date.timeIntervalSince1970)\t\(Self.string(p.total))"
                if !p.breakdown.isEmpty {
                    let raw = p.breakdown.mapValues(Self.string)
                    if let data = try? JSONEncoder().encode(raw),
                       let json = String(data: data, encoding: .utf8) {
                        line += "\t" + json
                    }
                }
                return line
            }
            .joined(separator: "\n")
        try? (body + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
