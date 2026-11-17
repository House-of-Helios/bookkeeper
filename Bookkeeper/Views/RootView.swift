import SwiftUI
import BookkeeperCore

enum Screen: String, CaseIterable, Identifiable {
    case dashboard = "Portfolio"
    case prices    = "Prices"
    case wallets   = "Wallets"
    case history   = "History"
    case spending  = "Spending"
    case transactions = "Transactions"
    case budget    = "Budget"
    case stocks    = "Stocks"
    case crypto2   = "Crypto 2"
    case settings  = "Settings"
    var id: String { rawValue }

    /// The bank-ledger screens, which wear `Ink` and their own chrome.
    var isLedger: Bool { self == .spending || self == .transactions || self == .budget }

    /// Budget grows in the Dev app first, beside the screens already shipped; a release
    /// build doesn't show it until it's been lived with.
    @MainActor var shown: Bool { self != .budget || Self.previews }
    @MainActor static var previews: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true || SnapshotRenderer.isRendering }

    /// The side of the app a screen lives on; nil for Settings, which sits on every side.
    var side: Mode? {
        switch self {
        case .spending, .transactions, .budget: return .spending
        case .stocks: return .stocks
        case .crypto2: return .crypto2
        case .settings: return nil
        default: return .crypto
        }
    }

    func belongs(to mode: Mode) -> Bool { side == nil || side == mode }

    /// What the dock calls the tab. Crypto 2's one tab is its portfolio — the name
    /// `Portfolio` itself already belongs to Crypto 1's first tab, so it's said here.
    var label: String { self == .crypto2 ? "Portfolio" : rawValue }

    /// The dock wears emoji, like the mode pill above it.
    var emoji: String {
        switch self {
        case .dashboard: return "money_bag"
        case .prices:    return "chart_increasing"
        case .wallets:   return "purse"
        case .history:   return "bar_chart"
        case .spending:  return "shopping_bags"
        case .transactions: return "ledger"
        case .budget:    return "seedling"
        case .stocks:    return "chart_increasing"
        case .crypto2:   return "money_bag"
        case .settings:  return "gear"
        }
    }
}

/// The two halves of the app, picked from the pill at the top: what you hold, and where
/// the money goes. Each keeps its own dock of screens below.
enum Mode: String, CaseIterable, Identifiable {
    /// The bank side — Spending and Transactions. Named for what it reads, not one screen.
    case spending = "Banking"
    case crypto = "Crypto"
    /// Crypto laid out like Banking — grown beside the old side, not over it.
    case crypto2 = "Crypto 2"
    case stocks = "Stocks"
    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .spending: return "bank"
        case .crypto: return "coin"
        case .crypto2: return "coin"
        case .stocks: return "chart_increasing"
        }
    }
    /// What the pill shows. One crypto side now: the redesign, named Crypto. The first
    /// Crypto's screens are shed — still in the code, no longer on the pill.
    static var shown: [Mode] { [.spending, .crypto2, .stocks] }
    var label: String { self == .crypto2 ? "Crypto" : rawValue }

    var home: Screen {
        switch self {
        case .spending: return .spending
        case .crypto: return .dashboard
        case .crypto2: return .crypto2
        case .stocks: return .stocks
        }
    }
}

/// The window: the current screen, full-bleed, with a floating pill dock over its
/// bottom edge to switch screens.
///
/// This used to be a `NavigationSplitView`, which on macOS decides for itself that a
/// narrowing window means the sidebar should collapse — so resizing the app made the
/// tabs vanish with no way to bring them back. It became a fixed left rail instead, and
/// then this: a dock that never collapses because it was never a sidebar to begin with.
struct ReportRequest: Identifiable {
    let id = UUID()
    var note = ""
}

struct RootView: View {
    @State private var screen: Screen
    @State private var status: UpdateChecker.Status = .offline(why: "")
    /// The change log on screen, opened from the update pill.
    @State private var changelog: UpdateInfo?
    /// The report sheet, from Settings or after a run that ended badly.
    @State private var report: ReportRequest?
    private var updater: Updater { .shared }
    /// Transactions' search + filter, kept here so Spending's review pill can open that
    /// screen already filtered to To review.
    @State private var transactions = TransactionsModel()
    /// The side Settings was opened from, and the screen each side was last left on.
    @State private var lastMode: Mode = .crypto2
    @State private var lastScreen: [Mode: Screen] = [:]
    @Namespace private var modeSpace
    @Namespace private var dockSpace
    /// For `--snapshot`: no ScrollViews, which `ImageRenderer` can't see into.
    var rendering = false
    /// The way in — the mark, then the landing's three doors — until a side is picked.
    @State private var opening: OpeningView.Stage?
    @State private var window: NSWindow?
    /// Where the window sat before the splash took it to the middle of the screen.
    @State private var homeFrame: NSRect?

