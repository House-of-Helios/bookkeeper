import CryptoKit
import Foundation
import Observation

public enum SpendingImportError: Error, Equatable {
    case unknownAccount
    /// No recipe fits — the mapping sheet's cue.
    case unknownShape
    case unreadable
}

/// What one drop did: "212 new · 40 already here · 3 to review".
public struct ImportSummary: Equatable, Sendable {
    public var importId: String
    public var recipeId: String
    public var added: Int
    public var alreadyHere: Int
    /// New rows that look like an existing one re-described — kept, flagged, not merged.
    public var toReview: Int
    /// Rows after the header that didn't read (an opening-balance line, a footer).
    public var skipped: Int
}

public struct CategorySpend: Equatable, Sendable {
    public var category: SpendingCategory
    /// Purchases minus refunds, positive = money spent.
    public var total: Decimal
    public var count: Int

    public init(category: SpendingCategory, total: Decimal, count: Int) {
        self.category = category; self.total = total; self.count = count
    }
}

public struct MonthSpend: Equatable, Sendable {
    public var month: Month
    public var total: Decimal
    /// Category id → spend, for the stacked strip.
    public var byCategory: [String: Decimal]
}

public struct CategoryIncome: Equatable, Sendable {
    public var category: SpendingCategory
    /// Money in, positive.
    public var total: Decimal
    public var count: Int
}

public struct MerchantSpend: Equatable, Sendable {
    public var name: String
    public var total: Decimal
    public var count: Int
}

/// Which transactions to list. Every field left nil means "any".
public struct TransactionFilter: Equatable, Sendable {
    public var range: ClosedRange<Month>?
    public var categoryId: String?
    public var kind: TransactionKind?
    public var accountId: String?
    /// Matches `displayName` exactly.
    public var merchant: String?
    public var needsReview: Bool?

    public init(range: ClosedRange<Month>? = nil, categoryId: String? = nil, kind: TransactionKind? = nil,
                accountId: String? = nil, merchant: String? = nil, needsReview: Bool? = nil) {
        self.range = range; self.categoryId = categoryId; self.kind = kind
        self.accountId = accountId; self.merchant = merchant; self.needsReview = needsReview
    }
}

/// The 2.0 ledger: bank accounts, their transactions, taught recipes and categories,
/// as plain JSON under `spending/` (dir 0700, files 0600). The directory is injected —
/// a store built in a test never sees the live root.
///
///     accounts.json  transactions.json  recipes.json  categories.json
///     merchants.json   Helios's merchant rules (seed rules live in code)
///     settings.json    the screens' preferences (theme)
///     imports.json     one line per drop: file name, account, when, counts — no bank text
///     imports/<importId>.csv     the original file, kept so a recipe fix can re-parse it
@Observable
public final class SpendingStore {
    @ObservationIgnored public let directory: URL

    public private(set) var accounts: [BankAccount] { didSet { changed() } }
    /// Chronological (date, then id), the order `transactions()` returns.
    public private(set) var transactions: [BankTransaction] { didSet { changed() } }
    /// User-taught only; built-ins live in `BuiltInRecipes`.
    public private(set) var recipes: [ImportRecipe]
    public private(set) var categories: CategoryBook { didSet { changed() } }
    /// Helios's rules, in the order made. `SeedRules` rank below every one of them.
    public private(set) var rules: [MerchantRule] { didSet { changed() } }
    /// Every drop, oldest first.
    public private(set) var imports: [ImportRecord]
    /// The screens' own preferences (`settings.json`) — the theme.
    public private(set) var settings: SpendingSettings
    /// The Budget tab's monthly amounts (`budgets.json`). A new file beside the others:
    /// a build from before budgets never reads it, so it needs no upgrade step.
    public private(set) var budget: BudgetBook
    /// The clock rules and the imports log read. Tests pin it.
    @ObservationIgnored var now: () -> Date = Date.init

    /// Every query's answer, kept until the ledger, the lists or the rules change. A
    /// hover redraws the screen many times a second and asks the same questions each time;
    /// this way only the first asking walks the ledger.
    @ObservationIgnored private var memo: [String: Any] = [:]
    /// Bumped on every change; a cached answer reads it, so a screen showing one still
    /// redraws when the data under it moves.
    public private(set) var revision = 0
    /// The last save that failed, for the screen to say so; the screen clears it once said.
    public var saveFailure: String?
    /// Why this folder must not be written, when its `schema.json` isn't the version this
    /// build reads: a newer Bookkeeper wrote it, or an upgrade step failed. The ledger
    /// still opens to look at; nothing reaches disk until the right build opens it.
    public private(set) var locked: String?

    /// A bank line's words, worked out once per distinct text — every rule check and
    /// every drawer's "like this" asks again, and the folding and regex are the slow part.
    @ObservationIgnored private var tokenMemo: [String: (all: [String], stripped: [String])] = [:]

    private func tokens(_ raw: String) -> (all: [String], stripped: [String]) {
        if let hit = tokenMemo[raw] { return hit }
        let t = MerchantCore.tokens(raw)
        tokenMemo[raw] = t
        return t
    }

