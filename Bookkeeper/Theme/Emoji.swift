import SwiftUI

/// One of the bundled Fluent Emoji Flat icons (MIT; `Resources/Licenses`), or Helios's
/// own `hoh_*`. A category's `icon` string is the asset name. Vector assets, so they
/// stay crisp at any size and under `ImageRenderer`.
struct Emoji: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Image(Self.known.contains(name) ? name : "package")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// Every emoji the bundle carries — the category editor's grid draws from these.
    static let known: Set<String> = [
        "admission_tickets", "airplane", "artist_palette", "bank", "bar_chart", "briefcase", "calendar",
        "chart_increasing", "coin", "gem_stone", "globe_with_meridians", "counterclockwise_arrows_button", "crescent_moon", "dollar_banknote", "hoh_mode_dark",
        "gear", "hoh_mode_light", "hot_beverage", "house", "inbox_tray", "laptop", "leafy_green", "ledger",
        "left-right_arrow", "light_bulb", "lotion_bottle", "metro", "money_bag", "money_with_wings", "package",
        "pencil", "pill", "purse", "receipt", "repeat_button", "shopping_bags", "shuffle_tracks_button",
        "steaming_bowl", "sun", "television", "wrapped_gift",
        // Wallets' marks.
        "locked", "rocket", "crystal_ball", "seedling", "fox", "owl", "dragon", "cactus", "mushroom", "octopus", "classical_building", "couch_and_lamp", "graduation_cap", "running_shoe", "t_shirt", "shield", "credit_card", "heavy_dollar_sign", "paw_prints",
    ]
}

/// An emoji on its tinted disc, beside a title: the disc is centred on the capitals and
/// overhangs them evenly, but lays out exactly `height` tall, so the title's line keeps
/// its place.
struct CapDisc: View {
    let icon: String
    let tint: Color
    let height: CGFloat

    var body: some View {
        let d = height * 1.45
        EmojiDisc(icon: icon, tint: tint, size: d)
            .padding(.vertical, -(d - height) / 2)
    }
}

/// An emoji sized to a line's capitals: its drawing — not the padding round it in its
/// square, which differs emoji to emoji — runs exactly `height`, and its box is trimmed to
/// the drawing, so set on a baseline its foot sits on the baseline and its top meets the
/// capitals.
struct CapEmoji: View {
    let name: String
    let height: CGFloat

    var body: some View {
        let b = Self.drawn(name)
        let size = height / max(0.3, b.bottom - b.top)
        Emoji(name: name, size: size)
            .padding(.top, -b.top * size)
            .padding(.bottom, -(1 - b.bottom) * size)
    }

    /// Where an emoji's drawing starts and stops down its square (0 top, 1 bottom), found
    /// once from its pixels and kept.
    @MainActor private static var bounds: [String: (top: CGFloat, bottom: CGFloat)] = [:]

    @MainActor static func drawn(_ name: String) -> (top: CGFloat, bottom: CGFloat) {
        if let b = bounds[name] { return b }
        let w = 96
        guard let img = NSImage(named: Emoji.known.contains(name) ? name : "package"),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: w, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (0, 1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: w))
        NSGraphicsContext.restoreGraphicsState()
        var top = w, bottom = -1
        for y in 0..<w { for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            top = min(top, y); bottom = max(bottom, y)
        } }
        let b: (top: CGFloat, bottom: CGFloat) = bottom < 0 ? (0, 1) : (CGFloat(top) / CGFloat(w), CGFloat(bottom + 1) / CGFloat(w))
        bounds[name] = b
        return b
    }
}
