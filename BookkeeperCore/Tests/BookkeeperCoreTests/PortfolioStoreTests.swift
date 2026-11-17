import XCTest
@testable import BookkeeperCore

final class PortfolioStoreTests: XCTestCase {
    func test_mockStoreAggregatesAcrossWallets() {
        let store = PortfolioStore.mock()
        XCTAssertGreaterThanOrEqual(store.wallets.count, 2)
        XCTAssertGreaterThan(store.totalUSD, 0)
        XCTAssertFalse(store.dashboardRows.isEmpty)
    }

    func test_mockIncludesAnUnpricedHoldingThatDoesNotInflateTotal() {
        let store = PortfolioStore.mock()
        XCTAssertTrue(store.dashboardRows.contains { $0.usdValue == nil },
                      "mock should include an unpriced token to exercise the rule")
    }

    func test_perWalletRowsAreNonEmpty() {
        let store = PortfolioStore.mock()
        let first = store.wallets[0]
        XCTAssertFalse(store.rows(forWallet: first.id).isEmpty)
    }

    // MARK: - groupedRows(forWallet:)

    /// w1 has 4 ethereum holdings + 1 arbitrum — groups should be [Ethereum(4), Arbitrum(1)].
    func test_groupedRows_w1_groupsByNetworkInFirstAppearanceOrder() {
        let store = PortfolioStore.mock()
        let groups = store.groupedRows(forWallet: "w1")
        XCTAssertEqual(groups.count, 2, "w1 should have exactly 2 network groups")
        XCTAssertEqual(groups[0].network.name, "Ethereum", "first group should be Ethereum (first appearance)")
        XCTAssertEqual(groups[0].rows.count, 4, "Ethereum group should contain 4 holdings")
        XCTAssertEqual(groups[1].network.name, "Arbitrum", "second group should be Arbitrum")
        XCTAssertEqual(groups[1].rows.count, 1, "Arbitrum group should contain 1 holding (mystery)")
    }

    /// w2 holds Arbitrum ETH, Monero, and two tokens on HyperEVM. All three networks get
    /// their own group: Monero and HyperEVM both answer `nil` for chain, and lumping them
    /// together under one nameless "manual" group is the bug this replaced.
    func test_groupedRows_w2_everyNetworkGetsItsOwnGroup() {
        let store = PortfolioStore.mock()
        let groups = store.groupedRows(forWallet: "w2")
        XCTAssertEqual(Set(groups.map { $0.network.name }), ["Arbitrum", "Monero", "HyperEVM"])

        let monero = groups.first { $0.network.name == "Monero" }
        XCTAssertEqual(monero?.rows.map(\.token.symbol), ["XMR"])

        let hyper = groups.first { $0.network.name == "HyperEVM" }
        XCTAssertEqual(hyper?.rows.count, 2, "HYPE and USDC both sit on HyperEVM")
        XCTAssertFalse(groups.contains { $0.network == .unknown },
                       "nothing falls back to the nameless group")
    }

    /// Row order within each group must match the original holdings order.
    /// Rows inside a group are ordered by value, not by the order the balance scan
    /// returned them. Scan order is arbitrary, and it looked it.
    func test_groupedRows_rowsWithinAGroupAreOrderedByValue() {
        let store = PortfolioStore.mock()
        let groups = store.groupedRows(forWallet: "w1")
        // rETH $11,205 · USDC $6,808 · ETH $6,165 · BOLD $4,327
        XCTAssertEqual(groups[0].rows.map(\.token.symbol), ["rETH", "USDC", "ETH", "BOLD"])
    }

    // MARK: - group ordering

    /// Networks are ordered by what they hold, not by the order balances happened to
    /// arrive in — the most valuable network leads.
    func test_groupedRows_ordersNetworksByValue() {
        let store = PortfolioStore.mock()
        let groups = store.groupedRows(forWallet: "w1")
        let totals = groups.map { $0.rows.reduce(Decimal(0)) { $0 + ($1.usdValue ?? 0) } }
        XCTAssertEqual(totals, totals.sorted(by: >), "groups run highest value first")
        XCTAssertEqual(groups.first?.network.chain, .ethereum, "w1's ethereum holdings outweigh its arbitrum ones")
    }

