import SwiftUI
import BookkeeperCore

/// Budget — "did I keep any, and where did it go against the plan?" for one month.
/// Top: the month's flow, every category's spending laid end to end in one band, and
/// what income was left over as an open space at the end (savings are not a category).
/// Below: one set of nested rings per family (Food: Groceries, Eating out, Cafés), each
/// ring filling as its category spends what it had. Then the charges that come every
/// month. Hover anything for its card; tap an amount to plan it.
///
/// Envelope rules from Actual Budget: a hand-set plan's leftover carries into next month;
/// an overspend doesn't, it comes out of next month's unplanned money.
/// `_Plan/2026-11-13-budget-tab-and-going-public.md`. Dev app only for now (`Screen.shown`).
struct BudgetView: View {
    let store: SpendingStore
    var rendering = false

    @State private var month: Month?
    /// The category whose plan editor is open.
    @State private var editing: String?
    /// The ring under the pointer, and where on the page: its card is drawn once, over the
    /// whole page, so nothing laid out after the rings can paint over it.
    @State private var hover: RingHover?
    @State private var pageWidth: CGFloat = 0

    struct RingHover: Equatable {
        var line: BudgetLine
        var point: CGPoint
        /// The ring's centre, on the page: rings in the left half open their card to the
        /// right of the pointer, rings in the right half to the left, so it never leaves the window.
        var ringX: CGFloat
    }

    private var ink: Ink { Ink.resolve(store.settings.theme, systemIsDark: SystemAppearance.shared.isDark) }
    private var months: [Month] { store.budgetMonths }
    private var current: Month? { month ?? months.last }

