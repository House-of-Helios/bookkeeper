import Foundation

/// A family of spend categories drawn as one set of nested rings on the Budget tab:
/// Groceries, Eating out and Cafés are all Food. At most four per family, so the rings
/// stay fat. Built in, like the categories themselves — ids never change.
public struct BudgetGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let categoryIds: [String]

    public static let all: [BudgetGroup] = [
        BudgetGroup(id: "food", name: "Food", categoryIds: ["groc", "eat", "cafe"]),
        BudgetGroup(id: "home", name: "Home", categoryIds: ["home", "util", "house"]),
        BudgetGroup(id: "bills", name: "Bills", categoryIds: ["ins", "tax", "debt", "fee"]),
        BudgetGroup(id: "around", name: "Getting around", categoryIds: ["move", "trip"]),
        BudgetGroup(id: "self", name: "Looking after you", categoryIds: ["heal", "fit", "care", "wear"]),
        BudgetGroup(id: "fun", name: "Fun", categoryIds: ["fun", "subs", "shop"]),
        BudgetGroup(id: "others", name: "Others", categoryIds: ["gift", "pet", "edu"]),
        BudgetGroup(id: "rest", name: "The rest", categoryIds: ["cash", CategoryBook.fallbackId]),
    ]

    public static func of(_ categoryId: String) -> BudgetGroup? { all.first { $0.categoryIds.contains(categoryId) } }
}

/// `spending/budgets.json`: one standing monthly amount per spend category, and the month
/// each was first set, from which its leftovers start to carry. A category with no amount
/// shows a guess from its recent months instead, said as a guess, and carries nothing.
public struct BudgetBook: Codable, Hashable, Sendable {
    public var plans: [String: Decimal]
    public var since: [String: Month]

    public init(plans: [String: Decimal] = [:], since: [String: Month] = [:]) {
        self.plans = plans; self.since = since
    }

    // `since` arrived after the first budgets.json was written: absent reads as empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = try c.decodeIfPresent([String: Decimal].self, forKey: .plans) ?? [:]
        since = try c.decodeIfPresent([String: Month].self, forKey: .since) ?? [:]
    }
}

/// One category's month: what was planned, what came over from last month, what went.
public struct BudgetLine: Equatable, Sendable {
    public var category: SpendingCategory
    public var plan: Decimal
    /// True when `plan` is the recent-months guess, not an amount set by hand.
    public var guessed: Bool
    /// Last month's leftover, carried in. Only ever positive: an overspend doesn't follow
    /// the category, it comes out of the next month's unplanned money (Actual's rule).
    public var carried: Decimal
    public var spent: Decimal
    /// What there was to spend this month.
    public var available: Decimal { plan + carried }
    public var left: Decimal { available - spent }
}

public struct BudgetGroupLine: Equatable, Sendable {
    public var group: BudgetGroup
    /// Outermost ring first.
    public var lines: [BudgetLine]
    public var available: Decimal { lines.reduce(0) { $0 + $1.available } }
    public var spent: Decimal { lines.reduce(0) { $0 + $1.spent } }
    public var left: Decimal { available - spent }
}

public struct BudgetMonth: Equatable, Sendable {
    public var month: Month
    public var income: Decimal
    public var groups: [BudgetGroupLine]
    /// What planned categories overspent last month, as a positive amount: it comes out of
    /// this month's unplanned money.
    public var overspentBefore: Decimal
    public var spent: Decimal { groups.reduce(0) { $0 + $1.spent } }
    public var plan: Decimal { groups.flatMap(\.lines).reduce(0) { $0 + $1.plan } }
    /// Income left after spending; negative when the month spent more than came in.
    public var kept: Decimal { income - spent }
    /// Income no plan has claimed yet — Actual's "To budget", one month at a time.
    public var unplanned: Decimal { income - plan - overspentBefore }
}

extension SpendingStore {
    /// The months with any spending, oldest first.
    public var budgetMonths: [Month] { monthlyTotals(everyday: false).filter { $0.total != 0 }.map(\.month) }

