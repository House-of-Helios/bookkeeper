import Foundation

/// Append-only diagnostic log at `debug.log` under the data root (`DataRoot`).
/// PRIVACY: never pass a wallet address or a full request URL here — only error
/// descriptions and response BODY snippets (chain data is public, addresses are not).
public enum BookkeeperLog {
    private static let fileURL: URL = {
        let dir = DataRoot.url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    public static func note(_ message: String) {
        // Defense in depth: even if a caller passes an NSError whose URL embeds the
        // wallet address, scrub any 0x-prefixed 40-hex address before it hits disk.
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + redactAddresses(message) + "\n"
        let data = Data(line.utf8)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Replace any `0x` + 40 hex chars (an EVM address) with a redaction marker.
    static func redactAddresses(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "0x[0-9a-fA-F]{40}") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "0x…REDACTED")
    }
}
