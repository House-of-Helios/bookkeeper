import Foundation

/// One bank account or card the ledger holds rows for. `recipeId` is the shape its
/// exports came in last — filled on first import.
public struct BankAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var recipeId: String?
    public var colorHex: String
    /// The card's last four digits, when its bank's file carries them — two cards from
    /// one bank are two accounts.
    public var card: String?
    /// Cards of accounts merged into this one: their files still find it.
    public var otherCards: [String]?

    public init(id: String = UUID().uuidString, name: String, recipeId: String? = nil, colorHex: String,
                card: String? = nil) {
        self.id = id; self.name = name; self.recipeId = recipeId; self.colorHex = colorHex; self.card = card
    }

    /// This account's card, or one merged into it.
    public func holds(card c: String) -> Bool { card == c || (otherCards ?? []).contains(c) }
}

/// The fixed layer above categories. Transfers (card payments, moves between your own
/// accounts) are never spend — counting them is the classic double count.
public enum TransactionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case spend, income, transfer
}

/// A spot edit on ONE transaction — "change just this one". Always beats rules and the
/// defaults; any field left nil falls through to them.
public struct TransactionOverride: Codable, Hashable, Sendable {
    public var name: String?
    public var categoryId: String?
    public var kind: TransactionKind?

    public init(name: String? = nil, categoryId: String? = nil, kind: TransactionKind? = nil) {
        self.name = name; self.categoryId = categoryId; self.kind = kind
    }

    public var isEmpty: Bool { name == nil && categoryId == nil && kind == nil }
}

/// One normalised ledger row in `transactions.json`.
public struct BankTransaction: Codable, Hashable, Identifiable, Sendable {
    /// Stable across re-imports — `SpendingStore.stableId`.
    public var id: String
    public var accountId: String
    public var date: Day
    /// Negative = money out, whatever the bank wrote. Stored as exact text.
    public var amount: Decimal
    /// The bank's text. Never edited — rules (Stage 3) match it, so it must stay as written.
    public var rawDescription: String
    /// A clean name the bank supplied (Apple Card's `Merchant`).
    public var bankMerchant: String?
    public var bankCategory: String?
    /// The bank's row type ("Sale", "Return", "Payment"), where it gives one.
    public var bankType: String?
    /// The import this row arrived in — names the kept copy `imports/<importId>.csv`.
    public var importId: String
    /// The default kind, as classified on import.
    public var kind: TransactionKind
    /// Seeded from the bank's category; Stage 3 rules write here too.
    public var categoryId: String?
    /// The clean name from the first merchant rule that has one. Rule fields are
    /// derived — the store rewrites them whenever its rules change — and stored so the
    /// file reads whole on its own.
    public var merchantName: String?
    /// The category from the first matching rule (Helios's, then the seed rules).
    public var ruleCategoryId: String?
    /// The kind from the first matching rule that sets one.
    public var ruleKind: TransactionKind?
    public var override: TransactionOverride?
    /// False only while an import left a question on this row (a near-duplicate).
    public var reviewed: Bool
    /// An import couldn't tell whether this money left for good (`ZELLE TO …`, `VENMO`):
    /// left uncategorised for Helios to answer.
    public var toReview: Bool

    public init(id: String, accountId: String, date: Day, amount: Decimal, rawDescription: String,
                bankMerchant: String? = nil, bankCategory: String? = nil, bankType: String? = nil,
                importId: String, kind: TransactionKind, categoryId: String? = nil,
                merchantName: String? = nil, ruleCategoryId: String? = nil, ruleKind: TransactionKind? = nil,
                override: TransactionOverride? = nil, reviewed: Bool = true, toReview: Bool = false) {
        self.id = id; self.accountId = accountId; self.date = date; self.amount = amount
        self.rawDescription = rawDescription; self.bankMerchant = bankMerchant
        self.bankCategory = bankCategory; self.bankType = bankType; self.importId = importId
        self.kind = kind; self.categoryId = categoryId; self.merchantName = merchantName
        self.ruleCategoryId = ruleCategoryId; self.ruleKind = ruleKind
        self.override = override; self.reviewed = reviewed; self.toReview = toReview
    }

    // MARK: What the screen shows — the override first, always

    // Every field resolves the same way: this line's override → the first matching
    // rule → the import's defaults (bank merchant, bank category, classifier) → raw.

    public var effectiveKind: TransactionKind { override?.kind ?? ruleKind ?? kind }

    /// Override → rule → bank-seeded → "Other" ("Other income" for money in) — each
    /// taken only if it belongs to the line's kind now. Edits and rules store only what was
    /// changed, so a category is read by what it is, not by which kind came with it: a rule
    /// that only picks Paycheck counts on money in; a seed word's spend category (UNIVERSITY
    /// → Education) never lands on a paycheck; a spot category from before a kind change
    /// steps aside rather than fold into "Other".
    public var effectiveCategoryId: String {
        let income = effectiveKind == .income
        func fits(_ id: String?) -> String? { id.flatMap { CategoryBook.isIncomeId($0) == income ? $0 : nil } }
        return fits(override?.categoryId) ?? fits(ruleCategoryId) ?? fits(categoryId)
            ?? (income ? CategoryBook.incomeFallbackId : CategoryBook.fallbackId)
    }

    /// In the To review queue: a near-duplicate, or a transfer-ish line nobody answered.
    public var needsReview: Bool { !reviewed || toReview }

    /// Override name → rule name (Stage 3) → the bank's clean merchant → the raw text.
    public var displayName: String {
        override?.name ?? merchantName ?? bankMerchant ?? rawDescription
    }

