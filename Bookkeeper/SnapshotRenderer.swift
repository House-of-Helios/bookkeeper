import SwiftUI
import AppKit
import BookkeeperCore

/// Renders the real screens to PNG files offscreen, so the UI can be reviewed without
/// screen-recording anything. `ImageRenderer` draws the same SwiftUI views the app shows
/// into an image buffer inside this process — nothing outside the app is observed or
/// captured.
///
/// Run it with:  `Bookkeeper.app/Contents/MacOS/Bookkeeper --snapshot <output-dir>`
///
/// It uses the mock portfolio, never the real wallets, so the images are safe to share
/// and don't depend on the network.
@MainActor
enum SnapshotRenderer {

    /// True while rendering offscreen. Interactive affordances that draw badly there —
    /// `.draggable` paints a placeholder instead of the view — check this and stand down.
    private(set) static var isRendering = false


    /// Screens worth reviewing, with the height each one needs at full content.
    private static let sizes: [(name: String, size: CGSize)] = [
        ("portfolio", CGSize(width: 1320, height: 1450)),
        ("prices",    CGSize(width: 900, height: 900)),
        ("wallets",   CGSize(width: 1320, height: 1100)),
        ("history",   CGSize(width: 1320, height: 1000)),
        // The index in Edit, with one column's ✕ pressed — the mock archive holds four
        // names that are not current wallets, which is exactly what Edit is for.
        ("history-edit", CGSize(width: 1320, height: 1000)),
        ("settings",  CGSize(width: 1320, height: 900)),
        // The add-token network picker, at the width it actually gets inside a wallet
        // module and with a real widely-deployed coin's chain list. Narrow on purpose:
        // the bug was a row that could not wrap, and a wide canvas would hide it.
        ("addtoken",     CGSize(width: 420, height: 120)),
        ("addtoken-all",  CGSize(width: 420, height: 300)),
        // The floating bottom dock, at a real window size — this is what replaced the
        // left rail, so it's worth a permanent check the same way addtoken's row is.
        ("dock",      CGSize(width: 1200, height: 800)),
        // Spending, at the mockup's own render size (1440 × 1150) so the two sit side by
        // side: the overview (dark), zoomed into Groceries (dark), the same zoom on the
        // light ground (`#light-drill`), and the category editor open (`#cat`).
        ("landing",        CGSize(width: 1440, height: 900)),
        ("landing-update", CGSize(width: 1440, height: 900)),
        ("spending",       CGSize(width: 1440, height: 1150)),
        ("spending-drill", CGSize(width: 1440, height: 1150)),
        ("spending-light", CGSize(width: 1440, height: 1150)),
        ("spending-edit",  CGSize(width: 1440, height: 1150)),
        // Transactions (`#tx`), the edit drawer on a Mr. Kale line with "All like this"
        // chosen (`#edit`), the teach-a-bank sheet on a headerless file (`#teach`), and
        // the list on the light ground (`#light-tx`).
        ("transactions",       CGSize(width: 1440, height: 1150)),
        ("transactions-edit",  CGSize(width: 1440, height: 1150)),
        ("teach",              CGSize(width: 1440, height: 1150)),
        ("transactions-light", CGSize(width: 1440, height: 1150)),
        // The crypto side on the light ground, now that the theme pill covers it too.
        ("portfolio-light", CGSize(width: 1320, height: 1450)),
        ("wallets-light",   CGSize(width: 1320, height: 1100)),
        ("history-light",   CGSize(width: 1320, height: 1000)),
        ("prices-light",    CGSize(width: 900, height: 900)),
        // The whole window with its top bar, on each side.
        ("window-crypto",   CGSize(width: 1440, height: 1000)),
        ("window-spending", CGSize(width: 1440, height: 1150)),
        // A newer build waiting: the pill in the wordmark's place, its change log, the ring.
        ("update-pill",     CGSize(width: 1440, height: 400)),
        ("update-sheet",    CGSize(width: 480, height: 520)),
        // The feedback sheet, with made-up facts and log lines.
        ("report-light",    CGSize(width: 560, height: 800)),
        ("update-ring",     CGSize(width: 1440, height: 400)),
        // Income on the same ring, and Settings from the Spending side with its file log.
        ("spending-income",   CGSize(width: 1440, height: 1150)),
        ("spending-total",    CGSize(width: 1440, height: 1150)),
        // A merchant row tapped: its drawer, set to change them all, its months above.
        ("spending-merchant", CGSize(width: 1440, height: 1150)),
        // Crypto 2: the overview on tokens, zoomed into the biggest token, and on wallets.
        ("crypto2",        CGSize(width: 1440, height: 1150)),
        ("crypto2-drill",  CGSize(width: 1440, height: 1150)),
        ("crypto2-wallet", CGSize(width: 1440, height: 1150)),
        ("crypto2-wallets", CGSize(width: 1440, height: 1150)),
        ("crypto2-networks", CGSize(width: 1440, height: 1150)),
        ("crypto2-network", CGSize(width: 1440, height: 1150)),
        ("crypto2-new", CGSize(width: 1440, height: 1150)),
        ("crypto2-edit", CGSize(width: 1440, height: 1150)),
        ("crypto2-usdc", CGSize(width: 1440, height: 1150)),
        ("crypto2-color", CGSize(width: 1440, height: 1150)),
        ("crypto2-newwallet", CGSize(width: 1440, height: 1150)),
        ("crypto2-price", CGSize(width: 1440, height: 1150)),
        ("settings-spending", CGSize(width: 1320, height: 900)),
        // Budget (Dev app only): the month's flow band over each family's nested rings.
        ("budget",       CGSize(width: 1440, height: 1500)),
        ("budget-light", CGSize(width: 1440, height: 1500)),
        // The plan editor (a popover live, drawn flat here) beside a ring's hover card.
        ("budget-parts", CGSize(width: 700, height: 520)),
    ]

