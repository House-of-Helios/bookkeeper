import XCTest
@testable import BookkeeperCore

/// Stage 3 through the store: the edit drawer's two scopes, rule persistence and
/// resolution, the seed rules shipped in code, the to-review queue and the imports log.
final class MerchantRulesTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-rules-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func store() -> SpendingStore { SpendingStore(directory: dir) }

    @discardableResult
    private func load(_ s: SpendingStore, _ fixture: String, into account: String) throws -> ImportSummary {
        try s.importCSV(fileURL: BankFixtures.url(fixture), accountId: account)
    }

    private func chase() throws -> (SpendingStore, BankAccount) {
        let s = store()
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C")
        try load(s, "chase_card", into: card.id)
        return (s, card)
    }

    private static let kaleVariants: Set<String> = [
        "MR KALE BROOKLYN NY 0042 POS", "SQ *MR KALE BKLYN", "MR. KALE #2 BROOKLYN NY",
    ]
    private static let decoy = "MR KALEIDOSCOPE TOYS BKLYN"
    private static let chaseHeader = "Card,Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n"
    private static let checkingHeader = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"

    private func kaleLines(_ s: SpendingStore) -> [BankTransaction] {
        s.transactions.filter { Self.kaleVariants.contains($0.rawDescription) }
    }

    // MARK: - The drawer: preview

    /// Zelle both ways with the same person, plus another person: a rule made on money in
    /// from Jane keeps to money in from Jane.
    private func zelle() throws -> SpendingStore {
        let s = store()
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.checkingHeader
            + "CREDIT,10/02/2026,Zelle payment from JANE ROE 1234567,120.00,QUICKPAY_CREDIT,100.00,\n"
            + "CREDIT,10/09/2026,Zelle payment from JANE ROE 2234567,80.00,QUICKPAY_CREDIT,100.00,\n"
            + "DEBIT,10/04/2026,Zelle payment to JANE ROE 7654321,-45.00,QUICKPAY_DEBIT,100.00,\n"
            + "CREDIT,10/05/2026,Zelle payment from SAM LEE 3334567,60.00,QUICKPAY_CREDIT,100.00,\n",
                        accountId: a.id)
        return s
    }

    func test_aPaymentLineKeepsThePersonInItsCore() {
        XCTAssertEqual(MerchantCore.core("Zelle payment from JANE ROE 1234567"), "JANE ROE")
        XCTAssertEqual(MerchantCore.core("ZELLE FROM JANE ROE ON 10/02 REF # BAC0abc"), "JANE ROE")
        XCTAssertEqual(MerchantCore.core("MR KALE BROOKLYN NY 0042 POS"), "MR KALE", "a shop's core is unchanged")
    }

    func test_allLikeThisOnMoneyInLeavesMoneyOutAlone() throws {
        let s = try zelle()
        let inLine = try XCTUnwrap(s.transactions.first { $0.amount == 120 })
        let p = try XCTUnwrap(s.editPreview(inLine.id))
        XCTAssertEqual(p.direction, .moneyIn)
        XCTAssertEqual(Set(p.likeThis.map(\.amount)), [120, 80], "Jane's money in, not her money out, not Sam")

        s.apply(edit: TransactionEdit(name: "Jane rent share", categoryId: CategoryBook.incomeFallbackId, kind: .income),
                to: inLine.id, scope: .allLikeThis(pattern: p.core, match: .contains, unticked: [], direction: p.direction))
        let out = try XCTUnwrap(s.transactions.first { $0.amount == -45 })
        XCTAssertNotEqual(out.displayName, "Jane rent share", "money out to Jane keeps its own name")
        XCTAssertEqual(s.transactions.filter { $0.displayName == "Jane rent share" }.count, 2)
        XCTAssertEqual(s.rules.first?.direction, .moneyIn)

        // A rule from before directions (no key in merchants.json) still reads, either way.
        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.rules.first?.direction, .moneyIn, "the direction is saved")
        let old = try JSONDecoder().decode(MerchantRule.self, from: Data(#"{"id":"x","match":"contains","pattern":"MR KALE","excludedTransactionIds":[],"createdAt":0}"#.utf8))
        XCTAssertNil(old.direction)
        XCTAssertTrue(old.allows(-5) && old.allows(5))
    }

    /// Money in starts as "Other income". Picking Paycheck (the kind already Income, so only
    /// the category changes) must move it — one line, and every line like it.
    func test_movingMoneyInToAnotherKindOfIncomeSticks() throws {
        let s = try zelle()
        let jane = try XCTUnwrap(s.transactions.first { $0.amount == 120 })
        XCTAssertEqual(jane.effectiveKind, .income)
        XCTAssertEqual(jane.effectiveCategoryId, CategoryBook.incomeFallbackId)
        let p = try XCTUnwrap(s.editPreview(jane.id))
        s.apply(edit: TransactionEdit(name: nil, categoryId: "pay", kind: nil), to: jane.id,
                scope: .allLikeThis(pattern: p.core, match: .contains, unticked: [], direction: p.direction))
        XCTAssertEqual(Set(s.transactions.filter { $0.effectiveCategoryId == "pay" }.map(\.amount)), [120, 80])
        XCTAssertEqual(s.income(byCategoryIn: nil).first { $0.category.id == "pay" }?.count, 2)

        let sam = try XCTUnwrap(s.transactions.first { $0.amount == 60 })
        s.apply(edit: TransactionEdit(name: nil, categoryId: "back", kind: nil), to: sam.id, scope: .justThisOne)
        XCTAssertEqual(s.transactions.first { $0.id == sam.id }?.effectiveCategoryId, "back")
    }

    func test_eachPersonIsTheirOwnRuleWhateverTheBanksWording() {
        // Chase, Bank of America, Wells Fargo, Capital One.
        XCTAssertEqual(MerchantCore.core("Zelle Payment To Jane Roe Jpm99c0xyz"), "JANE ROE")
        XCTAssertEqual(MerchantCore.core("Zelle payment from JANE ROE Conf# abc123"), "JANE ROE")
        XCTAssertEqual(MerchantCore.core("ZELLE TO ROE JANE ON 10/02 REF # PP0XYZ"), "ROE JANE")
        XCTAssertEqual(MerchantCore.core("Zelle money received from Jane A Roe"), "JANE A ROE")
        XCTAssertEqual(MerchantCore.core("Zelle money sent to Sam Lee"), "SAM LEE")
        XCTAssertEqual(MerchantCore.core("Zelle Transfer Conf# 9xk2; Smith, Ann"), "SMITH ANN")
        XCTAssertEqual(MerchantCore.core("Online Transfer to Sam Lee via Zelle"), "SAM LEE")
        XCTAssertEqual(MerchantCore.core("VENMO PAYMENT 1029384"), "VENMO PAYMENT", "no person named")
    }

    func test_aRuleOnMoneyToOnePersonLeavesOthersAlone() throws {
        let s = store()
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.checkingHeader
            + "DEBIT,10/02/2026,Zelle money sent to Sam Lee,-20.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/09/2026,Zelle money sent to Sam Lee,-25.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/04/2026,Zelle money sent to Sam Leeds,-45.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/05/2026,Zelle money sent to Ann Ito,-60.00,QUICKPAY_DEBIT,100.00,\n",
                        accountId: a.id)
        let sam = try XCTUnwrap(s.transactions.first { $0.amount == -20 })
        let p = try XCTUnwrap(s.editPreview(sam.id))
        XCTAssertEqual(p.direction, .moneyOut)
        XCTAssertEqual(Set(p.likeThis.map(\.amount)), [-20, -25], "only money to Sam Lee")
    }

    func test_aNameAtTheEndOfTheLineStillMakesItsOwnRule() throws {
        let s = store()
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.checkingHeader
            + "DEBIT,10/02/2026,\"Zelle Transfer Conf# 9xk2; Smith, Ann\",-20.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/09/2026,\"Zelle Transfer Conf# 7pq1; Smith, Ann\",-25.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/04/2026,\"Zelle Transfer Conf# 3zz8; Ito, Ken\",-45.00,QUICKPAY_DEBIT,100.00,\n"
            + "CREDIT,10/05/2026,\"Zelle Transfer Conf# 1aa1; Smith, Ann\",60.00,QUICKPAY_CREDIT,100.00,\n",
                        accountId: a.id)
        let ann = try XCTUnwrap(s.transactions.first { $0.amount == -20 })
        let p = try XCTUnwrap(s.editPreview(ann.id))
        XCTAssertEqual(p.core, "SMITH ANN")
        XCTAssertEqual(Set(p.likeThis.map(\.amount)), [-20, -25], "only money out to Ann Smith")
    }

    /// Both names on every line — the account holder's and the other person's — so the
    /// rule is on the other person, chosen by which way the money went.
    func test_aLineNamingBothPartiesIsAboutTheOtherOne() throws {
        let s = store()
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        func line(_ date: String, _ text: String, _ amount: String) -> String {
            let q = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return "\(amount.hasPrefix("-") ? "DEBIT" : "CREDIT"),\(date),\(q),\(amount),QUICKPAY,100.00,\n"
        }
        var csv = Self.checkingHeader
        for d in 1...6 { csv += line("10/0\(d)/2026", "Zelle payment from ALEX MORGAN \"Everyday Checking\" to FRED LEE", "-\(d)0.00") }
        csv += line("10/07/2026", "Zelle payment from ALEX MORGAN \"Everyday Checking\" to ANN ITO", "-70.00")
        csv += line("10/08/2026", "Zelle payment from ALEX MORGAN \"Everyday Checking\" to ANN ITO", "-80.00")
        csv += line("10/09/2026", "Zelle payment from FRED LEE to ALEX MORGAN \"Everyday Checking\"", "90.00")
        try s.importCSV(text: csv, accountId: a.id)
        XCTAssertEqual(s.transactions.count, 9)

        let toFred = try XCTUnwrap(s.transactions.first { $0.amount == -10 })
        let p = try XCTUnwrap(s.editPreview(toFred.id))
        XCTAssertEqual(p.core, "FRED LEE")
        XCTAssertEqual(p.likeThis.count, 6, "money to Fred — not to Ann, not from Fred")

        let fromFred = try XCTUnwrap(s.transactions.first { $0.amount == 90 })
        let q = try XCTUnwrap(s.editPreview(fromFred.id))
        XCTAssertEqual(q.core, "FRED LEE")
        XCTAssertEqual(q.likeThis.map(\.amount), [90], "money from Fred only")
        XCTAssertEqual(MerchantCore.suggestedName("Zelle payment from ALEX MORGAN \"Everyday Checking\" to ANN ITO", amount: -1), "Ann Ito")
    }

    func test_taxPaymentsLandInTaxesSetAsideLikeRent() throws {
        let s = store()
        let a = s.addAccount(name: "Checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.checkingHeader
            + "DEBIT,04/14/2026,IRS USATAXPYMT 270612345,-4200.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,04/15/2026,NYS DTF PIT TAX PAYMENT,-900.00,ACH_DEBIT,100.00,\n",
                        accountId: a.id)
        XCTAssertEqual(Set(s.transactions.map(\.effectiveCategoryId)), ["tax"])
        XCTAssertEqual(s.categories.category("tax")?.fixed, true, "kept out of Spending, counted in Total")
    }

    func test_aShopsRuleStillCoversRefunds() throws {
        let (s, _) = try chase()
        let line = try XCTUnwrap(kaleLines(s).first)
        XCTAssertNil(try XCTUnwrap(s.editPreview(line.id)).direction, "not a payment app: either way, as before")
    }

    func test_editPreviewOffersTheCoreAndEveryLineLikeIt() throws {
        let (s, _) = try chase()
        let kale = kaleLines(s)
        XCTAssertEqual(Set(kale.map(\.rawDescription)), Self.kaleVariants, "the fixture holds all three spellings")
        XCTAssertTrue(s.transactions.contains { $0.rawDescription == Self.decoy })

        let line = try XCTUnwrap(kale.first { $0.rawDescription == "MR KALE BROOKLYN NY 0042 POS" })
        let preview = try XCTUnwrap(s.editPreview(line.id))
        XCTAssertEqual(preview.core, "MR KALE")
        XCTAssertEqual(preview.suggestedName, "Mr Kale")
        XCTAssertEqual(preview.match, .contains)
        XCTAssertEqual(Set(preview.likeThis.map(\.id)), Set(kale.map(\.id)), "all three spellings, nothing else")
        XCTAssertFalse(preview.likeThis.contains { $0.rawDescription == Self.decoy }, "Kaleidoscope isn't like this")
        XCTAssertEqual(s.matches(for: "MR KALE", match: .contains).map(\.id), preview.likeThis.map(\.id))
        XCTAssertNil(s.editPreview("no-such-id"))
    }

    // MARK: - All like this

    func test_oneAllLikeThisEditFoldsThreeSpellingsIntoOneMerchant() throws {
        let (s, _) = try chase()
        let kale = kaleLines(s)
        let line = try XCTUnwrap(kale.first { $0.rawDescription == "SQ *MR KALE BKLYN" })
        let unticked = try XCTUnwrap(kale.first { $0.rawDescription == "MR. KALE #2 BROOKLYN NY" })
        let decoy = try XCTUnwrap(s.transactions.first { $0.rawDescription == Self.decoy })

        let changed = s.apply(edit: TransactionEdit(name: "Mr. Kale", categoryId: "groc", kind: .spend),
                              to: line.id,
                              scope: .allLikeThis(pattern: "MR KALE", match: .contains, unticked: [unticked.id]))
        XCTAssertEqual(changed, kale.count - 1, "every ticked line")
        XCTAssertEqual(s.rules.count, 1, "one rule")
        XCTAssertEqual(s.rules[0].excludedTransactionIds, [unticked.id])

        for t in kale where t.id != unticked.id {
            let now = try XCTUnwrap(s.transactions.first { $0.id == t.id })
            XCTAssertEqual(now.displayName, "Mr. Kale", t.rawDescription)
            XCTAssertEqual(now.effectiveCategoryId, "groc", t.rawDescription)
            XCTAssertEqual(now.rawDescription, t.rawDescription, "raw text never edited")
            XCTAssertNil(now.override, "a rule, not a pile of spot edits")
        }
        let left = try XCTUnwrap(s.transactions.first { $0.id == unticked.id })
        XCTAssertEqual(left.displayName, "MR. KALE #2 BROOKLYN NY", "the unticked line stays out")
        XCTAssertEqual(left.effectiveCategoryId, "eat")
        let toy = try XCTUnwrap(s.transactions.first { $0.id == decoy.id })
        XCTAssertEqual(toy.displayName, Self.decoy, "Kaleidoscope untouched")
        XCTAssertEqual(toy.effectiveCategoryId, "shop")

        let groc = s.merchants(in: "groc", range: nil)
        let merchant = try XCTUnwrap(groc.first { $0.name == "Mr. Kale" })
        XCTAssertEqual(merchant.count, kale.count - 1, "one merchant on the leaderboard")
        XCTAssertFalse(s.merchants(in: "eat", range: nil).contains { $0.name == "Mr. Kale" })

        // merchants.json holds it, and a reopen resolves the same way.
        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.rules, s.rules)
        XCTAssertEqual(reopened.transactions, s.transactions)
        let url = dir.appendingPathComponent("merchants.json")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }

    func test_aLaterImportOfTheMerchantResolvesWithNoPrompt() throws {
        let (s, card) = try chase()
        let line = try XCTUnwrap(kaleLines(s).first)
        s.apply(edit: TransactionEdit(name: "Mr. Kale", categoryId: "groc", kind: .spend), to: line.id,
                scope: .allLikeThis(pattern: "MR KALE", match: .contains, unticked: []))

        let summary = try s.importCSV(text: Self.chaseHeader
            + "4417,11/02/2026,11/03/2026,MR KALE BROOKLYN NY 0042 POS,Food & Drink,Sale,-15.10,\n"
            + "4417,11/03/2026,11/04/2026,PURCHASE AUTHORIZED ON 11/03 MR. KALE #7 BKLYN,Food & Drink,Sale,-12.00,\n"
            + "4417,11/04/2026,11/05/2026,MR KALEIDOSCOPE TOYS BKLYN,Shopping,Sale,-30.00,\n",
                                      accountId: card.id)
        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.toReview, 0, "no prompt")
        let fresh = s.transactions.filter { $0.date >= Day(2026, 11, 2) }
        let kale = fresh.filter { $0.rawDescription != Self.decoy }
        XCTAssertEqual(kale.count, 2)
        XCTAssertTrue(kale.allSatisfy { $0.displayName == "Mr. Kale" && $0.effectiveCategoryId == "groc" })
        XCTAssertTrue(kale.allSatisfy { !$0.needsReview })
        let toy = try XCTUnwrap(fresh.first { $0.rawDescription == Self.decoy })
        XCTAssertEqual(toy.displayName, Self.decoy)
    }

    func test_editingTheRuleAgainUpdatesItAndReticksALine() throws {
        let (s, _) = try chase()
        let kale = kaleLines(s)
        let off = kale[1]
        s.apply(edit: TransactionEdit(name: "Mr. Kale", categoryId: "groc", kind: .spend), to: kale[0].id,
                scope: .allLikeThis(pattern: "MR KALE", match: .contains, unticked: [off.id]))
        XCTAssertNotEqual(s.transactions.first { $0.id == off.id }?.displayName, "Mr. Kale")

        // Same pattern from another line: the rule is updated, not doubled, and the
        // line ticked this time comes back in.
        let changed = s.apply(edit: TransactionEdit(name: "Mr Kale Salads", categoryId: "eat", kind: .spend),
                              to: kale[2].id,
                              scope: .allLikeThis(pattern: "mr. kale", match: .contains, unticked: []))
        XCTAssertEqual(changed, kale.count)
        XCTAssertEqual(s.rules.count, 1)
        XCTAssertEqual(s.rules[0].excludedTransactionIds, [])
        XCTAssertTrue(kaleLines(s).allSatisfy { $0.displayName == "Mr Kale Salads" && $0.effectiveCategoryId == "eat" })
    }

    func test_anAllLikeThisEditCanMakeLinesInternalTransfers() throws {
        let s = store()
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try load(s, "chase_checking", into: a.id)
        let atm = s.transactions.filter { $0.rawDescription.hasPrefix("ATM WITHDRAWAL") }
        let spendBefore = s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }
        let changed = s.apply(edit: TransactionEdit(name: "Cash", kind: .transfer), to: atm[0].id,
                              scope: .allLikeThis(pattern: "ATM WITHDRAWAL", match: .startsWith, unticked: []))
        XCTAssertEqual(changed, atm.count)
        let spendAfter = s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }
        XCTAssertEqual(spendAfter, spendBefore + atm.reduce(Decimal(0)) { $0 + $1.amount })
        XCTAssertTrue(s.transactions(TransactionFilter(kind: .transfer)).contains { $0.id == atm[0].id })
        XCTAssertEqual(s.transactions.first { $0.id == atm[0].id }?.kind, .spend, "the stored default is left alone")
    }

    // MARK: - Just this one

    func test_aJustThisOneEditBeatsARule() throws {
        let (s, _) = try chase()
        let kale = kaleLines(s)
        s.apply(edit: TransactionEdit(name: "Mr. Kale", categoryId: "groc", kind: .spend), to: kale[0].id,
                scope: .allLikeThis(pattern: "MR KALE", match: .contains, unticked: []))
        let one = kale[3]
        XCTAssertEqual(s.apply(edit: TransactionEdit(name: "Kale with R", categoryId: "eat"), to: one.id,
                               scope: .justThisOne), 1)
        let edited = try XCTUnwrap(s.transactions.first { $0.id == one.id })
        XCTAssertEqual(edited.displayName, "Kale with R")
        XCTAssertEqual(edited.effectiveCategoryId, "eat")
        XCTAssertEqual(edited.effectiveKind, .spend)
        XCTAssertEqual(kaleLines(s).filter { $0.displayName == "Mr. Kale" }.count, kale.count - 1, "the others keep the rule")

        // Undo seams.
        s.clearOverride(one.id)
        XCTAssertEqual(s.transactions.first { $0.id == one.id }?.displayName, "Mr. Kale")
        s.removeRule(s.rules[0].id)
        XCTAssertTrue(s.rules.isEmpty)
        XCTAssertTrue(kaleLines(s).allSatisfy { Self.kaleVariants.contains($0.displayName) && $0.effectiveCategoryId == "eat" },
                      "back to the bank's own")
        XCTAssertTrue(SpendingStore(directory: dir).rules.isEmpty)
    }

    func test_aJustThisOneEditMergesFieldsIntoTheOverride() throws {
        let (s, _) = try chase()
        let one = try XCTUnwrap(kaleLines(s).first)
        s.apply(edit: TransactionEdit(name: "Kale"), to: one.id, scope: .justThisOne)
        s.apply(edit: TransactionEdit(categoryId: "groc"), to: one.id, scope: .justThisOne)
        XCTAssertEqual(s.transactions.first { $0.id == one.id }?.override,
                       TransactionOverride(name: "Kale", categoryId: "groc"))
        XCTAssertTrue(s.rules.isEmpty, "just this one never makes a rule")
        XCTAssertEqual(s.apply(edit: TransactionEdit(name: "x"), to: "no-such-id", scope: .justThisOne), 0)
    }

    // MARK: - Seed rules and the narrowed transfer list

    func test_rentLandsInRentAndUtilitiesFromEveryCheckingFile() throws {
        let s = store()
        for f in ["chase_checking", "bank_of_america_checking", "wells_fargo"] {
            try load(s, f, into: s.addAccount(name: f, colorHex: "#4A4A4A").id)
        }
        let rent = s.transactions.filter { $0.rawDescription.contains("PROPERTY MGMT RENT") }
        XCTAssertEqual(Set(rent.map(\.accountId)).count, 3)
        XCTAssertEqual(rent.count, 3 * 18)
        XCTAssertTrue(rent.allSatisfy { $0.effectiveKind == .spend && $0.effectiveCategoryId == "home" })
        XCTAssertTrue(s.rules.isEmpty, "seed rules live in code, not in merchants.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("merchants.json").path))
    }

    func test_seedRulesCategoriseCafesGroceriesAndBills() throws {
        let s = store()
        let wells = s.addAccount(name: "Wells", colorHex: "#4A4A4A")
        try load(s, "wells_fargo", into: wells.id)
        let chase = s.addAccount(name: "Chase", colorHex: "#4A4A4A")
        try load(s, "chase_card", into: chase.id)
        func cats(_ fragment: String) -> Set<String> {
            Set(s.transactions.filter { $0.rawDescription.contains(fragment) }.map(\.effectiveCategoryId))
        }
        // Cafés: nothing seeded them before — banks lump them into dining.
        XCTAssertEqual(cats("GOWANUS GRIND COFFEE"), ["cafe"])
        XCTAssertEqual(cats("LANTERN BEAN CAFE"), ["cafe"])
        // Groceries, even with no bank category (Wells is headerless).
        XCTAssertEqual(cats("PROSPECT GREENS MARKET"), ["groc"])
        XCTAssertEqual(cats("HALSEY STREET GROCERS"), ["groc"])
        XCTAssertEqual(cats("CORNER CO-OP"), ["groc"])
        // Bills.
        XCTAssertEqual(cats("BRIGHTLINE FIBER INTERNET"), ["util"])
        // Conservative: a deli the bank calls dining stays dining; unknowns stay put.
        XCTAssertEqual(Set(s.transactions.filter { $0.accountId == chase.id && $0.rawDescription.contains("BODEGA MOON DELI") }
            .map(\.effectiveCategoryId)), ["eat"])
        XCTAssertEqual(cats("MR KALEIDOSCOPE TOYS"), ["shop"])
        XCTAssertEqual(cats("ATLANTIC TAQUERIA").subtracting(["eat"]), ["else"], "Wells has no category; no seed guesses")
    }

    func test_aUserRuleBeatsASeedRule() throws {
        let (s, _) = try chase()
        let coffee = try XCTUnwrap(s.transactions.first { $0.rawDescription.hasPrefix("GOWANUS GRIND") })
        XCTAssertEqual(coffee.effectiveCategoryId, "cafe")
        s.apply(edit: TransactionEdit(name: "Gowanus Grind", categoryId: "eat"), to: coffee.id,
                scope: .allLikeThis(pattern: "GOWANUS GRIND", match: .contains, unticked: []))
        XCTAssertTrue(s.transactions.filter { $0.rawDescription.hasPrefix("GOWANUS GRIND") }
            .allSatisfy { $0.effectiveCategoryId == "eat" && $0.displayName == "Gowanus Grind" })
        // A rule that only renames still lets the seed category through.
        s.removeRule(s.rules[0].id)
        s.apply(edit: TransactionEdit(name: "Gowanus"), to: coffee.id,
                scope: .allLikeThis(pattern: "GOWANUS", match: .contains, unticked: []))
        XCTAssertEqual(s.transactions.first { $0.id == coffee.id }?.effectiveCategoryId, "cafe")
    }

    func test_anAutopayUtilityIsSpendAndCardPaymentsAreTransfers() throws {
        let s = store()
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try s.importCSV(text: Self.checkingHeader
            + "DEBIT,03/02/2026,CITY POWER LIGHT AUTOPAY,-88.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/03/2026,EASTRIVER POWER CO BILLPAY,-71.25,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/04/2026,PIGEON MOBILE WIRELESS AUTOPAY,-45.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/05/2026,ASHFORD MGMT ACH RENT,-2150.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/06/2026,CHASE CARD PAYMENT THANK YOU,-1840.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/07/2026,DISCOVER AUTOMATIC PAYMENT,-310.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/08/2026,AMEX AUTOPAY PAYMENT,-200.00,ACH_DEBIT,100.00,\n"
            + "CREDIT,03/09/2026,ONLINE TRANSFER FROM SAV 4471,500.00,ACCT_XFER,100.00,\n"
            + "DEBIT,03/10/2026,CITI CARD PAYMENT,-90.00,ACH_DEBIT,100.00,\n",
                         accountId: a.id)
        func line(_ raw: String) throws -> BankTransaction {
            try XCTUnwrap(s.transactions.first { $0.rawDescription == raw }, raw)
        }
        for raw in ["CITY POWER LIGHT AUTOPAY", "EASTRIVER POWER CO BILLPAY", "PIGEON MOBILE WIRELESS AUTOPAY"] {
            XCTAssertEqual(try line(raw).effectiveKind, .spend, raw)
            XCTAssertEqual(try line(raw).effectiveCategoryId, "util", raw)
        }
        XCTAssertEqual(try line("ASHFORD MGMT ACH RENT").effectiveKind, .spend)
        XCTAssertEqual(try line("ASHFORD MGMT ACH RENT").effectiveCategoryId, "home")
        for raw in ["CHASE CARD PAYMENT THANK YOU", "DISCOVER AUTOMATIC PAYMENT", "AMEX AUTOPAY PAYMENT",
                    "ONLINE TRANSFER FROM SAV 4471", "CITI CARD PAYMENT"] {
            XCTAssertEqual(try line(raw).effectiveKind, .transfer, raw)
        }
        XCTAssertFalse(CategoryBook.defaults.transferPatterns.contains("AUTOPAY"), "bare AUTOPAY is a bill, not a transfer")
    }

    // MARK: - To review

    func test_transferishSpendGoesToReviewUncategorised() throws {
        let s = store()
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        let summary = try s.importCSV(text: Self.checkingHeader
            + "DEBIT,10/09/2026,ZELLE TO J RIVERA 8812,-60.00,QUICKPAY_DEBIT,100.00,\n"
            + "DEBIT,10/10/2026,VENMO PAYMENT 1029384,-25.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,10/11/2026,CASH APP*R QUILL,-40.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,10/16/2026,ONLINE TRANSFER TO SAV 4471,-500.00,ACCT_XFER,100.00,\n"
            + "DEBIT,10/17/2026,LITTLE OWL COFFEE 02,-5.80,DEBIT_CARD,100.00,\n",
                                      accountId: a.id)
        XCTAssertEqual(summary.toReview, 3)
        let queue = s.reviewQueue()
        XCTAssertEqual(Set(queue.map(\.rawDescription)),
                       ["ZELLE TO J RIVERA 8812", "VENMO PAYMENT 1029384", "CASH APP*R QUILL"])
        XCTAssertTrue(queue.allSatisfy { $0.toReview && $0.categoryId == nil && $0.effectiveCategoryId == "else" },
                      "not silently categorised")
        XCTAssertEqual(s.transactions(TransactionFilter(needsReview: true)).map(\.id), queue.map(\.id))
        XCTAssertEqual(s.transactions.first { $0.rawDescription.hasPrefix("ONLINE TRANSFER") }?.effectiveKind, .transfer,
                       "a confident transfer needs no review")

        // Teach Zelle-to-Rivera as an internal transfer: it leaves the queue, and the next
        // one arrives already answered.
        let zelle = try XCTUnwrap(queue.first { $0.rawDescription.hasPrefix("ZELLE") })
        let preview = try XCTUnwrap(s.editPreview(zelle.id))
        XCTAssertEqual(preview.core, "J RIVERA")
        s.apply(edit: TransactionEdit(name: "To J. Rivera", kind: .transfer), to: zelle.id,
                scope: .allLikeThis(pattern: "ZELLE TO J RIVERA", match: .contains, unticked: []))
        XCTAssertEqual(s.reviewQueue().count, 2)
        let venmo = try XCTUnwrap(s.reviewQueue().first { $0.rawDescription.hasPrefix("VENMO") })
        s.apply(edit: TransactionEdit(categoryId: "eat"), to: venmo.id, scope: .justThisOne)
        XCTAssertEqual(s.reviewQueue().count, 1, "a spot edit answers it too")

        let next = try s.importCSV(text: Self.checkingHeader
            + "DEBIT,11/09/2026,ZELLE TO J RIVERA 8812,-60.00,QUICKPAY_DEBIT,100.00,\n", accountId: a.id)
        XCTAssertEqual(next.toReview, 0)
        let fresh = try XCTUnwrap(s.transactions.first { $0.date == Day(2026, 11, 9) })
        XCTAssertEqual(fresh.effectiveKind, .transfer)
        XCTAssertEqual(fresh.displayName, "To J. Rivera")
        XCTAssertFalse(fresh.needsReview)

        // markReviewed clears it too, and it survives a reopen.
        let cash = try XCTUnwrap(s.reviewQueue().first)
        s.markReviewed(cash.id)
        XCTAssertTrue(s.reviewQueue().isEmpty)
        XCTAssertTrue(SpendingStore(directory: dir).reviewQueue().isEmpty)
    }

    func test_noFixtureLineLandsInReviewByAccident() throws {
        let s = store()
        for f in ["chase_card", "chase_checking", "bank_of_america_checking", "wells_fargo",
                  "capital_one", "amex", "citi", "discover", "apple_card"] {
            XCTAssertEqual(try load(s, f, into: s.addAccount(name: f, colorHex: "#4A4A4A").id).toReview, 0, f)
        }
        XCTAssertTrue(s.reviewQueue().isEmpty)
    }

    // MARK: - imports.json

    func test_everyDropIsLoggedWithCountsOnly() throws {
        let s = store()
        let card = s.addAccount(name: "Chase", colorHex: "#D0104C")
        let first = try load(s, "chase_card_2026-01_to_2026-03", into: card.id)
        let second = try load(s, "chase_card_2026-02_to_2026-04", into: card.id)

        XCTAssertEqual(s.imports.count, 2)
        let log = s.imports[1]
        XCTAssertEqual(log.importId, second.importId)
        XCTAssertEqual(log.fileName, "chase_card_2026-02_to_2026-04.csv")
        XCTAssertEqual(log.accountId, card.id)
        XCTAssertEqual(log.recipeId, second.recipeId)
        XCTAssertEqual(log.added, 57)
        XCTAssertEqual(log.alreadyHere, 115)
        XCTAssertEqual(log.toReview, 0)
        XCTAssertEqual(s.imports[0].importId, first.importId)

        try s.importCSV(text: Self.chaseHeader + "4417,11/02/2026,11/03/2026,TINY FIG,Food & Drink,Sale,-15.10,\n",
                        accountId: card.id)
        XCTAssertNil(s.imports[2].fileName, "a pasted text has no file name")

        XCTAssertEqual(SpendingStore(directory: dir).imports, s.imports)
        let url = dir.appendingPathComponent("imports.json")
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("KALE") || json.contains("GOWANUS") || json.contains("TINY FIG"),
                       "counts only, no bank content")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
}
