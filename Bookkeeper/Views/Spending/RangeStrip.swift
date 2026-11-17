import SwiftUI
import BookkeeperCore

/// Stacked monthly bars across the whole ledger: each month's own three biggest categories
/// in colour (biggest at the bottom), everything else one grey block on top,
/// the exact whole-dollar total printed on every bar. Drag across it to pick any range;
/// hover a bar for that month's parts. Zoomed into a category, it is that category alone,
/// month by month.
///
/// Drawn at the real pixel width (`Canvas` inside a `GeometryReader`) — the v2 mockup's
/// numbers looked squashed because its SVG was stretched to fit.
struct RangeStrip: View {
    let model: SpendingScreenModel
    @Environment(\.ink) private var ink

    static let height: CGFloat = 176
    private let top: CGFloat = 24, base: CGFloat = 146

    @State private var anchor: Int?
    @State private var hover: (index: Int, at: CGPoint)?

    var body: some View {
        let data = model.stripMonths
        GeometryReader { geo in
            let w = geo.size.width
            let n = max(1, data.count)
            let slot = w / CGFloat(n)
            let bw = min(46, slot - 12)
            let maxTotal = max(1, data.map(\.total).max() ?? 1)
            let sel = model.range

            Canvas { ctx, _ in
                for (i, m) in data.enumerated() {
                    let on = sel.contains(i)
                    let x = CGFloat(i) * slot + (slot - bw) / 2
                    var y = base
                    for part in m.parts where part.value > 0 {
                        let h = CGFloat(part.value / maxTotal) * (base - top - 4)
                        let rect = CGRect(x: x, y: y - h, width: bw, height: max(0, h - 2))
                        let fill = part.colorHex.map { Color(hex: $0) } ?? ink.track
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill.opacity(on ? 1 : 0.32)))
                        y -= h
                    }
                    let total = ctx.resolve(Text(Fmt.usd(m.total)).font(HouseFont.jost(11.5, 500))
                        .foregroundStyle(on ? ink.text : ink.faint))
                    ctx.draw(total, at: CGPoint(x: x + bw / 2, y: y - 5), anchor: .bottom)
                    let label = m.month.month == 1 || i == 0
                        ? "\(Fmt.monthShort(m.month)) ’\(String(m.month.year).suffix(2))" : Fmt.monthShort(m.month)
                    let lbl = ctx.resolve(Text(label).font(HouseFont.jost(11.5))
                        .foregroundStyle(on ? ink.muted : ink.faint))
                    ctx.draw(lbl, at: CGPoint(x: x + bw / 2, y: Self.height - 3), anchor: .bottom)
                }
                if !data.isEmpty {
                    let frame = CGRect(x: CGFloat(sel.lowerBound) * slot + 2, y: 2,
                                       width: CGFloat(sel.count) * slot - 4, height: base + 4)
                    ctx.stroke(Path(roundedRect: frame, cornerRadius: 10), with: .color(ink.track), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let a = anchor ?? index(g.startLocation.x, slot: slot, n: n)
                    anchor = a
                    hover = nil
                    model.select(a, index(g.location.x, slot: slot, n: n))
                }
                .onEnded { _ in anchor = nil })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p) where anchor == nil: hover = (index(p.x, slot: slot, n: n), p)
                default: hover = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let h = hover, data.indices.contains(h.index) {
                    tooltip(data[h.index])
                        .fixedSize()
                        .offset(x: min(h.at.x + 14, w - 220), y: h.at.y + 14)
                        .allowsHitTesting(false)
                }
            }
            .help("Drag across the months to pick a range")
        }
        .frame(height: Self.height)
    }

    private func index(_ x: CGFloat, slot: CGFloat, n: Int) -> Int {
        max(0, min(n - 1, Int(x / slot)))
    }

    /// The month's categories, most first — five, then how many more and what they come to.
    private func tooltip(_ m: (month: Month, parts: [SpendingScreenModel.StripPart], total: Double,
                               detail: [SpendingScreenModel.StripPart])) -> some View {
        let shown = Array(m.detail.prefix(5))
        let more = m.detail.dropFirst(5)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(Fmt.monthYear(m.month)) · \(Fmt.usd(m.total))")
                .font(HouseFont.jost(12.5, 600)).foregroundStyle(ink.text)
            ForEach(shown, id: \.self) { p in
                HStack(spacing: 14) {
                    HStack(spacing: 5) { EmojiDisc(icon: p.icon, tint: EmojiDisc.tint(p.colorHex ?? "#8C9196"), size: 20); Text(p.name) }
                    Spacer(minLength: 0)
                    Text(Fmt.usd(p.value)).monospacedDigit()
                }
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.text)
            }
            if !more.isEmpty {
                HStack(spacing: 14) {
                    Text("\(more.count) more")
                    Spacer(minLength: 0)
                    Text(Fmt.usd(more.reduce(0) { $0 + $1.value })).monospacedDigit()
                }
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
            }
        }
        .frame(minWidth: 170, alignment: .leading)
        .modifier(FloatingCard())
    }
}

/// The mockup's tooltip / floating card: card ground, hairline, soft shadow.
struct FloatingCard: ViewModifier {
    @Environment(\.ink) private var ink
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(ink.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(ink.rule, lineWidth: 1))
            .shadow(color: ink.shadow, radius: 12, y: 6)
    }
}
