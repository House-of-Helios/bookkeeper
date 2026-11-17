import Foundation

public struct PricePoint: Sendable, Equatable, Codable {
    public let date: Date
    public let price: Decimal
}

/// Per-token price history from DefiLlama's keyless `/chart` endpoint — the same
/// provider and the same `chain:contract` / `coingecko:id` keys `PortfolioStore`
/// already prices spot quotes with, so this adds no new key scheme and no
/// rate-limited provider. (The prior per-token history feature was cut for burning
/// CoinGecko's budget; this one reuses the source that "leads and has no meaningful
/// rate limit" for spot prices today.)
public struct HistoricalPriceService: Sendable {
    private let fetcher: DataFetcher

    public init(fetcher: DataFetcher = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    /// Price points over the trailing `days`, oldest first. Hourly for a day or two (a
    /// 24-hour chart needs more than two points), daily up to half a year; past that, weekly — an ALL-time (multi-year) range at daily points
    /// would be a huge payload for no visual gain at that zoom level. Verified live:
    /// `ethereum:0x0…0` returns 3 years of weekly points from one keyless call.
    public func history(for token: Token, days: Int) async throws -> [PricePoint] {
        let key = PortfolioStore.priceKey(for: token)
        let period: String, span: Int
        if days <= 2 { period = "1h"; span = days * 24 }
        else if days > 180 { period = "1w"; span = max(2, days / 7) }
        else { period = "1d"; span = max(2, days) }
        let start = Int(Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string:
                "https://coins.llama.fi/chart/\(encoded)?start=\(start)&span=\(span)&period=\(period)")
        else { return [] }
        let data = try await fetcher.freshData(from: url, headers: [:])
        let resp = try JSONDecoder().decode(ChartResponse.self, from: data)
        guard let coin = resp.coins[key] else { return [] }
        return coin.prices
            .map { PricePoint(date: Date(timeIntervalSince1970: $0.timestamp), price: $0.price) }
            .sorted { $0.date < $1.date }
    }
}

private struct ChartResponse: Decodable {
    let coins: [String: Coin]
    struct Coin: Decodable {
        let prices: [Point]
        struct Point: Decodable {
            let timestamp: Double
            let price: Decimal
        }
    }
}
