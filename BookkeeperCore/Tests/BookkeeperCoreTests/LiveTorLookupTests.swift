import XCTest
@testable import BookkeeperCore

/// Live: a coin looked up by name through a running Bookkeeper Dev's Tor (port 3841).
/// Skipped unless BOOKKEEPER_LIVE_TOR=1 — it needs the network and Arti up.
final class LiveTorLookupTests: XCTestCase {
    func test_aaveResolvesByNameThroughTor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOOKKEEPER_LIVE_TOR"] == "1")
        Net.torPort = 3841
        defer { Net.torPort = nil }
        let found = await TokenLocator(search: CoinGeckoSearchService()).find("AAVE")
        print("FOUND", String(describing: found))
        XCTAssertEqual(found?.symbol.uppercased(), "AAVE")
    }
}
