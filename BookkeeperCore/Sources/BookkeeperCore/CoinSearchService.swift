import Foundation

/// Resolves a coin SYMBOL the user types (e.g. "XMR", "KAS") to a CoinGecko id used for
/// pricing — so a manual holding needs only a symbol + amount, no id lookup by the user.
public protocol CoinSearchService: Sendable {
    func coinId(forSymbol symbol: String) async -> String?

    /// Like `coinId`, but tells "no coin by that name" apart from "couldn't ask" — through
    /// Tor a search can fail for a moment, and that must not read as the coin not existing.
    func search(forSymbol symbol: String) async -> SearchHit

    /// The coin a contract address belongs to. A REQUIREMENT, not just an extension
    /// default: a method that exists only in a protocol extension is dispatched
    /// statically, so every call through a `CoinSearchService` value would run the
    /// default and a conforming type's own version would never be reached.
    func identity(platform: String, contract: String) async -> CoinIdentity?

    /// Where a coin actually lives. Same reason as above for being a requirement.
    func deployments(forCoin id: String) async -> CoinDeployments?

    /// Whether `deployments` is really asked — false for stubs that never know, so a
    /// nil from them isn't taken as a failure to ask.
    var answersDeployments: Bool { get }
}

/// A coin search's answer.
public enum SearchHit: Sendable, Equatable {
    case id(String)
    /// The register answered and holds no such coin.
    case none
    /// The register couldn't be reached (offline, Tor still connecting, rate-limited).
    case unreachable
}

/// Which chains a coin is deployed on, according to the register.
public struct CoinDeployments: Sendable, Equatable {
    /// The coin's home chain as a CoinGecko platform id, or nil when the coin IS its own
    /// chain. This is the field that separates "Monero, which is the Monero network" from
    /// "AAVE, which is an ERC-20 that merely has a name of its own".
    public let homePlatform: String?
    /// Contract address per platform. Carried rather than discarded because the contract
    /// is the only source that spells a ticker the way the industry writes it — see
    /// `TokenLocator.findCoin`.
    public let contracts: [String: String]

    /// Every platform it is deployed on.
    public var platforms: [String] { contracts.keys.sorted() }

    /// The address on the coin's home chain, when it has one.
    public var homeContract: String? { homePlatform.flatMap { contracts[$0] } }

    public init(homePlatform: String?, contracts: [String: String]) {
        self.homePlatform = homePlatform
        self.contracts = contracts
    }
}

public struct CoinGeckoSearchService: CoinSearchService {
    public var answersDeployments: Bool { true }
    private let fetcher: DataFetcher
    private let auth: CoinGeckoAuth
    public init(fetcher: DataFetcher = URLSessionFetcher(), auth: CoinGeckoAuth = CoinGeckoAuth()) {
        self.fetcher = fetcher
        self.auth = auth
    }

    public func coinId(forSymbol symbol: String) async -> String? {
        if case .id(let id) = await search(forSymbol: symbol) { return id }
        return nil
    }

    public func search(forSymbol symbol: String) async -> SearchHit {
        let q = symbol.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.coingecko.com/api/v3/search?query=\(enc)")
        else { return .none }

        // Retry: the keyless CoinGecko endpoint 429s easily — more so from a Tor exit
        // shared with strangers — and a single miss must not read as "symbol not found".
        // Back off and try a few times; only an answer with no match is "none".
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000) }
            guard let data = try? await fetcher.data(from: url, headers: auth.headers),
                  let resp = try? JSONDecoder().decode(SearchResponse.self, from: data)
            else { continue }
            // Prefer an exact symbol match; among ties, the highest-ranked (lowest number).
            let exact = resp.coins.filter { $0.symbol.uppercased() == q.uppercased() }
            let pool = exact.isEmpty ? resp.coins : exact
            if let id = pool.min(by: { ($0.market_cap_rank ?? .max) < ($1.market_cap_rank ?? .max) })?.id {
                return .id(id)
            }
            return .none
        }
        return .unreachable
    }

    private struct SearchResponse: Decodable {
        let coins: [Coin]
        struct Coin: Decodable { let id: String; let symbol: String; let market_cap_rank: Int? }
    }
}

// MARK: - Identifying the coin behind a contract address

