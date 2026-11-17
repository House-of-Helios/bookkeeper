import XCTest
@testable import BookkeeperCore

/// The fetcher answers whatever URL it is given, so a test can assert BOTH what came
/// back and that only one request was needed to search every chain.
private final class RecordingFetcher: DataFetcher, @unchecked Sendable {
    let body: String
    private(set) var urls: [URL] = []
    init(body: String) { self.body = body }
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        urls.append(url)
        return Data(body.utf8)
    }
}

private struct StubSearchService: CoinSearchService {
    let ids: [String: String]
    func coinId(forSymbol symbol: String) async -> String? { ids[symbol.lowercased()] }
}

/// Every request fails, the way they do while Tor is still connecting.
private struct DeadFetcher: DataFetcher {
    func data(from url: URL, headers: [String: String]) async throws -> Data { throw URLError(.cannotConnectToHost) }
}

/// Finds the coin, but can't say where it lives — the register timed out.
private struct NoDeploymentsSearch: CoinSearchService {
    func coinId(forSymbol symbol: String) async -> String? { "usd-coin" }
    func deployments(forCoin id: String) async -> CoinDeployments? { nil }
    var answersDeployments: Bool { true }
}

/// The register can't be asked at all.
private struct DeadSearch: CoinSearchService {
    func coinId(forSymbol symbol: String) async -> String? { nil }
    func search(forSymbol symbol: String) async -> SearchHit { .unreachable }
}

/// The user supplies a token; the app supplies the network. These cover the two inputs
/// that must work — a contract address whose chain is unknown, and a coin that is its
/// own chain and has no contract at all.
final class TokenLocatorTests: XCTestCase {

    private let degen = "0x4ed4e862860bed51a9570b96d89af5e1b0efefed"

    // MARK: - Input classification

    func test_recognisesAContractAddress() {
        XCTAssertTrue(TokenLocator.looksLikeContract(degen))
        XCTAssertTrue(TokenLocator.looksLikeContract("  " + degen.uppercased() + "  "))
    }

    func test_treatsAnythingElseAsAName() {
        for text in ["Monero", "XMR", "siacoin", "0x123", ""] {
            XCTAssertFalse(TokenLocator.looksLikeContract(text), "\(text) is not an address")
        }
    }

    // MARK: - A failure to ask is not "no such coin"

    func test_aSearchThatCannotBeAskedIsUnreachableNotNotFound() async {
        let outcome = await TokenLocator(fetcher: DeadFetcher(), search: DeadSearch()).lookup("AAVE")
        XCTAssertEqual(outcome, .unreachable)
    }

    func test_aPriceThatCannotBeFetchedIsUnreachable() async {
        let outcome = await TokenLocator(fetcher: DeadFetcher(), search: StubSearchService(ids: ["aave": "aave"]))
            .lookup("AAVE")
        XCTAssertEqual(outcome, .unreachable)
        let contract = await TokenLocator(fetcher: DeadFetcher(), search: StubSearchService(ids: [:])).lookup(degen)
        XCTAssertEqual(contract, .unreachable)
    }

