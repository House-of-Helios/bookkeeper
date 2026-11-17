import Foundation

/// A charge that comes every month: the same merchant, about the same day, about the same
/// amount. Found from the ledger alone — nothing to set up.
public struct RecurringCharge: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var categoryId: String
    /// The newest charge's amount, positive.
    public var amount: Decimal
    /// The day of the month it lands on (the newest charge's).
    public var day: Int
    public var last: Day
    /// When the next one should land, clamped to the month's length.
    public var next: Day
    /// Months in a row it has come, newest back.
    public var months: Int
}

extension SpendingStore {
    /// Monthly charges, biggest first. Taken from Actual Budget's schedule finder, which
    /// asks for three occurrences, the date within a couple of days and the amount within
    /// 7.5% of the newest. Here: three calendar months in a row, ±3 days (months differ in
    /// length), 7.5%, and the newest no more than 45 days before the ledger's last line —
    /// a subscription that stopped isn't one any more.
    public func recurring() -> [RecurringCharge] {
        cachedRecurring {
            let spends = transactions.filter { $0.effectiveKind == .spend && $0.amount < 0 }
            guard let end = transactions.last?.date else { return [] }
            let byName = Dictionary(grouping: spends, by: \.displayName)
            var found: [RecurringCharge] = []
            for (name, lines) in byName where lines.count >= 3 {
                let sorted = lines.sorted { $0.date > $1.date }
                let newest = sorted[0]
                guard end.days(since: newest.date) <= 45 else { continue }
                let base = -newest.amount
                let tolerance = max(Decimal(1), (base * Decimal(string: "0.075")!).rounded())
                var months = 1
                var m = newest.date.yearMonth.previous
                while sorted.contains(where: { t in
                    t.date.yearMonth == m && abs(-t.amount - base) <= tolerance
                        && abs(t.date.day - Self.clampedDay(newest.date.day, in: m)) <= 3
                }) {
                    months += 1
                    m = m.previous
                }
                guard months >= 3 else { continue }
                let nm = newest.date.yearMonth.next
                let next = Day(nm.year, nm.month, Self.clampedDay(newest.date.day, in: nm))
                found.append(RecurringCharge(name: name, categoryId: newest.effectiveCategoryId, amount: base,
                                             day: newest.date.day, last: newest.date, next: next, months: months))
            }
            return found.sorted { ($0.amount, $1.name) > ($1.amount, $0.name) }
        }
    }

    /// `day` in month `m`, or the month's last day when `m` is shorter.
    static func clampedDay(_ day: Int, in m: Month) -> Int {
        var d = min(day, 31)
        while Day(year: m.year, month: m.month, day: d) == nil { d -= 1 }
        return d
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var v = self, r = Decimal()
        NSDecimalRound(&r, &v, 0, .plain)
        return r
    }
}
