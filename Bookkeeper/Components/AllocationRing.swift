import SwiftUI
import BookkeeperCore

/// The portfolio ring: one continuous band, every holding a slice, each named by its own
/// logo floating just outside its arc.
///
/// No callout lines and no lettering. The lines in the reference sheet were a
/// spreadsheet's only way to label a slice; a logo sitting off the edge of its own arc
/// says the same thing without drawing four extra strokes across the chart. No gaps
/// either — the band is one whole thing being divided, and black slivers between slices
/// read as missing value rather than as separation.
struct AllocationRing: View {
    let rows: [PricedHolding]
    var diameter: CGFloat = 300
    var thickness: CGFloat = 78
    /// Logos are skipped below this share — there is no arc left to sit against, and
    /// they collide with their neighbours.
    var minLogoPercent: Double = 1.6
    var logoSize: CGFloat = 30
    /// Clear air between the outer edge of the band and the near edge of a logo. Set as
    /// a real gap rather than folded into the logo's radius: at `logoSize * 0.55` the
    /// mark's edge sat about a point off the band and read as stuck to it.
    var logoGap: CGFloat = 13
    /// Below this share the logo is drawn smaller, so a thin slice's mark is in
    /// proportion to its arc and a run of small holdings can sit side by side.
    var smallSlicePercent: Double = 4
    /// How much a hovered slice grows, outward from the band's inner edge.
    var growth: CGFloat = 14

    @State private var hovered: String?

    private struct Slice: Identifiable {
        let id: String
        let token: Token
        let start: Double        // degrees, 0 at top, clockwise
        let end: Double
        let pct: Double
        let usd: Decimal
        let color: Color
    }

    @MainActor private var slices: [Slice] {
        let valued = rows.compactMap { row -> (PricedHolding, Double)? in
            guard let v = row.usdValue, v > 0 else { return nil }
            return (row, NSDecimalNumber(decimal: v).doubleValue)
        }
        let total = valued.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        var angle = 0.0
        return valued.map { row, value in
            let sweep = value / total * 360
            let s = Slice(id: row.token.id, token: row.token,
                          start: angle, end: angle + sweep,
                          pct: value / total * 100,
                          usd: row.usdValue ?? 0,
                          color: Ledger.fill(for: row.token))
            angle += sweep
            return s
        }
    }

    @ViewBuilder private func logo(_ token: Token, size: CGFloat) -> some View {
        if let img = IconCache.shared.image(for: token) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Circle().fill(Ledger.fill(for: token))
                .frame(width: size, height: size)
                .overlay(Text(String(token.symbol.prefix(1)))
                    .font(Ledger.mono(size * 0.42))
                    .foregroundStyle(Ledger.ink(on: Ledger.fill(for: token))))
        }
    }

    /// Room for the ring plus a ring of logos around it — the band, then the gap, then a
    /// whole logo, on both sides, with the hover's outward reach allowed for.
    private var canvasSize: CGFloat { diameter + (logoGap + logoSize + growth) * 2 }

    /// Which slice the cursor is over, by angle — the band is a ring, so hit-testing it
    /// as one shape and reading the angle is simpler and steadier than hit-testing
    /// thirty overlapping arc strokes.
    private func sliceID(at p: CGPoint) -> String? {
        let c = canvasSize / 2
        let dx = p.x - c, dy = p.y - c
        let dist = sqrt(dx * dx + dy * dy)
        let r = (diameter - thickness) / 2
        // The outer bound allows for a grown slice, so moving onto the part that just
        // reached outward doesn't drop the hover and snap it back.
        guard dist >= r - thickness / 2, dist <= r + thickness / 2 + growth else { return nil }
        var deg = atan2(dy, dx) * 180 / .pi + 90     // 0 at top, clockwise
        if deg < 0 { deg += 360 }
        return slices.first { deg >= $0.start && deg < $0.end }?.id
    }

    var body: some View {
        let r = (diameter - thickness) / 2
        let logoRadius = r + thickness / 2 + logoGap + logoSize / 2
        let list = slices
        let hot = list.first { $0.id == hovered }

        ZStack {
            ForEach(list) { s in
                let isHot = s.id == hovered
                // Growing outward, not in place: the stroke is centred on its radius, so
                // widening alone would push the slice inward as much as outward and eat
                // the hole. Widening by `growth` while moving the centreline out by half
                // of it pins the inner edge and lets the slice reach out of the ring.
                let grow: CGFloat = isHot ? growth : 0
                Circle()
                    .trim(from: s.start / 360, to: s.end / 360)
                    .stroke(s.color, style: StrokeStyle(lineWidth: thickness + grow, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .frame(width: (r + grow / 2) * 2, height: (r + grow / 2) * 2)
                    .animation(.easeOut(duration: 0.13), value: hovered)
            }
            ForEach(list) { s in
                if s.pct >= minLogoPercent {
                    let mid = ((s.start + s.end) / 2 - 90) * .pi / 180
                    let isHot = s.id == hovered
                    // A thin slice gets a smaller mark; the hovered one rides out with
                    // its slice rather than staying behind on the old edge.
                    let size = s.pct < smallSlicePercent ? logoSize * 0.9 : logoSize
                    let radius = logoRadius + (isHot ? growth : 0)
                    logo(s.token, size: size)
                        .offset(x: cos(mid) * radius, y: sin(mid) * radius)
                        .animation(.easeOut(duration: 0.13), value: hovered)
                }
            }

            // What the hovered slice is, read in the hole rather than as a tooltip that
            // covers the chart you're pointing at.
            if let hot {
                VStack(spacing: 3) {
                    Text(hot.token.symbol).font(Ledger.mono(15)).foregroundStyle(Palette.ink)
                    Text(String(format: "%.1f%%", hot.pct))
                        .font(Ledger.mono(20)).foregroundStyle(hot.color)
                    Text("$" + Ledger.value(hot.usd))
                        .font(Ledger.mono(11)).foregroundStyle(Palette.ink.opacity(0.65))
                }
            }

            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hovered = sliceID(at: p)
                    case .ended:         hovered = nil
                    }
                }
        }
        .frame(width: canvasSize, height: canvasSize)
    }
}

