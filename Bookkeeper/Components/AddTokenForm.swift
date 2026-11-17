import SwiftUI
import BookkeeperCore

/// Add a token by naming it. One field, plus how much.
///
/// You paste a contract address or type a coin's name; the app works out the rest and
/// shows what it found — symbol, network, price, and what your amount is worth — before
/// you commit. There is deliberately no network picker: working out the chain is the
/// app's job, not yours, and for a coin that is its own chain (Monero) a picker of EVM
/// networks has no correct answer in it at all.
struct AddTokenForm: View {
    let store: PortfolioStore
    /// Pre-selected wallet. Nil on the portfolio screen, which asks.
    var fixedWallet: String? = nil

    @State private var open = false
    @State private var wallet = ""
    @State private var query = ""
    @State private var amount = ""
    @State private var found: TokenLocator.Found?
    @State private var searching = false
    @State private var adding = false
    @State private var notFound = false
    @State private var unreachable = false
    /// Which network the user picked, when the coin could be on several.
    @State private var network: String?

    private enum Field { case query, amount }
    @FocusState private var focus: Field?

    private var walletChoices: [String] { store.wallets.map(\.nickname) }
    private var targetWallet: String { fixedWallet ?? wallet }

    /// Arithmetic is allowed here too: adding a token already held tops it up, and
    /// "100+5" says the same thing in the field.
    private var amountValue: Decimal? { Money.expression(from: amount) }
    private var canAdd: Bool {
        found != nil && (amountValue ?? 0) > 0 && !targetWallet.isEmpty && !adding
    }

    private func submit() {
        guard let amt = amountValue else { return }
        adding = true
        let target = targetWallet, q = query
        Task {
            await store.addToken(walletId: target, query: q, amount: amt, network: network)
            await IconCache.shared.prefetch(store.visibleTokens)
            adding = false
            query = ""; amount = ""; found = nil; network = nil; open = false
            focus = nil
        }
    }

    private var collapsedBar: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { open = true } } label: {
            HStack(spacing: 9) {
                Text("+").font(AppFont.mono(13)).foregroundStyle(Palette.canvas)
                    .frame(width: 19, height: 19).background(Palette.ink).clipShape(Circle())
                Text("add token").font(AppFont.mono(11.5)).foregroundStyle(Palette.dim)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What the lookup found — including the network, which is the answer to the
    /// question this form pointedly does not ask.
    @ViewBuilder private var result: some View {
        if searching {
            Text(TorService.shared.state == .starting ? "tor is still connecting…" : "searching…")
                .font(AppFont.mono(11)).foregroundStyle(Palette.dim)
        } else if unreachable {
            Text("Couldn't reach the price sites — try again in a moment.")
                .font(AppFont.mono(11)).foregroundStyle(Ledger.change(false))
        } else if let f = found {
            HStack(spacing: 9) {
                Text(f.symbol).font(AppFont.mono(14)).foregroundStyle(Palette.ink)
                Text(f.networkName).font(AppFont.mono(10))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Palette.hairline).foregroundStyle(Palette.ink)
                    .clipShape(Capsule())
                Text(Money.price(f.price)).font(AppFont.mono(11)).foregroundStyle(Palette.dim)
                if let amt = amountValue, amt > 0 {
                    Text("= \(Money.usd(amt * f.price))").font(AppFont.mono(12))
                        .foregroundStyle(Ledger.change(true))
                }
                if f.confidence < 0.5 {
                    Text("thin liquidity").font(AppFont.mono(10))
                        .foregroundStyle(Look.shared.ink.isDark ? Color(hex: "#E8C66B") : Look.shared.ink.warm)
                }
                Spacer()
            }

            // Only asked when there is genuinely a choice. A contract address already
            // names its chain, and a coin that is its own chain has nothing to pick —
            // but ETH is ETH on three networks and only the holder knows which.
            if f.needsNetworkChoice {
                NetworkChoiceRow(names: f.availableNetworks,
                                 selected: network ?? f.networkName) { network = $0 }
            }
        } else if notFound {
            Text(TokenLocator.looksLikeContract(query)
                 ? "Not found on any network we price."
                 : "No coin by that name — try its contract address.")
                .font(AppFont.mono(11)).foregroundStyle(Ledger.change(false))
        }
    }

    private var openForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if fixedWallet == nil && walletChoices.count > 1 {
                    Picker("", selection: $wallet) {
                        ForEach(walletChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                }
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.15)) { open = false; focus = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                TextField("contract address or coin name", text: $query)
                    .textFieldStyle(.plain).font(AppFont.mono(12)).foregroundStyle(Palette.ink)
                    .focused($focus, equals: .query)
                    .onSubmit { focus = .amount }
                TextField("amount", text: $amount)
                    .textFieldStyle(.plain).font(AppFont.mono(12)).foregroundStyle(Palette.ink)
                    .frame(width: 90)
                    .focused($focus, equals: .amount)
                    .onSubmit { if canAdd { submit() } }
                Button(action: submit) {
                    Text(adding ? "Adding…" : "Add").font(AppFont.mono(12))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .foregroundStyle(canAdd ? Palette.canvas : Palette.dim)
                        .background(canAdd ? Palette.ink : Palette.hairline)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!canAdd)
            }

            result
        }
        // Straight into the field. Opening the form is already the statement of intent —
        // making someone then click the only box in it is a step for nothing. Deferred a
        // runloop because the field doesn't exist to receive focus until after this pass.
        .onAppear { DispatchQueue.main.async { focus = .query } }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 1)
        }
    }

    var body: some View {
        Group {
            if open { openForm } else { collapsedBar }
        }
        .onAppear { if wallet.isEmpty { wallet = walletChoices.first ?? "" } }
        // Look up once typing settles. One debounce for both kinds of input keeps the
        // behaviour predictable whether you pasted an address or typed a name.
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
}