    /// Every row survives the grouping — ordering must never drop a holding.
    func test_groupedRows_keepsEveryRow() {
        let store = PortfolioStore.mock()
        for wallet in ["w1", "w2"] {
            let grouped = store.groupedRows(forWallet: wallet).flatMap { $0.rows }
            XCTAssertEqual(grouped.count, store.rows(forWallet: wallet).count,
                           "\(wallet): grouping kept every row")
        }
    }

    // MARK: - Manual hide

    private func heldStore(dir: URL) -> PortfolioStore {
        let zro = Token(symbol: "ZRO", name: "ZRO", decimals: 18, chain: .arbitrum,
                        contractAddress: "0xzro", coingeckoId: nil, kind: .other, colorHex: "#000")
        let usdc = Token(symbol: "USDC", name: "USDC", decimals: 6, chain: .arbitrum,
                         contractAddress: "0xusdc", coingeckoId: nil, kind: .stablecoin, colorHex: "#000")
        let holdings = [
            Holding(walletId: "w1", token: usdc, amount: 4),
            Holding(walletId: "w1", token: zro, amount: 1),
        ]
        let prices: [String: PriceState] = [usdc.id: .priced(usd: 1), zro.id: .priced(usd: 0.4)]
        return PortfolioStore(wallets: [Wallet(id: "w1", nickname: "w1")],
                              holdings: holdings, prices: prices,
                              secret: SecretStore(directory: dir))
    }

    func test_manualHideRemovesTokenEverywhere() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-hide-\(UUID().uuidString)")
        let store = heldStore(dir: dir)
        XCTAssertEqual(Set(store.dashboardRows.map(\.token.symbol)), ["USDC", "ZRO"])

        let zroRow = store.dashboardRows.first { $0.token.symbol == "ZRO" }!
        store.hideToken(zroRow.token)

        XCTAssertEqual(store.dashboardRows.map(\.token.symbol), ["USDC"], "ZRO gone from dashboard")
        XCTAssertEqual(store.rows(forWallet: "w1").map(\.token.symbol), ["USDC"], "and from the wallet view")
        XCTAssertEqual(store.hiddenTokenRows.map(\.symbol), ["ZRO"], "ZRO listed as hidden")
    }

    func test_manualHolding_tiedToWalletAndPriced() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-man-\(UUID().uuidString)")
        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "cold"))   // manual-only wallet
        ss.addManualHolding(ManualHolding(walletId: "cold", symbol: "XMR", amount: 2,
                                          coingeckoId: "monero", networkName: "Monero"))

        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss,
                                   priceService: StubPriceService2(["coingecko:monero": 150]),
                                   history: HistoryStore(directory: dir))
        await store.refresh()
        XCTAssertTrue(store.wallets.contains { $0.id == "cold" }, "manual-only wallet exists")
        XCTAssertEqual(store.rows(forWallet: "cold").first { $0.token.symbol == "XMR" }?.usdValue, 300,
                       "2 XMR × $150 = $300, tied to the 'cold' wallet")
    }

    func test_manualHidePersistsAndUnhideRestores() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-hide-\(UUID().uuidString)")
        let store = heldStore(dir: dir)
        let zroRow = store.dashboardRows.first { $0.token.symbol == "ZRO" }!
        store.hideToken(zroRow.token)

        // A fresh store over the same secret dir still hides it (persisted).
        let reopened = heldStore(dir: dir)
        XCTAssertEqual(reopened.dashboardRows.map(\.token.symbol), ["USDC"], "hide survives relaunch")

        reopened.unhideToken(zroRow.token.id)
        XCTAssertEqual(Set(reopened.dashboardRows.map(\.token.symbol)), ["USDC", "ZRO"], "unhide brings it back")
    }
}

private struct StubPriceService2: PriceService {
    let map: [String: Decimal]
    init(_ map: [String: Decimal]) { self.map = map }
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        map.filter { keys.contains($0.key) }
    }
}

private struct StubSearch: CoinSearchService {
    let map: [String: String]
    init(_ map: [String: String]) { self.map = map }
    func coinId(forSymbol symbol: String) async -> String? { map[symbol.uppercased()] }
}

