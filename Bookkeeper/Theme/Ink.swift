import SwiftUI
import AppKit
import BookkeeperCore

/// A full set of ground + text tokens for one look. Spending (and Transactions next) draw
/// from these instead of `Theme` / `Palette`, which stay the v1 screens' fixed black —
/// built as a value so the whole app can switch to it later without a second type.
///
/// Hexes are the mockup's `:root` blocks (`_Plan/2026-10-20-spending-mockups.html`):
/// XMRange light + dark, and Bookkeeper's own pure black.
struct Ink: Equatable {
    var ground: Color, card: Color, pill: Color
    var text: Color, muted: Color, faint: Color
    var track: Color, rule: Color, hover: Color, active: Color
    var up: Color, warm: Color, scrim: Color
    /// The drop shadow under floating things (pill, tooltip, drawer).
    var shadow: Color
    var isDark: Bool

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    static let xmrangeLight = Ink(
        ground: Color(hex: "#faf6ee"), card: Color(hex: "#f1eee8"), pill: Color(hex: "#e9e4da"),
        text: Color(hex: "#2e363d"), muted: Color(hex: "#585d62"), faint: Color(hex: "#8a8f94"),
        track: Color(hex: "#ddd6ca"), rule: Color(hex: "#e4ddd0"), hover: Color(hex: "#f3eee4"),
        active: Color(hex: "#fffdf8"), up: Color(hex: "#3f9a4a"), warm: Color(hex: "#c2410c"),
        scrim: Color(hex: "#1b2025").opacity(0.28), shadow: Color(hex: "#2e363d").opacity(0.10),
        isDark: false)

    static let xmrangeDark = Ink(
        ground: Color(hex: "#1b2025"), card: Color(hex: "#252b31"), pill: Color(hex: "#2e353c"),
        text: Color(hex: "#eef0f1"), muted: Color(hex: "#a7afb6"), faint: Color(hex: "#7f8a94"),
        track: Color(hex: "#3a424a"), rule: Color(hex: "#2c333a"), hover: Color(hex: "#222830"),
        active: Color(hex: "#3a424a"), up: Color(hex: "#74d68a"), warm: Color(hex: "#ff8a3d"),
        scrim: .black.opacity(0.5), shadow: .black.opacity(0.35), isDark: true)

    static let bookkeeperBlack = Ink(
        ground: Color(hex: "#000000"), card: Color(hex: "#141414"), pill: Color(hex: "#1e1e1e"),
        text: Color(hex: "#ffffff"), muted: Color(hex: "#9a9a9a"), faint: Color(hex: "#5e5e5e"),
        track: Color(hex: "#2e2e2e"), rule: Color(hex: "#1c1c1c"), hover: Color(hex: "#0c0c0c"),
        active: Color(hex: "#2a2a2a"), up: Color(hex: "#7ed321"), warm: Color(hex: "#f05e1c"),
        scrim: .black.opacity(0.6), shadow: .black.opacity(0.6), isDark: true)

    /// The tokens a choice resolves to, given whether macOS is in dark mode.
    static func resolve(_ choice: ThemeChoice, systemIsDark: Bool) -> Ink {
        switch choice {
        case .system: return systemIsDark ? .xmrangeDark : .xmrangeLight
        case .light:  return .xmrangeLight
        case .dark:   return .xmrangeDark
        case .black:  return .bookkeeperBlack
        }
    }
}

/// The theme in force for the whole window. RootView writes it whenever the pill or macOS
/// flips; `Palette` and `Theme` read it, and because this is `@Observable` every v1 view
/// that touched a colour redraws with it.
@Observable
final class Look {
    static let shared = Look()
    var ink: Ink = .bookkeeperBlack
    /// The Settings text size, multiplied into every font the app asks for.
    var textScale: CGFloat = 1.08

    /// Every leaderboard bar's thickness, Banking and Crypto alike — about a capital
    /// letter's height and then some, so the colour carries the row.
    static let barHeight: CGFloat = 21
    /// A panel title's size, and its mark's height: the title's capitals (Fraunces caps
    /// stand 0.70 of the size), so a mark runs from the baseline to the top of a capital.
    static let panelTitle: CGFloat = 34
    static var panelCap: CGFloat { panelTitle * 0.70 * Look.shared.textScale }
}

private struct InkKey: EnvironmentKey { static let defaultValue = Ink.xmrangeDark }

extension EnvironmentValues {
    var ink: Ink {
        get { self[InkKey.self] }
        set { self[InkKey.self] = newValue }
    }
}

/// macOS's own light / dark setting, read directly. The window is forced dark for the v1
/// screens (`preferredColorScheme(.dark)`), so the environment's colour scheme can't
/// answer "what is the system in?" — the global default can, and a distributed
/// notification says when it flips.
@Observable
final class SystemAppearance {
    static let shared = SystemAppearance()
    private(set) var isDark: Bool = SystemAppearance.read()
    private var token: NSObjectProtocol?

    private init() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in self?.isDark = SystemAppearance.read() }
    }

    private static func read() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}

extension Color {
    /// `hex` lifted toward white by `t` (0…1) — the merchants' lighter steps of their
    /// category's hue, as the mockup's `shade()` does it.
    static func lifted(_ hex: String, _ t: Double) -> Color {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        func ch(_ v: UInt64) -> Double {
            let c = Double(v & 0xFF)
            return (c + (255 - c) * t).rounded() / 255
        }
        return Color(.sRGB, red: ch(rgb >> 16), green: ch(rgb >> 8), blue: ch(rgb), opacity: 1)
    }

    /// Step `k` of `n` lighter steps: the biggest merchant at full strength, the
    /// smallest lifted 45 % toward white.
    static func shade(_ hex: String, _ k: Int, _ n: Int) -> Color {
        lifted(hex, n <= 1 ? 0 : Double(k) / Double(n - 1) * 0.45)
    }
}

/// The rings' shared geometry, Banking and Crypto alike: drawn in a 680-unit square, centre
/// at 340. Nothing of a ring — slices, the marks floating outside them — may stand above
/// the panel title's top, so each screen lifts the square by the air above its highest
/// reach: Banking's badges (radius 290, 42 across), Crypto's marks (286, 38 across).
enum Rings {
    static let bankingAir: CGFloat = (340 - 290 - 21) / 680
    static let cryptoAir: CGFloat = (340 - 286 - 19) / 680
    /// How far the panel title's capitals start below the top of its line (Fraunces: ascent
    /// 0.978, caps 0.70) — the line nothing of a ring may rise above.
    static var capTop: CGFloat { (0.978 - 0.70) * Look.panelTitle * Look.shared.textScale }
    /// The way back out of a zoom, on the panel title's line — as tall as that line. The
    /// ring doesn't move for it: the row sits at the left, beside the ring's top.
    static var backRow: CGFloat { 1.25 * Look.panelTitle * Look.shared.textScale }

    /// The ring's size: as large as fits with its top on the title's capitals.
    static func size(width: CGFloat, room: CGFloat, under: CGFloat, air: CGFloat) -> CGFloat {
        max(260, min(width, (room - under - capTop) / (1 - air)))
    }

    /// How far the ring's square sits from the panel's top — the same zoomed or not, so a
    /// zoom grows the ring in place.
    static func top(ring: CGFloat, air: CGFloat) -> CGFloat { capTop - ring * air }
}
