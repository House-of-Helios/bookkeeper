import XCTest
@testable import BookkeeperCore

private struct StubFetcher: DataFetcher {
    let body: String
    func data(from url: URL, headers: [String: String]) async throws -> Data { Data(body.utf8) }
}

/// Pasting a contract address has to produce a complete token — symbol, decimals, price
/// and a logo — from one keyless call. These cover that path and the 24h-change endpoint
/// that replaced CoinGecko in the refresh.
final class AddByContractTests: XCTestCase {

    // MARK: - 24h change

    /// /percentage returns bare numbers, not objects — and in the same percent scale as
    /// CoinGecko's usd_24h_change (verified live: UNI 5.7339 from both).
    func test_changes24hDecodesBareNumbers() async throws {
        let json = """
        {"coins":{"coingecko:ethereum":0.3263017,"ethereum:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984":5.7339252}}
        """
        let svc = DefiLlamaPriceService(fetcher: StubFetcher(body: json))
        let out = try await svc.changes24h(forKeys: ["coingecko:ethereum",
                                                     "ethereum:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"])
        XCTAssertEqual(out["coingecko:ethereum"] ?? 0, 0.3263017, accuracy: 0.0000001)
        XCTAssertEqual(out["ethereum:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] ?? 0, 5.7339252, accuracy: 0.0000001)
    }

    func test_changes24hIsEmptyForNoKeys() async throws {
        let svc = DefiLlamaPriceService(fetcher: StubFetcher(body: #"{"coins":{}}"#))
        let out = try await svc.changes24h(forKeys: [])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Persistence

    func test_contractHoldingRoundTripsThroughTheSecretFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SecretStore(directory: dir)
        store.addManualHolding(ManualHolding(walletId: "Main", symbol: "COMP",
                                             amount: Decimal(string: "6.55")!,
                                             network: "base", contractAddress: "0xabc",
                                             networkName: "Base"))
        let loaded = store.manualHoldings()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.network, "base")
        XCTAssertEqual(loaded.first?.networkName, "Base")
        XCTAssertEqual(loaded.first?.contractAddress, "0xabc")
        XCTAssertEqual(loaded.first?.amount, Decimal(string: "6.55"))
        XCTAssertTrue(loaded.first?.isContractBased == true)
    }

    /// Entries written before by-contract existed have five fields; they must still load
    /// as by-symbol coins rather than being dropped.
    func test_legacyFiveFieldLineStillParsesAsABySymbolCoin() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("wallets.txt")
        try "#manual\tCold\tSC\tsiacoin\t1200\n".write(to: file, atomically: true, encoding: .utf8)

        let loaded = SecretStore(directory: dir).manualHoldings()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.symbol, "SC")
        XCTAssertEqual(loaded.first?.coingeckoId, "siacoin")
        XCTAssertNil(loaded.first?.network)
        XCTAssertFalse(loaded.first?.isContractBased == true)
    }
}

/// The same symbol on two networks is two holdings; the same symbol on the same network
/// added twice is one holding with a bigger balance.
final class ManualHoldingKeyTests: XCTestCase {

    private func store() -> (SecretStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-key-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SecretStore(directory: dir), dir)
    }

