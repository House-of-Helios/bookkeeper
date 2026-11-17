import XCTest
@testable import BookkeeperCore

final class DayTests: XCTestCase {

    func test_formatsReadWithoutATimeZone() {
        XCTAssertEqual(Day.parse("02/12/2026", format: "MM/dd/yyyy"), Day(2026, 2, 12))
        XCTAssertEqual(Day.parse("2026-02-12", format: "yyyy-MM-dd"), Day(2026, 2, 12))
        XCTAssertEqual(Day.parse("2/3/26", format: "MM/dd/yy"), Day(2026, 2, 3))
        XCTAssertNil(Day.parse("02/30/2026", format: "MM/dd/yyyy"), "no 30 February")
        XCTAssertNil(Day.parse("Date", format: "MM/dd/yyyy"))
    }

    func test_storedAsIsoText() throws {
        let data = try JSONEncoder().encode([Day(2026, 2, 12)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"2026-02-12\"]")
        XCTAssertEqual(try JSONDecoder().decode([Day].self, from: data), [Day(2026, 2, 12)])
    }

    func test_dayArithmeticCrossesMonthsAndLeapDays() {
        XCTAssertEqual(Day(2024, 3, 1).adding(days: -1), Day(2024, 2, 29))
        XCTAssertEqual(Day(2026, 1, 1).days(since: Day(2025, 12, 30)), 2)
    }
}

final class BankAmountTests: XCTestCase {

    func test_bankAmountSpellings() {
        XCTAssertEqual(BankAmount.parse("-4.50"), Decimal(string: "-4.5"))
        XCTAssertEqual(BankAmount.parse("-1,204.18"), Decimal(string: "-1204.18"))
        XCTAssertEqual(BankAmount.parse("$12.00"), 12)
        XCTAssertEqual(BankAmount.parse("(12.00)"), -12)
        XCTAssertEqual(BankAmount.parse("+3"), 3)
        XCTAssertNil(BankAmount.parse(""))
        XCTAssertNil(BankAmount.parse("Amount"))
    }
}

/// Every built-in recipe against the synthetic export of its bank: the right recipe is
/// picked by shape alone, every row parses, and the sign comes out as money-out-negative
/// whatever the bank did.
final class BuiltInRecipeTests: XCTestCase {

    private func parse(_ fixture: String) throws -> (ImportRecipe, ParsedFile) {
        let text = try BankFixtures.text(fixture)
        let recipe = try XCTUnwrap(RecipeMatcher.match(text), "no recipe for \(fixture)")
        return (recipe, recipe.parse(text: text))
    }

    func test_eachFixtureFindsItsBank() throws {
        let expected = ["chase_card": "chase-card", "chase_checking": "chase-checking",
                        "bank_of_america_checking": "bofa-checking", "wells_fargo": "wells-fargo",
                        "capital_one": "capital-one", "amex": "amex", "citi": "citi",
                        "discover": "discover", "apple_card": "apple-card",
                        "chase_card_2026-01_to_2026-03": "chase-card",
                        "chase_card_2026-02_to_2026-04": "chase-card",
                        "chase_card_quoted_commas": "chase-card"]
        XCTAssertEqual(Set(expected.keys), Set(BankFixtures.all))
        for (fixture, id) in expected {
            XCTAssertEqual(try parse(fixture).0.id, id, fixture)
        }
        XCTAssertEqual(BuiltInRecipes.all.count, 9)
    }

    func test_everyDataRowParses() throws {
        let rows = ["chase_card": 1017, "chase_checking": 283, "bank_of_america_checking": 481,
                    "wells_fargo": 489, "capital_one": 250, "amex": 155, "citi": 226,
                    "discover": 283, "apple_card": 357, "chase_card_2026-01_to_2026-03": 171,
                    "chase_card_2026-02_to_2026-04": 172, "chase_card_quoted_commas": 5]
        for (fixture, count) in rows {
            let (_, file) = try parse(fixture)
            XCTAssertEqual(file.rows.count, count, fixture)
            // Bank of America's opening-balance line has a date and no amount.
            XCTAssertEqual(file.skipped.count, fixture == "bank_of_america_checking" ? 1 : 0, fixture)
        }
    }

