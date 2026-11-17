import XCTest
@testable import BookkeeperCore

/// RFC 4180, as banks actually write it: a split on "," breaks on the first merchant
/// with a comma in its name.
final class CSVParserTests: XCTestCase {

    func test_plainRows() {
        XCTAssertEqual(CSV.parse("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
    }

    func test_noTrailingNewlineStillEndsTheLastRow() {
        XCTAssertEqual(CSV.parse("a,b\n1,2"), [["a", "b"], ["1", "2"]])
    }

    func test_quotedCommasStayInOneField() {
        XCTAssertEqual(CSV.parse("\"MR. KALE, BROOKLYN NY\",-13.25"), [["MR. KALE, BROOKLYN NY", "-13.25"]])
    }

    func test_doubledQuotesAreOneQuote() {
        XCTAssertEqual(CSV.parse("\"BAR \"\"THE GOWANUS\"\" BROOKLYN\",x"),
                       [["BAR \"THE GOWANUS\" BROOKLYN", "x"]])
    }

    func test_aQuotedNewlineStaysInTheField() {
        XCTAssertEqual(CSV.parse("a,\"line one\nline two\"\nb,c\n"),
                       [["a", "line one\nline two"], ["b", "c"]])
    }

    func test_crlfAndALoneCREndRows() {
        XCTAssertEqual(CSV.parse("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSV.parse("a,b\r1,2"), [["a", "b"], ["1", "2"]])
    }

    func test_aByteOrderMarkIsDropped() {
        XCTAssertEqual(CSV.parse("\u{FEFF}Date,Amount\n"), [["Date", "Amount"]])
    }

    func test_emptyFieldsAndBlankLinesSurvive() {
        XCTAssertEqual(CSV.parse("a,,c\n\nd,e,\n"), [["a", "", "c"], [""], ["d", "e", ""]])
    }

    func test_theQuotedCommaFixture() throws {
        let rows = CSV.parse(try BankFixtures.text("chase_card_quoted_commas"))
        XCTAssertEqual(rows.count, 6, "header + five rows, one with a newline inside")
        XCTAssertTrue(rows.allSatisfy { $0.count == 8 }, "every row keeps its eight columns")
        XCTAssertEqual(rows[1][3], "MR. KALE, BROOKLYN NY")
        XCTAssertEqual(rows[2][3], "BAR \"THE GOWANUS\" BROOKLYN")
        XCTAssertEqual(rows[2][7], "split with A., B., and C.")
        XCTAssertEqual(rows[3][6], "-1,204.18")
        XCTAssertEqual(rows[5][7], "line one\nline two")
    }
}

/// The synthetic bank exports under `Fixtures/bank/`.
enum BankFixtures {
    static let all = ["chase_card", "chase_checking", "bank_of_america_checking", "wells_fargo",
                      "capital_one", "amex", "citi", "discover", "apple_card",
                      "chase_card_2026-01_to_2026-03", "chase_card_2026-02_to_2026-04",
                      "chase_card_quoted_commas"]

    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "csv",
                                        subdirectory: "Fixtures/bank"))
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }
}
