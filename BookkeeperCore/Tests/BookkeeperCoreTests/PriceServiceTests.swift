import XCTest
@testable import BookkeeperCore

// MARK: - Stub

private struct PriceStubFetcher: DataFetcher {
    let response: @Sendable (URL) throws -> Data

    func data(from url: URL, headers: [String: String]) async throws -> Data {
        try response(url)
    }
}

// MARK: - Sample JSON

/// Two priced coins + one key (arbitrum:0xZZZ) absent from the response.
private let sampleLlamaResponse = """
{
    "coins": {
        "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48": {
            "decimals": 6,
            "symbol": "USDC",
            "price": 1.0,
            "timestamp": 1700000000,
            "confidence": 0.99
        },
        "coingecko:monero": {
            "decimals": 12,
            "symbol": "XMR",
            "price": 165.5,
            "timestamp": 1700000000,
            "confidence": 0.97
        }
    }
}
"""

// MARK: - Tests

final class PriceServiceTests: XCTestCase {

    // MARK: - llamaKey

    func test_llamaKey_ethereum() {
        XCTAssertEqual(
            DefiLlamaPriceService.llamaKey(chain: .ethereum, contract: "0xCA"),
            "ethereum:0xCA"
        )
    }

    func test_llamaKey_arbitrum() {
        XCTAssertEqual(
            DefiLlamaPriceService.llamaKey(chain: .arbitrum, contract: "0xBB"),
            "arbitrum:0xBB"
        )
    }

    func test_llamaKey_base() {
        XCTAssertEqual(
            DefiLlamaPriceService.llamaKey(chain: .base, contract: "0xCC"),
            "base:0xCC"
        )
    }

    // MARK: - Parsing

    func test_twoPricedCoins_parsedAsDecimal() async throws {
        let stub = PriceStubFetcher { _ in Data(sampleLlamaResponse.utf8) }
        let service = DefiLlamaPriceService(fetcher: stub)

        let keys = [
            "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "coingecko:monero",
            "arbitrum:0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ",   // absent
        ]
        let prices = try await service.prices(forKeys: keys)

        XCTAssertEqual(prices.count, 2, "only the 2 priced keys should appear in the result")

        let usdcKey = "ethereum:0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        XCTAssertEqual(prices[usdcKey], Decimal(string: "1.0"), "USDC price should be 1.0")

        let xmrKey = "coingecko:monero"
        XCTAssertEqual(prices[xmrKey], Decimal(string: "165.5"), "XMR price should be 165.5")
    }

    func test_absentKey_missingFromResult() async throws {
        let stub = PriceStubFetcher { _ in Data(sampleLlamaResponse.utf8) }
        let service = DefiLlamaPriceService(fetcher: stub)

        let prices = try await service.prices(forKeys: ["arbitrum:0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"])
        XCTAssertNil(prices["arbitrum:0xZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"],
                     "absent key must not appear in result — caller treats missing as unpriced")
    }

    func test_emptyKeys_returnsEmptyDictionary() async throws {
        let stub = PriceStubFetcher { _ in
            XCTFail("should not make a network request for empty key list")
            return Data()
        }
        let service = DefiLlamaPriceService(fetcher: stub)
        let prices = try await service.prices(forKeys: [])
        XCTAssertTrue(prices.isEmpty)
    }

    func test_priceIsDecimalNotDouble() async throws {
        // Confirm the parsed type is Decimal (compile-level; this validates type inference at runtime too)
        let stub = PriceStubFetcher { _ in Data(sampleLlamaResponse.utf8) }
        let service = DefiLlamaPriceService(fetcher: stub)
        let prices = try await service.prices(forKeys: ["coingecko:monero"])
        let price: Decimal? = prices["coingecko:monero"]
        XCTAssertNotNil(price, "price should be a Decimal, not nil")
        // 165.5 expressed as Decimal should equal Decimal(string:"165.5")
        XCTAssertEqual(price, Decimal(string: "165.5"))
    }
}
