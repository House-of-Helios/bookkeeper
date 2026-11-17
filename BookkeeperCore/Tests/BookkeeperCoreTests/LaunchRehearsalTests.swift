import XCTest
@testable import BookkeeperCore

/// `--rehearse-launch <dir>` names the data root, ahead of every other way to name one,
/// so a rehearsal can't land in the real folder.
final class LaunchRehearsalTests: XCTestCase {

    func test_theFlagNamesTheFolder() {
        XCTAssertEqual(LaunchRehearsal.requestedDirectory(arguments: ["app", "--rehearse-launch", "/tmp/r"])?.path,
                       "/tmp/r")
        XCTAssertNil(LaunchRehearsal.requestedDirectory(arguments: ["app"]))
        XCTAssertNil(LaunchRehearsal.requestedDirectory(arguments: ["app", "--rehearse-launch"]))
        XCTAssertNil(LaunchRehearsal.requestedDirectory(arguments: ["app", "--rehearse-launch", "  "]))
    }

    func test_theRehearsalFolderWinsOverEveryOtherRoot() {
        let root = DataRoot.resolve(arguments: ["app", "--data-dir", "/tmp/dev", "--rehearse-launch", "/tmp/r"],
                                    environment: [DataRoot.environmentKey: "/tmp/env"],
                                    info: [DataRoot.infoKey: "/tmp/info"],
                                    fallback: URL(fileURLWithPath: "/tmp/fallback"))
        XCTAssertEqual(root.path, "/tmp/r")
    }

    func test_safeOnlyWhenTheLiveRootIsTheRehearsalFolder() {
        let dir = URL(fileURLWithPath: "/tmp/r", isDirectory: true)
        XCTAssertTrue(LaunchRehearsal.isSafe(dir, liveRoot: URL(fileURLWithPath: "/tmp/r/")))
        XCTAssertFalse(LaunchRehearsal.isSafe(dir, liveRoot: URL(fileURLWithPath: "/tmp/other")))
        XCTAssertFalse(LaunchRehearsal.isSafe(DataRoot.defaultURL, liveRoot: DataRoot.defaultURL),
                       "never the real folder, even if both agree")
    }
}