    var body: some View {
        Group {
            if let m = current {
                let b = store.budget(for: m)
                if rendering { page(b) } else { ScrollView { page(b) } }
            } else {
                Text("Drop a bank export on Spending, and its months appear here to plan.")
                    .font(HouseFont.jost(14)).foregroundStyle(ink.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(ink.ground)
        .environment(\.ink, ink)
        .environment(\.colorScheme, ink.colorScheme)
    }

    private func page(_ b: BudgetMonth) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            head(b).padding(.bottom, 18)
            FlowBand(store: store, month: b).frame(height: 54).zIndex(2)
            legend(b).padding(.top, 12).padding(.bottom, 40)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 44, alignment: .top)],
                      alignment: .leading, spacing: 44) {
                ForEach(b.groups, id: \.group.id) { g in family(g, b.month) }
            }
            RecurringList(store: store).padding(.top, 52)
            Text("≈ marks a guess from the months before; a guess carries nothing over. Tap an amount to plan it, and what's left each month carries into the next.")
                .font(HouseFont.jost(12)).foregroundStyle(ink.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 36)
        }
        .frame(maxWidth: 1360, alignment: .leading)
        .padding(.top, 24).padding(.horizontal, 40).padding(.bottom, 96)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: BudgetView.space)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
        .overlay(alignment: .topLeading) {
            if let h = hover {
                BudgetTip(store: store, line: h.line, month: b.month)
                    .fixedSize()
                    .offset(x: h.ringX > pageWidth / 2 ? h.point.x - 256 : h.point.x + 16, y: h.point.y + 12)
                    .allowsHitTesting(false)
            }
        }
    }

    static let space = "budget-page"

    // MARK: Head

    private func head(_ b: BudgetMonth) -> some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                step("‹", to: months.last { $0 < b.month })
                Text(Self.title(b.month)).font(HouseFont.fraunces(26)).foregroundStyle(ink.text)
                step("›", to: months.first { $0 > b.month })
            }
            Spacer()
            if b.groups.flatMap(\.lines).contains(where: { $0.guessed && $0.plan > 0 }) {
                Button { store.keepGuesses(in: b.month) } label: {
                    Text("Keep every ≈ guess as the plan").font(HouseFont.jost(12.5))
                        .foregroundStyle(ink.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(ink.pill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func step(_ glyph: String, to target: Month?) -> some View {
        Button { if let target { month = target; editing = nil } } label: {
            Text(glyph).font(HouseFont.jost(22)).foregroundStyle(target == nil ? ink.track : ink.muted)
                .frame(width: 26, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(target == nil)
    }

    static func title(_ m: Month) -> String {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"
        return f.string(from: date(m))
    }

    static func shortMonth(_ m: Month) -> String {
        let f = DateFormatter(); f.dateFormat = "LLL"
        return f.string(from: date(m))
    }

    private static func date(_ m: Month) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: m.year, month: m.month, day: 1)) ?? Date()
    }

    private func legend(_ b: BudgetMonth) -> some View {
        HStack(spacing: 26) {
            figure("In", b.income.double)
            figure("Spent", b.spent.double)
            if b.kept >= 0 {
                figure("Kept", b.kept.double)
            } else {
                Text("Spent \(Fmt.usd(-b.kept.double)) more than came in")
                    .font(HouseFont.jost(13, 500)).foregroundStyle(ink.warm)
            }
            figure("Planned", b.plan.double)
            if b.unplanned > 0 {
                figure("Not planned yet", b.unplanned.double)
            } else if b.unplanned < 0 {
                Text("Planned \(Fmt.usd(-b.unplanned.double)) more than came in")
                    .font(HouseFont.jost(13, 500)).foregroundStyle(ink.warm)
            }
            if b.overspentBefore > 0 {
                Text("\(Fmt.usd(b.overspentBefore.double)) overspent in \(Self.shortMonth(b.month.previous)) comes out of this month")
                    .font(HouseFont.jost(12.5)).foregroundStyle(ink.faint)
            }
        }
    }

    private func figure(_ label: String, _ v: Double) -> some View {
        (Text(label + " ") + Text(Fmt.usd(v)).foregroundStyle(ink.text).fontWeight(.medium))
            .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
    }

    // MARK: A family

    private func family(_ g: BudgetGroupLine, _ month: Month) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NestedRings(group: g) { line, point, ringX in
                if let line { hover = RingHover(line: line, point: point, ringX: ringX) }
                else if let h = hover, g.lines.contains(where: { $0.category.id == h.line.category.id }) { hover = nil }
            }
            .frame(width: 220, height: 220).frame(maxWidth: .infinity)
            Text(g.group.name).font(HouseFont.fraunces(18)).foregroundStyle(ink.text)
            VStack(spacing: 0) {
                ForEach(g.lines, id: \.category.id) { line in row(line, month) }
            }
        }
    }

    private func row(_ l: BudgetLine, _ month: Month) -> some View {
        let over = l.left < 0
        return HStack(spacing: 10) {
            EmojiDisc(l.category, size: 24)
            Text(l.category.name).font(HouseFont.jost(13)).foregroundStyle(ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button { editing = l.category.id } label: {
                Group {
                    if l.available == 0 {
                        Text(Fmt.usd(l.spent.double)) + Text(" · no plan yet").foregroundStyle(ink.faint)
                    } else {
                        Text(Fmt.usd(l.spent.double)) + Text(" of ").foregroundStyle(ink.faint)
                            + Text((l.guessed ? "≈" : "") + Fmt.usd(l.available.double))
                    }
                }
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                .fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(editing == l.category.id ? ink.pill : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { editing == l.category.id },
                                          set: { if !$0, editing == l.category.id { editing = nil } }),
                     arrowEdge: .bottom) {
                PlanEditor(store: store, line: l, month: month) { editing = nil }
                    .environment(\.ink, ink)
                    .environment(\.colorScheme, ink.colorScheme)
            }
            Text((over ? "−" : "") + Fmt.usd(abs(l.left.double)))
                .font(HouseFont.jost(13, 500)).foregroundStyle(over ? ink.warm : ink.text)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
    }
}

// MARK: - The plan editor

/// Opened from a row's amount: type the monthly plan, or take one of Actual's quick picks
/// (last month, 3 / 6 / 12-month average, this month so far). Enter sets, Esc closes.
struct PlanEditor: View {
    let store: SpendingStore
    let line: BudgetLine
    let month: Month
    var onDone: () -> Void = {}

    @Environment(\.ink) private var ink
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var id: String { line.category.id }

    private var picks: [(String, Decimal)] {
        var out: [(String, Decimal)] = []
        let last = store.spent(id, in: month.previous)
        if last > 0 { out.append(("Last month", last)) }
        for n in [3, 6, 12] {
            if let a = store.averageSpend(id, months: n, before: month) { out.append(("Average, \(n) months", a)) }
        }
        let now = store.spent(id, in: month)
        if now > 0 { out.append(("This month so far", now)) }
        // Same amount twice reads as noise: keep the first label that names it.
        var seen = Set<Int>()
        return out.filter { seen.insert(NSDecimalNumber(decimal: $0.1).intValue).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                EmojiDisc(line.category, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.category.name).font(HouseFont.jost(14, 600)).foregroundStyle(ink.text)
                    Text("Each month").font(HouseFont.jost(12)).foregroundStyle(ink.faint)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("$").font(HouseFont.fraunces(24)).foregroundStyle(ink.muted)
                TextField(line.guessed ? Self.whole(line.plan) : "", text: $draft)
                    .textFieldStyle(.plain)
                    .font(HouseFont.fraunces(28)).foregroundStyle(ink.text)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: onDone)
                Button("Set", action: commit)
                    .buttonStyle(.plain).font(HouseFont.jost(13, 500)).foregroundStyle(ink.text)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(ink.pill, in: Capsule())
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(ink.rule).frame(height: 1) }

            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("QUICK PICKS").font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
                        .padding(.bottom, 6)
                    ForEach(picks, id: \.0) { label, amount in
                        Button { set(Self.roundUp(amount)) } label: {
                            HStack {
                                Text(label).font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                                Spacer()
                                Text(Fmt.usd(NSDecimalNumber(decimal: amount).doubleValue))
                                    .font(HouseFont.jost(13, 500)).foregroundStyle(ink.text)
                            }
                            .padding(.vertical, 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !line.guessed {
                Button {
                    store.setPlan(id, nil); onDone()
                } label: {
                    Text("Back to the guess").font(HouseFont.jost(12.5)).foregroundStyle(ink.muted).underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 300, alignment: .leading)
        .background(ink.card)
        .onAppear {
            draft = line.guessed ? "" : Self.whole(line.plan)
            focused = true
        }
    }

    private func commit() {
        let text = draft.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty, line.guessed, line.plan > 0 { set(line.plan); return }   // Enter on the guess keeps it
        if let v = Decimal(string: text), v >= 0 { set(v) } else { onDone() }
    }

    private func set(_ v: Decimal) {
        store.setPlan(id, v, from: month)
        onDone()
    }

    static func whole(_ d: Decimal) -> String { "\(NSDecimalNumber(decimal: d).intValue)" }
    /// Quick picks land on whole dollars, rounded up.
    static func roundUp(_ d: Decimal) -> Decimal { Decimal(NSDecimalNumber(decimal: d).doubleValue.rounded(.up)) }
}

// MARK: - The hover card

/// One category's month, in the card that floats beside a ring or a slice of the band:
/// what it had, what went, the merchants it went to, and how last month compares.
struct BudgetTip: View {
    let store: SpendingStore
    let line: BudgetLine
    let month: Month
    @Environment(\.ink) private var ink

    var body: some View {
        let c = line.category
        let merchants = store.merchants(in: c.id, range: month...month)
        let recurring = Set(store.recurring().map(\.name))
        let last = store.spent(c.id, in: month.previous)
        let used = line.available > 0 ? line.spent.double / line.available.double : nil
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                EmojiDisc(c, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.text)
                    if let g = BudgetGroup.of(c.id) {
                        Text(g.name).font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                    }
                }
            }
            (Text(Fmt.usd(line.spent.double)).foregroundStyle(ink.text).fontWeight(.medium)
             + Text(line.available > 0 ? " spent of " + (line.guessed ? "≈" : "") + Fmt.usd(line.available.double) : " spent, no plan yet"))
                .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
            if line.carried > 0 {
                Text("includes \(Fmt.usd(line.carried.double)) carried from \(BudgetView.shortMonth(month.previous))")
                    .font(HouseFont.jost(12)).foregroundStyle(ink.faint)
            }
            if let used {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.track)
                        Capsule().fill(line.left < 0 ? ink.warm : Color(hex: c.colorHex))
                            .frame(width: g.size.width * min(1, used))
                    }
                }
                .frame(height: 5)
                Text(line.left < 0 ? "\(Fmt.usd(-line.left.double)) over · \(Fmt.percent(used * 100)) of plan"
                                   : "\(Fmt.usd(line.left.double)) left · \(Fmt.percent(used * 100)) used")
                    .font(HouseFont.jost(12.5, 500)).foregroundStyle(line.left < 0 ? ink.warm : ink.text)
            }
            if !merchants.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(merchants.prefix(3), id: \.name) { m in
                        HStack {
                            Text((recurring.contains(m.name) ? "↻ " : "") + m.name).lineLimit(1)
                            Spacer(minLength: 12)
                            Text(Fmt.usd(m.total.double)).foregroundStyle(ink.text)
                        }
                    }
                    if merchants.count > 3 {
                        Text("and \(merchants.count - 3) more").foregroundStyle(ink.faint)
                    }
                }
                .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                .padding(.top, 3)
            }
            Text("\(merchants.reduce(0) { $0 + $1.count }) lines · \(BudgetView.shortMonth(month.previous)) \(Fmt.usd(last.double))")
                .font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
        }
        .frame(width: 240, alignment: .leading)
        .modifier(FloatingCard())
    }
}

