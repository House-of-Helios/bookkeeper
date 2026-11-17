import Foundation

/// How one bank lays out its CSV: which file it is (a header fingerprint, or "no header,
/// N columns"), where the header sits, and which column holds what. Built-ins live in
/// code (`BuiltInRecipes`); recipes taught in the mapping sheet go to `recipes.json`.
///
/// Columns are 0-based positions. Plain JSON, so a later non-Swift app reads the same file.
public struct ImportRecipe: Codable, Hashable, Identifiable, Sendable {

    /// Where the signed amount comes from. Normalised to negative = money out either way.
    public enum Amount: Codable, Hashable, Sendable {
        /// One amount column. `moneyOutIsNegative: false` for banks that write purchases
        /// positive (Amex, Discover, Apple Card) — the sign is flipped on read.
        case signed(column: Int, moneyOutIsNegative: Bool)
        /// A debit and a credit column; the column decides the direction and any sign in
        /// the cell is ignored, which reads both Capital One (both unsigned) and Citi (the
        /// credit carries a minus) without a flag.
        case split(debitColumn: Int, creditColumn: Int)
    }

    public var id: String
    public var name: String
    /// The header row, as written. Matched after `ImportRecipe.normalise`. Nil = headerless.
    public var headerFingerprint: [String]?
    /// For a headerless file: how many columns every row has.
    public var columnCount: Int?
    /// The header may sit below a preamble (Bank of America's summary block); scan the
    /// first `RecipeMatcher.preambleScan` rows for it instead of requiring row 0.
    public var skipRowsUntilHeader: Bool
    public var dateColumn: Int
    /// `MM/dd/yyyy`, `yyyy-MM-dd`, … — see `Day.parse`.
    public var dateFormat: String
    public var descriptionColumn: Int
    public var amount: Amount
    public var bankCategoryColumn: Int?
    /// A clean merchant name the bank already wrote (Apple Card's `Merchant`).
    public var bankMerchantColumn: Int?
    /// The bank's own row type (Chase "Sale" / "Return" / "Payment") — a strong kind hint.
    public var bankTypeColumn: Int?
    /// The card's number, or its last digits (Chase `Card`, Capital One `Card No.`, Amex
    /// `Account #`) — what tells two cards from the same bank apart.
    public var cardColumn: Int?

    public init(id: String, name: String, headerFingerprint: [String]? = nil, columnCount: Int? = nil,
                skipRowsUntilHeader: Bool = false, dateColumn: Int, dateFormat: String,
                descriptionColumn: Int, amount: Amount, bankCategoryColumn: Int? = nil,
                bankMerchantColumn: Int? = nil, bankTypeColumn: Int? = nil, cardColumn: Int? = nil) {
        self.id = id; self.name = name
        self.headerFingerprint = headerFingerprint; self.columnCount = columnCount
        self.skipRowsUntilHeader = skipRowsUntilHeader
        self.dateColumn = dateColumn; self.dateFormat = dateFormat
        self.descriptionColumn = descriptionColumn; self.amount = amount
        self.bankCategoryColumn = bankCategoryColumn; self.bankMerchantColumn = bankMerchantColumn
        self.bankTypeColumn = bankTypeColumn; self.cardColumn = cardColumn
    }

