import XCTest
@testable import BookkeeperCore

/// One folder holds everything, and one resolver names it. If a store could still build
/// its own path, isolating the others would leave it pointed at the real files.
final class DataRootTests: XCTestCase {

    private let fallback = URL(fileURLWithPath: "/fallback/Bookkeeper", isDirectory: true)

    func test_withNothingGivenTheDefaultIsUsed() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper"], environment: [:], fallback: fallback)
        XCTAssertEqual(url, fallback)
    }

    func test_theDefaultIsApplicationSupportBookkeeper() {
        XCTAssertEqual(DataRoot.defaultURL.lastPathComponent, "Bookkeeper")
        XCTAssertEqual(DataRoot.defaultURL.deletingLastPathComponent().lastPathComponent,
                       "Application Support")
    }

    func test_theEnvironmentReroutes() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper"],
                                   environment: ["BOOKKEEPER_DATA_DIR": "/tmp/bk-env"],
                                   fallback: fallback)
        XCTAssertEqual(url.path, "/tmp/bk-env")
    }

    func test_theArgumentReroutes() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir", "/tmp/bk-arg"],
                                   environment: [:], fallback: fallback)
        XCTAssertEqual(url.path, "/tmp/bk-arg")
    }

    func test_theArgumentBeatsTheEnvironment() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir", "/tmp/bk-arg"],
                                   environment: ["BOOKKEEPER_DATA_DIR": "/tmp/bk-env"],
                                   fallback: fallback)
        XCTAssertEqual(url.path, "/tmp/bk-arg")
    }

    /// `--data-dir` as the last word has no path after it; it must not swallow nothing
    /// and land the app in the current directory.
    func test_aDanglingArgumentFallsThrough() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir"],
                                   environment: ["BOOKKEEPER_DATA_DIR": "/tmp/bk-env"],
                                   fallback: fallback)
        XCTAssertEqual(url.path, "/tmp/bk-env")
    }

    func test_anEmptyEnvironmentValueCountsAsUnset() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper"],
                                   environment: ["BOOKKEEPER_DATA_DIR": "  "],
                                   fallback: fallback)
        XCTAssertEqual(url, fallback)
    }

    /// The Dev app names its folder in Info.plist, for Finder launches that drop
    /// `LSEnvironment`. Below the argument and the environment, above the default.
    func test_theInfoPlistKeyReroutes() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper"], environment: [:],
                                   info: ["BookkeeperDataDir": "/tmp/bk-info"], fallback: fallback)
        XCTAssertEqual(url.path, "/tmp/bk-info")
    }

    func test_theEnvironmentAndArgumentBeatTheInfoPlistKey() {
        let info: [String: Any] = ["BookkeeperDataDir": "/tmp/bk-info"]
        XCTAssertEqual(DataRoot.resolve(arguments: ["Bookkeeper"],
                                        environment: ["BOOKKEEPER_DATA_DIR": "/tmp/bk-env"],
                                        info: info, fallback: fallback).path, "/tmp/bk-env")
        XCTAssertEqual(DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir", "/tmp/bk-arg"],
                                        environment: [:], info: info, fallback: fallback).path, "/tmp/bk-arg")
    }

    func test_anEmptyInfoPlistKeyCountsAsUnset() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper"], environment: [:],
                                   info: ["BookkeeperDataDir": " "], fallback: fallback)
        XCTAssertEqual(url, fallback)
    }

    func test_aTildeExpands() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir", "~/bk-dev"],
                                   environment: [:], fallback: fallback)
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertEqual(url.lastPathComponent, "bk-dev")
    }

    func test_aRelativePathResolvesAgainstTheWorkingDirectory() {
        let url = DataRoot.resolve(arguments: ["Bookkeeper", "--data-dir", "_DevData"],
                                   environment: [:], fallback: fallback)
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertEqual(url.lastPathComponent, "_DevData")
    }
}