    /// What this row adds to spend: positive for a purchase, negative for a refund, zero
    /// for income and transfers.
    public var spendAmount: Decimal { effectiveKind == .spend ? -amount : 0 }

    // MARK: Codable — the amount as exact text, so no reader meets a binary float

    private enum CodingKeys: String, CodingKey {
        case id, accountId, date, amount, rawDescription, bankMerchant, bankCategory, bankType
        case importId, kind, categoryId, merchantName, ruleCategoryId, ruleKind, override, reviewed, toReview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .amount)
        guard let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw DecodingError.dataCorruptedError(forKey: .amount, in: c, debugDescription: "amount \(text)")
        }
        self.init(id: try c.decode(String.self, forKey: .id),
                  accountId: try c.decode(String.self, forKey: .accountId),
                  date: try c.decode(Day.self, forKey: .date),
                  amount: amount,
                  rawDescription: try c.decode(String.self, forKey: .rawDescription),
                  bankMerchant: try c.decodeIfPresent(String.self, forKey: .bankMerchant),
                  bankCategory: try c.decodeIfPresent(String.self, forKey: .bankCategory),
                  bankType: try c.decodeIfPresent(String.self, forKey: .bankType),
                  importId: try c.decode(String.self, forKey: .importId),
                  kind: try c.decode(TransactionKind.self, forKey: .kind),
                  categoryId: try c.decodeIfPresent(String.self, forKey: .categoryId),
                  merchantName: try c.decodeIfPresent(String.self, forKey: .merchantName),
                  ruleCategoryId: try c.decodeIfPresent(String.self, forKey: .ruleCategoryId),
                  ruleKind: try c.decodeIfPresent(TransactionKind.self, forKey: .ruleKind),
                  override: try c.decodeIfPresent(TransactionOverride.self, forKey: .override),
                  reviewed: try c.decodeIfPresent(Bool.self, forKey: .reviewed) ?? true,
                  toReview: try c.decodeIfPresent(Bool.self, forKey: .toReview) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(accountId, forKey: .accountId)
        try c.encode(date, forKey: .date)
        try c.encode("\(amount)", forKey: .amount)
        try c.encode(rawDescription, forKey: .rawDescription)
        try c.encodeIfPresent(bankMerchant, forKey: .bankMerchant)
        try c.encodeIfPresent(bankCategory, forKey: .bankCategory)
        try c.encodeIfPresent(bankType, forKey: .bankType)
        try c.encode(importId, forKey: .importId)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(categoryId, forKey: .categoryId)
        try c.encodeIfPresent(merchantName, forKey: .merchantName)
        try c.encodeIfPresent(ruleCategoryId, forKey: .ruleCategoryId)
        try c.encodeIfPresent(ruleKind, forKey: .ruleKind)
        try c.encodeIfPresent(override, forKey: .override)
        try c.encode(reviewed, forKey: .reviewed)
        if toReview { try c.encode(toReview, forKey: .toReview) }
    }
}

/// What the edit drawer saves: any field left nil is left as it is.
public struct TransactionEdit: Hashable, Sendable {
    public var name: String?
    /// A spend category, or an income one when the line counts as income.
    public var categoryId: String?
    public var kind: TransactionKind?

    public init(name: String? = nil, categoryId: String? = nil, kind: TransactionKind? = nil) {
        self.name = name; self.categoryId = categoryId; self.kind = kind
    }
}

/// The drawer's two buttons.
public enum EditScope: Hashable, Sendable {
    /// A spot edit on the one line — beats every rule.
    case justThisOne
    /// A rule: every line the pattern matches now, bar the unticked, and every future import.
    /// `direction` keeps it to money one way (a payment app's line); nil, either way.
    case allLikeThis(pattern: String, match: MerchantRule.Match, unticked: Set<String>,
                     direction: MerchantRule.Direction? = nil)
}

/// What the drawer opens with.
public struct EditPreview: Hashable, Sendable {
    public var transaction: BankTransaction
    /// The cleaned core of the bank text — the pattern chip.
    public var core: String
    /// The name already chosen for this line (spot edit, rule, bank), else the title-cased core.
    public var suggestedName: String
    public var match: MerchantRule.Match
    /// Every line the core matches, chronological — "All like this", each with a tick.
    public var likeThis: [BankTransaction]
    /// Set for a payment app's line: "All like this" keeps to money going this way.
    public var direction: MerchantRule.Direction? = nil
}

/// One drop, in `imports.json`: where it came from and what it did. Counts only — no
/// bank text.
public struct ImportRecord: Codable, Hashable, Sendable {
    public var importId: String
    /// The dropped file's name; nil for pasted text.
    public var fileName: String?
    public var accountId: String
    public var recipeId: String
    /// Whole seconds, ISO 8601 in the file.
    public var importedAt: Date
    public var added: Int
    public var alreadyHere: Int
    public var toReview: Int
    public var skipped: Int
    /// The one card this record took from a file holding several; nil = the whole file.
    public var card: String?

    public init(importId: String, fileName: String?, accountId: String, recipeId: String, importedAt: Date,
                added: Int, alreadyHere: Int, toReview: Int, skipped: Int, card: String? = nil) {
        self.importId = importId; self.fileName = fileName; self.accountId = accountId; self.card = card
        self.recipeId = recipeId
        self.importedAt = Date(timeIntervalSince1970: importedAt.timeIntervalSince1970.rounded(.down))
        self.added = added; self.alreadyHere = alreadyHere; self.toReview = toReview; self.skipped = skipped
    }
}