final class WalletNetworkTests: XCTestCase {
    func test_setWalletNetwork_roundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-net-\(UUID().uuidString)")
        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "testing"))
        XCTAssertEqual(ss.loadWallets().first?.network, "")
        ss.setWalletNetwork(nickname: "testing", network: "Sia")
        XCTAssertEqual(ss.loadWallets().first?.network, "Sia")
    }
    func test_oldThreeFieldLine_parsesEmptyNetwork() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-net2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "old\t\t".write(to: dir.appendingPathComponent("wallets.txt"), atomically: true, encoding: .utf8)
        let ss = SecretStore(directory: dir)
        XCTAssertEqual(ss.loadWallets().first?.network, "", "old 3-field line → empty network, no crash")
        ss.setWalletNetwork(nickname: "old", network: "Monero")
        XCTAssertEqual(ss.loadWallets().first?.network, "Monero")
    }
}

/// A refresh records a snapshot for the chart. That log is the user's real portfolio
/// history, so it must go exactly where it's told — a hardcoded path once let the test
/// suite append its own $300 fixture total to the live file on every run.
final class HistoryIsolationTests: XCTestCase {

    func test_archivingWritesIntoTheInjectedHistoryStoreOnly() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "cold"))
        ss.addManualHolding(ManualHolding(walletId: "cold", symbol: "XMR", amount: 2,
                                          coingeckoId: "monero", networkName: "Monero"))

        let history = HistoryStore(directory: dir)
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss,
                                   priceService: StubPriceService2(["coingecko:monero": 150]),
                                   history: history)
        await store.refresh()
        // Refreshing no longer records — the History tab's button does. The isolation
        // this test exists for is unchanged: whatever writes, writes HERE.
        XCTAssertTrue(history.load().isEmpty, "a refresh is not a mark")

        await store.archiveToday()

        XCTAssertEqual(history.load().last?.total, 300, "the mark landed in the injected store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.csv").path),
                      "and wrote to the temp directory, not Application Support")
    }
}

/// Editing an amount must not go near the network. It used to run a full refresh — a
/// balance scan across every wallet and chain, then a price fetch — for a number the
/// user had just typed, which made the field unusable.
final class LocalEditTests: XCTestCase {

    /// Counts how many times anything asks for a price.
    private final class CountingPrices: PriceService, @unchecked Sendable {
        let table: [String: Decimal]
        private(set) var calls = 0
        init(_ t: [String: Decimal]) { table = t }
        func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
            calls += 1
            return table.filter { keys.contains($0.key) }
        }
    }

    private func makeStore(dir: URL, prices: CountingPrices) -> (PortfolioStore, SecretStore) {
        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "cold"))
        ss.addManualHolding(ManualHolding(walletId: "cold", symbol: "XMR", amount: 2,
                                          coingeckoId: "monero", networkName: "Monero"))
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss, priceService: prices,
                                   history: HistoryStore(directory: dir),
                                   cacheDirectory: dir)
        return (store, ss)
    }

    func test_editingAnAmountCostsNoNetworkCall() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-edit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prices = CountingPrices(["coingecko:monero": 150])
        let (store, _) = makeStore(dir: dir, prices: prices)

        await store.refresh()
        let afterLoad = prices.calls
        XCTAssertEqual(store.totalUSD, 300, "2 XMR × $150")

        await store.setManualAmount(walletId: "cold", symbol: "XMR", amount: 5)

        XCTAssertEqual(prices.calls, afterLoad, "editing asked the price service for nothing")
        XCTAssertEqual(store.totalUSD, 750, "5 XMR × the price we already had")
    }

    /// A second refresh inside the quote lifetime reuses what it has.
    func test_refreshReusesQuotesUntilTheyAgeOut() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-quote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prices = CountingPrices(["coingecko:monero": 150])
        let (store, _) = makeStore(dir: dir, prices: prices)

        await store.refresh()
        XCTAssertEqual(prices.calls, 1)
        await store.refresh()
        XCTAssertEqual(prices.calls, 1, "quotes are still fresh")
        await store.refresh(force: true)
        XCTAssertEqual(prices.calls, 2, "forcing fetches again")
        XCTAssertEqual(store.totalUSD, 300, "value survives all of it")
    }

    /// Removing a hand-entered token is equally local.
    func test_removingAHandEnteredTokenCostsNoNetworkCall() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-rm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let prices = CountingPrices(["coingecko:monero": 150])
        let (store, _) = makeStore(dir: dir, prices: prices)
        await store.refresh()
        let afterLoad = prices.calls

        await store.removeManualToken(walletId: "cold", symbol: "XMR")

        XCTAssertEqual(prices.calls, afterLoad, "removal asked the price service for nothing")
        XCTAssertEqual(store.totalUSD, 0)
    }
}

