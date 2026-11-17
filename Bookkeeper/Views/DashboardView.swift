import SwiftUI
import BookkeeperCore

/// The portfolio screen: every wallet rolled up.
struct DashboardView: View {
    let store: PortfolioStore

    @State private var selectedToken: Token?

    var content: some View {
        PortfolioLedger(store: store) { selectedToken = $0 }
    }

    var body: some View {
        ScrollView { content }
        .background(Theme.ground)
        .overlay {
            // Custom overlay (not .sheet) so a click on the dimmed backdrop dismisses —
            // macOS sheets are modal and ignore outside clicks.
            if let token = selectedToken {
                ZStack {
                    Theme.ground.opacity(0.76).ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { selectedToken = nil }
                    TokenDetailView(token: token, store: store) { selectedToken = nil }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: Look.shared.ink.shadow, radius: 30, y: 10)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: selectedToken)
    }
}
