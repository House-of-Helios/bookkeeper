import Foundation

/// One category, spend or income. `icon` is an asset name (`steaming_bowl`), not a glyph.
public struct SpendingCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var colorHex: String
    public var icon: String
    /// A fixed cost (rent, utilities) — set aside in the Everyday view so it doesn't turn
    /// everything else into slivers.
    public var fixed: Bool

    public init(id: String, name: String, colorHex: String, icon: String, fixed: Bool = false) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.icon = icon; self.fixed = fixed
    }
}

/// The category edits the Edit sheet makes — only the fields changed, over a default.
public struct CategoryEdit: Codable, Hashable, Sendable {
    public var name: String?
    public var colorHex: String?
    public var icon: String?

    public init(name: String? = nil, colorHex: String? = nil, icon: String? = nil) {
        self.name = name; self.colorHex = colorHex; self.icon = icon
    }
}

/// The spend categories in ring order, the income list beside them, and the editable
/// lists that classify rows on import. The defaults live in code; `categories.json`
/// holds only what differs from them — a renamed or recoloured category, an edited
/// pattern list — so a later version's better defaults still reach every untouched one,
/// and a category added since the file was written (Cash) simply appears in its place.
public struct CategoryBook: Codable, Hashable, Sendable {
    /// Ring order — fixed, never sorted by size, so colour follows the category.
    public var categories: [SpendingCategory]
    /// Money in. Never in the spending ring or its totals.
    public var incomeCategories: [SpendingCategory]
    /// A bank's own category word (compared case-blind) → ours.
    public var bankCategoryMap: [String: String]
    /// Description fragments (case-blind) that mark a transfer: card payments and moves
    /// between your own accounts. Not bare `AUTOPAY` — a bill on autopay is still a bill.
    public var transferPatterns: [String]
    /// Description fragments that make a positive amount a refund, not income.
    public var refundPatterns: [String]
    /// Description fragments (case-blind) → an income category, first hit wins.
    public static let incomePatterns: [(String, String)] = [
        ("PAYROLL", "pay"), ("DIRECT DEP", "pay"), ("SALARY", "pay"),
        ("TAX REF", "back"), ("IRS TREAS", "back"),
        ("INTEREST", "int"), ("DIVIDEND", "int"),
    ]

    public static let fallbackId = "else"

    /// A kind of income's id, not a spending category's. Ids never change (categories are
    /// renamed and recoloured, never added), so the built-in list answers for every book.
    public static func isIncomeId(_ id: String) -> Bool { incomeIds.contains(id) }
    private static let incomeIds = Set(defaultIncome.map(\.id))
    public static let incomeFallbackId = "oin"

    public init(categories: [SpendingCategory], incomeCategories: [SpendingCategory] = CategoryBook.defaultIncome,
                bankCategoryMap: [String: String], transferPatterns: [String], refundPatterns: [String]) {
        self.categories = categories; self.incomeCategories = incomeCategories
        self.bankCategoryMap = bankCategoryMap
        self.transferPatterns = transferPatterns; self.refundPatterns = refundPatterns
    }

    /// A spend or income category by id.
    public func category(_ id: String) -> SpendingCategory? {
        categories.first { $0.id == id } ?? incomeCategories.first { $0.id == id }
    }

    /// Ours for a bank's category word, if the map knows it.
    public func categoryId(forBank bankCategory: String?) -> String? {
        guard let key = bankCategory?.trimmingCharacters(in: .whitespaces).lowercased(), !key.isEmpty
        else { return nil }
        if let hit = bankCategoryMap[key] { return hit }
        return bankCategoryMap.first { $0.key.lowercased() == key }?.value
    }

    /// The income category for a money-in line: pay, interest, else Other income.
    public func incomeCategoryId(for description: String) -> String {
        let text = description.uppercased()
        return Self.incomePatterns.first { text.contains($0.0) }?.1 ?? Self.incomeFallbackId
    }

    /// Apply a sheet edit to one category, spend or income. Unknown id: no change.
    public mutating func update(_ id: String, with edit: CategoryEdit) {
        func apply(_ c: inout SpendingCategory) {
            if let n = edit.name { c.name = n }
            if let h = edit.colorHex { c.colorHex = h }
            if let i = edit.icon { c.icon = i }
        }
        if let i = categories.firstIndex(where: { $0.id == id }) { apply(&categories[i]) }
        else if let i = incomeCategories.firstIndex(where: { $0.id == id }) { apply(&incomeCategories[i]) }
    }

    // MARK: Codable — edits over the defaults

