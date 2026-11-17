import XCTest
@testable import BookkeeperCore

final class SecretStoreTests: XCTestCase {

    // Creates a fresh temporary directory per test to avoid cross-test pollution.
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookkeeperCoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Round-trip

    func test_addTwoWalletsAndKey_roundTripsCorrectly() {
        let dir = makeTempDir()
        let store1 = SecretStore(directory: dir)

        let w1 = WalletSecret(nickname: "Cold Vault")
        let w2 = WalletSecret(nickname: "Daily")

        store1.addWallet(w1)
        store1.addWallet(w2)
        store1.setAPIKey("SOME_SERVICE", "secret-value-xyz")

        // Fresh store reading from the same directory — simulates app relaunch
        let store2 = SecretStore(directory: dir)
        let loaded = store2.loadWallets()

        XCTAssertEqual(loaded.count, 2, "should reload both wallets")
        XCTAssertEqual(loaded[0], w1, "first wallet should round-trip exactly")
        XCTAssertEqual(loaded[1], w2, "second wallet should round-trip exactly")
        XCTAssertEqual(store2.apiKey("SOME_SERVICE"), "secret-value-xyz",
                       "API key should survive reload")
    }

    // MARK: - Remove

    func test_removeWallet_leavesOnlyTheOtherOne() {
        let dir = makeTempDir()
        let store = SecretStore(directory: dir)

        let w1 = WalletSecret(nickname: "Alpha")
        let w2 = WalletSecret(nickname: "Beta")

        store.addWallet(w1)
        store.addWallet(w2)
        store.removeWallet(nickname: "Alpha")

        let remaining = store.loadWallets()
        XCTAssertEqual(remaining.count, 1, "exactly one wallet should remain after removal")
        XCTAssertEqual(remaining[0].nickname, "Beta", "surviving wallet should be Beta")
    }

    // MARK: - API key update / removal

    func test_setAPIKey_nil_removesKey() {
        let dir = makeTempDir()
        let store = SecretStore(directory: dir)
        store.setAPIKey("MY_KEY", "initial")
        XCTAssertEqual(store.apiKey("MY_KEY"), "initial")

        store.setAPIKey("MY_KEY", nil)
        XCTAssertNil(store.apiKey("MY_KEY"), "key should be gone after setting nil")
    }

    func test_setAPIKey_overwrite_replacesValue() {
        let dir = makeTempDir()
        let store = SecretStore(directory: dir)
        store.setAPIKey("API", "v1")
        store.setAPIKey("API", "v2")
        XCTAssertEqual(store.apiKey("API"), "v2", "overwrite should store the new value only")
    }

    // MARK: - Empty store

    func test_emptyStore_returnsNoWallets() {
        let dir = makeTempDir()
        let store = SecretStore(directory: dir)
        XCTAssertTrue(store.loadWallets().isEmpty, "fresh store should have no wallets")
        XCTAssertNil(store.apiKey("MISSING"), "fresh store should have no keys")
    }

    // MARK: - Files written before scanning was removed

    /// A wallet line written by an older build carries an address and a scan-chain list
    /// in fields 2 and 3. Those columns are retired, but the file on the user's disk
    /// still has them — and `network` is read positionally, so mis-reading the old shape
    /// would silently relabel every manual wallet. It must still load, address ignored.
    func test_aLineFromBeforeScanningStillLoads() {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("wallets.txt")
        try? "Cold Vault\t0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1\tethereum,arbitrum\tSia"
            .write(to: file, atomically: true, encoding: .utf8)

        let loaded = SecretStore(directory: dir).loadWallets()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.nickname, "Cold Vault")
        XCTAssertEqual(loaded.first?.network, "Sia", "the 4th field is still the network label")
    }

    /// And the address does not survive a rewrite: once the file is touched, the column
    /// goes out empty. There is nothing to scan, so there is no reason to keep a secret.
    func test_rewritingDropsTheOldAddress() {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("wallets.txt")
        try? "Cold Vault\t0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA1\tethereum\t"
            .write(to: file, atomically: true, encoding: .utf8)

        let store = SecretStore(directory: dir)
        store.addWallet(WalletSecret(nickname: "Daily"))   // any write rewrites the file
        store.removeWallet(nickname: "Daily")

        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("0xAAAA"), "no address is written back")
        XCTAssertTrue(text.contains("Cold Vault"), "the wallet itself survives")
    }
}