// MARK: - Launch preparation

private func tempRoot(_ tag: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bk-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

/// The first 2.0 launch copies the v1 files aside before anything else touches them —
/// the hand-rollback for a bad update on a machine with no other copy.
final class V1BackupTests: XCTestCase {

    func test_theFirstLaunchCopiesEveryV1File() throws {
        let root = tempRoot("bak"); defer { try? FileManager.default.removeItem(at: root) }
        try "w".write(to: root.appendingPathComponent("wallets.txt"), atomically: true, encoding: .utf8)
        try "h".write(to: root.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
        try "q".write(to: root.appendingPathComponent("quotes.json"), atomically: true, encoding: .utf8)

        let copied = V1Backup.runIfNeeded(root: root)

        XCTAssertEqual(Set(copied), ["wallets.txt", "history.csv", "quotes.json"])
        let dest = V1Backup.directory(in: root)
        XCTAssertEqual(dest.path, root.appendingPathComponent("backups/pre-2.0.0").path)
        for (name, body) in [("wallets.txt", "w"), ("history.csv", "h"), ("quotes.json", "q")] {
            let f = dest.appendingPathComponent(name)
            XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), body)
            XCTAssertEqual(permissions(f), 0o600, "\(name) is owner-only")
        }
        XCTAssertEqual(permissions(dest), 0o700)
        XCTAssertEqual(permissions(dest.deletingLastPathComponent()), 0o700)
    }

    func test_onlyTheFilesPresentAreCopied() throws {
        let root = tempRoot("bak1"); defer { try? FileManager.default.removeItem(at: root) }
        try "h".write(to: root.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(V1Backup.runIfNeeded(root: root), ["history.csv"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: V1Backup.directory(in: root).appendingPathComponent("wallets.txt").path))
    }

    /// The backup is of 1.x. A second launch — by then 2.0 has been writing — must never
    /// replace it with 2.0's files.
    func test_anExistingBackupIsNeverOverwritten() throws {
        let root = tempRoot("bak2"); defer { try? FileManager.default.removeItem(at: root) }
        let wallets = root.appendingPathComponent("wallets.txt")
        try "v1".write(to: wallets, atomically: true, encoding: .utf8)
        V1Backup.runIfNeeded(root: root)

        try "v2".write(to: wallets, atomically: true, encoding: .utf8)
        try "new".write(to: root.appendingPathComponent("history.csv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(V1Backup.runIfNeeded(root: root), [])

        let dest = V1Backup.directory(in: root)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("wallets.txt"), encoding: .utf8), "v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("history.csv").path),
                       "not even topped up with a file the first backup didn't have")
    }

    func test_aFreshInstallMakesNoBackup() {
        let root = tempRoot("bak3"); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(V1Backup.runIfNeeded(root: root), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    /// Icons and price curves download again on their own; copying them is bulk for nothing.
    func test_cachesAreNotBackedUp() throws {
        let root = tempRoot("bak4"); defer { try? FileManager.default.removeItem(at: root) }
        try "w".write(to: root.appendingPathComponent("wallets.txt"), atomically: true, encoding: .utf8)
        let icons = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try Data([0x89]).write(to: icons.appendingPathComponent("cg_monero.png"))

        V1Backup.runIfNeeded(root: root)
        let items = try FileManager.default.contentsOfDirectory(atPath: V1Backup.directory(in: root).path)
        XCTAssertEqual(items, ["wallets.txt"])
    }
}

final class SpendingFolderTests: XCTestCase {

    func test_theFolderAndSchemaAreCreated() throws {
        let root = tempRoot("sp"); defer { try? FileManager.default.removeItem(at: root) }
        SpendingFolder.ensure(root: root)

        let dir = root.appendingPathComponent("spending")
        XCTAssertEqual(permissions(dir), 0o700)
        let schema = dir.appendingPathComponent("schema.json")
        XCTAssertEqual(permissions(schema), 0o600)
        let decoded = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: schema))
        XCTAssertEqual(decoded, ["version": 1])
    }

    func test_anExistingSchemaIsLeftAlone() throws {
        let root = tempRoot("sp2"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("spending")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = dir.appendingPathComponent("schema.json")
        try #"{ "version": 7 }"#.write(to: schema, atomically: true, encoding: .utf8)

        SpendingFolder.ensure(root: root)
        XCTAssertEqual(try String(contentsOf: schema, encoding: .utf8), #"{ "version": 7 }"#)
    }

    // MARK: Upgrades

    private func folder(_ name: String, version: Int) throws -> (root: URL, dir: URL) {
        let root = tempRoot(name)
        let dir = root.appendingPathComponent("spending")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ \"version\": \(version) }".write(to: dir.appendingPathComponent("schema.json"),
                                                atomically: true, encoding: .utf8)
        try "old".write(to: dir.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8)
        return (root, dir)
    }

    private func backups(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("backups").path)) ?? []).sorted()
    }

    func test_upgradeRunsEachStepInOrderAfterABackup() throws {
        let (root, dir) = try folder("up", version: 1); defer { try? FileManager.default.removeItem(at: root) }
        var ran: [Int] = []
        let steps: [Int: (URL) throws -> Void] = [
            1: { d in ran.append(1); try "v2".write(to: d.appendingPathComponent("accounts.json"), atomically: true, encoding: .utf8) },
            2: { _ in ran.append(2) },
        ]
        XCTAssertEqual(SpendingFolder.upgrade(root: root, steps: steps, current: 3), .migrated(from: 1, to: 3))
        XCTAssertEqual(ran, [1, 2])
        XCTAssertEqual(SpendingFolder.storedVersion(in: dir), 3)
        let saved = backups(dir)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].hasPrefix("pre-v3-"))
        let copy = dir.appendingPathComponent("backups/\(saved[0])/accounts.json")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "old")
        // A second launch has nothing to do.
        XCTAssertEqual(SpendingFolder.upgrade(root: root, steps: steps, current: 3), .current)
        XCTAssertEqual(ran, [1, 2])
    }

    func test_newerDataIsLeftUntouched() throws {
        let (root, dir) = try folder("newer", version: 9); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(SpendingFolder.upgrade(root: root, steps: [:], current: 1), .newer(9))
        XCTAssertEqual(SpendingFolder.storedVersion(in: dir), 9)
        XCTAssertEqual(backups(dir), [])
    }

    func test_aFailedStepStopsAtItsVersionWithTheBackupKept() throws {
        let (root, dir) = try folder("fail", version: 1); defer { try? FileManager.default.removeItem(at: root) }
        struct Boom: Error {}
        let steps: [Int: (URL) throws -> Void] = [1: { _ in }, 2: { _ in throw Boom() }]
        guard case .failed(at: 2, _) = SpendingFolder.upgrade(root: root, steps: steps, current: 3) else {
            return XCTFail("expected a failure at version 2")
        }
        XCTAssertEqual(SpendingFolder.storedVersion(in: dir), 2)
        XCTAssertEqual(backups(dir).count, 1)
    }

    /// An old build opening a newer build's folder: it reads what it can, renames nothing,
    /// and writes nothing.
    func test_theStoreOpensANewerFolderReadOnly() throws {
        let (root, dir) = try folder("ro", version: SpendingFolder.schemaVersion + 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpendingStore(directory: dir)
        XCTAssertNotNil(store.locked)
        XCTAssertEqual(store.saveFailure, store.locked)
        // "old" is not valid JSON for this build — a newer shape, not damage: kept in place.
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("accounts.json"), encoding: .utf8), "old")

        store.addAccount(name: "Test", colorHex: "#000000")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("accounts.json"), encoding: .utf8), "old")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["accounts.json", "schema.json"])
    }
}

