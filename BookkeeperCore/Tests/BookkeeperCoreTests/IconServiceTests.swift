import XCTest
@testable import BookkeeperCore

/// The icon layer is now a pure URL derivation — no network, no rate limit — so these
/// tests assert the exact URLs the CDN serves (verified live against the endpoint).
final class TokenIconTests: XCTestCase {

    func testChainIDsMatchTheCDNPathSegments() {
        XCTAssertEqual(TokenIcon.chainId(.ethereum), 1)
        XCTAssertEqual(TokenIcon.chainId(.arbitrum), 42161)
        XCTAssertEqual(TokenIcon.chainId(.base), 8453)
    }

    func testBuildsCDNURLForAnERC20() {
        let url = TokenIcon.url(chain: .ethereum,
                                contract: "0xC00e94Cb662C3520282E6f5717214004A7f26888")
        XCTAssertEqual(url?.absoluteString,
            "https://token-icons.llamao.fi/icons/tokens/1/0xc00e94cb662c3520282e6f5717214004a7f26888?h=64&w=64")
    }

    /// The CDN normalizes case, so a lowercased address is what we send — unlike Trust
    /// Wallet's repo, which 404s on anything but an EIP-55 checksummed address.
    func testLowercasesTheAddress() {
        let upper = TokenIcon.url(chain: .base, contract: "0x4ED4E862860BED51A9570B96D89AF5E1B0EFEFED")
        let lower = TokenIcon.url(chain: .base, contract: "0x4ed4e862860bed51a9570b96d89af5e1b0efefed")
        XCTAssertEqual(upper, lower)
    }

    /// A native coin carries the "native" sentinel instead of an address; the CDN
    /// addresses it as the zero address (verified: returns the ETH logo).
    func testNativeSentinelMapsToTheZeroAddress() {
        let url = TokenIcon.url(chain: .arbitrum, contract: "native")
        XCTAssertEqual(url?.absoluteString,
            "https://token-icons.llamao.fi/icons/tokens/42161/\(TokenIcon.nativeAddress)?h=64&w=64")
    }

    func testResolvesATokenWithAContract() {
        let token = Token(symbol: "UNI", name: "Uniswap", decimals: 18, chain: .ethereum,
                          contractAddress: "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
                          coingeckoId: nil, kind: .other, colorHex: "#E86B9F")
        XCTAssertEqual(TokenIcon.url(for: token)?.absoluteString,
            "https://token-icons.llamao.fi/icons/tokens/1/0x1f9840a85d5af5bf1d1762f925bdaddc4201f984?h=64&w=64")
    }

    /// A non-EVM coin has no contract to derive from — it falls through to the one
    /// remaining CoinGecko lookup rather than producing a bogus CDN URL.
    func testReturnsNilForANonEVMCoin() {
        let token = Token(symbol: "SC", name: "Siacoin", decimals: 0, chain: nil,
                          contractAddress: nil, coingeckoId: "siacoin",
                          kind: .other, colorHex: "#7FBF6B")
        XCTAssertNil(TokenIcon.url(for: token))
    }

    func testHonorsARequestedSize() {
        let url = TokenIcon.url(chain: .ethereum, contract: "native", size: 128)
        XCTAssertEqual(url?.query, "h=128&w=128")
    }
}
