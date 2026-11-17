import SwiftUI
import BookkeeperCore

@main
struct BookkeeperApp: App {
    private let store: PortfolioStore
    private let spending: SpendingStore
    private let importer: SpendingImporter

    init() {
        // `--rehearse-launch <dir>` runs the launch path below against `<dir>` and exits:
        // no window, no network. `scripts/rehearse-update.sh` gates every ship on it.
        if let dir = LaunchRehearsal.requestedDirectory() {
            Self.rehearseLaunch(in: dir)
        }

        let snapshotDirectory = SnapshotRenderer.requestedDirectory

        // Before any store opens a file: the one-time copy of the v1 files, then the
        // spending folder. Not for `--snapshot`, which renders the mock and must leave
        // the data folder untouched.
        if snapshotDirectory == nil {
            DataRoot.prepareForLaunch()
        }
        store = PortfolioStore.live()

        // `--snapshot <dir>` renders the screens to PNG and exits — how the UI gets
        // reviewed without screen-recording anything.
        if let dir = snapshotDirectory {
            SnapshotRenderer.run(outputDirectory: dir)
        }

        // Before the first request: every lookup goes through Tor unless it was turned off.
        TorService.shared.apply()

        // Anything an update left beside the app — a swap cut short, or the old helper's
        // "(previous)" copy — goes, so Applications holds one Bookkeeper.
        AppSwap.clearLeftovers(for: Bundle.main.bundleURL)

        // After the snapshot exit: the live ledger is only ever opened by a real launch.
        spending = SpendingStore()
        importer = SpendingImporter(store: spending)
    }

    /// The same steps as a real launch, in the same order, up to where the window would
    /// open — then a read through each parser, so a file that no longer parses shows up.
    /// Every store lands in `dir`: the flag is the data root (`DataRoot.resolve`).
    private static func rehearseLaunch(in dir: URL) -> Never {
        guard LaunchRehearsal.isSafe(dir) else {
            print("❌ rehearsal refused: data root is \(DataRoot.url.path), not \(dir.path)")
            exit(2)
        }
        DataRoot.prepareForLaunch()
        let store = PortfolioStore.live()
        let spending = SpendingStore()
        print("🧪 rehearsed launch in \(dir.path)")
        print("   wallets \(store.hasRealWallets ? "read" : "none") · history \(store.historyPoints().count) points"
              + " · ledger \(spending.transactions.count) rows")
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, spending: spending, importer: importer, screen: .spending, opening: true)
                // Floored so the portfolio's charts always sit BESIDE the token table.
                // The row needs the table (378), a gap (48) and three breakdown rings
                // (3 × 198 + 28 = 622) — 1048 — plus the page padding (60) and the
                // navigation rail (172), which is 1280. Floored above that, and still
                // inside a 1440-wide laptop screen.
                .frame(minWidth: 1320, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        // Floor the window at the content's MINIMUM size, not its full scroll height, so
        // tall screens scroll instead of forcing a giant window.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import CSV…") { importer.chooseFiles() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}
