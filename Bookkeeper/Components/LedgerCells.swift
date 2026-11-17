import SwiftUI
import BookkeeperCore

/// The cell vocabulary of the reference sheets: saturated blocks separated by black
/// gutters, mono type, and text whose colour is chosen against the fill rather than
/// fixed — a mid blue takes white, a lime takes black, and picking one for both makes
/// half the table unreadable.
enum Ledger {
    static let gutter: CGFloat = 4
    static let radius: CGFloat = 5
    /// The band in the history chart for a mark made before per-wallet breakdowns
    /// existed. Carries the day's total so the day still appears, rather than dropping
    /// out of the chart and reading as a gap in the record.
    static let unattributed = "Before breakdowns"
    /// The band for money the archive credits to a name no wallet goes by any more.
    /// Shown as one quiet band, not a column each, so the stack still reaches the total
    /// without a gone wallet looking current — the index's Edit is where it gets cleared.
    static let retired = "Old wallets"
    /// Just taller than the type it holds. At 38 a row was mostly empty space, and a
    /// wallet of twenty tokens ran off the screen for no reason.
    static let rowHeight: CGFloat = 22

    static func mono(_ size: CGFloat) -> Font { .custom("RobotoMono-Bold", size: size * Look.shared.textScale) }

    /// How wide a string is in the ledger's own face, for columns that size to their
    /// contents rather than to a guess. Exact rather than estimated: the face is
    /// monospaced, so measuring it costs one call and removes the fudge factor.
    static func width(_ text: String, size: CGFloat, tracking: CGFloat = 0) -> CGFloat {
        let font = NSFont(name: "RobotoMono-Bold", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .bold)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return w + tracking * CGFloat(max(text.count - 1, 0))
    }

    /// A dollar figure at one decimal. Cents are noise in a column you read down —
    /// nobody scans a portfolio to the penny — and compacting above six figures keeps
    /// the column from having to grow for one large holding.
    static func value(_ d: Decimal?) -> String {
        guard let d else { return "—" }
        let v = NSDecimalNumber(decimal: d).doubleValue
        if abs(v) >= 100_000 {
            return v.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        }
        return v.formatted(.number.precision(.fractionLength(1)))
    }

    /// Perceived lightness, so the ink can be chosen against any fill.
    static func ink(on fill: Color) -> Color {
        let ns = NSColor(fill).usingColorSpace(.sRGB) ?? .white
        let l = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return l > 0.62 ? Color(hex: "#0B0B0B") : .white
    }

    /// A neutral cell: the page's ink mixed `a` of the way into the ground. On black,
    /// `0.14` is the old fixed #242424 and `0.29` the #4A4A4A total — on cream the same
    /// mixes come out as warm greys, so a cell stays a cell in every look. Opaque rather
    /// than an opacity, so `ink(on:)` reads the colour actually shown.
    static func wash(_ a: Double) -> Color {
        let ground = NSColor(Palette.canvas).usingColorSpace(.sRGB) ?? .black
        let text = NSColor(Palette.ink).usingColorSpace(.sRGB) ?? .white
        return Color(nsColor: ground.blended(withFraction: a, of: text) ?? ground)
    }

    /// Up / down for a change figure in the soft pair the price screens use. The pastels
    /// were picked against black and wash out on cream, so light takes the look's own.
    static func change(_ up: Bool) -> Color {
        let ink = Look.shared.ink
        if ink.isDark { return Color(hex: up ? "#7FBF6B" : "#F4A07A") }
        return up ? ink.up : ink.warm
    }

    /// The token's colour, at the full strength this language uses.
    @MainActor static func fill(for token: Token) -> Color {
        IconCache.shared.tint(for: token) ?? Palette.token(token.colorHex)
    }
}

/// A filled ledger block.
struct LedgerBlock<Content: View>: View {
    let fill: Color
    var height: CGFloat = Ledger.rowHeight
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
    }
}

/// The vertical network tab down the left of a group: one letter, one colour, naming the
/// network once for every row it spans.
struct NetworkTab: View {
    let letter: String
    let color: Color

    /// Full network name. Written out along the bar when the group is tall enough to
    /// hold it, and falling back to the letter when it isn't — a one- or two-token group
    /// has no room, and a squeezed word reads worse than an initial.
    var fullName: String = ""
    /// How tall the bar is, which decides whether the name fits.
    var height: CGFloat = 0

    /// Roughly the length the rotated word needs, at this font.
    private var spelledOut: Bool {
        height >= CGFloat(fullName.count) * 8.5 + 18
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Ledger.radius)
            .fill(color)
            .frame(width: 30)
            .overlay {
                if spelledOut {
                    Text(fullName.uppercased())
                        .font(Ledger.mono(11)).tracking(1.4)
                        .foregroundStyle(Ledger.ink(on: color))
                        .fixedSize()
                        .rotationEffect(.degrees(-90))   // runs along the bar
                } else {
                    Text(letter.uppercased())
                        .font(Ledger.mono(14))
                        .foregroundStyle(Ledger.ink(on: color))
                }
            }
            .help(fullName)
    }
}