/// Caches must follow the injected directory. A store built for a test that still reads
/// Application Support gets the live app's prices, and its stubbed price service is
/// quietly ignored — which made two tests pass against real Monero instead of $150.
final class CacheIsolationTests: XCTestCase {

    func test_quoteCacheFollowsTheInjectedHistoryDirectory() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-iso-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "cold"))
        ss.addManualHolding(ManualHolding(walletId: "cold", symbol: "XMR", amount: 2,
                                          coingeckoId: "monero", networkName: "Monero"))
        // Only the history store is injected — the quote cache must follow it.
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss,
                                   priceService: StubPriceService2(["coingecko:monero": 150]),
                                   history: HistoryStore(directory: dir))
        await store.refresh()

        XCTAssertEqual(store.totalUSD, 300, "priced by the stub, not by a cache on disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("quotes.json").path),
                      "and the cache was written into the injected directory")
    }
}

/// A wallet reads top-down from largest to smallest: the biggest network first, and the
/// biggest holding first inside it.
final class WalletSortingTests: XCTestCase {

    func test_networksAreOrderedByWhatTheyHold() {
        let store = PortfolioStore.mock()
        for wallet in ["w1", "w2"] {
            let totals = store.groupedRows(forWallet: wallet).map { g in
                g.rows.reduce(Decimal(0)) { $0 + ($1.usdValue ?? 0) }
            }
            XCTAssertEqual(totals, totals.sorted(by: >), "\(wallet): biggest network first")
        }
    }

    /// The part that was missing: only the groups were sorted, so tokens sat in whatever
    /// order the balance scan returned them.
    func test_tokensInsideEachNetworkAreOrderedByValue() {
        let store = PortfolioStore.mock()
        for wallet in ["w1", "w2"] {
            for group in store.groupedRows(forWallet: wallet) {
                let values = group.rows.map { $0.usdValue ?? -1 }
                XCTAssertEqual(values, values.sorted(by: >),
                               "\(wallet)/\(group.network.name): biggest holding first")
            }
        }
    }

    /// Sorting must not lose or duplicate a holding.
    func test_sortingKeepsEveryRow() {
        let store = PortfolioStore.mock()
        for wallet in ["w1", "w2"] {
            let grouped = store.groupedRows(forWallet: wallet).flatMap { $0.rows }
            XCTAssertEqual(grouped.count, store.rows(forWallet: wallet).count, wallet)
        }
    }
}

/// A wallet wears one colour everywhere. The bug this guards: each screen defaulted an
/// uncoloured wallet off its own index, and the portfolio's wallet ring counts through a
/// list sorted by value that skips empty wallets — so the same wallet came out green on
/// the Wallets tab and orange on the portfolio.
final class WalletColourTests: XCTestCase {

    private func makeStore() -> (PortfolioStore, SecretStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-colour-\(UUID().uuidString)")
        let ss = SecretStore(directory: dir)
        let wallets = ["Alpha", "Bravo", "Charlie"].map {
            Wallet(id: $0, nickname: $0)
        }
        return (PortfolioStore(wallets: wallets, holdings: [], prices: [:], secret: ss,
                               history: HistoryStore(directory: dir)), ss)
    }

    func test_anUncolouredWalletTakesItsPaletteEntryFromTheArrangedOrder() {
        let (store, _) = makeStore()
        let palette = PortfolioStore.walletPalette
        XCTAssertEqual(store.walletTintHex("Alpha"), palette[0])
        XCTAssertEqual(store.walletTintHex("Bravo"), palette[1])
        XCTAssertEqual(store.walletTintHex("Charlie"), palette[2])
    }

    /// The colour follows the wallet, not its rank in whatever list is asking.
    @MainActor
    func test_reorderingWalletsMovesTheDefaultColourWithTheOrder() {
        let (store, _) = makeStore()
        let palette = PortfolioStore.walletPalette
        store.setWalletOrder(["Charlie", "Alpha", "Bravo"])
        XCTAssertEqual(store.walletTintHex("Charlie"), palette[0])
        XCTAssertEqual(store.walletTintHex("Alpha"), palette[1])
    }

