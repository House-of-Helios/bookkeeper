import XCTest
@testable import BookkeeperCore

final class TokenTests: XCTestCase {
    func test_autoTokenIdentityIsContractAddressPlusChain() {
        let eth = Token(symbol: "ETH", name: "Ether", decimals: 18,
                        chain: .ethereum, contractAddress: "0xabc",
                        coingeckoId: nil, kind: .ethFamily, colorHex: "#6B7BE8")
        XCTAssertEqual(eth.id, "0xabc@ethereum")
    }

    func test_manualTokenIdentityIsCoingeckoId() {
        let xmr = Token(symbol: "XMR", name: "Monero", decimals: 12,
                        chain: nil, contractAddress: nil,
                        coingeckoId: "monero", kind: .other, colorHex: "#FF6600")
        XCTAssertEqual(xmr.id, "monero@manual")
    }
}

/// People paste balances from explorers and spreadsheets, separators and all.
final class AmountParsingTests: XCTestCase {

    func test_groupedAndPlainAreTheSameNumber() {
        XCTAssertEqual(Money.amount(from: "1,054,100"), Decimal(1054100))
        XCTAssertEqual(Money.amount(from: "1054100"), Decimal(1054100))
        XCTAssertEqual(Money.amount(from: "1,054,100"), Money.amount(from: "1054100"))
    }

    func test_keepsTheDecimalPointWhileStrippingGrouping() {
        XCTAssertEqual(Money.amount(from: "1,054.5"), Decimal(string: "1054.5"))
        XCTAssertEqual(Money.amount(from: "6.13"), Decimal(string: "6.13"))
        XCTAssertEqual(Money.amount(from: "0.000001"), Decimal(string: "0.000001"))
    }

    /// Spaces, underscores, apostrophes and a pasted currency symbol are all grouping
    /// noise people bring with a copied figure.
    func test_toleratesOtherWaysOfWritingTheSameNumber() {
        for text in ["1 000", "1_000", "1'000", "$1,000", " 1,000 "] {
            XCTAssertEqual(Money.amount(from: text), Decimal(1000), "\(text)")
        }
    }

    /// Partially reading a number is worse than refusing it: Decimal(string:) alone
    /// returns 12 for "12abc", which would silently store a fraction of the holding.
    func test_refusesAnythingThatIsNotPlainlyANumber() {
        for text in ["12abc", "abc", "", "   ", ".", "1.2.3", "--5", "1,0a0"] {
            XCTAssertNil(Money.amount(from: text), "\(text) should be refused")
        }
    }

    func test_readsASignedNumber() {
        XCTAssertEqual(Money.amount(from: "-1,500"), Decimal(-1500))
    }
}

/// Topping up is the common edit — you bought five more, you didn't recompute the total.
final class AmountExpressionTests: XCTestCase {

    func test_addsAndSubtracts() {
        XCTAssertEqual(Money.expression(from: "100+5"), Decimal(105))
        XCTAssertEqual(Money.expression(from: "100 + 5"), Decimal(105))
        XCTAssertEqual(Money.expression(from: "100-5"), Decimal(95))
        XCTAssertEqual(Money.expression(from: "100+5+2.5"), Decimal(string: "107.5"))
    }

    /// Grouping separators still work inside a sum.
    func test_worksWithGroupedNumbers() {
        XCTAssertEqual(Money.expression(from: "1,054,100+900"), Decimal(1055000))
        XCTAssertEqual(Money.expression(from: "1,000 + 1,000"), Decimal(2000))
    }

    func test_aPlainNumberIsStillJustANumber() {
        XCTAssertEqual(Money.expression(from: "6.13"), Decimal(string: "6.13"))
        XCTAssertEqual(Money.expression(from: "-5"), Decimal(-5))
    }

    /// A sign straight after an operator belongs to the number.
    func test_signAfterAnOperator() {
        XCTAssertEqual(Money.expression(from: "100+-5"), Decimal(95))
    }

    func test_refusesNonsense() {
        for text in ["100+", "+", "100++5", "100+abc", "", "   "] {
            XCTAssertNil(Money.expression(from: text), "\(text) should be refused")
        }
    }
}