    private var update: UpdateInfo? { status.update }
    let store: PortfolioStore
    let spending: SpendingStore
    let importer: SpendingImporter

    init(store: PortfolioStore, spending: SpendingStore, importer: SpendingImporter, screen: Screen = .crypto2,
         rendering: Bool = false, opening: Bool = false, update: UpdateInfo? = nil) {
        self.store = store; self.spending = spending; self.importer = importer; self.rendering = rendering
        if let update { _status = State(initialValue: .available(update)) }
        _screen = State(initialValue: screen)
        // A snapshot can't wait out the splash, so it starts on the landing.
        if opening { _opening = State(initialValue: rendering ? .landing : .splash) }
        if let side = screen.side { _lastMode = State(initialValue: side) }
    }

    private func sayFailure(_ why: String?) {
        guard let why else { return }
        Toaster.shared.say("⚠️ \(why)", for: 10)
        spending.saveFailure = nil
    }

    private func checkForUpdate() async {
        status = await Updater.check(current: Self.currentVersion)
        // Fetched ahead, so Install only has to swap and restart.
        if let u = status.update { updater.prepare(u) }
    }

    /// The theme in force, for the whole window — `Look.shared` carries it to the v1 screens.
    private var ink: Ink { Ink.resolve(spending.settings.theme, systemIsDark: SystemAppearance.shared.isDark) }

    // MARK: - Top bar: name · side · theme

    private var mode: Mode {
        screen.side ?? lastMode
    }

    /// Switching sides returns to the screen last open on that side, not its first tab.
    private func switchMode(to m: Mode) {
        guard m != mode else { return }
        lastScreen[mode] = screen
        lastMode = m
        withAnimation(.easeInOut(duration: 0.22)) { screen = lastScreen[m] ?? m.home }
    }

