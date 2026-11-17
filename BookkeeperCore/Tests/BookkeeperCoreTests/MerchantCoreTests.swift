import XCTest
@testable import BookkeeperCore

/// The normaliser behind the edit drawer's pattern chip, and the word-aware matching a
/// rule does against `rawDescription`. Every raw string in the bank fixtures and the
/// mockup is in the table.
final class MerchantCoreTests: XCTestCase {

    // MARK: - core(raw)

    /// raw → the cleaned core.
    private let table: [(String, String)] = [
        // 🥗 the merchant that has to fold
        ("MR KALE BROOKLYN NY 0042 POS", "MR KALE"),
        ("SQ *MR KALE BKLYN", "MR KALE"),
        ("MR. KALE #2 BROOKLYN NY", "MR KALE"),
        ("MR. KALE, BROOKLYN NY", "MR KALE"),
        ("CHECKCARD 0512 MR KALE BROOKLYN NY 0042 POS", "MR KALE"),
        ("CHECKCARD 1103 SQ *MR KALE BKLYN", "MR KALE"),
        ("CHECKCARD 0228 MR. KALE #2 BROOKLYN NY", "MR KALE"),
        ("PURCHASE AUTHORIZED ON 05/12 MR KALE BROOKLYN NY 0042 POS S00000003", "MR KALE"),
        ("PURCHASE AUTHORIZED ON 07/30 SQ *MR KALE BKLYN S00000000", "MR KALE"),
        ("PURCHASE AUTHORIZED ON 01/02 MR. KALE #2 BROOKLYN NY S00000007", "MR KALE"),
        ("MR KALEIDOSCOPE TOYS BKLYN", "MR KALEIDOSCOPE TOYS"),
        // fixtures — card files
        ("ATLANTIC TAQUERIA BROOKLYN NY", "ATLANTIC TAQUERIA"),
        ("BAR \"THE GOWANUS\" BROOKLYN", "BAR THE GOWANUS"),
        ("BERGEN HARDWARE BROOKLYN", "BERGEN HARDWARE"),
        ("BODEGA MOON DELI BROOKLYN", "BODEGA MOON DELI"),
        ("BRIGHTLINE FIBER INTERNET", "BRIGHTLINE FIBER INTERNET"),
        ("CITY TRANSIT FARE NEW YORK", "CITY TRANSIT FARE"),
        ("CORNER CO-OP BROOKLYN NY", "CORNER CO-OP"),
        ("FERRANTE'S SLICE SHOP BROOKLYN", "FERRANTE'S SLICE SHOP"),
        ("FULTON STREET BOOKS", "FULTON STREET BOOKS"),
        ("GOWANUS GRIND COFFEE BROOKLYN NY", "GOWANUS GRIND COFFEE"),
        ("HALSEY STREET GROCERS", "HALSEY STREET GROCERS"),
        ("IRONWORKS GYM MEMBERSHIP", "IRONWORKS GYM MEMBERSHIP"),
        ("LANTERN BEAN CAFE BKLYN", "LANTERN BEAN CAFE"),
        ("NINE DRAGONS NOODLE NEW YORK NY", "NINE DRAGONS NOODLE"),
        ("PIER 6 OYSTER BAR BROOKLYN", "PIER 6 OYSTER BAR"),
        ("PIGEON MOBILE WIRELESS", "PIGEON MOBILE WIRELESS"),
        ("PROSPECT GREENS MARKET BROOKLYN", "PROSPECT GREENS MARKET"),
        ("PROSPECT GREENS MARKET, INC.", "PROSPECT GREENS MARKET"),
        ("SMITH ST PHARMACY BROOKLYN", "SMITH ST PHARMACY"),
        ("SONGBIRD MUSIC 866-555-0100", "SONGBIRD MUSIC"),
        ("STARLIGHT CINEMA BKLYN", "STARLIGHT CINEMA"),
        ("STREAMLY.TV SUBSCRIPTION", "STREAMLY"),
        ("VELVET ROOM JAZZ NEW YORK", "VELVET ROOM JAZZ"),
        ("YELLOWBIRD RIDES *TRIP", "YELLOWBIRD RIDES"),
        ("PURCHASE AUTHORIZED ON 03/14 YELLOWBIRD RIDES *TRIP S00000005", "YELLOWBIRD RIDES"),
        ("CHECKCARD 0612 PIER 6 OYSTER BAR BROOKLYN", "PIER 6 OYSTER BAR"),
        // fixtures — payments, transfers, checking
        ("AUTOPAY PAYMENT", "AUTOPAY PAYMENT"),
        ("AUTOPAY PAYMENT - THANK YOU", "AUTOPAY PAYMENT THANK"),
        ("PAYMENT THANK YOU", "PAYMENT THANK YOU"),
        ("PAYMENT THANK YOU-MOBILE", "PAYMENT THANK YOU-MOBILE"),
        ("INTERNET PAYMENT - THANK YOU", "INTERNET PAYMENT THANK"),
        ("CAPITAL ONE AUTOPAY PYMT", "CAPITAL ONE AUTOPAY"),
        ("CHASE CREDIT CRD AUTOPAY PPD ID: 9000000003", "CHASE CREDIT CRD"),
        ("BANK OF AMERICA CREDIT CARD Bill Payment", "BANK OF AMERICA"),
        ("WF CREDIT CARD AUTO PAY", "WF CREDIT CARD"),
        ("ONLINE TRANSFER TO SAV XXXXXX9001", "SAV XXXXXX9001"),
        ("HALCYON LABS PAYROLL PPD ID: 9000000001", "HALCYON LABS PAYROLL"),
        ("BRIGHTSTONE PROPERTY MGMT RENT WEB ID: 9000000002", "BRIGHTSTONE PROPERTY MGMT"),
        ("ATM WITHDRAWAL 000417 7TH AVE BROOKLYN", "ATM WITHDRAWAL"),
        // mockup
        ("NOODLE LANTERN NEW YORK NY", "NOODLE LANTERN"),
        ("TST* NOODLE LANTERN", "NOODLE LANTERN"),
        ("TINY FIG BROOKLYN NY", "TINY FIG"),
        ("SQ *FERRY SLICE", "FERRY SLICE"),
        ("FERRY SLICE PIZZA 0193", "FERRY SLICE PIZZA"),
        ("BLUE HOUR TACOS BKLYN", "BLUE HOUR TACOS"),
        ("METRO FARE OMNY TAP", "METRO FARE OMNY"),
        ("METRO FARE NYCT", "METRO FARE NYCT"),
        ("YELLOW CAB 4471 NEW YORK", "YELLOW CAB"),
        ("BIKE SHARE MONTHLY", "BIKE SHARE MONTHLY"),
        ("GREENPOINT GREENS MKT", "GREENPOINT GREENS MKT"),
        ("CORNER BODEGA DELI 11222", "CORNER BODEGA DELI"),
        ("ASHFORD MGMT ACH RENT", "ASHFORD MGMT ACH RENT"),
        ("CITY POWER LIGHT AUTOPAY", "CITY POWER LIGHT"),
        ("FIBERLINK INTERNET", "FIBERLINK INTERNET"),
        ("NINTH ST GRIND", "NINTH ST GRIND"),
        ("SQ *NINTH STREET GRIND", "NINTH STREET GRIND"),
        ("LITTLE OWL COFFEE 02", "LITTLE OWL COFFEE"),
        ("TST* SEED AND STEAM", "SEED AND STEAM"),
        ("PAPER MOON BOOKS", "PAPER MOON BOOKS"),
        ("HARDWARE ON 5TH AVE", "HARDWARE ON 5TH"),
        ("ONLINE MKTPL*2R4T9", "ONLINE MKTPL"),
        ("ONLINE MARKETPLACE", "ONLINE MARKETPLACE"),
        ("STREAMLY.COM", "STREAMLY"),
        ("MUSICBOX SUBSCR", "MUSICBOX SUBSCR"),
        ("CLOUDLOCKER STORAGE", "CLOUDLOCKER STORAGE"),
        ("LANTERN CINEMA BKLYN", "LANTERN CINEMA"),
        ("BASEMENT JAZZ CLUB", "BASEMENT JAZZ CLUB"),
        ("MUSEUM PASS NYC", "MUSEUM PASS"),
        ("PHARMACY PLUS #331", "PHARMACY PLUS"),
        ("SQ *BARBER NED", "BARBER NED"),
        ("PAYROLL DIRECT DEP HOUSE OF HELIOS", "PAYROLL DIRECT DEP"),
        ("CHASE CARD PAYMENT THANK YOU", "CHASE CARD PAYMENT"),
        ("ONLINE TRANSFER TO SAV 4471", "SAV 4471"),
        ("ZELLE TO J RIVERA 8812", "J RIVERA"),
        // processor prefixes beyond the fixtures
        ("PP*CLOUDLOCKER", "CLOUDLOCKER"),
        ("PAYPAL *PAPERMOON", "PAPERMOON"),
        ("PY *LITTLE OWL", "LITTLE OWL"),
        ("SP SEED AND STEAM", "SEED AND STEAM"),
        ("POS DEBIT TINY FIG 10/14 BROOKLYN NY 11201", "TINY FIG"),
        ("tiny fig brooklyn ny", "TINY FIG"),
        ("  MR    KALE   ", "MR KALE"),
    ]

