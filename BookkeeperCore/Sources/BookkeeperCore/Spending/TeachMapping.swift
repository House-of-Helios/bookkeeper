import Foundation

/// What one column of an unknown file holds — the dropdown above each column in the
/// teach-a-bank sheet.
public enum ColumnRole: String, CaseIterable, Codable, Hashable, Sendable {
    case date = "Date"
    case description = "Description"
    case amount = "Amount"
    case moneyOut = "Money out"
    case moneyIn = "Money in"
    case bankCategory = "Bank category"
    case ignore = "Ignore"
}

/// The teach-a-bank sheet's answers so far: a role per column, which way money out is
/// signed, and the date format. Becomes an `ImportRecipe` once it names a date, a
/// description and an amount (one signed column, or a money-out + money-in pair).
public struct TeachMapping: Equatable, Sendable {
    public var roles: [ColumnRole]
    /// Only read for a single `Amount` column; a money-out / money-in pair carries its
    /// direction in the column.
    public var moneyOutIsNegative: Bool
    public var dateFormat: String

    public init(roles: [ColumnRole], moneyOutIsNegative: Bool = true, dateFormat: String = "MM/dd/yyyy") {
        self.roles = roles; self.moneyOutIsNegative = moneyOutIsNegative; self.dateFormat = dateFormat
    }

    public func column(_ role: ColumnRole) -> Int? { roles.firstIndex(of: role) }

    /// The amount source, or nil while the mapping doesn't name one.
    public var amount: ImportRecipe.Amount? {
        if let a = column(.amount) { return .signed(column: a, moneyOutIsNegative: moneyOutIsNegative) }
        if let out = column(.moneyOut), let into = column(.moneyIn) { return .split(debitColumn: out, creditColumn: into) }
        return nil
    }

    /// The recipe this mapping describes. `header` is the file's header row (fingerprint),
    /// nil for a headerless file, which is then recognised by its column count. Nil while
    /// date, description or amount is still unassigned.
    public func recipe(id: String, name: String, header: [String]?, columnCount: Int) -> ImportRecipe? {
        guard let date = column(.date), let description = column(.description), let amount else { return nil }
        return ImportRecipe(id: id, name: name,
                            headerFingerprint: header,
                            columnCount: header == nil ? columnCount : nil,
                            dateColumn: date, dateFormat: dateFormat, descriptionColumn: description,
                            amount: amount, bankCategoryColumn: column(.bankCategory))
    }
}

extension ColumnPreview {

    /// The formats the sheet can tell apart, most common first — so an all-ambiguous
    /// column (`03/04/2026`) reads the US way.
    public static let dateFormats = ["MM/dd/yyyy", "dd/MM/yyyy", "yyyy-MM-dd", "dd.MM.yyyy", "yyyy/MM/dd"]

    /// The data rows — the preview without its header row.
    public var dataRows: [[String]] { firstRowLooksLikeHeader ? Array(rows.dropFirst()) : rows }

    private func cells(_ column: Int) -> [String] {
        dataRows.compactMap { column < $0.count ? $0[column].trimmingCharacters(in: .whitespaces) : nil }
            .filter { !$0.isEmpty }
    }

    /// The first format every filled cell of `column` reads under, or nil if none does.
    public func dateFormat(column: Int) -> String? {
        let values = cells(column)
        guard !values.isEmpty else { return nil }
        return Self.dateFormats.first { f in values.allSatisfy { Day.parse($0, format: f) != nil } }
    }

    /// A first guess at the mapping, so a plain file needs no clicks at all: the first
    /// all-date column is the date; the first all-number column holding a minus is the
    /// amount (else two number columns that never both fill are money out + money in,
    /// else the first number column); the text column with the longest cells is the
    /// description. Everything else is ignored.
    public func suggestedMapping() -> TeachMapping {
        var roles = Array(repeating: ColumnRole.ignore, count: columnCount)
        let numeric = (0..<columnCount).filter { c in
            let v = cells(c)
            return !v.isEmpty && v.allSatisfy { BankAmount.parse($0) != nil } && dateFormat(column: c) == nil
        }
        let date = (0..<columnCount).first { dateFormat(column: $0) != nil }
        if let date { roles[date] = .date }

        if let signed = numeric.first(where: { c in cells(c).contains { (BankAmount.parse($0) ?? 0) < 0 } }) {
            roles[signed] = .amount
        } else if let pair = splitPair(numeric) {
            roles[pair.0] = .moneyOut; roles[pair.1] = .moneyIn
        } else if let first = numeric.first {
            roles[first] = .amount
        }

        let text = (0..<columnCount).filter { roles[$0] == .ignore && !numeric.contains($0) && !cells($0).isEmpty }
        func averageLength(_ c: Int) -> Double {
            let v = cells(c); return Double(v.reduce(0) { $0 + $1.count }) / Double(max(1, v.count))
        }
        if let description = text.max(by: { averageLength($0) < averageLength($1) }) {
            roles[description] = .description
        }
        return TeachMapping(roles: roles, moneyOutIsNegative: true,
                            dateFormat: date.flatMap { dateFormat(column: $0) } ?? Self.dateFormats[0])
    }

    /// Two number columns where no row fills both — a debit / credit pair, in file order.
    private func splitPair(_ numeric: [Int]) -> (Int, Int)? {
        for (i, a) in numeric.enumerated() {
            for b in numeric.dropFirst(i + 1) {
                let bothNever = dataRows.allSatisfy { row in
                    let x = a < row.count ? row[a].trimmingCharacters(in: .whitespaces) : ""
                    let y = b < row.count ? row[b].trimmingCharacters(in: .whitespaces) : ""
                    return x.isEmpty || y.isEmpty
                }
                if bothNever { return (a, b) }
            }
        }
        return nil
    }
}
