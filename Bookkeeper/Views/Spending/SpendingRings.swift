import SwiftUI
import BookkeeperCore

/// Direction C: two rings. Categories inside, biggest first from 3 o'clock and clockwise down to the smallest; the
/// merchants that make each one up outside it, in lighter steps of the same hue. Each
/// big enough slice wears its emoji just outside the rings. Tap a slice or its emoji →
/// the ring zooms into that category: its merchants fill the ring, named on the big
/// slices. Tap the middle to come back out.
///
/// Laid out in the mockup's own units — a 680-wide square (its SVG's 640 viewBox plus
/// 20 of air each side), centre at 340 — scaled to `size`, so every radius below reads
/// straight against `renderRings()`.
struct SpendingRings: View {
    let model: SpendingScreenModel
    var size: CGFloat = 600
    let namespace: Namespace.ID
    var onDrillIn: (String) -> Void
    var onDrillOut: () -> Void
    /// A merchant slice → that merchant's drawer, as its row in the panel opens it.
    var onMerchant: (String, String) -> Void = { _, _ in }

    @Environment(\.ink) private var ink
    @State private var hovered: Int?
    @State private var hoverAt: CGPoint = .zero

    private var k: CGFloat { size / 680 }
    private let centre: CGFloat = 340

    // MARK: Geometry

    struct Seg: Identifiable {
        let id: Int
        let r0: CGFloat, r1: CGFloat, a0: Double, a1: Double
        let color: Color
        let gap: CGFloat
        let categoryId: String?
        let icon: String, name: String, value: Double, share: Double, sub: String?
        /// Wide enough to wear its dollars and share inside the slice.
        var labelled = false
        /// Set on a merchant slice: a tap opens its drawer instead of zooming.
        var merchant: String? = nil
    }

    struct Badge: Identifiable {
        var id: String { categoryId }
        let categoryId: String, icon: String, colorHex: String, angle: Double
    }

    private var overview: (segs: [Seg], badges: [Badge], total: Double) {
        let items = Self.descending(model.ringCategories)
        let total = items.reduce(0) { $0 + $1.total.double }
        guard total > 0 else { return ([], [], 0) }
        var segs: [Seg] = [], badges: [Badge] = []
        var a = Self.turn(items.map(\.total.double), total: total)
        for it in items {
            let c = it.category, v = it.total.double
            let da = v / total * .pi * 2
            var cat = Seg(id: segs.count, r0: 150, r1: 226, a0: a, a1: a + da, color: Color(hex: c.colorHex),
                          gap: 3, categoryId: c.id, icon: c.icon, name: c.name, value: v, share: v / total, sub: nil)
            cat.labelled = da > 0.34
            segs.append(cat)
            let ms = model.merchants(c.id)
            var b = a
            for (i, m) in ms.enumerated() {
                let dm = m.total.double / total * .pi * 2
                var part = Seg(id: segs.count, r0: 233, r1: 258, a0: b, a1: b + dm,
                               color: .shade(c.colorHex, i, ms.count), gap: 2, categoryId: c.id, icon: c.icon,
                               name: m.name, value: m.total.double, share: m.total.double / total,
                               sub: "\(c.name) · ×\(m.count)")
                part.merchant = m.name
                segs.append(part)
                b += dm
            }
            if da > 0.12 { badges.append(Badge(categoryId: c.id, icon: c.icon, colorHex: c.colorHex, angle: a + da / 2)) }
            a += da
        }
        return (segs, badges, total)
    }

    private func zoomed(_ c: SpendingCategory) -> (segs: [Seg], total: Double) {
        let ms = model.merchants(c.id)
        let total = ms.reduce(0) { $0 + $1.total.double }
        guard total > 0 else { return ([], 0) }
        var segs: [Seg] = []
        var a = Self.turn(ms.map(\.total.double), total: total)
        for (i, m) in ms.enumerated() {
            let da = m.total.double / total * .pi * 2
            var s = Seg(id: i, r0: 160, r1: 258, a0: a, a1: a + da, color: .shade(c.colorHex, i, ms.count), gap: 3,
                        categoryId: nil, icon: c.icon, name: m.name, value: m.total.double,
                        share: m.total.double / total, sub: "×\(m.count)")
            s.labelled = da > 0.3
            s.merchant = m.name
            segs.append(s)
            a += da
        }
        return (segs, total)
    }