    /// ETH on Base and ETH on Arbitrum must both survive. Keyed on the symbol alone, the
    /// second silently replaced the first.
    func test_sameSymbolOnTwoNetworksAreKeptApart() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 1,
                                         coingeckoId: "ethereum", networkName: "Base"))
        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 2,
                                         coingeckoId: "ethereum", networkName: "Arbitrum"))

        let held = s.manualHoldings()
        XCTAssertEqual(held.count, 2)
        XCTAssertEqual(held.first { $0.networkName == "Base" }?.amount, 1)
        XCTAssertEqual(held.first { $0.networkName == "Arbitrum" }?.amount, 2)
    }

    /// Re-adding the same symbol on the SAME network replaces that one entry.
    func test_sameSymbolSameNetworkIsOneEntry() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 1,
                                         coingeckoId: "ethereum", networkName: "Base"))
        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 7,
                                         coingeckoId: "ethereum", networkName: "Base"))

        XCTAssertEqual(s.manualHoldings().count, 1)
        XCTAssertEqual(s.manualHoldings().first?.amount, 7)
    }

    /// Removing names the network, so taking the Base one leaves Arbitrum alone.
    func test_removingOneNetworkLeavesTheOther() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 1,
                                         coingeckoId: "ethereum", networkName: "Base"))
        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 2,
                                         coingeckoId: "ethereum", networkName: "Arbitrum"))

        s.removeManualHolding(walletId: "w", symbol: "ETH", network: "Base")

        XCTAssertEqual(s.manualHoldings().count, 1)
        XCTAssertEqual(s.manualHoldings().first?.networkName, "Arbitrum")
    }

    /// Removing without naming a network takes them all — what happens when a wallet goes.
    func test_removingWithoutANetworkTakesEveryEntry() {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }

        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 1,
                                         coingeckoId: "ethereum", networkName: "Base"))
        s.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 2,
                                         coingeckoId: "ethereum", networkName: "Arbitrum"))

        s.removeManualHolding(walletId: "w", symbol: "ETH")

        XCTAssertTrue(s.manualHoldings().isEmpty)
    }
}

/// A coin entered by name can be moved to the right network; one identified by contract
/// cannot, because its chain came from the address itself.
private struct FixedPrices: PriceService {
    let table: [String: Decimal]
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        table.filter { keys.contains($0.key) }
    }
}

final class NetworkReassignmentTests: XCTestCase {

    private func make() -> (PortfolioStore, SecretStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-net-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "w"))
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss,
                                   priceService: FixedPrices(table: ["coingecko:ethereum": 2000]),
                                   // Stubbed: moving a holding re-resolves its price, and
                                   // that must not become a live request during a test.
                                   locator: TokenLocator(fetcher: StubFetcher(body: #"{"coins":{}}"#),
                                                         search: NoSearch()),
                                   history: HistoryStore(directory: dir))
        return (store, ss, dir)
    }

    func test_movesACoinToAnotherNetwork() async {
        let (store, ss, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 2,
                                          coingeckoId: "ethereum", networkName: "Ethereum"))
        await store.refresh()

        await store.setManualNetwork(walletId: "w", symbol: "ETH", from: "Ethereum", to: "Base")

        let held = ss.manualHoldings()
        XCTAssertEqual(held.count, 1, "moved, not duplicated")
        XCTAssertEqual(held.first?.networkName, "Base")
        XCTAssertEqual(held.first?.amount, 2, "the balance came with it")
    }

    /// A contract-identified token moves too.
    ///
    /// This used to be refused, on the reasoning that the address had established the
    /// chain as a fact. It establishes where the token was FOUND — not which chain the
    /// holder's own coins sit on, which is a thing only the holder knows.
    func test_movesAContractIdentifiedTokenToo() async {
        let (store, ss, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "UNI", amount: 1,
                                          network: "ethereum", contractAddress: "0xabc",
                                          networkName: "Ethereum"))
        await store.refresh()

        await store.setManualNetwork(walletId: "w", symbol: "UNI", from: "Ethereum", to: "Base")

        let held = ss.manualHoldings()
        XCTAssertEqual(held.count, 1, "moved, not duplicated")
        XCTAssertEqual(held.first?.networkName, "Base")
        XCTAssertEqual(held.first?.amount, 1, "the balance came with it")
    }

    /// Nothing priced `0xabc` on Base, so the row loses its price — and says so, rather
    /// than leaving a bare dash to be interpreted.
    func test_anUnpriceableMoveStillHappensAndExplainsItself() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-move-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ss = SecretStore(directory: dir)
        ss.addWallet(WalletSecret(nickname: "w"))
        // Nothing prices anything: no chain knows this address and no register knows
        // this ticker, which is the only way the move can end up with no figure at all.
        let store = PortfolioStore(wallets: [], holdings: [], prices: [:],
                                   secret: ss,
                                   priceService: FixedPrices(table: [:]),
                                   locator: TokenLocator(fetcher: StubFetcher(body: #"{"coins":{}}"#),
                                                         search: NoSearch()),
                                   history: HistoryStore(directory: dir))
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "UNI", amount: 1,
                                          network: "ethereum", contractAddress: "0xabc",
                                          networkName: "Ethereum"))
        await store.refresh()

        await store.setManualNetwork(walletId: "w", symbol: "UNI", from: "Ethereum", to: "Base")

        XCTAssertEqual(ss.manualHoldings().first?.networkName, "Base", "the move is the user's call")
        XCTAssertNotNil(store.lastError, "and the lost price is reported")
        XCTAssertTrue(store.lastError?.contains("Base") == true, store.lastError ?? "no message")
    }

    /// A coin held by id keeps its price across the move — it is the same asset on
    /// either side, so the figure must not change.
    func test_aCoinKeepsItsValueAcrossTheMove() async {
        let (store, ss, dir) = make()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "ETH", amount: 2,
                                          coingeckoId: "ethereum", networkName: "Ethereum"))
        await store.refresh()
        XCTAssertEqual(store.totalUSD, 4000)

        await store.setManualNetwork(walletId: "w", symbol: "ETH", from: "Ethereum", to: "Arbitrum")

        XCTAssertEqual(store.totalUSD, 4000, "same asset, same figure, different chain")
        XCTAssertEqual(ss.manualHoldings().first?.coingeckoId, "ethereum", "still priced by id")
    }
}


