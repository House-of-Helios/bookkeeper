import Foundation

/// A calendar day with no time and no time zone. Bank exports are day-precise, and a
/// `Date` at midnight drifts a day the moment it meets a zone west of UTC — so the
/// ledger never holds one. Stored as `yyyy-MM-dd` text.
public struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Nil for a day that doesn't exist (30 February).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...Self.daysIn(month, of: year)).contains(day) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// For literals in code and tests, where the day is known to exist.
    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.init(year: year, month: month, day: day)!
    }

    /// `yyyy-MM-dd`.
    public init?(iso: String) {
        guard let d = Self.parse(iso, format: "yyyy-MM-dd") else { return nil }
        self = d
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }
    public var yearMonth: Month { Month(year, month) }

    public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    // MARK: Arithmetic — through a day count, so no calendar or zone is involved.

    /// Days since 1970-01-01 (Hinnant's civil algorithm).
    var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(ordinal z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }

    public func adding(days n: Int) -> Day { Day(ordinal: ordinal + n) }
    public func days(since other: Day) -> Int { ordinal - other.ordinal }

    static func daysIn(_ month: Int, of year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // MARK: Reading a bank's date column

    /// Read `text` in a recipe's `format` — `MM/dd/yyyy`, `yyyy-MM-dd`, `dd.MM.yyyy`, …
    /// Only the order of the y / M / d runs matters; separators and zero-padding are
    /// forgiven (`2/3/2026` reads under `MM/dd/yyyy`). A two-digit year is 20xx.
    public static func parse(_ text: String, format: String) -> Day? {
        let order = format.reduce(into: [Character]()) { acc, ch in
            if "yMd".contains(ch), acc.last != ch { acc.append(ch) }
        }
        let numbers = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard order.count == 3, numbers.count == 3,
              text.trimmingCharacters(in: .whitespaces).first?.isNumber == true else { return nil }
        var y = 0, m = 0, d = 0
        for (key, digits) in zip(order, numbers) {
            guard let n = Int(digits), digits.count <= 4 else { return nil }
            switch key {
            case "y": y = digits.count <= 2 ? 2000 + n : n
            case "M": m = n
            default: d = n
            }
        }
        return Day(year: y, month: m, day: d)
    }

    // MARK: Codable — plain `yyyy-MM-dd` text

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(iso: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a yyyy-MM-dd day: \(text)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

/// A calendar month — the unit the range strip and its presets work in. `yyyy-MM`.
public struct Month: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(_ year: Int, _ month: Int) {
        precondition((1...12).contains(month), "month \(month)")
        self.year = year; self.month = month
    }

    public var next: Month { month == 12 ? Month(year + 1, 1) : Month(year, month + 1) }
    public var previous: Month { month == 1 ? Month(year - 1, 12) : Month(year, month - 1) }
    public var description: String { String(format: "%04d-%02d", year, month) }

    public static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let p = text.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2, (1...12).contains(p[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a yyyy-MM month: \(text)"))
        }
        self.init(p[0], p[1])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A bank's amount cell, read exactly. Banks write `-4.50`, `"-1,204.18"`, `$12.00`,
/// `(12.00)` for a negative, `+3`. Nil for an empty or non-numeric cell.
public enum BankAmount {
    public static func parse(_ text: String) -> Decimal? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        s = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("+") { s.removeFirst() }
        if s.hasPrefix("-") { negative.toggle(); s.removeFirst() }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              s.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }
}