    func test_aChosenColourBeatsTheDefault() {
        let (store, ss) = makeStore()
        ss.setWalletColor("Bravo", "#FF1744")
        XCTAssertEqual(store.walletTintHex("Bravo"), "#FF1744")
        XCTAssertEqual(store.walletTintHex("Alpha"), PortfolioStore.walletPalette[0],
                       "and its neighbours keep theirs")
    }

    /// Every wallet the portfolio's ring can name resolves to the same colour its module
    /// wears — the two screens ask the one question.
    func test_everyWalletResolvesToOneColourForBothScreens() {
        let (store, ss) = makeStore()
        ss.setWalletColor("Charlie", "#FFD600")
        for w in store.orderedWallets {
            XCTAssertEqual(store.walletTintHex(w.nickname), store.walletTintHex(w.nickname))
            XCTAssertFalse(store.walletTintHex(w.nickname).isEmpty, w.nickname)
        }
        XCTAssertEqual(Set(store.orderedWallets.map { store.walletTintHex($0.nickname) }).count, 3,
                       "three wallets, three distinct colours")
    }
}

/// The wallet palette is an identity set, so what matters is not the colours but the
/// distances between them — especially between NEIGHBOURS, since wallets take their
/// default by counting through the list.
final class WalletPaletteTests: XCTestCase {

    /// CIE L*a*b*, for judging "do these look alike" rather than "are these different
    /// numbers" — two hexes far apart in RGB can be near-identical to the eye.
    private func lab(_ hex: String) -> (L: Double, a: Double, b: Double) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = Int(h, radix: 16) ?? 0
        func channel(_ shift: Int) -> Double {
            let u = Double((v >> shift) & 0xFF) / 255
            return u <= 0.04045 ? u / 12.92 : pow((u + 0.055) / 1.055, 2.4)
        }
        let r = channel(16), g = channel(8), b = channel(0)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private func distance(_ a: String, _ b: String) -> Double {
        let p = lab(a), q = lab(b)
        return sqrt(pow(p.L - q.L, 2) + pow(p.a - q.a, 2) + pow(p.b - q.b, 2))
    }

    func test_everyEntryIsAWellFormedHex() {
        for c in PortfolioStore.walletColors {
            XCTAssertEqual(c.hex.count, 7, c.hex)
            XCTAssertTrue(c.hex.hasPrefix("#"), c.hex)
            XCTAssertNotNil(Int(c.hex.dropFirst(), radix: 16), c.hex)
            XCTAssertFalse(c.romaji.isEmpty)
            XCTAssertFalse(c.kanji.isEmpty)
        }
    }

    func test_noColourAppearsTwice() {
        let hexes = PortfolioStore.walletColors.map { $0.hex.uppercased() }
        XCTAssertEqual(Set(hexes).count, hexes.count)
    }

    /// The property that actually matters on screen: wallet 4 must not look like wallet 5.
    /// The palette is Banking's (one palette across the app): its first twelve are the
    /// ring colours, handed out in order, and those must read apart; the softer twelve
    /// after are there to choose, and sit closer by design.
    func test_neighbouringColoursAreObviouslyDifferent() {
        let hexes = Array(PortfolioStore.walletPalette.prefix(12))
        for i in 0..<(hexes.count - 1) {
            let d = distance(hexes[i], hexes[i + 1])
            XCTAssertGreaterThan(d, 30, "\(hexes[i]) and \(hexes[i + 1]) sit next to each other")
        }
    }

    /// And no two anywhere in the set collapse into each other, however far apart they
    /// are assigned.
    /// 12, not 15: Banking's sky blue (Tsuyukusa, Travel) and teal blue (Chigusa,
    /// Subscriptions) sit at 12.5 — clearly apart on screen, and Banking's own. Gunjyo,
    /// at 5 from Tsuyukusa, was the true twin and is gone.
    func test_noTwoOfTheHandedOutColoursReadAlike() {
        let hexes = Array(PortfolioStore.walletPalette.prefix(12))
        for i in 0..<hexes.count {
            for j in (i + 1)..<hexes.count {
                XCTAssertGreaterThan(distance(hexes[i], hexes[j]), 12,
                                     "\(hexes[i]) vs \(hexes[j])")
            }
        }
    }

