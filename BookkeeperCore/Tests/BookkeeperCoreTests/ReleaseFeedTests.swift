import CryptoKit
import XCTest
@testable import BookkeeperCore

/// GitHub updates: nothing is unpacked unless the zip matches its fingerprint and the
/// fingerprint is signed by the release key for that exact version. Served from file://
/// URLs laid out like a release, so no network.
final class ReleaseFeedTests: XCTestCase {

    private var root: URL!
    private let key = Curve25519.Signing.PrivateKey()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bk-release-\(UUID().uuidString)")
        let app = root.appendingPathComponent("build/Bookkeeper.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "hello".write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let release = root.appendingPathComponent("download/v9.9.9", isDirectory: true)
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", root.appendingPathComponent("build/Bookkeeper.app").path,
                       release.appendingPathComponent("Bookkeeper.zip").path]
        try p.run(); p.waitUntilExit()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var zip: URL { root.appendingPathComponent("download/v9.9.9/Bookkeeper.zip") }

    private func feed() -> ReleaseFeed {
        ReleaseFeed(feedURL: root.appendingPathComponent("appcast.json"),
                    downloadBase: root.appendingPathComponent("download"),
                    publicKey: key.publicKey, session: .shared)
    }

    private func signed(version: String = "9.9.9", sha: String? = nil, by signer: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateInfo {
        let digest = try sha ?? SHA256.hash(data: Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        let sig = try (signer ?? key).signature(for: Data("\(version)\n\(digest)".utf8)).base64EncodedString()
        return UpdateInfo(version: version, notes: "n", file: "Bookkeeper.zip", sha256: digest, signature: sig)
    }

    private var work: URL { root.appendingPathComponent("work") }

    func test_aSignedReleaseUnpacksToItsApp() async throws {
        let out = try await feed().fetch(try signed(), into: work)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Bookkeeper.app/Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("Bookkeeper.zip").path),
                       "the zip is gone once unpacked")
    }

    func test_aChangedZipIsRefused() async throws {
        let info = try signed()
        try Data("tampered".utf8).write(to: zip)
        do { _ = try await feed().fetch(info, into: work); XCTFail("installed a tampered zip") }
        catch let f as ReleaseFeed.Failure { XCTAssertEqual(f, .fingerprint) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("unpacked").path))
    }

    func test_aSignatureForAnotherVersionOrKeyIsRefused() async throws {
        let other = try signed(version: "1.0.0")
        let relabelled = UpdateInfo(version: "9.9.9", file: "Bookkeeper.zip", sha256: other.sha256, signature: other.signature)
        for info in [relabelled, try signed(by: Curve25519.Signing.PrivateKey())] {
            do { _ = try await feed().fetch(info, into: work); XCTFail("accepted a bad signature") }
            catch let f as ReleaseFeed.Failure { XCTAssertEqual(f, .signature) }
        }
    }

    func test_anUnsignedReleaseIsRefused() async throws {
        do { _ = try await feed().fetch(UpdateInfo(version: "9.9.9", file: "Bookkeeper.zip"), into: work); XCTFail() }
        catch let f as ReleaseFeed.Failure { XCTAssertEqual(f, .unsigned) }
    }

    func test_theFeedSaysWhatItFound() async throws {
        let info = try signed()
        try JSONEncoder().encode(info).write(to: root.appendingPathComponent("appcast.json"))
        let status = await feed().check(current: "2.0.0")
        XCTAssertEqual(status.update?.version, "9.9.9")
        let current = await feed().check(current: "9.9.9")
        XCTAssertEqual(current, .upToDate(current: "9.9.9", published: "9.9.9"))
    }

    /// The baked public key is a real key, so the app can't ship with one that never verifies.
    func test_theBakedKeyIsAKey() {
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: ReleaseFeed.publicKeyBase64)!))
    }
}
