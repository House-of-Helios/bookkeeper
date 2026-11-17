import Foundation

/// Works out what a token IS from the one thing the user actually knows about it.
///
/// Asking which network a contract lives on is asking the user to do the lookup: they
/// have an address, not a map, and picking the wrong chain from a menu of three just
/// produces "not found" for a token that exists. Worse, the menu can't express a coin
/// that has no contract at all — Monero is its own network, so no EVM chain is the
/// right answer and the form has no way to say so.
///
/// So there is one input and the app does the work:
///   - looks like `0x…40 hex`  → probe every supported chain at once, keep what answers
///   - anything else           → treat it as a name or ticker and resolve the coin
public struct TokenLocator: Sendable {
    private let fetcher: DataFetcher
    private let search: CoinSearchService

    public init(fetcher: DataFetcher = URLSessionFetcher(),
                search: CoinSearchService = CoinGeckoSearchService()) {
        self.fetcher = fetcher
        self.search = search
    }

    /// What a lookup found: enough to price it, draw it, and tell the user where it lives.
    public struct Found: Sendable, Equatable {
        public let symbol: String
        public let decimals: Int
        public let price: Decimal
        public let confidence: Double
        /// Display name of the network, e.g. "Base", "Polygon", "Monero".
        public let networkName: String
        /// DefiLlama chain key for an on-chain token (`base`), nil for a coin priced by id.
        public let network: String?
        public let contract: String?
        /// CoinGecko id for a coin with no contract (Monero, Siacoin).
        public let coingeckoId: String?
        /// Networks this coin can legitimately sit on, when there is a real choice.
        ///
        /// A contract address answers "which chain" by itself — it only exists on one.
        /// A native coin doesn't: ETH is ETH on Ethereum, Arbitrum and Base, and nothing
        /// about the name says which one it's being held on. Only the holder knows, so
        /// when this has more than one entry the form has to ask.
        public let availableNetworks: [String]

        public var isOnChain: Bool { contract != nil }
        public var needsNetworkChoice: Bool { availableNetworks.count > 1 }
    }

    /// Chains a pasted address is searched across. Far more than the three the app scans
    /// balances on — a token you hold on Polygon is perfectly trackable by hand even
    /// though no Polygon balance scan exists, and searching a chain costs nothing extra
    /// because every chain goes into the same single batched request.
    public static let chains: [(key: String, name: String, chainId: Int)] = [
        ("ethereum", "Ethereum", 1),
        ("base",     "Base",     8453),
        ("arbitrum", "Arbitrum", 42161),
        ("optimism", "Optimism", 10),
        ("polygon",  "Polygon",  137),
        ("bsc",      "BNB Chain", 56),
        ("avax",     "Avalanche", 43114),
        ("gnosis",   "Gnosis",   100),
        ("linea",    "Linea",    59144),
        ("scroll",   "Scroll",   534352),
        ("zksync",   "zkSync",   324),
        ("blast",    "Blast",    81457),
        ("mantle",   "Mantle",   5000),
        ("celo",     "Celo",     42220),
        ("fantom",   "Fantom",   250),
        // DefiLlama files chain 999 under `hyperliquid`; the explorer, the holder and
        // CoinGecko's platform id all call it HyperEVM, so that is the name we show.
        ("hyperliquid", "HyperEVM", 999)
    ]

    public static func displayName(forNetwork key: String) -> String {
        chains.first { $0.key == key }?.name ?? key.capitalized
    }

    public static func chainId(forNetwork key: String) -> Int? {
        chains.first { $0.key == key }?.chainId
    }

    /// The chain key behind a display name ("Arbitrum" → "arbitrum"). The stored side of
    /// a holding keeps the display name, so moving one between networks has to translate
    /// back before it can ask what the contract is worth over there.
    public static func networkKey(forDisplayName name: String) -> String? {
        chains.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.key
    }

    /// Coins that are native to more than one chain the app knows about, by CoinGecko id.
    /// Their price is the same everywhere — it is the same asset — so only the network
    /// label differs, which is why this is a display question and not a pricing one.
    public static let nativeNetworks: [String: [String]] = [
        "ethereum": ["Ethereum", "Arbitrum", "Base"],
        // HYPE is HyperEVM's gas coin AND a spot balance on HyperCore, but the register
        // lists only the latter — so the holder has a real choice it cannot express.
        "hyperliquid": ["HyperEVM", "Hyperliquid"]
    ]

    /// `0x` + 40 hex digits.
    public static func looksLikeContract(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count == 42 && t.lowercased().hasPrefix("0x")
            && t.dropFirst(2).allSatisfy { $0.isHexDigit }
    }

    /// What a lookup came to: the token, no such token, or no answer at all.
    public enum Outcome: Sendable, Equatable {
        case found(Found)
        case notFound
        /// The price sites didn't answer — offline, Tor still connecting, or busy. Not
        /// the same as "no such coin", and the form must not say it is.
        case unreachable

        public var found: Found? { if case .found(let f) = self { return f } else { return nil } }
    }

    /// Resolve whatever the user typed.
    public func find(_ input: String) async -> Found? { await lookup(input).found }

