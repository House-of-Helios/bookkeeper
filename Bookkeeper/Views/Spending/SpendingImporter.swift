import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BookkeeperCore

/// Bank CSVs into the ledger: File → Import CSV…, a drop on Spending or Transactions, or
/// the dev app's one-click fake inbox. Each file's shape picks its recipe; the recipe and
/// the card's last digits pick its account (`SpendingStore.account(for:recipe:colorHex:)`,
/// made on first sight), so overlapping exports of one card land together and dedupe, and
/// a second card from the same bank gets its own.
///
/// After every import a toast says what happened ("212 new · 40 already here · 3 to
/// review"). A file no recipe fits opens the teach-a-bank sheet (`teaching`), one file at
/// a time; once taught, the rest of the drop is tried again under the new recipe.
@Observable
final class SpendingImporter {
    let store: SpendingStore
    /// Bumped after every import that added rows, so the screens re-pick their range.
    private(set) var generation = 0
    /// The unknown file the teach-a-bank sheet is showing, if any.
    var teaching: TeachRequest?
    /// Recognised files waiting on the import sheet, each with the account it goes to.
    var planning: ImportPlan?

    /// Where one file goes: Automatic (its digits, else the best guess), an account, or a new one.
    enum Destination: Hashable { case automatic, account(String), new }

    struct PlannedFile: Identifiable {
        let id = UUID()
        let file: DroppedFile
        let recipe: ImportRecipe
        /// What Automatic would do, in words: an account's name, or "new: …".
        let guess: String
        var destination: Destination = .automatic
    }

    struct ImportPlan: Identifiable {
        let id = UUID()
        var files: [PlannedFile]
        var unknown: [DroppedFile] = []
        var unreadable: [String] = []
    }
    /// Unknown files still waiting behind `teaching`.
    private var waiting: [DroppedFile] = []

    init(store: SpendingStore) { self.store = store }

    /// Account colours, handed out in order of first import.
    private static let accountColours = ["#7B90D2", "#90B44B", "#D19826", "#E03C8A", "#2EA9DF",
                                         "#986DB2", "#E98B2A", "#5DAC81", "#C1693C", "#3A8FB7"]

    /// True in Bookkeeper Dev — the only build whose Info.plist names a data folder.
    static var isDevApp: Bool { Bundle.main.object(forInfoDictionaryKey: DataRoot.infoKey) != nil }

    /// `_DevData/inbox/`, which `scripts/gen-fake-bank-csvs.py --dev` fills.
    static var devInbox: URL { DataRoot.url.appendingPathComponent("inbox", isDirectory: true) }

    /// A file as dropped: its name and bytes.
    struct DroppedFile {
        var name: String
        var data: Data
        var text: String
    }

    struct Report {
        var added = 0, alreadyHere = 0, toReview = 0
        var recognised = 0
        var unknown: [DroppedFile] = []
        var unreadable: [String] = []

        /// "212 new · 40 already here · 3 to review"
        var line: String { "\(added) new · \(alreadyHere) already here · \(toReview) to review" }
    }

