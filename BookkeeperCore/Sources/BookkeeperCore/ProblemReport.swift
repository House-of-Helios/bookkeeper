import Foundation

/// The text a person can choose to send when something goes wrong. Built here, on the Mac,
/// shown whole before anything happens, and editable. It never carries a wallet, an
/// amount, a merchant, a bank line, a home path, an IP address or a host name of the
/// person's own: the log lines are scrubbed, and the facts are only the ones listed here.
public enum ProblemReport {
    public struct Facts: Sendable {
        public var app = "bookkeeper"
        public var version: String
        public var macOS: String
        public var arch: String
        public var theme: String
        public var torOn: Bool
        public var wallets: Int
        public var banks: Int
        public var logLines: [String]
        public var note: String

        public init(version: String, macOS: String, arch: String, theme: String, torOn: Bool,
                    wallets: Int, banks: Int, logLines: [String], note: String) {
            self.version = version; self.macOS = macOS; self.arch = arch; self.theme = theme
            self.torOn = torOn; self.wallets = wallets; self.banks = banks
            self.logLines = logLines; self.note = note
        }
    }

    /// How many of the newest log lines a report carries.
    public static let logLimit = 40

    public static func build(_ f: Facts, home: String = NSHomeDirectory()) -> String {
        let note = scrub(f.note.trimmingCharacters(in: .whitespacesAndNewlines), home: home)
        let lines = f.logLines.suffix(logLimit).map { scrub($0, home: home) }
        var out = """
        # \(f.app) \(f.version) — problem report

        ## What happened
        \(note.isEmpty ? "(nothing written)" : note)

        ## This Mac
        - macOS \(f.macOS), \(f.arch)
        - Look: \(f.theme) · Tor: \(f.torOn ? "on" : "off")
        - Wallets: \(f.wallets) · Banks: \(f.banks)

        ## Last \(lines.count) log lines
        """
        out += "\n```\n" + (lines.isEmpty ? "(none)" : lines.joined(separator: "\n")) + "\n```\n"
        return out
    }

    /// The hosts the app itself talks to; any other host name is the person's own and goes.
    static let knownHosts: Set<String> = [
        "coins.llama.fi", "icons.llamao.fi", "token-icons.llamao.fi", "api.coingecko.com",
        "github.com", "api.github.com", "objects.githubusercontent.com",
    ]

    /// Take out everything that could say who or where someone is, or what they hold.
    public static func scrub(_ s: String, home: String = NSHomeDirectory()) -> String {
        var t = s
        if !home.isEmpty, home != "/" { t = t.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            (#"/(Users|Volumes|home)/[^/\s"']+"#, "/$1/…"),                       // someone else's path
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),        // e-mail
            (#"0x[0-9a-fA-F]{40,64}"#, "[address]"),                               // EVM address / hash
            (#"\bbc1[02-9ac-hj-np-z]{11,71}\b"#, "[address]"),                      // bitcoin bech32
            (#"\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b"#, "[address]"),                 // bitcoin legacy
            (#"\b[1-9A-HJ-NP-Za-km-z]{32,95}\b"#, "[address]"),                    // base58 (solana, monero…)
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[ip]"),                             // IPv4
            (#"\b(?:[0-9a-fA-F]{0,4}:){3,7}[0-9a-fA-F]{0,4}\b"#, "[ip]"),           // IPv6, 4+ groups (a clock has 3 at most)
            (#"\b(?=[0-9a-fA-F:]*(?:[a-fA-F]|::))(?:[0-9a-fA-F]{0,4}:){1,2}[0-9a-fA-F]{0,4}\b"#, "[ip]"), // short IPv6 with a letter or ::
            (#"[-+−]?[$€£]\s?[\d,]+(?:\.\d+)?"#, "[amount]"),                      // money with a sign
            (#"\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b"#, "[amount]"),                    // 1,234.56
            (#"(?<![\d.])[-+−]?\d+\.\d{2,}(?!\d|\.\d)"#, "[amount]"),                 // 12.50, 0.8123, not 2.0.22
        ]
        for (pattern, with) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: with)
        }
        // Host names last, so the known ones survive and everything else goes.
        if let re = try? NSRegularExpression(pattern: #"\b(?:[a-zA-Z0-9-]+\.)+(?:[a-zA-Z]{2,}|local|lan|onion)\b"#) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range, in: t) else { continue }
                let host = String(t[r]).lowercased()
                if knownHosts.contains(host) || host.hasSuffix(".swift") || host.hasSuffix(".json")
                    || host.hasSuffix(".csv") || host.hasSuffix(".txt") || host.hasSuffix(".log") { continue }
                t.replaceSubrange(r, with: "[host]")
            }
        }
        return t
    }

    /// The newest lines of `debug.log`, read from its tail only so a large log costs nothing.
    public static func recentLog(limit: Int = logLimit) -> [String] {
        let url = DataRoot.url.appendingPathComponent("debug.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 64_000 ? end - 64_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        return Array(text.split(separator: "\n").map(String.init).suffix(limit))
    }
}