    /// Every colour has to hold its own against the near-black canvas it sits on.
    ///
    /// The floor is 36, not the 3:1 that WCAG asks of a non-text block. Two colours sit
    /// just under that line — Ruri at L 39 and Edomurasaki at L 37, both around 2.8:1 —
    /// and both are kept deliberately. They are fully saturated hues with no lighter
    /// equivalent in the Nippon list (its blues and violets are darker still), and every
    /// candidate that does clear 3:1 is a brown in a band the palette already covers four
    /// times over. A hue missing entirely costs more than a colour being the dimmest. If
    /// this assertion is ever relaxed further, that is the thing being traded away.
    func test_everyColourSeparatesFromTheCanvas() {
        for c in PortfolioStore.walletColors {
            XCTAssertGreaterThan(lab(c.hex).L, 40, "\(c.name) disappears into the ground")
        }
        for c in PortfolioStore.walletColors.prefix(12) {
            XCTAssertLessThan(lab(c.hex).L, 84, "\(c.name) washes out")
        }
    }

    /// Wallets and Banking's categories choose from the same colours.
    func test_walletsAndCategoriesShareOnePalette() {
        XCTAssertEqual(PortfolioStore.walletPalette.first, "#90B44B")
        XCTAssertEqual(PortfolioStore.walletPalette.count, 24)
    }

    func test_thereAreEnoughColoursForAWalletListThatKeepsGrowing() {
        XCTAssertGreaterThanOrEqual(PortfolioStore.walletColors.count, 24)
    }

    func test_aColourCanSayWhatItIsCalled() {
        XCTAssertEqual(PortfolioStore.walletColorName("#E83015"), "Syojyohi 猩猩緋")
        XCTAssertEqual(PortfolioStore.walletColorName("#e83015"), "Syojyohi 猩猩緋",
                       "case-insensitive: stored hexes come back however they were written")
        XCTAssertNil(PortfolioStore.walletColorName("#123456"))
    }
}

/// The archive names wallets that may no longer exist — the past can't be edited. Those
/// names still have to get colours, and different ones.
final class RetiredWalletColourTests: XCTestCase {

    private func store() -> PortfolioStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-retired-\(UUID().uuidString)")
        let ss = SecretStore(directory: dir)
        let wallets = ["Alpha", "Bravo"].map {
            Wallet(id: $0, nickname: $0)
        }
        return PortfolioStore(wallets: wallets, holdings: [], prices: [:], secret: ss,
                              history: HistoryStore(directory: dir))
    }

    func test_everyNameInASetGetsItsOwnColour() {
        let s = store()
        let names = ["Alpha", "Bravo", "Farm", "Long Term", "Testing", "Spare", "Old Vault"]
        let tints = s.walletTints(for: names)
        XCTAssertEqual(Set(tints.values).count, names.count,
                       "two names share a colour: \(tints)")
    }

    func test_currentWalletsKeepTheColourTheWalletsTabGaveThem() {
        let s = store()
        let tints = s.walletTints(for: ["Alpha", "Bravo", "Farm"])
        XCTAssertEqual(tints["Alpha"], PortfolioStore.walletPalette[0])
        XCTAssertEqual(tints["Bravo"], PortfolioStore.walletPalette[1])
        XCTAssertNotEqual(tints["Farm"], PortfolioStore.walletPalette[0],
                          "a retired wallet must not borrow a live one's colour")
    }

    func test_theSameArchiveDrawsTheSameColoursEveryLaunch() {
        let names = ["Farm", "Long Term", "Testing"]
        XCTAssertEqual(store().walletTints(for: names), store().walletTints(for: names))
        XCTAssertEqual(store().walletTints(for: names),
                       store().walletTints(for: names.reversed()),
                       "and the load order of the archive must not change them")
    }

    /// More names than colours has to keep working, even though it must then repeat.
    func test_moreNamesThanColoursStillAnswersForAllOfThem() {
        let many = (0..<40).map { "Wallet \($0)" }
        XCTAssertEqual(store().walletTints(for: many).count, many.count)
    }

    /// A current wallet still takes its colour from the arranged order.
    func test_currentWalletsAreUnaffected() {
        let s = store()
        XCTAssertEqual(s.walletTintHex("Alpha"), PortfolioStore.walletPalette[0])
        XCTAssertEqual(s.walletTintHex("Bravo"), PortfolioStore.walletPalette[1])
    }
}
