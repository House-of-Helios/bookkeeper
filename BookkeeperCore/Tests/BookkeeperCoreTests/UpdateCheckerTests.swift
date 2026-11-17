import XCTest
@testable import BookkeeperCore

final class UpdateCheckerTests: XCTestCase {
    func test_isNewer() {
        XCTAssertTrue(UpdateChecker.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))   // numeric, not lexical
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.12.0", than: "1.11.1"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.99.99"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.11.1", than: "1.11.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
    }

    /// "Nothing new" and "I couldn't look" are different answers.
    func test_onlyAnAvailableStatusCarriesAnUpdate() {
        let info = UpdateInfo(version: "2.0")
        XCTAssertEqual(UpdateChecker.Status.available(info).update, info)
        XCTAssertFalse(UpdateChecker.Status.available(info).isFailure)
        XCTAssertFalse(UpdateChecker.Status.upToDate(current: "2.0", published: "2.0").isFailure)
        XCTAssertNil(UpdateChecker.Status.upToDate(current: "2.0", published: nil).update)
        XCTAssertTrue(UpdateChecker.Status.offline(why: "x").isFailure)
        XCTAssertTrue(UpdateChecker.Status.unreadableFeed(path: "x").isFailure)
    }

    // MARK: - Change log

    func test_theChangeLogHoldsEveryVersionNewerThanTheApp() throws {
        let json = """
        { "version": "2.0.14", "notes": "Ring.",
          "history": [ { "version": "2.0.14", "notes": "Ring." },
                       { "version": "2.0.13", "notes": "Faster." },
                       { "version": "2.0.12", "notes": "Discs." } ] }
        """
        let u = try JSONDecoder().decode(UpdateInfo.self, from: Data(json.utf8))
        XCTAssertEqual(u.changes(since: "2.0.12").map(\.version), ["2.0.14", "2.0.13"])
    }

    func test_aFeedWithoutHistoryStillGivesItsOwnNotes() throws {
        let u = try JSONDecoder().decode(UpdateInfo.self, from: Data(#"{"version":"2.0.14"}"#.utf8))
        XCTAssertEqual(u.changes(since: "2.0.13").map(\.version), ["2.0.14"])
    }
}