// MARK: - The month's flow

/// Every category's spending end to end, in family order, then what income left over as
/// an open, outlined space — kept money is not one more coloured category. The band's
/// full width is the month's income (or its spending, when that was more). Hover a slice
/// for its card.
private struct FlowBand: View {
    let store: SpendingStore
    let month: BudgetMonth
    @Environment(\.ink) private var ink
    @State private var hot: String?

    var body: some View {
        let parts = month.groups.flatMap(\.lines).filter { $0.spent > 0 }
        let spent = month.spent.double
        let kept = max(0, month.kept.double)
        let whole = max(spent + kept, 1)
        GeometryReader { geo in
            let gap: CGFloat = 2
            let usable = geo.size.width - gap * CGFloat(parts.count)
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.element.category.id) { i, l in
                    let w = max(1, usable * CGFloat(l.spent.double / whole))
                    let fill = Color(hex: l.category.colorHex)
                    let id = l.category.id
                    UnevenRoundedRectangle(topLeadingRadius: i == 0 ? 8 : 0, bottomLeadingRadius: i == 0 ? 8 : 0,
                                           bottomTrailingRadius: kept == 0 && i == parts.count - 1 ? 8 : 0,
                                           topTrailingRadius: kept == 0 && i == parts.count - 1 ? 8 : 0)
                        .fill(fill.opacity(hot == nil || hot == id ? 1 : 0.55))
                        .frame(width: w)
                        .overlay {
                            if w > 64 {
                                Text(l.category.name).font(HouseFont.jost(12, 500))
                                    .foregroundStyle(Ledger.ink(on: fill)).lineLimit(1)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .onHover { on in hover(id, on) }
                        .overlay(alignment: .topLeading) {
                            if hot == id {
                                BudgetTip(store: store, line: l, month: month.month)
                                    .fixedSize()
                                    .offset(x: tipX(at: offset(i, parts, usable, whole, gap), width: geo.size.width), y: 64)
                                    .allowsHitTesting(false)
                            }
                        }
                        .zIndex(hot == id ? 1 : 0)
                }
                if kept > 0 {
                    let w = usable * CGFloat(kept / whole)
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(ink.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .background(Color.clear.contentShape(Rectangle()))
                        .frame(width: w)
                        .overlay {
                            if w > 80 {
                                Text("Kept \(Fmt.usd(kept))").font(HouseFont.jost(13, 500))
                                    .foregroundStyle(ink.text).lineLimit(1)
                            }
                        }
                        .onHover { on in hover("kept", on) }
                        .overlay(alignment: .topTrailing) {
                            if hot == "kept" { keptTip(kept).fixedSize().offset(y: 64).allowsHitTesting(false) }
                        }
                        .zIndex(hot == "kept" ? 1 : 0)
                }
            }
        }
    }

    private func hover(_ id: String, _ on: Bool) {
        if on { hot = id } else if hot == id { hot = nil }
    }

    /// Where slice `i` starts, so its card can be nudged back inside the band's width.
    private func offset(_ i: Int, _ parts: [BudgetLine], _ usable: CGFloat, _ whole: Double, _ gap: CGFloat) -> CGFloat {
        parts.prefix(i).reduce(0) { $0 + max(1, usable * CGFloat($1.spent.double / whole)) + gap }
    }

    private func tipX(at x: CGFloat, width: CGFloat) -> CGFloat {
        min(0, width - x - 270)
    }

    private func keptTip(_ kept: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Kept \(Fmt.usd(kept))").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.text)
            if month.income > 0 {
                Text("\(Fmt.percent(kept / month.income.double * 100)) of the \(Fmt.usd(month.income.double)) that came in")
                    .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
            }
            Text("Income less spending, this month only — not a category, so it has no colour.")
                .font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 240, alignment: .leading)
        .modifier(FloatingCard())
    }
}

