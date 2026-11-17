import Foundation

/// Token logos WITHOUT a lookup call.
///
/// The old path asked GeckoTerminal (then CoinGecko) for a JSON document just to read
/// an `image_url` out of it — two rate-limited requests per token, which forced a 2.5s
/// throttle between tokens and meant a 30-token wallet waited over a minute for its
/// logos. DefiLlama's icon CDN serves the image directly at a URL derived from the
/// chain id + contract address, so the URL is known without asking anyone: no request
/// budget, no throttle, no 429. A token the CDN doesn't have answers 404 and the row
/// falls back to its lettered disc.
public enum TokenIcon {

    /// EVM chain ids — the CDN's path segment.
    public static func chainId(_ chain: Chain) -> Int {
        switch chain {
        case .ethereum: return 1
        case .arbitrum: return 42161
        case .base:     return 8453
        }
    }

    /// The zero address is how the CDN addresses a chain's native coin (ETH).
    public static let nativeAddress = "0x0000000000000000000000000000000000000000"

    /// Direct image URL for an EVM token. Lowercase address is fine — the CDN
    /// normalizes, unlike Trust Wallet's repo which demands an EIP-55 checksum.
    public static func url(chain: Chain, contract: String, size: Int = 64) -> URL? {
        let addr = contract == "native" ? nativeAddress : contract.lowercased()
        return URL(string: "https://token-icons.llamao.fi/icons/tokens/\(chainId(chain))/\(addr)?h=\(size)&w=\(size)")
    }

    /// Direct image URL for a token, or nil for a manual/non-EVM coin (those resolve
    /// through `CoinGeckoIconService`, which is one call and only on a handful of coins).
    public static func url(for token: Token, size: Int = 64) -> URL? {
        guard let chain = token.chain, let ca = token.contractAddress else { return nil }
        return url(chain: chain, contract: ca, size: size)
    }
}

// MARK: - CoinGecko (manual / non-EVM coins only)

/// Resolves a CoinGecko coin id → logo URL. The ONLY remaining icon lookup, used for
/// hand-entered non-EVM coins (XMR, SC) that have no contract address for the CDN.
/// A wallet holds a couple of these at most, so it never threatens the rate limit.
public struct CoinGeckoIconService: Sendable {
    private let fetcher: DataFetcher
    private let auth: CoinGeckoAuth

    public init(fetcher: DataFetcher = URLSessionFetcher(), auth: CoinGeckoAuth = CoinGeckoAuth()) {
        self.fetcher = fetcher
        self.auth = auth
    }

    public func iconURL(coingeckoId: String) async -> URL? {
        let urlStr = "https://api.coingecko.com/api/v3/coins/\(coingeckoId)"
            + "?localization=false&tickers=false&market_data=false"
            + "&community_data=false&developer_data=false&sparkline=false"
        guard let url = URL(string: urlStr) else { return nil }
        await CoinGeckoLimiter.shared.pace()
        guard let data = try? await fetcher.data(from: url, headers: auth.headers),
              let resp = try? JSONDecoder().decode(CoinGeckoResponse.self, from: data)
        else { return nil }
        return resp.image?.large.flatMap { URL(string: $0) }
    }

    private struct CoinGeckoResponse: Decodable {
        let image: ImageURLs?
        struct ImageURLs: Decodable { let large: String? }
    }
}