/// A full-width caption block — the sheets use one to title a section or a protocol.
struct LedgerBanner: View {
    let text: String
    let fill: Color
    var size: CGFloat = 20

    var body: some View {
        Text(text)
            .font(Ledger.mono(size))
            .foregroundStyle(Ledger.ink(on: fill))
            .frame(maxWidth: .infinity)
            .frame(height: size + 22)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
    }
}

// MARK: - The shared table vocabulary

/// Column widths, defined once so the portfolio sheet and every wallet module line up.
///
/// Sized to what each column actually holds rather than to each other: a ticker is three
/// or four characters, a token count is a whole number, and only the dollar figure needs
/// real width. Snapping them all to a common measure made the symbol cell twice the size
/// of anything in it.
enum LedgerCol {
    static let tab: CGFloat = 28
    static let icon: CGFloat = 30
    static let symbol: CGFloat = 66      // "rETH", "USDC"
    static let amount: CGFloat = 76      // a count of tokens
    static let value: CGFloat = 110      // the dollar figure, which does need the room
    static let pct: CGFloat = 48

    static var tableWidth: CGFloat {
        tab + icon + symbol + amount + value + pct + Ledger.gutter * 5
    }
}

/// The TKN / # / $ / % caption line. Plain ink on the field — the sheets leave it
/// unfilled so the coloured cells below are the only blocks in the column.
struct LedgerHeader: View {
    var body: some View {
        HStack(spacing: Ledger.gutter) {
            Color.clear.frame(width: LedgerCol.tab, height: 1)
            // TKN sits over the logo and the ticker together — they read as one column.
            Text("TKN").font(Ledger.mono(11)).foregroundStyle(Palette.ink)
                .frame(width: LedgerCol.icon + LedgerCol.symbol + Ledger.gutter)
            Text("AMOUNT").font(Ledger.mono(11)).foregroundStyle(Palette.ink)
                .frame(width: LedgerCol.amount)
            Text("VALUE").font(Ledger.mono(11)).foregroundStyle(Palette.ink)
                .frame(width: LedgerCol.value)
            Text("%").font(Ledger.mono(11)).foregroundStyle(Palette.ink)
                .frame(width: LedgerCol.pct, alignment: .trailing)
            Spacer(minLength: 0)
        }
    }
}

/// One holding as three separate blocks — ticker, count, dollars — each with a gutter
/// between it and the next, and the share outside the table on the right.
struct LedgerTokenRow: View {
    let row: PricedHolding
    var onTap: (() -> Void)? = nil
    /// Edit mode turns the amount into a field and puts a remove control on the row.
    var editing: Bool = false
    /// Only a hand-entered amount can be typed over — a scanned balance comes from the
    /// chain, and letting someone edit it would just be overwritten on the next refresh.
    var editable: Bool = false
    var onAmount: ((Decimal) -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    /// Networks this row can be moved between, and where it is now. Empty when the row's
    /// chain came from a contract address and isn't a preference to change.
    var networks: [String] = []
    var currentNetwork: String = ""
    var onNetwork: ((String) -> Void)? = nil

    @State private var draft = ""
    @State private var typing = false

    private var amountText: String {
        let d = NSDecimalNumber(decimal: row.amount).doubleValue
        if abs(d) >= 1000 {
            return d.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
        }
        // Two decimals, never more. A token count carries as many places as the chain
        // cares to report — eighteen for most ERC-20s — and none past the second is
        // information anyone reads off a row.
        return d.formatted(.number.precision(.fractionLength(0...2)))
    }
    private var valueText: String { Ledger.value(row.usdValue) }
    private var pctText: String {
        guard let p = row.pct else { return "—" }
        return String(format: "%.1f%%", NSDecimalNumber(decimal: p).doubleValue)
    }

    /// The amount as a plain number for editing — the display form is abbreviated
    /// ("6.81K"), and typing over an abbreviation would lose precision.
    private var plainAmount: String {
        NSDecimalNumber(decimal: row.amount)
            .description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    private func commitAmount() {
        // Same reading as the add form: "1,054,100" is a pasted amount, and "100+5" is
        // a top-up rather than a recomputed total.
        guard let v = Money.expression(from: draft), v > 0 else {
            draft = plainAmount
            return
        }
        onAmount?(v)
    }

    @ViewBuilder private func logo(_ token: Token, fill: Color) -> some View {
        if let img = IconCache.shared.image(for: token) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: 22, height: 22).clipShape(Circle())
        } else {
            Circle().fill(fill).frame(width: 22, height: 22)
                .overlay(Text(String(token.symbol.prefix(1)))
                    .font(Ledger.mono(10)).foregroundStyle(Ledger.ink(on: fill)))
        }
    }