// MARK: - Nested rings

/// One family: a ring per category, outermost first, each filling clockwise from twelve
/// o'clock as its spending reaches what it had. Past it, the ring is full and the overrun
/// laps it again as a pale wash of its own colour with a dark dashed border round it. The middle says what the family has left. Hover
/// a ring for its category's card.
private struct NestedRings: View {
    let group: BudgetGroupLine
    /// The hovered ring's line (nil when none), the pointer and the ring's centre x, all
    /// on the page's coordinates.
    var onHover: (BudgetLine?, CGPoint, CGFloat) -> Void = { _, _, _ in }

    @Environment(\.ink) private var ink
    @State private var hot: Int?
    @State private var at: CGPoint = .zero

    private let hole: CGFloat = 40, gap: CGFloat = 5

    private func width(_ outer: CGFloat) -> CGFloat {
        let n = CGFloat(group.lines.count)
        return min(26, (outer - hole - gap * (n - 1)) / n)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 2
            let w = width(outer)
            Canvas { ctx, _ in
                for (i, l) in group.lines.enumerated() {
                    let r = outer - w / 2 - CGFloat(i) * (w + gap)
                    let track = Path { $0.addArc(center: c, radius: r, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) }
                    ctx.stroke(track, with: .color(ink.track), lineWidth: w)
                    let have = l.available.double, spent = l.spent.double
                    let color = Color(hex: l.category.colorHex).opacity(hot == nil || hot == i ? 1 : 0.5)
                    let share = have > 0 ? spent / have : (spent > 0 ? 2 : 0)
                    ctx.stroke(arc(c, r, min(share, 1)), with: .color(color),
                               style: StrokeStyle(lineWidth: w, lineCap: share >= 1 ? .butt : .round))
                    // Past the plan: the overrun laps the ring again as a paler wash of its own
                    // colour with a dark dashed border round it — never darkened, so a red ring never
                    // turns a muddy dark red, and the dash reads on every ring colour.
                    if share > 1 {
                        let lap = arc(c, r, min(share - 1, 1))
                        ctx.stroke(lap, with: .color(.white.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: w, lineCap: .butt))
                        let lw = max(1.5, w * 0.12)
                        ctx.stroke(outline(c, r, w - lw, min(share - 1, 1)), with: .color(Color(hex: "#1c1f24").opacity(0.8)),
                                   style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                    }
                }
            }
            .contentShape(Circle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    at = p
                    let d = hypot(p.x - c.x, p.y - c.y)
                    let i = Int(((outer - d) / (w + gap)).rounded(.down))
                    let inRing = i >= 0 && i < group.lines.count && outer - d - CGFloat(i) * (w + gap) <= w
                    hot = inRing ? i : nil
                } else {
                    hot = nil
                }
                let page = geo.frame(in: .named(BudgetView.space))
                onHover(hot.map { group.lines[$0] },
                        CGPoint(x: page.minX + at.x, y: page.minY + at.y), page.midX)
            }
            .overlay { centre }
        }
    }

    private var centre: some View {
        let v = group.left.double
        return VStack(spacing: 0) {
            Text((v < 0 ? "−" : "") + Fmt.usd(abs(v)))
                .font(HouseFont.fraunces(17)).foregroundStyle(v < 0 ? ink.warm : ink.text)
            Text(v < 0 ? "OVER" : "LEFT").font(HouseFont.jost(9, 500)).tracking(1.5).foregroundStyle(ink.faint)
        }
        .allowsHitTesting(false)
    }

    /// The border of a ring band `w` wide from twelve o'clock round `share` of a turn:
    /// outer edge, the far end, inner edge back, the near end. A whole lap is two circles.
    private func outline(_ c: CGPoint, _ r: CGFloat, _ w: CGFloat, _ share: Double) -> Path {
        Path { p in
            guard share > 0 else { return }
            let ro = r + w / 2, ri = r - w / 2
            if share >= 1 {
                p.addEllipse(in: CGRect(x: c.x - ro, y: c.y - ro, width: ro * 2, height: ro * 2))
                p.addEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: ri * 2, height: ri * 2))
                return
            }
            let a0 = Angle.degrees(-90), a1 = Angle.degrees(-90 + 360 * share)
            p.addArc(center: c, radius: ro, startAngle: a0, endAngle: a1, clockwise: false)
            p.addArc(center: c, radius: ri, startAngle: a1, endAngle: a0, clockwise: true)
            p.closeSubpath()
        }
    }

    private func arc(_ c: CGPoint, _ r: CGFloat, _ share: Double) -> Path {
        Path { p in
            guard share > 0 else { return }
            p.addArc(center: c, radius: r, startAngle: .degrees(-90),
                     endAngle: .degrees(-90 + 360 * min(share, 0.9999)), clockwise: false)
        }
    }
}

