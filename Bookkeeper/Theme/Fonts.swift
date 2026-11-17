import SwiftUI
import AppKit

/// Two faces, each doing the job it's actually good at.
///
/// Roboto Mono on every string made the app read as a terminal readout: monospace gives
/// each letter the same width, which is exactly right for a column of dollar figures and
/// exactly wrong for a name or a label, where it forces even spacing onto letters that
/// want to sit closer. So numbers keep the mono (and get tabular figures, so digits line
/// up as they change), and everything else moves to the system face, which is drawn for
/// reading at UI sizes.
enum AppFont {

    /// Figures: money, amounts, percentages. Tabular so a ticking value doesn't shuffle
    /// the column left and right under the eye.
    static func num(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("RobotoMono-Bold", size: size * Look.shared.textScale).weight(weight).monospacedDigit()
    }

    /// Interface text: names, labels, buttons, navigation.
    ///
    /// This is the mono face too, and deliberately so. Splitting the app between a
    /// system UI face and mono figures was a reasonable-sounding idea that made the app
    /// look worse: the mono IS the house voice here, and mixing two faces at these small
    /// sizes read as inconsistent rather than considered. The separate entry point stays
    /// because the distinction is real — it just resolves to one family.
    static func ui(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("RobotoMono-Bold", size: size * Look.shared.textScale).weight(weight)
    }

    /// Small uppercase section labels. Letter-spacing is applied at the call site with
    /// `.tracking(_:)` — the eyebrow only reads as an eyebrow when it's spaced out.
    static func eyebrow(_ size: CGFloat = 10.5) -> Font {
        .custom("RobotoMono-Bold", size: size * Look.shared.textScale)
    }

    /// Kept so existing call sites keep compiling; prefer `num` or `ui` in new code.
    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        num(size, weight: weight)
    }
}

extension View {
    /// The app's one eyebrow treatment: small, spaced, dim. Used for TOTAL, BY CHAIN, …
    func eyebrowStyle() -> some View {
        self.font(AppFont.eyebrow())
            .tracking(1.1)
            .foregroundStyle(Palette.dim)
    }
}

/// The 2.0 faces, from XMRange: Jost for words, Fraunces for the big numbers, and the
/// house Roboto Mono for raw bank text (it is what the bank wrote, so it reads as data).
/// Used by the Spending screens; the v1 screens stay on `AppFont` until Helios decides
/// app-wide.
///
/// Both are variable fonts, so weight is set on the `wght` axis directly — `.weight()`
/// on a `.custom` face picks a named instance at best, and Fraunces' optical size (`opsz`)
/// has no SwiftUI handle at all. Fraunces runs with `opsz` = point size, as a browser's
/// `font-optical-sizing: auto` does, and `WONK` off, so the numbers sit upright.
enum HouseFont {
    static func jost(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        Font(variable("Jost-Regular", size: size * Look.shared.textScale, axes: [wght: weight]))
    }

    static func fraunces(_ size: CGFloat, _ weight: CGFloat = 600) -> Font {
        let size = size * Look.shared.textScale
        return Font(variable("Fraunces-Regular", size: size,
                      axes: [wght: weight, opsz: min(144, max(9, size)), wonk: 0, soft: 0]))
    }

    /// Raw bank text.
    static func raw(_ size: CGFloat) -> Font {
        Font(variable("RobotoMono-Regular", size: size * Look.shared.textScale, axes: [wght: 400]))
    }

    static func nsJost(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        variable("Jost-Regular", size: size * Look.shared.textScale, axes: [wght: weight])
    }

    // Four-char axis tags as integers.
    private static let wght = 0x7767_6874, opsz = 0x6F70_737A, wonk = 0x574F_4E4B, soft = 0x534F_4654

    private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    private static func variable(_ name: String, size: CGFloat, axes: [Int: CGFloat]) -> NSFont {
        let key = "\(name)|\(size)|\(axes.sorted { $0.key < $1.key })"
        lock.lock(); defer { lock.unlock() }
        if let f = cache[key] { return f }
        let variation = Dictionary(uniqueKeysWithValues: axes.map { (NSNumber(value: $0.key), NSNumber(value: Double($0.value))) })
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: name,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): variation,
        ])
        let font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        cache[key] = font
        return font
    }
}