    /// Resolve whatever the user typed, telling a miss from a failure to ask.
    public func lookup(_ input: String) async -> Outcome {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .notFound }
        return Self.looksLikeContract(text)
            ? await findContract(text.lowercased())
            : await findCoin(text)
    }

    // MARK: - On-chain: discover the network

    /// One request carrying the same address keyed for every chain. Whichever chains have
    /// a market answer; the most confident one wins, with Ethereum-first ordering as the
    /// tie-break since a token deployed at the same address on several chains is usually
    /// canonical there.
    private func findContract(_ contract: String) async -> Outcome {
        let keys = Self.chains.map { "\($0.key):\(contract)" }
        let joined = keys.joined(separator: ",")
        guard let url = URL(string: "https://coins.llama.fi/prices/current/\(joined)") else { return .notFound }
        guard let data = try? await fetcher.freshData(from: url, headers: [:]) else { return .unreachable }
        guard let resp = try? JSONDecoder().decode(PriceLookupResponse.self, from: data) else { return .notFound }

        var best: (rank: Int, key: String, coin: PriceLookupResponse.Coin)?
        for (rank, chain) in Self.chains.enumerated() {
            guard let coin = resp.coins["\(chain.key):\(contract)"] else { continue }
            let better = best.map { current in
                (coin.confidence ?? 0) > (current.coin.confidence ?? 0)
            } ?? true
            if better { best = (rank, chain.key, coin) }
        }
        guard let hit = best, let symbol = hit.coin.symbol else { return .notFound }

        // What the contract calls itself is not necessarily what the token is called.
        // `symbol()` is written once at deployment and can never change, so a rebranded
        // token answers with its old ticker forever — Ethereum's `0x7d1a…ebb0` still says
        // WMATIC for a coin that has been POL since 2024. One lookup against the coin
        // register gets the current name, and the id that comes back is what lets the
        // logo match the one a search by ticker would have found.
        var identity: CoinIdentity?
        if let platform = Self.platform(forNetwork: hit.key) {
            identity = await search.identity(platform: platform, contract: contract)
        }

        return .found(Found(symbol: Self.preferredSpelling(onChain: symbol, registered: identity?.symbol),
                     decimals: hit.coin.decimals ?? 18,
                     price: hit.coin.price,
                     confidence: hit.coin.confidence ?? 0,
                     networkName: Self.displayName(forNetwork: hit.key),
                     network: hit.key,
                     contract: contract,
                     coingeckoId: identity?.id,
                     availableNetworks: []))   // an address already names its chain
    }

    private static func platform(forNetwork key: String) -> String? {
        CoinGeckoSearchService.platformIds[key]
    }

    /// Our chain key for a CoinGecko platform id, when we price that chain.
    static func networkKey(forPlatform platform: String) -> String? {
        CoinGeckoSearchService.platformIds.first { $0.value == platform }?.key
    }

    /// How to spell a ticker, given what the contract says and what the register says.
    ///
    /// The two sources are each authoritative about a different half of the answer, and
    /// the halves pull in opposite directions:
    ///
    ///   - the contract has the CASING, because `symbol()` stores the string the team
    ///     actually deployed — `rETH`, `wstETH`, `cbETH`, the way the industry writes them
    ///   - the register has the NAME, because a contract cannot be renamed and a rebranded
    ///     token answers with its old ticker forever (`WMATIC` for what is now `POL`)
    ///
    /// The register normalises case, so taking its answer outright flattened `rETH` to
    /// `RETH`. Taking the contract's outright brings the stale names back. So: same
    /// letters means the register only re-cased it and the contract's spelling stands;
    /// different letters means a real rename and the register wins.
    static func preferredSpelling(onChain: String?, registered: String?) -> String {
        guard let registered, !registered.isEmpty else { return onChain ?? "" }
        guard let onChain, !onChain.isEmpty else { return registered }
        return onChain.caseInsensitiveCompare(registered) == .orderedSame ? onChain : registered
    }

    /// Is this contract priced on THIS chain? Asked when a holding is moved between
    /// networks: the same address is only occasionally live on both, so the answer
    /// decides whether the move can keep the contract or has to fall back to the coin.
    public func priced(contract: String, onNetwork key: String) async -> Found? {
        let lookup = "\(key):\(contract.lowercased())"
        guard let url = URL(string: "https://coins.llama.fi/prices/current/\(lookup)"),
              let data = try? await fetcher.freshData(from: url, headers: [:]),
              let resp = try? JSONDecoder().decode(PriceLookupResponse.self, from: data),
              let coin = resp.coins[lookup], let symbol = coin.symbol
        else { return nil }
        return Found(symbol: symbol,
                     decimals: coin.decimals ?? 18,
                     price: coin.price,
                     confidence: coin.confidence ?? 0,
                     networkName: Self.displayName(forNetwork: key),
                     network: key,
                     contract: contract.lowercased(),
                     coingeckoId: nil,
                     availableNetworks: [])
    }

    // MARK: - By name: coins with no contract

    /// "Monero", "XMR", "siacoin" — resolved to a coin id, then priced by that id. The
    /// network is the coin's own chain, which is the honest answer for an asset that
    /// isn't a token on somebody else's chain.
    private func findCoin(_ text: String) async -> Outcome {
        let id: String
        switch await search.search(forSymbol: text) {
        case .id(let found): id = found
        case .none: return .notFound
        case .unreachable: return .unreachable
        }
        let key = "coingecko:\(id)"
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://coins.llama.fi/prices/current/\(encoded)") else { return .notFound }
        guard let data = try? await fetcher.freshData(from: url, headers: [:]) else { return .unreachable }
        guard let resp = try? JSONDecoder().decode(PriceLookupResponse.self, from: data),
              let coin = resp.coins[key]
        else { return .notFound }
        let deployments = await search.deployments(forCoin: id)
        // No answer about where it lives is not "it lives on its own chain": only a coin
        // the register says has no home platform (Monero) gets its own name as a network.
        // ETH-like coins listed in `nativeNetworks` need no answer.
        if deployments == nil, Self.nativeNetworks[id] == nil, search.answersDeployments { return .unreachable }
        // Priced by id, the symbol comes back upper-cased — `RETH`, never `rETH`. The
        // contract on the coin's home chain is the one place the real spelling is
        // recorded, so when the coin has one, ask it and keep its casing.
        var onChainSpelling: String?
        if let contract = deployments?.homeContract,
           let platform = deployments?.homePlatform,
           let key = Self.networkKey(forPlatform: platform) {
            onChainSpelling = await priced(contract: contract, onNetwork: key)?.symbol
        }
        let symbol = Self.preferredSpelling(onChain: onChainSpelling,
                                            registered: coin.symbol ?? text.uppercased())
        let choices = Self.networks(forCoin: id, deployments: deployments)
        return .found(Found(symbol: symbol,
                     decimals: coin.decimals ?? 0,
                     price: coin.price,
                     confidence: coin.confidence ?? 0,
                     // Default to the first choice when there is one; the form can change it.
                     networkName: choices.first ?? Self.prettyNetwork(fromCoinId: id),
                     network: nil,
                     contract: nil,
                     coingeckoId: id,
                     // One deployment is not a choice — only ask when there is really
                     // more than one chain the holder could mean.
                     availableNetworks: choices.count > 1 ? choices : []))
    }

    /// The networks a coin can be held on, home chain first.
    ///
    /// A coin id is not a network. Deriving one from the id — "aave" → "Aave" — named a
    /// network after the token for every ERC-20 that was added by ticker rather than by
    /// address, which is how holdings ended up filed under chains that don't exist. That
    /// spelling is only right for a coin that IS its own chain, and the register says
    /// which those are outright: a token has an `asset_platform_id`, Monero has none.
    ///
    /// Returns empty for a coin that is its own chain, so the caller falls back to
    /// spelling out the coin's own name — which is the correct answer in that one case.
    private static func networks(forCoin id: String, deployments: CoinDeployments?) -> [String] {
        // ETH is the exception the register can't express: no asset platform, yet held
        // on three chains we scan. Its own list wins.
        if let native = nativeNetworks[id] { return native }
        guard let found = deployments, let home = found.homePlatform else { return [] }

        var names: [String] = []
        for platform in [home] + found.platforms where !names.contains(name(forPlatform: platform)) {
            names.append(name(forPlatform: platform))
        }
        // Home first, then the networks the app can name, then everything else in the
        // order the register gave. USDC is deployed on 36 chains, so alphabetical order
        // buried Base and Arbitrum among Algorand, Aptos and Hedera. A chain the ledger
        // cannot name draws as an unnamed block, so it is the least likely answer and
        // belongs last — offered, because the holder may really hold it there, but never
        // in the way of the ones they probably mean.
        let head = names.first
        return names.enumerated()
            .sorted { a, b in
                if a.element == head { return true }
                if b.element == head { return false }
                let ka = Network(name: a.element).isNamed, kb = Network(name: b.element).isNamed
                return ka == kb ? a.offset < b.offset : ka
            }
            .map(\.element)
    }

    /// A CoinGecko platform id as a network name. Chains we price get their proper name;
    /// anything else is spelled out from the id, which still beats naming it after the coin.
    static func name(forPlatform platform: String) -> String {
        if let key = CoinGeckoSearchService.platformIds.first(where: { $0.value == platform })?.key {
            return displayName(forNetwork: key)
        }
        return prettyNetwork(fromCoinId: platform)
    }

    /// A coin id doubles as its network's name ("monero" → "Monero", "siacoin" → "Siacoin").
    static func prettyNetwork(fromCoinId id: String) -> String {
        id.split(separator: "-")
          .map { $0.prefix(1).uppercased() + $0.dropFirst() }
          .joined(separator: " ")
    }
}

// MARK: - Decodable

private struct PriceLookupResponse: Decodable {
    let coins: [String: Coin]
    struct Coin: Decodable {
        let price: Decimal
        let symbol: String?
        let decimals: Int?
        let confidence: Double?
    }
}