    /// One look for every pill in the bars: a track, the chosen option lifted onto it, the
    /// lift sliding between options.
    private func pill<T: Hashable, L: View>(_ options: [T], on: T?, space: Namespace.ID, id: String,
                                           pick: @escaping (T) -> Void,
                                           @ViewBuilder label: @escaping (T) -> L) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let lit = o == on
                Button { pick(o) } label: {
                    label(o)
                        .foregroundStyle(lit ? ink.text : ink.muted)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background {
                            if lit { Capsule().fill(ink.active).matchedGeometryEffect(id: id, in: space) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(ink.pill, in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
    }

    private var wordmark: some View {
        HStack(spacing: 9) {
            Image("app-mark").resizable().interpolation(.high).frame(width: 20, height: 20)
            Text("Bookkeeper").font(HouseFont.fraunces(17)).foregroundStyle(ink.text)
            Image("app-mark").resizable().interpolation(.high).frame(width: 20, height: 20)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(ink.pill, in: Capsule())
        // Installing: a ring closes round the pill as the new build comes over.
        .overlay {
            if let u = updater.installing {
                ZStack {
                    Capsule().stroke(ink.track, lineWidth: 2.5)
                    Capsule().trim(from: 0, to: max(0.02, updater.progress))
                        .stroke(Self.updateGreen, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .animation(.linear(duration: 0.25), value: updater.progress)
                }
                .padding(-4)
                .help("Installing Bookkeeper \(u.version) — \(Int(updater.progress * 100))%")
            }
        }
    }

    static let updateGreen = Color(hex: "#7BA05B")

    /// In the wordmark's place while a newer build waits: opens the change log.
    private func updatePill(_ u: UpdateInfo) -> some View {
        Button { changelog = u } label: {
            HStack(spacing: 9) {
                Emoji(name: "inbox_tray", size: 20)
                Text("Update to \(u.version)").font(HouseFont.jost(14, 600)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Self.updateGreen, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("See what's new and install")
    }

    @ViewBuilder private var brand: some View {
        if let u = update, updater.installing == nil { updatePill(u) } else { wordmark }
    }

    private var modePill: some View {
        pill(Mode.shown, on: mode, space: modeSpace, id: "mode", pick: switchMode) { m in
            HStack(spacing: 7) {
                Emoji(name: m.emoji, size: 17)
                Text(m.label).font(HouseFont.jost(13))
            }
        }
    }

    /// Light · dark · black. The window follows macOS until one is picked; picking the lit
    /// one again hands it back to macOS.
    private var themePill: some View {
        let lit: ThemeChoice = spending.settings.theme == .system
            ? (SystemAppearance.shared.isDark ? .dark : .light) : spending.settings.theme
        return pill([ThemeChoice.light, .dark, .black], on: lit, space: modeSpace, id: "theme") { t in
            spending.setTheme(t == spending.settings.theme ? .system : t)
        } label: { t in
            switch t {
            case .light: Emoji(name: "hoh_mode_light", size: 18)
            case .dark:  Emoji(name: "hoh_mode_dark", size: 18)
            default:     Text("black").font(HouseFont.jost(12.5)).frame(height: 18)
            }
        }
        .help(spending.settings.theme == .system ? "Following macOS" : "Click the lit one to follow macOS")
    }

    /// Fixed above every screen and opaque, so nothing scrolls up behind it.
    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                brand
                Spacer()
                if screen.side == .crypto || screen.side == .crypto2 { statusCluster }
                themePill
            }
            modePill
        }
        .padding(.horizontal, 16)
        .padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(ink.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(ink.rule).frame(height: 1) }
    }

    // MARK: - Dock

    private var dock: some View {
        pill(Screen.allCases.filter { $0.belongs(to: mode) && $0.shown }, on: screen, space: dockSpace, id: "dock") { s in
            screen = s
        } label: { s in
            HStack(spacing: 7) {
                Emoji(name: s.emoji, size: 17)
                Text(s.label).font(HouseFont.jost(13))
            }
            .padding(.vertical, 2)
        }
        .shadow(color: ink.shadow, radius: 14, y: 6)
        .padding(.bottom, 18)
    }

    /// Refresh + "last updated", in the top bar beside the theme on the crypto side.
    private var statusCluster: some View {
        HStack(spacing: 8) {
            if let updated = store.lastUpdated, !store.isLoading {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(relative(updated)).font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                }
            }
            Button {
                Task { await store.refresh(force: true); await IconCache.shared.prefetch(store.visibleTokens) }
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(ink.muted)
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 6)
    }

    var body: some View {
        ZStack {
            // Not drawn under the splash, which shows through to the desktop.
            if opening != .splash {
                VStack(spacing: 0) {
                    topBar
                    current
                }
            }
            if let opening {
                OpeningView(stage: opening, update: update, onInstall: { if let u = update { updater.install(u) } },
                            installing: updater.installing == nil ? nil : updater.progress) {
                    if let w = window {
                        // Back to where the window lives, then solid again for the landing.
                        if let homeFrame { w.setFrame(homeFrame, display: true) }
                        w.seeThrough(false, ground: NSColor(ink.ground))
                    }
                    withAnimation(.easeInOut(duration: 0.45)) { self.opening = .landing }
                } onPick: { m in
                    lastMode = m
                    screen = lastScreen[m] ?? m.home
                    withAnimation(.easeInOut(duration: 0.35)) { self.opening = nil }
                }
                .environment(\.ink, ink)
                .transition(.opacity)
            }
        }
        .background(opening == .splash ? .clear : ink.ground)
        .background(WindowReader { w in
            window = w
            guard opening == .splash && !rendering else { return }
            w.seeThrough(true, ground: NSColor(ink.ground))
            // The splash opens in the middle of the screen, wherever the window was left —
            // a beat later too, after macOS has put back the window's saved place.
            DispatchQueue.main.async {
                if homeFrame == nil { homeFrame = w.frame }
                w.centreOnScreen()
            }
        })
        .onAppear { Look.shared.ink = ink; Look.shared.textScale = spending.settings.textSize.scale }
        .onChange(of: ink) { _, new in Look.shared.ink = new }
        .onChange(of: spending.settings.textSize) { _, new in Look.shared.textScale = new.scale }
    }

    @ViewBuilder private var current: some View {
        Group {
            switch screen {
            case .dashboard: DashboardView(store: store)
            case .prices:    ScrollView { PricesLedger(store: store) }
            case .wallets:   WalletsLedger(store: store)
            case .history:   ScrollView { HistoryLedger(store: store) }
            case .spending:
                SpendingView(store: spending, importer: importer, rendering: rendering) {
                    transactions.query = ""
                    transactions.filter = .review
                    screen = .transactions
                }
            case .transactions:
                TransactionsView(store: spending, importer: importer, model: transactions, rendering: rendering)
            case .budget:
                BudgetView(store: spending, rendering: rendering)
            case .stocks:    StocksSoon()
            case .crypto2:   CryptoTwoView(store: store, rendering: rendering).environment(\.ink, ink)
            case .settings:  SettingsView(store: store, mode: mode, spending: spending, importer: importer) { report = ReportRequest() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Palette.canvas)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                // Crypto's refresh, shown on the crypto side only — Banking never goes online.
                if store.isLoading && (screen.side == .crypto || screen.side == .crypto2) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.surface.opacity(0.95))
                }
                dock
            }
        }
        // The import summary and the edit drawer's "✓ 12 lines now …", over any screen.
        .overlay(alignment: .bottom) { ToastView().environment(\.ink, ink) }
        .animation(.easeOut(duration: 0.25), value: Toaster.shared.message)
        // A file no recipe fits: teach it once.
        .sheet(item: Bindable(importer).teaching, onDismiss: importer.resumeTeaching) { req in
            TeachBankSheet(importer: importer, request: req)
                .environment(\.ink, ink)
                .environment(\.colorScheme, ink.colorScheme)
                .frame(width: TeachBankSheet.width + 80, height: 740)
        }
        // Recognised files: which account each goes to, before anything is imported.
        .sheet(item: Bindable(importer).planning, onDismiss: importer.cancelPlan) { plan in
            ImportPlanSheet(importer: importer, plan: plan)
                .environment(\.ink, ink)
                .environment(\.colorScheme, ink.colorScheme)
        }
        // A save that didn't reach the disk, or a file that wouldn't read at launch, is
        // said, not lost quietly.
        .onChange(of: spending.saveFailure) { _, why in sayFailure(why) }
        .onAppear { sayFailure(spending.saveFailure) }
        // An import from the menu while on a crypto screen lands on the ledger.
        .onChange(of: importer.generation) { _, _ in if !screen.isLedger { screen = .spending } }
        .sheet(item: $report) { r in
            ReportSheet(facts: ReportSheet.facts(store: store, spending: spending, note: r.note)) { report = nil }
                .environment(\.ink, ink)
                .environment(\.colorScheme, ink.colorScheme)
        }
        .onChange(of: opening) { _, now in
            // The landing has settled: say so if the last run did not end cleanly.
            guard now == .landing, !rendering, LastRun.endedBadly else { return }
            LastRun.endedBadly = false
            report = ReportRequest(note: "Bookkeeper closed unexpectedly last time.")
        }
        .sheet(item: $changelog) { u in
            UpdateSheet(update: u, current: Self.currentVersion, rendering: rendering) {
                changelog = nil
            } onInstall: {
                changelog = nil
                updater.install(u)
            }
            .environment(\.ink, ink)
            .environment(\.colorScheme, ink.colorScheme)
        }
        .preferredColorScheme(ink.colorScheme)
        // Tor coming back (Try again, or turned on in Settings): fetch at once.
        .onChange(of: TorService.shared.state) { _, now in
            guard now == .off || (now == .ready && TorService.shared.readies > 1) else { return }
            Task { await store.refresh(force: true); await IconCache.shared.prefetch(store.visibleTokens) }
        }
        .task {
            // Open on what's saved, then wait for Tor (seconds once its cache is warm)
            // before asking for anything — a request before then would only fail.
            await store.refresh()
            await TorService.shared.settled()
            // Refresh on launch, then auto-refresh every 5 minutes.
            while !Task.isCancelled {
                // The scheduled pass is what keeps prices current — forced, so it always
                // fetches, while everything else prices from the cache.
                await store.refresh(force: true)
                await IconCache.shared.prefetch(store.visibleTokens)
                // A history mark, when one is due (Settings → History), on the prices just fetched.
                store.archiveIfDue(HistorySection.current)
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
        .task {
            // GitHub, on launch and then every hour. Tor may still be coming up at launch
            // and requests fail until it is, so an offline answer is retried a few times.
            for _ in 0..<6 {
                await checkForUpdate()
                guard case .offline = status else { break }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                await checkForUpdate()
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "updated just now" }
        if s < 3600 { return "updated \(s / 60)m ago" }
        return "updated \(s / 3600)h ago"
    }
}

/// Stocks: the third side, not built yet.
struct StocksSoon: View {
    private var ink: Ink { Look.shared.ink }
    var body: some View {
        VStack(spacing: 14) {
            Emoji(name: "chart_increasing", size: 64)
            Text("Stocks").font(HouseFont.fraunces(30)).foregroundStyle(ink.text)
            Text("Coming soon").font(HouseFont.jost(15)).foregroundStyle(ink.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ink.ground)
    }
}