    private func row(_ file: ParsedFile, _ day: Day, _ raw: String) throws -> ParsedRow {
        try XCTUnwrap(file.rows.first { $0.date == day && $0.description == raw }, "\(day) \(raw)")
    }

    func test_signsAreMoneyOutNegativeInEveryFile() throws {
        // (fixture, a purchase, its normalised amount, a credit, its normalised amount)
        let cases: [(String, Day, String, Decimal, Day, String, Decimal)] = [
            ("chase_card", Day(2026, 10, 31), "GOWANUS GRIND COFFEE BROOKLYN NY", -7,
             Day(2025, 11, 18), "FULTON STREET BOOKS", 24),
            ("chase_checking", Day(2026, 10, 30), "BODEGA MOON DELI BROOKLYN", Decimal(string: "-4.5")!,
             Day(2026, 10, 30), "HALCYON LABS PAYROLL PPD ID: 9000000001", Decimal(string: "2851.85")!),
            ("bank_of_america_checking", Day(2025, 5, 1), "BRIGHTSTONE PROPERTY MGMT RENT WEB ID: 9000000002", -2150,
             Day(2025, 5, 2), "HALCYON LABS PAYROLL PPD ID: 9000000001", Decimal(string: "2627.4")!),
            ("wells_fargo", Day(2026, 10, 31),
             "PURCHASE AUTHORIZED ON 10/31 GOWANUS GRIND COFFEE BROOKLYN NY S00000004", -7,
             Day(2026, 10, 30), "HALCYON LABS PAYROLL PPD ID: 9000000001", Decimal(string: "2381.85")!),
            ("capital_one", Day(2026, 10, 29), "NINE DRAGONS NOODLE NEW YORK NY", Decimal(string: "-33.25")!,
             Day(2026, 10, 24), "CAPITAL ONE AUTOPAY PYMT", 0),
            ("amex", Day(2026, 10, 25), "SQ *MR KALE BKLYN", Decimal(string: "-11.75")!,
             Day(2026, 10, 22), "AUTOPAY PAYMENT - THANK YOU", 0),
            ("citi", Day(2026, 10, 31), "CITY TRANSIT FARE NEW YORK", Decimal(string: "-2.9")!,
             Day(2026, 10, 20), "PAYMENT THANK YOU", 0),
            ("discover", Day(2025, 5, 2), "GOWANUS GRIND COFFEE BROOKLYN NY", Decimal(string: "-6.75")!,
             Day(2025, 6, 18), "INTERNET PAYMENT - THANK YOU", 0),
            ("apple_card", Day(2026, 10, 29), "LANTERN BEAN CAFE BKLYN", -5,
             Day(2026, 10, 28), "AUTOPAY PAYMENT", Decimal(string: "202.44")!),
        ]
        for (fixture, pDay, pRaw, pAmount, cDay, cRaw, cAmount) in cases {
            let (_, file) = try parse(fixture)
            XCTAssertEqual(try row(file, pDay, pRaw).amount, pAmount, "\(fixture) purchase")
            let credit = try row(file, cDay, cRaw).amount
            XCTAssertGreaterThan(credit, 0, "\(fixture) credit")
            if cAmount != 0 { XCTAssertEqual(credit, cAmount, "\(fixture) credit") }
        }
    }

    /// The broad version of the spot checks: on a card nothing but a payment or a return
    /// is money in; in a checking account nothing but payroll is.
    func test_onlyPaymentsReturnsAndPayrollAreMoneyIn() throws {
        let cards = ["chase_card", "capital_one", "amex", "citi", "discover", "apple_card"]
        for fixture in cards {
            let (_, file) = try parse(fixture)
            let credits = file.rows.filter { $0.amount > 0 }
            XCTAssertFalse(credits.isEmpty, fixture)
            for c in credits {
                XCTAssertTrue(c.description.contains("PAY") || c.bankType == "Return",
                              "\(fixture): \(c.description) came out as money in")
            }
            XCTAssertGreaterThan(file.rows.filter { $0.amount < 0 }.count, credits.count, fixture)
        }
        for fixture in ["chase_checking", "bank_of_america_checking", "wells_fargo"] {
            let (_, file) = try parse(fixture)
            for c in file.rows where c.amount > 0 {
                XCTAssertTrue(c.description.contains("PAYROLL"), "\(fixture): \(c.description)")
            }
        }
    }

