import XCTest
@testable import BookkeeperCore

final class ChainTests: XCTestCase {
    func test_badgeLettersAreSingleUppercase() {
        XCTAssertEqual(Chain.ethereum.badge, "E")
        XCTAssertEqual(Chain.arbitrum.badge, "A")
        XCTAssertEqual(Chain.base.badge, "B")
    }

    func test_allChainsHaveDistinctBadges() {
        let badges = Chain.allCases.map(\.badge)
        XCTAssertEqual(Set(badges).count, badges.count)
    }
}