    /// The ring's one order, on every ring: biggest first, then clockwise smaller and
    /// smaller back round to 12 o'clock. Ties by name, so a slice never jumps on redraw.
    static func descending(_ items: [CategorySpend]) -> [CategorySpend] {
        items.sorted { $0.total != $1.total ? $0.total > $1.total : $0.category.name < $1.category.name }
    }

    /// Where the ring starts so its biggest slice sits centred at 3 o'clock, its emoji
    /// pointing at the panel beside it.
    static func turn(_ values: [Double], total: Double) -> Double {
        guard total > 0, let big = values.indices.max(by: { values[$0] < values[$1] }) else { return 0 }
        let before = values[..<big].reduce(0, +) / total * .pi * 2
        return .pi / 2 - before - values[big] / total * .pi
    }

    private func point(_ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: (centre + r * CGFloat(sin(a))) * k, y: (centre - r * CGFloat(cos(a))) * k)
    }

    // MARK: Body

    var body: some View {
        let drillCat = model.drill.flatMap { model.category($0) }
        let ov = overview
        let zm = drillCat.map(zoomed)
        let segs = zm?.segs ?? ov.segs

        ZStack {
            // The rings and their centre, which swap with a swell / grow-in.
            ZStack {
                if let c = drillCat, let zm {
                    ringLayer(zm.segs)
                        .overlay { zoomCentre(c, total: zm.total) }
                        .transition(.asymmetric(
                            insertion: .modifier(active: Swing(scale: 0.45, angle: -25, opacity: 0),
                                                 identity: Swing(scale: 1, angle: 0, opacity: 1)),
                            removal: .scale(scale: 0.82).combined(with: .opacity)))
                        .id("zoom-\(c.id)")
                } else {
                    ringLayer(ov.segs)
                        .overlay { overviewCentre(total: ov.total) }
                        .transition(.asymmetric(insertion: .scale(scale: 1.15).combined(with: .opacity),
                                                removal: .scale(scale: 1.12).combined(with: .opacity)))
                }
            }

            // The emoji: badges round the overview, one big one at the zoomed centre — the
            // same view by id, so drilling in flies the badge to the middle.
            ZStack {
                if let c = drillCat {
                    EmojiDisc(c, size: 71 * k)
                        .matchedGeometryEffect(id: "emoji-\(c.id)", in: namespace)
                        .position(x: centre * k, y: (centre - 86) * k)
                        .allowsHitTesting(false)
                } else {
                    ForEach(ov.badges) { b in badge(b) }
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase {
                hoverAt = p
                hovered = hit(p, segs: segs)
            } else { hovered = nil }
        }
        .onTapGesture(coordinateSpace: .local) { p in tap(p, segs: segs, badges: drillCat == nil ? ov.badges : []) }
        .overlay(alignment: .topLeading) {
            if let h = hovered, let s = segs.first(where: { $0.id == h }) {
                tip(s)
                    .fixedSize()
                    .offset(x: hoverAt.x + 14, y: hoverAt.y + 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func ringLayer(_ segs: [Seg]) -> some View {
        let ground = ink.ground
        let hot = hovered
        return Canvas { ctx, _ in
            for s in segs {
                let path = sector(s)
                ctx.fill(path, with: .color(s.color.opacity(s.id == hot ? 0.85 : 1)))
                ctx.stroke(path, with: .color(ground), lineWidth: s.gap * k)
            }
            // Dollars over share, the way a money pie reads; the name is in the tooltip.
            for s in segs where s.labelled {
                let p = point((s.r0 + s.r1) / 2, (s.a0 + s.a1) / 2)
                // Dark on a pale slice, white on a deep one — the user picks the colours.
                let fg = Ledger.ink(on: s.color)
                let usd = ctx.resolve(Text(Fmt.usd(s.value)).font(HouseFont.jost(13 * k, 600)).foregroundStyle(fg))
                let pct = ctx.resolve(Text(Fmt.percent(s.share * 100)).font(HouseFont.jost(11 * k, 500))
                    .foregroundStyle(fg.opacity(0.85)))
                ctx.draw(usd, at: CGPoint(x: p.x, y: p.y - 7 * k), anchor: .center)
                ctx.draw(pct, at: CGPoint(x: p.x, y: p.y + 8 * k), anchor: .center)
            }
        }
        .frame(width: size, height: size)
    }

    private func sector(_ s: Seg) -> Path {
        var a1 = s.a1
        if a1 - s.a0 >= .pi * 2 - 1e-6 { a1 = s.a0 + .pi * 2 - 1e-4 }
        var p = Path()
        let c = CGPoint(x: centre * k, y: centre * k)
        // SwiftUI angles run from +x clockwise (y down); the ring's run from 12 o'clock.
        let start = Angle(radians: s.a0 - .pi / 2), end = Angle(radians: a1 - .pi / 2)
        p.addArc(center: c, radius: s.r1 * k, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: s.r0 * k, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func badge(_ b: Badge) -> some View {
        ZStack {
            Circle().fill(ink.card).frame(width: 42 * k, height: 42 * k)
            EmojiDisc(icon: b.icon, tint: EmojiDisc.tint(b.colorHex), size: 42 * k)
                .overlay(Circle().stroke(ink.rule, lineWidth: 1))
                .matchedGeometryEffect(id: "emoji-\(b.categoryId)", in: namespace)
        }
        // Placed by angle, not by point, so a badge that moves rides round the ring
        // instead of cutting across it.
        .modifier(Orbit(angle: b.angle, radius: 290, centre: centre, k: k))
        .transition(.opacity)
    }

    private func overviewCentre(total: Double) -> some View {
        ZStack {
            Text(model.income ? "TOTAL RECEIVED" : "TOTAL SPENT")
                .font(HouseFont.jost(11 * k, 500)).tracking(2).foregroundStyle(ink.faint)
                .position(x: centre * k, y: (centre - 30) * k)
            Text(Fmt.usd(total)).font(HouseFont.fraunces(40 * k)).foregroundStyle(ink.text)
                .position(x: centre * k, y: (centre + 4) * k)
            delta(model.delta()).position(x: centre * k, y: (centre + 46) * k)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func zoomCentre(_ c: SpendingCategory, total: Double) -> some View {
        ZStack {
            Text(c.name.uppercased())
                .font(HouseFont.jost(11 * k, 500)).tracking(2).foregroundStyle(ink.faint)
                .position(x: centre * k, y: (centre - 34) * k)
            Text(Fmt.usd(total)).font(HouseFont.fraunces(40 * k)).foregroundStyle(ink.text)
                .position(x: centre * k, y: centre * k)
            delta(model.delta(c.id)).position(x: centre * k, y: (centre + 40) * k)
            Text("← back")
                .font(HouseFont.jost(12.5 * k)).foregroundStyle(ink.muted)
                .position(x: centre * k, y: (centre + 78) * k)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func delta(_ d: Double?) -> some View {
        if let d {
            Text("\(d > 0 ? "▲" : "▼") \(Fmt.percent(abs(d))) vs before")
                .font(HouseFont.jost(13 * k, 500))
                .foregroundStyle(model.deltaIsGood(d) ? ink.up : ink.warm)
        }
    }

    private func tip(_ s: Seg) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                EmojiDisc(icon: s.icon, tint: s.color, size: 26)
                Text(s.name).font(HouseFont.jost(12.5, 600)).foregroundStyle(ink.text)
            }
            Text("\(Fmt.usd(s.value)) · \(Fmt.percent(s.share * 100, digits: 1))\(s.sub.map { " · " + $0 } ?? "")")
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
        }
        .frame(minWidth: 170, alignment: .leading)
        .modifier(FloatingCard())
    }

    // MARK: Hit-testing — by radius and angle, one ring at a time

    private func polar(_ p: CGPoint) -> (r: CGFloat, a: Double) {
        let dx = p.x / k - centre, dy = p.y / k - centre
        var a = atan2(Double(dx), Double(-dy))
        if a < 0 { a += .pi * 2 }
        return (sqrt(dx * dx + dy * dy), a)
    }

    private func hit(_ p: CGPoint, segs: [Seg]) -> Int? {
        let (r, a) = polar(p)
        // Slices may start below zero now the ring is turned, so compare on the circle.
        return segs.first { s in
            let d = (a - s.a0).truncatingRemainder(dividingBy: .pi * 2)
            return r >= s.r0 && r <= s.r1 && (d < 0 ? d + .pi * 2 : d) < s.a1 - s.a0
        }?.id
    }

    private func tap(_ p: CGPoint, segs: [Seg], badges: [Badge]) {
        if let d = model.drill {
            if polar(p).r < 150 { onDrillOut() }
            else if let id = hit(p, segs: segs), let m = segs.first(where: { $0.id == id })?.merchant { onMerchant(m, d) }
            return
        }
        for b in badges {
            let c = point(290, b.angle)
            if hypot(p.x - c.x, p.y - c.y) <= 22 * k { onDrillIn(b.categoryId); return }
        }
        if let id = hit(p, segs: segs), let s = segs.first(where: { $0.id == id }), let cat = s.categoryId {
            if let m = s.merchant { onMerchant(m, cat) } else { onDrillIn(cat) }
        }
    }
}

/// Scale + turn + fade, for the zoomed ring growing in.
struct Swing: ViewModifier {
    let scale: CGFloat, angle: Double, opacity: Double
    func body(content: Content) -> some View {
        content.scaleEffect(scale).rotationEffect(.degrees(angle)).opacity(opacity)
    }
}

/// A small copy of the overview ring with one slice lit — the back bar's way out.
struct MiniRing: View {
    let items: [CategorySpend]
    let lit: String
    var size: CGFloat = 54
    @Environment(\.ink) private var ink

    var body: some View {
        let items = SpendingRings.descending(items)
        let total = items.reduce(0) { $0 + $1.total.double }
        Canvas { ctx, sz in
            guard total > 0 else { return }
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            var a = SpendingRings.turn(items.map(\.total.double), total: total)
            for it in items {
                let da = it.total.double / total * .pi * 2
                var p = Path()
                let s = Angle(radians: a - .pi / 2), e = Angle(radians: a + da - .pi / 2)
                p.addArc(center: c, radius: size * 0.48, startAngle: s, endAngle: e, clockwise: false)
                p.addArc(center: c, radius: size * 0.26, startAngle: e, endAngle: s, clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(hex: it.category.colorHex).opacity(it.category.id == lit ? 1 : 0.35)))
                ctx.stroke(p, with: .color(ink.ground), lineWidth: 1)
                a += da
            }
        }
        .frame(width: size, height: size)
    }
}

/// Places a view on a circle by its angle (radians clockwise from 12 o'clock). Animating
/// the angle swings it round the ring.
private struct Orbit: ViewModifier, Animatable {
    var angle: Double
    let radius: CGFloat, centre: CGFloat, k: CGFloat

    init(angle: Double, radius: CGFloat, centre: CGFloat, k: CGFloat) {
        // Kept in 0..<2π so two placements never sit a whole turn apart.
        let turn = Double.pi * 2
        self.angle = (angle.truncatingRemainder(dividingBy: turn) + turn).truncatingRemainder(dividingBy: turn)
        self.radius = radius; self.centre = centre; self.k = k
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content.position(x: (centre + radius * CGFloat(sin(angle))) * k, y: (centre - radius * CGFloat(cos(angle))) * k)
    }
}