    var body: some View {
        // One colour across the three cells. Washing the figures down read as disabled
        // rather than as secondary — the gutters already separate them.
        let fill = Ledger.fill(for: row.token)
        let ink = Ledger.ink(on: fill)
        HStack(spacing: Ledger.gutter) {
            logo(row.token, fill: fill).frame(width: LedgerCol.icon)

            LedgerBlock(fill: fill) {
                if editing, !networks.isEmpty {
                    // The picker hangs off the ticker rather than taking a column of its
                    // own: the row is already tight, and a network is an attribute of
                    // the token rather than another figure to line up.
                    Menu {
                        ForEach(networks, id: \.self) { name in
                            Button {
                                if name != currentNetwork { onNetwork?(name) }
                            } label: {
                                if name == currentNetwork { Label(name, systemImage: "checkmark") }
                                else { Text(name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(row.token.symbol)
                                .font(Ledger.mono(12.5)).foregroundStyle(ink)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold)).foregroundStyle(ink.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .padding(.horizontal, 4)
                    .help("Network: \(currentNetwork.isEmpty ? "none" : currentNetwork)")
                } else {
                    Text(row.token.symbol)
                        .font(Ledger.mono(12.5)).foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: LedgerCol.symbol)

            LedgerBlock(fill: fill) {
                if editing && editable {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(Ledger.mono(12)).foregroundStyle(ink)
                        .multilineTextAlignment(.trailing)
                        .padding(.horizontal, 6)
                        .onAppear { draft = plainAmount }
                        .onSubmit { commitAmount() }
                        .overlay(alignment: .leading) {
                            Image(systemName: "pencil").font(.system(size: 8))
                                .foregroundStyle(ink.opacity(0.55)).padding(.leading, 5)
                        }
                } else {
                    Text(amountText)
                        .font(Ledger.mono(12)).foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: LedgerCol.amount)

            LedgerBlock(fill: fill) {
                HStack(spacing: 0) {
                    Text("$").font(Ledger.mono(12)).foregroundStyle(ink)
                        .padding(.leading, 6)
                    Spacer(minLength: 2)
                    Text(valueText)
                        .font(Ledger.mono(12)).foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .padding(.trailing, 6)
                }
            }
            .frame(width: LedgerCol.value)

            if editing {
                Button { onRemove?() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "#D0021B"))
                }
                .buttonStyle(.plain)
                .frame(width: LedgerCol.pct, alignment: .trailing)
                .help(editable ? "Remove this token" : "Hide this token")
            } else {
                Text(pctText)
                    .font(Ledger.mono(12)).italic().foregroundStyle(Palette.ink)
                    .frame(width: LedgerCol.pct, alignment: .trailing)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { onTap?() } }
    }
}

/// A network's rows, with the letter tab running down beside them.
struct LedgerNetworkGroup: View {
    let network: Network
    let rows: [PricedHolding]
    var onSelect: (Token) -> Void
    var editing: Bool = false
    var isEditable: (PricedHolding) -> Bool = { _ in false }
    var onAmount: (PricedHolding, Decimal) -> Void = { _, _ in }
    var networks: (PricedHolding) -> [String] = { _ in [] }
    var currentNetwork: (PricedHolding) -> String = { _ in "" }
    var onNetwork: (PricedHolding, String) -> Void = { _, _ in }
    var onRemove: (PricedHolding) -> Void = { _ in }

    private var barHeight: CGFloat {
        CGFloat(rows.count) * Ledger.rowHeight + CGFloat(max(0, rows.count - 1)) * Ledger.gutter
    }

    var body: some View {
        HStack(alignment: .top, spacing: Ledger.gutter) {
            // Every group is tabbed. A coin that is its own chain — Monero, Siacoin — is
            // still a network, and leaving it blank filed it next to every other
            // nil-chain token under one nameless block.
            NetworkTab(letter: network.badge,
                       color: MetricStyle.networkColor(network),
                       fullName: network.name,
                       height: barHeight)
                .frame(height: barHeight)
            VStack(spacing: Ledger.gutter) {
                ForEach(rows) { r in
                    LedgerTokenRow(row: r,
                                   onTap: { onSelect(r.token) },
                                   editing: editing,
                                   editable: isEditable(r),
                                   onAmount: { onAmount(r, $0) },
                                   onRemove: { onRemove(r) },
                                   networks: networks(r),
                                   currentNetwork: currentNetwork(r),
                                   onNetwork: { onNetwork(r, $0) })
                }
            }
        }
    }
}
