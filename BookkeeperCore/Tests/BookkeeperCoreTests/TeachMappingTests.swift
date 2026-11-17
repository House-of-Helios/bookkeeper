import XCTest
@testable import BookkeeperCore

/// The teach-a-bank sheet: a first guess at each column's role, date-format detection,
/// the mapping → recipe step, and the promise that a taught shape imports with no
/// questions the next time.
final class TeachMappingTests: XCTestCase {

    /// Headerless, six columns: date, amount, `*`, empty, description, running balance —
    /// Wells Fargo's shape plus a balance, so no built-in recipe claims it.
    private let creditUnion = """
    10/14/2026,-23.18,*,,MR KALE BROOKLYN NY 0042 POS,1842.20
    10/13/2026,-6.40,*,,SQ *NINTH STREET GRIND,1865.38
    10/12/2026,-2.90,*,,METRO FARE OMNY TAP,1871.78
    10/11/2026,3200.00,*,,PAYROLL DIRECT DEP HOUSE OF HELIOS,1874.68
    10/10/2026,-500.00,*,,ONLINE TRANSFER TO SAV 4471,-1325.32
    10/09/2026,-11.15,*,,CORNER BODEGA DELI 11222,-825.32

    """

    private var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-teach-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func test_noBuiltInRecipeClaimsTheFile() {
        XCTAssertNil(RecipeMatcher.match(creditUnion))
    }

    func test_theFirstGuessNamesDateAmountAndDescription() {
        let preview = ColumnPreview(text: creditUnion)
        XCTAssertFalse(preview.firstRowLooksLikeHeader)
        XCTAssertEqual(preview.columnCount, 6)
        let m = preview.suggestedMapping()
        XCTAssertEqual(m.roles, [.date, .amount, .ignore, .ignore, .description, .ignore],
                       "the balance column also goes negative, but the amount is the first that does")
        XCTAssertEqual(m.dateFormat, "MM/dd/yyyy")
        XCTAssertTrue(m.moneyOutIsNegative)
    }

    func test_dateFormatIsReadFromTheCells() {
        let eu = ColumnPreview(text: "14/10/2026,Coffee,-4.50\n03/10/2026,Tea,-3.00\n")
        XCTAssertEqual(eu.dateFormat(column: 0), "dd/MM/yyyy", "a day over 12 rules out month-first")
        XCTAssertEqual(ColumnPreview(text: "2026-10-14,Coffee,-4.50\n").dateFormat(column: 0), "yyyy-MM-dd")
        XCTAssertEqual(ColumnPreview(text: "03/04/2026,Coffee,-4.50\n").dateFormat(column: 0), "MM/dd/yyyy",
                       "ambiguous reads the US way")
        XCTAssertNil(eu.dateFormat(column: 1))
    }

    func test_twoNumberColumnsThatNeverBothFillAreMoneyOutAndIn() {
        let text = "Date,Memo,Debit,Credit\n01/02/2026,Coffee,4.50,\n01/03/2026,Payroll,,900.00\n"
        let preview = ColumnPreview(text: text)
        XCTAssertTrue(preview.firstRowLooksLikeHeader)
        XCTAssertEqual(preview.dataRows.count, 2)
        XCTAssertEqual(preview.suggestedMapping().roles, [.date, .description, .moneyOut, .moneyIn])
    }

    func test_anIncompleteMappingMakesNoRecipe() {
        let m = TeachMapping(roles: [.date, .ignore, .ignore, .ignore, .description, .ignore])
        XCTAssertNil(m.recipe(id: "x", name: "x", header: nil, columnCount: 6))
        XCTAssertNil(TeachMapping(roles: [.date, .moneyOut, .description]).recipe(id: "x", name: "x", header: nil, columnCount: 3),
                     "money out alone is half an amount")
    }

    func test_thePreviewReadsLiveAndTheSignToggleFlipsIt() throws {
        let preview = ColumnPreview(text: creditUnion)
        var m = preview.suggestedMapping()
        let negative = try XCTUnwrap(m.recipe(id: "cu", name: "CU", header: nil, columnCount: 6))
        XCTAssertEqual(preview.apply(negative).compactMap { $0?.amount }.prefix(4),
                       [Decimal(string: "-23.18")!, Decimal(string: "-6.4")!, Decimal(string: "-2.9")!, 3200])
        m.moneyOutIsNegative = false
        let positive = try XCTUnwrap(m.recipe(id: "cu", name: "CU", header: nil, columnCount: 6))
        XCTAssertEqual(preview.apply(positive).first??.amount, Decimal(string: "23.18"))
    }

    func test_aTaughtHeaderlessRecipeImportsAndTheNextFileNeedsNoQuestions() throws {
        let s = SpendingStore(directory: dir)
        let preview = ColumnPreview(text: creditUnion)
        let recipe = try XCTUnwrap(preview.suggestedMapping()
            .recipe(id: "taught-cu", name: "My Credit Union", header: preview.header, columnCount: preview.columnCount))
        s.addRecipe(recipe)
        let a = s.addAccount(name: recipe.name, recipeId: recipe.id, colorHex: "#4A4A4A")
        XCTAssertEqual(try s.importCSV(text: creditUnion, accountId: a.id).added, 6)
        XCTAssertEqual(s.transactions.first { $0.rawDescription.hasPrefix("PAYROLL") }?.amount, 3200)

        // A later export from the same bank: same shape, new rows.
        let next = "11/02/2026,-4.75,*,,LITTLE OWL COFFEE 02,1200.00\n"
        let reopened = SpendingStore(directory: dir)
        XCTAssertEqual(RecipeMatcher.match(rows: CSV.parse(next), among: reopened.allRecipes)?.id, "taught-cu")
        // …and a real Wells Fargo file still goes to Wells Fargo.
        XCTAssertEqual(RecipeMatcher.match(rows: CSV.parse(try BankFixtures.text("wells_fargo")),
                                           among: reopened.allRecipes)?.id, "wells-fargo")
    }

    func test_aHeaderedRecipeKeepsTheHeaderAsItsFingerprint() throws {
        let text = "Date,Memo,Debit,Credit\n01/02/2026,Coffee,4.50,\n01/03/2026,Payroll,,900.00\n"
        let preview = ColumnPreview(text: text)
        let recipe = try XCTUnwrap(preview.suggestedMapping()
            .recipe(id: "t", name: "T", header: preview.header, columnCount: preview.columnCount))
        XCTAssertEqual(recipe.headerFingerprint, ["Date", "Memo", "Debit", "Credit"])
        XCTAssertNil(recipe.columnCount)
        XCTAssertEqual(recipe.parse(text: text).rows.map(\.amount), [Decimal(string: "-4.5")!, 900])
    }
}
