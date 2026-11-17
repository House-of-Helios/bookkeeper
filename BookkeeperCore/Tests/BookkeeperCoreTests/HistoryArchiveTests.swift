import XCTest
@testable import BookkeeperCore

/// The archive is the one file in the app that cannot be rebuilt from anywhere — a
/// missed day is gone, and a mangled one is a lie in a chart. So these cover the format
/// boundary hardest: old lines must keep loading, and a wallet's own typed nickname must
/// survive a round trip whatever is in it.
final class HistoryArchiveTests: XCTestCase {

    private func make() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-hist-\(UUID().uuidString)")
        return (HistoryStore(directory: dir), dir)
    }

    private let day = TimeInterval(86_400)

    func test_anArchiveRoundTripsWithItsBreakdown() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        h.archive(total: 128_000, breakdown: ["Cold Vault": 54_000, "Daily": 74_000])

        let points = h.load()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.total, 128_000)
        XCTAssertEqual(points.first?.breakdown["Cold Vault"], 54_000)
        XCTAssertEqual(points.first?.breakdown["Daily"], 74_000)
    }

    /// The reason the breakdown is JSON and not more tab-separated pairs: a nickname is
    /// typed by the user and can hold the characters a homemade format would break on.
    func test_awkwardWalletNamesSurvive() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Cold, Vault", "a:b", #"quote " inside"#, "emoji 🔐", "back\\slash"]
        var breakdown: [String: Decimal] = [:]
        for (i, n) in names.enumerated() { breakdown[n] = Decimal(i + 1) * 1000 }
        h.archive(total: 15_000, breakdown: breakdown)

        let loaded = h.load().first?.breakdown ?? [:]
        XCTAssertEqual(Set(loaded.keys), Set(names))
        XCTAssertEqual(loaded["Cold, Vault"], 1000)
        XCTAssertEqual(loaded[#"quote " inside"#], 3000)
    }

    /// Two-field lines are what every mark written before this change looks like. They
    /// must still load — that file is the user's real history.
    func test_linesWrittenBeforeBreakdownsExistedStillLoad() throws {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = "1700000000\t95000.5\n1700086400\t97250.25\n"
        try legacy.write(to: dir.appendingPathComponent("history.csv"),
                         atomically: true, encoding: .utf8)

        let points = h.load()
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.total, Decimal(string: "95000.5"))
        XCTAssertTrue(points.first?.breakdown.isEmpty == true, "no breakdown, but not dropped")
    }

    /// And a new mark alongside them must not destroy them.
    func test_archivingKeepsTheOldLines() throws {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "1700000000\t95000\n".write(to: dir.appendingPathComponent("history.csv"),
                                        atomically: true, encoding: .utf8)

        h.archive(total: 101_000, breakdown: ["Daily": 101_000])

        let points = h.load()
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.total, 95_000, "the old mark is still first")
        XCTAssertEqual(points.last?.breakdown["Daily"], 101_000)
    }

    /// One mark per day. Pressing again means "no, THIS is today's figure".
    func test_archivingTwiceInADayReplacesRatherThanAppends() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        // A real noon: `Date()` plus an hour crosses midnight when the suite runs after 23:00.
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        h.archive(total: 100_000, breakdown: ["Daily": 100_000], on: noon)
        h.archive(total: 103_500, breakdown: ["Daily": 103_500], on: noon.addingTimeInterval(3600))

        XCTAssertEqual(h.load().count, 1)
        XCTAssertEqual(h.load().first?.total, 103_500)
    }

    func test_separateDaysAreSeparateMarks() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let today = Date()
        h.archive(total: 100_000, on: today.addingTimeInterval(-2 * day))
        h.archive(total: 101_000, on: today.addingTimeInterval(-day))
        h.archive(total: 102_000, on: today)
        XCTAssertEqual(h.load().count, 3)
        XCTAssertEqual(h.load().map(\.total), [100_000, 101_000, 102_000], "oldest first")
    }

    func test_hasMarkAnswersForTodayOnly() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(h.hasMark())
        h.archive(total: 100_000, on: Date().addingTimeInterval(-day))
        XCTAssertFalse(h.hasMark(), "yesterday's mark is not today's")
        h.archive(total: 100_000)
        XCTAssertTrue(h.hasMark())
    }

    /// A hand-made archive needs a way back out of a mistake.
    func test_aMarkCanBeRemoved() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let today = Date()
        h.archive(total: 100_000, on: today.addingTimeInterval(-day))
        h.archive(total: 999_999, on: today)
        h.removeMark(on: today)
        XCTAssertEqual(h.load().map(\.total), [100_000])
    }

    func test_aZeroTotalIsNotArchived() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(h.archive(total: 0))
        XCTAssertTrue(h.load().isEmpty, "an empty portfolio is not a data point")
    }

    /// Decimals must not drift through the file — this is money.
    func test_valuesSurviveExactly() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let exact = Decimal(string: "128456.789012")!
        h.archive(total: exact, breakdown: ["W": exact])
        XCTAssertEqual(h.load().first?.total, exact)
        XCTAssertEqual(h.load().first?.breakdown["W"], exact)
    }
}