    private enum CodingKeys: String, CodingKey {
        case edits, bankCategoryMap, transferPatterns, refundPatterns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = CategoryBook.defaults
        self = base
        bankCategoryMap = try c.decodeIfPresent([String: String].self, forKey: .bankCategoryMap) ?? base.bankCategoryMap
        transferPatterns = try c.decodeIfPresent([String].self, forKey: .transferPatterns) ?? base.transferPatterns
        refundPatterns = try c.decodeIfPresent([String].self, forKey: .refundPatterns) ?? base.refundPatterns
        let edits = try c.decodeIfPresent([String: CategoryEdit].self, forKey: .edits) ?? [:]
        for (id, edit) in edits { update(id, with: edit) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let base = CategoryBook.defaults
        var edits: [String: CategoryEdit] = [:]
        for now in categories + incomeCategories {
            guard let was = base.category(now.id) else { continue }
            let edit = CategoryEdit(name: now.name == was.name ? nil : now.name,
                                    colorHex: now.colorHex == was.colorHex ? nil : now.colorHex,
                                    icon: now.icon == was.icon ? nil : now.icon)
            if edit != CategoryEdit() { edits[now.id] = edit }
        }
        try c.encode(edits, forKey: .edits)
        if bankCategoryMap != base.bankCategoryMap { try c.encode(bankCategoryMap, forKey: .bankCategoryMap) }
        if transferPatterns != base.transferPatterns { try c.encode(transferPatterns, forKey: .transferPatterns) }
        if refundPatterns != base.refundPatterns { try c.encode(refundPatterns, forKey: .refundPatterns) }
    }

    public static func == (a: CategoryBook, b: CategoryBook) -> Bool {
        a.categories == b.categories && a.incomeCategories == b.incomeCategories
            && a.bankCategoryMap == b.bankCategoryMap && a.transferPatterns == b.transferPatterns
            && a.refundPatterns == b.refundPatterns
    }

    public func hash(into h: inout Hasher) {
        h.combine(categories); h.combine(incomeCategories); h.combine(bankCategoryMap)
        h.combine(transferPatterns); h.combine(refundPatterns)
    }

    // MARK: Defaults

    /// Mockup v3's lighter Nippon set, ring order fixed and colourblind-checked (worst
    /// neighbour ΔE 8.8) — see `_Plan/2026-10-20-bookeeper-v2-spending.md`.
    public static let defaultSpend: [SpendingCategory] = [
        SpendingCategory(id: "groc", name: "Groceries", colorHex: "#90B44B", icon: "leafy_green"),
        SpendingCategory(id: "eat", name: "Eating out", colorHex: "#E83015", icon: "steaming_bowl"),
        SpendingCategory(id: "cafe", name: "Cafés", colorHex: "#D19826", icon: "hot_beverage"),
        SpendingCategory(id: "move", name: "Transport", colorHex: "#7B90D2", icon: "metro"),
        SpendingCategory(id: "heal", name: "Health", colorHex: "#5DAC81", icon: "pill"),
        SpendingCategory(id: "fit", name: "Fitness", colorHex: "#F7D94C", icon: "running_shoe"),
        SpendingCategory(id: "fun", name: "Entertainment", colorHex: "#986DB2", icon: "admission_tickets"),
        SpendingCategory(id: "trip", name: "Travel", colorHex: "#2EA9DF", icon: "airplane"),
        SpendingCategory(id: "edu", name: "Education", colorHex: "#FB966E", icon: "graduation_cap"),
        SpendingCategory(id: "pet", name: "Pets", colorHex: "#86C166", icon: "paw_prints"),
        SpendingCategory(id: "shop", name: "Shopping", colorHex: "#E03C8A", icon: "shopping_bags"),
        SpendingCategory(id: "wear", name: "Clothing", colorHex: "#A5DEE4", icon: "t_shirt"),
        SpendingCategory(id: "house", name: "Home", colorHex: "#DC9FB4", icon: "couch_and_lamp"),
        // Fixed costs: the same every month, or one big payment a year — set aside in the
        // Spending view so they don't turn everything else into slivers; counted in Total.
        SpendingCategory(id: "home", name: "Rent", colorHex: "#C1693C", icon: "house", fixed: true),
        SpendingCategory(id: "util", name: "Utilities", colorHex: "#6A4C9C", icon: "light_bulb", fixed: true),
        SpendingCategory(id: "tax", name: "Taxes", colorHex: "#81C7D4", icon: "classical_building", fixed: true),
        SpendingCategory(id: "ins", name: "Insurance", colorHex: "#E87A90", icon: "shield", fixed: true),
        SpendingCategory(id: "debt", name: "Loans", colorHex: "#A8D8B9", icon: "credit_card", fixed: true),
        SpendingCategory(id: "subs", name: "Subscriptions", colorHex: "#3A8FB7", icon: "television"),
        SpendingCategory(id: "care", name: "Personal care", colorHex: "#E98B2A", icon: "lotion_bottle"),
        SpendingCategory(id: "gift", name: "Gifts & giving", colorHex: "#D0104C", icon: "wrapped_gift"),
        SpendingCategory(id: "fee", name: "Fees", colorHex: "#7DB9DE", icon: "heavy_dollar_sign"),
        // ATM withdrawals: spent, just not anywhere the bank can say.
        SpendingCategory(id: "cash", name: "Cash", colorHex: "#FFB11B", icon: "dollar_banknote"),
        SpendingCategory(id: fallbackId, name: "Other", colorHex: "#8C9196", icon: "package"),
    ]