    func test_bankColumnsCarryThrough() throws {
        let (_, apple) = try parse("apple_card")
        let lantern = try row(apple, Day(2026, 10, 29), "LANTERN BEAN CAFE BKLYN")
        XCTAssertEqual(lantern.bankMerchant, "Lantern Bean Cafe")
        XCTAssertEqual(lantern.bankCategory, "Restaurants")
        let (_, chase) = try parse("chase_card")
        XCTAssertEqual(try row(chase, Day(2025, 11, 18), "FULTON STREET BOOKS").bankType, "Return")
    }

    func test_theQuotedFixtureKeepsItsCommasAndThousands() throws {
        let (_, file) = try parse("chase_card_quoted_commas")
        XCTAssertEqual(file.rows.map(\.description),
                       ["MR. KALE, BROOKLYN NY", "BAR \"THE GOWANUS\" BROOKLYN",
                        "PROSPECT GREENS MARKET, INC.", "FULTON STREET BOOKS", "SQ *MR KALE BKLYN"])
        XCTAssertEqual(file.rows[2].amount, Decimal(string: "-1204.18"))
        XCTAssertEqual(file.rows[3].amount, Decimal(string: "18.99"))
    }

    func test_anUnknownShapeMatchesNothing() {
        XCTAssertNil(RecipeMatcher.match("When,What,How much\n01/02/2026,Coffee,4.50\n"))
        XCTAssertNil(RecipeMatcher.match(""))
    }

    func test_headersMatchLooselyOnCaseAndSpacing() {
        let text = " card ,TRANSACTION DATE,Post  Date,Description,Category,Type,Amount,Memo\n"
            + "4417,01/02/2026,01/03/2026,COFFEE,Food & Drink,Sale,-4.50,\n"
        XCTAssertEqual(RecipeMatcher.match(text)?.id, "chase-card")
    }

    func test_recipesRoundTripAsPlainJSON() throws {
        let data = try JSONEncoder().encode(BuiltInRecipes.all)
        XCTAssertEqual(try JSONDecoder().decode([ImportRecipe].self, from: data), BuiltInRecipes.all)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"split\""), "the amount rule is readable JSON: \(json.prefix(200))")
    }
}

/// What the mapping sheet needs for an unknown file: the first rows split into columns,
/// and a live parse of them under whatever mapping is chosen so far.
final class ColumnPreviewTests: XCTestCase {

    private let text = "When,What,How much\n01/02/2026,\"Coffee, large\",4.50\n01/03/2026,Payroll,-900\n"

    func test_previewShowsTheFirstRowsSplit() {
        let preview = ColumnPreview(text: text)
        XCTAssertEqual(preview.rows.first, ["When", "What", "How much"])
        XCTAssertEqual(preview.rows.count, 3)
        XCTAssertEqual(preview.columnCount, 3)
        XCTAssertTrue(preview.firstRowLooksLikeHeader)
        XCTAssertFalse(ColumnPreview(text: try! BankFixtures.text("wells_fargo")).firstRowLooksLikeHeader)
        XCTAssertEqual(ColumnPreview(text: try! BankFixtures.text("chase_card")).rows.count, 5)
    }

    func test_applyingAMappingParsesThePreviewLive() {
        let preview = ColumnPreview(text: text)
        let mapping = ImportRecipe(id: "mine", name: "My bank", headerFingerprint: preview.rows[0],
                                   dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1,
                                   amount: .signed(column: 2, moneyOutIsNegative: false))
        let parsed = preview.apply(mapping)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertNil(parsed[0], "the header row is not a transaction")
        XCTAssertEqual(parsed[1]?.amount, Decimal(string: "-4.5"), "money out flipped to negative")
        XCTAssertEqual(parsed[1]?.description, "Coffee, large")
        XCTAssertEqual(parsed[2]?.amount, 900)
        // Once taught, the same shape matches the saved recipe.
        XCTAssertEqual(RecipeMatcher.match(text, among: [mapping] + BuiltInRecipes.all)?.id, "mine")
    }
}