/// Archiving is a deliberate act now, not a side effect of refreshing.
final class ArchiveButtonTests: XCTestCase {

    func test_refreshDoesNotWriteAMark() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-noauto-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "cold"))
        ss.addManualHolding(ManualHolding(walletId: "cold", symbol: "XMR", amount: 2,
                                          coingeckoId: "monero", networkName: "Monero"))
        let history = HistoryStore(directory: dir)
        let store = await PortfolioStore(wallets: [], holdings: [], prices: [:], secret: ss,
                                         priceService: FixedPriceStub(["coingecko:monero": 150]),
                                         history: history)
        await store.refresh()

        XCTAssertTrue(history.load().isEmpty,
                      "a refresh landing is not a day worth recording")

        let wrote = await store.archiveToday()
        XCTAssertTrue(wrote)
        XCTAssertEqual(history.load().count, 1, "the button is what records")
        XCTAssertEqual(history.load().first?.total, 300)
        XCTAssertEqual(history.load().first?.breakdown["cold"], 300,
                       "and it records which wallet the value sat in")
    }
}


private struct FixedPriceStub: PriceService {
    let map: [String: Decimal]
    init(_ map: [String: Decimal]) { self.map = map }
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        map.filter { keys.contains($0.key) }
    }
}

/// The mock store exists to be rendered and demoed, which means it gets archived from.
/// It must never be able to reach the real history file — that has happened once.
final class MockArchiveIsolationTests: XCTestCase {

    /// The live root under test is a throwaway folder (`DataRoot.isUnderTest`), so this
    /// plants a known archive there and checks the mock leaves it byte-for-byte alone —
    /// without ever opening the owner's real `history.csv`.
    @MainActor
    func test_archivingFromTheMockNeverTouchesTheLiveRoot() throws {
        XCTAssertNotEqual(DataRoot.url.standardizedFileURL, DataRoot.defaultURL.standardizedFileURL,
                          "refusing to run against the real data folder")
        try FileManager.default.createDirectory(at: DataRoot.url, withIntermediateDirectories: true)
        let live = DataRoot.url.appendingPathComponent("history.csv")
        let planted = Data("1700000000\t123.45\n".utf8)
        let original = try? Data(contentsOf: live)
        try planted.write(to: live)
        defer {
            if let original { try? original.write(to: live) } else { try? FileManager.default.removeItem(at: live) }
        }

        let store = PortfolioStore.mock()
        XCTAssertTrue(store.archiveToday(), "the mock has values, so it does archive somewhere")

        XCTAssertEqual(try Data(contentsOf: live), planted, "the mock wrote into the live archive")
    }

    func test_theMockComesWithSomethingToDraw() {
        let store = PortfolioStore.mock()
        let points = store.historyPoints()
        XCTAssertGreaterThanOrEqual(points.count, 30, "the History tab needs a shape")
        XCTAssertFalse(points.last?.breakdown.isEmpty ?? true, "and a split to stack")
    }

    /// A fixture that moves every launch makes two rendered screens impossible to compare.
    func test_theSeededArchiveIsTheSameEveryTime() {
        let a = PortfolioStore.mock().historyPoints().map(\.total)
        let b = PortfolioStore.mock().historyPoints().map(\.total)
        XCTAssertEqual(a, b)
    }
}

/// A wallet's name is the archive's key, so a rename or a clean-up has to reach back
/// through every mark — otherwise one wallet shows as two columns, split at the day it
/// was renamed.
final class ArchivedWalletEditTests: XCTestCase {

    private func make() -> (HistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-hist-\(UUID().uuidString)")
        return (HistoryStore(directory: dir), dir)
    }

    private let day = TimeInterval(86_400)

    func test_renamingCarriesTheNameThroughEveryMarkAndLeavesTotalsAlone() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let d0 = Date(timeIntervalSince1970: 1_700_000_000)
        h.archive(total: 300, breakdown: ["Old": 100, "Daily": 200], on: d0)
        h.archive(total: 330, breakdown: ["Old": 110, "Daily": 220], on: d0 + day)