/// A breakdown ring — by chain, by type, by wallet. Same idea as the allocation ring,
/// but its slices are categories rather than tokens, so each is named by its own word
/// floating beside its arc instead of by a logo.
///
/// No callout lines here either. They were only ever the spreadsheet's way of reaching a
/// label; a word sitting against its slice, in the slice's colour, does the same job.
struct BreakdownRing: View {
    /// How a slice names itself. A mark that is already recognisable — ETH, USDC, the
    /// Monero ring — says what the slice is faster than its word does, and takes less
    /// room beside a small ring.
    enum Mark {
        case text
        case token(Token)        // whatever logo that token already has
        case asset(String)       // a bundled image
        case system(String)      // an SF Symbol, for a category with no coin of its own
        case network(Network)    // the network's OWN logo — not a token that happens to live on it
    }

    struct Slice: Identifiable {
        let id: String
        let label: String
        let value: Double
        let color: Color
        var mark: Mark = .text
    }

    let slices: [Slice]
    var diameter: CGFloat = 150
    var thickness: CGFloat = 40
    /// Below this a slice has no arc to sit a word against.
    var minLabelPercent: Double = 5

    @State private var hovered: String?

    private struct Placed: Identifiable {
        let id: String
        let label: String
        let color: Color
        let mark: Mark
        let start: Double
        let end: Double
        let pct: Double
        let value: Double
    }

    private var placed: [Placed] {
        let total = slices.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        var angle = 0.0
        return slices.map { s in
            let sweep = s.value / total * 360
            let p = Placed(id: s.id, label: s.label, color: s.color, mark: s.mark,
                           start: angle, end: angle + sweep,
                           pct: s.value / total * 100, value: s.value)
            angle += sweep
            return p
        }
    }

    /// Room for a label either side. Kept tight: at +150 each, three of these together
    /// were wider than the table beside them and forced the whole column below it.
    private var canvasWidth: CGFloat { diameter + 56 }

    /// A label, already placed and separated from its neighbours.
    private struct Label: Identifiable {
        let id: String
        let label: String
        let color: Color
        let mark: Mark
        let x: CGFloat
        var y: CGFloat
        let right: Bool
    }

    /// Labels at their slice's angle, then pushed apart down each side.
    ///
    /// At the angle alone, two slices meeting near the horizontal put their words on top
    /// of each other, and a word from a narrow slice lands against the ring instead of
    /// clear of it. Fixing the x to one of two columns and separating the y is what keeps
    /// each word beside its own slice and legible.
    private func labelled(_ list: [Placed], labelRadius: CGFloat) -> [Label] {
        var out: [Label] = []
        for s in list where s.pct >= minLabelPercent {
            let mid = ((s.start + s.end) / 2 - 90) * .pi / 180
            let right = cos(mid) >= 0
            // Every slice is marked at its own angle, just off its arc. Words were
            // tried here and don't fit: three rings side by side leave about 240pt
            // each, and "Cold Vault" beside a ring needs more than that on its own,
            // which is what pushed the whole column below the table.
            //
            // A slice centred near the bottom would put its mark under the ring, in the
            // gap before the sheet. Rather than let it sit there, the mark is held above
            // that line and slid around the circle to the nearest point that clears it —
            // so it stays against its own arc instead of floating out of the figure.
            let floorY = labelRadius * 0.55
            var x = cos(mid) * labelRadius
            var y = sin(mid) * labelRadius
            if y > floorY {
                y = floorY
                let run = sqrt(max(labelRadius * labelRadius - y * y, 0))
                x = (x >= 0 ? run : -run)
            }
            out.append(Label(id: s.id, label: s.label, color: s.color, mark: s.mark,
                             x: x, y: y, right: right))
        }
        return out
    }

