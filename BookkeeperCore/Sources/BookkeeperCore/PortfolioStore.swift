import Foundation
import Observation

@Observable
public final class PortfolioStore {
    public var wallets: [Wallet]
    private var holdings: [Holding]
    private var prices: [String: PriceState]

    // Stage-2 live data. Defaults wire the keyless services + on-disk secret store.
    @ObservationIgnored private let secret: SecretStore
    @ObservationIgnored private let priceService: PriceService
    @ObservationIgnored private let searchService: CoinSearchService
    @ObservationIgnored private let locator: TokenLocator
    @ObservationIgnored private let historicalPriceService = HistoricalPriceService()
    /// Follows the history store's directory, like the quote cache — a default one here
    /// sent every test's chart fetches into the live folder.
    @ObservationIgnored private let priceHistoryCache: PriceHistoryCache
    /// Injectable so a test never appends its fixture totals to the real snapshot log —
    /// a hardcoded one wrote a $300 test portfolio into the live history file on every run.
    @ObservationIgnored private let history: HistoryStore
    public var isLoading = false
    public var lastError: String?
    /// When the last successful refresh completed — drives the "updated Xm ago" label.
    public var lastUpdated: Date?

    /// Token ids the user has manually hidden. Every holding is hand-entered, so this
    /// is the only way a row leaves the list — and it is always the user's own call.
    public private(set) var hiddenIDs: Set<String> = []

    /// Token.id → 24h price change (percent), refreshed alongside prices. Drives the
    /// per-row + portfolio 24h deltas.
    public var change24h: [String: Double] = [:]

    /// Weighted portfolio 24h change (percent): from the value held 24h ago vs now.
    public var portfolio24hChange: Double? {
        var now = 0.0, prior = 0.0
        for h in visiblePricedRows {
            guard let v = h.usdValue, let c = change24h[h.token.id] else { continue }
            let val = NSDecimalNumber(decimal: v).doubleValue
            now += val
            prior += val / (1 + c / 100)
        }
        guard prior > 0 else { return nil }
        return (now - prior) / prior * 100
    }

    public init(wallets: [Wallet], holdings: [Holding], prices: [String: PriceState],
                secret: SecretStore = SecretStore(),
                priceService: PriceService = CompositePriceService(
                    primary: DefiLlamaPriceService(), fallback: CoinGeckoPriceService()),
                searchService: CoinSearchService = CoinGeckoSearchService(),
                /// Injectable so a test can exercise adding and moving tokens without
                /// reaching the live price API — `setManualNetwork` re-resolves, and an
                /// un-injected locator made that a real request mid-test.
                locator: TokenLocator? = nil,
                history: HistoryStore = HistoryStore(),
                cacheDirectory: URL? = nil) {
        self.wallets = wallets
        self.holdings = holdings
        self.prices = prices
        self.secret = secret
        self.priceService = priceService
        self.searchService = searchService
        self.locator = locator ?? TokenLocator(search: searchService)
        self.history = history
        self.quoteCache = JSONFileCache<QuoteSnapshot>(name: "quotes.json",
                                                       directory: cacheDirectory ?? history.directory)
        self.priceHistoryCache = PriceHistoryCache(directory: cacheDirectory ?? history.directory)
        self.hiddenIDs = Set(secret.hiddenTokenIDs())
        // Last known quotes, so the first paint after launch shows real values instead
        // of waiting on the network.
        if let snap = quoteCache.load() {
            self.quotes = snap.prices
            self.quoteChanges = snap.changes
            self.quotedAt = snap.at
        }
    }

    // MARK: - Manual hide / always-show

    /// Hide a specific token everywhere (persisted). Right-click affordance on a row.
    public func hideToken(_ token: Token) {
        secret.hideToken(token.id)
        hiddenIDs.insert(token.id)
    }

    public func unhideToken(_ id: String) {
        secret.unhideToken(id)
        hiddenIDs.remove(id)
    }

    /// Currently-held tokens the user manually hid — drives the Settings unhide list.
    public var hiddenTokenRows: [(id: String, symbol: String)] {
        var seen = Set<String>()
        var out: [(id: String, symbol: String)] = []
        for h in holdings where hiddenIDs.contains(h.token.id) && !seen.contains(h.token.id) {
            seen.insert(h.token.id)
            out.append((id: h.token.id, symbol: h.token.symbol))
        }
        return out
    }

    /// Drop rows the user manually hid. Applied before spam filtering and before
    /// any symbol collapse, so a hidden per-chain contract is gone from the total.
    private func applyHidden(_ rows: [PricedHolding]) -> [PricedHolding] {
        hiddenIDs.isEmpty ? rows : rows.filter { !hiddenIDs.contains($0.token.id) }
    }

    /// Quotes by price key, and when they were fetched. Held here and on disk so an edit
    /// prices instantly from what is already known, and a relaunch shows real values
    /// before any network call returns.
    @ObservationIgnored private var quotes: [String: Decimal] = [:]
    @ObservationIgnored private var quoteChanges: [String: Double] = [:]
    @ObservationIgnored private var quotedAt: Date?
    /// Follows the history store's directory unless told otherwise, so injecting one
    /// isolates both. Two separately-injectable paths meant a test could isolate the
    /// history log, forget the quote cache, and silently read the live app's prices —
    /// which is exactly what happened.
    @ObservationIgnored private let quoteCache: JSONFileCache<QuoteSnapshot>