    static func run(outputDirectory: String) {
        let dir = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        isRendering = true
        let store = PortfolioStore.mock()
        let (spending, importer) = SpendingMock.make()

        for (name, size) in sizes {
            let ledger = name.hasPrefix("spending") || name.hasPrefix("transactions") || name == "teach"
                || name.hasPrefix("budget")
                || name == "window-spending" || name == "settings-spending"
            // BOOKKEEPER_SNAPSHOT_LIGHT=1 renders every screen on the light ground (the docs default).
            let light = name.hasSuffix("-light") || ProcessInfo.processInfo.environment["BOOKKEEPER_SNAPSHOT_LIGHT"] == "1"
            spending.setTheme(light ? .light : (ledger ? .dark : .black))
            let ink = Ink.resolve(spending.settings.theme, systemIsDark: true)
            Look.shared.ink = ink
            let screen = Group {
                switch name {
                case "settings": SettingsView(store: store).content
                case "settings-spending":
                    SettingsView(store: store, mode: .spending, spending: spending, importer: importer).content
                case "prices", "prices-light":   PricesLedger(store: store).content
                case "wallets", "wallets-light":  WalletsLedger(store: store).content
                case "history", "history-light":  HistoryLedger(store: store).content
                case "window-crypto":
                    RootView(store: store, spending: spending, importer: importer, rendering: true)
                case "landing-update":
                    OpeningView(stage: .landing,
                                update: UpdateInfo(version: "2.0.1", notes: "Updates reopen the app on their own; a newer build shows here."),
                                onSettled: {}, onPick: { _ in })
                        .environment(\.ink, Ink.resolve(spending.settings.theme, systemIsDark: true))
                case "landing":
                    RootView(store: store, spending: spending, importer: importer, rendering: true, opening: true)
                case "update-pill":
                    RootView(store: store, spending: spending, importer: importer, screen: .spending, rendering: true,
                             update: Self.sampleUpdate)
                case "update-sheet":
                    UpdateSheet(update: Self.sampleUpdate, current: "2.0.12", rendering: true, onLater: {}, onInstall: {})
                        .environment(\.ink, Ink.resolve(spending.settings.theme, systemIsDark: true))
                case "report-light":
                    ReportSheet(facts: Self.sampleFacts, rendering: true, onClose: {})
                        .environment(\.ink, ink)
                case "update-ring":
                    let _ = Updater.shared.showForSnapshot(Self.sampleUpdate, progress: 0.62)
                    RootView(store: store, spending: spending, importer: importer, screen: .spending, rendering: true,
                             update: Self.sampleUpdate)
                case "window-spending":
                    RootView(store: store, spending: spending, importer: importer, screen: .spending, rendering: true)
                case "history-edit":
                    HistoryLedger(store: store, editing: true, confirmingColumn: "Testing").content
                case "addtoken":
                    NetworkChoiceRow(names: MockData.usdcNetworks, selected: "HyperEVM") { _ in }
                        .padding(14)
                case "addtoken-all":
                    NetworkChoiceRow(names: MockData.usdcNetworks, selected: "HyperEVM",
                                     onPick: { _ in }, startExpanded: true)
                        .padding(14)
                case "dock":     RootView(store: store, spending: spending, importer: importer)
                case "spending", "spending-drill", "spending-light", "spending-edit", "spending-income",
                     "spending-total", "spending-merchant":
                    SpendingView(store: spending, importer: importer,
                                 model: spendingModel(name, spending), rendering: true)
                case "crypto2-new":
                    // A wallet of the user's own added and no archive yet: the strip is empty.
                    CryptoTwoView(store: newWalletStore(), rendering: true).environment(\.ink, ink)
                case "crypto2", "crypto2-drill", "crypto2-wallet", "crypto2-wallets", "crypto2-networks", "crypto2-network", "crypto2-edit", "crypto2-usdc", "crypto2-color", "crypto2-newwallet", "crypto2-price":
                    CryptoTwoView(store: store, model: cryptoTwoModel(name, store), rendering: true).environment(\.ink, ink)
                case "transactions", "transactions-edit", "transactions-light":
                    TransactionsView(store: spending, importer: importer,
                                     model: transactionsModel(name, spending), rendering: true)
                case "budget", "budget-light":
                    BudgetView(store: spending, rendering: true)
                case "budget-parts":
                    budgetParts(spending)
                case "teach":
                    TeachBankSheet(importer: importer, request: SpendingMock.teachRequest(), rendering: true)
                        .environment(\.ink, light ? ink : .xmrangeDark)
                default:         PortfolioLedger(store: store) { _ in }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Theme.ground)
            .preferredColorScheme(ink.colorScheme)
            .environment(\.colorScheme, ink.colorScheme)

            let renderer = ImageRenderer(content: screen)
            renderer.scale = 2                       // retina, so text is judged fairly
            renderer.proposedSize = .init(size)

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
                continue
            }
            let out = dir.appendingPathComponent("\(name).png")
            try? png.write(to: out)
            print(out.path)
        }
        exit(0)
    }