// MARK: - v1 survives 2.0

private struct OfflinePrices: PriceService {
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, Decimal(1)) })
    }
}

private struct OfflineSearch: CoinSearchService {
    func coinId(forSymbol symbol: String) async -> String? { nil }
}

/// A frozen 1.x data folder (`Fixtures/v1`, synthetic) goes through everything 2.0 does
/// on launch, and every v1 file must come out byte for byte what went in.
final class V1SurvivesUpdateTests: XCTestCase {

    private static let v1Files = ["wallets.txt", "history.csv", "quotes.json"]

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: nil,
                                        subdirectory: "Fixtures"))
    }

    /// The fixture copied into a fresh temp root — the test never runs against the
    /// bundled copy, so a write would show up as a diff rather than a corrupted fixture.
    private func stagedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: try fixture(), to: root)
        return root
    }

    private func bytes(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in Self.v1Files { out[name] = try Data(contentsOf: dir.appendingPathComponent(name)) }
        return out
    }

    private func makeStore(_ root: URL) -> PortfolioStore {
        PortfolioStore(wallets: [], holdings: [], prices: [:],
                       secret: SecretStore(directory: root),
                       priceService: OfflinePrices(),
                       searchService: OfflineSearch(),
                       history: HistoryStore(directory: root))
    }

    func test_theFixtureCoversEveryLineKind() throws {
        let text = try String(contentsOf: try fixture().appendingPathComponent("wallets.txt"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        for kind in ["#key\tupdateFolder\t", "#key\tcoingecko\t", "#wmeta\t", "#wpos\t", "#worder\t", "#hide\t"] {
            XCTAssertTrue(lines.contains { $0.hasPrefix(kind) }, "fixture lacks \(kind)")
        }
        let manualFields = Set(lines.filter { $0.hasPrefix("#manual\t") }
            .map { $0.components(separatedBy: "\t").count })
        XCTAssertEqual(manualFields, [5, 8], "both the old 5-field and the 8-field #manual")
        XCTAssertTrue(lines.contains { !$0.hasPrefix("#") && $0.components(separatedBy: "\t")[1].hasPrefix("0x") },
                      "and a wallet line still carrying a retired address")
        let history = try String(contentsOf: try fixture().appendingPathComponent("history.csv"), encoding: .utf8)
        let widths = Set(history.split(separator: "\n").map { $0.components(separatedBy: "\t").count })
        XCTAssertEqual(widths, [2, 3])
    }

    func test_v1FilesAreByteIdenticalAfterA2Point0Launch() throws {
        let root = try stagedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try bytes(try fixture())

        DataRoot.prepareForLaunch(at: root)
        let store = makeStore(root)
        let secret = SecretStore(directory: root)

        // Everything 1.x wrote still reads through the 2.0 parsers.
        XCTAssertTrue(store.hasRealWallets)
        XCTAssertEqual(secret.loadWallets().map(\.nickname), ["Cold Vault", "Daily", "Old Scanner"])
        XCTAssertEqual(secret.manualHoldings().count, 3)
        // A retired setting from an older file is left in place and simply never read.
        XCTAssertEqual(secret.apiKey("updateFolder"), "/Volumes/Shared/updates")
        XCTAssertEqual(secret.walletColor("Cold Vault"), "#C73E3A")
        XCTAssertEqual(secret.walletPosition("Daily")?.x, 540.5)
        XCTAssertEqual(secret.walletOrder(), ["Daily", "Cold Vault", "Old Scanner"])
        XCTAssertEqual(store.hiddenIDs.count, 1)
        XCTAssertEqual(store.historyPoints().count, 4)
        XCTAssertEqual(store.historyPoints().last?.breakdown["Daily"], 11540)

        XCTAssertEqual(try bytes(root), before, "a v1 file changed on a 2.0 launch")
        // The backup is the same bytes too, owner-only.
        let backup = V1Backup.directory(in: root)
        XCTAssertEqual(try bytes(backup), before)
        for name in Self.v1Files {
            XCTAssertEqual(permissions(backup.appendingPathComponent(name)), 0o600)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("spending/schema.json").path))
    }

    /// Documents today's behaviour rather than wanting it: the first price refresh after
    /// launch re-saves `quotes.json` when the cached quotes are stale (always, on an
    /// update). That file is a cache — it was backed up, and nothing else is touched.
    /// Wallets and history stay byte-identical; a refresh never writes them.
    func test_aRefreshRewritesOnlyTheQuoteCache() async throws {
        let root = try stagedRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try bytes(try fixture())

        DataRoot.prepareForLaunch(at: root)
        let store = makeStore(root)
        await store.refresh()

        let after = try bytes(root)
        XCTAssertEqual(after["wallets.txt"], before["wallets.txt"])
        XCTAssertEqual(after["history.csv"], before["history.csv"])
        XCTAssertNotEqual(after["quotes.json"], before["quotes.json"],
                          "if this starts failing, refresh stopped re-saving stale quotes — good news, drop this test")
        XCTAssertEqual(try bytes(V1Backup.directory(in: root))["quotes.json"], before["quotes.json"],
                       "the original quotes are still in the backup")
    }
}

