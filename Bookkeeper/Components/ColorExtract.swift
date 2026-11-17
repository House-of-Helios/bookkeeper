import AppKit
import SwiftUI

/// Pulls a token's "brand" color out of its logo so the dashboard can colour-code
/// each row, donut slice, and glyph to match the icon. Picks the hue most of the
/// logo's strong pixels share, ignoring the transparent background. A logo that's essentially black on transparency maps to
/// white — otherwise its slice would vanish on the dark canvas.
enum ColorExtract {

    struct RGB { let r, g, b: Double }

    /// Cached so each icon is decoded once.
    static func dominant(of image: NSImage) -> Color? {
        guard let rgb = dominantRGB(of: image) else { return nil }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    static func dominantRGB(of image: NSImage) -> RGB? {
        // Drawn into an sRGB bitmap and read as bytes. Going through
        // `tiffRepresentation` + `colorAt` tagged the pixels Generic RGB, and converting
        // that "back" to sRGB shifted every colour — Bitcoin's #F7931A came out mustard.
        let side = 48
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { ctx.interpolationQuality = .medium
                           ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
                           return ctx.data }()
        else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // The logo's dominant colour: the hue most of its strong pixels share, averaged
        // within that hue. A single "most vibrant" pixel picked out highlights and edges.
        var buckets: [Int: (n: Double, r: Double, g: Double, b: Double)] = [:]
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, n = 0.0
        for i in 0..<(side * side) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a >= 0.5 else { continue }
            // Un-premultiply.
            let r = Double(px[i * 4]) / 255 / a, g = Double(px[i * 4 + 1]) / 255 / a, b = Double(px[i * 4 + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            if mx > 0.08 && mn < 0.96 { sumR += r; sumG += g; sumB += b; n += 1 }
            guard sat > 0.3, mx > 0.25 else { continue }
            let hue = Int(Self.hue(r, g, b) * 24) % 24
            var e = buckets[hue] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[hue] = e
        }
        var r: Double, g: Double, b: Double
        if let top = buckets.max(by: { $0.value.n < $1.value.n })?.value, top.n >= 3 {
            r = top.r / top.n; g = top.g / top.n; b = top.b / top.n
        } else if n > 0 {
            r = sumR / n; g = sumG / n; b = sumB / n      // a grey logo: its average
        } else { return nil }

        // Near-black brand (e.g. a black logo) -> white, so the slice reads on dark.
        if max(r, g, b) < 0.18 { return RGB(r: 1, g: 1, b: 1) }
        return RGB(r: min(1, r), g: min(1, g), b: min(1, b))
    }

    /// The logo's main colours, most used first — up to `count` distinct hues, each the
    /// average of its pixels. What the colour drawer offers to pick from.
    static func palette(of image: NSImage, count: Int = 4) -> [RGB] {
        let side = 48
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return [] }
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // 24 hues × light/dark, so a logo in two shades of one hue offers both.
        var buckets: [Int: (n: Double, r: Double, g: Double, b: Double)] = [:]
        for i in 0..<(side * side) {
            let a = Double(px[i * 4 + 3]) / 255
            guard a >= 0.5 else { continue }
            let r = Double(px[i * 4]) / 255 / a, g = Double(px[i * 4 + 1]) / 255 / a, b = Double(px[i * 4 + 2]) / 255 / a
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            guard mx > 0.12 else { continue }
            let key = sat < 0.18 ? 100 + Int(mx * 3) : Int(hue(r, g, b) * 24) % 24 * 2 + (mx > 0.6 ? 1 : 0)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        return buckets.values.filter { $0.n >= 6 }.sorted { $0.n > $1.n }.prefix(count)
            .map { RGB(r: min(1, $0.r / $0.n), g: min(1, $0.g / $0.n), b: min(1, $0.b / $0.n)) }
    }

    /// Hue in 0..<1.
    private static func hue(_ r: Double, _ g: Double, _ b: Double) -> Double {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double
        if mx == r { h = (g - b) / d } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    /// Whether text on a fill of this color should be dark (true) or light (false).
    static func prefersDarkText(_ rgb: RGB) -> Bool {
        // Relative luminance — bright fills want dark text.
        let lum = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
        return lum > 0.6
    }
}
