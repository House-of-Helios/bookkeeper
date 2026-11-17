import Foundation
import BookkeeperCore

/// A Spending ledger for `--snapshot`, seeded at init — an offscreen render can't wait
/// for callbacks. Built in a fresh temp folder from the Core test fixtures (synthetic
/// bank exports), never from the live data folder or `_DevData/`.
enum SpendingMock {

    /// The repo's synthetic exports, found from this source file's own path — so the
    /// fake CSVs stay in the test fixtures and never ride inside a shipped app.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BookkeeperCore/Tests/BookkeeperCoreTests/Fixtures/bank", isDirectory: true)
    }

    /// One person's three accounts, not all nine fixture banks at once — nine copies of
    /// the same fake life made every total nine-fold and Groceries half the ring. The
    /// two overlapping Chase exports ride along, so dedupe is in the picture too.
    private static let keep = ["chase_card", "chase_checking", "apple_card"]

    static func make() -> (SpendingStore, SpendingImporter) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bookkeeper-snapshot-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let files = ((try? fm.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { f in f.pathExtension == "csv" && keep.contains { f.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files { try? fm.copyItem(at: f, to: inbox.appendingPathComponent(f.lastPathComponent)) }

        let store = SpendingStore(directory: root.appendingPathComponent("spending", isDirectory: true))
        let importer = SpendingImporter(store: store)
        importer.run(((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent })
        teach(store)
        lastDrop(store)
        return (store, importer)
    }

    /// The merchants a Helios would have named by now — one "All like this" each, the
    /// same rule the edit drawer makes.
    private static let taught: [(pattern: String, name: String, category: String)] = [
        ("GOWANUS GRIND", "Gowanus Grind", "cafe"), ("LANTERN BEAN", "Lantern Bean", "cafe"),
        ("PROSPECT GREENS", "Prospect Greens", "groc"), ("BODEGA MOON", "Bodega Moon", "groc"),
        ("HALSEY STREET GROCERS", "Halsey St Grocers", "groc"), ("MR KALE", "Mr. Kale", "groc"),
        ("CORNER CO-OP", "Corner Co-op", "groc"),
        ("CITY TRANSIT FARE", "City Transit", "move"), ("YELLOWBIRD RIDES", "Yellowbird Rides", "move"),
        ("SLICE SHOP", "Ferrante’s Slice", "eat"), ("ATLANTIC TAQUERIA", "Atlantic Taqueria", "eat"),
        ("NINE DRAGONS NOODLE", "Nine Dragons", "eat"), ("OYSTER BAR", "Oyster Bar", "eat"),
        ("STREAMLY", "Streamly", "subs"), ("SONGBIRD MUSIC", "Songbird Music", "subs"),
        ("STARLIGHT CINEMA", "Starlight Cinema", "fun"), ("VELVET ROOM JAZZ", "Velvet Room", "fun"),
        ("FULTON STREET BOOKS", "Fulton St Books", "shop"), ("BERGEN HARDWARE", "Bergen Hardware", "shop"),
        ("MR KALEIDOSCOPE", "Mr. Kaleidoscope", "shop"),
        ("SMITH ST PHARMACY", "Smith St Pharmacy", "heal"), ("IRONWORKS GYM", "Ironworks Gym", "heal"),
        ("BRIGHTSTONE PROPERTY", "Brightstone — rent", "home"), ("PIGEON MOBILE", "Pigeon Mobile", "util"),
        ("BRIGHTLINE FIBER", "Brightline Fiber", "util"),
    ]

    /// The fixtures carry no open questions, so the newest drop brings two, as in the
    /// mockup: money to a person, which the import can't call spending or a transfer.
    private static func lastDrop(_ store: SpendingStore) {
        guard let checking = store.accounts.first(where: { $0.recipeId == "chase-checking" }) else { return }
        let csv = """
        Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #
        DEBIT,10/29/2026,ZELLE TO J RIVERA 8812,-60.00,QUICKPAY_DEBIT,27100.00,
        DEBIT,10/30/2026,VENMO PAYMENT 1044 WEB ID,-24.00,ACH_DEBIT,27076.00,
        """
        _ = try? store.importCSV(text: csv, accountId: checking.id)
    }

    /// The teach sheet's file: a credit union's headerless export — Wells Fargo's five
    /// columns plus a running balance, so no built-in recipe claims it. Synthetic, made
    /// here: 214 rows walking back from mid-October.
    static func teachRequest() -> TeachRequest {
        let lead: [(String, String)] = [
            ("10/14/2026", "-23.18|MR KALE BROOKLYN NY 0042 POS"), ("10/13/2026", "-6.40|SQ *NINTH STREET GRIND"),
            ("10/12/2026", "-2.90|METRO FARE OMNY TAP"), ("10/11/2026", "3200.00|PAYROLL DIRECT DEP HOUSE OF HELIOS"),
            ("10/10/2026", "-500.00|ONLINE TRANSFER TO SAV 4471"),
        ]
        let filler = ["-4.75|LITTLE OWL COFFEE 02", "-31.20|GREENPOINT GREENS MKT", "-14.33|SQ *FERRY SLICE",
                      "-2.90|METRO FARE NYCT", "-18.00|LANTERN CINEMA BKLYN", "-9.49|CORNER BODEGA DELI 11222"]
        var balance = 4210.55
        var lines: [String] = []
        for i in 0..<214 {
            let (date, rest): (String, String)
            if i < lead.count { (date, rest) = lead[i] }
            else {
                let day = Day(2026, 10, 9).adding(days: -(i - lead.count) / 2)
                date = String(format: "%02d/%02d/%04d", day.month, day.day, day.year)
                rest = filler[i % filler.count]
            }
            let parts = rest.split(separator: "|").map(String.init)
            balance -= Double(parts[0]) ?? 0
            lines.append("\(date),\(parts[0]),*,,\(parts[1]),\(String(format: "%.2f", balance))")
        }
        let text = lines.joined(separator: "\n") + "\n"
        return TeachRequest(file: .init(name: "export_2026-10.csv", data: Data(text.utf8), text: text),
                            suggestedName: "My Credit Union")
    }

    private static func teach(_ store: SpendingStore) {
        for t in taught {
            guard let first = store.matches(for: t.pattern, match: .contains).first else { continue }
            store.apply(edit: TransactionEdit(name: t.name, categoryId: t.category), to: first.id,
                        scope: .allLikeThis(pattern: t.pattern, match: .contains, unticked: []))
        }
        // Pay, named once and counted as income.
        if let pay = store.matches(for: "HALCYON LABS PAYROLL", match: .contains).first {
            store.apply(edit: TransactionEdit(name: "Payroll", categoryId: "pay", kind: .income), to: pay.id,
                        scope: .allLikeThis(pattern: "HALCYON LABS PAYROLL", match: .contains, unticked: []))
        }
    }
}
