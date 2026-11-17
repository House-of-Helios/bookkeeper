import Foundation

/// The bank's text, cleaned. `core` is the edit drawer's pattern chip ("MR KALE" out of
/// `SQ *MR KALE BKLYN`); `tokens` is the form every rule matches against, so a pattern and
/// the text it's tested on are always cleaned the same way.
public enum MerchantCore {

    /// The cleaned core: bank and processor prefixes off, everything from a mid-text `*`
    /// on dropped (a reference, not a name), numbers and filler words out round the edges,
    /// cut at the first place name, then the first three words (with any number between
    /// them). Never empty for non-empty text — all
    /// noise falls back to the raw words.
    /// `amount`, when known, picks the other party on a payment line naming both
    /// (`ZELLE PAYMENT FROM YOU "CHECKING" TO FRED LEE`): money out is about whoever it went
    /// to, money in about whoever it came from.
    public static func core(_ raw: String, amount: Decimal? = nil) -> String {
        // A payment app's line is about a person, wherever the bank puts them.
        if isPayment(raw), let person = paymentPerson(raw, outgoing: amount.map { $0 < 0 }) { return person }
        // A transfer is about the account at the other end, so each account is its own rule.
        if let account = transferAccount(raw) { return account }
        var text = stripPrefixes(fold(raw))
        if let star = text.firstIndex(of: "*") { text = String(text[..<star]) }
        // A web name ends the merchant: `STREAMLY.TV SUBSCRIPTION` → `STREAMLY`. Cut, not
        // removed, or the words either side would close up into a pair the bank never wrote.
        if let dot = text.range(of: #"\.(COM|NET|ORG|TV|IO)\b"#, options: .regularExpression) {
            text = String(text[..<dot.lowerBound])
        }
        text = text.replacingOccurrences(of: #"[^A-Z0-9'\-]+"#, with: " ", options: .regularExpression)

        var tokens: [(word: String, noise: Bool)] = []
        for token in text.split(separator: " ").map(String.init) {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "-'"))
            guard !word.isEmpty else { continue }
            tokens.append((word, isNoise(word)))
        }
        // The first three real words, cut at a place name — but kept as the run of the
        // bank's text they span, so a number *inside* the name stays (`PIER 6 OYSTER BAR`,
        // not `PIER OYSTER BAR`). A rule matches whole words side by side, so a core with
        // a word lifted out of its middle would match no line, not even its own.
        var names = cutAtPlace(tokens.filter { !$0.noise }.map(\.word))
        // A payment app's line names a person, not a shop: `ZELLE PAYMENT FROM JOHN DOE`.
        // The person is the merchant, so the core runs on through their name — up to five
        // words, stopping where the bank's own bookkeeping starts (`ON 10/02`, `REF #`).
        let payment = isPaymentApp(names)
        if payment, let stop = names.dropFirst().firstIndex(where: { paymentStops.contains($0) }) {
            names = Array(names[..<stop])
        }
        // Whatever the bank's wording (`ZELLE TO`, `ZELLE PAYMENT FROM`, `ZELLE MONEY
        // RECEIVED FROM`), the core runs to `TO`/`FROM` and then up to three words of the
        // person — so each person in and each person out is a rule of their own.
        var limit = 3
        if payment {
            if let way = names.firstIndex(where: { $0 == "TO" || $0 == "FROM" }) {
                limit = min(names.count, way + 1 + 3)
            } else {
                limit = 5
            }
        }
        let picked = Array(names.prefix(limit))
        guard let first = picked.first,
              let lo = tokens.firstIndex(where: { !$0.noise && $0.word == first }) else {
            return collapse(fold(raw))
        }
        var span: [String] = []
        var left = picked.count
        for t in tokens[lo...] where left > 0 {
            // A store or terminal number (three digits or more) ends the name; a short one
            // (`PIER 6`) is part of it.
            if t.noise, t.word.count >= 3, t.word.contains(where: \.isNumber) { break }
            span.append(t.word)
            if !t.noise { left -= 1 }
        }
        while span.count > 1, let last = span.last, isNoise(last) { span.removeLast() }
        return span.joined(separator: " ")
    }

    /// The name the drawer offers first: the core in title case ("MR KALE" → "Mr Kale"),
    /// small joining words lower-cased after the first.
    public static func suggestedName(_ raw: String, amount: Decimal? = nil) -> String {
        core(raw, amount: amount).split(separator: " ").enumerated().map { i, word in
            let w = String(word)
            if i > 0, smallWords.contains(w) { return w.lowercased() }
            return w.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: "-")
        }.joined(separator: " ")
    }

    /// The words a rule compares: upper-cased, accents folded, apostrophes closed up
    /// (`FERRANTE'S` = `FERRANTES`), every other mark a word break — so `MR. KALE` and
    /// `SQ *MR KALE` both hold the words `MR KALE`. `stripped` drops the bank and
    /// processor prefixes first, for starts-with and exact.
    static func tokens(_ text: String) -> (all: [String], stripped: [String]) {
        let folded = fold(text)
        return (words(folded), words(stripPrefixes(folded)))
    }

    // MARK: - Pieces

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ s: String) -> [String] {
        s.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^A-Z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Debit-card wrappers the bank puts in front, then the card processor's tag. Applied
    /// until nothing changes — Bank of America writes `CHECKCARD 1103 SQ *MR KALE`.
    private static let prefixes = [
        #"^PURCHASE AUTHORIZED ON \d{1,2}/\d{1,2}\s+"#,
        #"^RECURRING PAYMENT AUTHORIZED ON \d{1,2}/\d{1,2}\s+"#,
        #"^CHECKCARD \d{4}\s+"#,
        #"^DEBIT CARD PURCHASE\s+"#,
        #"^POS (DEBIT|PURCHASE)\s+"#,
        #"^POS\s+"#,
        #"^(SQ|TST|PP|PY|PAYPAL|SPO|SP|DD)\s*\*\s*"#,
        #"^(SQ|TST|SP)\s+"#,
    ]

    private static func stripPrefixes(_ s: String) -> String {
        var text = s
        var changed = true
        while changed {
            changed = false
            for p in prefixes {
                let next = text.replacingOccurrences(of: p, with: "", options: .regularExpression)
                if next != text, !next.isEmpty { text = next; changed = true }
            }
        }
        return text
    }

    /// Store and terminal numbers, zips, dates, card digits (any digit, bar an ordinal
    /// like `5TH`), masks, and the bank's own filler.
    private static func isNoise(_ word: String) -> Bool {
        if noiseWords.contains(word) { return true }
        if word.count >= 3, word.allSatisfy({ $0 == "X" }) { return true }
        guard word.contains(where: \.isNumber) else { return false }
        return word.range(of: #"^\d+(ST|ND|RD|TH)$"#, options: .regularExpression) == nil
    }

    private static let noiseWords: Set<String> = ["POS", "PPD", "ID", "WEB", "ACH", "INC", "LLC", "CORP", "PYMT"]

    /// Lines from apps that move money between people — where the same words go both ways.
    static func isPaymentApp(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        return ["ZELLE", "VENMO", "PAYPAL", "CASHAPP"].contains(first) || words.starts(with: ["CASH", "APP"])
    }

    /// Where a payment line's person ends and the bank's bookkeeping begins.
    private static let paymentStops: Set<String> = ["ON", "REF", "CONF", "CONFIRMATION", "MEMO", "TRANS", "TXN"]

    /// The person on a payment app's line, whatever the bank's wording: `JANE ROE` from
    /// `Zelle payment to Jane Roe 1234`, `ZELLE FROM ROE JANE ON 10/02 REF # PP0X`,
    /// `Zelle money received from Jane Roe`, `Zelle Transfer Conf# 9xk2; Smith, Ann`. The
    /// app's and the bank's own words, numbers and confirmation codes are passed over; the
    /// person is the first run of what's left — up to three words, side by side as the bank
    /// wrote them, so a rule on them matches every line with that person. Nil when no person
    /// is named (`VENMO PAYMENT 1029384`).
    static func paymentPerson(_ raw: String, outgoing: Bool? = nil) -> String? {
        // Quoted text is the bank's own label for an account (`"Checking"`), never a person.
        let unquoted = raw.replacingOccurrences(of: #""[^"]*"|“[^”]*”"#, with: " ", options: .regularExpression)
        var words = tokens(unquoted).all
        // Both parties named: keep the other one's side — after TO for money out, after FROM
        // (up to TO) for money in. The account holder's own name is on every line, so
        // matching it would catch them all.
        if let from = words.firstIndex(of: "FROM"), let to = words.lastIndex(of: "TO"), from < to, let outgoing {
            words = outgoing ? Array(words[(to + 1)...]) : Array(words[(from + 1)..<to])
        }
        var runs: [[String]] = [], run: [String] = []
        var skipNext = false
        for w in words {
            if skipNext { skipNext = false; if !run.isEmpty { runs.append(run); run = [] }; continue }
            if paymentCodes.contains(w) { skipNext = true }
            if paymentWords.contains(w) || paymentCodes.contains(w) || w.contains(where: \.isNumber) {
                if !run.isEmpty { runs.append(run); run = [] }
                continue
            }
            run.append(w)
        }
        if !run.isEmpty { runs.append(run) }
        guard let pick = runs.first(where: { $0.count >= 2 }) ?? runs.first else { return nil }
        return pick.prefix(3).joined(separator: " ")
    }

    /// The app's and the bank's words on a payment line — never part of a person's name.
    private static let paymentWords: Set<String> = [
        "ZELLE", "VENMO", "PAYPAL", "CASHAPP", "CASH", "APP", "PAYMENT", "PAYMENTS", "PMT", "PYMT", "TO", "FROM",
        "SENT", "RECEIVED", "RECEIVE", "SEND", "MONEY", "TRANSFER", "TRANSFERRED", "XFER", "INST", "INSTANT",
        "ON", "FOR", "P2P", "WEB", "DEBIT", "CREDIT", "ONLINE", "MOBILE", "BANKING", "QUICKPAY", "WITH", "REQUEST",
        "CASHOUT", "INC", "LLC", "VIA", "CHASE", "BOA", "BANK", "OF", "AMERICA", "WELLS", "FARGO", "CITI", "PNC", "MEMO",
    ]
    /// Words a confirmation code follows — the code is passed over with them.
    private static let paymentCodes: Set<String> = ["CONF", "CONFIRMATION", "REF", "ID", "TXN", "TRANS", "TRN"]

    /// The account a transfer names, as its bank words and number: `ALLY BANK SAVINGS 4567`
    /// from `Requested transfer to JDOE77 (Ally Bank Savings ...4567)`, `SAV 4471` from
    /// `ONLINE TRANSFER TO SAV 4471`. The number is the first one after `TO`/`FROM` that is
    /// all digits (masked `XXXX` in front allowed); the words are up to three right before
    /// it, side by side as the bank wrote them, so a rule on them matches that account's
    /// lines and no other's. Nil when the line names no account number.
    static func transferAccount(_ raw: String) -> String? {
        let w = tokens(raw).all
        guard let t = w.firstIndex(where: { ["TRANSFER", "TRANSFERRED", "XFER"].contains($0) }),
              let way = w[t...].firstIndex(where: { $0 == "TO" || $0 == "FROM" }),
              let n = w[(way + 1)...].firstIndex(where: {
                  $0.range(of: #"^X*\d{3,6}$"#, options: .regularExpression) != nil
              })
        else { return nil }
        var start = n
        while start > way + 1, n - start < 3, !w[start - 1].contains(where: \.isNumber) { start -= 1 }
        return w[start...n].joined(separator: " ")
    }

    /// Whether this bank text is a payment app's — money between people, in or out.
    /// The app may lead the line or close it (`Online Transfer to Sam Lee via Zelle`).
    public static func isPayment(_ raw: String) -> Bool {
        let w = tokens(raw).all
        return w.contains { ["ZELLE", "VENMO", "PAYPAL", "CASHAPP"].contains($0) }
            || zip(w, w.dropFirst()).contains { $0 == "CASH" && $1 == "APP" }
    }

    /// Cut at the first place name after the first word ("… BROOKLYN NY"), then drop a
    /// trailing state code.
    private static func cutAtPlace(_ words: [String]) -> [String] {
        var out: [String] = []
        for (i, w) in words.enumerated() {
            let newYork = w == "NEW" && i + 1 < words.count && words[i + 1] == "YORK"
            if i > 0, places.contains(w) || newYork { break }
            out.append(w)
        }
        while out.count > 1, let last = out.last, states.contains(last) { out.removeLast() }
        return out
    }

    private static let places: Set<String> = [
        "NY", "NYC", "BROOKLYN", "BKLYN", "BKLN", "QUEENS", "BRONX", "MANHATTAN", "ASTORIA",
        "LIC", "JERSEY", "HOBOKEN",
    ]

    /// Two-letter US state codes, less the ones that are also everyday words in a name
    /// (CO, IN, ME, OR, OK, HI, DE, AL, LA, MA, PA).
    private static let states: Set<String> = [
        "AK", "AZ", "AR", "CA", "CT", "DC", "FL", "GA", "IA", "IL", "KS", "KY", "MD", "MI",
        "MN", "MO", "MS", "MT", "NC", "ND", "NE", "NH", "NJ", "NM", "NV", "NY", "RI", "SC",
        "SD", "TN", "TX", "UT", "VA", "VT", "WA", "WI", "WV", "WY",
    ]

    private static let smallWords: Set<String> = ["AND", "OF", "ON", "THE", "TO", "AT", "FOR", "IN", "A", "&"]
}

/// One rule in `merchants.json`, born in the edit drawer's "All like this". Matches the
/// bank's `rawDescription` only, case-blind and word-aware. Any field left nil falls
/// through to the next rule that has one, then the bank's defaults.
public struct MerchantRule: Codable, Hashable, Identifiable, Sendable {
    public enum Match: String, Codable, Hashable, Sendable, CaseIterable {
        /// The pattern's words appear together, as whole words (`MR KALE` ≠ `MR KALEIDOSCOPE`).
        case contains
        /// The text begins with the pattern's words — after the bank's and the card
        /// processor's prefixes, or before them.
        case startsWith
        /// The whole cleaned text is the pattern.
        case exact
    }

    /// Which way the money goes, for words that go both ways (`ZELLE PAYMENT …` in and
    /// out). Nil: either way — every rule made before there was a direction.
    public enum Direction: String, Codable, Hashable, Sendable {
        case moneyIn, moneyOut
        public init(_ amount: Decimal) { self = amount < 0 ? .moneyOut : .moneyIn }
    }

    public var id: String
    public var match: Match
    /// As typed or offered — matched in its cleaned form.
    public var pattern: String
    public var name: String?
    public var categoryId: String?
    public var kind: TransactionKind?
    /// Lines unticked in the drawer: like this, but not this merchant.
    public var excludedTransactionIds: Set<String>
    public var direction: Direction?
    /// Whole seconds, so the file round-trips exactly.
    public var createdAt: Date

    public init(id: String = UUID().uuidString, match: Match, pattern: String, name: String? = nil,
                categoryId: String? = nil, kind: TransactionKind? = nil,
                excludedTransactionIds: Set<String> = [], createdAt: Date = Date(), direction: Direction? = nil) {
        self.id = id; self.match = match; self.pattern = pattern; self.name = name
        self.direction = direction
        self.categoryId = categoryId; self.kind = kind
        self.excludedTransactionIds = excludedTransactionIds
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    /// The pattern's words — two rules with the same `match` and these are the same rule.
    public var words: [String] { MerchantCore.tokens(pattern).all }

    /// Whether a line's money goes this rule's way (always, for a rule with no direction).
    public func allows(_ amount: Decimal) -> Bool { direction.map { Direction(amount) == $0 } ?? true }

    public func matches(_ rawDescription: String) -> Bool {
        matches(MerchantCore.tokens(rawDescription))
    }

    func matches(_ text: (all: [String], stripped: [String])) -> Bool { matches(text, words: words) }

    /// With the pattern's words already worked out — the store's hot loop.
    func matches(_ text: (all: [String], stripped: [String]), words p: [String]) -> Bool {
        guard !p.isEmpty else { return false }
        switch match {
        case .exact: return text.stripped == p || text.all == p
        case .startsWith: return text.stripped.starts(with: p) || text.all.starts(with: p)
        case .contains:
            guard text.all.count >= p.count else { return false }
            return (0...(text.all.count - p.count)).contains { text.all[$0..<($0 + p.count)].elementsEqual(p) }
        }
    }

    /// Exact beats starts-with beats contains; then the longer pattern; then the newer
    /// rule (a later place in the list breaks a same-second tie).
    public static func ordered(_ rules: [MerchantRule]) -> [MerchantRule] {
        func rank(_ m: Match) -> Int { m == .exact ? 0 : m == .startsWith ? 1 : 2 }
        return rules.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x.match) != rank(y.match) { return rank(x.match) < rank(y.match) }
            let (lx, ly) = (x.words.joined(separator: " ").count, y.words.joined(separator: " ").count)
            if lx != ly { return lx > ly }
            if x.createdAt != y.createdAt { return x.createdAt > y.createdAt }
            return a.offset > b.offset
        }.map(\.element)
    }
}

/// Rules shipped in code. They rank below every rule Helios makes, never live in
/// `merchants.json`, and only ever set a category (and, for cash, a name) — kinds stay
/// the classifier's, so an ATM withdrawal is spend by its sign and an ATM deposit stays
/// income. Conservative on purpose: whole words that name what a place is.
public enum SeedRules {
    public static let all: [MerchantRule] = {
        let groups: [(String, [String])] = [
            ("home", ["RENT", "PROPERTY MGMT", "PROPERTY MANAGEMENT", "LANDLORD", "MORTGAGE"]),
            // Power, gas, water, phone and wire — the bills that come every month whatever
            // you do. Carrier and utility names are whole words, so `ATT` alone is no AT&T.
            ("util", ["POWER CO", "POWER LIGHT", "ELECTRIC", "GAS CO", "CON ED", "CONED",
                      "NATIONAL GRID", "PSEG", "WATER BOARD", "WATER DEPT", "WATER DEPARTMENT",
                      "UTILITY", "UTILITIES", "INTERNET", "WIRELESS",
                      "VERIZON", "AT&T", "T-MOBILE", "SPRINT", "SPECTRUM", "COMCAST", "XFINITY",
                      "OPTIMUM"]),
            ("cafe", ["COFFEE", "CAFE", "ESPRESSO", "GRIND", "ROASTERS"]),
            ("groc", ["MARKET", "MKT", "GROCERY", "GROCERS", "SUPERMARKET", "CO-OP"]),
            ("heal", ["PHARMACY", "DENTAL", "DENTIST", "DOCTOR", "CLINIC", "MEDICAL", "HOSPITAL"]),
            ("fit", ["GYM", "FITNESS", "YOGA", "PILATES", "CROSSFIT", "CLIMBING", "BOULDERING", "EQUINOX",
                     "PELOTON", "BARRYS", "SOULCYCLE", "ORANGETHEORY"]),
            ("edu", ["TUITION", "COURSERA", "UDEMY", "SKILLSHARE", "MASTERCLASS", "UNIVERSITY", "COLLEGE",
                     "SCHOOL", "ACADEMY", "BURSAR"]),
            ("pet", ["PETCO", "PETSMART", "CHEWY", "VET", "VETERINARY", "ANIMAL HOSPITAL", "PET SUPPLIES"]),
            ("wear", ["UNIQLO", "ZARA", "H&M", "NIKE", "ADIDAS", "OLD NAVY", "J CREW", "LULULEMON", "EVERLANE",
                      "APPAREL", "CLOTHING", "SHOES"]),
            ("house", ["IKEA", "HOME DEPOT", "LOWES", "LOWE'S", "WAYFAIR", "HOMEGOODS", "BED BATH",
                       "CONTAINER STORE", "CRATE & BARREL", "CRATE AND BARREL", "WEST ELM", "POTTERY BARN",
                       "ACE HARDWARE", "HARDWARE", "FURNITURE"]),
            ("ins", ["INSURANCE", "GEICO", "STATE FARM", "PROGRESSIVE INS", "ALLSTATE", "LEMONADE INS",
                     "LIBERTY MUTUAL"]),
            ("debt", ["STUDENT LOAN", "LOAN PAYMENT", "LOAN PMT", "AUTO LOAN", "NAVIENT", "NELNET",
                      "SALLIE MAE", "MOHELA", "AIDVANTAGE"]),
            ("fee", ["OVERDRAFT", "INTEREST CHARGE", "FINANCE CHARGE", "LATE FEE", "ANNUAL FEE",
                     "SERVICE CHARGE", "SERVICE FEE", "MONTHLY FEE", "FOREIGN TRANSACTION FEE", "ATM FEE"]),
            ("trip", ["AIRLINE", "AIRLINES", "AIRWAYS", "AIR LINES", "HOTEL", "HOTELS", "MOTEL",
                      "HOSTEL", "RESORT", "AIRBNB"]),
            ("care", ["SALON", "BARBER", "BARBERSHOP", "SPA", "NAILS"]),
            ("gift", ["FLORIST", "FLOWERS", "DONATION", "DONATE", "CHARITY"]),
            ("subs", ["SUBSCRIPTION"]),
            ("tax", ["IRS", "US TREASURY", "TREAS TAX", "TAX PYMT", "TAX PAYMENT", "ESTIMATED TAX",
                     "DEPT OF REVENUE", "DEPARTMENT OF REVENUE", "DEPT OF TAXATION", "FRANCHISE TAX",
                     "TAX BOARD", "STATE TAX"]),
        ]
        let rules = groups.flatMap { category, patterns in
            patterns.map { MerchantRule(id: "seed-\($0.lowercased())", match: .contains, pattern: $0,
                                        categoryId: category, createdAt: Date(timeIntervalSince1970: 0)) }
        }
        // Cash out of a machine. Starts-with `ATM` outranks every contains seed, so the
        // street in `ATM WITHDRAWAL 123 MARKET ST` doesn't make it groceries.
        let cash: [(MerchantRule.Match, String)] = [
            (.startsWith, "ATM"), (.contains, "ATM WITHDRAWAL"), (.contains, "CASH WITHDRAWAL"),
        ]
        let cashRules = cash.map { match, pattern in
            MerchantRule(id: "seed-\(pattern.lowercased())", match: match, pattern: pattern, name: "ATM",
                         categoryId: "cash", createdAt: Date(timeIntervalSince1970: 0))
        }
        return MerchantRule.ordered(rules + cashRules)
    }()

    /// Words that make a spend line a question rather than an answer: money that may be
    /// moving between people or your own accounts. A line holding one, that no rule of
    /// Helios's has answered, lands in To review uncategorised.
    public static let reviewWords: [MerchantRule] = ["ZELLE", "VENMO", "CASH APP", "TRANSFER", "XFER"]
        .map { MerchantRule(id: "review-\($0.lowercased())", match: .contains, pattern: $0,
                            createdAt: Date(timeIntervalSince1970: 0)) }
}
