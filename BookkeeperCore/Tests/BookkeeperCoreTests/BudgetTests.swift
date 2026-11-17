import XCTest
@testable import BookkeeperCore

/// The Budget tab's month: families, guessed vs set amounts, what was kept.
final class BudgetTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-budget-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func loaded() throws -> SpendingStore {
        let s = SpendingStore(directory: dir)
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C")
        _ = try s.importCSV(fileURL: BankFixtures.url("chase_card"), accountId: card.id)
        let checking = s.addAccount(name: "Checking", colorHex: "#7B90D2")
        _ = try s.importCSV(fileURL: BankFixtures.url("chase_checking"), accountId: checking.id)
        return s
    }

    func test_everyCategoryIsInAtMostOneFamilyOfAtMostFour() {
        let ids = BudgetGroup.all.flatMap(\.categoryIds)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(BudgetGroup.all.allSatisfy { $0.categoryIds.count <= 4 })
        let spend = Set(CategoryBook.defaults.categories.map(\.id))
        XCTAssertEqual(Set(ids), spend, "every spend category has a family, and only those")
    }

    func test_aMonthAddsUpAndKeptIsWhatIncomeLeft() throws {
        let s = try loaded()
        let month = try XCTUnwrap(s.budgetMonths.last)
        let b = s.budget(for: month)
        let spendTotal = s.spend(byCategoryIn: month...month, everyday: false).reduce(Decimal(0)) { $0 + $1.total }
        XCTAssertEqual(b.spent, spendTotal)
        XCTAssertEqual(b.kept, b.income - b.spent)
        XCTAssertFalse(b.groups.isEmpty)
        let food = try XCTUnwrap(b.groups.first { $0.group.id == "food" })
        XCTAssertEqual(food.lines.map(\.category.id).first, "groc", "rings keep the family's order")
    }

    func test_anAmountSetByHandReplacesTheGuessAndSurvivesReopening() throws {
        let s = try loaded()
        let month = try XCTUnwrap(s.budgetMonths.last)
        let guess = try XCTUnwrap(s.budget(for: month).groups.flatMap(\.lines).first { $0.category.id == "groc" })
        XCTAssertTrue(guess.guessed)
        XCTAssertEqual(guess.plan, s.guessedPlan("groc", before: month))

        s.setPlan("groc", 520)
        let reopened = SpendingStore(directory: dir).budget(for: month).groups.flatMap(\.lines)
        let set = try XCTUnwrap(reopened.first { $0.category.id == "groc" })
        XCTAssertFalse(set.guessed)
        XCTAssertEqual(set.plan, 520)

        s.setPlan("groc", nil)
        XCTAssertTrue(try XCTUnwrap(s.budget(for: month).groups.flatMap(\.lines).first { $0.category.id == "groc" }).guessed)
    }

    func test_theGuessIsTheRecentAverageRoundedUpToTen() throws {
        let s = try loaded()
        let month = try XCTUnwrap(s.budgetMonths.last)
        let earlier = s.budgetMonths.filter { $0 < month }.suffix(3)
        let total = s.spend(byCategoryIn: earlier.first!...earlier.last!, everyday: false)
            .first { $0.category.id == "groc" }!.total
        let avg = NSDecimalNumber(decimal: total / Decimal(earlier.count)).doubleValue
        let guess = try XCTUnwrap(s.guessedPlan("groc", before: month))
        XCTAssertGreaterThanOrEqual(NSDecimalNumber(decimal: guess).doubleValue, avg)
        XCTAssertLessThan(NSDecimalNumber(decimal: guess).doubleValue, avg + 10)
        XCTAssertNil(s.guessedPlan("groc", before: s.budgetMonths.first!))
    }

    func test_aPlannedCategoryCarriesItsLeftoverAndAnOverspendComesOutOfUnplanned() throws {
        let s = try loaded()
        let months = s.budgetMonths
        XCTAssertGreaterThanOrEqual(months.count, 3)
        let (m0, m1, m2) = (months[0], months[1], months[2])
        let plan: Decimal = 400
        s.setPlan("groc", plan, from: m0)
        let left0 = plan - s.spent("groc", in: m0)
        let carried1 = max(left0, 0)
        let line1 = try XCTUnwrap(s.budget(for: m1).groups.flatMap(\.lines).first { $0.category.id == "groc" })
        XCTAssertEqual(line1.carried, carried1)
        XCTAssertEqual(line1.left, plan + carried1 - s.spent("groc", in: m1))
        let left1 = line1.left
        let b2 = s.budget(for: m2)
        let line2 = try XCTUnwrap(b2.groups.flatMap(\.lines).first { $0.category.id == "groc" })
        XCTAssertEqual(line2.carried, max(left1, 0))
        XCTAssertEqual(b2.overspentBefore, left1 < 0 ? -left1 : 0)
        XCTAssertEqual(b2.unplanned, b2.income - b2.plan - b2.overspentBefore)
        // Before its plan was set, a category carries nothing.
        XCTAssertEqual(s.budget(for: m0).groups.flatMap(\.lines).first { $0.category.id == "groc" }?.carried, 0)
    }

    func test_guessesCarryNothingAndKeepingThemMakesThemHandSet() throws {
        let s = try loaded()
        let month = try XCTUnwrap(s.budgetMonths.last)
        XCTAssertTrue(s.budget(for: month).groups.flatMap(\.lines).allSatisfy { $0.carried == 0 })
        s.keepGuesses(in: month)
        let lines = s.budget(for: month).groups.flatMap(\.lines).filter { $0.plan > 0 }
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { !$0.guessed })
    }

    func test_recurringChargesComeEveryMonthOnAboutTheSameDay() throws {
        let s = try loaded()
        let found = s.recurring()
        XCTAssertFalse(found.isEmpty, "the fixtures carry subscriptions and rent")
        for r in found {
            XCTAssertGreaterThanOrEqual(r.months, 3, r.name)
            XCTAssertEqual(r.next.yearMonth, r.last.yearMonth.next, r.name)
        }
        XCTAssertEqual(SpendingStore.clampedDay(31, in: Month(2026, 2)), 28)
        XCTAssertEqual(SpendingStore.clampedDay(15, in: Month(2026, 2)), 15)
    }
}
