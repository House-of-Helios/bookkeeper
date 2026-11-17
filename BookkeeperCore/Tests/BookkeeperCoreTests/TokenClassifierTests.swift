import XCTest
@testable import BookkeeperCore

/// BY TYPE is a liquidity question — how much is ETH exposure, how much is dollars —
/// so a liquid staking token landing in "other" understates ETH badly.
final class TokenClassifierTests: XCTestCase {

    // MARK: - The case that prompted this

    /// A vendor prefix must not change what the token is.
    func test_prefixedRethIsStillEth() {
        XCTAssertEqual(TokenClassifier.kind(for: "rock.reth"), .ethFamily)
        XCTAssertEqual(TokenClassifier.kind(for: "rETH"), .ethFamily)
        XCTAssertEqual(TokenClassifier.kind(for: "RETH"), .ethFamily)
    }

    /// Stacked wrappers: Aave's receipt for Lido's wstETH is still ether exposure.
    func test_stackedWrappersAreStillEth() {
        XCTAssertEqual(TokenClassifier.kind(for: "aEthLidowstETH"), .ethFamily)
        XCTAssertEqual(TokenClassifier.kind(for: "wstETH"), .ethFamily)
    }

    // MARK: - Symbols verified live against DefiLlama

    func test_everyLiquidStakingTokenCountsAsEth() {
        for s in ["rETH", "stETH", "wstETH", "cbETH", "frxETH", "sfrxETH",
                  "ETHx", "swETH", "osETH", "ankrETH", "mETH", "LsETH"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .ethFamily, "\(s) tracks ether")
        }
    }

    func test_everyRestakingTokenCountsAsEth() {
        for s in ["weETH", "ezETH", "eETH", "pufETH", "rsETH", "amphrETH", "rswETH"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .ethFamily, "\(s) tracks ether")
        }
    }

    func test_plainEtherAndItsWrappers() {
        for s in ["ETH", "eth", "WETH"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .ethFamily)
        }
    }

    func test_dollarStablecoins() {
        for s in ["USDC", "USDT", "DAI", "FRAX", "LUSD", "GHO", "crvUSD",
                  "USDe", "USDS", "PYUSD", "BOLD", "USND", "TUSD", "DOLA", "MIM"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .stablecoin, "\(s) is a dollar")
        }
    }

    /// A yield-bearing wrapper accrues into its price — sDAI trades near $1.18 — so
    /// whether it costs a dollar can't be what decides this. What it redeems for is.
    func test_yieldBearingStableWrappersAreStillStable() {
        for s in ["sDAI", "sUSDe", "sFRAX", "aUSDC"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .stablecoin, "\(s) redeems for dollars")
        }
    }

    // MARK: - What must NOT be swept up

    func test_ordinaryTokensAreNotMiscounted() {
        for s in ["UNI", "GTC", "PEAR", "XMR", "SC", "ARB", "OP", "LINK", "AAVE"] {
            XCTAssertEqual(TokenClassifier.kind(for: s), .other, "\(s) is neither")
        }
    }

    /// A bare "ETH" suffix rule would drag in anything ending in those letters, which is
    /// why plain ether is matched exactly and only the named LSTs are matched by suffix.
    func test_aTickerMerelyEndingInEthIsNotEth() {
        XCTAssertEqual(TokenClassifier.kind(for: "SHIBETH"), .other)
        XCTAssertEqual(TokenClassifier.kind(for: "MYETH"), .other)
    }

    func test_normalizationStripsPunctuationAndCase() {
        XCTAssertEqual(TokenClassifier.normalize("rock.reth"), "ROCKRETH")
        XCTAssertEqual(TokenClassifier.normalize("sfrxETH"), "SFRXETH")
        XCTAssertEqual(TokenClassifier.normalize(""), "")
    }

    func test_anEmptyOrPunctuationOnlySymbolIsNotClassified() {
        XCTAssertEqual(TokenClassifier.kind(for: ""), .other)
        XCTAssertEqual(TokenClassifier.kind(for: "..."), .other)
    }
}