/// The "ON <network>" pills under a found coin — which chain these particular coins are
/// sitting on, when the coin is deployed on more than one.
///
/// Wrapped, because it has to be. USDC is deployed on thirty-six chains and an `HStack`
/// does not wrap: it squeezed thirty-six pills into one row's width until each was a bar
/// too narrow to show its own name, which read as a chart rather than a set of choices.
/// `FlowRow` is the same fix the wallet-colour legend needed at twenty-four.
struct NetworkChoiceRow: View {
    let names: [String]
    let selected: String
    var onPick: (String) -> Void
    /// Starts expanded only for a snapshot; the form always opens collapsed.
    var startExpanded: Bool = false

    @State private var expanded = false

    private var shown: [String] {
        expanded ? names : Network.collapsedChoices(from: names, selected: selected)
    }
    private var hiddenCount: Int { names.count - shown.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ON").font(AppFont.mono(9.5)).tracking(1.2)
                .foregroundStyle(Palette.dim)
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(shown, id: \.self) { name in
                    pill(name, on: selected == name)
                }
                // The count is on the control, so the choice to open it is made knowing
                // what it costs — "show all" alone says nothing about 3 more or 31.
                if hiddenCount > 0 {
                    Button { withAnimation(.easeOut(duration: 0.12)) { expanded = true } } label: {
                        Text("+\(hiddenCount) more").font(AppFont.mono(10.5))
                            .fixedSize()
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(Palette.dim)
                            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Show every network this coin is deployed on")
                } else if expanded {
                    Button { withAnimation(.easeOut(duration: 0.12)) { expanded = false } } label: {
                        Text("fewer").font(AppFont.mono(10.5))
                            .fixedSize()
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .foregroundStyle(Palette.dim)
                            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { expanded = startExpanded }
    }

    private func pill(_ name: String, on: Bool) -> some View {
        Button { onPick(name) } label: {
            Text(name).font(AppFont.mono(10.5))
                .fixedSize()                     // never compress the label away
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(on ? Palette.canvas : Palette.dim)
                .background(on ? Palette.ink : Palette.hairline)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
