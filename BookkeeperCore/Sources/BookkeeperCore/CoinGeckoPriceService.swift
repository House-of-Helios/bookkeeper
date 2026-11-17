import Foundation

/// Prices tokens through CoinGecko — a far broader index than DefiLlama, so it
/// prices long-tail real tokens (e.g. GTC) that DefiLlama leaves unpriced. Keyless
/// public API; rate-limited but our refresh makes only a few batched calls.
///
/// Accepts the SAME keys the rest of the app already builds, so it drops in beside
/// `DefiLlamaPriceService`:
///   - `"<chain>:<contract>"`  → CoinGecko `simple/token_price/{platform}` by contract
///   - `"coingecko:<id>"`      → CoinGecko `simple/price` by coin id
/// Verified live response shape: `{ "<contract|id>": { "usd": <number> } }`,
/// contracts/ids with no price simply omitted.
public struct CoinGeckoPriceService: PriceService {
    private let fetcher: DataFetcher
    private let auth: CoinGeckoAuth

    public init(fetcher: DataFetcher = URLSessionFetcher(), auth: CoinGeckoAuth = CoinGeckoAuth()) {
        self.fetcher = fetcher
        self.auth = auth
    }

    /// DefiLlama chain name (the key prefix) → CoinGecko asset-platform id.
    private static func platform(forChainPrefix prefix: String) -> String? {
        switch prefix {
        case "ethereum": return "ethereum"
        case "arbitrum": return "arbitrum-one"
        case "base":     return "base"
        case "hyperliquid": return "hyperevm"   // DefiLlama's name for CoinGecko's `hyperevm`
        default:         return nil
        }
    }

    public func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        guard !keys.isEmpty else { return [:] }

        // Bucket keys by CoinGecko platform (for contracts) and collect coin ids.
        var contractsByPlatform: [String: [String]] = [:]          // platform → [contract]
        var keyForContract: [String: String] = [:]                 // "platform|contractLower" → original key
        var ids: [String] = []
        var keyForID: [String: String] = [:]                       // id → original key

        for key in keys {
            if key.hasPrefix("coingecko:") {
                let id = String(key.dropFirst("coingecko:".count))
                guard !id.isEmpty else { continue }
                ids.append(id); keyForID[id] = key
            } else if let colon = key.firstIndex(of: ":") {
                let prefix = String(key[..<colon])
                let contract = String(key[key.index(after: colon)...])
                guard let platform = Self.platform(forChainPrefix: prefix), !contract.isEmpty else { continue }
                contractsByPlatform[platform, default: []].append(contract)
                keyForContract["\(platform)|\(contract.lowercased())"] = key
            }
        }

        var result: [String: Decimal] = [:]

        // Chunk contracts per platform so no single URL is oversized (a big wallet
        // can hold 100s of tokens). A failed chunk is skipped, never aborts the rest.
        for (platform, contracts) in contractsByPlatform {
            for batch in contracts.chunked(into: 40) {
                let joined = batch.joined(separator: ",")
                guard let url = URL(string:
                    "https://api.coingecko.com/api/v3/simple/token_price/\(platform)"
                    + "?contract_addresses=\(joined)&vs_currencies=usd"),
                    let map = try? await fetchUSD(url) else { continue }
                for (contractLower, usd) in map {
                    if let key = keyForContract["\(platform)|\(contractLower.lowercased())"] {
                        result[key] = usd
                    }
                }
            }
        }

        // Coin ids, also chunked.
        for batch in ids.chunked(into: 100) {
            let joined = batch.joined(separator: ",")
            guard let url = URL(string:
                "https://api.coingecko.com/api/v3/simple/price?ids=\(joined)&vs_currencies=usd"),
                let map = try? await fetchUSD(url) else { continue }
            for (id, usd) in map {
                if let key = keyForID[id] { result[key] = usd }
            }
        }

