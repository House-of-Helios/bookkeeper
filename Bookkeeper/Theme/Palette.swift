import SwiftUI

extension Color {
    /// Hex like "#RRGGBB" or "RRGGBB".
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        self.init(.sRGB,
                  red:   Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue:  Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The v1 screens' ground and text, now read from the theme the top-bar pill picks
/// (`Look.shared.ink`) instead of fixed hexes, so the crypto side follows light / dark /
/// black the way Spending does. Names kept so the 120-odd call sites stay as they were.
enum Palette {
    static var canvas: Color   { Look.shared.ink.ground }
    static var surface: Color  { Look.shared.ink.pill }
    static var ink: Color      { Look.shared.ink.text }
    static var dim: Color      { Look.shared.ink.muted }
    static var hairline: Color { Look.shared.ink.track }

    static func token(_ hex: String) -> Color { Color(hex: hex) }
}