    /// Set (or, with nil or zero, clear back to the guess) a category's monthly amount.
    /// The first time a category gets one, `from` becomes the month its leftovers carry from.
    public func setPlan(_ categoryId: String, _ amount: Decimal?, from month: Month? = nil) {
        var book = budget
        if let amount, amount > 0 {
            book.plans[categoryId] = amount
            if book.since[categoryId] == nil { book.since[categoryId] = month ?? budgetMonths.last }
        } else {
            book.plans[categoryId] = nil
            book.since[categoryId] = nil
        }
        setBudget(book)
    }

    /// Hand-set every guess showing in `month` as that category's plan.
    public func keepGuesses(in month: Month) {
        var book = budget
        for line in budget(for: month).groups.flatMap(\.lines) where line.guessed && line.plan > 0 {
            book.plans[line.category.id] = line.plan
            book.since[line.category.id] = month
        }
        setBudget(book)
    }

    /// The average of up to three months with spending before `month`, rounded up to $10.
    /// Nil with no earlier month.
    public func guessedPlan(_ categoryId: String, before month: Month) -> Decimal? {
        averageSpend(categoryId, months: 3, before: month).map { avg in
            Decimal((NSDecimalNumber(decimal: avg).doubleValue / 10).rounded(.up) * 10)
        }
    }

    /// What one category spent in one month.
    public func spent(_ categoryId: String, in month: Month) -> Decimal {
        spend(byCategoryIn: month...month, everyday: false).first { $0.category.id == categoryId }?.total ?? 0
    }

    /// The plain average over up to `months` months with spending before `month`; nil with
    /// no earlier month or no spending in them. The editor's "3 / 6 / 12-month average".
    public func averageSpend(_ categoryId: String, months: Int, before month: Month) -> Decimal? {
        let earlier = budgetMonths.filter { $0 < month }.suffix(months)
        guard let first = earlier.first, let last = earlier.last else { return nil }
        let total = spend(byCategoryIn: first...last, everyday: false)
            .first { $0.category.id == categoryId }?.total ?? 0
        return total > 0 ? total / Decimal(earlier.count) : nil
    }

    /// Each hand-planned category's leftover carried into `month`, and what planned
    /// categories overspent in the month before. Walked month by month from each plan's
    /// `since`: a positive leftover carries on, an overspend stops at the month's end.
    func carry(into month: Month) -> (carried: [String: Decimal], overspent: Decimal) {
        var carried: [String: Decimal] = [:]
        var overspent: Decimal = 0
        guard let start = budget.since.values.min(), start < month else { return ([:], 0) }
        var m = start
        while m < month {
            overspent = 0
            for (id, plan) in budget.plans {
                guard let since = budget.since[id], since <= m else { continue }
                let left = plan + (carried[id] ?? 0) - spent(id, in: m)
                carried[id] = max(left, 0)
                if left < 0 { overspent -= left }
            }
            m = m.next
        }
        return (carried, overspent)
    }

    /// The Budget tab's whole month. A category appears when it has an amount set, a
    /// guess, money carried in, or spending this month; a family with none is left out.
    public func budget(for month: Month) -> BudgetMonth {
        let spent = Dictionary(spend(byCategoryIn: month...month, everyday: false).map { ($0.category.id, $0.total) },
                               uniquingKeysWith: +)
        let income = self.income(byCategoryIn: month...month).reduce(Decimal(0)) { $0 + $1.total }
        let (carried, overspent) = carry(into: month)
        let groups: [BudgetGroupLine] = BudgetGroup.all.compactMap { g in
            let lines: [BudgetLine] = g.categoryIds.compactMap { id in
                guard let c = categories.category(id) else { return nil }
                let set = budget.plans[id]
                let guess = set == nil ? guessedPlan(id, before: month) : nil
                let s = spent[id] ?? 0, carry = carried[id] ?? 0
                guard set != nil || guess != nil || s != 0 || carry != 0 else { return nil }
                return BudgetLine(category: c, plan: set ?? guess ?? 0, guessed: set == nil, carried: carry, spent: s)
            }
            return lines.isEmpty ? nil : BudgetGroupLine(group: g, lines: lines)
        }
        return BudgetMonth(month: month, income: income, groups: groups, overspentBefore: overspent)
    }
}