    @ViewBuilder private static func budgetParts(_ store: SpendingStore) -> some View {
        if let m = store.budgetMonths.last {
            let lines = store.budget(for: m).groups.flatMap(\.lines)
            HStack(alignment: .top, spacing: 40) {
                if let g = lines.first(where: { $0.category.id == "groc" }) { PlanEditor(store: store, line: g, month: m) }
                if let e = lines.first(where: { $0.category.id == "eat" }) { BudgetTip(store: store, line: e, month: m) }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.resolve(store.settings.theme, systemIsDark: true).ground)
            .environment(\.ink, Ink.resolve(store.settings.theme, systemIsDark: true))
        }
    }

    /// The screen state each Spending render starts in.
    private static func spendingModel(_ name: String, _ store: SpendingStore) -> SpendingScreenModel {
        let m = SpendingScreenModel(store: store)
        switch name {
        case "spending-drill", "spending-light": m.drill = "groc"; m.focus = "groc"
        case "spending-edit": m.editing = "eat"
        case "spending-income": m.lens = .income
        case "spending-total": m.lens = .all
        case "spending-merchant":
            m.drill = "groc"; m.focus = "groc"
            if let top = m.merchants("groc").first {
                m.editingMerchant = true
                m.editingLine = m.newestLine(merchant: top.name, in: "groc")?.id
            }
        default: break
        }
        return m
    }