        h.renameWallet(from: "Old", to: "New")

        let points = h.load()
        XCTAssertEqual(points.map(\.total), [300, 330])
        XCTAssertEqual(points.map { $0.breakdown["New"] }, [100, 110])
        XCTAssertTrue(points.allSatisfy { $0.breakdown["Old"] == nil }, "no ghost column left")
    }

    /// The case the bug left behind: marks under the old name, later marks already under
    /// the new one. Folding them must add, never overwrite.
    func test_renamingOntoANameAMarkAlreadyHoldsAddsTheTwo() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        h.archive(total: 300, breakdown: ["Old": 100, "New": 50, "Daily": 150])
        h.renameWallet(from: "Old", to: "New")
        XCTAssertEqual(h.load().first?.breakdown["New"], 150)
        XCTAssertEqual(h.load().first?.total, 300)
    }

    func test_removingAWalletTakesItsDollarsOutOfEveryTotal() {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        let d0 = Date(timeIntervalSince1970: 1_700_000_000)
        h.archive(total: 300, breakdown: ["Dup": 100, "Daily": 200], on: d0)
        h.archive(total: 220, breakdown: ["Daily": 220], on: d0 + day)

        h.removeWallet("Dup")

        let points = h.load()
        XCTAssertEqual(points.map(\.total), [200, 220])
        XCTAssertTrue(points.allSatisfy { $0.breakdown["Dup"] == nil })
    }

    /// A mark that held only the removed wallet has nothing left to say — drop it rather
    /// than keep a $0 day in the chart. Marks from before breakdowns are untouched.
    func test_removingTheOnlyWalletInAMarkDropsTheMark() throws {
        let (h, dir) = make(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "1600000000\t95000\n".write(to: dir.appendingPathComponent("history.csv"),
                                         atomically: true, encoding: .utf8)
        h.archive(total: 80, breakdown: ["Test": 80], on: Date(timeIntervalSince1970: 1_700_000_000))

        h.removeWallet("Test")

        XCTAssertEqual(h.load().map(\.total), [95000], "legacy mark kept, emptied mark gone")
    }
}

/// Renaming on the Wallets tab is what split history in two. It has to rename the
/// archive in the same stroke.
final class RenameReachesHistoryTests: XCTestCase {

    @MainActor
    func test_renamingAWalletRenamesItInTheArchive() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "Old"))
        let history = HistoryStore(directory: dir)
        history.archive(total: 100, breakdown: ["Old": 100])
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss, history: history)

        await store.renameWallet(from: "Old", to: "New")

        XCTAssertEqual(history.load().first?.breakdown, ["New": 100])
    }

    /// A rename the wallet file refuses must not rename the archive either.
    @MainActor
    func test_aRefusedRenameLeavesTheArchiveAlone() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "Old"))
        let history = HistoryStore(directory: dir)
        history.archive(total: 100, breakdown: ["Old": 100])
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss, history: history)

        await store.renameWallet(from: "Old", to: "   ")

        XCTAssertEqual(history.load().first?.breakdown, ["Old": 100])
    }

    // MARK: - Recording on its own

    func test_aMonthlyMarkIsDueOnlyWhenTheMonthHasNone() {
        let cal = Calendar(identifier: .gregorian)
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        XCTAssertTrue(HistoryStore.isDue(.monthly, marks: [], now: d(2026, 10, 22), calendar: cal))
        XCTAssertTrue(HistoryStore.isDue(.monthly, marks: [d(2026, 9, 30)], now: d(2026, 10, 1), calendar: cal))
        XCTAssertFalse(HistoryStore.isDue(.monthly, marks: [d(2026, 10, 2)], now: d(2026, 10, 22), calendar: cal))
        XCTAssertFalse(HistoryStore.isDue(.manual, marks: [], now: d(2026, 10, 22), calendar: cal))
    }

    func test_twiceAMonthSplitsAtTheSixteenth() {
        let cal = Calendar(identifier: .gregorian)
        func d(_ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day))! }
        XCTAssertFalse(HistoryStore.isDue(.twiceMonthly, marks: [d(3)], now: d(15), calendar: cal))
        XCTAssertTrue(HistoryStore.isDue(.twiceMonthly, marks: [d(3)], now: d(16), calendar: cal))
        XCTAssertFalse(HistoryStore.isDue(.twiceMonthly, marks: [d(3), d(20)], now: d(31), calendar: cal))
    }

}
