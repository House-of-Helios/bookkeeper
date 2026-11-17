import Foundation

/// The network a holding sits on, as the ledger draws it: a name, a letter, a colour.
///
/// The ledger used to group by `Chain?`, which meant the three chains the app once
/// scanned each got a coloured tab and *everything else* — HyperEVM, Monero, Sia —
/// fell into a single untabbed group together, because they all answer `nil`. A token
/// held on Monero and a token held on HyperEVM are not the same network, and neither of
/// them is "Manual".
///
/// So the grouping key is a network, not a chain. `Chain` stays what it is — the three
/// the app models as a type — and every other network is named by what the register or
/// the contract lookup already told us it was.
public struct Network: Hashable, Sendable, Identifiable {
    /// Display name, and the identity: "Ethereum", "HyperEVM", "Monero".
    public let name: String
    /// The chain case behind it, for the three that have one. Nil is not "manual" here;
    /// it only means the app has no `Chain` for this network.
    public let chain: Chain?

    public var id: String { name }

    public init(name: String, chain: Chain? = nil) {
        self.name = name
        self.chain = chain
    }

    /// The network a token belongs to.
    ///
    /// A hand-entered token carries the name the lookup discovered (`manualNetwork`); a
    /// token on one of the three modelled chains carries the chain. A token with neither
    /// is a coin whose own network we never learned, which is the only real "Manual".
    public static func of(_ token: Token) -> Network {
        if let chain = token.chain { return Network(name: chain.displayName, chain: chain) }
        if let named = token.manualNetwork, !named.isEmpty { return Network(name: named) }
        return .unknown
    }

    public static let unknown = Network(name: "Manual")

    /// The letter on the tab when the group is too short to spell the name out.
    ///
    /// The first letter, as it always was. Two networks can share one — Base and Blast,
    /// Monero and Mantle — but the tab spells the full name whenever there is room, and
    /// an initial that occasionally repeats reads better than an invented code nobody
    /// can map back to a name.
    public var badge: String { String(name.prefix(1)).uppercased() }

    /// Brand colour, as hex.
    ///
    /// Networks wear their own brand, unlike wallets, which wear Nippon colours: a
    /// wallet's colour is an arbitrary identifier the user can change, while a network's
    /// is a fact about the network. Anything the table doesn't name falls back to the
    /// neutral that unnamed holdings have always used.
    public var colorHex: String { Self.brand[name] ?? Self.neutral }

    /// Whether the colour table names this network, i.e. whether `colorHex` is its own
    /// brand or the shared fallback. A caller that wants to substitute something better
    /// than the neutral — a token's own tint, say — asks this rather than the table.
    public var isNamed: Bool { Self.brand[name] != nil }

    public static let neutral = "#E8A06B"

    /// How many network choices to show before the rest are folded behind "show all".
    /// Four, so the leading pills and the "+N more" control sit on one line at the width
    /// the add-token form actually gets. One constant — raise it if the form widens.
    public static let choiceLimit = 4

    /// The choices to show when the picker is collapsed.
    ///
    /// The first few, which are the ones the app can name and therefore the ones a holder
    /// most likely means — plus the current selection, wherever it sits in the list. That
    /// second part is the whole subtlety: picking Stellar and then collapsing must not
    /// hide the answer you just gave, leaving the row looking like nothing is selected.
    /// The selection is appended rather than promoted, so the leading few never reshuffle
    /// under the cursor as you click along them.
    public static func collapsedChoices(from names: [String], selected: String,
                                        limit: Int = choiceLimit) -> [String] {
        guard names.count > limit + 1 else { return names }   // "+1 more" is worse than showing it
        var head = Array(names.prefix(limit))
        if !head.contains(selected), names.contains(selected) { head.append(selected) }
        return head
    }

    /// Every network the app can put a name to. Keyed by display name, which is the
    /// identity — `TokenLocator.chains` and `Chain.displayName` both spell it this way.
    static let brand: [String: String] = [
        // The three that are also `Chain` cases — unchanged, so nothing recolours.
        "Ethereum":  "#7B83A8",
        "Arbitrum":  "#5BA4E8",
        "Base":      "#2A6BF0",
        // Hyperliquid's mint, darkened off its #97FCE4 so it sits on the black canvas.
        // The only non-blue among the chains, which is most of why it reads instantly.
        "HyperEVM":  "#6BD6BF",
        // Monero's own orange is #FF6600, which is already the By-Type ring's "Tokens"
        // slice. One orange meaning two different things on one screen is worse than a
        // near-miss, so this is Ohni — the Nippon orange nearest it.
        "Monero":    "#F05E1C",
        // The rest of what a pasted address can resolve to, so a network the app can
        // already price is never a nameless grey block.
        "Optimism":  "#E8484A",
        "Polygon":   "#8247E5",
        "BNB Chain": "#F0B90B",
        "Avalanche": "#E84142",
        "Gnosis":    "#3E8F72",
        "Linea":     "#61C3DF",
        "Scroll":    "#D9A86C",
        "zkSync":    "#8C8DFC",
        "Blast":     "#D6D53B",
        "Mantle":    "#65B3AE",
        "Celo":      "#B9C74A",
        "Fantom":    "#4C86FF",
    ]
}