/// The synthetic bank exports (`scripts/gen-fake-bank-csvs.py`) ship with the tests —
/// Stage 2's importer reads them from here.
final class BankFixtureTests: XCTestCase {

    func test_everyBankShapeIsBundled() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "bank", withExtension: nil,
                                                  subdirectory: "Fixtures"))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        for shape in ["chase_card", "chase_checking", "bank_of_america_checking", "wells_fargo",
                      "capital_one", "amex", "citi", "discover", "apple_card",
                      "chase_card_2026-01_to_2026-03", "chase_card_2026-02_to_2026-04",
                      "chase_card_quoted_commas"] {
            XCTAssertTrue(names.contains("\(shape).csv"), "missing \(shape).csv")
        }
    }
}

/// Editing the demo turns it into the user's own wallets instead of blanking the screen.
final class DemoAdoptionTests: XCTestCase {
    @MainActor
    func test_aTokenAddedToADemoWalletAdoptsTheDemoAndLandsInIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bk-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = SecretStore(directory: root)
        let store = PortfolioStore(wallets: MockData.wallets, holdings: MockData.holdings, prices: MockData.prices,
                                   secret: secret, priceService: OfflinePrices(), searchService: OfflineSearch(),
                                   history: HistoryStore(directory: root))
        secret.addManualHolding(ManualHolding(walletId: "w1", symbol: "UNI", amount: 50,
                                              coingeckoId: "uniswap", networkName: "Arbitrum"))
        store.rebuildLocally()
        XCTAssertEqual(store.wallets.map(\.nickname), ["Cold Vault", "Daily"])
        XCTAssertEqual(store.visiblePricedRows.count, MockData.holdings.count + 1)
        XCTAssertTrue(store.rows(forWallet: "Cold Vault").contains { $0.token.symbol == "UNI" })
        XCTAssertFalse(secret.manualHoldings().contains { $0.walletId == "w1" })
        XCTAssertFalse(store.adoptDemoIfEdited(), "once is enough")
    }

    func test_aFileWithItsOwnWalletIsNeverAdopted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bk-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = SecretStore(directory: root)
        secret.addWallet(WalletSecret(nickname: "Mine"))
        secret.addManualHolding(ManualHolding(walletId: "w1", symbol: "UNI", amount: 50, coingeckoId: "uniswap"))
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:], secret: secret,
                                   priceService: OfflinePrices(), searchService: OfflineSearch(),
                                   history: HistoryStore(directory: root))
        XCTAssertFalse(store.adoptDemoIfEdited())
        XCTAssertEqual(secret.loadWallets().map(\.nickname), ["Mine"])
    }
}
