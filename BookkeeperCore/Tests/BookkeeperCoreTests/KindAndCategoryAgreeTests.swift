import XCTest
@testable import BookkeeperCore

/// A line's category always belongs to its kind, whatever left it there — a seed word, a
/// rule that set only part of a line, a spot edit from before a kind change — and the
/// bank side's bookkeeping (files, banks, cards) never drops what wasn't asked for.
final class KindAndCategoryAgreeTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-agree-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private static let header = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"

    private func ledger(_ lines: String) throws -> SpendingStore {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.header + lines, accountId: a.id)
        return s
    }

    // MARK: - Categories follow the kind

    func test_aSeedWordsSpendCategoryNeverLandsOnAPaycheck() throws {
        let s = try ledger("CREDIT,10/02/2026,UNIVERSITY PAYROLL DEP,2000.00,ACH_CREDIT,100.00,\n")
        let pay = try XCTUnwrap(s.transactions.first)
        XCTAssertEqual(pay.effectiveKind, .income)
        XCTAssertEqual(pay.effectiveCategoryId, "pay", "Paycheck, not Education")
        XCTAssertEqual(s.income(byCategoryIn: nil).first { $0.category.id == "pay" }?.count, 1)
    }

    func test_anIncomeKindRuleLeavesPurchasesOfTheSameShopAlone() throws {
        let s = try ledger("DEBIT,10/02/2026,PROSPECT GREENS MARKET,-40.00,DEBIT_CARD,100.00,\n"
            + "CREDIT,10/03/2026,PROSPECT GREENS MARKET,15.00,ACH_CREDIT,100.00,\n")
        let buy = try XCTUnwrap(s.transactions.first { $0.amount < 0 })
        let before = buy.effectiveCategoryId
        let credit = try XCTUnwrap(s.transactions.first { $0.amount > 0 })
        XCTAssertEqual(credit.effectiveKind, .income)
        let p = try XCTUnwrap(s.editPreview(credit.id))
        s.apply(edit: TransactionEdit(name: nil, categoryId: "back", kind: nil), to: credit.id,
                scope: .allLikeThis(pattern: p.core, match: .contains, unticked: [], direction: p.direction))
        XCTAssertEqual(s.transactions.first { $0.id == credit.id }?.effectiveCategoryId, "back")
        XCTAssertEqual(s.transactions.first { $0.id == buy.id }?.effectiveCategoryId, before,
                       "the purchase keeps its own category, not Refunds")
    }

    func test_aSpotCategoryStepsAsideWhenARuleChangesTheKind() throws {
        let s = try ledger("DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n")
        let t = try XCTUnwrap(s.transactions.first)
        s.apply(edit: TransactionEdit(name: nil, categoryId: "groc", kind: nil), to: t.id, scope: .justThisOne)
        let p = try XCTUnwrap(s.editPreview(t.id))
        s.apply(edit: TransactionEdit(name: nil, categoryId: nil, kind: .income), to: t.id,
                scope: .allLikeThis(pattern: p.core, match: .contains, unticked: [], direction: p.direction))
        let now = try XCTUnwrap(s.transactions.first)
        XCTAssertEqual(now.effectiveKind, .income)
        XCTAssertEqual(now.effectiveCategoryId, CategoryBook.incomeFallbackId, "Groceries is no kind of income")
    }

    // MARK: - What a line is to begin with

    func test_cardPaymentsAndRefundsReadThroughPunctuationAndWholeWords() {
        let k = KindClassifier(book: .defaults)
        XCTAssertEqual(k.kind(amount: 300, description: "ONLINE PAYMENT, THANK YOU", bankType: nil), .transfer)
        XCTAssertEqual(k.kind(amount: 300, description: "CAPITAL ONE MOBILE PYMT", bankType: nil), .transfer)
        XCTAssertEqual(k.kind(amount: 12, description: "AMAZON REFUNDS", bankType: nil), .spend)
        XCTAssertEqual(k.kind(amount: 900, description: "ACME RETURNED PAYROLL ADJ", bankType: nil), .income,
                       "RETURNED is not the word RETURN")
        XCTAssertEqual(CategoryBook.defaults.incomeCategoryId(for: "IRS TREAS 310 TAX REF"), "back")
    }

    // MARK: - Banks and files

    func test_removingAFileKeepsABankAddedByHand() throws {
        let s = try ledger("DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n")
        let waiting = s.addBank(name: "Savings", colorHex: "#222222")
        let file = try XCTUnwrap(s.imports.first)
        s.removeImport(file.importId)
        XCTAssertEqual(s.accounts.map(\.id), [waiting.id], "the emptied account goes; the waiting one stays")
    }

    func test_aDateAtTheEndOfAFileNameIsNotACard() {
        XCTAssertNil(SpendingStore.lastFour(inFileName: "export_1023.csv"))
        XCTAssertNil(SpendingStore.lastFour(inFileName: "transactions-0131.csv"))
        XCTAssertEqual(SpendingStore.lastFour(inFileName: "Chase checking 1023.csv"), "1023")
        XCTAssertEqual(SpendingStore.lastFour(inFileName: "export_4417.csv"), "4417", "not a date")
    }

    func test_aMergedAccountsCardStillFindsItsNewHome() throws {
        let s = SpendingStore(directory: dir)
        let lines = "DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n"
        let rows = CSV.parse(Self.header + lines)
        let recipe = try XCTUnwrap(RecipeMatcher.match(rows: rows, among: s.allRecipes))
        let a = s.account(for: rows, recipe: recipe, fileName: "Chase checking 1111.csv") { _ in "#000000" }
        try s.importCSV(text: Self.header + lines, accountId: a.id)
        let b = s.account(for: rows, recipe: recipe, fileName: "Chase checking 2222.csv") { _ in "#000000" }
        XCTAssertNotEqual(a.id, b.id)
        s.mergeAccount(a.id, into: b.id)
        let again = s.account(for: rows, recipe: recipe, fileName: "Chase checking 1111.csv") { _ in "#000000" }
        XCTAssertEqual(again.id, b.id, "a 1111 file goes to the account 1111 was merged into")
        XCTAssertEqual(s.accounts.count, 1)
    }

    func test_aFilePutInAnotherBanksAccountLeavesThatAccountsBankAlone() throws {
        let s = SpendingStore(directory: dir)
        let citi = s.addAccount(name: "Citi", recipeId: "citi-card", colorHex: "#000000")
        try s.importCSV(text: Self.header + "DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n",
                        accountId: citi.id)
        XCTAssertEqual(s.accounts.first?.recipeId, "citi-card")
    }

    // MARK: - Several cards, overlapping files, a file that won't read

    private static let cardHeader = "Card,Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n"

    func test_aFileHoldingTwoCardsGoesToTwoAccounts() throws {
        let s = SpendingStore(directory: dir)
        let text = Self.cardHeader
            + "1005,10/02/2026,10/03/2026,CORNER CO-OP,Groceries,Sale,-20.00,\n"
            + "1005,10/04/2026,10/05/2026,SLICE SHOP,Food & Drink,Sale,-12.00,\n"
            + "2003,10/06/2026,10/07/2026,MR KALE,Groceries,Sale,-9.00,\n"
        let rows = CSV.parse(text)
        let recipe = try XCTUnwrap(RecipeMatcher.match(rows: rows, among: s.allRecipes))
        XCTAssertEqual(s.cards(in: rows, recipe: recipe), ["1005", "2003"])
        for card in s.cards(in: rows, recipe: recipe) {
            let a = s.account(for: rows, recipe: recipe, fileName: "amex.csv", card: card) { _ in "#000000" }
            try s.importCSV(data: Data(text.utf8), accountId: a.id, recipe: recipe, fileName: "amex.csv", card: card)
        }
        XCTAssertEqual(s.accounts.count, 2)
        let byCard = Dictionary(grouping: s.transactions) { t in s.accounts.first { $0.id == t.accountId }?.card ?? "" }
        XCTAssertEqual(byCard["1005"]?.count, 2)
        XCTAssertEqual(byCard["2003"]?.count, 1)

        // Taking one card's part out leaves the other's.
        let one = try XCTUnwrap(s.imports.first { $0.card == "2003" })
        s.removeImport(one.importId)
        XCTAssertEqual(s.transactions.count, 2)
    }

    func test_removingAnEarlierFileKeepsTheLinesALaterOneAlsoHolds() throws {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        let jan = "DEBIT,01/10/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n"
        let feb = "DEBIT,02/10/2026,SLICE SHOP,-12.00,DEBIT_CARD,100.00,\n"
        let mar = "DEBIT,03/10/2026,MR KALE,-9.00,DEBIT_CARD,100.00,\n"
        try s.importCSV(data: Data((Self.header + jan + feb).utf8), accountId: a.id, fileName: "jan-feb.csv")
        try s.importCSV(data: Data((Self.header + feb + mar).utf8), accountId: a.id, fileName: "feb-mar.csv")
        XCTAssertEqual(s.transactions.count, 3)
        let first = try XCTUnwrap(s.imports.first { $0.fileName == "jan-feb.csv" })
        XCTAssertEqual(s.removeImport(first.importId), 1, "only January goes")
        XCTAssertEqual(Set(s.transactions.map(\.rawDescription)), ["SLICE SHOP", "MR KALE"])
        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.transactions.count, 2, "and it is saved")
    }

    func test_aFileThatWontReadIsSaidNotSilentlyEmptied() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("transactions.json"))
        let s = SpendingStore(directory: dir)
        XCTAssertTrue(s.transactions.isEmpty)
        XCTAssertTrue(s.saveFailure?.contains("transactions.json") ?? false)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("transactions.json.corrupt-") }, "set aside, not deleted")
    }

    func test_aWindowOfDaysCountsOnlyThoseDays() throws {
        let s = try ledger("DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n"
            + "DEBIT,10/20/2026,CORNER CO-OP,-30.00,DEBIT_CARD,100.00,\n")
        let w = s.totals(from: Day(2026, 10, 1), through: Day(2026, 10, 12), income: false)
        XCTAssertEqual(w.values.flatMap(\.values).reduce(0, +), 20)
    }
}