// MARK: - Every month

/// The charges that land every month, found in the ledger: what the month starts already
/// owing. Two columns on hairlines, biggest first.
private struct RecurringList: View {
    let store: SpendingStore
    @Environment(\.ink) private var ink

    var body: some View {
        let list = store.recurring()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text("Comes every month").font(HouseFont.fraunces(18)).foregroundStyle(ink.text)
                    Text("\(Fmt.usd(list.reduce(0) { $0 + $1.amount }.double)) a month, \(list.count) charges")
                        .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 44, alignment: .top)],
                          alignment: .leading, spacing: 0) {
                    ForEach(list) { r in row(r) }
                }
            }
        }
    }

    private func row(_ r: RecurringCharge) -> some View {
        let c = store.categories.category(r.categoryId)
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let next = Calendar(identifier: .gregorian).date(from: DateComponents(year: r.next.year, month: r.next.month, day: r.next.day)) ?? Date()
        return HStack(spacing: 10) {
            if let c { EmojiDisc(c, size: 24) }
            Text(r.name).font(HouseFont.jost(13)).foregroundStyle(ink.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text("next \(f.string(from: next))")
                .font(HouseFont.jost(12)).foregroundStyle(ink.faint).fixedSize()
            Text(Fmt.usd(r.amount.double)).font(HouseFont.jost(13, 500)).foregroundStyle(ink.text)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
        .help("\(r.months) months running, on about the \(r.day)\(Self.ordinal(r.day))")
    }

    static func ordinal(_ d: Int) -> String {
        if (11...13).contains(d % 100) { return "th" }
        return ["th", "st", "nd", "rd"][d % 10 < 4 ? d % 10 : 0]
    }
}
