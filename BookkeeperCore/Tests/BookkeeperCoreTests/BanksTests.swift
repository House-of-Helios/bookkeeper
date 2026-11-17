import XCTest
@testable import BookkeeperCore

/// Settings → Banks: digits from a file's name, renaming, and folding one account into
/// another without counting anything twice.
final class BanksTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-banks-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private static let header = "Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #\n"
    private static let lines = "DEBIT,10/02/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n"
        + "DEBIT,10/03/2026,CORNER CO-OP,-20.00,DEBIT_CARD,100.00,\n"
        + "DEBIT,10/04/2026,SLICE SHOP,-12.00,DEBIT_CARD,100.00,\n"

    func test_lastFourDigitsFromAFileName() {
        XCTAssertEqual(SpendingStore.lastFour(inFileName: "Chase1234_Activity_20261023.CSV"), "1234")
        XCTAssertEqual(SpendingStore.lastFour(inFileName: "Chase checking 5678.csv"), "5678")
        XCTAssertEqual(SpendingStore.lastFour(inFileName: "boa-x4417.csv"), "4417")
        XCTAssertNil(SpendingStore.lastFour(inFileName: "statement 2026.csv"), "a year is not digits")
        XCTAssertNil(SpendingStore.lastFour(inFileName: "chase_card_2026-02_to_2026-04.csv"))
        XCTAssertNil(SpendingStore.lastFour(inFileName: "export.csv"))
    }

    func test_filesNamedForTheSameDigitsGoToOneAccountOthersToTheirOwn() throws {
        let s = SpendingStore(directory: dir)
        let rows = CSV.parse(Self.header + Self.lines)
        let recipe = try XCTUnwrap(RecipeMatcher.match(rows: rows, among: s.allRecipes))
        let a = s.account(for: rows, recipe: recipe, fileName: "Chase checking 1234.csv") { _ in "#000000" }
        try s.importCSV(text: Self.header + Self.lines, accountId: a.id)
        let b = s.account(for: rows, recipe: recipe, fileName: "Chase1234_Activity.csv") { _ in "#000000" }
        XCTAssertEqual(a.id, b.id, "same digits, same account")
        let c = s.account(for: rows, recipe: recipe, fileName: "Chase savings 9876.csv") { _ in "#000000" }
        XCTAssertNotEqual(a.id, c.id)
        XCTAssertEqual(c.card, "9876")
    }

    func test_renameAndMergeCountNothingTwice() throws {
        let s = SpendingStore(directory: dir)
        let one = s.addBank(name: "Chase", colorHex: "#111111")
        let two = s.addBank(name: "Chase 2", colorHex: "#222222")
        try s.importCSV(text: Self.header + Self.lines, accountId: one.id)
        // The same three lines landed in a second account too, plus one of its own.
        try s.importCSV(text: Self.header + Self.lines + "DEBIT,10/05/2026,MR KALE,-9.00,DEBIT_CARD,100.00,\n",
                        accountId: two.id)
        XCTAssertEqual(s.transactions.count, 7)

        s.renameAccount(one.id, to: "  Chase checking ")
        XCTAssertEqual(s.accounts.first { $0.id == one.id }?.name, "Chase checking")

        XCTAssertEqual(s.mergeAccount(two.id, into: one.id), 3, "the three repeats are dropped")
        XCTAssertEqual(s.accounts.map(\.id), [one.id])
        XCTAssertEqual(s.transactions.count, 4)
        XCTAssertTrue(s.transactions.allSatisfy { $0.accountId == one.id })
        XCTAssertTrue(s.imports.allSatisfy { $0.accountId == one.id }, "its files come along")

        // Importing the same file again finds every line already here.
        let again = try s.importCSV(text: Self.header + Self.lines + "DEBIT,10/05/2026,MR KALE,-9.00,DEBIT_CARD,100.00,\n",
                                    accountId: one.id)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(SpendingStore(directory: dir).transactions.count, 4, "saved")
    }
}
