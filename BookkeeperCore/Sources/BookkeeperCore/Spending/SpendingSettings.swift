import Foundation

/// Which ground the Spending screens wear. `system` follows macOS: XMRange light by
/// day, XMRange dark by night. `black` is Bookkeeper's own pure black.
public enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case system, light, dark, black
}

/// `spending/settings.json` — preferences of the 2.0 screens. Lives beside the ledger,
/// never in `wallets.txt` or any other v1 file. Unknown keys or values (a later version
/// wrote them) fall back to the defaults instead of failing the read.
public struct SpendingSettings: Codable, Hashable, Sendable {
    public var theme: ThemeChoice
    public var textSize: TextSize

    public init(theme: ThemeChoice = .system, textSize: TextSize = .standard) {
        self.theme = theme; self.textSize = textSize
    }

    private enum CodingKeys: String, CodingKey { case theme, textSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .theme)
        theme = raw.flatMap(ThemeChoice.init(rawValue:)) ?? .system
        let size = try c.decodeIfPresent(String.self, forKey: .textSize)
        textSize = size.flatMap(TextSize.init(rawValue:)) ?? .standard
    }
}

/// How big the whole app's type is drawn. `standard` already sits a little above the
/// sizes the screens were laid out at — they read small.
public enum TextSize: String, Codable, CaseIterable, Sendable {
    case small, standard, large, larger

    public var scale: Double {
        switch self {
        case .small: return 1.0
        case .standard: return 1.08
        case .large: return 1.18
        case .larger: return 1.3
        }
    }
}
