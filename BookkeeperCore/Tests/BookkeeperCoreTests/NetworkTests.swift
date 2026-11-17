import XCTest
@testable import BookkeeperCore

/// The ledger tabs every group by network. Before this, `Chain?` was the key, so the
/// three modelled chains each got a tab and every other network shared one untabbed
/// group — Monero filed next to HyperEVM under "Manual".
final class NetworkTests: XCTestCase {

    private func token(chain: Chain? = nil, manualNetwork: String? = nil,
                       symbol: String = "X") -> Token {
        Token(symbol: symbol, name: symbol, decimals: 18, chain: chain,
              contractAddress: chain == nil ? nil : "0xabc", coingeckoId: nil,
              kind: .other, colorHex: "#000", manualNetwork: manualNetwork)
    }

    func test_aModelledChainKeepsItsNameAndCase() {
        let n = Network.of(token(chain: .ethereum))
        XCTAssertEqual(n.name, "Ethereum")
        XCTAssertEqual(n.chain, .ethereum)
        XCTAssertEqual(n.badge, "E")
    }

    /// The whole point: two networks that both answer `nil` for `chain` must not collapse
    /// into one group.
    func test_hyperEVMAndMoneroAreDifferentNetworks() {
        let hype = Network.of(token(manualNetwork: "HyperEVM", symbol: "HYPE"))
        let xmr  = Network.of(token(manualNetwork: "Monero", symbol: "XMR"))
        XCTAssertNotEqual(hype, xmr, "two nil-chain networks are still two networks")
        XCTAssertEqual(hype.name, "HyperEVM")
        XCTAssertEqual(xmr.name, "Monero")
        XCTAssertEqual(hype.badge, "H")
        XCTAssertEqual(xmr.badge, "M")
    }

    /// Both of them get a real colour, not the nameless neutral.
    func test_hyperEVMAndMoneroEachHaveTheirOwnColour() {
        let hype = Network.of(token(manualNetwork: "HyperEVM"))
        let xmr  = Network.of(token(manualNetwork: "Monero"))
        XCTAssertEqual(hype.colorHex, "#6BD6BF")
        XCTAssertEqual(xmr.colorHex, "#F05E1C")
        XCTAssertNotEqual(hype.colorHex, Network.neutral)
        XCTAssertNotEqual(xmr.colorHex, Network.neutral)
    }

    /// Monero must not reuse the By-Type ring's "Tokens" orange — one colour meaning two
    /// things on one screen is the bug this avoids.
    func test_moneroDoesNotReuseTheTokensBucketOrange() {
        XCTAssertNotEqual(Network.of(token(manualNetwork: "Monero")).colorHex, "#FF6600")
    }

    /// The three that already had colours keep exactly the ones they had, so adding the
    /// table recolours nothing that was already on screen.
    func test_theThreeModelledChainsKeepTheirExistingColours() {
        XCTAssertEqual(Network.of(token(chain: .ethereum)).colorHex, "#7B83A8")
        XCTAssertEqual(Network.of(token(chain: .arbitrum)).colorHex, "#5BA4E8")
        XCTAssertEqual(Network.of(token(chain: .base)).colorHex, "#2A6BF0")
    }

    /// Every network a pasted address can resolve to is named, so none of them draws a
    /// nameless block. This is the check that keeps the two tables in step.
    func test_everyNetworkTheLocatorProbesHasAColour() {
        for entry in TokenLocator.chains {
            XCTAssertNotNil(Network.brand[entry.name],
                            "\(entry.name) is probed for pasted addresses but has no colour")
        }
    }

    /// A coin whose network was never learned is the only real "Manual".
    func test_aTokenWithNoNetworkAtAllFallsBackToManual() {
        let n = Network.of(token())
        XCTAssertEqual(n, .unknown)
        XCTAssertEqual(n.name, "Manual")
        XCTAssertEqual(n.colorHex, Network.neutral)
    }
}

/// A coin can be deployed on dozens of chains, so the picker shows a few and folds the
/// rest behind "show all".
final class NetworkPickerCollapseTests: XCTestCase {

    private let many = ["Ethereum", "HyperEVM", "Base", "Arbitrum", "Optimism",
                        "Polygon", "Avalanche", "Algorand", "Stellar", "Sui"]

    func test_collapsedShowsTheLeadingFew() {
        let shown = Network.collapsedChoices(from: many, selected: "Ethereum")
        XCTAssertEqual(shown, ["Ethereum", "HyperEVM", "Base", "Arbitrum"])
    }

    /// The subtlety: collapsing must never hide the answer the user just gave.
    func test_aSelectionPastTheCutIsStillShown() {
        let shown = Network.collapsedChoices(from: many, selected: "Stellar")
        XCTAssertTrue(shown.contains("Stellar"), "the picked network cannot vanish")
        XCTAssertEqual(shown.first, "Ethereum", "and the leading few do not reshuffle")
        XCTAssertEqual(shown.count, Network.choiceLimit + 1)
    }

    /// Hiding one item behind a "show all" costs more than it saves. Sized off the
    /// constant, so tuning the limit cannot silently invalidate this case.
    func test_aListBarelyOverTheLimitIsShownWhole() {
        let justOver = Array(many.prefix(Network.choiceLimit + 1))
        XCTAssertEqual(Network.collapsedChoices(from: justOver, selected: "Ethereum"), justOver)
    }

