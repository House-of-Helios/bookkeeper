import XCTest
@testable import BookkeeperCore

private func tok(_ sym: String, _ kind: TokenKind, ca: String) -> Token {
    Token(symbol: sym, name: sym, decimals: 18, chain: .ethereum,
          contractAddress: ca, coingeckoId: nil, kind: kind, colorHex: "#FFFFFF")
}

final class AggregationTests: XCTestCase {
    func test_unpricedHoldingExcludedFromTotalAndPercent() {
        let eth = tok("ETH", .ethFamily, ca: "0x1")
        let mystery = tok("???", .other, ca: "0x2")
        let holdings = [
            Holding(walletId: "w1", token: eth, amount: 2),
            Holding(walletId: "w1", token: mystery, amount: 100),
        ]
        let prices: [String: PriceState] = [eth.id: .priced(usd: 1000), mystery.id: .unpriced]

        var priced = Aggregation.price(holdings, with: prices)
        XCTAssertEqual(Aggregation.total(priced), 2000)   // mystery excluded
        priced = Aggregation.withPercentages(priced)

        let ethRow = priced.first { $0.token.id == eth.id }!
        let mysteryRow = priced.first { $0.token.id == mystery.id }!
        XCTAssertEqual(ethRow.pct, 100)                   // 2000/2000
        XCTAssertNil(mysteryRow.usdValue)
        XCTAssertNil(mysteryRow.pct)                      // never faked
    }

    func test_collapseByTokenSumsAcrossWallets() {
        let eth = tok("ETH", .ethFamily, ca: "0x1")
        let holdings = [
            Holding(walletId: "w1", token: eth, amount: 1),
            Holding(walletId: "w2", token: eth, amount: 3),
        ]
        let priced = Aggregation.price(holdings, with: [eth.id: .priced(usd: 1000)])
        let collapsed = Aggregation.collapseByToken(priced)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].amount, 4)
        XCTAssertEqual(collapsed[0].usdValue, 4000)
    }

    func test_bucketSharesGroupByKind() {
        let eth = tok("ETH", .ethFamily, ca: "0x1")
        let usdc = tok("USDC", .stablecoin, ca: "0x2")
        let holdings = [
            Holding(walletId: "w1", token: eth, amount: 1),
            Holding(walletId: "w1", token: usdc, amount: 1000),
        ]
        var priced = Aggregation.price(holdings, with: [
            eth.id: .priced(usd: 3000), usdc.id: .priced(usd: 1),
        ])
        priced = Aggregation.withPercentages(priced)
        let buckets = Dictionary(uniqueKeysWithValues: Aggregation.bucketShares(priced))
        XCTAssertEqual(buckets[.ethFamily], 75)   // 3000/4000
        XCTAssertEqual(buckets[.stablecoin], 25)  // 1000/4000
    }

    func test_withPercentages_allUnpriced_returnsUnchangedWithNilPct() {
        let a = tok("AAA", .other, ca: "0x1")
        let priced = Aggregation.price([Holding(walletId: "w1", token: a, amount: 5)],
                                       with: [a.id: .unpriced])
        let result = Aggregation.withPercentages(priced)   // total == 0, guard fires
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].usdValue)
        XCTAssertNil(result[0].pct)
    }

    func test_price_tokenAbsentFromMap_defaultsToUnpriced() {
        let a = tok("AAA", .other, ca: "0x1")
        let priced = Aggregation.price([Holding(walletId: "w1", token: a, amount: 5)],
                                       with: [:])   // empty price map
        XCTAssertEqual(priced[0].price, .unpriced)
        XCTAssertNil(priced[0].usdValue)
    }

    func test_collapseByToken_unpricedStaysNilAndNoPctStamped() {
        let a = tok("AAA", .other, ca: "0x1")
        let holdings = [
            Holding(walletId: "w1", token: a, amount: 2),
            Holding(walletId: "w2", token: a, amount: 3),
        ]
        let priced = Aggregation.price(holdings, with: [a.id: .unpriced])
        let collapsed = Aggregation.collapseByToken(priced)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].amount, 5)
        XCTAssertNil(collapsed[0].usdValue)
        XCTAssertNil(collapsed[0].pct)   // collapse no longer stamps percentages
    }
}