    /// How long a quote stands before a refresh will fetch again. Prices move, but not
    /// so fast that every edit should pay for a round trip.
    public static let quoteLifetime: TimeInterval = 240

    struct QuoteSnapshot: Codable {
        let at: Date
        let prices: [String: Decimal]
        let changes: [String: Double]
    }

    /// Live store — starts empty; call `refresh()` to load real wallets (or the mock demo if none).
    public static func live() -> PortfolioStore {
        let secret = SecretStore()
        // CoinGecko key read per-call, so saving it in Settings lifts rate limits live.
        // It only ever sees keys DefiLlama couldn't price, so the key is a nicety now.
        let cg = CoinGeckoAuth(key: { secret.apiKey("coingecko") })
        let price = CompositePriceService(primary: DefiLlamaPriceService(),
                                          fallback: CoinGeckoPriceService(auth: cg))
        return PortfolioStore(wallets: [], holdings: [], prices: [:],
                              secret: secret,
                              priceService: price,
                              searchService: CoinGeckoSearchService(auth: cg))
    }

    public var hasRealWallets: Bool { !secret.loadWallets().isEmpty }

    // MARK: - Network group ordering

    /// Stable string key for a network group. `nil` chain = manual / non-EVM (e.g. XMR).
    public static func groupKey(for chain: Chain?) -> String {
        chain?.rawValue ?? "manual"
    }

    public static func mock() -> PortfolioStore {
        // Its own throwaway directory, seeded with a fabricated archive. Two reasons:
        // the History tab has something to draw in a snapshot render, and — the one that
        // matters — a mock store can no longer reach the real history file. It used to
        // take the default `HistoryStore()`, which points at the live data root, so
        // anything that archived from a mock wrote fixture figures into the user's own
        // record. That has happened once already and must not be possible again.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookkeeper-mock-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryStore(directory: dir)
        MockData.seedArchive(into: history)
        return PortfolioStore(wallets: MockData.wallets,
                              holdings: MockData.holdings,
                              prices: MockData.prices,
                              history: history)
    }

    /// All holdings combined by symbol **within each network**, valued, with
    /// percentages. One row per asset per network, so the portfolio groups under exactly
    /// the network tabs the wallet modules do. Collapse merges only; % stamped here.
    private var dashboardPriced: [PricedHolding] {
        let perRow = applyHidden(Aggregation.price(holdings, with: prices))
        let combined = Aggregation.collapseBySymbolPerNetwork(perRow)
        return combined
    }

    public var dashboardRows: [PricedHolding] {
        Aggregation.withPercentages(dashboardPriced)
    }

    public var totalUSD: Decimal {
        Aggregation.total(dashboardPriced)
    }

    /// Distinct tokens currently held — used by the app to prefetch icons by contract.
    public var allTokens: [Token] {
        var seen = Set<String>()
        var out: [Token] = []
        for h in holdings where !seen.contains(h.token.id) {
            seen.insert(h.token.id); out.append(h.token)
        }
        return out
    }

    /// Distinct VISIBLE tokens (survive the spam filter + manual hide) — the icon
    /// prefetch targets these so it doesn't waste rate-limited calls on the hundreds
    /// of junk tokens that are never shown anyway.
    public var visibleTokens: [Token] {
        var seen = Set<String>()
        var out: [Token] = []
        let rows = applyHidden(Aggregation.price(holdings, with: prices))
        for r in rows where !seen.contains(r.token.id) {
            seen.insert(r.token.id); out.append(r.token)
        }
        return out
    }

    public var buckets: [(TokenKind, Decimal)] {
        Aggregation.bucketShares(dashboardPriced)
    }

    /// Visible holdings priced per-row (filtered, NOT collapsed by symbol) — feeds the
    /// dashboard's By-Chain / By-Type metrics so a multi-chain token splits per chain.
    public var visiblePricedRows: [PricedHolding] {
        applyHidden(Aggregation.price(holdings, with: prices))
    }

    /// Daily price points for one token over the trailing `days`, oldest first.
    /// Cached on disk (`PriceHistoryCache`) so re-opening the same chart within the
    /// TTL costs nothing; a cache miss fetches DefiLlama's keyless `/chart` endpoint.
    public func priceHistory(for token: Token, days: Int) async -> [PricePoint] {
        let key = Self.priceKey(for: token)
        if let cached = await priceHistoryCache.points(for: key, days: days) { return cached }
        guard let fetched = try? await historicalPriceService.history(for: token, days: days)
        else { return [] }
        await priceHistoryCache.store(fetched, for: key, days: days)
        return fetched
    }

    /// Visible USD value per wallet (filtered) — drives the dashboard "By Wallet" donut.
    public var walletShares: [(nickname: String, usd: Decimal)] {
        wallets.compactMap { w in
            let v = rows(forWallet: w.id).reduce(Decimal(0)) { $0 + ($1.usdValue ?? 0) }
            return v > 0 ? (w.nickname, v) : nil
        }
        .sorted { $0.usd > $1.usd }
    }