    func test_aShortListIsUntouched() {
        let three = ["Ethereum", "Arbitrum", "Base"]
        XCTAssertEqual(Network.collapsedChoices(from: three, selected: "Base"), three)
    }
}

/// The Portfolio table and the Wallets modules must name a holding's network the same
/// way. They took different paths — the wallet listed rows as held, the portfolio
/// collapsed them by symbol and then asked the merged row which network it was on — so
/// the portfolio's answer was whichever row the merge happened to see first.
final class PortfolioNetworkAgreementTests: XCTestCase {

    private func store(_ holdings: [Holding], _ prices: [String: PriceState]) -> PortfolioStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-net-\(UUID().uuidString)")
        return PortfolioStore(wallets: [Wallet(id: "w1", nickname: "w1")],
                              holdings: holdings, prices: prices,
                              secret: SecretStore(directory: dir),
                              history: HistoryStore(directory: dir))
    }

    private func usdc(network: String?, chain: Chain?, ca: String) -> Token {
        Token(symbol: "USDC", name: "USD Coin", decimals: 6, chain: chain,
              contractAddress: ca, coingeckoId: nil, kind: .stablecoin, colorHex: "#000",
              manualNetwork: network)
    }

    /// The reported bug: USDC held only on HyperEVM was filed under Ethereum, a network
    /// no wallet holds it on.
    func test_aTokenHeldOnOneNetworkIsNamedThatNetwork() {
        let hyper = usdc(network: "HyperEVM", chain: nil, ca: "0xb88")
        let eth = Token(symbol: "ETH", name: "Ether", decimals: 18, chain: .ethereum,
                        contractAddress: "native", coingeckoId: nil, kind: .ethFamily, colorHex: "#000")
        let s = store([Holding(walletId: "w1", token: eth, amount: 1),
                       Holding(walletId: "w1", token: hyper, amount: 1500)],
                      [eth.id: .priced(usd: 1581), hyper.id: .priced(usd: 1)])

        let row = s.dashboardRows.first { $0.token.symbol == "USDC" }
        XCTAssertNotNil(row)
        XCTAssertEqual(Network.of(row!.token).name, "HyperEVM",
                       "USDC is only held on HyperEVM — no wallet has it on Ethereum")
    }

    /// The same symbol on two networks is two holdings, and the portfolio says so rather
    /// than merging them under whichever it saw first.
    func test_theSameSymbolOnTwoNetworksStaysTwoRows() {
        let onEth = usdc(network: nil, chain: .ethereum, ca: "0xa0b")
        let onHyper = usdc(network: "HyperEVM", chain: nil, ca: "0xb88")
        let s = store([Holding(walletId: "w1", token: onEth, amount: 5200),
                       Holding(walletId: "w1", token: onHyper, amount: 1500)],
                      [onEth.id: .priced(usd: 1), onHyper.id: .priced(usd: 1)])

        let rows = s.dashboardRows.filter { $0.token.symbol == "USDC" }
        XCTAssertEqual(rows.count, 2, "one USDC row per network")
        XCTAssertEqual(Set(rows.map { Network.of($0.token).name }), ["Ethereum", "HyperEVM"])
        XCTAssertEqual(rows.first { Network.of($0.token).name == "HyperEVM" }?.amount, 1500)
    }

    /// Still merged where merging is right: the same asset on the SAME network, held in
    /// two different wallets, is one line on a portfolio-wide view.
    func test_theSameSymbolOnOneNetworkAcrossWalletsStillMerges() {
        let t = usdc(network: "HyperEVM", chain: nil, ca: "0xb88")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bk-net-\(UUID().uuidString)")
        let s = PortfolioStore(wallets: [Wallet(id: "w1", nickname: "w1"),
                                         Wallet(id: "w2", nickname: "w2")],
                               holdings: [Holding(walletId: "w1", token: t, amount: 100),
                                          Holding(walletId: "w2", token: t, amount: 40)],
                               prices: [t.id: .priced(usd: 1)],
                               secret: SecretStore(directory: dir),
                               history: HistoryStore(directory: dir))

        let rows = s.dashboardRows.filter { $0.token.symbol == "USDC" }
        XCTAssertEqual(rows.count, 1, "one network, one row")
        XCTAssertEqual(rows.first?.amount, 140, "both wallets' coins counted")
    }

    /// The invariant the bug broke: the portfolio is the wallets, added up. Every
    /// symbol-on-network the wallets hold appears once on the portfolio, carrying exactly
    /// the coins the wallets hold there — nothing renamed, nothing absorbed into a
    /// neighbour. Checking only that the *name* exists was too weak: HyperEVM USDC
    /// absorbed into an Ethereum USDC row still leaves "USDC@Ethereum" a name a wallet
    /// holds, so the amounts have to be checked too.
    func test_thePortfolioIsTheWalletsAddedUp() {
        let s = PortfolioStore.mock()
        var held: [String: Decimal] = [:]
        for w in s.wallets {
            for r in s.rows(forWallet: w.id) {
                held["\(r.token.symbol.uppercased())@\(Network.of(r.token).name)", default: 0] += r.amount
            }
        }
        var shown: [String: Decimal] = [:]
        for r in s.dashboardRows {
            shown["\(r.token.symbol.uppercased())@\(Network.of(r.token).name)", default: 0] += r.amount
        }
        XCTAssertEqual(shown, held, "the portfolio must hold exactly what the wallets do")
    }
}