    /// Never on the ring, so the colours only need to tell the five apart in a list.
    public static let defaultIncome: [SpendingCategory] = [
        SpendingCategory(id: "pay", name: "Paycheck", colorHex: "#7BA23F", icon: "briefcase"),
        SpendingCategory(id: "side", name: "Side income", colorHex: "#33A6B8", icon: "laptop"),
        SpendingCategory(id: "int", name: "Interest & dividends", colorHex: "#E2943B", icon: "chart_increasing"),
        SpendingCategory(id: "back", name: "Refunds", colorHex: "#B481BB", icon: "counterclockwise_arrows_button"),
        SpendingCategory(id: incomeFallbackId, name: "Other income", colorHex: "#8C9196", icon: "money_bag"),
    ]

    public static let defaults = CategoryBook(
        categories: defaultSpend,
        incomeCategories: defaultIncome,
        // Keys lowercased. Banks lump cafés into dining and airlines into travel; the seed
        // rules (`SeedRules`) pull those back out by word.
        bankCategoryMap: [
            // Chase — "Travel" is mostly rides and transit in practice; airlines and
            // hotels are caught by seed words.
            "food & drink": "eat", "groceries": "groc", "travel": "move", "shopping": "shop",
            "entertainment": "fun", "bills & utilities": "util", "health & wellness": "heal",
            "gas": "move", "home": "house", "personal": "care", "fees & adjustments": "fee",
            "gifts & donations": "gift", "automotive": "move", "education": "edu",
            "professional services": fallbackId,
            // Capital One
            "dining": "eat", "grocery": "groc", "other travel": "move", "merchandise": "shop",
            "phone/cable": "util", "health care": "heal", "gas/automotive": "move",
            "airfare": "trip", "lodging": "trip", "utilities": "util", "insurance": "ins",
            "home improvement": "house", "clothing": "wear", "pets": "pet", "fees": "fee",
            // Discover — "Travel/ Entertainment" is one bucket; fun is the better guess,
            // and an airline or hotel in it goes to Travel by seed word.
            "restaurants": "eat", "supermarkets": "groc", "travel/ entertainment": "fun",
            "medical services": "heal", "services": fallbackId, "gasoline": "move",
            // Apple Card
            "transportation": "move", "medical": "heal", "other": fallbackId,
        ],
        transferPatterns: [
            "PAYMENT THANK YOU", "PAYMENT - THANK YOU", "AUTOPAY PAYMENT", "AUTOPAY PYMT",
            "AUTOMATIC PAYMENT", "CARD PAYMENT", "CREDIT CRD", "CREDIT CARD BILL PAYMENT",
            "CREDIT CARD AUTO PAY", "ONLINE TRANSFER", "TRANSFER TO", "TRANSFER FROM",
            "MOBILE PYMT", "ONLINE PYMT", "INTERNET TRANSFER",
        ],
        refundPatterns: ["RETURN", "REFUND"])
}

/// Default kind for a fresh row. Order: transfer patterns (and a bank "Payment" type),
/// then sign — money out is spend; money in is income unless the bank calls it a return
/// or the text says refund, which is spend with a positive amount (it shrinks its
/// category). A per-transaction override beats all of this, at read time.
public struct KindClassifier: Sendable {
    public let book: CategoryBook

    public init(book: CategoryBook) { self.book = book }

    public func kind(amount: Decimal, description: String, bankType: String?) -> TransactionKind {
        let text = Self.words(description)
        let type = bankType?.trimmingCharacters(in: .whitespaces).lowercased()
        // Punctuation aside, so Citi's "ONLINE PAYMENT, THANK YOU" reads like Chase's.
        if type == "payment" || book.transferPatterns.contains(where: { text.contains(Self.words($0)) }) {
            return .transfer
        }
        guard amount > 0 else { return .spend }
        // Whole words: "RETURNED" or "REFUNDABLE" in a paycheck's text is no refund.
        let padded = " \(text) "
        if type == "return" || type == "refund"
            || book.refundPatterns.contains(where: { let w = Self.words($0); return padded.contains(" \(w) ") || padded.contains(" \(w)S ") }) {
            return .spend
        }
        return .income
    }

    /// Upper-cased, every run of non-letters-or-digits one space.
    static func words(_ s: String) -> String {
        s.uppercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
