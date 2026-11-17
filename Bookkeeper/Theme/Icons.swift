import AppKit

/// Asset-catalog helpers. Token and network icons are NOT here: every one comes from
/// `IconCache` (`<data>/icons/`, keyed by coin id), the single source of icons — the
/// bundled token logos it once fell back to were a second source, and two ETH drawings
/// side by side was the result.
enum Icons {
    /// True only if the named asset actually loads (guards Image("") blanks).
    static func exists(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return NSImage(named: name) != nil
    }
}