    func test_coreCleansEveryRawString() {
        for (raw, expected) in table {
            XCTAssertEqual(MerchantCore.core(raw), expected, raw)
        }
    }

    /// A transfer is about the account it goes to or comes from — its bank words and last
    /// digits — so a rule on one account (rent paid from savings, a fee account) never
    /// catches every transfer.
    func test_aTransferIsKeyedByItsAccount() {
        XCTAssertEqual(MerchantCore.core("Requested transfer to JDOE77 (Ally Bank Savings ...4567)"), "ALLY BANK SAVINGS 4567")
        XCTAssertEqual(MerchantCore.core("Requested transfer to JDOE77 (Marcus Savings ...9120)"), "MARCUS SAVINGS 9120")
        XCTAssertEqual(MerchantCore.core("Internal transfer to Spending Account ...1234"), "SPENDING ACCOUNT 1234")
        XCTAssertEqual(MerchantCore.core("Internal transfer from Savings Account XXXX5521"), "SAVINGS ACCOUNT XXXX5521")
        XCTAssertEqual(MerchantCore.core("TRANSFER TO CHK 0042 CONF 88112"), "CHK 0042")
        // Two accounts at one bank are two rules, and neither matches the other.
        let a = MerchantRule(match: .contains, pattern: MerchantCore.core("Requested transfer to JDOE77 (Ally Bank Savings ...4567)"))
        XCTAssertTrue(a.matches("Requested transfer to JDOE77 (Ally Bank Savings ...4567)"))
        XCTAssertFalse(a.matches("Requested transfer to JDOE77 (Ally Bank Savings ...8890)"))
        // No account named: as before.
        XCTAssertEqual(MerchantCore.core("ONLINE TRANSFER TO SAVINGS"), "ONLINE TRANSFER TO")
        // A payment app's transfer is still about the person.
        XCTAssertEqual(MerchantCore.core("Online Transfer to Sam Lee via Zelle"), "SAM LEE")
    }