    private func isIcon(_ m: Mark) -> Bool {
        if case .text = m { return false }
        return true
    }

    @ViewBuilder private func mark(_ l: Label) -> some View {
        switch l.mark {
        case .text:
            // A wallet has no logo, so its colour is its mark — and the sheet directly
            // beneath the ring already names every slice in that same colour.
            Circle().fill(l.color).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1))
        case .token(let t):
            markImage(IconCache.shared.image(for: t), fallbackAsset: nil, color: l.color, letter: String(t.symbol.prefix(1)))
        case .asset(let name):
            markImage(nil, fallbackAsset: name, color: l.color, letter: String(l.label.prefix(1)))
        case .network(let n):
            // A network wears its token's icon — the same one, from the same store, as everywhere.
            let coin = NetworkTint.coin(for: n)
            markImage(coin.map { IconCache.shared.image(for: $0) } ?? IconCache.shared.image(forNetwork: n),
                      fallbackAsset: nil, color: l.color, letter: n.badge)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(l.color)
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder private func markImage(_ image: NSImage?, fallbackAsset: String?,
                                        color: Color, letter: String) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: 24, height: 24).clipShape(Circle())
        } else if Icons.exists(fallbackAsset), let name = fallbackAsset {
            Image(name).resizable().interpolation(.high).scaledToFit()
                .frame(width: 24, height: 24).clipShape(Circle())
        } else {
            Circle().fill(color).frame(width: 24, height: 24)
                .overlay(Text(letter).font(Ledger.mono(11))
                    .foregroundStyle(Ledger.ink(on: color)))
        }
    }

    private func sliceID(at p: CGPoint) -> String? {
        let cx = canvasWidth / 2, cy = (diameter + 28) / 2
        let dx = p.x - cx, dy = p.y - cy
        let dist = sqrt(dx * dx + dy * dy)
        let r = (diameter - thickness) / 2
        guard dist >= r - thickness / 2, dist <= r + thickness / 2 else { return nil }
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        return placed.first { deg >= $0.start && deg < $0.end }?.id
    }

    var body: some View {
        let r = (diameter - thickness) / 2
        let labelRadius = r + thickness / 2 + 15
        let list = placed
        let hot = list.first { $0.id == hovered }

        ZStack {
            ForEach(list) { s in
                // Same outward growth as the allocation ring — see there for why the
                // radius moves by half of what the width gains. Scaled to this ring's
                // own diameter: a fixed 10 was a far bigger gesture on a 142pt ring
                // than on the 330pt one, and read as the slice leaping out.
                let grow: CGFloat = s.id == hovered ? diameter * 0.042 : 0
                Circle()
                    .trim(from: s.start / 360, to: s.end / 360)
                    .stroke(s.color, style: StrokeStyle(lineWidth: thickness + grow, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .frame(width: (r + grow / 2) * 2, height: (r + grow / 2) * 2)
                    .animation(.easeOut(duration: 0.13), value: hovered)
            }
            ForEach(labelled(list, labelRadius: labelRadius)) { l in
                // The mark rides out with its slice, exactly as the logos do on the
                // allocation ring. It was staying put while the slice grew outward
                // underneath it, so the band crept over its own mark.
                let grow: CGFloat = l.id == hovered ? diameter * 0.042 : 0
                let scale = labelRadius > 0 ? (labelRadius + grow) / labelRadius : 1
                mark(l)
                    .offset(x: l.x * scale, y: l.y * scale)
                    .animation(.easeOut(duration: 0.13), value: hovered)
            }

            if let hot {
                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", hot.pct))
                        .font(Ledger.mono(16)).foregroundStyle(hot.color)
                    Text("$" + Ledger.value(Decimal(hot.value)))
                        .font(Ledger.mono(9)).foregroundStyle(Palette.ink.opacity(0.65))
                }
            }

            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hovered = sliceID(at: p)
                    case .ended:         hovered = nil
                    }
                }
        }
        .frame(width: canvasWidth, height: diameter + 28)
    }
}
