import XCTest
@testable import BookkeeperCore

/// `spending/settings.json`: the Spending screens' own preferences, beside the ledger and
/// never in any v1 file.
final class SpendingSettingsTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-settings-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func test_aFreshStoreFollowsTheSystem() {
        XCTAssertEqual(SpendingStore(directory: dir).settings.theme, .system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path),
                       "reading the default writes nothing")
    }

    func test_aThemeChoiceSurvivesAReopen() {
        SpendingStore(directory: dir).setTheme(.black)
        XCTAssertEqual(SpendingStore(directory: dir).settings.theme, .black)
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_anUnknownThemeFromALaterVersionFallsBackToSystem() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "theme": "sepia", "future": 1 }"#.utf8)
            .write(to: dir.appendingPathComponent("settings.json"))
        XCTAssertEqual(SpendingStore(directory: dir).settings.theme, .system)
    }

    func test_textSizeDefaultsToStandardAndSurvivesAReopen() {
        XCTAssertEqual(SpendingStore(directory: dir).settings.textSize, .standard)
        SpendingStore(directory: dir).setTextSize(.large)
        let reopened = SpendingStore(directory: dir).settings
        XCTAssertEqual(reopened.textSize, .large)
        XCTAssertEqual(reopened.theme, .system, "a text size alone leaves the theme as it was")
    }

    func test_aSettingsFileWithoutTextSizeReadsAsStandard() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{ "theme": "dark" }"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        let s = SpendingStore(directory: dir).settings
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(s.textSize, .standard)
    }

    func test_theFourChoicesInOrder() {
        XCTAssertEqual(ThemeChoice.allCases.map(\.rawValue), ["system", "light", "dark", "black"])
    }
}