    /// Portfolio allocation by chain (% of priced value on each chain), over the
    /// visible/filtered holdings. Computed per-row (pre symbol-collapse) so a token
    /// spread across chains splits correctly. Drives the dashboard "By Chain" donut.
    public var chainShares: [(chain: Chain?, pct: Decimal, usd: Decimal)] {
        let perRow = applyHidden(Aggregation.price(holdings, with: prices))
        var order: [Chain?] = []
        var sums: [Chain?: Decimal] = [:]
        for r in perRow {
            guard let v = r.usdValue else { continue }
            let c = r.token.chain
            if sums[c] == nil { order.append(c) }
            sums[c, default: 0] += v
        }
        let total = sums.values.reduce(0, +)
        guard total > 0 else { return [] }
        return order.map { (chain: $0, pct: sums[$0]! / total * 100, usd: sums[$0]!) }
    }

    public func rows(forWallet walletId: String) -> [PricedHolding] {
        let scoped = holdings.filter { $0.walletId == walletId }
        let priced = applyHidden(Aggregation.price(scoped, with: prices))
        return Aggregation.withPercentages(priced)
    }

    /// Holdings for `walletId`, grouped by `token.chain`, **most valuable network first**.
    ///
    /// Groups used to sit in whatever order the balances arrived in, with a drag to
    /// reorder them by hand — but that order was held in memory only, so it was silently
    /// forgotten on every relaunch. Ordering by what each network is worth needs no
    /// gesture, never forgets, and puts the network that matters at the top by itself.
    /// Rows inside each group are sorted by value too, so the whole list reads top-down
    /// from largest to smallest: the biggest network first, and within it the biggest
    /// holding first. Sorting only the groups left the tokens in whatever order the
    /// balance scan happened to return them, which looks arbitrary because it is.
    ///
    /// Keyed by `Network`, not by `Chain?` — a token on Monero and a token on HyperEVM
    /// both answer `nil` for chain, and they are not the same network.
    public func groupedRows(forWallet walletId: String) -> [(network: Network, rows: [PricedHolding])] {
        Self.grouped(rows(forWallet: walletId))
    }

    /// Rows grouped by network, most valuable network first and the biggest holding
    /// first inside it. Shared so the portfolio and each wallet module group alike.
    public static func grouped(_ rows: [PricedHolding]) -> [(network: Network, rows: [PricedHolding])] {
        var order: [Network] = []
        var groups: [Network: [PricedHolding]] = [:]
        for row in rows {
            let net = Network.of(row.token)
            if groups[net] == nil {
                order.append(net)
                groups[net] = []
            }
            groups[net]!.append(row)
        }
        func total(_ rows: [PricedHolding]) -> Decimal {
            rows.reduce(0) { $0 + ($1.usdValue ?? 0) }
        }
        // Sorted by value, falling back to first-appearance order so two equal groups
        // (or two unpriced ones) don't shuffle between renders.
        return order
            .enumerated()
            .sorted { a, b in
                let ta = total(groups[a.element]!), tb = total(groups[b.element]!)
                return ta == tb ? a.offset < b.offset : ta > tb
            }
            .map { (network: $0.element,
                    // Unpriced rows sink rather than reading as zero-value.
                    rows: groups[$0.element]!.sorted { ($0.usdValue ?? -1) > ($1.usdValue ?? -1) }) }
    }

    // MARK: - Stage 2: live refresh + wallet management

    /// Load real wallets from the secret store and fetch balances, pricing from the
    /// quote cache unless it has aged out (or `force` is set).
    /// With no real wallets, falls back to the MockData demo so the app isn't blank.
    @MainActor
    public func refresh(force: Bool = false) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        adoptDemoIfEdited()
        let secrets = secret.loadWallets()
        let manuals = secret.manualHoldings()
        guard !secrets.isEmpty || !manuals.isEmpty else {
            wallets = MockData.wallets
            holdings = MockData.holdings
            prices = MockData.prices
            return
        }

        var newWallets: [Wallet] = []
        var newHoldings: [Holding] = []
        for s in secrets {
            newWallets.append(Wallet(id: s.nickname, nickname: s.nickname,
                                     manualNetwork: s.network.isEmpty ? nil : s.network))
            newHoldings += Self.manualHoldings(for: s, manuals: manuals)
        }

        // Quotes: fetched only when the cached ones have aged out, or when forced. An
        // edit re-composes locally and never lands here, so typing an amount costs no
        // network at all; the periodic refresh keeps prices current on its own clock.
        let keys = Array(Set(newHoldings.map { Self.priceKey(for: $0.token) }))
        let stale = quotedAt.map { Date().timeIntervalSince($0) >= Self.quoteLifetime } ?? true
        if !keys.isEmpty, force || stale {
            do {
                let fresh = try await priceService.prices(forKeys: keys)
                // Merged rather than replaced: a key the source didn't answer for this
                // time keeps its last known quote instead of blinking to unpriced.
                for (k, v) in fresh { quotes[k] = v }
                quotedAt = Date()
            } catch {
                lastError = (lastError.map { $0 + " · " } ?? "") + "price fetch failed"
            }
            // 24h change rides the same keyless batch. Best-effort: a miss leaves the row
            // without a delta rather than showing a fabricated 0%.
            if let ch = try? await priceService.changes24h(forKeys: keys) {
                for (k, v) in ch { quoteChanges[k] = v }
            }
            quoteCache.save(QuoteSnapshot(at: quotedAt ?? Date(),
                                          prices: quotes, changes: quoteChanges))
        }

        change24h = Self.changeMap(for: newHoldings, changes: quoteChanges)

