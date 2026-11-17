import Foundation

// MARK: - Protocol

public protocol PriceService: Sendable {
    /// Returns USD prices keyed by the same strings passed in.
    /// Keys with no price data are omitted — the caller treats missing as unpriced.
    func prices(forKeys keys: [String]) async throws -> [String: Decimal]

    /// 24h price change (percent) keyed the same way. Sources that can't supply it
    /// return nothing rather than a fabricated zero.
    func changes24h(forKeys keys: [String]) async throws -> [String: Double]
}

public extension PriceService {
    func changes24h(forKeys keys: [String]) async throws -> [String: Double] { [:] }
}

// MARK: - DefiLlama implementation

/// Prices and 24h changes from DefiLlama's public endpoints. No API key, no meaningful
/// rate limit — which is why it leads and CoinGecko (which 429s on the free tier) only
/// fills the gaps behind it.
///
/// Verified live shapes:
///   `/prices/current/<keys>`  → `{"coins":{"<key>":{"decimals":18,"symbol":"COMP",
///                                "price":20.14,"timestamp":…,"confidence":0.99}}}`
///   `/percentage/<keys>`      → `{"coins":{"<key>": 5.7339}}`  (percent, 24h)
/// The percentage figures match CoinGecko's `usd_24h_change` to four decimals.
public struct DefiLlamaPriceService: PriceService {
    private let fetcher: DataFetcher

    public init(fetcher: DataFetcher = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    public func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        try await batched(keys, path: "prices/current") { data in
            let resp = try JSONDecoder().decode(PriceResponse.self, from: data)
            return resp.coins.mapValues { $0.price }
        }
    }

    public func changes24h(forKeys keys: [String]) async throws -> [String: Double] {
        try await batched(keys, path: "percentage") { data in
            try JSONDecoder().decode(ChangeResponse.self, from: data).coins
        }
    }

    /// Full metadata for one contract — symbol, decimals and price in a single keyless
    /// call. This is what makes "paste a contract address" work without a search API:
    /// everything needed to render the token comes back at once.
    public func resolve(chain: Chain, contract: String) async -> ResolvedToken? {
        let key = Self.llamaKey(chain: chain, contract: contract)
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://coins.llama.fi/prices/current/\(encoded)"),
              let data = try? await fetcher.freshData(from: url, headers: [:]),
              let resp = try? JSONDecoder().decode(PriceResponse.self, from: data),
              let coin = resp.coins[key], let symbol = coin.symbol
        else { return nil }
        return ResolvedToken(symbol: symbol, decimals: coin.decimals ?? 18,
                             price: coin.price, confidence: coin.confidence ?? 0)
    }

    /// What a contract address resolves to before it becomes a holding.
    public struct ResolvedToken: Sendable, Equatable {
        public let symbol: String
        public let decimals: Int
        public let price: Decimal
        /// DefiLlama's own confidence in the quote (0…1). Below ~0.5 the price is thin.
        public let confidence: Double
    }

    /// Shared request loop for both endpoints. Chunks so a big wallet's key list can't
    /// build an over-length URL the server rejects (seen as NSURLError -1011), and wraps
    /// each chunk so one bad batch is skipped rather than failing the whole fetch.
    private func batched<V>(_ keys: [String], path: String,
                            decode: @Sendable (Data) throws -> [String: V]) async throws -> [String: V] {
        guard !keys.isEmpty else { return [:] }
        var result: [String: V] = [:]
        for batch in keys.chunked(into: 50) {
            let joined = batch.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
                              .joined(separator: ",")
            guard let url = URL(string: "https://coins.llama.fi/\(path)/\(joined)"),
                  let data = try? await fetcher.freshData(from: url, headers: [:]),
                  let map = try? decode(data)
            else { continue }
            for (key, value) in map { result[key] = value }
        }
        return result
    }

    // MARK: - Key helpers

    /// Builds the DefiLlama price key for an ERC-20 contract address.
    /// Format: `{llamaChainName}:{contractAddress}`.
    ///
    /// Example: llamaKey(chain: .ethereum, contract: "0xCA") → "ethereum:0xCA"
    public static func llamaKey(chain: Chain, contract: String) -> String {
        "\(llamaChainName(chain)):\(contract)"
    }

    /// DefiLlama's key for a chain the app scans — also how a discovered network is
    /// matched back to a scanned `Chain`.
    public static func llamaChainKey(_ chain: Chain) -> String { llamaChainName(chain) }

    private static func llamaChainName(_ chain: Chain) -> String {
        switch chain {
        case .ethereum: return "ethereum"
        case .arbitrum: return "arbitrum"
        case .base:     return "base"
        }
    }
}

// MARK: - Decodable shapes

private struct PriceResponse: Decodable {
    let coins: [String: CoinPrice]

    struct CoinPrice: Decodable {
        let price: Decimal
        let symbol: String?
        let decimals: Int?
        let confidence: Double?
    }
}

private struct ChangeResponse: Decodable {
    let coins: [String: Double]
}
