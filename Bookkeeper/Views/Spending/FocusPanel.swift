import SwiftUI
import BookkeeperCore

/// The right-hand panel: one category over the range — its total and share, its latest
/// lines first (what came in is what gets sorted), then its top merchants as a short
/// leaderboard. Each list stops at a handful; "See all" opens the whole of it in a window
/// (`FocusListWindow`), so the page never runs on past the rings.
struct FocusPanel: View {
    let model: SpendingScreenModel
    var onEdit: (String) -> Void
    /// A Latest row → the line-edit drawer.
    var onEditLine: (String) -> Void = { _ in }
    /// A merchant row → the line drawer on its newest line, set to change them all.
    var onEditMerchant: (String, String) -> Void = { _, _ in }
    var onSeeAll: (FocusList) -> Void = { _ in }
    /// A category row in the overview → zoom the ring into it.
    var onDrill: (String) -> Void = { _ in }
    @Environment(\.ink) private var ink

    static let top = 5
    static let topMerchants = 6

    /// Zoomed: that category. On the whole ring: the whole ring — its latest lines across
    /// every category, then the categories themselves as a leaderboard.
    var body: some View {
        if model.drill != nil, let c = model.category(model.focusId) {
            content(c)
        } else {
            overview
        }
    }

    private var overview: some View {
        let total = model.total(nil, in: model.rangeMonths)
        let lines = model.lineCountAll
        let months = model.range.count
        let cats = model.ringCategories.sorted { $0.total > $1.total }
        let (icon, title) = switch model.lens {
            case .income: ("briefcase", "Income")
            case .everyday: ("steaming_bowl", "Spending")
            case .all: ("house", "Total spending")
        }
        let tint = model.lens.discTint(ink)

        return VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: title,
                        sub: Text(months > 1 ? "avg \(Fmt.usd(total / Double(months)))/mo · \(Self.kinds(cats.count))" : Self.kinds(cats.count))) {
                CapDisc(icon: icon, tint: tint, height: Look.panelCap)
            }

            head("Latest", count: lines, more: lines > Self.top) { onSeeAll(.everything) }.padding(.bottom, 6)
            ForEach(model.latestAll(), id: \.id) { t in
                Button { onEditLine(t.id) } label: {
                    LineRow(line: t, book: model.store.categories,
                            selected: model.editingLine == t.id)
                }
                .buttonStyle(.plain)
            }

