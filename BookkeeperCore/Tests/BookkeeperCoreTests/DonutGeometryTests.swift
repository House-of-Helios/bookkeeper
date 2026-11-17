import XCTest
@testable import BookkeeperCore

final class DonutGeometryTests: XCTestCase {
    func test_wedgesCover360AndAreContiguous() {
        let w = DonutGeometry.wedges(fractions: [1, 1, 2])  // 25/25/50
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0].startAngle, 0, accuracy: 0.0001)
        XCTAssertEqual(w[0].endAngle, 90, accuracy: 0.0001)
        XCTAssertEqual(w[1].startAngle, 90, accuracy: 0.0001)
        XCTAssertEqual(w[2].endAngle, 360, accuracy: 0.0001)
    }

    func test_emptyOrZeroInputReturnsEmpty() {
        XCTAssertTrue(DonutGeometry.wedges(fractions: []).isEmpty)
        XCTAssertTrue(DonutGeometry.wedges(fractions: [0, 0]).isEmpty)
    }
}
