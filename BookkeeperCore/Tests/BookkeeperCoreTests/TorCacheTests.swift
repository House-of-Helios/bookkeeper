import XCTest
@testable import BookkeeperCore

final class TorCacheTests: XCTestCase {
    func testCacheOverTheLimitIsRemovedAndUnderItIsKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("cache/dir_blobs")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 600).write(to: cache.appendingPathComponent("a"))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(TorCache.trim(root.appendingPathComponent("cache"), limit: 1000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        try Data(count: 600).write(to: cache.appendingPathComponent("b"))
        XCTAssertTrue(TorCache.trim(root.appendingPathComponent("cache"), limit: 1000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
        XCTAssertFalse(TorCache.trim(root.appendingPathComponent("cache"), limit: 1000)) // missing folder: nothing to do
    }
}