    func test_anAnswerWithNoMatchIsNotFound() async {
        let outcome = await TokenLocator(fetcher: RecordingFetcher(body: #"{"coins":{}}"#),
                                         search: StubSearchService(ids: [:])).lookup("NOSUCHCOIN")
        XCTAssertEqual(outcome, .notFound)
        let searchSays = await CoinGeckoSearchService(fetcher: RecordingFetcher(body: #"{"coins":[]}"#))
            .search(forSymbol: "NOSUCHCOIN")
        XCTAssertEqual(searchSays, .none)
    }

    func test_aCoinWhoseNetworksCouldNotBeAskedIsNotFiledUnderItsOwnName() async {
        let price = #"{"coins":{"coingecko:usd-coin":{"price":1.0,"symbol":"USDC","confidence":0.99}}}"#
        let outcome = await TokenLocator(fetcher: RecordingFetcher(body: price), search: NoDeploymentsSearch()).lookup("USDC")
        XCTAssertEqual(outcome, .unreachable, "never a network called 'Usd Coin'")
    }

    // MARK: - A pasted address finds its own network

    /// The whole point: the user doesn't say which chain. Every chain is searched in ONE
    /// request and the one that answers is the answer.
    func test_discoversTheNetworkAContractLivesOn() async {
        let json = """
        {"coins":{"base:\(degen)":
        {"decimals":18,"symbol":"DEGEN","price":0.00103,"timestamp":1789262540,"confidence":0.99}}}
        """
        let fetcher = RecordingFetcher(body: json)
        let found = await TokenLocator(fetcher: fetcher, search: StubSearchService(ids: [:])).find(degen)

        XCTAssertEqual(found?.symbol, "DEGEN")
        XCTAssertEqual(found?.network, "base")
        XCTAssertEqual(found?.networkName, "Base")
        XCTAssertEqual(found?.contract, degen)
        XCTAssertEqual(found?.decimals, 18)
        XCTAssertTrue(found?.isOnChain == true)
        XCTAssertEqual(fetcher.urls.count, 1, "every chain is probed in a single request")
    }

    /// Searching fifteen chains must not cost fifteen calls.
    func test_probesEveryChainInOneRequest() async {
        let fetcher = RecordingFetcher(body: #"{"coins":{}}"#)
        _ = await TokenLocator(fetcher: fetcher, search: StubSearchService(ids: [:])).find(degen)
        let url = fetcher.urls.first?.absoluteString ?? ""
        for chain in TokenLocator.chains {
            XCTAssertTrue(url.contains("\(chain.key):\(degen)"), "\(chain.key) was searched")
        }
    }

    /// The same address deployed on several chains resolves to the most confident quote.
    func test_picksTheMostConfidentChainWhenAddressExistsOnSeveral() async {
        let json = """
        {"coins":{
          "ethereum:\(degen)":{"decimals":18,"symbol":"X","price":1.0,"confidence":0.4},
          "polygon:\(degen)":{"decimals":18,"symbol":"X","price":1.0,"confidence":0.99}
        }}
        """
        let found = await TokenLocator(fetcher: RecordingFetcher(body: json),
                                       search: StubSearchService(ids: [:])).find(degen)
        XCTAssertEqual(found?.network, "polygon")
        XCTAssertEqual(found?.networkName, "Polygon")
    }

    func test_returnsNothingWhenNoChainHasIt() async {
        let found = await TokenLocator(fetcher: RecordingFetcher(body: #"{"coins":{}}"#),
                                       search: StubSearchService(ids: [:])).find(degen)
        XCTAssertNil(found)
    }

    /// Chains beyond the three the app scans balances on are searchable — a token held
    /// on Polygon is perfectly trackable by hand.
    func test_searchesChainsTheAppDoesNotScan() {
        let keys = TokenLocator.chains.map(\.key)
        for unscanned in ["polygon", "optimism", "bsc", "avax"] {
            XCTAssertTrue(keys.contains(unscanned), "\(unscanned) is searchable")
        }
    }

    // MARK: - A coin that is its own network

    /// Monero has no contract and belongs to no EVM chain, so no picker could express
    /// it. Typing its name has to work, and the network it reports is itself.
    func test_findsMoneroByName() async {
        let json = """
        {"coins":{"coingecko:monero":{"symbol":"XMR","price":541.12,"confidence":0.99}}}
        """
        let found = await TokenLocator(fetcher: RecordingFetcher(body: json),
                                       search: StubSearchService(ids: ["monero": "monero"])).find("Monero")

        XCTAssertEqual(found?.symbol, "XMR")
        XCTAssertEqual(found?.coingeckoId, "monero")
        XCTAssertEqual(found?.networkName, "Monero")
        XCTAssertNil(found?.network, "not an EVM chain")
        XCTAssertNil(found?.contract, "no contract exists to store")
        XCTAssertFalse(found?.isOnChain == true)
    }

    func test_namesAMultiWordCoinsNetworkProperly() {
        XCTAssertEqual(TokenLocator.prettyNetwork(fromCoinId: "siacoin"), "Siacoin")
        XCTAssertEqual(TokenLocator.prettyNetwork(fromCoinId: "bitcoin-cash"), "Bitcoin Cash")
    }

    func test_returnsNothingForANameThatResolvesToNoCoin() async {
        let found = await TokenLocator(fetcher: RecordingFetcher(body: #"{"coins":{}}"#),
                                       search: StubSearchService(ids: [:])).find("not a coin")
        XCTAssertNil(found)
    }

    func test_ignoresEmptyInput() async {
        let found = await TokenLocator(fetcher: RecordingFetcher(body: #"{"coins":{}}"#),
                                       search: StubSearchService(ids: [:])).find("   ")
        XCTAssertNil(found)
    }
}

/// A contract address names its own chain. A native coin does not — ETH is ETH on three
/// networks, and only the holder knows which one they're on.
final class NetworkChoiceTests: XCTestCase {

    private final class StubFetcher2: DataFetcher, @unchecked Sendable {
        let body: String
        init(_ b: String) { body = b }
        func data(from url: URL, headers: [String: String]) async throws -> Data { Data(body.utf8) }
    }
    private struct Search: CoinSearchService {
        let ids: [String: String]
        func coinId(forSymbol symbol: String) async -> String? { ids[symbol.lowercased()] }
    }

    func test_ethOffersItsThreeNetworks() async {
        let json = #"{"coins":{"coingecko:ethereum":{"symbol":"ETH","price":2523.04,"confidence":0.99}}}"#
        let found = await TokenLocator(fetcher: StubFetcher2(json),
                                       search: Search(ids: ["eth": "ethereum"])).find("ETH")

        XCTAssertTrue(found?.needsNetworkChoice == true)
        XCTAssertEqual(found?.availableNetworks, ["Ethereum", "Arbitrum", "Base"])
        XCTAssertEqual(found?.networkName, "Ethereum", "defaults to the first, the form can change it")
    }

    /// A coin that is its own chain has nothing to choose.
    func test_moneroOffersNoChoice() async {
        let json = #"{"coins":{"coingecko:monero":{"symbol":"XMR","price":541.12,"confidence":0.99}}}"#
        let found = await TokenLocator(fetcher: StubFetcher2(json),
                                       search: Search(ids: ["monero": "monero"])).find("Monero")

        XCTAssertFalse(found?.needsNetworkChoice == true)
        XCTAssertTrue(found?.availableNetworks.isEmpty == true)
        XCTAssertEqual(found?.networkName, "Monero")
    }

    /// An address is only ever on one chain, so it is never asked about.
    func test_aContractIsNeverAsked() async {
        let addr = "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
        let json = "{\"coins\":{\"ethereum:\(addr)\":{\"decimals\":18,\"symbol\":\"UNI\",\"price\":6.38,\"confidence\":0.99}}}"
        let found = await TokenLocator(fetcher: StubFetcher2(json), search: Search(ids: [:])).find(addr)

        XCTAssertFalse(found?.needsNetworkChoice == true)
        XCTAssertEqual(found?.networkName, "Ethereum")
    }

    /// The same coin on two networks is two holdings, not one — their identities differ.
    func test_sameCoinOnTwoNetworksAreDistinctHoldings() {
        func eth(on network: String) -> Token {
            Token(symbol: "ETH", name: "ETH", decimals: 0, chain: nil, contractAddress: nil,
                  coingeckoId: "ethereum", kind: .ethFamily, colorHex: "#6B7BE8",
                  manualNetwork: network)
        }
        XCTAssertNotEqual(eth(on: "Base").id, eth(on: "Arbitrum").id,
                          "otherwise the two collapse into one row and double-count")
    }
}

/// A contract cannot rename itself: `symbol()` is fixed at deployment, so a token that
/// has rebranded still answers with its old ticker forever. Ethereum's `0x7d1a…ebb0`
/// reports WMATIC for a coin that has been POL since 2024. That is why pasting an
/// address and typing a ticker used to produce two different names — and, because the
/// logo is keyed off whichever identity won, two different logos.
final class ContractIdentityTests: XCTestCase {

    private struct RegisterStub: CoinSearchService {
        let bySymbol: [String: String]
        let byContract: [String: CoinIdentity]
        func coinId(forSymbol symbol: String) async -> String? { bySymbol[symbol.lowercased()] }
        func identity(platform: String, contract: String) async -> CoinIdentity? {
            byContract["\(platform):\(contract.lowercased())"]
        }
    }

    private let matic = "0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0"

    private var priceBody: String {
        #"{"coins":{"ethereum:0x7d1afa7b718fb893db30a3abc0cfc608aacfebb0":"#
        + #"{"decimals":18,"symbol":"WMATIC","price":0.097,"confidence":0.99}}}"#
    }

    func test_theRegistersNameWinsOverTheContractsFrozenTicker() async {
        let search = RegisterStub(
            bySymbol: [:],
            byContract: ["ethereum:\(matic)": CoinIdentity(id: "polygon-ecosystem-token",
                                                           symbol: "POL")])
        let locator = TokenLocator(fetcher: RecordingFetcher(body: priceBody), search: search)
        let found = await locator.find(matic)
        XCTAssertEqual(found?.symbol, "POL", "not the contract's frozen WMATIC")
        XCTAssertEqual(found?.coingeckoId, "polygon-ecosystem-token",
                       "and the id comes back, so the logo can match a search by ticker")
        XCTAssertEqual(found?.networkName, "Ethereum")
        XCTAssertEqual(found?.contract, matic, "the address is still what prices it")
    }

    /// The register is one keyless request that routinely 429s. When it says nothing the
    /// contract's own ticker still has to carry the row.
    func test_withoutTheRegisterTheContractsTickerStillStands() async {
        let locator = TokenLocator(fetcher: RecordingFetcher(body: priceBody),
                                   search: RegisterStub(bySymbol: [:], byContract: [:]))
        let found = await locator.find(matic)
        XCTAssertEqual(found?.symbol, "WMATIC")
        XCTAssertNil(found?.coingeckoId)
    }

    func test_everyChainWeSearchCanBeAskedAboutByContract() {
        for chain in TokenLocator.chains {
            XCTAssertNotNil(CoinGeckoSearchService.platformIds[chain.key],
                            "\(chain.key) has no CoinGecko platform id, so a contract "
                            + "found there could never be identified")
        }
    }

    func test_networkKeyTranslatesADisplayNameBack() {
        XCTAssertEqual(TokenLocator.networkKey(forDisplayName: "Arbitrum"), "arbitrum")
        XCTAssertEqual(TokenLocator.networkKey(forDisplayName: "BNB Chain"), "bsc")
        XCTAssertEqual(TokenLocator.networkKey(forDisplayName: "base"), "base", "case-insensitive")
        XCTAssertNil(TokenLocator.networkKey(forDisplayName: "Monero"), "not an EVM chain we price")
    }
}

/// A coin id is not a network. Deriving one from the id spelled "aave" as a network
/// called Aave, so every ERC-20 added by ticker rather than by address was filed under
/// a chain that doesn't exist.
final class CoinNetworkTests: XCTestCase {

    private struct Register: CoinSearchService {
        var ids: [String: String] = [:]
        var deployed: [String: CoinDeployments] = [:]
        func coinId(forSymbol symbol: String) async -> String? { ids[symbol.lowercased()] }
        func deployments(forCoin id: String) async -> CoinDeployments? { deployed[id] }
    }

    private func locator(_ register: Register, price body: String) -> TokenLocator {
        TokenLocator(fetcher: RecordingFetcher(body: body), search: register)
    }

    private let aaveBody = #"{"coins":{"coingecko:aave":{"symbol":"AAVE","price":152.3,"confidence":0.99}}}"#
    private let xmrBody = #"{"coins":{"coingecko:monero":{"symbol":"XMR","price":1078.43,"confidence":0.99}}}"#

    func test_aTokenIsReportedOnItsHomeChainNotOnAChainNamedAfterItself() async {
        let register = Register(
            ids: ["aave": "aave"],
            deployed: ["aave": CoinDeployments(homePlatform: "ethereum",
                                               contracts: ["ethereum": "0xaave"])])
        let found = await locator(register, price: aaveBody).find("AAVE")
        XCTAssertEqual(found?.networkName, "Ethereum", "not \"Aave\"")
        XCTAssertEqual(found?.coingeckoId, "aave")
    }

    /// Deployed on exactly one chain — so there is nothing to ask about.
    func test_aSingleDeploymentIsNotAChoice() async {
        let register = Register(
            ids: ["aave": "aave"],
            deployed: ["aave": CoinDeployments(homePlatform: "ethereum",
                                               contracts: ["ethereum": "0xaave"])])
        let found = await locator(register, price: aaveBody).find("AAVE")
        XCTAssertEqual(found?.availableNetworks, [], "one deployment, no question")
        XCTAssertEqual(found?.needsNetworkChoice, false)
    }

    /// USDC is deployed on 36 chains. The picker offered every one of them, in
    /// alphabetical order, so the networks the app can actually name and colour were
    /// scattered among Algorand, Aptos and Hedera — and there were far too many to read.
    /// Home first, then the ones the app knows, then the rest.
    func test_aWidelyDeployedCoinOffersTheNetworksWeKnowFirst() async {
        let register = Register(
            ids: ["usdc": "usd-coin"],
            deployed: ["usd-coin": CoinDeployments(
                homePlatform: "ethereum",
                contracts: ["algorand": "0x1", "aptos": "0x2", "hedera-hashgraph": "0x3",
                            "ethereum": "0x4", "hyperevm": "0x5", "base": "0x6",
                            "arbitrum-one": "0x7", "stellar": "0x8"])])
        let body = #"{"coins":{"coingecko:usd-coin":{"symbol":"USDC","price":1.0,"confidence":0.99}}}"#
        let found = await locator(register, price: body).find("USDC")
        let names = found?.availableNetworks ?? []

        XCTAssertEqual(names.first, "Ethereum", "home chain still leads")
        let known = ["Ethereum", "HyperEVM", "Base", "Arbitrum"]
        XCTAssertEqual(Array(names.prefix(known.count)).sorted(), known.sorted(),
                       "every network the app can name comes before any it cannot")
        XCTAssertTrue(names.contains("Algorand"),
                      "a chain we cannot name is still offered — just not first")
    }

    func test_aMultiChainTokenOffersItsChainsWithHomeFirst() async {
        let register = Register(
            ids: ["pepe": "pepe"],
            deployed: ["pepe": CoinDeployments(
                homePlatform: "ethereum",
                contracts: ["arbitrum-one": "0xa", "avalanche": "0xb",
                            "binance-smart-chain": "0xc", "ethereum": "0xd"])])
        let found = await locator(register, price: #"{"coins":{"coingecko:pepe":{"symbol":"PEPE","price":0.00001,"confidence":0.99}}}"#).find("PEPE")
        XCTAssertEqual(found?.networkName, "Ethereum", "home chain is the default")
        XCTAssertEqual(found?.availableNetworks,
                       ["Ethereum", "Arbitrum", "Avalanche", "BNB Chain"],
                       "home first, then the rest — under OUR names, not CoinGecko's")
        XCTAssertTrue(found?.needsNetworkChoice == true)
    }

    /// The one case where naming the network after the coin is right: the coin IS the
    /// network. The register says so by having no asset platform at all.
    func test_aCoinThatIsItsOwnChainKeepsItsOwnName() async {
        let register = Register(
            ids: ["xmr": "monero"],
            deployed: ["monero": CoinDeployments(homePlatform: nil, contracts: [:])])
        let found = await locator(register, price: xmrBody).find("XMR")
        XCTAssertEqual(found?.networkName, "Monero")
        XCTAssertEqual(found?.availableNetworks, [])
    }

    /// The register is one keyless request that routinely 429s. Silence must not invent
    /// a network either — it falls back to the coin's own name, same as before.
    func test_withoutTheRegisterItFallsBackToTheCoinsOwnName() async {
        let register = Register(ids: ["xmr": "monero"], deployed: [:])
        let found = await locator(register, price: xmrBody).find("XMR")
        XCTAssertEqual(found?.networkName, "Monero")
    }

    /// ETH has no asset platform — the register would call it its own chain — yet it is
    /// held on three chains the app scans. Its own list has to win.
    func test_ethKeepsItsThreeNetworks() async {
        let register = Register(
            ids: ["eth": "ethereum"],
            deployed: ["ethereum": CoinDeployments(homePlatform: nil, contracts: [:])])
        let found = await locator(register, price: #"{"coins":{"coingecko:ethereum":{"symbol":"ETH","price":2523.04,"confidence":0.99}}}"#).find("ETH")
        XCTAssertEqual(found?.availableNetworks, ["Ethereum", "Arbitrum", "Base"])
        XCTAssertEqual(found?.networkName, "Ethereum")
    }

    /// A chain we don't price still gets spelled out properly rather than taking the
    /// coin's name.
    func test_aChainWeDontPriceIsStillNamedAfterTheChain() async {
        let register = Register(
            ids: ["bonk": "bonk"],
            deployed: ["bonk": CoinDeployments(homePlatform: "solana", contracts: ["solana": "So111"])])
        let found = await locator(register, price: #"{"coins":{"coingecko:bonk":{"symbol":"BONK","price":0.00002,"confidence":0.99}}}"#).find("BONK")
        XCTAssertEqual(found?.networkName, "Solana")
    }
}

/// A ticker answers to a different source for its letters than for its casing, and the
/// two disagree. Confirmed live on rETH, 2026-09-13:
///
///   DefiLlama by contract  → "rETH"   the string the team deployed
///   DefiLlama by coin id   → "RETH"   normalised
///   CoinGecko              → "reth"   normalised the other way
///
/// Only the contract carries the spelling the industry actually writes.
final class SymbolSpellingTests: XCTestCase {

    /// Answers per URL, so the coin-id lookup and the contract lookup can differ the way
    /// the real endpoints do.
    private final class RoutingFetcher: DataFetcher, @unchecked Sendable {
        let bodies: [String: String]
        init(_ bodies: [String: String]) { self.bodies = bodies }
        func data(from url: URL, headers: [String: String]) async throws -> Data {
            // Decoded: Foundation percent-escapes the ":" in "coingecko:<id>" when it
            // builds the path, so matching the raw string would never hit.
            let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            let match = bodies.first { s.contains($0.key) }
            return Data((match?.value ?? #"{"coins":{}}"#).utf8)
        }
    }

    private struct Register: CoinSearchService {
        var ids: [String: String] = [:]
        var deployed: [String: CoinDeployments] = [:]
        var identities: [String: CoinIdentity] = [:]
        func coinId(forSymbol symbol: String) async -> String? { ids[symbol.lowercased()] }
        func deployments(forCoin id: String) async -> CoinDeployments? { deployed[id] }
        func identity(platform: String, contract: String) async -> CoinIdentity? {
            identities[contract.lowercased()]
        }
    }

    private let rocket = "0xae78736cd615f374d3085123a210448e74fc6393"

    private var bodies: [String: String] {
        ["coingecko:rocket-pool-eth": #"{"coins":{"coingecko:rocket-pool-eth":{"symbol":"RETH","price":2902.5,"confidence":0.99}}}"#,
         rocket: #"{"coins":{"ethereum:0xae78736cd615f374d3085123a210448e74fc6393":{"decimals":18,"symbol":"rETH","price":2902.5,"confidence":0.99}}}"#]
    }

    func test_pastingTheAddressKeepsTheContractsOwnCasing() async {
        // The register normalises to RETH; the contract says rETH and it deployed the string.
        let register = Register(identities: [rocket: CoinIdentity(id: "rocket-pool-eth",
                                                                  symbol: "RETH")])
        let locator = TokenLocator(fetcher: RoutingFetcher(bodies), search: register)
        let found = await locator.find(rocket)
        XCTAssertEqual(found?.symbol, "rETH", "not RETH")
        XCTAssertEqual(found?.coingeckoId, "rocket-pool-eth", "and it is still identified")
    }

    func test_typingTheTickerBorrowsTheCasingFromTheHomeContract() async {
        let register = Register(
            ids: ["reth": "rocket-pool-eth"],
            deployed: ["rocket-pool-eth": CoinDeployments(homePlatform: "ethereum",
                                                          contracts: ["ethereum": rocket])])
        let locator = TokenLocator(fetcher: RoutingFetcher(bodies), search: register)
        let found = await locator.find("rETH")
        XCTAssertEqual(found?.symbol, "rETH", "priced by id, but spelled by the contract")
        XCTAssertEqual(found?.networkName, "Ethereum")
    }

    /// Casing must not become a way for the stale on-chain name to come back: when the
    /// letters genuinely differ, that is a rebrand and the register still wins.
    func test_aRealRenameStillBeatsTheContract() {
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "WMATIC", registered: "POL"), "POL")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "rETH", registered: "RETH"), "rETH")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "wstETH", registered: "WSTETH"), "wstETH")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "USDC", registered: "USDC"), "USDC")
    }

    /// Either source alone still has to produce something.
    func test_oneSourceMissingFallsBackToTheOther() {
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "rETH", registered: nil), "rETH")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: nil, registered: "POL"), "POL")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "", registered: "POL"), "POL")
        XCTAssertEqual(TokenLocator.preferredSpelling(onChain: "rETH", registered: ""), "rETH")
    }

    /// A coin with no contract anywhere has no cased source — it keeps what it had.
    func test_aCoinThatIsItsOwnChainIsUnaffected() async {
        let register = Register(
            ids: ["xmr": "monero"],
            deployed: ["monero": CoinDeployments(homePlatform: nil, contracts: [:])])
        let locator = TokenLocator(
            fetcher: RoutingFetcher(["coingecko:monero": #"{"coins":{"coingecko:monero":{"symbol":"XMR","price":1078.43,"confidence":0.99}}}"#]),
            search: register)
        let found = await locator.find("XMR")
        XCTAssertEqual(found?.symbol, "XMR")
    }
}

/// HyperEVM is priced and named but never scanned — the holder types or pastes it,
/// so the whole feature lives in how the two price sources' chain names are paired.
final class HyperEVMTests: XCTestCase {

    /// Held tokens on HyperEVM must find their own chain the way any other pasted
    /// address does. DefiLlama files chain 999 under `hyperliquid`; the app spells it
    /// HyperEVM, which is the name on the explorer and the name the holder recognises.
    func test_aPastedHyperEVMAddressIsSearchedAndNamed() {
        let entry = TokenLocator.chains.first { $0.key == "hyperliquid" }
        XCTAssertNotNil(entry, "a HyperEVM address must be probed like any other")
        XCTAssertEqual(entry?.name, "HyperEVM")
        XCTAssertEqual(entry?.chainId, 999)
        XCTAssertEqual(TokenLocator.displayName(forNetwork: "hyperliquid"), "HyperEVM")
        XCTAssertEqual(TokenLocator.networkKey(forDisplayName: "HyperEVM"), "hyperliquid")
    }

    /// CoinGecko calls the chain `hyperevm`; DefiLlama calls it `hyperliquid`. Without
    /// the pairing the register's name leaks through `prettyNetwork` as "Hyperevm" —
    /// so a USDC held on HyperEVM offered a network spelled two different ways.
    func test_theRegistersHyperEVMPlatformIsNamedProperly() {
        XCTAssertEqual(CoinGeckoSearchService.platformIds["hyperliquid"], "hyperevm")
        XCTAssertEqual(TokenLocator.name(forPlatform: "hyperevm"), "HyperEVM")
        XCTAssertEqual(TokenLocator.networkKey(forPlatform: "hyperevm"), "hyperliquid")
    }

    /// HYPE is the gas coin of HyperEVM and a spot balance on HyperCore, and the
    /// register lists only the latter — so the holder has a real choice the register
    /// can't express, exactly like ETH across three chains.
    func test_hypeOffersBothHyperliquidLayers() {
        XCTAssertEqual(TokenLocator.nativeNetworks["hyperliquid"], ["HyperEVM", "Hyperliquid"])
    }

}
