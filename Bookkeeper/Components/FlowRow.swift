import SwiftUI

/// A row that wraps onto the next line when it runs out of width.
///
/// An `HStack` doesn't wrap — with twenty-four wallets the legend simply ran off the
/// side of the window and the last several were unreachable. `Layout` rather than a
/// `LazyVGrid` because the items are different widths: a grid would give "Spare" the
/// same column as "Cold Vault" and leave a ragged gap after every short name.
struct FlowRow: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                widest = max(widest, x)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: max(widest, x), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            if x > bounds.minX { x += spacing }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