    /// The picker opens a beat after the click, as a sheet on the window. Run straight
    /// from the menu bar, a modal panel opened while the menu was still closing and
    /// wouldn't take clicks. Where a Dev inbox of made-up files exists, it opens there.
    @MainActor
    func chooseFiles() {
        DispatchQueue.main.async { [self] in
            let panel = NSOpenPanel()
            panel.title = "Import bank CSVs"
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.commaSeparatedText, .plainText]
            if Self.isDevApp, FileManager.default.fileExists(atPath: Self.devInbox.path) {
                panel.directoryURL = Self.devInbox
            }
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
                panel.beginSheetModal(for: window) { response in
                    if response == .OK { self.importFiles(panel.urls) }
                }
            } else if panel.runModal() == .OK {
                importFiles(panel.urls)
            }
        }
    }

    func importDevInbox() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.devInbox, includingPropertiesForKeys: nil)) ?? []
        importFiles(files.filter { $0.pathExtension.lowercased() == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    /// Read the files and put the recognised ones on the import sheet, each set to
    /// Automatic; the unknown ones go to teaching once the sheet is done.
    func importFiles(_ urls: [URL]) {
        var plan = ImportPlan(files: [])
        for url in urls {
            guard let f = Self.read(url) else { plan.unreadable.append(url.lastPathComponent); continue }
            let rows = CSV.parse(f.text)
            guard let recipe = RecipeMatcher.match(rows: rows, among: store.allRecipes) else { plan.unknown.append(f); continue }
            let cards = store.cards(in: rows, recipe: recipe)
            if cards.count > 1 {
                plan.files.append(PlannedFile(file: f, recipe: recipe,
                                              guess: "one account per card: " + cards.map { "··\($0)" }.joined(separator: ", ")))
                continue
            }
            let g = store.accountGuess(for: rows, recipe: recipe, fileName: f.name)
            plan.files.append(PlannedFile(file: f, recipe: recipe, guess: g.account?.name ?? "new: \(g.newName)"))
        }
        if plan.files.isEmpty {
            finish(Report(unknown: plan.unknown, unreadable: plan.unreadable))
        } else {
            planning = plan
        }
    }

    /// The sheet's Import: each file into the account chosen for it.
    func confirm(_ plan: ImportPlan) {
        planning = nil
        var r = Report(unknown: plan.unknown, unreadable: plan.unreadable)
        // "New account" on two files of one bank and card means one new account, not two.
        var made: [String: BankAccount] = [:]
        for p in plan.files { importOne(p.file, recipe: p.recipe, into: p.destination, made: &made, report: &r) }
        finish(r)
    }

    /// The sheet's Cancel: nothing imported; unknown files still get their teaching.
    func cancelPlan() {
        guard let plan = planning else { return }
        planning = nil
        finish(Report(unknown: plan.unknown, unreadable: plan.unreadable))
    }

    private func importOne(_ file: DroppedFile, recipe: ImportRecipe, into d: Destination,
                           made: inout [String: BankAccount], report r: inout Report) {
        let rows = CSV.parse(file.text)
        // Automatic on a file holding several cards: each card into its own account.
        if case .automatic = d {
            let cards = store.cards(in: rows, recipe: recipe)
            if cards.count > 1 {
                for card in cards {
                    let a = store.account(for: rows, recipe: recipe, fileName: file.name, card: card) {
                        Self.accountColours[$0 % Self.accountColours.count]
                    }
                    add(file, recipe: recipe, into: a, card: card, report: &r)
                }
                return
            }
        }
        let account: BankAccount
        switch d {
        case .automatic:
            account = store.account(for: rows, recipe: recipe, fileName: file.name) {
                Self.accountColours[$0 % Self.accountColours.count]
            }
        case .account(let id):
            guard let a = store.accounts.first(where: { $0.id == id }) else { r.unreadable.append(file.name); return }
            account = a
        case .new:
            let digits = SpendingStore.lastFour(inFileName: file.name)
            let key = "\(recipe.id)|\(digits ?? "")"
            if let a = made[key] {
                account = a
            } else {
                account = store.addAccount(name: digits.map { "\(recipe.name) ··\($0)" } ?? recipe.name, recipeId: recipe.id,
                                           colorHex: Self.accountColours[store.accounts.count % Self.accountColours.count],
                                           card: digits)
                made[key] = account
            }
        }
        add(file, recipe: recipe, into: account, card: nil, report: &r)
    }

    private func add(_ file: DroppedFile, recipe: ImportRecipe, into account: BankAccount, card: String?,
                     report r: inout Report) {
        do {
            let s = try store.importCSV(data: file.data, accountId: account.id, recipe: recipe,
                                        fileName: file.name, card: card)
            r.added += s.added; r.alreadyHere += s.alreadyHere; r.toReview += s.toReview
            r.recognised += 1
        } catch {
            r.unreadable.append(file.name)
        }
    }

    /// Toast the report and put any unknown files in front of the teach sheet.
    private func finish(_ r: Report) {
        if r.added > 0 { generation += 1 }
        var parts: [String] = []
        if r.recognised > 0 { parts.append(r.line) }
        if !r.unreadable.isEmpty { parts.append("couldn’t read \(r.unreadable.joined(separator: ", "))") }
        if !parts.isEmpty { Toaster.shared.say(parts.joined(separator: " · "), for: 4) }
        waiting += r.unknown
        if teaching == nil { teachNext() }
    }

    private func teachNext() {
        guard !waiting.isEmpty else { teaching = nil; return }
        teaching = TeachRequest(file: waiting.removeFirst())
    }

    /// The sheet's "Save recipe & import N": remember the shape, import the file under it,
    /// then try the files still waiting — the same bank's other exports now go straight in.
    func teach(_ request: TeachRequest, recipe: ImportRecipe) {
        store.addRecipe(recipe)
        let rest = waiting
        waiting = []
        teaching = nil
        var r = run([request.file] + rest)
        if r.recognised > 0 {
            Toaster.shared.say("✓ “\(recipe.name)” saved · \(r.line)", for: 4)
            r.recognised = 0   // said above
        }
        finish(r)
    }

    /// The sheet went away on its own (Esc): show the next unknown file, if any.
    func resumeTeaching() { if teaching == nil { teachNext() } }

    /// "Not now": drop this file, show the next unknown one if any.
    func skipTeaching() {
        teaching = nil
        teachNext()
    }

    private static func read(_ url: URL) -> DroppedFile? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        return DroppedFile(name: url.lastPathComponent, data: data, text: text)
    }

    /// The import itself, no UI — the snapshot mock seeds through this too.
    @discardableResult
    func run(_ urls: [URL]) -> Report {
        var unreadable: [String] = []
        let files = urls.compactMap { url -> DroppedFile? in
            guard let f = Self.read(url) else { unreadable.append(url.lastPathComponent); return nil }
            return f
        }
        var r = run(files)
        r.unreadable += unreadable
        return r
    }

    private func run(_ files: [DroppedFile]) -> Report {
        var r = Report()
        var made: [String: BankAccount] = [:]
        for file in files {
            guard let recipe = RecipeMatcher.match(rows: CSV.parse(file.text), among: store.allRecipes) else {
                r.unknown.append(file); continue
            }
            importOne(file, recipe: recipe, into: .automatic, made: &made, report: &r)
        }
        return r
    }
}
