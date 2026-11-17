import Foundation

/// The one place USD is formatted. Every dollar figure in the app routes through here
/// so cents show consistently and the rules live in a single spot instead of being
/// re-derived per view.
public enum Money {

    /// Read a typed amount, tolerating the way people actually write numbers.
    ///
    /// "1,054,100" and "1054100" are the same holding, and anyone copying a balance from
    /// a block explorer or a spreadsheet brings the separators with them. Rejecting that
    /// makes the field feel broken for no reason. Grouping separators — commas, spaces,
    /// underscores, apostrophes — and a leading currency symbol are stripped; the dot
    /// stays as the decimal point.
    ///
    /// Anything that isn't a plain number after that is rejected rather than partially
    /// read: `Decimal(string:)` will happily return 12 for "12abc", and silently storing
    /// a fraction of what someone typed is worse than refusing it.
    public static func amount(from text: String) -> Decimal? {
        var s = text.trimmingCharacters(in: .whitespaces)
        s.removeAll { ",_$'\u{00A0}\u{2009}\u{202F}".contains($0) || $0 == " " }
        guard !s.isEmpty else { return nil }

        // One optional leading minus, digits, and at most one decimal point.
        //
        // A leading PLUS is not accepted: nobody types "+5" as an amount, and allowing
        // it made "100++5" parse as 100 plus (+5) instead of being caught as the typo
        // it is.
        var body = Substring(s)
        if body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty,
              body.allSatisfy({ $0.isNumber || $0 == "." }),
              body.filter({ $0 == "." }).count <= 1,
              body.contains(where: { $0.isNumber })
        else { return nil }

        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Read a typed amount that may be a small sum: "100+5" is 105.
    ///
    /// Topping up a holding is the common edit — you bought five more, you didn't
    /// recalculate the total — so the field does that arithmetic rather than making the
    /// user do it in their head and retype the whole figure.
    ///
    /// Deliberately only + and −. A holding is a quantity being adjusted, not a formula;
    /// multiplication and division invite precedence questions this field has no reason
    /// to answer.
    public static func expression(from text: String) -> Decimal? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var total: Decimal?
        var term = ""
        var sign: Decimal = 1
        var first = true

        for ch in s {
            // A sign directly after another operator is part of the number, not a new
            // operator — otherwise "100+-5" would lose its meaning.
            if (ch == "+" || ch == "-"), !term.trimmingCharacters(in: .whitespaces).isEmpty {
                guard let v = amount(from: term) else { return nil }
                total = (total ?? 0) + sign * v
                sign = (ch == "+") ? 1 : -1
                term = ""
                first = false
            } else if ch == "-" , first, term.isEmpty {
                term.append(ch)       // leading minus on the first term
            } else {
                term.append(ch)
            }
        }
        guard let v = amount(from: term) else { return nil }
        return (total ?? 0) + sign * v
    }

    /// Portfolio / holding / wallet values. Always shows cents so live ticks are
    /// visible; seven-figure values compact ($1.2M) to fit columns; real sub-cent
    /// dust is guarded so it never collapses to a misleading "$0.00".
    public static func usd(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d == 0 { return "$0.00" }
        if abs(d) < 0.01 { return d > 0 ? "<$0.01" : ">-$0.01" }
        if abs(d) >= 1_000_000 {
            return "$" + d.formatted(.number.notation(.compactName).precision(.fractionLength(1)))
        }
        return d.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// Tight per-unit price for compact row displays: ≥ $0.10 → 2 decimals; smaller → up to
    /// 4 decimals; tiny → subscript-zero notation ($0.0₅633) so leading zeros don't sprawl.
    public static func price(_ value: Decimal) -> String {
        let p = NSDecimalNumber(decimal: value).doubleValue
        guard p > 0 else { return "—" }
        if p >= 0.1 { return p.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
        if p >= 0.0001 { return p.formatted(.currency(code: "USD").precision(.fractionLength(2...4))) }
        return subscriptPrice(p)
    }

    /// Fuller price for the detail modal — keeps up to 6 decimals, subscript only for tiny.
    public static func priceFull(_ value: Decimal) -> String {
        let p = NSDecimalNumber(decimal: value).doubleValue
        guard p > 0 else { return "—" }
        if p >= 1 { return p.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
        if p < 0.0001 { return subscriptPrice(p) }
        return p.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
    }

    /// Crypto subscript-zero notation: 0.00000633 → "$0.0₅633" (₅ = five leading zeros).
    private static func subscriptPrice(_ p: Double) -> String {
        let exp = Int(floor(log10(p)))            // e.g. -6 for 6.33e-6
        let zeros = -exp - 1                       // leading zeros after the decimal point
        let scaled = p / pow(10, Double(exp))      // 1.0 ..< 10.0
        let sig = Int((scaled * 100).rounded())    // 3 significant digits
        let subs = String(String(zeros).map(Self.subDigit))
        return "$0.0\(subs)\(sig)"
    }
    private static func subDigit(_ c: Character) -> Character {
        let map: [Character: Character] = ["0":"₀","1":"₁","2":"₂","3":"₃","4":"₄",
                                           "5":"₅","6":"₆","7":"₇","8":"₈","9":"₉"]
        return map[c] ?? c
    }
}
