import SwiftUI
import AppKit
import BookkeeperCore

/// Settings for the side it was opened from: the crypto side keeps wallets, hidden
/// tokens and the key; the Spending side has its bank files.
struct SettingsView: View {
    let store: PortfolioStore
    var mode: Mode = .crypto
    var spending: SpendingStore? = nil
    var importer: SpendingImporter? = nil

    @State private var coingeckoKey = ""
    @State private var hiddenExpanded = false
    @State private var confirmStartOver = false

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(HouseFont.jost(11, 500)).tracking(2).foregroundStyle(Look.shared.ink.faint)
    }

    private func valueLabel(_ usd: Decimal?) -> String {
        guard let v = usd else { return "—" }
        return Money.usd(v)
    }

    /// A wallet is just a name — every holding on it is entered by hand.
    @ViewBuilder var content: some View {
            VStack(alignment: .leading, spacing: 28) {
                if mode == .crypto || mode == .crypto2 { cryptoSections; HistorySection(store: store); TorSection() } else if mode == .spending { spendingSections }
                if let spending { appearanceSection(spending); textSizeSection(spending) }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Spending side

    @ViewBuilder private var spendingSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("BANKS")
            if let spending { BanksList(store: spending) }
            HStack(spacing: 10) {
                Text(spending.map { "\($0.transactions.count) lines" } ?? "—")
                    .font(HouseFont.jost(12)).foregroundStyle(Palette.ink)
                Spacer()
                Button { importer?.chooseFiles() } label: {
                    Text("Import CSV…").font(HouseFont.jost(12))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .foregroundStyle(Palette.ink).background(Look.shared.ink.active).clipShape(Capsule())
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(12).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Bank CSVs stay on this Mac. Drop a file on any Spending screen, or press ⇧⌘I.")
                .font(HouseFont.jost(11)).foregroundStyle(Palette.dim)
            if let spending, !spending.rules.isEmpty {
                sectionTitle("RULES").padding(.top, 10)
                RuleList(store: spending)
            }
            if let spending, !spending.accounts.isEmpty || !spending.transactions.isEmpty {
                HStack {
                    Spacer()
                    Button { confirmStartOver = true } label: {
                        Text("Start over…").font(HouseFont.jost(12)).foregroundStyle(Look.shared.ink.warm)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .overlay(Capsule().stroke(Look.shared.ink.warm.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
                .confirmationDialog("Start the bank side over?", isPresented: $confirmStartOver) {
                    Button("Delete all bank data", role: .destructive) { spending.startOver() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every bank file, entry, name and rule on this Mac goes, and Banking opens empty as on first launch. Crypto is not touched. This can't be undone.")
                }
            }
        }
    }

    // MARK: - Appearance

    /// Light or dark follows macOS by default; the top-right pill picks one by hand, which
    /// turns this off. Turning it off here keeps whatever the window shows now.
    private func appearanceSection(_ spending: SpendingStore) -> some View {
        let follows = spending.settings.theme == .system
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("LIGHT & DARK")
            HStack(spacing: 12) {
                Text("Mode").font(HouseFont.jost(13)).foregroundStyle(Look.shared.ink.text)
                Spacer()
                Seg(options: [true, false], selected: follows, help: nil) { on in
                    guard on != follows else { return }
                    spending.setTheme(on ? .system : (SystemAppearance.shared.isDark ? .dark : .light))
                } label: { on in
                    Text(on ? "match macOS" : "my pick").font(HouseFont.jost(12.5))
                }
                .environment(\.ink, Look.shared.ink)
            }
            Text(follows
                 ? "Bookkeeper turns light or dark with your Mac. Pick a mode with the pill at the top right to keep it there."
                 : "Bookkeeper stays in the mode picked with the pill at the top right, whatever your Mac does.")
                .font(HouseFont.jost(11.5)).foregroundStyle(Look.shared.ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Text size

    private func textSizeSection(_ spending: SpendingStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("TEXT SIZE")
            Seg(options: TextSize.allCases, selected: spending.settings.textSize, help: nil) { spending.setTextSize($0) }
                label: { t in
                    // Each "Aa" drawn at its own size, unscaled, so the four read as a ramp.
                    Text("Aa").font(.custom("Jost-Regular", size: 13 * t.scale))
                        .frame(minWidth: 26)
                }
                .environment(\.ink, Look.shared.ink)
        }
    }

    // MARK: - Crypto side

    @ViewBuilder private var cryptoSections: some View {
                // Wallets are added, renamed, recoloured and removed in Portfolio itself
                // (+ Wallet, and each wallet's Edit drawer) — not here as well.
                if let err = store.lastError {
                    Text(err).font(HouseFont.jost(11)).foregroundStyle(Color(hex: "#F4A07A"))
                }

                // HIDDEN TOKENS — collapsed by default so it doesn't clutter Settings
                if !store.hiddenTokenRows.isEmpty {
                    let count = store.hiddenTokenRows.count
                    DisclosureGroup(isExpanded: $hiddenExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.hiddenTokenRows, id: \.id) { item in
                            HStack {
                                Text(item.symbol).font(HouseFont.jost(14)).foregroundStyle(Palette.ink)
                                Text("hidden by you").font(HouseFont.jost(11)).foregroundStyle(Palette.dim)
                                Spacer()
                                Button { store.unhideToken(item.id) } label: {
                                    Text("Unhide").font(HouseFont.jost(11))
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .foregroundStyle(Palette.ink).background(Look.shared.ink.active).clipShape(Capsule())
                        .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10).background(Palette.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text("Taking a token out in a wallet's Edit drawer hides it when the chain reported it.")
                            .font(HouseFont.jost(11)).foregroundStyle(Palette.dim)
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            sectionTitle("HIDDEN TOKENS")
                            Text("(\(count))").font(HouseFont.jost(12)).foregroundStyle(Palette.dim)
                        }
                    }
                    .tint(Palette.dim)
                }

                // API KEYS — all optional; the app runs keyless, keys add reliability.
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("API KEY (optional)")
                    VStack(spacing: 8) {
                        keyField("CoinGecko demo key — long-tail prices", $coingeckoKey)
                        HStack {
                            Spacer()
                            Button(action: saveKeys) {
                                Text("Save").font(HouseFont.jost(12))
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .foregroundStyle(Palette.ink).background(Look.shared.ink.active)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12).background(Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text("Optional. Prices, 24h changes and logos all come from keyless sources; the CoinGecko key only helps the few tokens DefiLlama has no market for. A free demo key comes from coingecko.com → Developers → Dashboard.")
                        .font(HouseFont.jost(11)).foregroundStyle(Palette.dim)
                }

    }

    // MARK: - Both sides

    var body: some View {
        ScrollView { content }
        .background(Palette.canvas)
        .onAppear {
            coingeckoKey = store.apiKey("coingecko") ?? ""
        }
    }

    private func keyField(_ label: String, _ text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .textFieldStyle(.plain).font(HouseFont.jost(13)).foregroundStyle(Palette.ink)
    }

    private func saveKeys() {
        store.setAPIKey("coingecko", coingeckoKey.isEmpty ? nil : coingeckoKey)
        Task { await store.refresh() }
    }
}

/// Every "All like this" rule, A to Z by the bank words it looks for, with a search over
/// those words and what it makes of them, and how many entries follow it now. ✕ takes it
/// away, after asking.
struct RuleList: View {
    let store: SpendingStore
    private var ink: Ink { Look.shared.ink }
    @State private var removing: MerchantRule?
    /// The rule whose editor is open.
    @State private var opened: MerchantRule?
    @State private var query = ""

    private var shown: [MerchantRule] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.rules
            .filter { q.isEmpty || $0.pattern.localizedCaseInsensitiveContains(q) || outcome($0).localizedCaseInsensitiveContains(q) }
            .sorted { $0.pattern.localizedStandardCompare($1.pattern) == .orderedAscending }
    }

    var body: some View {
        let rules = shown
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ink.faint)
                TextField("Search rules", text: $query)
                    .textFieldStyle(.plain).font(HouseFont.jost(13)).foregroundStyle(ink.text)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(ink.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(ink.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.rule, lineWidth: 1))
            .frame(maxWidth: 320)

            scroller {
                VStack(alignment: .leading, spacing: 0) {
                    if rules.isEmpty {
                        Text("No rule matches “\(query)”.").font(HouseFont.jost(12.5)).foregroundStyle(ink.faint)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(rules.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(ink.rule).frame(height: 1) }
                        row(r)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .background(ink.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.rule, lineWidth: 1))
        }
        .sheet(item: $opened) { r in
            RuleEditor(store: store, rule: r) { opened = nil }.environment(\.ink, ink)
        }
    }

    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if SnapshotRenderer.isRendering { content() } else { ScrollView { content() } }
    }

    private func row(_ r: MerchantRule) -> some View {
        let n = store.reach(of: r)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(r.pattern).font(HouseFont.raw(12)).foregroundStyle(ink.text)
                .lineLimit(1).truncationMode(.middle)
            if let d = r.direction {
                Text(d == .moneyIn ? "money in" : "money out").font(HouseFont.jost(11)).foregroundStyle(ink.faint)
            }
            Text("→ " + outcome(r)).font(HouseFont.jost(12)).foregroundStyle(ink.muted).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(n) \(n == 1 ? "entry" : "entries")").font(HouseFont.jost(12)).foregroundStyle(ink.faint)
                .monospacedDigit()
            Button { removing = r } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(ink.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { opened = r }
        .help("Click to edit this rule")
        .confirmationDialog("Remove the rule for \(r.pattern)?",
                            isPresented: Binding(get: { removing?.id == r.id },
                                                 set: { if !$0 { removing = nil } })) {
            Button("Remove rule", role: .destructive) {
                store.removeRule(r.id)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its \(n) \(n == 1 ? "entry goes" : "entries go") back to the bank’s own name and category, and new files stop following it. Entries you changed one at a time keep their change.")
        }
    }

    /// "Pier 6 Oyster Bar · Eating out", or "Transfer" — whatever the rule sets.
    private func outcome(_ r: MerchantRule) -> String {
        var parts: [String] = []
        if let name = r.name { parts.append(name) }
        if let id = r.categoryId { parts.append(store.categories.category(id)?.name ?? id) }
        if let k = r.kind, k != .spend || parts.isEmpty { parts.append(k.rawValue.capitalized) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Settings → Tor: how prices and logos reach Bookkeeper, in plain words, with the switch.
struct TorSection: View {
    private var tor: TorService { TorService.shared }
    private var ink: Ink { Look.shared.ink }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOR").font(HouseFont.jost(11, 500)).tracking(2).foregroundStyle(ink.faint)
            HStack(spacing: 12) {
                Text("Prices & logos").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                Spacer()
                Seg(options: [true, false], selected: tor.enabled, help: nil) { tor.setEnabled($0) } label: { on in
                    Text(on ? "through Tor" : "direct").font(HouseFont.jost(12.5))
                }
                .environment(\.ink, ink)
            }
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(status).font(HouseFont.jost(12.5)).foregroundStyle(ink.text)
                if case .failed = tor.state {
                    Button { tor.restart() } label: {
                        Text("Try again").font(HouseFont.jost(12, 500)).foregroundStyle(ink.text)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(ink.pill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(tor.enabled
                 ? "Bookkeeper looks up prices, charts, coin names and logos through Tor. DefiLlama and CoinGecko see a Tor exit, not your IP address. They never get your wallets, your amounts or anything from Banking. If Tor can't connect, Bookkeeper waits with the last prices it has — it never goes direct on its own."
                 : "Bookkeeper looks up prices, charts, coin names and logos directly. DefiLlama and CoinGecko see your IP address. They never get your wallets, your amounts or anything from Banking.")
                .font(HouseFont.jost(11.5)).foregroundStyle(ink.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Banking never goes online, either way.")
                .font(HouseFont.jost(11.5)).foregroundStyle(ink.muted)
        }
        .padding(.top, 8)
    }

    private var status: String {
        switch tor.state {
        case .off: return "Direct — no Tor"
        case .starting: return "Connecting to Tor · a first start can take a minute"
        case .ready: return "Connected through Tor"
        case .failed(let why): return why
        }
    }

    private var dot: Color {
        switch tor.state {
        case .ready: return ink.up
        case .starting: return ink.muted
        case .off: return ink.faint
        case .failed: return ink.warm
        }
    }
}


/// Settings → History: how often Portfolio records what the holdings are worth — the
/// points its value chart is drawn through. Recorded on prices already fetched.
struct HistorySection: View {
    let store: PortfolioStore
    private var ink: Ink { Look.shared.ink }
    @State private var cadence = HistorySection.current

    static let key = "archiveCadence"
    static var current: HistoryStore.Cadence {
        UserDefaults.standard.string(forKey: key).flatMap(HistoryStore.Cadence.init) ?? .monthly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HISTORY").font(HouseFont.jost(11, 500)).tracking(2).foregroundStyle(ink.faint)
            HStack(spacing: 12) {
                Text("Record the value").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                Spacer()
                Seg(options: HistoryStore.Cadence.allCases, selected: cadence, help: nil) { c in
                    cadence = c
                    UserDefaults.standard.set(c.rawValue, forKey: Self.key)
                    store.archiveIfDue(c)
                } label: { c in
                    Text(c == .monthly ? "monthly" : c == .twiceMonthly ? "twice a month" : "by hand")
                        .font(HouseFont.jost(12.5))
                }
                .environment(\.ink, ink)
            }
            Text(cadence == .manual
                 ? "Only when you press Archive today. The chart at the top of Portfolio is drawn through these."
                 : "Once \(cadence == .monthly ? "a month" : "in each half of the month"), the first time Bookkeeper opens — from prices it already has, so it asks nothing extra. The chart at the top of Portfolio is drawn through these.")
                .font(HouseFont.jost(11.5)).foregroundStyle(ink.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }
}