/// A register that knows nothing — the offline/rate-limited case.
private struct NoSearch: CoinSearchService {
    func coinId(forSymbol symbol: String) async -> String? { nil }
}

/// A token's spelling can change under an existing holding — RETH on file, rETH once
/// the contract's own casing is read. A case-only difference must not fork one holding
/// into two rows.
final class SymbolCasingStorageTests: XCTestCase {

    private func store() -> (SecretStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-case-\(UUID().uuidString)")
        return (SecretStore(directory: dir), dir)
    }

    func test_reAddingWithNewCasingReplacesTheRowRatherThanDoublingIt() {
        let (ss, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "RETH", amount: 3,
                                          coingeckoId: "rocket-pool-eth",
                                          networkName: "Ethereum"))
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "rETH", amount: 5,
                                          coingeckoId: "rocket-pool-eth",
                                          networkName: "Ethereum"))

        let held = ss.manualHoldings()
        XCTAssertEqual(held.count, 1, "one holding, not one per spelling")
        XCTAssertEqual(held.first?.symbol, "rETH", "and the row takes the new spelling")
        XCTAssertEqual(held.first?.amount, 5)
    }

    func test_removingFindsTheRowWhateverItsCasing() {
        let (ss, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "rETH", amount: 3,
                                          coingeckoId: "rocket-pool-eth",
                                          networkName: "Ethereum"))
        ss.removeManualHolding(walletId: "w", symbol: "RETH", network: "Ethereum")
        XCTAssertTrue(ss.manualHoldings().isEmpty)
    }

    /// The network is still part of the key — case-insensitivity must not merge two
    /// genuinely different holdings.
    func test_theSameTickerOnTwoChainsStaysTwoHoldings() {
        let (ss, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "rETH", amount: 3,
                                          coingeckoId: "rocket-pool-eth", networkName: "Ethereum"))
        ss.addManualHolding(ManualHolding(walletId: "w", symbol: "RETH", amount: 1,
                                          coingeckoId: "rocket-pool-eth", networkName: "Arbitrum"))
        XCTAssertEqual(ss.manualHoldings().count, 2)
    }
}
