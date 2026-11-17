import XCTest
@testable import BookkeeperCore

private struct StubFetcher: DataFetcher {
    let response: @Sendable (URL) throws -> Data
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        try response(url)
    }
}

final class CoinGeckoPriceServiceTests: XCTestCase {

    func test_pricesByContract_mappedBackToOriginalKey() async throws {
        // CG lowercases contract keys and nests usd; we pass a mixed-case key.
        let stub = StubFetcher { url in
            XCTAssertTrue(url.absoluteString.contains("token_price/ethereum"))
            XCTAssertTrue(url.absoluteString.contains("0xDE30"))   // contract forwarded
            return Data(#"{"0xde30da39c46104798bb5aa3fe8b9e0e1f348163f":{"usd":0.069358}}"#.utf8)
        }
        let svc = CoinGeckoPriceService(fetcher: stub)
        let key = "ethereum:0xDE30DA39c46104798bb5AA3FE8B9E0e1f348163F"
        let prices = try await svc.prices(forKeys: [key])
        XCTAssertEqual(prices[key], Decimal(string: "0.069358"), "GTC priced, keyed by the original mixed-case key")
    }

    func test_arbitrumPrefixMapsToArbitrumOnePlatform() async throws {
        let stub = StubFetcher { url in
            XCTAssertTrue(url.absoluteString.contains("token_price/arbitrum-one"),
                          "arbitrum prefix must hit the arbitrum-one platform")
            return Data(#"{"0xabc":{"usd":2.5}}"#.utf8)
        }
        let svc = CoinGeckoPriceService(fetcher: stub)
        let prices = try await svc.prices(forKeys: ["arbitrum:0xABC"])
        XCTAssertEqual(prices["arbitrum:0xABC"], Decimal(string: "2.5"))
    }

    /// The two price sources disagree on the chain's name: DefiLlama keys it
    /// `hyperliquid`, CoinGecko's asset platform is `hyperevm`. Unpaired, the CoinGecko
    /// fallback silently drops every HyperEVM contract instead of pricing it.
    func test_hyperliquidPrefixMapsToTheHyperevmPlatform() async throws {
        let stub = StubFetcher { url in
            XCTAssertTrue(url.absoluteString.contains("token_price/hyperevm"),
                          "hyperliquid prefix must hit the hyperevm platform")
            return Data(#"{"0xb88339cb7199b77e23db6e890353e22632ba630f":{"usd":0.9998}}"#.utf8)
        }
        let svc = CoinGeckoPriceService(fetcher: stub)
        let key = "hyperliquid:0xb88339cb7199b77e23db6e890353e22632ba630f"
        let prices = try await svc.prices(forKeys: [key])
        XCTAssertEqual(prices[key], Decimal(string: "0.9998"))
    }

    func test_coingeckoIdKey_usesSimplePrice() async throws {
        let stub = StubFetcher { url in
            XCTAssertTrue(url.absoluteString.contains("simple/price"))
            XCTAssertTrue(url.absoluteString.contains("ids=ethereum"))
            return Data(#"{"ethereum":{"usd":2400.5}}"#.utf8)
        }
        let svc = CoinGeckoPriceService(fetcher: stub)
        let prices = try await svc.prices(forKeys: ["coingecko:ethereum"])
        XCTAssertEqual(prices["coingecko:ethereum"], Decimal(string: "2400.5"))
    }

    func test_missingContractOmitted() async throws {
        let stub = StubFetcher { _ in Data(#"{}"#.utf8) }   // CG knows nothing
        let svc = CoinGeckoPriceService(fetcher: stub)
        let prices = try await svc.prices(forKeys: ["base:0xUNKNOWN"])
        XCTAssertNil(prices["base:0xUNKNOWN"])
    }

    func test_emptyKeys_noRequest() async throws {
        let stub = StubFetcher { _ in XCTFail("no request for empty keys"); return Data() }
        let svc = CoinGeckoPriceService(fetcher: stub)
        let out = try await svc.prices(forKeys: [])
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Composite

    func test_composite_primaryWins_fallbackFillsGaps() async throws {
        let primary = StubPriceService(["A": 1])               // prices only A
        let fallback = StubPriceService(["A": 99, "B": 2])     // would price both
        let svc = CompositePriceService(primary: primary, fallback: fallback)
        let out = try await svc.prices(forKeys: ["A", "B"])
        XCTAssertEqual(out["A"], 1, "primary wins for A")
        XCTAssertEqual(out["B"], 2, "fallback fills B")
    }

    func test_composite_primaryThrows_fallbackStillUsed() async throws {
        let svc = CompositePriceService(primary: ThrowingPriceService(),
                                        fallback: StubPriceService(["A": 7]))
        let out = try await svc.prices(forKeys: ["A"])
        XCTAssertEqual(out["A"], 7, "a primary failure degrades to the fallback")
    }
}

private struct StubPriceService: PriceService {
    let map: [String: Decimal]
    init(_ map: [String: Decimal]) { self.map = map }
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] {
        map.filter { keys.contains($0.key) }
    }
}

private struct ThrowingPriceService: PriceService {
    struct Boom: Error {}
    func prices(forKeys keys: [String]) async throws -> [String: Decimal] { throw Boom() }
}