    /// Header cells compared case- and spacing-blind, trailing empty cells dropped — a
    /// bank that re-capitalises a column or adds a trailing comma is still the same bank.
    public static func normalise(_ header: [String]) -> [String] {
        var cells = header.map {
            $0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        while cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    // MARK: - Fitting a file

    /// The row index of the header in `rows`, `-1` for a headerless file that fits, nil
    /// when this recipe doesn't describe the file at all.
    public func headerIndex(in rows: [[String]]) -> Int? {
        if let fingerprint = headerFingerprint {
            let want = Self.normalise(fingerprint)
            let scan = skipRowsUntilHeader ? min(rows.count, RecipeMatcher.preambleScan) : min(rows.count, 1)
            return (0..<scan).first { Self.normalise(rows[$0]) == want }
        }
        guard let count = columnCount,
              let first = rows.first(where: { !Self.isBlank($0) }),
              first.count == count, parseRow(first) != nil else { return nil }
        return -1
    }

    // MARK: - Reading rows

    /// Parse every data row of a file this recipe fits. Rows after the header that don't
    /// read (an opening-balance line with no amount, a footer) are listed in `skipped`
    /// by their row index, never guessed at.
    public func parse(text: String) -> ParsedFile { parse(rows: CSV.parse(text)) }

    public func parse(rows: [[String]]) -> ParsedFile {
        let start = (headerIndex(in: rows) ?? (headerFingerprint == nil ? -1 : 0)) + 1
        var parsed: [ParsedRow] = [], skipped: [Int] = []
        for i in start..<max(start, rows.count) where !Self.isBlank(rows[i]) {
            if var row = parseRow(rows[i]) { row.line = i; parsed.append(row) } else { skipped.append(i) }
        }
        return ParsedFile(rows: parsed, skipped: skipped)
    }

    /// One row under this mapping, or nil if its date or amount doesn't read.
    public func parseRow(_ cells: [String]) -> ParsedRow? {
        func cell(_ i: Int?) -> String? {
            guard let i, i >= 0, i < cells.count else { return nil }
            let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        guard let dateText = cell(dateColumn), let day = Day.parse(dateText, format: dateFormat),
              let description = cell(descriptionColumn) else { return nil }
        let value: Decimal
        switch amount {
        case let .signed(column, moneyOutIsNegative):
            guard let a = cell(column).flatMap(BankAmount.parse) else { return nil }
            value = moneyOutIsNegative ? a : -a
        case let .split(debit, credit):
            if let d = cell(debit).flatMap(BankAmount.parse), d != 0 { value = -abs(d) }
            else if let c = cell(credit).flatMap(BankAmount.parse) { value = abs(c) }
            else { return nil }
        }
        return ParsedRow(date: day, amount: value, description: description,
                         bankMerchant: cell(bankMerchantColumn), bankCategory: cell(bankCategoryColumn),
                         bankType: cell(bankTypeColumn), card: cell(cardColumn).flatMap(Self.lastFour))
    }

    /// A card cell's last four digits — `4417`, `XXXX-XXXXXX-41007` → `1007`. Nil when it
    /// holds fewer than four.
    static func lastFour(_ cell: String) -> String? {
        let digits = cell.filter(\.isASCII).filter(\.isNumber)
        return digits.count >= 4 ? String(digits.suffix(4)) : nil
    }

    static func isBlank(_ row: [String]) -> Bool {
        row.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// One bank row, read and sign-normalised but not yet in the ledger.
public struct ParsedRow: Equatable, Sendable {
    public var date: Day
    /// Negative = money out.
    public var amount: Decimal
    /// The bank's text, exactly as written (trimmed).
    public var description: String
    public var bankMerchant: String?
    public var bankCategory: String?
    public var bankType: String?
    /// The card's last four digits, where the bank writes them.
    public var card: String?
    /// Row index in the file (0-based, counting the header and any preamble).
    public var line: Int = 0
}

public struct ParsedFile: Equatable, Sendable {
    public var rows: [ParsedRow]
    /// Row indices after the header that didn't read.
    public var skipped: [Int]
}

/// Picks the recipe for a dropped file by its shape alone.
public enum RecipeMatcher {
    /// How far down a preamble can push the header.
    public static let preambleScan = 10

    /// The first recipe that fits, trying header fingerprints before headerless shapes
    /// (a headerless recipe only checks column count and a readable first row, so it
    /// would otherwise claim files a fingerprint describes exactly). `among` lists
    /// user-taught recipes first so a taught shape wins over a built-in. Nil = unknown,
    /// and the mapping sheet takes over.
    public static func match(_ text: String,
                             among recipes: [ImportRecipe] = BuiltInRecipes.all) -> ImportRecipe? {
        match(rows: CSV.parse(text), among: recipes)
    }

    public static func match(rows: [[String]], among recipes: [ImportRecipe]) -> ImportRecipe? {
        let ordered = recipes.filter { $0.headerFingerprint != nil } + recipes.filter { $0.headerFingerprint == nil }
        return ordered.first { $0.headerIndex(in: rows) != nil }
    }
}

/// The mapping sheet's view of an unknown file: its first rows split into columns, and a
/// live parse of them under the mapping chosen so far.
public struct ColumnPreview: Equatable, Sendable {
    public let rows: [[String]]
    public let columnCount: Int

    public init(text: String, limit: Int = 5) {
        rows = Array(CSV.parse(text).filter { !ImportRecipe.isBlank($0) }.prefix(limit))
        columnCount = rows.map(\.count).max() ?? 0
    }

    /// The header row it (probably) has — the fingerprint a taught recipe saves.
    public var header: [String]? { firstRowLooksLikeHeader ? rows.first : nil }

    /// A header row holds no date and no amount; a data row holds both.
    public var firstRowLooksLikeHeader: Bool {
        guard let first = rows.first else { return false }
        let hasNumber = first.contains { BankAmount.parse($0) != nil }
        let hasDate = first.contains { cell in
            ["MM/dd/yyyy", "yyyy-MM-dd", "dd.MM.yyyy"].contains { Day.parse(cell, format: $0) != nil }
        }
        return !hasNumber && !hasDate
    }

    /// One entry per preview row: the parsed transaction, or nil for the header row and
    /// any row the mapping can't read yet.
    public func apply(_ mapping: ImportRecipe) -> [ParsedRow?] {
        let headerAt = mapping.headerIndex(in: rows)
        return rows.indices.map { i in i == headerAt ? nil : mapping.parseRow(rows[i]) }
    }
}
