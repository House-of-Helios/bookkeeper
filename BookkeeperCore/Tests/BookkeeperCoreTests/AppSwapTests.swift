import XCTest
@testable import BookkeeperCore

/// The swap on fake bundles in a temp folder: the new build in, the old one gone, nothing
/// left beside it — and on failure, the installed app exactly where it was.
final class AppSwapTests: XCTestCase {
    private var root: URL!
    private var installed: URL { root.appendingPathComponent("Bookkeeper.app") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bk-swap-\(UUID().uuidString)")
        try makeApp(at: installed, version: "2.0.1")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeApp(at url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("Contents/version"), atomically: true, encoding: .utf8)
    }

    private func version(_ url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/version"), encoding: .utf8)
    }

    private var entries: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted() }

    func test_theNewBuildTakesTheNameAndNothingIsLeftBeside() throws {
        let staged = AppSwap.stagedURL(for: installed)
        XCTAssertEqual(staged.lastPathComponent, ".Bookkeeper.app.update")
        try makeApp(at: staged, version: "2.0.2")
        try AppSwap.swap(installed: installed, staged: staged)
        XCTAssertEqual(version(installed), "2.0.2")
        XCTAssertEqual(entries, ["Bookkeeper.app"], "no old copy, no staged copy, no (previous)")
    }

    func test_aMissingStagedBuildPutsTheAppBack() {
        XCTAssertThrowsError(try AppSwap.swap(installed: installed, staged: AppSwap.stagedURL(for: installed))) {
            XCTAssertEqual($0 as? AppSwap.Failure, .couldNotMoveIn)
        }
        XCTAssertEqual(version(installed), "2.0.1", "the installed app is where it was")
        XCTAssertEqual(entries, ["Bookkeeper.app"])
    }

    func test_leftoversFromAnyUpdateAreCleared() throws {
        try makeApp(at: root.appendingPathComponent("Bookkeeper (previous).app"), version: "2.0.0")
        try makeApp(at: AppSwap.oldURL(for: installed), version: "2.0.0")
        try makeApp(at: AppSwap.stagedURL(for: installed), version: "2.0.2")
        XCTAssertEqual(AppSwap.clearLeftovers(for: installed).count, 3)
        XCTAssertEqual(entries, ["Bookkeeper.app"])
        XCTAssertEqual(version(installed), "2.0.1", "the app itself is never touched")
    }
}