            // The leaderboard sits as one block, as wide as it needs, centred under Latest.
            CategoryBars(rows: Array(cats.prefix(Self.top)), top: cats.first?.total.double ?? 1, onPick: onDrill) {
                head("Category", count: cats.count, more: cats.count > Self.top) { onSeeAll(.categories) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    private static func kinds(_ n: Int) -> String { "\(n) \(n == 1 ? "category" : "categories")" }

    private func content(_ c: SpendingCategory) -> some View {
        let total = model.total(c.id, in: model.rangeMonths)
        let all = model.total(nil, in: model.rangeMonths)
        let ms = model.merchants(c.id)
        let months = model.range.count

        return VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: c.name, sub: Text(subline(total: total, all: all, months: months)),
                        onEdit: { onEdit(c.id) }) {
                CapDisc(icon: c.icon, tint: EmojiDisc.tint(c.colorHex), height: Look.panelCap)
            }

            let lines = model.lineCount(c.id)
            head("Latest", count: lines, more: lines > Self.top) { onSeeAll(.lines(c.id)) }.padding(.bottom, 6)
            ForEach(model.latestLines(c.id), id: \.id) { t in
                Button { onEditLine(t.id) } label: {
                    LineRow(line: t, selected: model.editingLine == t.id)
                }
                .buttonStyle(.plain)
            }

            // Set like the category leaderboard: one block, centred under Latest.
            MerchantBars(merchants: Array(ms.prefix(Self.topMerchants)), colorHex: c.colorHex, shadeOf: ms.count,
                         onPick: { onEditMerchant($0, c.id) }) {
                head(model.income ? "Payer" : "Merchant", count: ms.count, more: ms.count > Self.topMerchants) { onSeeAll(.merchants(c.id)) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
    }

    private func subline(total: Double, all: Double, months: Int) -> String {
        var s = "\(Fmt.percent(all > 0 ? total / all * 100 : 0, digits: 1)) of \(model.income ? "income" : model.withBills ? "total spending" : "spending")"
        if months > 1 { s += " · avg \(Fmt.usd(total / Double(months)))/mo" }
        return s
    }

    /// An eyebrow with its count, and "See all" when the list is cut short.
    private func head(_ s: String, count: Int, more: Bool, seeAll: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(s.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            Spacer()
            if more {
                Button(action: seeAll) {
                    Text("See all \(count)").font(HouseFont.jost(12.5, 500)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(ink.pill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Category leaderboard rows on the whole ring: emoji, name, a bar in the category's
/// colour, the amount — set as one tight block: the name column only as wide as the
/// longest name, the bars long, and the whole thing (its "Category · See all" head
/// across the top) as wide as its rows, for the panel to centre. A tap zooms the ring.
struct CategoryBars<Head: View>: View {
    let rows: [CategorySpend]
    let top: Double
    var onPick: (String) -> Void
    @ViewBuilder var head: () -> Head
    @Environment(\.ink) private var ink

    static var barWidth: CGFloat { 168 }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                head().gridCellColumns(4).gridCellUnsizedAxes(.horizontal).padding(.bottom, 8)
            }
            ForEach(rows, id: \.category.id) { c in
                GridRow {
                    EmojiDisc(c.category, size: 30)
                    Text(c.category.name).font(HouseFont.jost(16, 500)).foregroundStyle(ink.text).lineLimit(1)
                    Capsule(style: .continuous)
                        .fill(Color(hex: c.category.colorHex))
                        .frame(width: max(Look.barHeight, Self.barWidth * CGFloat(c.total.double / max(1, top))), height: Look.barHeight)
                        .frame(width: Self.barWidth, alignment: .leading)
                    Text(Fmt.usd(c.total.double)).font(HouseFont.jost(16)).monospacedDigit()
                        .foregroundStyle(ink.text)
                        .gridColumnAlignment(.trailing)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { onPick(c.category.id) }
            }
        }
        .fixedSize()
    }
}

/// The panels' header, Banking and Crypto alike: the mark and a big title, the line under
/// it — centred over the panel, with Edit (when there is one) at the top right. The total
/// itself lives once, in the ring's centre, never here too.
struct PanelHeader<Mark: View>: View {
    let title: String
    var sub: Text? = nil
    var onEdit: (() -> Void)? = nil
    /// `Look.panelCap` tall, set by the caller (`CapEmoji` for an emoji): as tall as the title's capitals.
    @ViewBuilder var mark: () -> Mark
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 0) {
            // The mark sits on the title's baseline, its top level with the capitals.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                mark().alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text(title).font(HouseFont.fraunces(Look.panelTitle)).foregroundStyle(ink.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 110)
            if let sub {
                sub.font(HouseFont.jost(14)).foregroundStyle(ink.muted).multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
        .overlay(alignment: .topTrailing) {
            if let onEdit {
                Button(action: onEdit) {
                    HStack(spacing: 6) {
                        Emoji(name: "artist_palette", size: 16)
                        Text("Edit").font(HouseFont.jost(12.5, 600))
                    }
                    .foregroundStyle(ink.muted)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Merchant leaderboard rows, set like `CategoryBars`: one tight block — the name column
/// only as wide as the longest name (a long one set a touch smaller), the bars long
/// in shades of the category's colour, the amount and its count — with its head across
/// the top, for the panel to centre. A tap opens that merchant's drawer.
struct MerchantBars<Head: View>: View {
    let merchants: [MerchantSpend]
    let colorHex: String
    /// How many merchants the shades are spread over — the whole list, so a row keeps
    /// its colour whether it shows in the panel or the window.
    let shadeOf: Int
    /// A tap → that merchant's drawer, to rename, re-sort and see it month by month.
    var onPick: (String) -> Void = { _ in }
    @ViewBuilder var head: () -> Head
    @Environment(\.ink) private var ink

    var body: some View {
        let top = max(1, merchants.first?.total.double ?? 1)
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                head().gridCellColumns(4).gridCellUnsizedAxes(.horizontal).padding(.bottom, 8)
            }
            ForEach(Array(merchants.enumerated()), id: \.element.name) { i, m in
                GridRow {
                    // A long name gets more room, then a slightly smaller size — one line.
                    Text(m.name).font(HouseFont.jost(16, 500)).foregroundStyle(ink.text)
                        .lineLimit(1).minimumScaleFactor(0.78)
                        .frame(maxWidth: 236, alignment: .leading)
                    Capsule(style: .continuous)
                        .fill(Color.shade(colorHex, i, shadeOf))
                        .frame(width: max(Look.barHeight, CategoryBars<EmptyView>.barWidth * CGFloat(m.total.double / top)), height: Look.barHeight)
                        .frame(width: CategoryBars<EmptyView>.barWidth, alignment: .leading)
                    Text(Fmt.usd(m.total.double)).font(HouseFont.jost(16)).monospacedDigit()
                        .foregroundStyle(ink.text)
                        .gridColumnAlignment(.trailing)
                    Text("×\(m.count)").font(HouseFont.jost(12)).monospacedDigit().foregroundStyle(ink.faint)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { onPick(m.name) }
            }
        }
        .fixedSize()
    }
}

/// One bank line: date, the clean name over the bank's own text, the amount.
struct LineRow: View {
    let line: BankTransaction
    /// The categories, where lines from every category share one list: each line then
    /// wears its category's emoji on its colour, as on Transactions.
    var book: CategoryBook? = nil
    var selected = false
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(ink.rule).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.dayShort(line.date)).font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                    .frame(width: 56, alignment: .leading)
                if let book {
                    TransactionIcon(line: line, book: book, size: 26)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 8 }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.displayName).font(HouseFont.jost(14)).foregroundStyle(ink.text)
                        .lineLimit(2).lineSpacing(-1).fixedSize(horizontal: false, vertical: true)
                    Text(line.rawDescription).font(HouseFont.raw(11)).foregroundStyle(ink.faint)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                // Money in reads green with its `+`, as on Transactions.
                Text(amount(line.amount.double)).font(HouseFont.jost(14)).monospacedDigit()
                    .foregroundStyle(line.effectiveKind == .income ? ink.up : ink.text)
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .background(selected ? ink.card : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
    }

    /// Money out as `−$8.77`, a refund as `+$8.77`.
    private func amount(_ v: Double) -> String { (v < 0 ? "−" : "+") + Fmt.usdCents(v) }
}

/// "See all": the whole list in a window over the screen, scrolled on its own so the rings
/// stay put behind it. A click outside, ✕ or Esc closes it.
struct FocusListWindow: View {
    let model: SpendingScreenModel
    let list: FocusList
    var rendering = false
    var onEditLine: (String) -> Void
    var onEditMerchant: (String, String) -> Void = { _, _ in }
    var onDrill: (String) -> Void = { _ in }
    var onClose: () -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        let c = list.categoryId.flatMap(model.category)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let c { EmojiDisc(c, size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
                    Text(c?.name ?? (model.income ? "All income" : "All spending")).font(HouseFont.fraunces(20))
                        .foregroundStyle(ink.text)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 14)
            Rectangle().fill(ink.rule).frame(height: 1)
            Group {
                if rendering { rows } else { ScrollView { rows }.scrollIndicators(.automatic) }
            }
        }
        .frame(width: 560)
        .frame(maxHeight: 640)
        .background(ink.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.rule, lineWidth: 1))
        .shadow(color: ink.shadow, radius: 30, y: 12)
    }

    private var title: String {
        if case .merchants = list { return model.income ? "Payer" : "Merchant" }
        if case .categories = list { return "Category" }
        return "Lines"
    }

    private var lines: [BankTransaction] {
        if let id = list.categoryId { return model.latestLines(id, limit: .max) }
        return model.latestAll(limit: .max)
    }

    @ViewBuilder private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if case .categories = list {
                let cats = model.ringCategories.sorted { $0.total > $1.total }
                CategoryBars(rows: cats, top: cats.first?.total.double ?? 1, onPick: onDrill) { EmptyView() }
                    .frame(maxWidth: .infinity)
            } else if case .merchants(let id) = list {
                let ms = model.merchants(id)
                MerchantBars(merchants: ms, colorHex: model.category(id)?.colorHex ?? "#8C9196", shadeOf: ms.count,
                             onPick: { onEditMerchant($0, id) }) { EmptyView() }
                    .frame(maxWidth: .infinity)
            } else {
                let mixed = list.categoryId == nil
                ForEach(lines, id: \.id) { t in
                    Button { onEditLine(t.id) } label: {
                        LineRow(line: t, book: mixed ? model.store.categories : nil)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 12)
    }
}

extension SpendingScreenModel.Lens {
    /// The disc behind the lens's emoji, in its header and on its pill: green for what
    /// comes in, warm for what goes out, grey for everything together.
    func discTint(_ ink: Ink) -> Color {
        switch self {
        case .income: ink.up
        case .everyday: ink.warm
        case .all: EmojiDisc.tint("#8C9196")
        }
    }
}