    func test_theCoreNeverComesBackEmpty() {
        // All noise: fall back to the raw words rather than an empty chip.
        XCTAssertEqual(MerchantCore.core("POS 0042"), "POS 0042")
        XCTAssertEqual(MerchantCore.core(""), "")
    }

    func test_suggestedNameIsTheTitleCasedCore() {
        XCTAssertEqual(MerchantCore.suggestedName("MR KALE BROOKLYN NY 0042 POS"), "Mr Kale")
        XCTAssertEqual(MerchantCore.suggestedName("SQ *MR KALE BKLYN"), "Mr Kale")
        XCTAssertEqual(MerchantCore.suggestedName("FERRANTE'S SLICE SHOP BROOKLYN"), "Ferrante's Slice Shop")
        XCTAssertEqual(MerchantCore.suggestedName("TST* SEED AND STEAM"), "Seed and Steam")
        XCTAssertEqual(MerchantCore.suggestedName("BANK OF AMERICA CREDIT CARD Bill Payment"), "Bank of America")
        XCTAssertEqual(MerchantCore.suggestedName("CORNER CO-OP BROOKLYN NY"), "Corner Co-Op")
        XCTAssertEqual(MerchantCore.suggestedName("HARDWARE ON 5TH AVE"), "Hardware on 5th")
        XCTAssertEqual(MerchantCore.suggestedName("BAR \"THE GOWANUS\" BROOKLYN"), "Bar the Gowanus")
    }

