import SwiftUI
import BookkeeperCore

/// Crypto 2 — Banking's layout given to the holdings. Top to bottom: the value strip
/// (presets + drag), the range sentence, then the two rings beside the panel. Tap a slice
/// to zoom into it; the back bar, Esc or a tap on the ring's middle comes back out.
struct CryptoTwoView: View {
    let store: PortfolioStore
    @State private var model: CryptoTwoModel
    var rendering = false
    @Environment(\.ink) private var ink

    init(store: PortfolioStore, model: CryptoTwoModel? = nil, rendering: Bool = false) {
        self.store = store
        self.rendering = rendering
        _model = State(initialValue: model ?? CryptoTwoModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.total <= 0 {
                Text("No holdings priced yet.").font(HouseFont.jost(14)).foregroundStyle(ink.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                stripHead.padding(.bottom, 4)
                if model.buckets.count >= 2 { ValueChart(model: model).zIndex(1) } else { noHistory }
                GeometryReader { g in stage(g.size) }
            }
        }
        .frame(maxWidth: 1360, maxHeight: .infinity, alignment: .top)
        // Network logos for the Networks slices and the token rows' tabs.
        .task(id: Set(model.rows.map { Network.of($0.token).name })) {
            // Each network's token, for its icon even where the token itself isn't held.
            let nets = Array(Set(model.rows.map { Network.of($0.token) }))
            await IconCache.shared.prefetch(NetworkTint.coins(for: nets))
            await IconCache.shared.prefetchNetworks(NetworkTint.tokenless(nets))
        }
        .padding(.top, 20).padding(.horizontal, 40).padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ink.ground)
        // A wallet's drawer slides in from the right, as Banking's category drawer does; a
        // click outside it closes it without saving.
        .overlay {
            if model.editingWallet != nil || model.editingColor != nil || model.addingWallet || model.pricing != nil {
                Scrim { model.editingWallet = nil; model.editingColor = nil; model.addingWallet = false; model.pricing = nil }
            }
        }
        // A token clicked in a wallet's or a network's list: its price, over the screen.
        .overlay {
            if let t = model.pricing {
                TokenPriceModal(model: model, token: t) { model.pricing = nil }
                    .id(t.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay(alignment: .trailing) {
            if let id = model.editingWallet {
                WalletEditWindow(store: store, walletId: id,
                                 emoji: model.walletEmoji(store.wallets.first { $0.id == id }?.nickname ?? id),
                                 colorHex: store.wallets.first { $0.id == id }.map(model.walletHex) ?? "#8C9196") {
                    model.editingWallet = nil
                }
                .id(id)
                .transition(.move(edge: .trailing))
            } else if let c = model.editingColor {
                ColorEditor(target: c) { model.editingColor = nil }
                    .id(c.id)
                    .transition(.move(edge: .trailing))
            } else if model.addingWallet {
                NewWalletDrawer(model: model) { model.addingWallet = false }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.editingWallet)
        .animation(.easeOut(duration: 0.22), value: model.editingColor)
        .animation(.easeOut(duration: 0.22), value: model.addingWallet)
        .animation(.easeOut(duration: 0.18), value: model.pricing?.id)
    }

    // MARK: - Strip head + range sentence

    /// The range presets on the right, and — centred over the whole width — Log portfolio,
    /// which records today's worth into the history the chart is drawn through.
    private var stripHead: some View {
        ZStack {
            logButton
            presets
        }
    }

    /// Log portfolio, and beside it the day's move — the whole portfolio's, or the zoomed
    /// slice's. Said once, here, not in every panel's header.
    private var logButton: some View {
        let d = model.change24h(model.slice(model.drill))
        // An invisible twin on the left keeps the pill itself centred.
        return HStack(spacing: 14) {
            if let d { day(d).hidden() }
            logPill
            if let d { day(d) }
        }
    }

    private func day(_ d: Double) -> some View {
        Text("\(d >= 0 ? "▲" : "▼") \(Fmt.percent(abs(d), digits: 1)) 24h")
            .font(HouseFont.jost(13, 500)).foregroundStyle(d >= 0 ? ink.up : ink.warm)
    }

    private var logPill: some View {
        Button {
            if store.archiveToday() { model.applyPreset(model.preset ?? .threeMonths) }
        } label: {
            HStack(spacing: 7) {
                Emoji(name: "calendar", size: 16)
                Text(store.archivedToday ? "Logged today" : "Log portfolio").font(HouseFont.jost(12.5, 500))
            }
            .foregroundStyle(ink.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(ink.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(store.archivedToday ? "Today is logged — press again to log today's worth again"
                                  : "Record what everything is worth today")
    }

    private var presets: some View {
        HStack(alignment: .bottom) {
            Spacer()
            HStack(spacing: 2) {
                ForEach(CryptoTwoModel.Preset.allCases) { p in
                    let on = model.preset == p
                    Button { model.applyPreset(p) } label: {
                        Text(p.rawValue).font(HouseFont.jost(12))
                            .foregroundStyle(on ? ink.text : ink.muted)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? ink.pill : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The strip with fewer than two marks: say so, and offer the History tab's button here.
    private var noHistory: some View {
        HStack(spacing: 14) {
            Text("No history yet — Log portfolio records today; Settings → History sets how often it records on its own.")
                .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
        }
        .frame(maxWidth: .infinity, minHeight: ValueChart.height, alignment: .center)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1.5))
    }

    private func walletHex(_ name: String) -> String {
        store.wallets.first { $0.nickname == name }.map(model.walletHex) ?? "#8C9196"
    }

    // MARK: - Stage

    /// The same frame as Banking: lined up on the strip's first bar, the panel from the
    /// left edge of the bar nearest 55% across (the strip's bar count changes with the
    /// archive's length, so no fixed bar), the ring centred in the room between.
    private func stage(_ size: CGSize) -> some View {
        let w = size.width
        let n = max(1, model.buckets.count)
        let slot = w / CGFloat(n)
        _ = slot
        let inset: CGFloat = 0
        // On a bar edge once the strip has bars to line up with; with too few (a new
        // archive), straight at 55% — snapping to one bar sent the panel off the right edge.
        // The chart has no bars to line up with: the panel starts at 55% across.
        let panelX = w * 0.55
        let left = panelX - inset
        let say: CGFloat = 22, under: CGFloat = 66
        // The ring's highest reach (a mark's top) level with the panel title's top, as on Banking.
        let room = size.height - say - 6
        let ring = Rings.size(width: left - 40, room: room, under: under, air: Rings.cryptoAir)

        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: say)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    CryptoRing(model: model, size: ring, onDrillIn: drillIn, onDrillOut: drillOut)
                        .padding(.top, Rings.top(ring: ring, air: Rings.cryptoAir))
                    self.under.padding(.top, 4)
                }
                // Zoomed, the way back out runs along the panel title's line, above the ring.
                .overlay(alignment: .topLeading) { backBar.frame(height: Rings.backRow) }
                .frame(width: left)
                .padding(.leading, inset)
                .zIndex(1)
                Group {
                    if rendering { panel } else { ScrollView { panel }.scrollIndicators(.never) }
                }
                .frame(width: max(320, w - panelX - inset), height: max(0, size.height - say - 6), alignment: .top)
            }
        }
    }

    private var panel: some View {
        CryptoPanel(model: model, onDrill: drillIn, onEdit: { id in
            withAnimation(.easeOut(duration: 0.18)) { model.editingWallet = id }
        }, onColor: { t in
            withAnimation(.easeOut(duration: 0.18)) { model.editingColor = t }
        }, onAddWallet: {
            withAnimation(.easeOut(duration: 0.18)) { model.addingWallet = true }
        })
    }

    @ViewBuilder private var backBar: some View {
        if let s = model.slice(model.drill) {
            HStack(spacing: 10) {
                Button(action: drillOut) { CryptoMiniRing(slices: model.slices, lit: s.id) }
                    .buttonStyle(.plain).help("Back to all \(model.lens.title.lowercased())")
                Button(action: drillOut) {
                    Text("← All \(model.lens.title.lowercased())").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(ink.pill, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(model.editingWallet == nil && model.editingColor == nil && !model.addingWallet && model.pricing == nil ? .cancelAction : nil)
                Spacer()
            }
        }
    }

    /// Under the ring: the lens pill.
    private var under: some View {
        VStack(spacing: 10) {
            Seg(options: CryptoTwoModel.Lens.allCases, selected: model.lens, help: nil) { v in
                withAnimation(.easeOut(duration: 0.3)) {
                    model.lens = v
                    model.drill = nil
                    model.showAll = false
                }
            } label: { v in
                HStack(spacing: 7) { Emoji(name: v.emoji, size: 20); Text(v.title) }
                    .font(HouseFont.jost(13))
            }
            if model.drill == nil {
                Text(model.lens == .token ? "inner: tokens · outer: wallets" : "inner: \(model.lens.title.lowercased()) · outer: tokens")
                    .font(HouseFont.jost(12)).foregroundStyle(ink.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func drillIn(_ id: String) {
        guard model.drill == nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { model.drill = id }
    }

    private func drillOut() {
        guard model.drill != nil else { return }
        withAnimation(.easeOut(duration: 0.28)) { model.drill = nil }
    }
}

/// The whole ring in small, the zoomed slice lit — the back button, as on Banking.
struct CryptoMiniRing: View {
    let slices: [CryptoTwoModel.Slice]
    let lit: String
    var size: CGFloat = 54
    @Environment(\.ink) private var ink

    var body: some View {
        let total = slices.reduce(0) { $0 + $1.value }
        Canvas { ctx, sz in
            guard total > 0 else { return }
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            var a = Double.pi / 2 - (slices.first?.value ?? 0) / total * .pi
            for s in slices {
                let da = s.value / total * .pi * 2
                var p = Path()
                let st = Angle(radians: a - .pi / 2), en = Angle(radians: a + da - .pi / 2)
                p.addArc(center: c, radius: size * 0.48, startAngle: st, endAngle: en, clockwise: false)
                p.addArc(center: c, radius: size * 0.26, startAngle: en, endAngle: st, clockwise: true)
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(hex: s.colorHex).opacity(s.id == lit ? 1 : 0.35)))
                ctx.stroke(p, with: .color(ink.ground), lineWidth: 1)
                a += da
            }
        }
        .frame(width: size, height: size)
    }
}

/// A slice's mark: a token's own logo, else a disc in its colour with its first letter.
struct SliceGlyph: View {
    let slice: CryptoTwoModel.Slice
    var size: CGFloat = 20
    var body: some View {
        if let n = slice.network {
            NetworkMark(network: n, among: slice.mark.map { [$0] } ?? [], size: size)
        } else if let t = slice.token ?? slice.mark {
            TokenGlyph(token: t, size: size)
        } else if let e = slice.emoji {
            Emoji(name: e, size: size)
        } else {
            Letter(name: slice.name, hex: slice.colorHex, size: size)
        }
    }
}

struct Letter: View {
    let name: String
    let hex: String
    var size: CGFloat
    var body: some View {
        let c = Color(hex: hex)
        Circle().fill(c).frame(width: size, height: size)
            .overlay(Text(String(name.prefix(1)).uppercased())
                .font(HouseFont.jost(size * 0.52, 600)).foregroundStyle(Ledger.ink(on: c)))
    }
}

// MARK: - Strip

/// Money in short, for a ring label: `$148k` — the exact figure is one hover away.
enum CryptoStrip {
    static func short(_ v: Double) -> String {
        v >= 1_000_000 ? String(format: "$%.2fM", v / 1_000_000)
            : v >= 10_000 ? "$\(Int((v / 1000).rounded()))k" : Fmt.usd(v)
    }
}

// MARK: - Ring

/// Banking's two rings in the same 680-unit square: slices inside, their parts outside,
/// logos just beyond. Zoomed, the parts fill the whole ring.
struct CryptoRing: View {
    let model: CryptoTwoModel
    var size: CGFloat = 600
    var onDrillIn: (String) -> Void
    var onDrillOut: () -> Void
    @Environment(\.ink) private var ink
    @State private var hovered: Int?
    @State private var hoverAt: CGPoint = .zero

    private var k: CGFloat { size / 680 }
    private let centre: CGFloat = 340

    struct Seg {
        let id: Int
        let r0: CGFloat, r1: CGFloat, a0: Double, a1: Double
        let color: Color
        let gap: CGFloat
        let sliceId: String?
        let name: String, value: Double, share: Double, sub: String?
        var labelled = false
        /// What the hover card shows beside the name: a token's logo, a wallet's emoji or
        /// a network's coin — the same mark the thing wears everywhere else.
        var token: Token? = nil
        var emoji: String? = nil
        var network: Network? = nil
        /// Drawn at half strength until hovered — the wallet band under Tokens, so the
        /// token colours lead.
        var faint = false
    }

    /// A token's mark on the outer band, at its part's middle angle.
    /// A mark floating just outside the ring: a token's logo, or a wallet's lettered disc.
    /// Tapping one on the whole ring zooms into the slice it belongs to.
    struct Mark: Identifiable {
        let id: String
        let token: Token?
        var emoji: String? = nil
        let name: String
        let hex: String
        let a: Double
        let slice: String?
        /// The arc it marks, in radians — what sizes it (`Mark.scale`).
        var span: Double = 1

        /// 4% of the ring and up wears the full mark; 2–4% a notch smaller; under 2% none —
        /// as the share is shown, rounded, so a slice the list calls 2% keeps its mark.
        static func shows(_ span: Double) -> Bool { span / (.pi * 2) >= 0.015 }
        var scale: CGFloat { span / (.pi * 2) >= 0.035 ? 1 : 0.78 }
    }

    /// Outside the ring are always the finest pieces — tokens wherever tokens are the
    /// outer ring or the zoomed ring, wallets when a token is zoomed. Under Tokens the
    /// tokens are the inner slices, so they are the marks. A wallet or network slice
    /// carries its own mark inside the slice instead.
    private var layout: (segs: [Seg], marks: [Mark], total: Double) {
        let total = model.total
        guard total > 0 else { return ([], [], 0) }
        if let s = model.slice(model.drill) {
            var segs: [Seg] = [], marks: [Mark] = []
            var a = Double.pi / 2 - (s.parts.first?.value ?? 0) / s.value * .pi
            // A token on more than one network: the wallets inside, each split by network
            // in a thin ring outside, as the whole ring splits slices into their parts.
            let split = s.parts.contains { !$0.networks.isEmpty }
            for p in s.parts {
                let da = p.value / s.value * .pi * 2
                var g = Seg(id: segs.count, r0: 160, r1: split ? 226 : 258, a0: a, a1: a + da,
                            color: Color(hex: p.colorHex), gap: 3,
                            sliceId: nil, name: p.name, value: p.value, share: p.value / s.value, sub: nil)
                g.labelled = da > 0.3
                if model.lens == .token { g.emoji = model.walletEmoji(p.name) } else { g.token = p.token }
                segs.append(g)
                var b = a
                for n in p.networks {
                    let dn = n.value / s.value * .pi * 2
                    var ns = Seg(id: segs.count, r0: 233, r1: 258, a0: b, a1: b + dn,
                                 color: Color(hex: n.colorHex), gap: 2, sliceId: nil,
                                 name: n.name, value: n.value, share: n.value / s.value, sub: p.name)
                    ns.network = Network(name: n.name)
                    segs.append(ns)
                    b += dn
                }
                if Mark.shows(da) {
                    marks.append(Mark(id: p.id, token: model.lens == .token ? nil : p.token,
                                      emoji: model.lens == .token ? model.walletEmoji(p.name) : nil, name: p.name,
                                      hex: p.colorHex, a: a + da / 2, slice: nil, span: da))
                }
                a += da
            }
            return (segs, marks, s.value)
        }
        let slices = model.slices
        var segs: [Seg] = [], marks: [Mark] = []
        var a = Double.pi / 2 - (slices.first?.value ?? 0) / total * .pi
        for s in slices {
            let da = s.value / total * .pi * 2
            var g = Seg(id: segs.count, r0: 150, r1: 226, a0: a, a1: a + da, color: Color(hex: s.colorHex), gap: 3,
                        sliceId: s.id, name: s.name, value: s.value, share: s.value / total, sub: nil)
            g.labelled = da > 0.34
            g.token = s.token; g.emoji = s.emoji; g.network = s.network
            segs.append(g)
            var b = a
            for p in s.parts {
                let dp = p.value / total * .pi * 2
                // Outer parts are the other side of the split, each in its own colour: a
                // wallet's under Tokens, a token's under Wallets and Networks — so one wallet
                // or one token reads the same all the way round.
                var part = Seg(id: segs.count, r0: 233, r1: 258, a0: b, a1: b + dp,
                               color: Color(hex: p.colorHex), gap: 2, sliceId: s.id,
                               name: p.name, value: p.value, share: p.value / total, sub: s.name)
                part.faint = model.lens == .token
                if model.lens == .token { part.emoji = model.walletEmoji(p.name) } else { part.token = p.token }
                segs.append(part)
                if model.lens != .token, let t = p.token, Mark.shows(dp) {
                    marks.append(Mark(id: "\(s.id)|\(p.id)", token: t, name: p.name, hex: p.colorHex,
                                      a: b + dp / 2, slice: s.id, span: dp))
                }
                b += dp
            }
            if model.lens == .token, Mark.shows(da) {
                marks.append(Mark(id: s.id, token: s.token, name: s.name, hex: s.colorHex, a: a + da / 2, slice: s.id, span: da))
            }
            a += da
        }
        return (segs, marks, total)
    }

    private func point(_ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: (centre + r * CGFloat(sin(a))) * k, y: (centre - r * CGFloat(cos(a))) * k)
    }

    var body: some View {
        let l = layout
        let zoomed = model.slice(model.drill)
        ZStack {
            Canvas { ctx, _ in
                for s in l.segs {
                    let path = sector(s)
                    ctx.fill(path, with: .color(s.color.opacity(s.id == hovered ? (s.faint ? 1 : 0.85) : (s.faint ? 0.5 : 1))))
                    ctx.stroke(path, with: .color(ink.ground), lineWidth: s.gap * k)
                }
                for s in l.segs where s.labelled {
                    let p = point((s.r0 + s.r1) / 2, (s.a0 + s.a1) / 2)
                    let fg = Ledger.ink(on: s.color)
                    let usd = ctx.resolve(Text(CryptoStrip.short(s.value)).font(HouseFont.jost(13 * k, 600)).foregroundStyle(fg))
                    let pct = ctx.resolve(Text(Fmt.percent(s.share * 100)).font(HouseFont.jost(11 * k, 500)).foregroundStyle(fg.opacity(0.85)))
                    let drop: CGFloat = 0
                    ctx.draw(usd, at: CGPoint(x: p.x, y: p.y + (drop - 7) * k), anchor: .center)
                    ctx.draw(pct, at: CGPoint(x: p.x, y: p.y + (drop + 8) * k), anchor: .center)
                }
            }
            .id(model.drill ?? "all-\(model.lens.rawValue)")
            .transition(.scale(scale: 0.9).combined(with: .opacity))

            ForEach(l.marks) { m in
                // A logo (or a lettered disc) is already round and filled, so it takes the
                // whole disc; an emoji has no ground of its own and sits on a card circle.
                let d = 38 * k * m.scale
                ZStack {
                    if let t = m.token { TokenGlyph(token: t, size: d) }
                    else if let e = m.emoji {
                        Circle().fill(ink.card).overlay(Circle().stroke(ink.rule, lineWidth: 1))
                            .frame(width: d, height: d)
                        Emoji(name: e, size: d * 0.63)
                    }
                    else { Letter(name: m.name, hex: m.hex, size: d) }
                }
                .position(point(286, m.a))
            }


            centreText(zoomed, total: l.total)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverAt = p; hovered = hit(p, l.segs) } else { hovered = nil }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            if model.drill != nil { if polar(p).r < 150 { onDrillOut() }; return }
            for m in l.marks {
                let c = point(286, m.a)
                if let sid = m.slice, hypot(p.x - c.x, p.y - c.y) <= 20 * k { onDrillIn(sid); return }
            }
            if let id = hit(p, l.segs), let sid = l.segs.first(where: { $0.id == id })?.sliceId { onDrillIn(sid) }
        }
        .overlay(alignment: .topLeading) {
            if let h = hovered, let s = l.segs.first(where: { $0.id == h }) {
                HStack(spacing: 10) {
                    if let t = s.token { TokenGlyph(token: t, size: 26) }
                    else if let e = s.emoji { Emoji(name: e, size: 26) }
                    else if let n = s.network { NetworkMark(network: n, among: model.rows.map(\.token), size: 26) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.name).font(HouseFont.jost(12.5, 600)).foregroundStyle(ink.text)
                        Text("\(Fmt.usd(s.value)) · \(Fmt.percent(s.share * 100, digits: 1))\(s.sub.map { " · " + $0 } ?? "")")
                            .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                    }
                }
                .frame(minWidth: 150, alignment: .leading)
                .modifier(FloatingCard())
                .fixedSize()
                .offset(x: hoverAt.x + 14, y: hoverAt.y + 14)
                .allowsHitTesting(false)
            }
        }
    }

    private func centreText(_ zoomed: CryptoTwoModel.Slice?, total: Double) -> some View {
        let d = model.change24h(zoomed)
        return ZStack {
            if let z = zoomed { SliceGlyph(slice: z, size: 44 * k).position(x: centre * k, y: (centre - 80) * k) }
            Text(zoomed?.name.uppercased() ?? "TOTAL VALUE")
                .font(HouseFont.jost(11 * k, 500)).tracking(2).foregroundStyle(ink.faint)
                .position(x: centre * k, y: (centre - 30) * k)
            Text(Fmt.usd(total)).font(HouseFont.fraunces(40 * k)).foregroundStyle(ink.text)
                .position(x: centre * k, y: (centre + 4) * k)
            if let d {
                Text("\(d >= 0 ? "▲" : "▼") \(Fmt.percent(abs(d), digits: 1)) 24h")
                    .font(HouseFont.jost(13 * k, 500)).foregroundStyle(d >= 0 ? ink.up : ink.warm)
                    .position(x: centre * k, y: (centre + 46) * k)
            }
            if zoomed != nil {
                Text("← back").font(HouseFont.jost(12.5 * k)).foregroundStyle(ink.muted)
                    .position(x: centre * k, y: (centre + 80) * k)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }

    private func sector(_ s: Seg) -> Path {
        var a1 = s.a1
        if a1 - s.a0 >= .pi * 2 - 1e-6 { a1 = s.a0 + .pi * 2 - 1e-4 }
        var p = Path()
        let c = CGPoint(x: centre * k, y: centre * k)
        let start = Angle(radians: s.a0 - .pi / 2), end = Angle(radians: a1 - .pi / 2)
        p.addArc(center: c, radius: s.r1 * k, startAngle: start, endAngle: end, clockwise: false)
        p.addArc(center: c, radius: s.r0 * k, startAngle: end, endAngle: start, clockwise: true)
        p.closeSubpath()
        return p
    }

    private func polar(_ p: CGPoint) -> (r: CGFloat, a: Double) {
        let dx = p.x / k - centre, dy = p.y / k - centre
        var a = atan2(Double(dx), Double(-dy))
        if a < 0 { a += .pi * 2 }
        return (sqrt(dx * dx + dy * dy), a)
    }

    private func hit(_ p: CGPoint, _ segs: [Seg]) -> Int? {
        let (r, a) = polar(p)
        return segs.first { s in
            let d = (a - s.a0).truncatingRemainder(dividingBy: .pi * 2)
            return r >= s.r0 && r <= s.r1 && (d < 0 ? d + .pi * 2 : d) < s.a1 - s.a0
        }?.id
    }
}

// MARK: - Panel

/// Beside the ring. Whole ring: the holdings' total and day, then the
/// slices as a leaderboard. Zoomed: that slice — its worth, share and day, a token's
/// price and units, then what it is made of, and a wallet's value over the strip.
struct CryptoPanel: View {
    let model: CryptoTwoModel
    var onDrill: (String) -> Void
    var onEdit: (String) -> Void = { _ in }
    /// Edit on a token or a network → its colour drawer.
    var onColor: (ColorTarget) -> Void = { _ in }
    /// Add wallet → the new-wallet drawer.
    var onAddWallet: () -> Void = {}
    @Environment(\.ink) private var ink

    var body: some View {
        if let s = model.slice(model.drill) { zoomed(s) } else { overview }
    }

    /// The whole ring's panel, by lens. Tokens: every token in its own colour, filed under
    /// its network's tab. Wallets: one line a wallet, opening onto its tokens. Networks:
    /// the networks biggest first, then their tokens.
    private var overview: some View {
        let slices = model.slices
        let tokens = Set(model.rows.map(\.token.symbol)).count
        let wallets = Set(model.rows.map(\.wallet.id)).count
        let shown = model.showAll ? slices : Array(slices.prefix(10))
        return VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: model.lens.title,
                        // The count of what this tab lists, and nothing else.
                        sub: Text(countLine(tokens: tokens, wallets: wallets, networks: slices.count))) {
                CapEmoji(name: model.lens.emoji, height: Look.panelCap)
            }
            .overlay(alignment: .topTrailing) {
                if model.lens == .wallet { EditButton(title: "Add wallet", emoji: "purse", action: onAddWallet) }
            }

            switch model.lens {
            case .token:
                NetworkGroups(groups: tokenGroups, total: model.store.totalUSD) { onDrill("t:\($0.symbol)") }
            case .wallet:
                WalletList(model: model, onEdit: onEdit)
            case .network:
                // One list, so no eyebrow over it — only See all, when it's cut short.
                Bars(rows: shown.map { ($0.id, $0.name, $0.colorHex, $0.value, $0) }, onPick: onDrill) {
                    if slices.count > 10 { head("", more: slices.count) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Crypto 1's portfolio rows, filed by network, most valuable first.
    private var tokenGroups: [(network: Network, rows: [PricedHolding])] {
        PortfolioStore.grouped(model.store.dashboardRows.sorted { ($0.usdValue ?? -1) > ($1.usdValue ?? -1) })
    }

    private func zoomed(_ s: CryptoTwoModel.Slice) -> some View {
        let share = model.total > 0 ? s.value / model.total * 100 : 0
        // Edit opens the wallet's drawer, or — for a token or a network — the colour drawer.
        let wallet = model.lens == .wallet ? model.store.wallets.first(where: { $0.nickname == s.name }) : nil
        return VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: s.name,
                        // Its share only — the value is in the ring's centre, and a token's
                        // price and its move live in its price section below.
                        sub: Text("\(Fmt.percent(share, digits: 1)) of holdings"),
                        onEdit: {
                            if let wallet { onEdit(wallet.id) }
                            else if let t = s.token { onColor(.token(t)) }
                            else if let n = s.network { onColor(.network(n, held: model.rows.map(\.token))) }
                        }) {
                if let e = s.emoji, s.token == nil, s.network == nil { CapEmoji(name: e, height: Look.panelCap) }
                else { SliceGlyph(slice: s, size: Look.panelCap) }
            }

            // A token: what's held, its price now, and its price over time.
            if let t = s.token, let amount = s.amount {
                TokenPriceSection(store: model.store, token: t, amount: amount, price: s.price, hex: s.colorHex)
                    .padding(.bottom, 22)
            }

            // A wallet: its tokens by network; Edit (top right) opens its Crypto 1 module.
            if model.lens == .wallet, let w = model.store.wallets.first(where: { $0.nickname == s.name }) {
                NetworkGroups(groups: model.store.groupedRows(forWallet: w.id), total: Decimal(s.value)) { model.pricing = $0 }
            } else if model.lens == .network {
                NetworkGroups(groups: tokenGroups.filter { $0.network.name == s.name }, total: Decimal(s.value)) { model.pricing = $0 }
            } else {
                Bars(rows: s.parts.map { ($0.id, $0.name, $0.colorHex, $0.value, nil) },
                     tokens: model.lens == .token ? [:] : Dictionary(s.parts.compactMap { p in p.token.map { (p.id, $0) } },
                                                                        uniquingKeysWith: { a, _ in a }),
                     emojis: model.lens == .token ? Dictionary(s.parts.map { ($0.id, model.walletEmoji($0.name)) },
                                                               uniquingKeysWith: { a, _ in a }) : [:],
                     onPick: { _ in }) { EmptyView() }
                .frame(maxWidth: .infinity)
            }
        }
    }


    private func countLine(tokens: Int, wallets: Int, networks: Int) -> String {
        // The title already names what's counted ("Tokens"), so the line says only how many.
        switch model.lens {
        case .token: return "\(tokens) total"
        case .wallet: return "\(model.store.wallets.count) total"
        case .network: return "\(networks) total"
        }
    }


    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            Text(value).font(HouseFont.jost(16)).monospacedDigit().foregroundStyle(ink.text)
        }
    }

    private func head(_ s: String, more: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(s.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            Spacer()
            if let more {
                Button { model.showAll.toggle() } label: {
                    Text(model.showAll ? "Top 10" : "See all \(more)").font(HouseFont.jost(12.5, 500)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(ink.pill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Leaderboard rows, each a `LeaderRow` — the same columns as the wallet list, so the
    /// tabs line up — under their head, with a rule closing the list.
    private struct Bars<Head: View>: View {
        let rows: [(id: String, name: String, hex: String, value: Double, slice: CryptoTwoModel.Slice?)]
        /// A row's token, for its logo. A row with neither slice nor token gets a lettered disc.
        var tokens: [String: Token] = [:]
        /// A wallet row's emoji.
        var emojis: [String: String] = [:]
        var onPick: (String) -> Void
        @ViewBuilder var head: () -> Head
        @Environment(\.ink) private var ink

        var body: some View {
            let top = max(1, rows.map(\.value).max() ?? 1)
            let sum = max(1, rows.reduce(0) { $0 + $1.value })
            VStack(spacing: 0) {
                head().padding(.bottom, 4)
                ForEach(rows, id: \.id) { r in
                    LeaderRow(name: r.name, hex: r.hex, value: r.value, top: top, share: r.value / sum) {
                        if let s = r.slice { SliceGlyph(slice: s, size: 26) }
                        else if let t = tokens[r.id] { TokenGlyph(token: t, size: 28) }
                        else if let e = emojis[r.id] { Emoji(name: e, size: 26) }
                        else { Letter(name: r.name, hex: r.hex, size: 26) }
                    }
                    .onTapGesture { onPick(r.id) }
                }
                Rectangle().fill(ink.rule).frame(height: 1)
            }
        }
    }

}

