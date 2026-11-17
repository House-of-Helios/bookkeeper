import SwiftUI
import BookkeeperCore

/// The Transactions screen's state — search text, the kind filter, the line under the
/// edit drawer. Owned by `RootView` so the Spending screen's review pill can open this
/// screen already filtered to To review.
@Observable
final class TransactionsModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", spend = "Spending", income = "Income", transfer = "Transfers", review = "To review"
        var id: String { rawValue }
    }

    var filter: Filter = .all
    var query = ""
    /// The line under the edit drawer.
    var editing: String?
    /// `--snapshot` only: open the drawer with "All like this" already chosen.
    var editStartsAllLikeThis = false
    /// The drawer was opened from its history chart: it starts on the form.
    var editOpensForm = false

    /// One month of the list: its lines, newest first, and what they spent.
    struct MonthGroup: Identifiable {
        var month: Month
        var lines: [BankTransaction]
        var spent: Double
        var id: Month { month }
    }

    /// The filtered lines, newest first.
    func lines(_ store: SpendingStore) -> [BankTransaction] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.transactions.reversed().filter { t in
            switch filter {
            case .all: break
            case .spend: if t.effectiveKind != .spend { return false }
            case .income: if t.effectiveKind != .income { return false }
            case .transfer: if t.effectiveKind != .transfer { return false }
            case .review: if !t.needsReview { return false }
            }
            guard !q.isEmpty else { return true }
            return t.displayName.lowercased().contains(q)
                || t.rawDescription.lowercased().contains(q)
                || String(format: "%.2f", abs(t.amount.double)).contains(q)
        }
    }

    /// The lines cut into months; each month's figure is what the lines shown spent.
    static func months(_ lines: [BankTransaction]) -> [MonthGroup] {
        var out: [MonthGroup] = []
        for t in lines {
            let m = t.date.yearMonth
            if out.last?.month != m { out.append(MonthGroup(month: m, lines: [], spent: 0)) }
            out[out.count - 1].lines.append(t)
            out[out.count - 1].spent += t.spendAmount.double
        }
        return out
    }

    /// The groups cut to their first `n` lines in all — totals untouched.
    static func firstLines(_ groups: [MonthGroup], _ n: Int) -> [MonthGroup] {
        var left = n, out: [MonthGroup] = []
        for var g in groups where left > 0 {
            g.lines = Array(g.lines.prefix(left))
            left -= g.lines.count
            out.append(g)
        }
        return out
    }
}

extension Fmt {
    static let monthLongNames = ["January", "February", "March", "April", "May", "June", "July",
                                 "August", "September", "October", "November", "December"]
    /// `October 2026`.
    static func monthLong(_ m: Month) -> String { "\(monthLongNames[m.month - 1]) \(m.year)" }
    /// Money out as `−$8.77`, money in as `+$8.77`.
    static func signedCents(_ v: Double) -> String { (v < 0 ? "−" : "+") + usdCents(v) }
}