    // MARK: - Matching

    private func rule(_ match: MerchantRule.Match, _ pattern: String) -> MerchantRule {
        MerchantRule(match: match, pattern: pattern)
    }

    func test_containsIsWordAware() {
        let kale = rule(.contains, "MR KALE")
        for raw in ["MR KALE BROOKLYN NY 0042 POS", "SQ *MR KALE BKLYN", "MR. KALE #2 BROOKLYN NY",
                    "MR. KALE, BROOKLYN NY", "CHECKCARD 0512 MR KALE BROOKLYN NY 0042 POS",
                    "PURCHASE AUTHORIZED ON 01/02 MR. KALE #2 BROOKLYN NY S00000007", "mr kale"] {
            XCTAssertTrue(kale.matches(raw), raw)
        }
        for raw in ["MR KALEIDOSCOPE TOYS BKLYN", "SMR KALE", "MR KALES", "KALE MR", "MRKALE"] {
            XCTAssertFalse(kale.matches(raw), raw)
        }
        XCTAssertTrue(rule(.contains, "Mr. Kale").matches("SQ *MR KALE BKLYN"), "the pattern is normalised too")
        XCTAssertTrue(rule(.contains, "FERRANTE'S SLICE").matches("FERRANTES SLICE SHOP"))
        XCTAssertFalse(rule(.contains, "").matches("ANYTHING"), "an empty pattern matches nothing")
    }

    func test_startsWithLooksPastProcessorAndBankPrefixes() {
        let kale = rule(.startsWith, "MR KALE")
        XCTAssertTrue(kale.matches("MR KALE BROOKLYN NY 0042 POS"))
        XCTAssertTrue(kale.matches("SQ *MR KALE BKLYN"))
        XCTAssertTrue(kale.matches("PURCHASE AUTHORIZED ON 05/12 MR KALE BROOKLYN NY 0042 POS S00000003"))
        XCTAssertFalse(kale.matches("MR KALEIDOSCOPE TOYS BKLYN"))
        XCTAssertFalse(kale.matches("THE MR KALE"))
        XCTAssertTrue(rule(.startsWith, "SQ MR").matches("SQ *MR KALE BKLYN"), "a pattern that names the prefix still works")
    }

    func test_exactIsTheWholeCleanedText() {
        let fig = rule(.exact, "TINY FIG BROOKLYN NY")
        XCTAssertTrue(fig.matches("TINY FIG BROOKLYN NY"))
        XCTAssertTrue(fig.matches("tiny fig, brooklyn ny"))
        XCTAssertFalse(fig.matches("TINY FIG BROOKLYN NY 11201"))
        XCTAssertFalse(rule(.exact, "TINY FIG").matches("TINY FIG BROOKLYN NY"))
    }

    func test_rulesOrderExactThenStartsWithThenContainsThenLongerThenNewer() {
        let t0 = Date(timeIntervalSince1970: 0), t1 = Date(timeIntervalSince1970: 100)
        let rules = [
            MerchantRule(id: "c-short", match: .contains, pattern: "KALE", createdAt: t1),
            MerchantRule(id: "c-long", match: .contains, pattern: "MR KALE", createdAt: t0),
            MerchantRule(id: "s", match: .startsWith, pattern: "MR", createdAt: t0),
            MerchantRule(id: "e", match: .exact, pattern: "MR KALE BKLYN", createdAt: t0),
            MerchantRule(id: "c-long-new", match: .contains, pattern: "MR KALE", createdAt: t1),
        ]
        XCTAssertEqual(MerchantRule.ordered(rules).map(\.id), ["e", "s", "c-long-new", "c-long", "c-short"])
    }
}