        return result
    }

    /// 24h price change (percent) per key — same bucketing as `prices`, parsing
    /// `usd_24h_change`. Used for the DeBank-style per-token + portfolio 24h deltas.
    public func changes24h(forKeys keys: [String]) async throws -> [String: Double] {
        guard !keys.isEmpty else { return [:] }
        var contractsByPlatform: [String: [String]] = [:]
        var keyForContract: [String: String] = [:]
        var ids: [String] = []
        var keyForID: [String: String] = [:]
        for key in keys {
            if key.hasPrefix("coingecko:") {
                let id = String(key.dropFirst("coingecko:".count))
                guard !id.isEmpty else { continue }
                ids.append(id); keyForID[id] = key
            } else if let colon = key.firstIndex(of: ":") {
                let prefix = String(key[..<colon])
                let contract = String(key[key.index(after: colon)...])
                guard let platform = Self.platform(forChainPrefix: prefix), !contract.isEmpty else { continue }
                contractsByPlatform[platform, default: []].append(contract)
                keyForContract["\(platform)|\(contract.lowercased())"] = key
            }
        }
        var result: [String: Double] = [:]
        for (platform, contracts) in contractsByPlatform {
            for batch in contracts.chunked(into: 40) {
                let joined = batch.joined(separator: ",")
                guard let url = URL(string:
                    "https://api.coingecko.com/api/v3/simple/token_price/\(platform)"
                    + "?contract_addresses=\(joined)&vs_currencies=usd&include_24hr_change=true"),
                    let map = try? await fetchChange(url) else { continue }
                for (cLower, ch) in map where keyForContract["\(platform)|\(cLower.lowercased())"] != nil {
                    result[keyForContract["\(platform)|\(cLower.lowercased())"]!] = ch
                }
            }
        }
        for batch in ids.chunked(into: 100) {
            let joined = batch.joined(separator: ",")
            guard let url = URL(string:
                "https://api.coingecko.com/api/v3/simple/price?ids=\(joined)&vs_currencies=usd&include_24hr_change=true"),
                let map = try? await fetchChange(url) else { continue }
            for (id, ch) in map { if let key = keyForID[id] { result[key] = ch } }
        }
        return result
    }

    /// Decode `{ "<k>": { "usd_24h_change": <number> } }` → `[k: change]`.
    private func fetchChange(_ url: URL) async throws -> [String: Double] {
        await CoinGeckoLimiter.shared.pace()
        let data = try await fetcher.freshData(from: url, headers: auth.headers)
        let resp = try JSONDecoder().decode([String: Entry].self, from: data)
        var out: [String: Double] = [:]
        for (k, e) in resp { if let c = e.usd_24h_change { out[k] = c } }
        return out
    }

    /// Decode `{ "<k>": { "usd": <number> } }` → `[k: usd]`, dropping entries with no usd.
    private func fetchUSD(_ url: URL) async throws -> [String: Decimal] {
        await CoinGeckoLimiter.shared.pace()
        let data = try await fetcher.freshData(from: url, headers: auth.headers)
        let resp = try JSONDecoder().decode([String: Entry].self, from: data)
        var out: [String: Decimal] = [:]
        for (k, e) in resp { if let usd = e.usd { out[k] = usd } }
        return out
    }

    private struct Entry: Decodable {
        let usd: Decimal?
        let usd_24h_change: Double?
    }
}

extension Array {
    /// Split into sub-arrays of at most `size` — used to keep price-request URLs
    /// under server length limits when a wallet holds many tokens.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

/// Tries `primary` first, then asks `fallback` for ONLY the keys still missing.
///
/// Order matters: DefiLlama leads because it is keyless and effectively unthrottled,
/// so a 200-token wallet prices in a handful of calls that can't 429. CoinGecko follows
/// with its broader index to catch the long-tail tokens DefiLlama has no market for —
/// and because it only ever sees the leftovers, that's one small call, not the hot path.
/// A throw from either source degrades to whatever the other returned (partial beats nothing).
public struct CompositePriceService: PriceService {
    private let primary: PriceService
    private let fallback: PriceService

    public init(primary: PriceService, fallback: PriceService) {
        self.primary = primary
        self.fallback = fallback
    }

    public func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        guard !keys.isEmpty else { return [:] }
        var out = (try? await primary.prices(forKeys: keys)) ?? [:]
        let missing = keys.filter { out[$0] == nil }
        if !missing.isEmpty, let fb = try? await fallback.prices(forKeys: missing) {
            for (k, v) in fb where out[k] == nil { out[k] = v }
        }
        return out
    }

    public func changes24h(forKeys keys: [String]) async throws -> [String: Double] {
        guard !keys.isEmpty else { return [:] }
        var out = (try? await primary.changes24h(forKeys: keys)) ?? [:]
        let missing = keys.filter { out[$0] == nil }
        if !missing.isEmpty, let fb = try? await fallback.changes24h(forKeys: missing) {
            for (k, v) in fb where out[k] == nil { out[k] = v }
        }
        return out
    }
}
