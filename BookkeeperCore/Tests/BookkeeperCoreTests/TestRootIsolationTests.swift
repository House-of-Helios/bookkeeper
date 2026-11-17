import XCTest
@testable import BookkeeperCore

/// The whole test run lives in a throwaway data root. Anything that falls back to
/// `DataRoot.url` — the debug log, a store built without a directory — must land there,
/// never in the owner's `Application Support/Bookkeeper/`.
final class TestRootIsolationTests: XCTestCase {

    func test_underTestTheLiveRootIsNotTheDefault() {
        XCTAssertNotEqual(DataRoot.url.standardizedFileURL.path,
                          DataRoot.defaultURL.standardizedFileURL.path)
    }

    func test_underTestTheLiveRootIsATemporaryFolder() {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(DataRoot.url.resolvingSymlinksInPath().path.hasPrefix(tmp),
                      "live root under test is \(DataRoot.url.path)")
    }

    func test_theDebugLogWritesIntoTheTestRoot() throws {
        BookkeeperLog.note("🧪 isolation probe")
        let log = DataRoot.url.appendingPathComponent("debug.log")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("🧪 isolation probe"))
    }
}