        wallets = newWallets
        holdings = newHoldings
        prices = Self.priceStates(for: newHoldings, quotes: quotes)
        lastUpdated = Date()
        // No snapshot here. A refresh happening to land is not a thing worth recording:
        // it made the archive a log of when the app was open, with several marks on the
        // days it was used and none on the days it wasn't, which is a shape that says
        // nothing about the portfolio. The History tab's button records a day, on purpose.
    }

    // MARK: - The archive

    /// Every mark ever made, oldest first.
    public func historyPoints() -> [HistoryStore.Point] { history.load() }

    /// When the archive file last changed; see `HistoryStore.stamp`.
    public var historyStamp: Date? { history.stamp }

    /// Whether today has already been marked.
    public var archivedToday: Bool { history.hasMark() }

    /// Record what the portfolio is worth today, and how that splits across wallets.
    ///
    /// Deliberately a button and not a side effect of refreshing — see `refresh`. Returns
    /// false when there is nothing to record, so the button can say so rather than
    /// appearing to work.
    @MainActor
    @discardableResult
    public func archiveToday() -> Bool {
        let total = totalUSD
        guard total > 0 else {
            lastError = "Nothing to archive yet — refresh so there are values to record."
            return false
        }
        var breakdown: [String: Decimal] = [:]
        for share in walletShares { breakdown[share.nickname] = share.usd }
        return history.archive(total: total, breakdown: breakdown)
    }

    /// Record today's mark if one is due under `cadence` — run after a refresh, on prices
    /// already fetched, so it costs no lookups. Returns whether it recorded.
    @MainActor
    @discardableResult
    public func archiveIfDue(_ cadence: HistoryStore.Cadence, now: Date = Date()) -> Bool {
        // Never the built-in demo's made-up worth into a real archive.
        guard hasRealWallets,
              HistoryStore.isDue(cadence, marks: history.load().map(\.date), now: now) else { return false }
        return archiveToday()
    }

    /// Drop a day's mark. The archive is hand-made, so a bad entry has to be removable.
    @MainActor
    public func removeArchive(on date: Date) { history.removeMark(on: date) }

    /// Strike a wallet's column out of every mark, its dollars with it.
    @MainActor
    public func removeArchivedWallet(_ name: String) { history.removeWallet(name) }

    /// Your holdings of a symbol broken out per wallet + network — for the token detail view.
    public func breakdown(forSymbol symbol: String) -> [(wallet: String, network: Network, amount: Decimal, usd: Decimal?)] {
        holdings.filter { $0.token.symbol == symbol }.map { h in
            var usd: Decimal?
            if case .priced(let p) = (prices[h.token.id] ?? .unpriced) { usd = h.amount * p }
            return (wallet: h.walletId, network: Network.of(h.token), amount: h.amount, usd: usd)
        }
    }

    @MainActor
    public func addWallet(nickname: String) async {
        secret.addWallet(WalletSecret(nickname: nickname))
        await refresh()
    }

    /// Manual (non-EVM) tokens the user added to a given wallet.
    public func manualHoldings(forWallet walletId: String) -> [ManualHolding] {
        secret.manualHoldings().filter { $0.walletId == walletId }
    }

    /// Add a token from whatever the user typed — a contract address, or a coin's name.
    ///
    /// The network is DISCOVERED, never chosen. Asking which chain an address is on asks
    /// the user to do the lookup, and it cannot express a coin like Monero that is its
    /// own chain. Anything that doesn't resolve sets `lastError` and adds nothing, rather
    /// than storing a nameless unpriced row.
    @MainActor
    public func addToken(walletId: String, query: String, amount: Decimal,
                         network: String? = nil) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !walletId.isEmpty else { return }
        guard let found = await locator.find(text) else {
            lastError = TokenLocator.looksLikeContract(text)
                ? "Couldn't find that contract on any network we price."
                : "No coin found for that name. Try the contract address instead."
            return
        }
        // A chosen network only applies to a coin that had a choice to make; a contract
        // already named its chain and must not be overridden.
        let chosen = found.isOnChain ? found.networkName
            : (network.flatMap { found.availableNetworks.contains($0) ? $0 : nil } ?? found.networkName)
        // Adding a token already held on the same network tops it up rather than
        // replacing it — "add 5 more" is what the second entry means.
        let existing = secret.manualHoldings().first {
            $0.walletId == walletId
            && $0.symbol.caseInsensitiveCompare(found.symbol) == .orderedSame
            && $0.networkName == chosen
        }
        secret.addManualHolding(ManualHolding(walletId: walletId, symbol: found.symbol,
                                              amount: (existing?.amount ?? 0) + amount,
                                              network: found.network,
                                              contractAddress: found.contract,
                                              coingeckoId: found.coingeckoId,
                                              networkName: chosen))
        // The lookup just returned a price — seed it rather than making the user wait
        // for a refresh to learn what we already know.
        if let net = found.network, let ca = found.contract {
            quotes["\(net):\(ca)"] = found.price
        } else if let id = found.coingeckoId {
            quotes["coingecko:\(id)"] = found.price
        }
        rebuildLocally()
    }

    /// Look up what the user typed WITHOUT storing it, so the form can show the symbol,
    /// the network it was found on, and the price before they commit.
    public func preview(_ query: String) async -> TokenLocator.Found? {
        await locator.find(query)
    }

    /// The add-token form's lookup: found, no such coin, or the price sites didn't answer.
    public func lookup(_ query: String) async -> TokenLocator.Outcome {
        await locator.lookup(query)
    }

    /// The hand-entered holding behind a row, if there is one. A demo row has no
    /// stored entry — its amount comes from the chain and isn't ours to edit.
    public func manualHolding(walletId: String, symbol: String,
                              network: String? = nil) -> ManualHolding? {
        secret.manualHoldings().first {
            $0.walletId == walletId
            && $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame
            && (network == nil || $0.networkName == network)
        }
    }

    /// True when this row's amount can be typed over: it was entered by hand.
    public func isEditable(walletId: String, symbol: String, network: String? = nil) -> Bool {
        manualHolding(walletId: walletId, symbol: symbol, network: network) != nil
    }

    /// Move a hand-entered holding to a different network — any of them, contract or not.
    ///
    /// A contract-identified token used to be refused here, on the reasoning that its
    /// chain had been discovered FROM the address. That reasoning describes how the
    /// token was found, not where it is held: the same asset routinely sits on several
    /// chains, and only the holder knows which. So the move is always allowed and the
    /// price is re-resolved for the destination, in the order that keeps the figure
    /// honest:
    ///
    ///   1. the same address, priced on the target chain — a canonical bridge deployment
    ///   2. the coin it belongs to, priced by id — same asset, so the same figure
    ///   3. the coin looked up afresh from its ticker
    ///
    /// If none of those answer, the move still happens — the holder is right about where
    /// their coins are — but the row goes unpriced and `lastError` says why rather than
    /// letting a silent dash stand for an explanation.
    @MainActor
    public func setManualNetwork(walletId: String, symbol: String,
                                 from: String, to: String) async {
        guard from != to,
              let existing = manualHolding(walletId: walletId, symbol: symbol, network: from)
        else { return }

        var network: String?
        var contract: String?
        var coingeckoId = existing.coingeckoId
        var priced = false

        if let ca = existing.contractAddress, let key = TokenLocator.networkKey(forDisplayName: to),
           let hit = await locator.priced(contract: ca, onNetwork: key) {
            network = hit.network
            contract = hit.contract
            quotes["\(key):\(ca.lowercased())"] = hit.price
            priced = true
        } else if let id = coingeckoId {
            // Priced by id: the asset is the same wherever it is held, so the figure is
            // right even though the contract link is gone.
            priced = quotes["coingecko:\(id)"] != nil
            if !priced, let hit = await locator.find(existing.symbol), hit.coingeckoId == id {
                quotes["coingecko:\(id)"] = hit.price
                priced = true
            }
        } else if let hit = await locator.find(existing.symbol), let id = hit.coingeckoId {
            coingeckoId = id
            quotes["coingecko:\(id)"] = hit.price
            priced = true
        }

        // Re-keyed rather than edited in place: the network is part of the key, so the
        // old entry has to go or the holding exists twice.
        secret.removeManualHolding(walletId: walletId, symbol: symbol, network: from)
        secret.addManualHolding(ManualHolding(walletId: walletId, symbol: existing.symbol,
                                              amount: existing.amount,
                                              network: network,
                                              contractAddress: contract,
                                              coingeckoId: coingeckoId,
                                              networkName: to))
        if !priced {
            lastError = "Moved \(existing.symbol) to \(to), but nothing prices it there — "
                      + "the amount is kept, the value will show as \u{2014}."
        }
        rebuildLocally()
    }

    /// Change how much of a hand-entered token a wallet holds. Everything else about the
    /// entry — the network it was found on, its contract, its coin id — is kept, so an
    /// edit doesn't quietly undo the lookup that identified it.
    @MainActor
    public func setManualAmount(walletId: String, symbol: String, amount: Decimal,
                                network: String? = nil) async {
        guard amount > 0,
              let existing = manualHolding(walletId: walletId, symbol: symbol, network: network)
        else { return }
        secret.addManualHolding(ManualHolding(walletId: walletId, symbol: existing.symbol,
                                              amount: amount,
                                              network: existing.network,
                                              contractAddress: existing.contractAddress,
                                              coingeckoId: existing.coingeckoId,
                                              networkName: existing.networkName))
        rebuildLocally()      // an amount is local; nothing on the network knows about it
    }

    @MainActor
    public func removeManualToken(walletId: String, symbol: String,
                                  network: String? = nil) async {
        secret.removeManualHolding(walletId: walletId, symbol: symbol, network: network)
        rebuildLocally()      // removing a hand-entered row changes nothing on chain
    }

    /// Set the network label for a manual wallet (e.g. "Sia") — retroactive edit.
    @MainActor
    public func setWalletNetwork(nickname: String, network: String) async {
        secret.setWalletNetwork(nickname: nickname,
                                network: network.trimmingCharacters(in: .whitespaces))
        await refresh()
    }

    // MARK: - Wallet presentation

    /// Rename a wallet, carrying its manual holdings, colour, position — and its history —
    /// with it.
    @MainActor
    public func renameWallet(from old: String, to new: String) async {
        let clean = new.trimmingCharacters(in: .whitespaces)
        secret.renameWallet(from: old, to: new)
        // Only once the wallet file actually took the new name — it refuses an empty or
        // tab-holding one — so the archive never renames to something no wallet is called.
        if clean != old, secret.loadWallets().contains(where: { $0.nickname == clean }) {
            history.renameWallet(from: old, to: clean)
        }
        await refresh()
    }

    public func walletColorHex(_ nickname: String) -> String? { secret.walletColor(nickname) }

    /// A colour a wallet can wear, with the name it goes by.
    public struct WalletColor: Sendable, Equatable {
        public let hex: String
        public let romaji: String
        public let kanji: String
        public var name: String { "\(romaji) \(kanji)" }

        public init(_ hex: String, _ romaji: String, _ kanji: String) {
            self.hex = hex
            self.romaji = romaji
            self.kanji = kanji
        }
    }

    /// Banner colours a wallet can be given — 24 traditional Japanese colours, from the
    /// shared list at `_Graphics/Palettes/nippon-colors.json`.
    ///
    /// Picked from the saturated end of that list, not the pastel end Art Line NYC draws
    /// from: a wallet's colour is an identifier, and an identifier has to be unmistakable
    /// at a glance and in a chart slice. Every entry clears S 0.36 and sits between L 37
    /// and L 80, so none of them sinks into the near-black canvas or washes out on it.
    /// Ruri and Edomurasaki are the two dimmest, a touch under the 3:1 a non-text block
    /// normally wants — kept because the Nippon list has no lighter blue or violet, and
    /// losing those hues costs more than those two being the quietest.
    ///
    /// The ORDER is the work. Wallets take their default by counting through this list,
    /// so the run matters more than the set: consecutive entries are at least ΔLab 34
    /// apart, which is why the first several wallets on a fresh canvas never read alike.
    /// Across the whole set the closest pair is ΔLab 17, so even the twenty-fourth wallet
    /// is still its own colour.
    /// The colours a wallet can wear — the same 24 Banking offers its categories (Nippon,
    /// the joyful half), in the same order: one palette across the app.
    public static let walletColors: [WalletColor] = [
        WalletColor("#90B44B", "Hiwamoegi", "鶸萌黄"),
        WalletColor("#E83015", "Syojyohi", "猩猩緋"),
        WalletColor("#D19826", "Yamabukicha", "山吹茶"),
        WalletColor("#7B90D2", "Benimidori", "紅碧"),
        WalletColor("#5DAC81", "Wakatake", "若竹"),
        WalletColor("#986DB2", "Hashita", "半"),
        WalletColor("#2EA9DF", "Tsuyukusa", "露草"),
        WalletColor("#C1693C", "Kaba", "樺"),
        WalletColor("#E03C8A", "Tsutsuji", "躑躅"),
        WalletColor("#3A8FB7", "Chigusa", "千草"),
        WalletColor("#E98B2A", "Beniukon", "紅鬱金"),
        WalletColor("#D0104C", "Karakurenai", "韓紅花"),   // not Gunjyo #51A8DD: it read as Tsuyukusa
        WalletColor("#DC9FB4", "Nadeshiko", "撫子"),
        WalletColor("#F596AA", "Momo", "桃"),
        WalletColor("#B481BB", "Benifuji", "紅藤"),
        WalletColor("#A5DEE4", "Kamenozoki", "瓶覗"),
        WalletColor("#81C7D4", "Mizu", "水"),
        WalletColor("#7DB9DE", "Wasurenagusa", "勿忘草"),
        WalletColor("#A8D8B9", "Byakuroku", "白緑"),
        WalletColor("#86C166", "Nae", "苗"),
        WalletColor("#F7D94C", "Nanohana", "菜の花"),
        WalletColor("#FFB11B", "Yamabuki", "山吹"),
        WalletColor("#FB966E", "Araisyu", "洗朱"),
        WalletColor("#E87A90", "Usubeni", "薄紅")
    ]

    public static let walletPalette: [String] = walletColors.map(\.hex)

    /// What a colour is called, for the swatch that offers it.
    public static func walletColorName(_ hex: String) -> String? {
        walletColors.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name
    }

    /// The colour a wallet actually wears, chosen or defaulted — the ONE answer every
    /// screen asks for.
    ///
    /// Each screen used to default its own way, off its own index: the modules counted
    /// through `orderedWallets`, the portfolio's wallet ring counted through
    /// `walletShares`, which is sorted by value and skips empty wallets. So a wallet
    /// nobody had recoloured was green on one tab and orange on the other. The default
    /// is only meaningful against the arranged order, so that is the only place it is
    /// worked out.
    public func walletTintHex(_ nickname: String) -> String {
        if let chosen = secret.walletColor(nickname) { return chosen }
        if let i = orderedWalletNames.firstIndex(of: nickname) {
            return Self.walletPalette[i % Self.walletPalette.count]
        }
        // A name that is not a current wallet — renamed or removed, but still named in
        // the archive, where the past cannot be edited. Alone, it can only be given a
        // guess; `walletTints(for:)` is the one that can answer properly, because it sees
        // every name at once.
        let h = nickname.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.walletPalette[h % Self.walletPalette.count]
    }

    /// Colours for a whole set of names at once, including names that are no longer
    /// wallets.
    ///
    /// Asked one at a time, a retired name can only be hashed into the palette, and
    /// hashes collide — five retired wallets came out as four colours, which in a stacked
    /// chart is two bands that cannot be told apart. Assignment has to see the whole set:
    /// current wallets keep the colour the Wallets tab gave them, and whatever is left
    /// takes palette entries nobody else is using, in a stable order so it is the same
    /// colour every launch.
    public func walletTints(for names: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var used = Set<String>()
        for name in names where orderedWalletNames.contains(name) || secret.walletColor(name) != nil {
            let hex = walletTintHex(name)
            out[name] = hex
            used.insert(hex.uppercased())
        }
        var pool = Self.walletPalette.filter { !used.contains($0.uppercased()) }
        // Sorted, so the same archive draws the same colours whatever order it loaded in.
        for name in names.filter({ out[$0] == nil }).sorted() {
            if pool.isEmpty { pool = Self.walletPalette }   // more names than colours
            out[name] = pool.removeFirst()
        }
        return out
    }

    /// Where the module sits on the canvas, or nil if it has never been placed.
    public func walletPosition(_ nickname: String) -> (x: Double, y: Double)? {
        secret.walletPosition(nickname)
    }

    @MainActor
    public func setWalletPosition(_ nickname: String, x: Double, y: Double) {
        secret.setWalletPosition(nickname, x: x, y: y)
    }

    @MainActor
    public func setWalletColor(_ nickname: String, hex: String) {
        secret.setWalletColor(nickname, hex)
        // Nudge observers: the colour lives in the secret file, not in `wallets`.
        wallets = wallets
    }

    /// Wallet nicknames in their arranged order; anything unplaced follows in natural order.
    public var orderedWalletNames: [String] {
        let stored = secret.walletOrder()
        let present = wallets.map(\.nickname)
        let placed = stored.filter { present.contains($0) }
        return placed + present.filter { !placed.contains($0) }
    }

    /// Wallets in their arranged order — what the wallet modules iterate.
    public var orderedWallets: [Wallet] {
        let byName = Dictionary(wallets.map { ($0.nickname, $0) }, uniquingKeysWith: { a, _ in a })
        return orderedWalletNames.compactMap { byName[$0] }
    }

    @MainActor
    public func setWalletOrder(_ names: [String]) {
        secret.setWalletOrder(names)
        wallets = wallets            // republish so the grid reorders
    }

    /// Move `name` to sit where `target` currently sits.
    @MainActor
    public func moveWallet(_ name: String, before target: String) {
        var names = orderedWalletNames
        guard let from = names.firstIndex(of: name), name != target else { return }
        names.remove(at: from)
        guard let to = names.firstIndex(of: target) else { return }
        names.insert(name, at: to)
        setWalletOrder(names)
    }

    @MainActor
    public func removeWallet(nickname: String) async {
        // Drop the wallet AND any manual tokens attached to it.
        for m in secret.manualHoldings() where m.walletId == nickname {
            secret.removeManualHolding(walletId: nickname, symbol: m.symbol)
        }
        secret.removeWallet(nickname: nickname)
        await refresh()
    }

    public func apiKey(_ name: String) -> String? { secret.apiKey(name) }
    public func setAPIKey(_ name: String, _ value: String?) { secret.setAPIKey(name, value) }

    // MARK: - Composing holdings

    /// A wallet's hand-entered holdings, as tokens.
    ///
    /// One whose discovered network is a chain the app draws a badge for keeps its
    /// `Chain`; one on any other chain we can price carries the discovered network name;
    /// a coin with no contract at all prices by its id.
    static func manualHoldings(for s: WalletSecret, manuals: [ManualHolding]) -> [Holding] {
        var out: [Holding] = []
        for m in manuals where m.walletId == s.nickname {
            let token: Token
            if let net = m.network, let ca = m.contractAddress {
                let chain = Chain.allCases.first { DefiLlamaPriceService.llamaChainKey($0) == net }
                token = Token(symbol: m.symbol, name: m.symbol, decimals: 18, chain: chain,
                              contractAddress: ca, coingeckoId: nil,
                              kind: kind(for: m.symbol), colorHex: color(for: m.symbol),
                              manualNetwork: chain == nil ? m.networkName : nil,
                              llamaNetwork: chain == nil ? net : nil)
            } else {
                // A coin held on a chain the app also scans groups under that chain's
                // tab; one on its own chain (Monero) keeps its network as a label.
                let named = m.networkName.isEmpty
                    ? (s.network.isEmpty ? nil : s.network) : m.networkName
                let onKnownChain = Chain.allCases.first { $0.displayName == named }
                token = Token(symbol: m.symbol, name: m.symbol, decimals: 0,
                              chain: onKnownChain,
                              contractAddress: nil, coingeckoId: m.coingeckoId,
                              kind: kind(for: m.symbol), colorHex: color(for: m.symbol),
                              manualNetwork: named)
            }
            out.append(Holding(walletId: s.nickname, token: token, amount: m.amount))
        }
        return out
    }

    /// Re-compose and re-price from what is already in memory — no network at all.
    ///
    /// Editing an amount used to run a full refresh: a balance scan across every wallet
    /// and chain, then a price fetch, for a number the user just typed. The scan can't
    /// tell us anything about a hand-entered amount, and quotes from four minutes ago
    /// are the same quotes. So an edit re-composes against the last scan and prices from
    /// the quote cache, and the periodic refresh keeps prices current on its own clock.
    @MainActor
    public func rebuildLocally() {
        let adopted = adoptDemoIfEdited()
        let secrets = secret.loadWallets()
        let manuals = secret.manualHoldings()
        if adopted {
            wallets = secrets.map { Wallet(id: $0.nickname, nickname: $0.nickname,
                                           manualNetwork: $0.network.isEmpty ? nil : $0.network) }
        }
        var out: [Holding] = []
        for s in secrets {
            out += Self.manualHoldings(for: s, manuals: manuals)
        }
        holdings = out
        prices = Self.priceStates(for: out, quotes: quotes)
        change24h = Self.changeMap(for: out, changes: quoteChanges)
    }

    /// The demo wallets, edited, become the user's own.
    ///
    /// With no wallets of their own the app shows `MockData`, whose wallets have ids
    /// (`w1`, `w2`) and no line in the wallet file. A token added to one was saved under
    /// that id — a wallet that doesn't exist — so the next rebuild saw "real" data with no
    /// wallet to hang it on and drew nothing at all. So: when the file holds no wallets and
    /// every hand-entered holding belongs to a demo wallet, the demo is written out as
    /// hand-entered wallets and holdings first, the stray holdings move to the wallet's
    /// name, and the edit lands where it was made. Tokens hidden from the demo stay hidden
    /// (same token ids). A file with any wallet, or any holding not on a demo wallet, is
    /// never touched. Returns whether it adopted.
    @discardableResult
    func adoptDemoIfEdited() -> Bool {
        let manuals = secret.manualHoldings()
        let demoIds = Set(MockData.wallets.map(\.id))
        guard secret.loadWallets().isEmpty, !manuals.isEmpty,
              manuals.allSatisfy({ demoIds.contains($0.walletId) }) else { return false }
        let name = Dictionary(uniqueKeysWithValues: MockData.wallets.map { ($0.id, $0.nickname) })
        for w in MockData.wallets { secret.addWallet(WalletSecret(nickname: w.nickname)) }
        for h in MockData.holdings {
            guard let owner = name[h.walletId] else { continue }
            let t = h.token
            let held: ManualHolding
            if t.symbol == "ETH", let chain = t.chain {
                // Native ether: priced by coin id, grouped under its chain.
                held = ManualHolding(walletId: owner, symbol: t.symbol, amount: h.amount,
                                     coingeckoId: "ethereum", networkName: chain.displayName)
            } else if let ca = t.contractAddress, let chain = t.chain {
                held = ManualHolding(walletId: owner, symbol: t.symbol, amount: h.amount,
                                     network: DefiLlamaPriceService.llamaChainKey(chain),
                                     contractAddress: ca, networkName: chain.displayName)
            } else if let ca = t.contractAddress, let net = t.llamaNetwork {
                held = ManualHolding(walletId: owner, symbol: t.symbol, amount: h.amount,
                                     network: net, contractAddress: ca, networkName: t.manualNetwork ?? "")
            } else {
                held = ManualHolding(walletId: owner, symbol: t.symbol, amount: h.amount,
                                     coingeckoId: t.coingeckoId, networkName: t.manualNetwork ?? "")
            }
            secret.addManualHolding(held)
        }
        for m in manuals {
            guard let owner = name[m.walletId] else { continue }
            secret.removeManualHolding(walletId: m.walletId, symbol: m.symbol, network: m.networkName)
            secret.addManualHolding(ManualHolding(walletId: owner, symbol: m.symbol, amount: m.amount,
                                                  network: m.network, contractAddress: m.contractAddress,
                                                  coingeckoId: m.coingeckoId, networkName: m.networkName))
        }
        return true
    }

    /// Price every holding from a set of quotes; anything unquoted stays unpriced rather
    /// than being invented as zero.
    static func priceStates(for holdings: [Holding],
                            quotes: [String: Decimal]) -> [String: PriceState] {
        var out: [String: PriceState] = [:]
        for h in holdings {
            if let p = quotes[priceKey(for: h.token)] { out[h.token.id] = .priced(usd: p) }
            else { out[h.token.id] = .unpriced }
        }
        return out
    }

    static func changeMap(for holdings: [Holding],
                          changes: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for h in holdings where out[h.token.id] == nil {
            if let c = changes[priceKey(for: h.token)] { out[h.token.id] = c }
        }
        return out
    }

    /// DefiLlama key: `chain:contract` for ERC-20s; native coins price via CoinGecko id.
    static func priceKey(for token: Token) -> String {
        if let ca = token.contractAddress, ca != "native", let chain = token.chain {
            return DefiLlamaPriceService.llamaKey(chain: chain, contract: ca)
        }
        // A chain the app prices but doesn't scan balances on (Polygon, Optimism, …).
        if let ca = token.contractAddress, let net = token.llamaNetwork { return "\(net):\(ca)" }
        if let cg = token.coingeckoId { return "coingecko:\(cg)" }
        return "coingecko:ethereum"   // native ETH on Ethereum/Arbitrum/Base
    }

    /// Classification lives in TokenClassifier, which matches on a normalised symbol —
    /// the two flat lists here missed `rock.reth` and every other prefixed wrapper.
    static func kind(for symbol: String) -> TokenKind {
        TokenClassifier.kind(for: symbol)
    }

    private static let palette = ["#6B7BE8","#F4A07A","#3B82C4","#7FBF6B","#FF6600","#8A6FE8",
                                  "#E8C66B","#6BE8C0","#E86B9F","#9FE86B","#6BA8E8","#E8746B"]

    /// Deterministic per-symbol color so the same token always tints the same.
    static func color(for symbol: String) -> String {
        let h = symbol.uppercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[h % palette.count]
    }
}