/// What a contract address turns out to be, according to the coin register rather than
/// according to the contract itself.
public struct CoinIdentity: Sendable, Equatable {
    public let id: String
    public let symbol: String
    public init(id: String, symbol: String) {
        self.id = id
        self.symbol = symbol
    }
}

public extension CoinSearchService {
    /// Defaults: nothing known. A stub that only maps symbols keeps working.
    func identity(platform: String, contract: String) async -> CoinIdentity? { nil }
    func search(forSymbol symbol: String) async -> SearchHit {
        (await coinId(forSymbol: symbol)).map(SearchHit.id) ?? .none
    }
    func deployments(forCoin id: String) async -> CoinDeployments? { nil }
    var answersDeployments: Bool { false }
}

public extension CoinGeckoSearchService {

    /// DefiLlama chain key → CoinGecko asset-platform id. The two registers name the
    /// same chains differently ("arbitrum" vs "arbitrum-one", "avax" vs "avalanche",
    /// "gnosis" vs "xdai"), so a lookup by contract has to translate first.
    static let platformIds: [String: String] = [
        "ethereum": "ethereum",
        "base":     "base",
        "arbitrum": "arbitrum-one",
        "optimism": "optimistic-ethereum",
        "polygon":  "polygon-pos",
        "bsc":      "binance-smart-chain",
        "avax":     "avalanche",
        "gnosis":   "xdai",
        "linea":    "linea",
        "scroll":   "scroll",
        "zksync":   "zksync",
        "blast":    "blast",
        "mantle":   "mantle",
        "celo":     "celo",
        "fantom":   "fantom",
        // The one chain the two sources spell differently.
        "hyperliquid": "hyperevm"
    ]

    /// The coin a contract address belongs to — its id and its CURRENT ticker.
    ///
    /// Worth one request because a contract cannot rename itself: `symbol()` is fixed at
    /// deployment, so a token that has since rebranded still answers with the old ticker
    /// forever. Ethereum's `0x7d1a…ebb0` reports WMATIC; the coin it belongs to has been
    /// POL since 2024. Asking the register is the only way to get the name the holder
    /// actually recognises — and the id it returns is what makes the logo match too.
    func identity(platform: String, contract: String) async -> CoinIdentity? {
        guard let enc = contract.lowercased()
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.coingecko.com/api/v3/coins/\(platform)/contract/\(enc)")
        else { return nil }
        await CoinGeckoLimiter.shared.pace()
        guard let data = try? await fetcher.data(from: url, headers: auth.headers),
              let resp = try? JSONDecoder().decode(ContractResponse.self, from: data),
              !resp.id.isEmpty, !resp.symbol.isEmpty
        else { return nil }
        return CoinIdentity(id: resp.id, symbol: resp.symbol.uppercased())
    }

    private struct ContractResponse: Decodable {
        let id: String
        let symbol: String
    }

    /// The chains a coin is deployed on.
    ///
    /// Needed because a coin id alone does not say where the token lives, and guessing
    /// from the id produced nonsense: "aave" became a network called Aave, when AAVE is
    /// an ERC-20 on Ethereum. The register distinguishes the two outright — a coin that
    /// is its own chain has no `asset_platform_id`, a token has one.
    func deployments(forCoin id: String) async -> CoinDeployments? {
        let urlStr = "https://api.coingecko.com/api/v3/coins/\(id)"
            + "?localization=false&tickers=false&market_data=false"
            + "&community_data=false&developer_data=false&sparkline=false"
        guard let url = URL(string: urlStr) else { return nil }
        // Retried like a search: nil here means "couldn't ask", and the caller must not
        // read that as "this coin is its own chain" — it filed USDC under "Usd Coin".
        var answer: CoinResponse?
        for attempt in 0..<4 where answer == nil {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000) }
            await CoinGeckoLimiter.shared.pace()
            if let data = try? await fetcher.data(from: url, headers: auth.headers) {
                answer = try? JSONDecoder().decode(CoinResponse.self, from: data)
            }
        }
        guard let resp = answer else { return nil }
        // An empty address is a placeholder, not a deployment.
        var contracts: [String: String] = [:]
        for (platform, address) in resp.platforms ?? [:] {
            guard let address, !address.isEmpty else { continue }
            contracts[platform] = address
        }
        return CoinDeployments(homePlatform: resp.asset_platform_id, contracts: contracts)
    }

    private struct CoinResponse: Decodable {
        let asset_platform_id: String?
        let platforms: [String: String?]?
    }
}
