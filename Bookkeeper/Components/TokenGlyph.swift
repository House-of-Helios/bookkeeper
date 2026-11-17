import SwiftUI
import BookkeeperCore

/// The token's real logo (bundled CoinGecko PNG) in a circle. Falls back to a
/// colored disc + first letter only when no logo is bundled (unlisted tokens).
struct TokenGlyph: View {
    let token: Token
    var size: CGFloat = 26

    var body: some View {
        if let img = IconCache.shared.image(for: token) {
            // Real logo downloaded by contract address.
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Palette.token(token.colorHex))
                .frame(width: size, height: size)
                // Still fetching its logo: a turning ring, so the disc reads as "coming".
                .overlay { if IconCache.shared.isLoading(token) { LoadingRing(size: size) } }
                .overlay(
                    Text(String(token.symbol.prefix(1)))
                        .font(HouseFont.jost(size * 0.5, 600))
                        .foregroundStyle(Palette.canvas)
                )
        }
    }
}


/// A thin arc turning round a glyph whose logo is still on its way.
struct LoadingRing: View {
    let size: CGFloat
    @State private var turn = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Palette.ink.opacity(0.85), style: StrokeStyle(lineWidth: max(1.5, size * 0.08), lineCap: .round))
            .frame(width: size + 4, height: size + 4)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turn)
            .onAppear { turn = true }
            .help("Fetching its logo")
    }
}