    private func changed() {
        memo.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    private func cached<T>(_ key: String, _ make: () -> T) -> T {
        _ = revision
        if let hit = memo[key] as? T { return hit }
        let value = make()
        memo[key] = value
        return value
    }

    /// Defaults to `spending/` under the live data root.
    public init(directory: URL? = nil) {
        let dir = directory ?? SpendingFolder.directory(in: DataRoot.url)
        self.directory = dir
        var bad: [String] = []
        // Decided before any read: a locked folder's files are a newer shape, not damage,
        // and must never be moved aside as corrupt.
        let lock = Self.lockReason(dir)
        let aside = lock == nil
        accounts = Self.read([BankAccount].self, dir, "accounts.json", &bad, moveAside: aside) ?? []
        transactions = Self.read([BankTransaction].self, dir, "transactions.json", &bad, moveAside: aside) ?? []
        recipes = Self.read([ImportRecipe].self, dir, "recipes.json", &bad, moveAside: aside) ?? []
        categories = Self.read(CategoryBook.self, dir, "categories.json", &bad, moveAside: aside) ?? .defaults
        rules = Self.read([MerchantRule].self, dir, "merchants.json", &bad, moveAside: aside) ?? []
        imports = Self.read([ImportRecord].self, dir, "imports.json", &bad, moveAside: aside) ?? []
        settings = Self.read(SpendingSettings.self, dir, "settings.json", &bad, moveAside: aside) ?? SpendingSettings()
        budget = Self.read(BudgetBook.self, dir, "budgets.json", &bad, moveAside: aside) ?? BudgetBook()
        locked = lock
        if let locked {
            saveFailure = locked
        } else if !bad.isEmpty {
            saveFailure = "Couldn’t read \(bad.joined(separator: ", ")) — set aside in the data folder as .corrupt, and a copy is in backups. Nothing was overwritten."
        }
        // Rent & utilities split in two: a bank's "Bills & Utilities" stored as `home`
        // before the split now reads as Utilities. The bank default is set at import, so
        // it's the one category field `resolveAll` doesn't rewrite.
        for i in transactions.indices where transactions[i].categoryId == "home" {
            if let id = categories.categoryId(forBank: transactions[i].bankCategory), id != "home" {
                transactions[i].categoryId = id
            }
        }
        // Rule fields are derived: a newer build's seed rules reach old rows on open.
        resolveAll()
    }

    /// The recurring-charge scan, kept until the ledger changes (`Recurring.swift`).
    func cachedRecurring(_ make: () -> [RecurringCharge]) -> [RecurringCharge] { cached("recurring", make) }

    public func setBudget(_ book: BudgetBook) {
        budget = book
        changed()
        save("budgets.json", budget)
    }

    // MARK: - Accounts, recipes, categories

    @discardableResult
    public func addAccount(name: String, recipeId: String? = nil, colorHex: String,
                           card: String? = nil) -> BankAccount {
        let account = BankAccount(name: name, recipeId: recipeId, colorHex: colorHex, card: card)
        accounts.append(account)
        save("accounts.json", accounts)
        return account
    }

    /// The account a dropped file belongs to, made if it's the first of its kind.
    ///
    /// A bank whose file carries the card's last digits (Chase card, Capital One, Amex)
    /// gets one account per card: `Chase card ··4417` and `Chase card ··8830`. An account
    /// made from a file without them takes the digits from the first such file that
    /// repeats its rows.
    ///
    /// A file with no card digits goes to the account of its bank whose rows it repeats.
    /// Repeating none, it goes to the first account of its bank it doesn't overlap — a
    /// file that shares two weeks of dates with an account but not one row is another
    /// account at that bank, not a later export of the same one.
    public func account(for rows: [[String]], recipe: ImportRecipe, fileName: String? = nil,
                        card only: String? = nil, colorHex: (Int) -> String) -> BankAccount {
        var parsed = recipe.parse(rows: rows).rows
        // One card of a file that holds several: only its rows count.
        if let only { parsed = parsed.filter { $0.card == only } }
        let same = accounts.filter { $0.recipeId == recipe.id }
        let cards = Dictionary(grouping: parsed.compactMap(\.card), by: { $0 })
        // The file's own card column first; else the last four digits in its name.
        let card = only ?? cards.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
            ?? fileName.flatMap(Self.lastFour(inFileName:))

        if let card {
            if let a = same.first(where: { $0.holds(card: card) }) { return a }
            if let a = mostRepeated(parsed, among: same.filter { $0.card == nil }),
               let i = accounts.firstIndex(where: { $0.id == a.id }) {
                accounts[i].card = card
                save("accounts.json", accounts)
                return accounts[i]
            }
            return addAccount(name: "\(recipe.name) ··\(card)", recipeId: recipe.id,
                              colorHex: colorHex(accounts.count), card: card)
        }
        if let a = mostRepeated(parsed, among: same) { return a }
        if let a = same.first(where: { $0.card == nil && !overlaps(parsed, $0) }) { return a }
        let name = same.isEmpty ? recipe.name : "\(recipe.name) \(same.count + 1)"
        return addAccount(name: name, recipeId: recipe.id, colorHex: colorHex(accounts.count))
    }

    /// The candidate holding the most of these rows already, if any holds one.
    private func mostRepeated(_ rows: [ParsedRow], among candidates: [BankAccount]) -> BankAccount? {
        guard !candidates.isEmpty else { return nil }
        let ids = Set(transactions.map(\.id))
        let scored = candidates.map { a -> (BankAccount, Int) in
            var occurrences: [String: Int] = [:]
            var hits = 0
            for row in rows {
                let tuple = Self.tupleKey(accountId: a.id, date: row.date, amount: row.amount,
                                          rawDescription: row.description)
                let n = occurrences[tuple, default: 0]
                occurrences[tuple] = n + 1
                if ids.contains(Self.stableId(tuple: tuple, occurrence: n)) { hits += 1 }
            }
            return (a, hits)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Whether these rows' dates share two weeks or more with an account's.
    private func overlaps(_ rows: [ParsedRow], _ account: BankAccount) -> Bool {
        let mine = transactions.filter { $0.accountId == account.id }.map(\.date)
        guard let a0 = mine.min(), let a1 = mine.max(),
              let f0 = rows.map(\.date).min(), let f1 = rows.map(\.date).max() else { return false }
        let start = max(a0, f0), end = min(a1, f1)
        return end.days(since: start) >= 14
    }

    /// Save a recipe taught in the mapping sheet. Same id replaces.
    public func addRecipe(_ recipe: ImportRecipe) {
        recipes.removeAll { $0.id == recipe.id }
        recipes.append(recipe)
        save("recipes.json", recipes)
    }

    /// User-taught first, so a taught shape wins over a built-in.
    public var allRecipes: [ImportRecipe] { recipes + BuiltInRecipes.all }

    /// Replace the category book. Kinds and seeded categories of rows already in the
    /// ledger are left as they are — no silent history rewrite.
    public func updateCategories(_ book: CategoryBook) {
        categories = book
        save("categories.json", categories)
    }

    /// The Edit-category sheet: rename, recolour, re-icon one category, spend or income.
    /// Stored as an edit over the default; an unknown id changes nothing.
    public func updateCategory(_ id: String, name: String? = nil, colorHex: String? = nil, icon: String? = nil) {
        guard categories.category(id) != nil else { return }
        categories.update(id, with: CategoryEdit(name: name, colorHex: colorHex, icon: icon))
        save("categories.json", categories)
    }

    /// The theme picker. Written only when it changes, so opening never writes.
    public func setTheme(_ theme: ThemeChoice) {
        guard settings.theme != theme else { return }
        settings.theme = theme
        save("settings.json", settings)
    }

    public func setTextSize(_ size: TextSize) {
        guard settings.textSize != size else { return }
        settings.textSize = size
        save("settings.json", settings)
    }

    // MARK: - Import

    @discardableResult
    public func importCSV(fileURL: URL, accountId: String,
                          recipe: ImportRecipe? = nil) throws -> ImportSummary {
        guard let data = try? Data(contentsOf: fileURL) else { throw SpendingImportError.unreadable }
        return try importCSV(data: data, accountId: accountId, recipe: recipe, fileName: fileURL.lastPathComponent)
    }

    @discardableResult
    public func importCSV(text: String, accountId: String,
                          recipe: ImportRecipe? = nil) throws -> ImportSummary {
        try importCSV(data: Data(text.utf8), accountId: accountId, recipe: recipe)
    }

    /// Parse a bank file into the ledger. The recipe is the one given, else the first
    /// that fits the file's shape (`RecipeMatcher`); none fits → `.unknownShape`.
    ///
    /// Each row's id is `stableId` — so re-dropping an overlapping export maps the same
    /// rows to the same ids and skips them. A new row with the same amount as an
    /// existing one within two days but different text goes in flagged `reviewed: false`
    /// — unless that existing row came back verbatim in this same file, which proves
    /// it isn't the one being re-described.
    ///
    /// Then the merchant rules: a fresh row resolves through them at once, so a merchant
    /// taught once arrives named and categorised. A spend row holding a transfer-ish word
    /// (`SeedRules.reviewWords`) that none of Helios's rules answers is flagged `toReview`
    /// and left uncategorised. Every call is logged to `imports.json`.
    @discardableResult
    public func importCSV(data: Data, accountId: String,
                          recipe: ImportRecipe? = nil, fileName: String? = nil,
                          card: String? = nil) throws -> ImportSummary {
        guard let accountIndex = accounts.firstIndex(where: { $0.id == accountId }) else {
            throw SpendingImportError.unknownAccount
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { throw SpendingImportError.unreadable }
        let rows = CSV.parse(text)
        guard let recipe = recipe ?? RecipeMatcher.match(rows: rows, among: allRecipes) else {
            throw SpendingImportError.unknownShape
        }
        var parsed = recipe.parse(rows: rows)
        // A file holding several cards goes in one card at a time, each to its own account.
        if let card { parsed.rows = parsed.rows.filter { $0.card == card } }
        let importId = Self.hex(SHA256.hash(data: data), count: 16) + (card.map { "-\($0)" } ?? "")

        let read = freshRows(parsed.rows, accountId: accountId, importId: importId)
        var fresh = read.fresh
        let seenAgain = read.seenAgain

        // Near-duplicates: only against rows from earlier imports that this file did not
        // repeat word for word.
        var lookalikes: [Decimal: [BankTransaction]] = [:]
        for t in transactions where t.accountId == accountId && !seenAgain.contains(t.id) {
            lookalikes[t.amount, default: []].append(t)
        }
        var toReview = 0
        for i in fresh.indices {
            let t = fresh[i]
            let near = lookalikes[t.amount]?.contains {
                abs(t.date.days(since: $0.date)) <= 2 && $0.rawDescription != t.rawDescription
            } ?? false
            if near { fresh[i].reviewed = false }
            if fresh[i].needsReview { toReview += 1 }
        }

        // Kept even when every line was here already: removing an earlier file puts back
        // the lines this one also holds, from this copy.
        keepOriginal(data, importId: importId)
        if !fresh.isEmpty {
            transactions = (transactions + fresh).sorted(by: Self.chronological)
            save("transactions.json", transactions)
        }
        // An account picked by hand for another bank's file keeps its own bank: only one
        // made by hand, with none yet, takes this file's.
        if accounts[accountIndex].recipeId == nil {
            accounts[accountIndex].recipeId = recipe.id
            save("accounts.json", accounts)
        }
        // The first import writes the defaults out, so the lists are there to edit.
        if !FileManager.default.fileExists(atPath: file("categories.json").path) {
            save("categories.json", categories)
        }
        let summary = ImportSummary(importId: importId, recipeId: recipe.id, added: fresh.count,
                                    alreadyHere: seenAgain.count, toReview: toReview,
                                    skipped: parsed.skipped.count)
        imports.append(ImportRecord(importId: importId, fileName: fileName, accountId: accountId,
                                    recipeId: recipe.id, importedAt: now(), added: summary.added,
                                    alreadyHere: summary.alreadyHere, toReview: summary.toReview,
                                    skipped: summary.skipped, card: card))
        save("imports.json", imports)
        return summary
    }

    /// The rows not in the ledger yet, read into lines (kind, default category, rules and
    /// the questions they leave), and the ids of the ones already here.
    private func freshRows(_ rows: [ParsedRow], accountId: String,
                           importId: String) -> (fresh: [BankTransaction], seenAgain: Set<String>) {
        let existing = Set(transactions.map(\.id))
        let classifier = KindClassifier(book: categories)
        var occurrences: [String: Int] = [:]
        var fresh: [BankTransaction] = []
        var seenAgain = Set<String>()
        for row in rows {
            let tuple = Self.tupleKey(accountId: accountId, date: row.date, amount: row.amount,
                                      rawDescription: row.description)
            let n = occurrences[tuple, default: 0]
            occurrences[tuple] = n + 1
            let id = Self.stableId(tuple: tuple, occurrence: n)
            if existing.contains(id) { seenAgain.insert(id); continue }

            let kind = classifier.kind(amount: row.amount, description: row.description, bankType: row.bankType)
            fresh.append(BankTransaction(
                id: id, accountId: accountId, date: row.date, amount: row.amount,
                rawDescription: row.description, bankMerchant: row.bankMerchant,
                bankCategory: row.bankCategory, bankType: row.bankType, importId: importId,
                kind: kind, categoryId: defaultCategory(kind: kind, description: row.description,
                                                         bankCategory: row.bankCategory)))
        }
        // Rules, then the questions they leave.
        let ruleSet = RuleSet(rules)
        for i in fresh.indices {
            let text = tokens(fresh[i].rawDescription)
            let answered = ruleSet.resolve(&fresh[i], text: text)
            if !answered, fresh[i].effectiveKind == .spend,
               SeedRules.reviewWords.contains(where: { $0.matches(text) }) {
                fresh[i].toReview = true
                fresh[i].categoryId = nil
                ruleSet.resolve(&fresh[i], text: text)
            }
        }
        return (fresh, seenAgain)
    }

    /// The cards a file's rows name, most rows first.
    public func cards(in rows: [[String]], recipe: ImportRecipe) -> [String] {
        let counts = Dictionary(grouping: recipe.parse(rows: rows).rows.compactMap(\.card), by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Take one dropped file back out: its entries, its line in the log, its kept copy.
    /// Entries another file in the account also holds stay — read back from that file's
    /// kept copy. Rules and categories stay too, so dropping the file again lands it sorted
    /// as before. An account left with no files goes with it. Returns the entries removed.
    @discardableResult
    public func removeImport(_ importId: String) -> Int {
        backUp()
        let before = transactions.count
        let owner = imports.first { $0.importId == importId }?.accountId
        transactions.removeAll { $0.importId == importId }
        imports.removeAll { $0.importId == importId }
        // Only the account this file was in, if nothing is left in it — a bank added by
        // hand and still waiting for its first file stays.
        if let owner, !imports.contains(where: { $0.accountId == owner }),
           !transactions.contains(where: { $0.accountId == owner }) {
            accounts.removeAll { $0.id == owner }
            save("accounts.json", accounts)
        }
        // Lines this file brought in that another kept file also holds come back, under
        // that file — so taking out Jan–Feb leaves Feb–Mar whole.
        if let owner { refill(owner) }
        remove(directory.appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("\(importId).csv"))
        save("transactions.json", transactions)
        save("imports.json", imports)
        return before - transactions.count
    }

    /// Re-reads the kept copy of every file still in the account, oldest first, and puts
    /// back any of its lines missing from the ledger.
    private func refill(_ accountId: String) {
        let dir = directory.appendingPathComponent("imports", isDirectory: true)
        var back: [BankTransaction] = []
        for r in imports where r.accountId == accountId {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(r.importId).csv")),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let recipe = allRecipes.first(where: { $0.id == r.recipeId }) else { continue }
            var rows = recipe.parse(rows: CSV.parse(text)).rows
            if let card = r.card { rows = rows.filter { $0.card == card } }
            let fresh = freshRows(rows, accountId: accountId, importId: r.importId).fresh
                .filter { f in !back.contains { $0.id == f.id } }
            back += fresh
        }
        if !back.isEmpty { transactions = (transactions + back).sorted(by: Self.chronological) }
    }

    /// Back to the first launch for the bank side: no accounts, entries, files, taught
    /// banks, rules or category edits. The screens' own settings (theme, text size) stay,
    /// and the whole folder is copied to `backups/` first.
    /// Nothing outside this store's folder is touched — the crypto side is never in it.
    public func startOver() {
        if let locked { saveFailure = locked; return }
        backUp()
        accounts = []; transactions = []; recipes = []; rules = []; imports = []
        categories = .defaults
        for (name, value) in [("accounts.json", [BankAccount]() as any Encodable),
                              ("transactions.json", [BankTransaction]()), ("recipes.json", [ImportRecipe]()),
                              ("merchants.json", [MerchantRule]()), ("imports.json", [ImportRecord]())] {
            save(name, value)
        }
        remove(file("categories.json"))
        remove(directory.appendingPathComponent("imports", isDirectory: true))
    }

    /// The import's own category: the bank's word for spend, the description for income.
    private func defaultCategory(kind: TransactionKind, description: String, bankCategory: String?) -> String? {
        switch kind {
        case .spend: return categories.categoryId(forBank: bankCategory)
        case .income: return categories.incomeCategoryId(for: description)
        case .transfer: return nil
        }
    }

    /// `accountId|yyyy-MM-dd|amount|rawDescription` — the identity of a row before its
    /// occurrence index. Documented so another app can rebuild the same ids.
    static func tupleKey(accountId: String, date: Day, amount: Decimal, rawDescription: String) -> String {
        "\(accountId)|\(date.iso)|\(amount)|\(rawDescription)"
    }

    /// First 32 hex chars of SHA-256 of `tuple|n`, where n counts earlier rows with the
    /// same tuple in the same file — two $4.50 coffees on one day are `…|0` and `…|1`,
    /// and both come out the same way from every export that contains them.
    static func stableId(tuple: String, occurrence n: Int) -> String {
        hex(SHA256.hash(data: Data("\(tuple)|\(n)".utf8)), count: 16)
    }

    private static func hex(_ digest: SHA256.Digest, count: Int) -> String {
        digest.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private static func chronological(_ a: BankTransaction, _ b: BankTransaction) -> Bool {
        a.date != b.date ? a.date < b.date : a.id < b.id
    }

    // MARK: - Edits

    /// The one-transaction edit. Nil (or an empty override) clears it.
    public func setOverride(_ override: TransactionOverride?, for id: String) {
        guard let i = transactions.firstIndex(where: { $0.id == id }) else { return }
        transactions[i].override = (override?.isEmpty ?? true) ? nil : override
        save("transactions.json", transactions)
    }

    public func markReviewed(_ id: String) {
        guard let i = transactions.firstIndex(where: { $0.id == id }) else { return }
        transactions[i].reviewed = true
        transactions[i].toReview = false
        resolveAll()
        save("transactions.json", transactions)
    }

    /// Undo for "Just this one".
    public func clearOverride(_ transactionId: String) { setOverride(nil, for: transactionId) }

    // MARK: - Merchant rules (the edit drawer)

    /// Every line a pattern catches — the live "All like this" list.
    public func matches(for pattern: String, match: MerchantRule.Match,
                        direction: MerchantRule.Direction? = nil) -> [BankTransaction] {
        let rule = MerchantRule(match: match, pattern: pattern, direction: direction)
        let words = rule.words
        return transactions.filter { rule.allows($0.amount) && rule.matches(tokens($0.rawDescription), words: words) }
    }

    /// What the drawer opens with for one line. Nil for an unknown id.
    public func editPreview(_ transactionId: String) -> EditPreview? {
        guard let t = transactions.first(where: { $0.id == transactionId }) else { return nil }
        let core = MerchantCore.core(t.rawDescription, amount: t.amount)
        let name = t.override?.name ?? t.merchantName ?? t.bankMerchant ?? MerchantCore.suggestedName(t.rawDescription, amount: t.amount)
        // A payment app's words go both ways, so its rule keeps to this line's way: money
        // in from a person is never caught up with money out to them.
        let direction = MerchantCore.isPayment(t.rawDescription) ? MerchantRule.Direction(t.amount) : nil
        return EditPreview(transaction: t, core: core, suggestedName: name, match: .contains,
                           likeThis: matches(for: core, match: .contains, direction: direction), direction: direction)
    }

    /// The drawer's Save. "Just this one" merges the edit into that line's override.
    /// "All like this" makes a rule — or updates the one with the same match and pattern
    /// words — whose exclusions are the unticked lines; it reaches every line it matches
    /// now and every future import. A rule never overwrites another line's spot edit;
    /// on the line the drawer was opened on, the fields this edit sets are cleared from
    /// its override so the new choice shows. Touched lines leave To review.
    /// Returns the number of lines changed.
    @discardableResult
    public func apply(edit: TransactionEdit, to transactionId: String, scope: EditScope) -> Int {
        guard let i = transactions.firstIndex(where: { $0.id == transactionId }) else { return 0 }
        switch scope {
        case .justThisOne:
            var o = transactions[i].override ?? TransactionOverride()
            if let n = edit.name { o.name = n }
            if let c = edit.categoryId { o.categoryId = c }
            if let k = edit.kind { o.kind = k }
            transactions[i].override = o.isEmpty ? nil : o
            transactions[i].reviewed = true
            transactions[i].toReview = false
            resolveAll()
            save("transactions.json", transactions)
            return 1

        case let .allLikeThis(pattern, match, unticked, direction):
            let matched = Set(matches(for: pattern, match: match, direction: direction).map(\.id))
            let ticked = matched.subtracting(unticked)
            let words = MerchantCore.tokens(pattern).all
            guard !words.isEmpty else { return 0 }
            if let r = rules.firstIndex(where: { $0.match == match && $0.words == words && $0.direction == direction }) {
                rules[r].pattern = pattern
                if let n = edit.name { rules[r].name = n }
                if let c = edit.categoryId { rules[r].categoryId = c }
                if let k = edit.kind { rules[r].kind = k }
                // A transfer has no category: an old one would linger under filters.
                if edit.kind == .transfer { rules[r].categoryId = nil }
                rules[r].excludedTransactionIds = rules[r].excludedTransactionIds
                    .subtracting(matched).union(unticked.intersection(matched))
            } else {
                rules.append(MerchantRule(match: match, pattern: pattern, name: edit.name,
                                          categoryId: edit.categoryId, kind: edit.kind,
                                          excludedTransactionIds: unticked.intersection(matched),
                                          createdAt: now(), direction: direction))
            }
            if ticked.contains(transactionId), var o = transactions[i].override {
                if edit.name != nil { o.name = nil }
                if edit.categoryId != nil { o.categoryId = nil }
                if edit.kind != nil { o.kind = nil }
                transactions[i].override = o.isEmpty ? nil : o
            }
            for j in transactions.indices where ticked.contains(transactions[j].id) {
                transactions[j].reviewed = true
                transactions[j].toReview = false
            }
            resolveAll()
            save("merchants.json", rules)
            save("transactions.json", transactions)
            return ticked.count
        }
    }

    /// How many entries a rule reaches now: the lines it matches, less the ones unticked.
    public func reach(of rule: MerchantRule) -> Int {
        cached("reach|\(rule.id)|\(rule.match)|\(rule.pattern)|\(rule.excludedTransactionIds.count)|\(rule.direction?.rawValue ?? "")") {
            matches(for: rule.pattern, match: rule.match, direction: rule.direction).filter { !rule.excludedTransactionIds.contains($0.id) }.count
        }
    }

    /// The rule editor's Save: new words to look for, and what they make of a line. Every
    /// line is re-read under the rules, so lines the new words no longer catch fall back to
    /// the next rule or the defaults, and lines they now catch follow it. Spot edits still win.
    public func updateRule(_ id: String, pattern: String, name: String?, categoryId: String?,
                           kind: TransactionKind?) {
        guard let i = rules.firstIndex(where: { $0.id == id }),
              !MerchantCore.tokens(pattern).all.isEmpty else { return }
        rules[i].pattern = pattern.trimmingCharacters(in: .whitespaces)
        rules[i].name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        rules[i].categoryId = categoryId
        rules[i].kind = kind
        resolveAll()
        save("merchants.json", rules)
        save("transactions.json", transactions)
    }

    /// Undo for "All like this": the lines fall back to the next rule, then the defaults.
    public func removeRule(_ id: String) {
        guard rules.contains(where: { $0.id == id }) else { return }
        rules.removeAll { $0.id == id }
        resolveAll()
        save("merchants.json", rules)
        save("transactions.json", transactions)
    }

    /// Rewrite every row's rule fields from the current rules.
    private func resolveAll() {
        let ruleSet = RuleSet(rules)
        // One assignment, so one change: not a didSet per line.
        var next = transactions
        for i in next.indices {
            ruleSet.resolve(&next[i], text: tokens(next[i].rawDescription))
        }
        if next != transactions { transactions = next }
    }

    // MARK: - Queries

    public func transactions(_ filter: TransactionFilter = TransactionFilter()) -> [BankTransaction] {
        cached("tx|\(filter)") {
            transactions.filter { t in
                if let r = filter.range, !r.contains(t.date.yearMonth) { return false }
                if let c = filter.categoryId, t.effectiveCategoryId != c { return false }
                if let k = filter.kind, t.effectiveKind != k { return false }
                if let a = filter.accountId, t.accountId != a { return false }
                if let m = filter.merchant, t.displayName != m { return false }
                if let r = filter.needsReview, t.needsReview != r { return false }
                return true
            }
        }
    }

    /// Spend per category over `range` (nil = all), in ring order, empty categories
    /// left out. `everyday` sets fixed costs aside. A category id the book doesn't know
    /// (removed by hand) folds into "Other".
    public func spend(byCategoryIn range: ClosedRange<Month>?, everyday: Bool) -> [CategorySpend] {
        cached("spend|\(String(describing: range))|\(everyday)") {
            var totals: [String: (Decimal, Int)] = [:]
            for t in spendRows(range) {
                let id = ringId(t)
                let now = totals[id] ?? (0, 0)
                totals[id] = (now.0 + t.spendAmount, now.1 + 1)
            }
            return categories.categories.compactMap { c in
                guard !(everyday && c.fixed), let (total, count) = totals[c.id] else { return nil }
                return CategorySpend(category: c, total: total, count: count)
            }
        }
    }

    /// Money in per income category over `range` (nil = all), in list order. Never part
    /// of any spend figure. An id the income list doesn't know folds into Other income.
    public func income(byCategoryIn range: ClosedRange<Month>?) -> [CategoryIncome] {
        cached("income|\(String(describing: range))") {
            var totals: [String: (Decimal, Int)] = [:]
            for t in transactions where t.effectiveKind == .income && (range?.contains(t.date.yearMonth) ?? true) {
                let raw = t.effectiveCategoryId
                let id = categories.incomeCategories.contains { $0.id == raw } ? raw : CategoryBook.incomeFallbackId
                let now = totals[id] ?? (0, 0)
                totals[id] = (now.0 + t.amount, now.1 + 1)
            }
            return categories.incomeCategories.compactMap { c in
                totals[c.id].map { CategoryIncome(category: c, total: $0.0, count: $0.1) }
            }
        }
    }

    /// Income per month, first ledger month to last, gaps as zero — the strip on the
    /// Income view. `category` narrows to one income category.
    public func monthlyIncome(category: String? = nil) -> [MonthSpend] {
        cached("monthlyIncome|\(category ?? "")") {
            guard let first = transactions.first?.date.yearMonth,
                  let last = transactions.last?.date.yearMonth else { return [] }
            var byMonth: [Month: [String: Decimal]] = [:]
            for t in incomeRows(nil) {
                let id = incomeId(t)
                if let category, id != category { continue }
                byMonth[t.date.yearMonth, default: [:]][id, default: 0] += t.amount
            }
            var out: [MonthSpend] = []
            var m = first
            while m <= last {
                let split = byMonth[m] ?? [:]
                out.append(MonthSpend(month: m, total: split.values.reduce(0, +), byCategory: split))
                m = m.next
            }
            return out
        }
    }

    /// Who paid in, in one income category, biggest first.
    /// Between two days (both counted): each category's merchants and what they came to,
    /// grouped as the ring groups them — spend, or money in.
    public func totals(from: Day, through: Day, income: Bool) -> [String: [String: Decimal]] {
        cached("window|\(from)|\(through)|\(income)") {
            var out: [String: [String: Decimal]] = [:]
            for t in transactions where t.date >= from && t.date <= through {
                if income, t.effectiveKind == .income {
                    out[incomeId(t), default: [:]][t.displayName, default: 0] += t.amount
                } else if !income, t.effectiveKind == .spend {
                    out[ringId(t), default: [:]][t.displayName, default: 0] += t.spendAmount
                }
            }
            return out
        }
    }

    public func payers(in categoryId: String, range: ClosedRange<Month>?) -> [MerchantSpend] {
        cached("payers|\(categoryId)|\(String(describing: range))") {
            var totals: [String: (Decimal, Int)] = [:]
            for t in incomeRows(range) where incomeId(t) == categoryId {
                let now = totals[t.displayName] ?? (0, 0)
                totals[t.displayName] = (now.0 + t.amount, now.1 + 1)
            }
            return totals.map { MerchantSpend(name: $0.key, total: $0.value.0, count: $0.value.1) }
                .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        }
    }

    /// Income lines in one income category, oldest first like every list.
    /// A ring category's spend lines, chronological — grouped as the ring groups them, so a
    /// line whose category was removed is listed under Other, where it is counted.
    public func spendLines(in categoryId: String, range: ClosedRange<Month>?) -> [BankTransaction] {
        spendRows(range).filter { ringId($0) == categoryId }
    }

    public func incomeLines(in categoryId: String, range: ClosedRange<Month>?) -> [BankTransaction] {
        incomeRows(range).filter { incomeId($0) == categoryId }
    }

    private func incomeRows(_ range: ClosedRange<Month>?) -> [BankTransaction] {
        transactions.filter { $0.effectiveKind == .income && (range?.contains($0.date.yearMonth) ?? true) }
    }

    private func incomeId(_ t: BankTransaction) -> String {
        let id = t.effectiveCategoryId
        return categories.incomeCategories.contains { $0.id == id } ? id : CategoryBook.incomeFallbackId
    }

    /// The To review queue: near-duplicates and transfer-ish lines nobody has answered,
    /// chronological like every other list.
    public func reviewQueue() -> [BankTransaction] {
        cached("review") { transactions.filter(\.needsReview) }
    }

    /// The fixed costs the Everyday view set aside, as one figure.
    public func fixedSpend(in range: ClosedRange<Month>?) -> Decimal {
        cached("fixed|\(String(describing: range))") {
            let fixed = Set(categories.categories.filter(\.fixed).map(\.id))
            return spendRows(range).filter { fixed.contains(ringId($0)) }.reduce(0) { $0 + $1.spendAmount }
        }
    }

    /// One entry per month from the first to the last in the ledger, gaps as zero — the
    /// range strip. `category` narrows to one.
    public func monthlyTotals(category: String? = nil, everyday: Bool) -> [MonthSpend] {
        cached("monthly|\(category ?? "")|\(everyday)") {
            guard let first = transactions.first?.date.yearMonth,
                  let last = transactions.last?.date.yearMonth else { return [] }
            let fixed = Set(categories.categories.filter(\.fixed).map(\.id))
            var byMonth: [Month: [String: Decimal]] = [:]
            for t in spendRows(nil) {
                let id = ringId(t)
                if everyday && fixed.contains(id) { continue }
                if let category, id != category { continue }
                byMonth[t.date.yearMonth, default: [:]][id, default: 0] += t.spendAmount
            }
            var out: [MonthSpend] = []
            var m = first
            while m <= last {
                let split = byMonth[m] ?? [:]
                out.append(MonthSpend(month: m, total: split.values.reduce(0, +), byCategory: split))
                m = m.next
            }
            return out
        }
    }

    /// One merchant (or payer) over the whole ledger, a month at a time, gaps as zero —
    /// the strip under a merchant's editor. Matched on `displayName`, so it fills in as
    /// messy bank text is consolidated into one name.
    public func monthlyTotals(merchant: String, income: Bool) -> [MonthSpend] {
        cached("monthlyMerchant|\(merchant)|\(income)") {
            guard let first = transactions.first?.date.yearMonth,
                  let last = transactions.last?.date.yearMonth else { return [] }
            var byMonth: [Month: Decimal] = [:]
            for t in (income ? incomeRows(nil) : spendRows(nil)) where t.displayName == merchant {
                byMonth[t.date.yearMonth, default: 0] += income ? t.amount : t.spendAmount
            }
            var out: [MonthSpend] = []
            var m = first
            while m <= last {
                let v = byMonth[m] ?? 0
                out.append(MonthSpend(month: m, total: v, byCategory: [:]))
                m = m.next
            }
            return out
        }
    }

    /// The focus panel's leaderboard: merchants in one category, biggest first.
    public func merchants(in categoryId: String, range: ClosedRange<Month>?) -> [MerchantSpend] {
        cached("merchants|\(categoryId)|\(String(describing: range))") {
            var totals: [String: (Decimal, Int)] = [:]
            for t in spendRows(range) where ringId(t) == categoryId {
                let now = totals[t.displayName] ?? (0, 0)
                totals[t.displayName] = (now.0 + t.spendAmount, now.1 + 1)
            }
            return totals.map { MerchantSpend(name: $0.key, total: $0.value.0, count: $0.value.1) }
                .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        }
    }

    private func spendRows(_ range: ClosedRange<Month>?) -> [BankTransaction] {
        transactions.filter { $0.effectiveKind == .spend && (range?.contains($0.date.yearMonth) ?? true) }
    }

    private func ringId(_ t: BankTransaction) -> String {
        let id = t.effectiveCategoryId
        return categories.categories.contains { $0.id == id } ? id : CategoryBook.fallbackId
    }

    // MARK: - Files

    /// Why `dir` must not be written, or nil when its `schema.json` is this build's
    /// version (or absent: a folder from before versions, or a test's).
    static func lockReason(_ dir: URL) -> String? {
        guard let v = SpendingFolder.storedVersion(in: dir), v != SpendingFolder.schemaVersion else { return nil }
        return v > SpendingFolder.schemaVersion
            ? "This bank data was saved by a newer Bookkeeper (data version \(v)). It’s open to look at, but nothing will be saved until the newer app is back."
            : "This bank data couldn’t be brought up to date (stuck at version \(v)). It’s open to look at, nothing will be saved, and a copy from before is in spending/backups."
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Nil for a missing file. A file that is there but won't decode is moved aside to
    /// `<name>.corrupt-<unix seconds>` first — otherwise the empty state the store opens
    /// with would be written over it on the next save, and the edits in it lost for good.
    private static func read<T: Decodable>(_ type: T.Type, _ dir: URL, _ name: String,
                                           _ unreadable: inout [String], moveAside: Bool) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            unreadable.append(name)
            guard moveAside else { return nil }
            let aside = dir.appendingPathComponent("\(name).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    /// A copy of every file in the folder (bar earlier backups) under
    /// `backups/<unix seconds>/`, taken before anything is removed.
    private func backUp() {
        let fm = FileManager.default
        let root = directory.appendingPathComponent("backups", isDirectory: true)
        // Two in the same second each get a folder of their own.
        var dest = root.appendingPathComponent("\(Int(now().timeIntervalSince1970))", isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            n += 1
            dest = root.appendingPathComponent("\(Int(now().timeIntervalSince1970))-\(n)", isDirectory: true)
        }
        ensureDirectory(dest)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name != "backups" {
            do { try fm.copyItem(at: directory.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
            catch { saveFailure = "Couldn’t back up \(name) before the change: \(error.localizedDescription)" }
        }
    }

    private func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Pretty, key-sorted JSON written atomically, then owner-only.
    private func save<T: Encodable>(_ name: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do { write(try encoder.encode(value), to: file(name)) }
        catch { saveFailure = "Couldn’t save \(name): \(error.localizedDescription)" }
    }

    /// A failed write is said, never swallowed: the screen would show a change the next
    /// launch doesn't have.
    private func write(_ data: Data, to url: URL) {
        if let locked { saveFailure = locked; return }
        ensureDirectory(url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            saveFailure = "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The dropped file, byte for byte. Named by its content hash, so the same file
    /// twice is kept once.
    private func remove(_ url: URL) {
        guard locked == nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func keepOriginal(_ data: Data, importId: String) {
        let url = directory.appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent("\(importId).csv")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(data, to: url)
    }
}

// MARK: - Banks (Settings → Banks, and the import sheet's account picker)

extension SpendingStore {
    /// The last four digits a file's name gives its account: Chase's own export name
    /// (`Chase1234_Activity_20261023.CSV`), or a name that ends in them
    /// (`Chase checking 1234.csv`, `boa-x1234.csv`). A trailing year (`statement 2026`) is not
    /// taken for digits.
    /// `export_1023`, `transactions-0131`: a month and day after `_` or `-`, not a card.
    /// "Chase checking 1023" — a space — is still read as the card the tip asks for.
    private static func looksLikeDate(_ d: String, in base: String) -> Bool {
        guard let mm = Int(d.prefix(2)), let dd = Int(d.suffix(2)), (1...12).contains(mm), (1...31).contains(dd),
              let sep = base.dropLast(4).last else { return false }
        return sep == "_" || sep == "-"
    }

    public static func lastFour(inFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        func first(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern),
                  let m = r.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
                  let g = Range(m.range(at: 1), in: base) else { return nil }
            return String(base[g])
        }
        if let d = first(#"^[A-Za-z]+(\d{4})(?!\d)"#) { return d }
        if let d = first(#"(?<!\d)(\d{4})$"#), !(1990...2039).contains(Int(d) ?? 0), !Self.looksLikeDate(d, in: base) {
            return d
        }
        return nil
    }

    /// Where Automatic would put a file, without making anything: an existing account, or
    /// the name a new one would get — for the import sheet to show before anything is done.
    public func accountGuess(for rows: [[String]], recipe: ImportRecipe, fileName: String?) -> (account: BankAccount?, newName: String) {
        let parsed = recipe.parse(rows: rows).rows
        let same = accounts.filter { $0.recipeId == recipe.id }
        let cards = Dictionary(grouping: parsed.compactMap(\.card), by: { $0 })
        let card = cards.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.key
            ?? fileName.flatMap(Self.lastFour(inFileName:))
        if let card {
            if let a = same.first(where: { $0.holds(card: card) }) { return (a, a.name) }
            if let a = mostRepeated(parsed, among: same.filter { $0.card == nil }) { return (a, a.name) }
            return (nil, "\(recipe.name) ··\(card)")
        }
        if let a = mostRepeated(parsed, among: same) { return (a, a.name) }
        if let a = same.first(where: { $0.card == nil && !overlaps(parsed, $0) }) { return (a, a.name) }
        return (nil, same.isEmpty ? recipe.name : "\(recipe.name) \(same.count + 1)")
    }

    /// A bank or account added by hand, ready for files to be imported into.
    @discardableResult
    public func addBank(name: String, colorHex: String) -> BankAccount {
        addAccount(name: name.trimmingCharacters(in: .whitespaces), colorHex: colorHex)
    }

    public func renameAccount(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].name = n
        save("accounts.json", accounts)
    }

    /// Fold one account into another: its entries, its files, its card digits (if the other
    /// has none). An entry the other already holds (same day, amount and bank text, counted
    /// the way an import counts repeats) is dropped, so nothing counts twice. Entries move
    /// under the other's ids, so a later import into it still finds them; spot edits and
    /// rule exclusions come along. Returns how many entries were dropped as repeats.
    @discardableResult
    public func mergeAccount(_ fromId: String, into toId: String) -> Int {
        guard fromId != toId, let from = accounts.first(where: { $0.id == fromId }),
              accounts.contains(where: { $0.id == toId }) else { return 0 }
        backUp()
        func tuple(_ t: BankTransaction) -> String {
            Self.tupleKey(accountId: toId, date: t.date, amount: t.amount, rawDescription: t.rawDescription)
        }
        var held: [String: Int] = [:]
        for t in transactions where t.accountId == toId { held[tuple(t), default: 0] += 1 }
        var seen: [String: Int] = [:]
        var renamed: [String: String] = [:]
        var dropped = Set<String>()
        var next = transactions
        for i in next.indices where next[i].accountId == fromId {
            let k = tuple(next[i])
            let n = seen[k, default: 0]
            seen[k] = n + 1
            if n < held[k, default: 0] { dropped.insert(next[i].id); continue }
            let id = Self.stableId(tuple: k, occurrence: n)
            renamed[next[i].id] = id
            next[i].id = id
            next[i].accountId = toId
        }
        next.removeAll { dropped.contains($0.id) && $0.accountId == fromId }
        transactions = next
        for r in rules.indices {
            rules[r].excludedTransactionIds = Set(rules[r].excludedTransactionIds.map { renamed[$0] ?? $0 })
        }
        for i in imports.indices where imports[i].accountId == fromId { imports[i].accountId = toId }
        if let t = accounts.firstIndex(where: { $0.id == toId }) {
            // Every card the merged account answered to now finds this one.
            let cards = ([from.card].compactMap { $0 } + (from.otherCards ?? [])).filter { !accounts[t].holds(card: $0) }
            if accounts[t].card == nil, let first = cards.first {
                accounts[t].card = first
                accounts[t].otherCards = Array(cards.dropFirst()).nilIfEmpty
            } else if !cards.isEmpty {
                accounts[t].otherCards = (accounts[t].otherCards ?? []) + cards
            }
        }
        accounts.removeAll { $0.id == fromId }
        resolveAll()
        save("accounts.json", accounts)
        save("transactions.json", transactions)
        save("imports.json", imports)
        save("merchants.json", rules)
        return dropped.count
    }
}


/// Helios's rules in rank order, then the seed rules, each with its pattern's words
/// worked out once.
private struct RuleSet {
    let mine: [(MerchantRule, [String])]
    let seeds: [(MerchantRule, [String])]

    init(_ rules: [MerchantRule]) {
        mine = MerchantRule.ordered(rules).map { ($0, $0.words) }
        seeds = Self.seedWords
    }

    private static let seedWords = SeedRules.all.map { ($0, $0.words) }

    /// Each field from the first rule that has one and doesn't exclude the row — Helios's
    /// rules first, then the seed rules (skipped on a row left to review, so it isn't
    /// silently categorised). Returns whether one of Helios's rules matched.
    @discardableResult
    func resolve(_ t: inout BankTransaction, text: (all: [String], stripped: [String])) -> Bool {
        var name: String?, spendCategory: String?, incomeCategory: String?, kind: TransactionKind?
        var answered = false
        func take(_ list: [(MerchantRule, [String])], mine: Bool) {
            for (rule, words) in list
            where !rule.excludedTransactionIds.contains(t.id) && rule.allows(t.amount) && rule.matches(text, words: words) {
                if mine { answered = true }
                name = name ?? rule.name
                // The first category of each kind: a Refunds rule on a shop's credit must
                // not hide the seed word that files its purchases under Groceries.
                if let c = rule.categoryId {
                    if CategoryBook.isIncomeId(c) { incomeCategory = incomeCategory ?? c }
                    else { spendCategory = spendCategory ?? c }
                }
                kind = kind ?? rule.kind
            }
        }
        take(mine, mine: true)
        if !t.toReview { take(seeds, mine: false) }
        t.merchantName = name
        t.ruleKind = kind
        let income = (t.override?.kind ?? kind ?? t.kind) == .income
        t.ruleCategoryId = income ? incomeCategory : spendCategory
        return answered
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
