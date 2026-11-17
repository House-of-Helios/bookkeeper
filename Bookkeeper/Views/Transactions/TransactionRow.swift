import SwiftUI
import BookkeeperCore

/// One ledger line, as the mockup's `.row`: date · emoji in a tinted circle · clean name
/// over the bank's raw text · category chip · amount. Income reads green with a `+`, a
/// transfer reads muted with no sign, a line to review wears a warm dot.
struct TransactionRow: View {
    let line: BankTransaction
    let book: CategoryBook
    var selected = false
    var onTap: () -> Void = {}
    @Environment(\.ink) private var ink
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Text(Fmt.dayShort(line.date)).font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                    .frame(width: 64, alignment: .leading)
                TransactionIcon(line: line, book: book)
                    .frame(width: 40, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(line.displayName).font(HouseFont.jost(14)).foregroundStyle(ink.text).lineLimit(1)
                        if line.needsReview {
                            Circle().fill(ink.warm).frame(width: 7, height: 7).help("To review")
                        }
                    }
                    Text(line.rawDescription).font(HouseFont.raw(11)).foregroundStyle(ink.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chip.frame(width: 190, alignment: .leading)
                amount.font(HouseFont.jost(14.5)).monospacedDigit()
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(selected ? ink.card : hovering ? ink.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var chip: some View {
        switch line.effectiveKind {
        case .spend:
            let c = book.category(line.effectiveCategoryId) ?? book.category(CategoryBook.fallbackId)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: c?.colorHex ?? "#8C9196"))
                    .frame(width: 8, height: 8)
                Text(c?.name ?? "Other")
            }
            .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
        case .income:
            Text(book.category(line.effectiveCategoryId)?.name ?? "Other income")
                .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
        case .transfer:
            Text("Internal transfer · not spending").font(HouseFont.jost(12)).foregroundStyle(ink.muted)
        }
    }

    private var amount: some View {
        let v = line.amount.double
        switch line.effectiveKind {
        case .income: return Text("+" + Fmt.usdCents(v)).foregroundStyle(ink.up)
        case .transfer: return Text(Fmt.usdCents(v)).foregroundStyle(ink.faint)
        case .spend: return Text(Fmt.signedCents(v)).foregroundStyle(ink.text)
        }
    }
}

/// The line's emoji in a tinted circle: its category's colour for spending, green for
/// money in (with the income kind's emoji), the pill grey and ↔ for a transfer.
struct TransactionIcon: View {
    let line: BankTransaction
    let book: CategoryBook
    var size: CGFloat = 34
    @Environment(\.ink) private var ink

    var body: some View {
        let (tint, icon) = look
        EmojiDisc(icon: icon, tint: tint, size: size)
    }

    private var look: (Color, String) {
        switch line.effectiveKind {
        case .income:
            return (ink.up, book.category(line.effectiveCategoryId)?.icon ?? "money_bag")
        case .transfer:
            return (Color(hex: "#8C9196"), "left-right_arrow")
        case .spend:
            let c = book.category(line.effectiveCategoryId) ?? book.category(CategoryBook.fallbackId)
            return (EmojiDisc.tint(c?.colorHex ?? "#8C9196"), c?.icon ?? "package")
        }
    }
}

/// An emoji on a circle tinted its category's colour — how a category shows in every list,
/// so a row reads as its slice of the ring.
struct EmojiDisc: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 34

    init(icon: String, tint: Color, size: CGFloat = 34) {
        self.icon = icon; self.tint = tint; self.size = size
    }

    init(_ c: SpendingCategory, size: CGFloat = 34) {
        self.init(icon: c.icon, tint: Self.tint(c.colorHex), size: size)
    }

    static func tint(_ hex: String) -> Color { Color(hex: hex) }

    @Environment(\.ink) private var ink

    /// Solid, never see-through: a see-through tint over a dark ground turns to mud. Light,
    /// the colour washed into white; dark, the colour itself, dimmed so the emoji stands out.
    var body: some View {
        Circle().fill(ink.isDark ? tint : .white)
            .overlay(Circle().fill(ink.isDark ? Color.black.opacity(0.38) : tint.opacity(0.28)))
            .frame(width: size, height: size)
            .overlay(Emoji(name: icon, size: size * 0.62))
    }
}
