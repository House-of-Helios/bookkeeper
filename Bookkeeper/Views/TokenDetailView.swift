import SwiftUI
import AppKit
import BookkeeperCore

/// Detail sheet for a tapped token: what it is, what it's worth, and where you hold it.
///
/// It draws entirely on data the refresh already fetched, so opening a token costs no
/// network call and can't be throttled — the old sheet fired a price-history and a
/// market-stats request per open, which is what starved the icon and price budget.
struct TokenDetailView: View {
    let token: Token
    let store: PortfolioStore
    /// Close the overlay. NOT `@Environment(\.dismiss)` — the modal is a custom overlay, not
    /// a sheet, so `dismiss()` would fall through to the window and quit the app.
    var onClose: () -> Void

    @State private var copied = false

    private var rows: [(wallet: String, network: Network, amount: Decimal, usd: Decimal?)] {
        store.breakdown(forSymbol: token.symbol)
            .sorted { ($0.usd ?? 0) > ($1.usd ?? 0) }
    }
    private var totalAmount: Decimal { rows.reduce(0) { $0 + $1.amount } }
    private var totalUSD: Decimal { rows.reduce(0) { $0 + ($1.usd ?? 0) } }
    private var unitPrice: Decimal? {
        guard totalAmount > 0, totalUSD > 0 else { return nil }
        return totalUSD / totalAmount
    }
    private var change: Double? { store.change24h[token.id] }

    private func amt(_ d: Decimal) -> String {
        let v = NSDecimalNumber(decimal: d).doubleValue
        if abs(v) >= 1000 { return v.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        return v.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func copyContract() {
        guard let ca = token.contractAddress, ca != "native" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ca, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 12) {
            TokenGlyph(token: token, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(token.symbol).font(AppFont.ui(21, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(Network.of(token).name).font(AppFont.ui(11)).foregroundStyle(Palette.dim)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.dim)
            }
            .buttonStyle(.plain)
        }
    }

    private var valueBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Money.usd(totalUSD)).font(AppFont.num(30)).foregroundStyle(Palette.ink)
                if let c = change {
                    Text(String(format: "%+.2f%% · 24h", c)).font(AppFont.ui(13))
                        .foregroundStyle(Ledger.change(c >= 0))
                }
            }
            HStack(spacing: 10) {
                Text("\(amt(totalAmount)) \(token.symbol)").font(AppFont.num(12)).foregroundStyle(Palette.dim)
                if let p = unitPrice {
                    Text("@ \(Money.priceFull(p))").font(AppFont.num(12)).foregroundStyle(Palette.dim)
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HELD IN").eyebrowStyle()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 10) {
                    Circle().fill(MetricStyle.networkColor(r.network)).frame(width: 8, height: 8)
                    Text(r.wallet).font(AppFont.ui(13)).foregroundStyle(Palette.ink)
                    Text(r.network.name).font(AppFont.ui(11)).foregroundStyle(Palette.dim)
                    Spacer(minLength: 12)
                    Text(amt(r.amount)).font(AppFont.num(12)).foregroundStyle(Palette.dim)
                    Text(r.usd.map { Money.usd($0) } ?? "—")
                        .font(AppFont.num(13)).foregroundStyle(Palette.ink)
                        .frame(width: 92, alignment: .trailing)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder private var contractRow: some View {
        if let ca = token.contractAddress, ca != "native" {
            Button(action: copyContract) {
                HStack(spacing: 8) {
                    Text(copied ? "copied" : ca)
                        .font(AppFont.num(10, weight: .regular)).foregroundStyle(Palette.dim)
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9)).foregroundStyle(Palette.hairline)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .help("Copy contract address")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            valueBlock
            breakdown
            contractRow
            HStack {
                Spacer()
                Button { store.hideToken(token); onClose() } label: {
                    Label("Hide this token", systemImage: "eye.slash")
                        .font(AppFont.ui(11)).foregroundStyle(Palette.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Palette.canvas)
    }
}
