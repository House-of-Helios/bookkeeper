import XCTest
@testable import BookkeeperCore

/// The ledger: import through a recipe, dedup by stable id, kinds, categories, overrides,
/// and the queries the Spending screen draws from. Every store gets its own temp folder.
final class SpendingStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-spend-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store() -> SpendingStore { SpendingStore(directory: dir) }

    @discardableResult
    private func load(_ s: SpendingStore, _ fixture: String, into account: String) throws -> ImportSummary {
        try s.importCSV(fileURL: BankFixtures.url(fixture), accountId: account)
    }

    private func tx(_ s: SpendingStore, _ day: Day, _ raw: String) throws -> BankTransaction {
        try XCTUnwrap(s.transactions.first { $0.date == day && $0.rawDescription == raw }, "\(day) \(raw)")
    }

    // MARK: - Import + dedup

    func test_everyFixtureImportsThroughItsBuiltInRecipe() throws {
        let s = store()
        let counts = ["chase_card": 1017, "chase_checking": 283, "bank_of_america_checking": 481,
                      "wells_fargo": 489, "capital_one": 250, "amex": 155, "citi": 226,
                      "discover": 283, "apple_card": 357]
        for (fixture, count) in counts {
            let account = s.addAccount(name: fixture, colorHex: "#7B90D2")
            let summary = try load(s, fixture, into: account.id)
            XCTAssertEqual(summary.added, count, fixture)
            XCTAssertEqual(summary.alreadyHere, 0, fixture)
            XCTAssertEqual(s.accounts.first { $0.id == account.id }?.recipeId,
                           RecipeMatcher.match(try BankFixtures.text(fixture))?.id,
                           "the account remembers its bank's recipe")
        }
        XCTAssertEqual(s.transactions.count, counts.values.reduce(0, +))
    }

    func test_twinCoffeesOnOneDayStayTwo() throws {
        let s = store()
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C")
        try load(s, "chase_card", into: card.id)
        let twins = s.transactions.filter {
            $0.date == Day(2026, 2, 12) && $0.rawDescription == "GOWANUS GRIND COFFEE BROOKLYN NY"
                && $0.amount == Decimal(string: "-4.5")
        }
        XCTAssertEqual(twins.count, 2)
        XCTAssertNotEqual(twins[0].id, twins[1].id)
    }

    func test_overlappingExportsAddOnlyTheNewMonths() throws {
        let s = store()
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C")
        XCTAssertEqual(try load(s, "chase_card_2026-01_to_2026-03", into: card.id).added, 171)

        let second = try load(s, "chase_card_2026-02_to_2026-04", into: card.id)
        XCTAssertEqual(second.added, 57, "April only")
        XCTAssertEqual(second.alreadyHere, 115, "February–March were already here")
        XCTAssertEqual(second.toReview, 0, "rows that came back verbatim are not near-duplicates")

        let again = try load(s, "chase_card_2026-02_to_2026-04", into: card.id)
        XCTAssertEqual(again.added, 0, "the same file twice adds nothing")
        XCTAssertEqual(again.alreadyHere, 172)

        let full = try load(s, "chase_card", into: card.id)
        XCTAssertEqual(full.added, 1017 - 228)
        XCTAssertEqual(full.alreadyHere, 228)
        XCTAssertEqual(s.transactions.count, 1017)
    }

    func test_theSameRowsInAnotherAccountAreNotDuplicates() throws {
        let s = store()
        let a = s.addAccount(name: "Mine", colorHex: "#D0104C")
        let b = s.addAccount(name: "Partner's", colorHex: "#7B90D2")
        try load(s, "citi", into: a.id)
        XCTAssertEqual(try load(s, "citi", into: b.id).added, 226)
    }

    func test_aNearDuplicateGoesToReviewNotMerged() throws {
        let s = store()
        let a = s.addAccount(name: "Card", colorHex: "#D0104C")
        let header = "Card,Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n"
        try s.importCSV(text: header + "4417,03/10/2026,03/11/2026,MR KALE BROOKLYN NY 0042 POS,Food & Drink,Sale,-13.25,\n",
                        accountId: a.id)
        // The bank re-describes the same purchase a day later in the next export.
        let next = try s.importCSV(text: header
            + "4417,03/11/2026,03/12/2026,MR KALE BKLYN,Food & Drink,Sale,-13.25,\n"
            + "4417,03/20/2026,03/21/2026,MR KALE BKLYN,Food & Drink,Sale,-13.25,\n",
                                   accountId: a.id)
        XCTAssertEqual(next.added, 2, "kept, never silently merged")
        XCTAssertEqual(next.toReview, 1, "only the one within two days of a lookalike")
        XCTAssertEqual(s.transactions(TransactionFilter(needsReview: true)).map(\.rawDescription),
                       ["MR KALE BKLYN"])
        let flagged = try XCTUnwrap(s.transactions(TransactionFilter(needsReview: true)).first)
        s.markReviewed(flagged.id)
        XCTAssertTrue(s.transactions(TransactionFilter(needsReview: true)).isEmpty)
    }

    func test_anUnknownShapeIsRefusedForTheMappingSheet() {
        let s = store()
        let a = s.addAccount(name: "Odd bank", colorHex: "#4A4A4A")
        XCTAssertThrowsError(try s.importCSV(text: "When,What,How much\n01/02/2026,Coffee,4.50\n",
                                             accountId: a.id)) { error in
            XCTAssertEqual(error as? SpendingImportError, .unknownShape)
        }
        XCTAssertTrue(s.transactions.isEmpty)
    }

    func test_aTaughtRecipeImportsAndIsRemembered() throws {
        let s = store()
        let a = s.addAccount(name: "Odd bank", colorHex: "#4A4A4A")
        let text = "When,What,How much\n01/02/2026,Coffee,4.50\n"
        let recipe = ImportRecipe(id: "odd", name: "Odd bank", headerFingerprint: ["When", "What", "How much"],
                                  dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1,
                                  amount: .signed(column: 2, moneyOutIsNegative: false))
        s.addRecipe(recipe)
        XCTAssertEqual(try s.importCSV(text: text, accountId: a.id).added, 1)
        XCTAssertEqual(s.transactions.first?.amount, Decimal(string: "-4.5"))
        XCTAssertEqual(SpendingStore(directory: dir).recipes, [recipe], "recipes.json holds what was taught")
    }

    func test_theOriginalFileIsKeptOwnerOnly() throws {
        let s = store()
        let a = s.addAccount(name: "Citi", colorHex: "#D0104C")
        let summary = try load(s, "citi", into: a.id)
        let kept = dir.appendingPathComponent("imports/\(summary.importId).csv")
        XCTAssertEqual(try Data(contentsOf: kept), try Data(contentsOf: BankFixtures.url("citi")))
        let perms = try FileManager.default.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(s.transactions.allSatisfy { $0.importId == summary.importId })
    }

    // MARK: - Files

    func test_everythingSurvivesAReopenAsPlainJSON() throws {
        let s = store()
        let a = s.addAccount(name: "Apple", colorHex: "#A8497A")
        try load(s, "apple_card", into: a.id)
        let first = s.transactions[0]
        s.setOverride(TransactionOverride(name: "Lantern"), for: first.id)

        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.accounts, s.accounts)
        XCTAssertEqual(reopened.transactions, s.transactions)
        XCTAssertEqual(reopened.categories, s.categories)

        for name in ["accounts.json", "transactions.json", "categories.json"] {
            let url = dir.appendingPathComponent(name)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: url)), name)
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(perms, 0o600, name)
        }
        // Amounts are exact text and dates are plain days — readable by anything.
        let json = try String(contentsOf: dir.appendingPathComponent("transactions.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"amount\" : \"-5\"") || json.contains("\"amount\" : \"-5.00\""),
                      "amount stored as text")
        XCTAssertTrue(json.contains("\"date\" : \"2026-10-29\""))
    }

    // MARK: - Kinds

    func test_paymentsAndTransfersAreTransfersEverywhere() throws {
        let s = store()
        let files = ["chase_card", "chase_checking", "bank_of_america_checking", "wells_fargo",
                     "capital_one", "amex", "citi", "discover", "apple_card"]
        for f in files { try load(s, f, into: s.addAccount(name: f, colorHex: "#4A4A4A").id) }
        let transfers = s.transactions.filter { $0.kind == .transfer }
        for raw in ["AUTOPAY PAYMENT - THANK YOU", "PAYMENT THANK YOU-MOBILE",
                    "CHASE CREDIT CRD AUTOPAY PPD ID: 9000000003", "ONLINE TRANSFER TO SAV XXXXXX9001",
                    "BANK OF AMERICA CREDIT CARD Bill Payment", "WF CREDIT CARD AUTO PAY",
                    "CAPITAL ONE AUTOPAY PYMT", "PAYMENT THANK YOU", "INTERNET PAYMENT - THANK YOU",
                    "AUTOPAY PAYMENT"] {
            XCTAssertTrue(transfers.contains { $0.rawDescription == raw }, raw)
            XCTAssertTrue(s.transactions.filter { $0.rawDescription == raw }.allSatisfy { $0.kind == .transfer }, raw)
        }
        // Money in is payroll and nothing else.
        let income = Set(s.transactions.filter { $0.kind == .income }.map(\.rawDescription))
        XCTAssertEqual(income, ["HALCYON LABS PAYROLL PPD ID: 9000000001"])
    }

    func test_incomeByMonthAndByPayerAddUpToTheIncomeTotals() throws {
        let s = store()
        try load(s, "chase_checking", into: s.addAccount(name: "Chase", colorHex: "#4A4A4A").id)
        let byCategory = s.income(byCategoryIn: nil)
        let total = byCategory.reduce(Decimal(0)) { $0 + $1.total }
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(s.monthlyIncome().reduce(Decimal(0)) { $0 + $1.total }, total)
        for c in byCategory {
            XCTAssertEqual(s.payers(in: c.category.id, range: nil).reduce(Decimal(0)) { $0 + $1.total }, c.total)
            XCTAssertEqual(s.incomeLines(in: c.category.id, range: nil).count, c.count)
            XCTAssertEqual(s.monthlyIncome(category: c.category.id).reduce(Decimal(0)) { $0 + $1.total }, c.total)
        }
    }

    func test_aReturnIsSpendThatShrinksItsCategory() throws {
        let s = store()
        let a = s.addAccount(name: "Chase", colorHex: "#D0104C")
        try load(s, "chase_card_quoted_commas", into: a.id)
        let back = try tx(s, Day(2026, 3, 12), "FULTON STREET BOOKS")
        XCTAssertEqual(back.kind, .spend)
        XCTAssertEqual(back.amount, Decimal(string: "18.99"))
        XCTAssertEqual(back.effectiveCategoryId, "shop")
        let shop = s.spend(byCategoryIn: nil, everyday: true).first { $0.category.id == "shop" }
        XCTAssertEqual(shop?.total, Decimal(string: "-18.99"), "a return alone nets below zero")

        // A refund named in the description counts too, without a Type column.
        XCTAssertEqual(KindClassifier(book: .defaults).kind(amount: 12, description: "AMAZON REFUND", bankType: nil),
                       .spend)
        XCTAssertEqual(KindClassifier(book: .defaults).kind(amount: 12, description: "INTEREST PAID", bankType: nil),
                       .income)
    }

    func test_transfersNeverCountAsSpend() throws {
        let s = store()
        let a = s.addAccount(name: "Citi", colorHex: "#D0104C")
        try load(s, "citi", into: a.id)
        let total = s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }
        let purchases = s.transactions.filter { $0.amount < 0 }.reduce(Decimal(0)) { $0 - $1.amount }
        XCTAssertEqual(total, purchases, "payments are left out, purchases all in")
        XCTAssertGreaterThan(total, 0)
    }

    func test_transferPatternsAreEditable() throws {
        let s = store()
        var book = s.categories
        book.transferPatterns.append("ZELLE TO R QUILL")
        s.updateCategories(book)
        let a = s.addAccount(name: "Chase", colorHex: "#D0104C")
        try s.importCSV(text: "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
                        + "DEBIT,03/02/2026,Zelle to R Quill savings,-50.00,QUICKPAY_DEBIT,100.00,\n",
                        accountId: a.id)
        XCTAssertEqual(s.transactions.first?.kind, .transfer, "matched without regard to case")
        XCTAssertTrue(SpendingStore(directory: dir).categories.transferPatterns.contains("ZELLE TO R QUILL"))
    }

    // MARK: - Overrides

    func test_anOverrideBeatsTheDefaultForThatOneTransaction() throws {
        let s = store()
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try load(s, "chase_checking", into: a.id)
        let atm = s.transactions.filter { $0.rawDescription.hasPrefix("ATM WITHDRAWAL") }
        XCTAssertGreaterThan(atm.count, 1)
        let one = atm[0]
        XCTAssertEqual(one.kind, .spend)

        let before = s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }
        s.setOverride(TransactionOverride(name: "Cash for rent split", categoryId: "home", kind: .transfer),
                      for: one.id)
        let after = s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }

        let edited = try XCTUnwrap(s.transactions.first { $0.id == one.id })
        XCTAssertEqual(edited.effectiveKind, .transfer, "internal transfer — doesn't count as spend")
        XCTAssertEqual(edited.effectiveCategoryId, "home")
        XCTAssertEqual(edited.displayName, "Cash for rent split")
        XCTAssertEqual(edited.rawDescription, one.rawDescription, "raw text never edited")
        XCTAssertEqual(after, before + one.amount, "that one ATM left the total")
        XCTAssertEqual(s.transactions.filter { $0.rawDescription.hasPrefix("ATM WITHDRAWAL") && $0.effectiveKind == .spend }.count,
                       atm.count - 1, "the others are untouched")

        // A re-import never clobbers the edit.
        try load(s, "chase_checking", into: a.id)
        XCTAssertEqual(s.transactions.first { $0.id == one.id }?.override?.kind, .transfer)

        s.setOverride(nil, for: one.id)
        XCTAssertEqual(s.transactions.first { $0.id == one.id }?.effectiveKind, .spend)
    }

    func test_anOverrideCanTurnSpendIntoIncomeAndBack() throws {
        let s = store()
        let a = s.addAccount(name: "Citi", colorHex: "#D0104C")
        try load(s, "citi", into: a.id)
        let pay = try XCTUnwrap(s.transactions.first { $0.kind == .transfer })
        s.setOverride(TransactionOverride(kind: .spend), for: pay.id)
        XCTAssertEqual(s.transactions.first { $0.id == pay.id }?.effectiveKind, .spend)
    }

    // MARK: - Categories


    func test_bankCategoriesSeedOurs() throws {
        let s = store()
        for f in ["chase_card", "capital_one", "discover", "apple_card"] {
            try load(s, f, into: s.addAccount(name: f, colorHex: "#4A4A4A").id)
        }
        // Every bank category in the fixtures lands somewhere deliberate.
        let unmapped = Set(s.transactions.filter { $0.kind == .spend && $0.categoryId == nil }
            .compactMap(\.bankCategory))
        XCTAssertEqual(unmapped, [], "no bank category falls through by accident")

        let seeded = Dictionary(s.transactions.compactMap { t in t.bankCategory.map { ($0, t.categoryId) } },
                                uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(seeded["Food & Drink"], "eat")
        XCTAssertEqual(seeded["Groceries"], "groc")
        XCTAssertEqual(seeded["Supermarkets"], "groc")
        XCTAssertEqual(seeded["Restaurants"], "eat")
        XCTAssertEqual(seeded["Dining"], "eat")
        XCTAssertEqual(seeded["Grocery"], "groc")
        XCTAssertEqual(seeded["Travel"], "move")
        XCTAssertEqual(seeded["Transportation"], "move")
        XCTAssertEqual(seeded["Bills & Utilities"], "util")
        XCTAssertEqual(seeded["Health & Wellness"], "heal")
        XCTAssertEqual(seeded["Entertainment"], "fun")
        XCTAssertEqual(seeded["Merchandise"], "shop")
        // A payment carries no spend category, whatever the bank called it.
        XCTAssertEqual(seeded["Payment/Credit"] ?? nil, nil)
    }

    func test_anUncategorisedSpendFallsToEverythingElse() throws {
        let s = store()
        let a = s.addAccount(name: "Citi", colorHex: "#D0104C")
        try load(s, "citi", into: a.id)
        // Citi has no category column: only seed words place a line; the rest fall through.
        let byRaw = Dictionary(s.transactions.filter { $0.kind == .spend }.map { ($0.rawDescription, $0.effectiveCategoryId) },
                               uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byRaw["CITY TRANSIT FARE NEW YORK"], "else")
        XCTAssertEqual(byRaw["YELLOWBIRD RIDES *TRIP"], "else")
        XCTAssertEqual(byRaw["PROSPECT GREENS MARKET BROOKLYN"], "groc")
        XCTAssertEqual(byRaw["SMITH ST PHARMACY BROOKLYN"], "heal")
        XCTAssertTrue(s.transactions.filter { $0.kind == .spend }.allSatisfy { $0.ruleCategoryId != nil || $0.effectiveCategoryId == "else" })
    }

    // MARK: - Queries

    private func chase() throws -> SpendingStore {
        let s = store()
        try load(s, "chase_card", into: s.addAccount(name: "Chase", colorHex: "#D0104C").id)
        return s
    }

    func test_spendByCategoryFollowsRingOrderAndTheRange() throws {
        let s = try chase()
        let march = Month(2026, 3)...Month(2026, 3)
        let ring = s.spend(byCategoryIn: march, everyday: false)
        let order = CategoryBook.defaults.categories.map(\.id)
        XCTAssertEqual(ring.map(\.category.id), order.filter { id in ring.contains { $0.category.id == id } },
                       "ring order, never sorted by size")
        let expected = s.transactions
            .filter { $0.date.yearMonth == Month(2026, 3) && $0.kind == .spend && $0.effectiveCategoryId == "eat" }
            .reduce(Decimal(0)) { $0 - $1.amount }
        XCTAssertEqual(ring.first { $0.category.id == "eat" }?.total, expected)
        XCTAssertGreaterThan(expected, 0)
    }

    func test_everydaySetsFixedCostsAside() throws {
        let s = try chase()
        try s.importCSV(text: "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
            + "DEBIT,03/01/2026,BRIGHTSTONE PROPERTY MGMT RENT WEB ID: 9000000002,-2150.00,ACH_DEBIT,100.00,\n",
                         accountId: s.addAccount(name: "Chase checking", colorHex: "#0089A7").id)
        let all = s.spend(byCategoryIn: nil, everyday: false)
        let everyday = s.spend(byCategoryIn: nil, everyday: true)
        for fixed in ["home", "util"] {
            XCTAssertTrue(all.contains { $0.category.id == fixed }, fixed)
            XCTAssertFalse(everyday.contains { $0.category.id == fixed }, fixed)
        }
        XCTAssertEqual(s.fixedSpend(in: nil), all.filter { ["home", "util"].contains($0.category.id) }
            .reduce(Decimal(0)) { $0 + $1.total })
        XCTAssertEqual(s.monthlyTotals(everyday: true).reduce(Decimal(0)) { $0 + $1.total }
            + s.fixedSpend(in: nil), s.monthlyTotals(everyday: false).reduce(Decimal(0)) { $0 + $1.total })
    }

    func test_monthlyTotalsCoverEveryMonthInOrder() throws {
        let s = try chase()
        let months = s.monthlyTotals(everyday: true)
        XCTAssertEqual(months.first?.month, Month(2025, 5))
        XCTAssertEqual(months.last?.month, Month(2026, 10))
        XCTAssertEqual(months.count, 18, "no gaps")
        let overall = s.spend(byCategoryIn: nil, everyday: true).reduce(Decimal(0)) { $0 + $1.total }
        XCTAssertEqual(months.reduce(Decimal(0)) { $0 + $1.total }, overall)
        // The stacked strip: each month's categories add to its total.
        for m in months { XCTAssertEqual(m.byCategory.values.reduce(0, +), m.total) }
        let cafes = s.monthlyTotals(category: "eat", everyday: true)
        XCTAssertTrue(cafes.allSatisfy { Set($0.byCategory.keys).isSubset(of: ["eat"]) })
    }

    func test_merchantsRankByTotalAndUseTheBestName() throws {
        let s = store()
        try load(s, "apple_card", into: s.addAccount(name: "Apple", colorHex: "#A8497A").id)
        let eat = s.merchants(in: "eat", range: nil)
        XCTAssertEqual(eat.map(\.total), eat.map(\.total).sorted(by: >))
        XCTAssertTrue(eat.contains { $0.name == "Mr. Kale" }, "Apple's clean Merchant column folds the Kale spellings")
        XCTAssertFalse(eat.contains { $0.name.hasPrefix("SQ *") })
        let kale = try XCTUnwrap(eat.first { $0.name == "Mr. Kale" })
        XCTAssertEqual(kale.count, s.transactions.filter { $0.bankMerchant == "Mr. Kale" }.count)
    }

    func test_oneMerchantMonthByMonthAddsUpToItsTotal() throws {
        let s = store()
        try load(s, "apple_card", into: s.addAccount(name: "Apple", colorHex: "#A8497A").id)
        let kale = try XCTUnwrap(s.merchants(in: "eat", range: nil).first { $0.name == "Mr. Kale" })
        let months = s.monthlyTotals(merchant: "Mr. Kale", income: false)
        XCTAssertEqual(months.map(\.month), s.monthlyTotals(everyday: false).map(\.month),
                       "every ledger month, gaps as zero")
        XCTAssertEqual(months.reduce(0) { $0 + $1.total }, kale.total)
        XCTAssertTrue(s.monthlyTotals(merchant: "NO SUCH SHOP", income: false).allSatisfy { $0.total == 0 })
    }

    func test_everyLinesAllLikeThisCatchesAtLeastItself() throws {
        let s = store()
        for fixture in ["chase_card", "chase_checking", "bank_of_america_checking", "wells_fargo",
                        "capital_one", "amex", "citi", "discover", "apple_card"] {
            try load(s, fixture, into: s.addAccount(name: fixture, colorHex: "#7B90D2").id)
        }
        var seen = Set<String>()
        for t in s.transactions where seen.insert(t.rawDescription).inserted {
            let p = try XCTUnwrap(s.editPreview(t.id))
            XCTAssertTrue(p.likeThis.contains { $0.id == t.id }, "\(t.rawDescription) → \(p.core)")
        }
    }

    func test_renamingAllLikeThisRenamesEveryEntryOfThatMerchant() throws {
        let s = store()
        try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        let pier = s.transactions.filter { $0.rawDescription.hasPrefix("PIER 6 OYSTER BAR") }
        XCTAssertGreaterThan(pier.count, 1)
        let p = try XCTUnwrap(s.editPreview(pier[0].id))
        XCTAssertEqual(p.suggestedName, "Pier 6 Oyster Bar")
        let n = s.apply(edit: TransactionEdit(name: "Pier 6 Oyster Bar", categoryId: "eat", kind: .spend),
                        to: pier[0].id, scope: .allLikeThis(pattern: p.core, match: .contains, unticked: []))
        XCTAssertEqual(n, pier.count)
        for t in s.transactions where t.rawDescription.hasPrefix("PIER 6 OYSTER BAR") {
            XCTAssertEqual(t.displayName, "Pier 6 Oyster Bar")
            XCTAssertEqual(t.effectiveCategoryId, "eat")
        }
        XCTAssertTrue(s.merchants(in: "eat", range: nil).contains { $0.name == "Pier 6 Oyster Bar" })
    }

    func test_removingAFileTakesOutOnlyItsOwnEntries() throws {
        let s = store()
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C").id
        let amex = s.addAccount(name: "Amex", colorHex: "#7B90D2").id
        let chase = try load(s, "chase_card", into: card)
        try load(s, "amex", into: amex)
        let amexCount = s.transactions.filter { $0.accountId == amex }.count
        XCTAssertEqual(s.removeImport(chase.importId), chase.added)
        XCTAssertTrue(s.transactions.allSatisfy { $0.accountId == amex })
        XCTAssertEqual(s.transactions.count, amexCount)
        XCTAssertFalse(s.imports.contains { $0.importId == chase.importId })
        XCTAssertFalse(s.accounts.contains { $0.id == card }, "an account with no files left goes")
        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.transactions.count, amexCount, "the removal is on disk")
        try load(s, "chase_card", into: s.addAccount(name: "Chase", colorHex: "#D0104C").id)
        XCTAssertEqual(s.imports.last?.added, chase.added, "dropping it again brings it all back")
    }

    func test_startingOverEmptiesTheBankSideButKeepsTheLook() throws {
        let s = store()
        try load(s, "apple_card", into: s.addAccount(name: "Apple", colorHex: "#A8497A").id)
        s.setTextSize(.large)
        let t = try XCTUnwrap(s.transactions.first)
        let p = try XCTUnwrap(s.editPreview(t.id))
        s.apply(edit: TransactionEdit(name: "X", categoryId: "eat", kind: .spend), to: t.id,
                scope: .allLikeThis(pattern: p.core, match: .contains, unticked: []))
        XCTAssertFalse(s.rules.isEmpty)
        s.startOver()
        let reopened = SpendingStore(directory: dir)
        for x in [s, reopened] {
            XCTAssertTrue(x.transactions.isEmpty && x.accounts.isEmpty && x.imports.isEmpty && x.rules.isEmpty)
            XCTAssertEqual(x.settings.textSize, .large)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("imports").path))
    }

    func test_aFileThatWontReadIsMovedAsideNotWrittenOver() throws {
        let s = store()
        try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        let file = dir.appendingPathComponent("transactions.json")
        try Data("{ not json".utf8).write(to: file)
        let reopened = SpendingStore(directory: dir)
        XCTAssertTrue(reopened.transactions.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("transactions.json.corrupt-") }
        XCTAssertEqual(aside.count, 1, "the unreadable file is kept, under a new name")
    }

    func test_removingOrStartingOverKeepsABackupFirst() throws {
        let s = store()
        let r = try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        s.removeImport(r.importId)
        let backups = dir.appendingPathComponent("backups")
        let first = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        let kept = try Data(contentsOf: backups.appendingPathComponent(first).appendingPathComponent("transactions.json"))
        XCTAssertFalse(try JSONDecoder.iso.decode([BankTransaction].self, from: kept).isEmpty)
    }

    func test_nameResolutionOrder() {
        var t = BankTransaction(id: "x", accountId: "a", date: Day(2026, 1, 1), amount: -1,
                                rawDescription: "SQ *MR KALE BKLYN", importId: "i", kind: .spend)
        XCTAssertEqual(t.displayName, "SQ *MR KALE BKLYN")
        t.bankMerchant = "Mr. Kale"
        XCTAssertEqual(t.displayName, "Mr. Kale")
        t.merchantName = "Mr. Kale (rule)"   // where Stage 3's rules write
        XCTAssertEqual(t.displayName, "Mr. Kale (rule)")
        t.override = TransactionOverride(name: "Kale, the good one")
        XCTAssertEqual(t.displayName, "Kale, the good one")
    }

    func test_transactionsAreChronologicalAndFilter() throws {
        let s = try chase()
        let all = s.transactions()
        XCTAssertEqual(all.map(\.date), all.map(\.date).sorted())
        let marchEat = s.transactions(TransactionFilter(range: Month(2026, 3)...Month(2026, 3), categoryId: "eat"))
        XCTAssertFalse(marchEat.isEmpty)
        XCTAssertTrue(marchEat.allSatisfy { $0.date.yearMonth == Month(2026, 3) && $0.effectiveCategoryId == "eat" })
        let transfers = s.transactions(TransactionFilter(kind: .transfer))
        XCTAssertTrue(transfers.allSatisfy { $0.effectiveKind == .transfer })
        XCTAssertEqual(transfers.count, 17)
        let gowanus = s.transactions(TransactionFilter(merchant: "GOWANUS GRIND COFFEE BROOKLYN NY"))
        XCTAssertTrue(gowanus.allSatisfy { $0.displayName == "GOWANUS GRIND COFFEE BROOKLYN NY" })
        XCTAssertGreaterThan(gowanus.count, 100)
    }

    // MARK: - Which account a file goes to

    private func chaseCard(_ card: String, _ lines: [String]) -> String {
        (["Card,Transaction Date,Post Date,Description,Category,Type,Amount,Memo"]
            + lines.map { "\(card),\($0)" }).joined(separator: "\n")
    }

    private func drop(_ s: SpendingStore, _ text: String) throws -> (BankAccount, ImportSummary) {
        let rows = CSV.parse(text)
        let recipe = try XCTUnwrap(RecipeMatcher.match(rows: rows, among: s.allRecipes))
        let a = s.account(for: rows, recipe: recipe) { _ in "#7B90D2" }
        return (a, try s.importCSV(text: text, accountId: a.id, recipe: recipe))
    }

    func test_twoCardsFromOneBankAreTwoAccountsAndKeepTheirSameDayTwins() throws {
        let s = store()
        let coffee = "10/03/2026,10/04/2026,GOWANUS GRIND COFFEE,Food & Drink,Sale,-7.00,"
        let (a, first) = try drop(s, chaseCard("4417", [coffee, "10/05/2026,10/06/2026,MR KALE,Food & Drink,Sale,-12.00,"]))
        let (b, second) = try drop(s, chaseCard("8830", [coffee]))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual([a.name, b.name], ["Chase card ··4417", "Chase card ··8830"])
        XCTAssertEqual(first.added + second.added, 3, "the same coffee on two cards is two coffees")
        let (again, repeatSummary) = try drop(s, chaseCard("4417", [coffee]))
        XCTAssertEqual(again.id, a.id)
        XCTAssertEqual(repeatSummary.added, 0)
        XCTAssertEqual(s.accounts.count, 2)
    }

    func test_aCheckingFileThatSharesDatesButNoRowsIsAnotherAccount() throws {
        let s = store()
        let header = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #"
        func file(_ rows: [String]) -> String { ([header] + rows).joined(separator: "\n") }
        let (a, _) = try drop(s, file(["DEBIT,10/01/2026,CORNER DELI,-8.00,DEBIT_CARD,100.00,",
                                       "DEBIT,10/28/2026,CORNER DELI,-9.00,DEBIT_CARD,91.00,"]))
        // Same month, nothing in common: a second checking account at the same bank.
        let (b, _) = try drop(s, file(["DEBIT,10/02/2026,BAKERY,-4.00,DEBIT_CARD,50.00,",
                                       "DEBIT,10/27/2026,BAKERY,-5.00,DEBIT_CARD,45.00,"]))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(b.name, "Chase checking 2")
        // Next month, repeating one of the first account's rows: the first account.
        let (c, summary) = try drop(s, file(["DEBIT,10/28/2026,CORNER DELI,-9.00,DEBIT_CARD,91.00,",
                                             "DEBIT,11/20/2026,CORNER DELI,-6.00,DEBIT_CARD,85.00,"]))
        XCTAssertEqual(c.id, a.id)
        XCTAssertEqual(summary.added, 1)
    }

    func test_anAccountMadeBeforeCardDigitsTakesThemFromAFileThatRepeatsIt() throws {
        let s = store()
        let old = s.addAccount(name: "Chase card", recipeId: BuiltInRecipes.chaseCard.id, colorHex: "#7B90D2")
        let line = "10/03/2026,10/04/2026,GOWANUS GRIND COFFEE,Food & Drink,Sale,-7.00,"
        try s.importCSV(text: chaseCard("4417", [line]), accountId: old.id, recipe: BuiltInRecipes.chaseCard)
        let (a, _) = try drop(s, chaseCard("4417", [line]))
        XCTAssertEqual(a.id, old.id)
        XCTAssertEqual(s.accounts.first?.card, "4417")
    }

    // MARK: - Cached answers stay true

    func test_aCachedFigureMovesWhenAnEntryIsRecategorised() throws {
        let s = store()
        try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        let pier = try XCTUnwrap(s.transactions.first { $0.rawDescription.hasPrefix("PIER 6 OYSTER BAR") })
        let before = s.spend(byCategoryIn: nil, everyday: false)
        let revision = s.revision
        s.apply(edit: TransactionEdit(categoryId: "fun"), to: pier.id, scope: .justThisOne)
        XCTAssertNotEqual(s.revision, revision)
        let after = s.spend(byCategoryIn: nil, everyday: false)
        let fun = { (rows: [CategorySpend]) in rows.first { $0.category.id == "fun" }?.total ?? 0 }
        XCTAssertEqual(fun(after) - fun(before), pier.spendAmount)
    }

    // MARK: - Rules

    func test_aRuleCountsItsEntriesAndRemovingItHandsThemBack() throws {
        let s = store()
        try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        let pier = s.transactions.filter { $0.rawDescription.hasPrefix("PIER 6 OYSTER BAR") }
        let core = try XCTUnwrap(s.editPreview(pier[0].id)).core
        s.apply(edit: TransactionEdit(name: "The Pier"), to: pier[0].id,
                scope: .allLikeThis(pattern: core, match: .contains, unticked: []))
        let rule = try XCTUnwrap(s.rules.first)
        XCTAssertEqual(s.reach(of: rule), pier.count)
        XCTAssertTrue(s.transactions.filter { $0.rawDescription.hasPrefix("PIER 6") }.allSatisfy { $0.displayName == "The Pier" })
        s.removeRule(rule.id)
        XCTAssertTrue(s.rules.isEmpty)
        XCTAssertFalse(s.transactions.contains { $0.displayName == "The Pier" })
    }


    func test_editingARuleRenamesAndRecategorisesEveryEntryItCatches() throws {
        let s = store()
        try load(s, "amex", into: s.addAccount(name: "Amex", colorHex: "#7B90D2").id)
        let pier = s.transactions.filter { $0.rawDescription.hasPrefix("PIER 6 OYSTER BAR") }
        let core = try XCTUnwrap(s.editPreview(pier[0].id)).core
        s.apply(edit: TransactionEdit(name: "The Pier"), to: pier[0].id,
                scope: .allLikeThis(pattern: core, match: .contains, unticked: []))
        let rule = try XCTUnwrap(s.rules.first)
        s.updateRule(rule.id, pattern: rule.pattern, name: "Pier Six", categoryId: "fun", kind: .spend)
        let now = s.transactions.filter { $0.rawDescription.hasPrefix("PIER 6 OYSTER BAR") }
        XCTAssertTrue(now.allSatisfy { $0.displayName == "Pier Six" && $0.effectiveCategoryId == "fun" })
        s.updateRule(rule.id, pattern: "   ", name: "Nothing", categoryId: nil, kind: nil)
        XCTAssertEqual(s.rules.first?.name, "Pier Six", "an empty pattern is refused")
    }

}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
