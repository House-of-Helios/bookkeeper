import XCTest
@testable import BookkeeperCore

/// Mockup v3's category set: 14 spend + Everything else in a fixed ring order, a short
/// income list beside it, edits stored over defaults that stay in code.
final class CategoryBookTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-cats-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func test_theSpendRingIsTheFullSet() {
        let c = CategoryBook.defaults.categories
        XCTAssertEqual(c.map(\.id), ["groc", "eat", "cafe", "move", "heal", "fit", "fun", "trip", "edu", "pet", "shop",
                                     "wear", "house", "home", "util", "tax", "ins", "debt", "subs", "care", "gift", "fee",
                                     "cash", "else"])
        XCTAssertEqual(Set(c.map { $0.colorHex.uppercased() }).count, c.count, "no two categories share a colour")
        XCTAssertEqual(c.filter(\.fixed).map(\.id), ["home", "util", "tax", "ins", "debt"])
    }

    func test_incomeHasItsOwnList() {
        let i = CategoryBook.defaults.incomeCategories
        XCTAssertEqual(i.map(\.id), ["pay", "side", "int", "back", "oin"])
        XCTAssertEqual(i.map(\.name), ["Paycheck", "Side income", "Interest & dividends", "Refunds", "Other income"])
        XCTAssertEqual(i.map(\.icon), ["briefcase", "laptop", "chart_increasing", "counterclockwise_arrows_button",
                                       "money_bag"])
        XCTAssertEqual(CategoryBook.incomeFallbackId, "oin")
        XCTAssertTrue(Set(i.map(\.id)).isDisjoint(with: CategoryBook.defaults.categories.map(\.id)))
    }

    func test_incomeLinesGetAnIncomeCategoryAndStayOutOfSpend() throws {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try s.importCSV(text: "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
            + "CREDIT,03/02/2026,HALCYON LABS PAYROLL PPD ID: 9000000001,2860.00,ACH_CREDIT,100.00,\n"
            + "CREDIT,03/03/2026,ACME DIRECT DEP,100.00,ACH_CREDIT,100.00,\n"
            + "CREDIT,03/31/2026,INTEREST PAYMENT,1.25,ACH_CREDIT,100.00,\n"
            + "CREDIT,03/31/2026,BROKERAGE DIVIDEND,4.00,ACH_CREDIT,100.00,\n"
            + "CREDIT,04/01/2026,MOM BIRTHDAY,50.00,ACH_CREDIT,100.00,\n"
            + "DEBIT,04/02/2026,LITTLE OWL COFFEE,-5.00,DEBIT_CARD,100.00,\n",
                         accountId: a.id)
        func cat(_ raw: String) -> String? { s.transactions.first { $0.rawDescription == raw }?.effectiveCategoryId }
        XCTAssertEqual(cat("HALCYON LABS PAYROLL PPD ID: 9000000001"), "pay")
        XCTAssertEqual(cat("ACME DIRECT DEP"), "pay")
        XCTAssertEqual(cat("INTEREST PAYMENT"), "int")
        XCTAssertEqual(cat("BROKERAGE DIVIDEND"), "int")
        XCTAssertEqual(cat("MOM BIRTHDAY"), "oin")
        XCTAssertEqual(s.spend(byCategoryIn: nil, everyday: false).reduce(Decimal(0)) { $0 + $1.total }, 5,
                       "income never in spend totals")
        let income = s.income(byCategoryIn: nil)
        XCTAssertEqual(income.map(\.category.id), ["pay", "int", "oin"], "income list order")
        XCTAssertEqual(income.first?.total, Decimal(string: "2960"))

        // A refund the user calls income: kind income, category Refunds.
        let coffee = try XCTUnwrap(s.transactions.first { $0.rawDescription == "LITTLE OWL COFFEE" })
        s.apply(edit: TransactionEdit(categoryId: "back", kind: .income), to: coffee.id, scope: .justThisOne)
        XCTAssertEqual(cat("LITTLE OWL COFFEE"), "back")
        XCTAssertTrue(s.income(byCategoryIn: nil).contains { $0.category.id == "back" })
        // An income line with an id the book doesn't know folds into Other income.
        s.apply(edit: TransactionEdit(categoryId: "nope"), to: coffee.id, scope: .justThisOne)
        XCTAssertTrue(s.income(byCategoryIn: nil).contains { $0.category.id == "oin" && $0.count == 2 })
    }

    func test_aCategoryEditPersistsOverTheDefaults() throws {
        let s = SpendingStore(directory: dir)
        s.updateCategory("cafe", name: "Coffee", colorHex: "#F05E1C")
        s.updateCategory("back", icon: "receipt")
        s.updateCategory("no-such", name: "x")
        XCTAssertEqual(s.categories.category("cafe")?.name, "Coffee")
        XCTAssertEqual(s.categories.category("cafe")?.icon, "hot_beverage", "untouched fields keep the default")
        XCTAssertEqual(s.categories.category("back")?.icon, "receipt")

        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(reopened.categories, s.categories)
        XCTAssertEqual(reopened.categories.category("cafe")?.colorHex, "#F05E1C")

        // The file holds the edits, not a copy of the defaults.
        let json = try String(contentsOf: dir.appendingPathComponent("categories.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("Coffee"))
        XCTAssertFalse(json.contains("Groceries"), "defaults stay in code")
        XCTAssertFalse(json.contains("PAYMENT THANK YOU"), "unedited lists stay in code")
    }

    func test_aBookSavedBeforeCashGainsItInPlaceKeepingItsEdits() throws {
        // A categories.json from before Cash: an edit or two, no word of "cash".
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(##"{"edits":{"gift":{"name":"Giving","colorHex":"#123456"}}}"##.utf8)
            .write(to: dir.appendingPathComponent("categories.json"))
        let book = SpendingStore(directory: dir).categories
        XCTAssertEqual(Array(book.categories.map(\.id).suffix(2)), ["cash", "else"],
                       "Cash lands just before the fallback")
        XCTAssertEqual(book.category("cash")?.name, "Cash")
        XCTAssertEqual(book.category("cash")?.icon, "dollar_banknote")
        XCTAssertEqual(book.category("gift")?.name, "Giving", "the old edit survives")
        XCTAssertEqual(book.category("gift")?.colorHex, "#123456")
    }

    func test_aBookSavedBeforeTheSplitGainsUtilitiesAndKeepsARenamedHome() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(##"{"edits":{"home":{"name":"Housing","colorHex":"#654321"}}}"##.utf8)
            .write(to: dir.appendingPathComponent("categories.json"))
        let book = SpendingStore(directory: dir).categories
        let ids = book.categories.map(\.id)
        XCTAssertEqual(ids.firstIndex(of: "util"), ids.firstIndex(of: "home").map { $0 + 1 }, "util right after home")
        XCTAssertEqual(book.category("util")?.name, "Utilities")
        XCTAssertEqual(book.category("util")?.fixed, true)
        XCTAssertEqual(book.category("home")?.name, "Housing", "the old rename survives")
        XCTAssertEqual(book.category("home")?.colorHex, "#654321")
    }

    func test_billsGoToUtilitiesAndRentStaysHome() throws {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try s.importCSV(text: "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
            + "DEBIT,03/01/2026,BRIGHTSTONE PROPERTY MGMT RENT WEB ID: 9000000002,-2150.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/02/2026,FIRSTHOME MORTGAGE PMT,-1800.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/03/2026,CON ED OF NY INTELL CK,-88.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/04/2026,NATIONAL GRID NY UTILITYPAY,-61.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/05/2026,VERIZON WIRELESS PAYMENTS,-70.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/06/2026,AT&T BILL PAYMENT,-55.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/07/2026,T-MOBILE AUTO PAY,-50.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/08/2026,SPECTRUM CABLE,-80.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/09/2026,COMCAST XFINITY,-79.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/10/2026,OPTIMUM 7812,-65.00,ACH_DEBIT,100.00,\n"
            + "DEBIT,03/11/2026,NYC WATER BOARD,-40.00,ACH_DEBIT,100.00,\n",
                         accountId: a.id)
        func cat(_ fragment: String) -> String? {
            s.transactions.first { $0.rawDescription.contains(fragment) }?.effectiveCategoryId
        }
        XCTAssertEqual(cat("BRIGHTSTONE"), "home")
        XCTAssertEqual(cat("MORTGAGE"), "home")
        for bill in ["CON ED", "NATIONAL GRID", "VERIZON", "AT&T", "T-MOBILE", "SPECTRUM", "XFINITY", "OPTIMUM",
                     "WATER BOARD"] {
            XCTAssertEqual(cat(bill), "util", bill)
        }
        XCTAssertEqual(CategoryBook.defaults.categoryId(forBank: "Bills & Utilities"), "util")
        XCTAssertEqual(CategoryBook.defaults.categoryId(forBank: "Phone/Cable"), "util")
        XCTAssertEqual(CategoryBook.defaults.categoryId(forBank: "Utilities"), "util")
    }

    func test_aLedgerFromBeforeTheSplitReadsItsBillsAsUtilities() throws {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Chase", colorHex: "#D0104C")
        try s.importCSV(text: "Card,Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n"
            + "4417,03/02/2026,03/03/2026,HARBORVIEW BILLPAY,Bills & Utilities,Sale,-30.00,\n"
            + "4417,03/03/2026,03/04/2026,HARBORVIEW HOMEWARES,Home,Sale,-20.00,\n",
                         accountId: a.id)
        // Written the way the old build stored them: the bank default as `home`.
        let file = dir.appendingPathComponent("transactions.json")
        var rows = try JSONDecoder().decode([BankTransaction].self, from: Data(contentsOf: file))
        for i in rows.indices { rows[i].categoryId = "home" }
        try JSONEncoder().encode(rows).write(to: file)

        let reopened = SpendingStore(directory: dir)
        func cat(_ raw: String) -> String? { reopened.transactions.first { $0.rawDescription == raw }?.effectiveCategoryId }
        XCTAssertEqual(cat("HARBORVIEW BILLPAY"), "util")
        XCTAssertEqual(cat("HARBORVIEW HOMEWARES"), "house", "Chase's own Home is home goods, not rent")
    }

    func test_anATMWithdrawalIsCashSpendNamedATM() throws {
        let s = SpendingStore(directory: dir)
        let a = s.addAccount(name: "Chase checking", colorHex: "#0089A7")
        try s.importCSV(text: "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
            + "DEBIT,03/02/2026,ATM WITHDRAWAL 000417 7TH AVE BROOKLYN,-60.00,ATM,100.00,\n"
            + "DEBIT,03/03/2026,ATM WITHDRAWAL 000418 MARKET ST,-40.00,ATM,100.00,\n"
            + "DEBIT,03/04/2026,NON-CHASE CASH WITHDRAWAL 0099,-20.00,ATM,100.00,\n"
            + "CREDIT,03/05/2026,ATM CHECK DEPOSIT 0311,250.00,DEPOSIT,100.00,\n"
            + "DEBIT,03/06/2026,PATMOS DINER,-12.00,DEBIT_CARD,100.00,\n",
                         accountId: a.id)
        func row(_ fragment: String) throws -> BankTransaction {
            try XCTUnwrap(s.transactions.first { $0.rawDescription.contains(fragment) })
        }
        for fragment in ["7TH AVE", "MARKET ST", "CASH WITHDRAWAL"] {
            let t = try row(fragment)
            XCTAssertEqual(t.effectiveKind, .spend, fragment)
            XCTAssertEqual(t.effectiveCategoryId, "cash", fragment)
            XCTAssertEqual(t.merchantName, "ATM", fragment)
            XCTAssertFalse(t.needsReview, "\(fragment): not a question just for being ATM")
        }
        XCTAssertEqual(s.spend(byCategoryIn: nil, everyday: false).first { $0.category.id == "cash" }?.total, 120,
                       "a slice of the ring")
        // Money in at a machine is still income; ATM inside a word is no ATM.
        XCTAssertEqual(try row("CHECK DEPOSIT").effectiveKind, .income)
        XCTAssertNotEqual(try row("PATMOS").effectiveCategoryId, "cash")
    }

    func test_newBankCategoriesAndSeedRulesUseTheNewIds() throws {
        let s = SpendingStore(directory: dir)
        for f in ["chase_card", "citi", "capital_one", "discover", "apple_card"] {
            try s.importCSV(fileURL: BankFixtures.url(f), accountId: s.addAccount(name: f, colorHex: "#4A4A4A").id)
        }
        func cats(_ fragment: String) -> Set<String> {
            Set(s.transactions.filter { $0.rawDescription.contains(fragment) }.map(\.effectiveCategoryId))
        }
        XCTAssertEqual(cats("SMITH ST PHARMACY"), ["heal"])
        XCTAssertEqual(cats("IRONWORKS GYM"), ["fit"])
        let book = CategoryBook.defaults
        XCTAssertEqual(book.categoryId(forBank: "Health & Wellness"), "heal")
        XCTAssertEqual(book.categoryId(forBank: "Medical Services"), "heal")
        XCTAssertEqual(book.categoryId(forBank: "Lodging"), "trip")
        XCTAssertEqual(book.categoryId(forBank: "Airfare"), "trip")
        XCTAssertEqual(book.categoryId(forBank: "Personal"), "care")
        XCTAssertEqual(book.categoryId(forBank: "Gifts & Donations"), "gift")
        XCTAssertEqual(book.categoryId(forBank: "Travel/ Entertainment"), "fun")

        // Seed words reach the new categories — and an airline in Discover's mixed
        // "Travel/ Entertainment" bucket goes to Travel.
        let a = s.addAccount(name: "Discover 2", colorHex: "#4A4A4A")
        try s.importCSV(text: "Trans. Date,Post Date,Description,Amount,Category\n"
            + "05/01/2026,05/02/2026,SKYWARD AIRLINES 0061234,320.00,Travel/ Entertainment\n"
            + "05/02/2026,05/03/2026,HARBOR HOTEL BOSTON MA,210.00,Travel/ Entertainment\n"
            + "05/03/2026,05/04/2026,STARLIGHT CINEMA BKLYN,15.50,Travel/ Entertainment\n"
            + "05/04/2026,05/05/2026,SQ *BARBER NED,32.00,Services\n"
            + "05/05/2026,05/06/2026,LUNA NAIL SALON,40.00,Services\n"
            + "05/06/2026,05/07/2026,PETAL FLORIST,45.00,Merchandise\n"
            + "05/07/2026,05/08/2026,FOOD BANK DONATION,25.00,Services\n"
            + "05/08/2026,05/09/2026,GRAND ST DENTAL,120.00,Medical Services\n",
                         accountId: a.id)
        XCTAssertEqual(cats("SKYWARD AIRLINES"), ["trip"])
        XCTAssertEqual(cats("HARBOR HOTEL"), ["trip"])
        XCTAssertEqual(Set(s.transactions.filter { $0.accountId == a.id && $0.rawDescription.contains("STARLIGHT") }
            .map(\.effectiveCategoryId)), ["fun"])
        XCTAssertEqual(cats("BARBER NED"), ["care"])
        XCTAssertEqual(cats("NAIL SALON"), ["care"])
        XCTAssertEqual(cats("PETAL FLORIST"), ["gift"])
        XCTAssertEqual(cats("FOOD BANK DONATION"), ["gift"])
        XCTAssertEqual(cats("GRAND ST DENTAL"), ["heal"])
    }
}
