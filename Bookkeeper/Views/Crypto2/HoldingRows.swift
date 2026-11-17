import SwiftUI
import BookkeeperCore

/// What Crypto 1's ledger gets right, at the panel's full width and Banking's type size:
/// each token a row of blocks in its own logo colour — logo, symbol, amount, value — and
/// the share beside it, filed under a tab in its network's colour.
struct NetworkGroups: View {
    let groups: [(network: Network, rows: [PricedHolding])]
    /// The whole the share is of: the portfolio, a wallet, a network.
    let total: Decimal
    var onPick: (Token) -> Void = { _ in }
    @Environment(\.ink) private var ink

    static let rowHeight: CGFloat = 32

    static let gap: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.padding(.bottom, -8)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in group(g.network, g.rows) }
        }
    }

    /// What each column is, over the rows and on their grid: the tab's and logo's room
    /// left blank, then Token · Amount · Value · Share, each label at its column's edge.
    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 30, height: 1)
            HStack(spacing: 6) {
                Color.clear.frame(width: Self.rowHeight, height: 1)
                label("Token", .leading).padding(.horizontal, 10).frame(width: 92, alignment: .leading)
                label("Amount", .trailing).padding(.horizontal, 10).frame(minWidth: 70, maxWidth: .infinity, alignment: .trailing)
                label("Value", .trailing).padding(.horizontal, 10).frame(minWidth: 110, maxWidth: .infinity, alignment: .trailing)
                label("Share", .trailing).frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func label(_ t: String, _ a: Alignment) -> some View {
        Text(t.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(1.5).foregroundStyle(ink.faint).lineLimit(1)
    }

    private func group(_ network: Network, _ rows: [PricedHolding]) -> some View {
        let height = CGFloat(rows.count) * Self.rowHeight + CGFloat(max(0, rows.count - 1)) * Self.gap
        return HStack(alignment: .top, spacing: 8) {
            NetworkTab(letter: network.badge, color: Color(hex: NetworkTint.hex(network, among: rows.map(\.token))),
                       fullName: network.name, height: height)
                .frame(height: height)
            VStack(spacing: Self.gap) {
                ForEach(rows) { r in row(r) }
            }
        }
    }

    private func row(_ r: PricedHolding) -> some View {
        let fill = Ledger.fill(for: r.token)
        let fg = Ledger.ink(on: fill)
        return Button { onPick(r.token) } label: {
            HStack(spacing: 6) {
                TokenGlyph(token: r.token, size: Self.rowHeight).frame(width: Self.rowHeight)
                block(fill) {
                    Text(r.token.symbol).font(HouseFont.jost(14.5, 600)).foregroundStyle(fg).lineLimit(1)
                }
                .frame(width: 92)
                block(fill) {
                    Text(Self.amount(r.amount)).font(HouseFont.jost(14.5, 500)).monospacedDigit()
                        .foregroundStyle(fg).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(minWidth: 70, maxWidth: .infinity)
                block(fill) {
                    HStack(spacing: 0) {
                        Text("$").foregroundStyle(fg.opacity(0.7))
                        Spacer(minLength: 6)
                        Text(r.usdValue.map { Fmt.usdCents($0.double) } ?? "—").monospacedDigit().foregroundStyle(fg)
                    }
                    .font(HouseFont.jost(14.5, 500)).lineLimit(1)
                }
                .frame(minWidth: 110, maxWidth: .infinity)
                Text(share(r)).font(HouseFont.jost(12.5)).monospacedDigit().foregroundStyle(ink.muted)
                    .frame(width: 48, alignment: .trailing)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func block<C: View>(_ fill: Color, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }

    private func share(_ r: PricedHolding) -> String {
        guard let v = r.usdValue, total > 0 else { return "—" }
        return Fmt.percent((v / total).double * 100, digits: 1)
    }

    /// Two places at most; thousands and up compacted (6.81K) — a count of tokens, not money.
    static func amount(_ a: Decimal) -> String {
        let d = a.double
        if abs(d) >= 1000 { return d.formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
        return d.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Wallets as Banking lists its categories: a mark, the name, the worth and the share —
/// one line each. A click opens the line onto that wallet's tokens, by network; Edit opens
/// the wallet's Crypto 1 module in a window over the screen.
struct WalletList: View {
    let model: CryptoTwoModel
    var onEdit: (String) -> Void
    @State private var open: Set<String>

    init(model: CryptoTwoModel, onEdit: @escaping (String) -> Void) {
        self.model = model; self.onEdit = onEdit
        // A render opens the first wallet, so the open state can be looked at.
        _open = State(initialValue: SnapshotRenderer.isRendering ? Set(model.store.orderedWallets.prefix(1).map(\.id)) : [])
    }
    @Environment(\.ink) private var ink

    var body: some View {
        let store = model.store
        let worth = Dictionary(store.orderedWallets.map { w in
            (w.id, store.rows(forWallet: w.id).reduce(Decimal(0)) { $0 + ($1.usdValue ?? 0) })
        }, uniquingKeysWith: { a, _ in a })
        let total = max(Decimal(1), worth.values.reduce(0, +))
        let topWorth = max(Decimal(1), worth.values.max() ?? 1)
        // Most valuable first, as every list in the app; equal worth by name.
        let wallets = store.orderedWallets.sorted {
            let a = worth[$0.id] ?? 0, b = worth[$1.id] ?? 0
            return a != b ? a > b : $0.nickname < $1.nickname
        }
        VStack(spacing: 0) {
            ForEach(wallets, id: \.id) { w in
                let v = worth[w.id] ?? 0
                let isOpen = open.contains(w.id)
                VStack(spacing: 0) {
                    LeaderRow(name: w.nickname, hex: model.walletHex(w), value: v.double,
                              top: topWorth.double, share: (v / total).double, chevron: isOpen ? .open : .closed) {
                        Emoji(name: model.walletEmoji(w.nickname), size: 26)
                    }
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if isOpen { open.remove(w.id) } else { open.insert(w.id) }
                        }
                    }
                    if isOpen {
                        VStack(alignment: .leading, spacing: 12) {
                            let groups = store.groupedRows(forWallet: w.id)
                            if groups.isEmpty {
                                Text("Nothing in this wallet yet.").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                            } else {
                                NetworkGroups(groups: groups, total: v) { model.pricing = $0 }
                            }
                            EditButton { onEdit(w.id) }
                        }
                        .padding(.bottom, 16)
                        .transition(.opacity)
                    }
                }
            }
            Rectangle().fill(ink.rule).frame(height: 1)
        }
    }
}

/// One row of every Crypto 2 list — wallets, networks, a token's wallets — laid out the
/// same, column for column, so switching tabs swaps the contents and nothing moves: a rule
/// above, the mark, the name, a bar as long as its share of the biggest row, the worth,
/// the share, and the arrow's place (blank where a row doesn't open).
struct LeaderRow<Mark: View>: View {
    enum Chevron { case none, closed, open }
    let name: String
    let hex: String
    let value: Double
    let top: Double
    let share: Double
    var chevron: Chevron = .none
    @ViewBuilder var mark: () -> Mark
    @Environment(\.ink) private var ink

    static var barWidth: CGFloat { 168 }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ink.rule).frame(height: 1)
            HStack(spacing: 12) {
                mark().frame(width: 28, height: 28)
                Text(name).font(HouseFont.jost(16, 500)).foregroundStyle(ink.text)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Capsule(style: .continuous)
                    .fill(Color(hex: hex))
                    .frame(width: max(Look.barHeight, Self.barWidth * CGFloat(value / max(top, 1))), height: Look.barHeight)
                    .frame(width: Self.barWidth, alignment: .leading)
                Text(Fmt.usd(value)).font(HouseFont.jost(16)).monospacedDigit().foregroundStyle(ink.text)
                    .frame(width: 96, alignment: .trailing)
                Text(Fmt.percent(share * 100)).font(HouseFont.jost(12)).monospacedDigit()
                    .foregroundStyle(ink.faint).frame(width: 40, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.muted)
                    .rotationEffect(.degrees(chevron == .open ? 90 : 0))
                    .opacity(chevron == .none ? 0 : 1)
                    .frame(width: 12)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
    }
}

/// Banking's Edit capsule.
struct EditButton: View {
    var title = "Edit"
    var emoji = "pencil"
    let action: () -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Emoji(name: emoji, size: 16)
                Text(title).font(HouseFont.jost(13.5, 500))
            }
            .foregroundStyle(ink.text)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A wallet's drawer, Banking's category drawer for a wallet: a live preview, the name,
/// the colour, the emoji, then each
/// token as a plain row — logo, symbol and network, the amount to type over, the worth,
/// and ✕ to take it out — then a token to add. Name, colour, amounts and removals wait
/// for Save; Cancel leaves the wallet as it was. Adding a token is its own step and lands
/// at once, as it did in Crypto 1.
struct WalletEditWindow: View {
    let store: PortfolioStore
    let walletId: String
    var emoji: String = "purse"
    /// The colour the wallet wears now, picked or defaulted — what the preview starts on.
    var colorHex: String = "#8C9196"
    var onClose: () -> Void
    @Environment(\.ink) private var ink

    @State private var name = ""
    @State private var colour: String?
    @State private var icon: String?
    @State private var amounts: [String: String] = [:]
    @State private var removed: Set<String> = []
    @State private var saving = false
    @State private var confirmRemoveWallet = false

    /// Seeded here, not in `onAppear`, so the drawer opens on the real name.
    init(store: PortfolioStore, walletId: String, emoji: String = "purse", colorHex: String = "#8C9196",
         onClose: @escaping () -> Void) {
        self.store = store; self.walletId = walletId; self.emoji = emoji; self.colorHex = colorHex; self.onClose = onClose
        _name = State(initialValue: store.wallets.first { $0.id == walletId }?.nickname ?? "")
    }

    private var wallet: Wallet? { store.wallets.first { $0.id == walletId } }
    private var rows: [PricedHolding] {
        store.rows(forWallet: walletId).sorted { ($0.usdValue ?? -1) > ($1.usdValue ?? -1) }
    }
    private func network(_ r: PricedHolding) -> String { WalletsLedger.network(of: r.token) }
    private func editable(_ r: PricedHolding) -> Bool {
        store.isEditable(walletId: walletId, symbol: r.token.symbol, network: network(r))
    }
    /// The amount in full, thousands marked as English writes them: 10,000.25. (The
    /// rows' short form — 33.4K — is for reading; this one is for changing.)
    private func amountText(_ a: Decimal) -> String {
        Self.full.string(from: NSDecimalNumber(decimal: a)) ?? "\(a)"
    }

    private static let full: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 12
        f.minimumFractionDigits = 0
        return f
    }()

    private var changed: Bool {
        guard let w = wallet else { return false }
        return name.trimmingCharacters(in: .whitespaces) != w.nickname
            || (colour != nil && colour != store.walletColorHex(w.nickname))
            || (icon != nil && icon != emoji)
            || !removed.isEmpty
            || rows.contains { r in amounts[r.id].map { Money.expression(from: $0) != r.amount } ?? false }
    }

    var body: some View {
        Group {
            if SnapshotRenderer.isRendering { form } else { ScrollView { form }.scrollIndicators(.never) }
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ink.card)
        .overlay(alignment: .leading) { Rectangle().fill(ink.rule).frame(width: 1) }
        .shadow(color: ink.shadow, radius: 24, y: 8)
        .confirmationDialog("Remove \(wallet?.nickname ?? "this wallet")?", isPresented: $confirmRemoveWallet) {
            Button("Remove wallet", role: .destructive) {
                let nick = wallet?.nickname ?? walletId
                onClose()
                Task { await store.removeWallet(nickname: nick) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The wallet and every token entered in it leave Bookkeeper. Its past days stay in the history.")
        }
    }

    /// The colour the preview and swatches show: the one picked, else the wallet's own.
    private var shownColour: String {
        colour ?? wallet.flatMap { store.walletColorHex($0.nickname) } ?? colorHex
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("EDIT WALLET").font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
                    Text(wallet?.nickname ?? walletId).font(HouseFont.fraunces(22))
                        .foregroundStyle(ink.text)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 14) {
                Circle().fill(Color(hex: shownColour).opacity(0.22))
                    .frame(width: 52, height: 52)
                    .overlay(Emoji(name: icon ?? emoji, size: 30))
                VStack(alignment: .leading, spacing: 8) {
                    Text(name.isEmpty ? " " : name).font(HouseFont.jost(17, 600)).foregroundStyle(ink.text)
                    Capsule(style: .continuous)
                        .fill(Color(hex: shownColour))
                        .frame(width: 180, height: 8)
                }
            }
            .padding(.top, 18).padding(.bottom, 4)

            field("Name") {
                Group {
                    // AppKit-backed fields draw as a placeholder offscreen; the render shows the text.
                    if SnapshotRenderer.isRendering { Text(name).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TextField("", text: $name).textFieldStyle(.plain) }
                }
                    .font(HouseFont.jost(16)).foregroundStyle(ink.text)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
            }
            field("Colour — Nippon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(PortfolioStore.walletColors, id: \.hex) { c in
                        Button { colour = c.hex } label: {
                            Circle().fill(Color(hex: c.hex))
                                .overlay(Circle().strokeBorder(c.hex == shownColour ? ink.text : .clear, lineWidth: 3))
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                    }
                }
            }
            field("Emoji") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(CryptoTwoModel.walletEmojis, id: \.self) { n in
                        Button { icon = n } label: {
                            Emoji(name: n, size: 28)
                                .padding(7)
                                .frame(maxWidth: .infinity)
                                .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(n == (icon ?? emoji) ? ink.text : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            field("Tokens") {
                VStack(spacing: 0) {
                    if rows.isEmpty {
                        Text("Nothing here yet — add a token below.").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                            .padding(.vertical, 8)
                    }
                    ForEach(rows) { r in tokenRow(r) }
                }
            }
            field("Add token") { AddTokenRow(store: store, walletId: walletId) }

            HStack(spacing: 10) {
                Button(action: save) {
                    Text(saving ? "Saving…" : "Save").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!changed || saving)
                .opacity(changed ? 1 : 0.4)
                Button(action: onClose) {
                    Text("Cancel").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { confirmRemoveWallet = true } label: {
                    Text("Remove wallet").font(HouseFont.jost(13)).foregroundStyle(ink.warm)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
    }

    private func tokenRow(_ r: PricedHolding) -> some View {
        let gone = removed.contains(r.id)
        let canType = editable(r)
        return VStack(spacing: 0) {
            Rectangle().fill(ink.rule).frame(height: 1)
            HStack(spacing: 12) {
                TokenGlyph(token: r.token, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.token.symbol).font(HouseFont.jost(14.5, 600)).foregroundStyle(ink.text)
                        .strikethrough(gone)
                    Text(network(r).isEmpty ? (r.token.chain?.displayName ?? "") : network(r))
                        .font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                }
                .frame(width: 96, alignment: .leading)
                Group {
                    if canType && !gone {
                        TextField("", text: Binding(get: { amounts[r.id] ?? amountText(r.amount) },
                                                    set: { amounts[r.id] = $0 }))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            .font(HouseFont.jost(14)).monospacedDigit().foregroundStyle(ink.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(ink.ground, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.track, lineWidth: 1))
                    } else {
                        Text(NetworkGroups.amount(r.amount)).font(HouseFont.jost(14)).monospacedDigit()
                            .foregroundStyle(ink.muted).frame(maxWidth: .infinity, alignment: .trailing)
                            .help(canType ? "" : "Read from the chain — it can be hidden, not typed over")
                    }
                }
                .frame(maxWidth: .infinity)
                Text(r.usdValue.map { Fmt.usd($0.double) } ?? "—").font(HouseFont.jost(14)).monospacedDigit()
                    .foregroundStyle(ink.text).frame(width: 84, alignment: .trailing)
                Button {
                    if gone { removed.remove(r.id) } else { removed.insert(r.id) }
                } label: {
                    Group {
                        if gone { Text("Undo").font(HouseFont.jost(12, 500)) }
                        else { Image(systemName: "xmark").font(.system(size: 11)) }
                    }
                    .foregroundStyle(ink.muted).frame(width: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(canType ? "Take this token out" : "Hide this token")
            }
            .padding(.vertical, 9)
            .opacity(gone ? 0.45 : 1)
        }
    }

    private func save() {
        guard let w = wallet else { return }
        saving = true
        let old = w.nickname
        let newName = name.trimmingCharacters(in: .whitespaces)
        let pick = colour
        let chosenEmoji = icon
        let edits = rows.compactMap { r -> (PricedHolding, Decimal)? in
            guard !removed.contains(r.id), editable(r), let t = amounts[r.id],
                  let v = Money.expression(from: t), v > 0, v != r.amount else { return nil }
            return (r, v)
        }
        let gone = rows.filter { removed.contains($0.id) }
        Task { @MainActor in
            for (r, v) in edits {
                await store.setManualAmount(walletId: walletId, symbol: r.token.symbol, amount: v, network: network(r))
            }
            for r in gone {
                if editable(r) {
                    await store.removeManualToken(walletId: walletId, symbol: r.token.symbol, network: network(r))
                } else {
                    store.hideToken(r.token)
                }
            }
            if let pick { store.setWalletColor(old, hex: pick) }
            if let chosenEmoji { WalletEmojis.shared.set(chosenEmoji, for: old) }
            // Last: the wallet's id is its name, so everything above uses the old one.
            if !newName.isEmpty, newName != old {
                await store.renameWallet(from: old, to: newName)
                WalletEmojis.shared.rename(from: old, to: newName)
            }
            saving = false
            onClose()
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
            content()
        }
        .padding(.top, 22)
    }
}

/// Crypto 1's add-a-token lookup in the drawers' look: a contract address or a coin's
/// name, how many, and — only when the coin lives on several — which network.
struct AddTokenRow: View {
    let store: PortfolioStore
    let walletId: String
    @Environment(\.ink) private var ink

    @State private var query = ""
    @State private var amount = ""
    @State private var found: TokenLocator.Found?
    @State private var searching = false
    @State private var notFound = false
    @State private var unreachable = false
    @State private var adding = false
    @State private var network: String?

    private var amountValue: Decimal? { Money.expression(from: amount) }
    private var canAdd: Bool { found != nil && (amountValue ?? 0) > 0 && !adding }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                box("Contract address or coin name", $query).onSubmit { if canAdd { add() } }
                box("Amount", $amount).frame(width: 110).onSubmit { if canAdd { add() } }
                Button(action: add) {
                    Text(adding ? "Adding…" : "Add").font(HouseFont.jost(13.5, 600))
                        .foregroundStyle(canAdd ? ink.ground : ink.muted)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(canAdd ? ink.text : ink.pill, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(!canAdd)
            }
            if searching {
                Text(TorService.shared.state == .starting ? "Tor is still connecting — looking it up as soon as it's through…"
                                                          : "Looking it up…")
                    .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
            } else if unreachable {
                Text("Couldn't reach the price sites just now. Try again in a moment — it isn't that the coin doesn't exist.")
                    .font(HouseFont.jost(12.5)).foregroundStyle(ink.warm)
            } else if let f = found {
                HStack(spacing: 8) {
                    Text(f.symbol).font(HouseFont.jost(14, 600)).foregroundStyle(ink.text)
                    Text("on \(f.networkName)").font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                    Text(Money.price(f.price)).font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                    if let a = amountValue, a > 0 {
                        Text("= \(Money.usd(a * f.price))").font(HouseFont.jost(12.5, 500)).foregroundStyle(ink.up)
                    }
                    if f.confidence < 0.5 {
                        Text("thin liquidity").font(HouseFont.jost(12)).foregroundStyle(ink.warm)
                    }
                }
                if f.needsNetworkChoice {
                    NetworkChoiceRow(names: f.availableNetworks, selected: network ?? f.networkName) { network = $0 }
                }
            } else if notFound {
                Text(TokenLocator.looksLikeContract(query) ? "Not found on any network we price."
                                                          : "No coin by that name — try its contract address.")
                    .font(HouseFont.jost(12.5)).foregroundStyle(ink.warm)
            }
        }
        .task(id: query) {
            found = nil; notFound = false; unreachable = false; network = nil
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3 else { return }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            // Through Tor, ask once it's connected — before then every request fails.
            await TorService.shared.settled()
            // A Tor route can drop a request; a few patient tries before saying so.
            var outcome = TokenLocator.Outcome.unreachable
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                guard !Task.isCancelled else { return }
                outcome = await store.lookup(q)
                if outcome != .unreachable { break }
            }
            guard !Task.isCancelled else { return }
            searching = false
            found = outcome.found
            notFound = outcome == .notFound
            unreachable = outcome == .unreachable
        }
    }

    private func add() {
        guard let a = amountValue else { return }
        adding = true
        let q = query
        Task {
            await store.addToken(walletId: walletId, query: q, amount: a, network: network)
            await IconCache.shared.prefetch(store.visibleTokens)
            adding = false
            query = ""; amount = ""; found = nil; network = nil
        }
    }

    private func box(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text).textFieldStyle(.plain)
            .font(HouseFont.jost(14)).foregroundStyle(ink.text)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
    }
}

/// The emoji each wallet was given in its drawer, by name, in `wallet-emojis.json` beside
/// the v1 files (never inside them). A wallet with none picked takes one from the pool.
@Observable @MainActor
final class WalletEmojis {
    static let shared = WalletEmojis()
    private(set) var chosen: [String: String]
    @ObservationIgnored private let file = DataRoot.url.appendingPathComponent("wallet-emojis.json")

    init() {
        chosen = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func set(_ emoji: String, for wallet: String) {
        chosen[wallet] = emoji
        write()
    }

    func rename(from old: String, to new: String) {
        guard let e = chosen.removeValue(forKey: old) else { return }
        chosen[new] = e
        write()
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(chosen) else { return }
        try? data.write(to: file, options: .atomic)
    }
}



/// A new wallet, in the drawers' look: a live preview, its name, a Nippon colour and an
/// emoji — the next ones no other wallet wears, ready to change — then Add wallet. Its
/// tokens come after, from its Edit drawer.
struct NewWalletDrawer: View {
    let model: CryptoTwoModel
    var onClose: () -> Void
    @Environment(\.ink) private var ink

    @State private var name = ""
    @State private var colour: String
    @State private var icon: String
    @State private var adding = false
    @FocusState private var nameFocused: Bool

    init(model: CryptoTwoModel, onClose: @escaping () -> Void) {
        self.model = model; self.onClose = onClose
        let usedColours = Set(model.store.wallets.map(model.walletHex))
        _colour = State(initialValue: PortfolioStore.walletColors.map(\.hex).first { !usedColours.contains($0) }
                        ?? PortfolioStore.walletColors[0].hex)
        let usedEmoji = Set(model.store.wallets.map { model.walletEmoji($0.nickname) })
        _icon = State(initialValue: CryptoTwoModel.walletEmojis.first { !usedEmoji.contains($0) } ?? "purse")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var taken: Bool { model.store.wallets.contains { $0.nickname.caseInsensitiveCompare(trimmed) == .orderedSame } }
    private var canAdd: Bool { !trimmed.isEmpty && !taken && !trimmed.contains("\t") && !adding }

    var body: some View {
        Group {
            if SnapshotRenderer.isRendering { form } else { ScrollView { form }.scrollIndicators(.never) }
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ink.card)
        .overlay(alignment: .leading) { Rectangle().fill(ink.rule).frame(width: 1) }
        .shadow(color: ink.shadow, radius: 24, y: 8)
        .onAppear { nameFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    label("New wallet")
                    Text(trimmed.isEmpty ? "Wallet" : trimmed).font(HouseFont.fraunces(22))
                        .foregroundStyle(ink.text)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 14) {
                Circle().fill(Color(hex: colour).opacity(0.22)).frame(width: 52, height: 52)
                    .overlay(Emoji(name: icon, size: 30))
                VStack(alignment: .leading, spacing: 8) {
                    Text(trimmed.isEmpty ? " " : trimmed).font(HouseFont.jost(17, 600)).foregroundStyle(ink.text)
                    Capsule(style: .continuous).fill(Color(hex: colour)).frame(width: 180, height: Look.barHeight)
                }
            }
            .padding(.top, 18).padding(.bottom, 4)

            field("Name") {
                Group {
                    if SnapshotRenderer.isRendering { Text(name.isEmpty ? " " : name).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TextField("Cold storage, Daily, Savings…", text: $name).textFieldStyle(.plain).focused($nameFocused)
                            .onSubmit { if canAdd { add() } } }
                }
                .font(HouseFont.jost(16)).foregroundStyle(ink.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                if taken {
                    Text("A wallet is already called that.").font(HouseFont.jost(12)).foregroundStyle(ink.warm)
                }
            }
            field("Colour — Nippon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(PortfolioStore.walletColors, id: \.hex) { c in
                        Button { colour = c.hex } label: {
                            Circle().fill(Color(hex: c.hex))
                                .overlay(Circle().strokeBorder(c.hex == colour ? ink.text : .clear, lineWidth: 3))
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                    }
                }
            }
            field("Emoji") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(CryptoTwoModel.walletEmojis, id: \.self) { n in
                        Button { icon = n } label: {
                            Emoji(name: n, size: 28).padding(7).frame(maxWidth: .infinity)
                                .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(n == icon ? ink.text : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Its tokens go in next, from its Edit drawer.")
                .font(HouseFont.jost(12)).foregroundStyle(ink.muted).padding(.top, 14)

            HStack(spacing: 10) {
                Button(action: add) {
                    Text(adding ? "Adding…" : "Add wallet").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
                Button(action: onClose) {
                    Text("Cancel").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
    }

    private func add() {
        let nick = trimmed, hex = colour, emoji = icon
        adding = true
        Task { @MainActor in
            await model.store.addWallet(nickname: nick)
            model.store.setWalletColor(nick, hex: hex)
            WalletEmojis.shared.set(emoji, for: nick)
            adding = false
            onClose()
        }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            content()
        }
        .padding(.top, 20)
    }
}