    private static func newWalletStore() -> PortfolioStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-snap-\(UUID().uuidString)")
        let secret = SecretStore(directory: dir)
        for w in MockData.wallets + [Wallet(id: "Testing 3", nickname: "Testing 3")] {
            secret.addWallet(WalletSecret(nickname: w.nickname))
        }
        return PortfolioStore(wallets: MockData.wallets + [Wallet(id: "Testing 3", nickname: "Testing 3")],
                              holdings: MockData.holdings, prices: MockData.prices,
                              secret: secret, history: HistoryStore(directory: dir))
    }

    private static func cryptoTwoModel(_ name: String, _ store: PortfolioStore) -> CryptoTwoModel {
        let m = CryptoTwoModel(store: store)
        if name == "crypto2-drill" { m.drill = m.slices.first?.id }
        if name == "crypto2-wallet" { m.lens = .wallet; m.drill = m.slices.first?.id }
        if name == "crypto2-wallets" { m.lens = .wallet }
        if name == "crypto2-networks" { m.lens = .network }
        if name == "crypto2-usdc" { m.drill = "t:USDC" }
        if name == "crypto2-price" { m.lens = .wallet; m.pricing = m.rows.max { $0.value < $1.value }?.token }
        if name == "crypto2-newwallet" { m.lens = .wallet; m.addingWallet = true }
        if name == "crypto2-color" {
            m.drill = m.slices.first?.id
            if let t = m.slices.first?.token { m.editingColor = .token(t) }
        }
        if name == "crypto2-edit" { m.lens = .wallet; m.editingWallet = store.orderedWallets.first?.id }
        if name == "crypto2-network" { m.lens = .network; m.drill = m.slices.dropFirst().first?.id }
        return m
    }

    /// The Transactions state each render starts in: the edit one opens the drawer on the
    /// newest Mr. Kale line with "All like this" chosen, as `#edit` does.
    private static func transactionsModel(_ name: String, _ store: SpendingStore) -> TransactionsModel {
        let m = TransactionsModel()
        if name == "transactions-edit" {
            m.editing = store.transactions.last { $0.displayName == "Mr. Kale" }?.id
            m.editStartsAllLikeThis = true
        }
        return m
    }

    /// `--snapshot <dir>` on the command line, if present.
    static var requestedDirectory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

extension SnapshotRenderer {
    static let sampleUpdate = UpdateInfo(
        version: "2.0.14", notes: "Updates fetch ahead and install from the Bookkeeper pill.",
        history: [UpdateNote(version: "2.0.14", notes: "Updates fetch ahead and install from the Bookkeeper pill."),
                  UpdateNote(version: "2.0.13", notes: "Updates install faster.")])
}

extension SnapshotRenderer {
    static let sampleFacts = ProblemReport.Facts(
        version: "2.0.22", macOS: "15.1.0", arch: "arm64", theme: "light", torOn: true, wallets: 3, banks: 2,
        logLines: ["12:01:03 launch 2.0.22", "12:01:04 tor starting", "12:01:19 tor ready",
                   "12:01:20 prices fetched 41 tokens", "12:02:44 save failed: disk full"],
        note: "The chart stayed empty after I added a wallet.")
}
