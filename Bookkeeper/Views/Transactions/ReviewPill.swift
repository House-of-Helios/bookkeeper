import SwiftUI
import BookkeeperCore

/// "3 to review · last import 212 new, 40 already here" — bottom right of Spending and
/// Transactions, only while an import has left questions. A tap opens Transactions
/// filtered to To review.
struct ReviewPill: View {
    let store: SpendingStore
    var onTap: () -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        let n = store.reviewQueue().count
        if n > 0, !store.transactions.isEmpty {
            Button(action: onTap) {
                HStack(spacing: 9) {
                    Circle().fill(ink.warm).frame(width: 7, height: 7)
                    Text("\(n)  to review").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                    if let last = store.imports.last {
                        Text("· last import \(last.added) new, \(last.alreadyHere) already here")
                            .font(HouseFont.jost(13)).foregroundStyle(ink.faint)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(ink.card, in: Capsule())
                .shadow(color: ink.shadow, radius: 12, y: 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show the lines to review")
            .padding(.trailing, 30).padding(.bottom, 28)
        }
    }
}

/// The one-line confirmation after a save or an import — "✓ 12 lines now “Mr. Kale” ·
/// Groceries · future imports too", "212 new · 40 already here · 3 to review". One at a
/// time; a newer message replaces the older and restarts its clock.
@Observable
final class Toaster {
    static let shared = Toaster()
    private(set) var message: String?
    private var stamp = 0

    func say(_ text: String, for seconds: Double = 2.8) {
        stamp += 1
        let mine = stamp
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.stamp == mine else { return }
            self.message = nil
        }
    }
}

/// The mockup's `.toast`: the text colour as the ground, bottom centre — lifted clear of
/// the dock.
struct ToastView: View {
    var toaster = Toaster.shared
    @Environment(\.ink) private var ink

    var body: some View {
        if let m = toaster.message {
            Text(m).font(HouseFont.jost(13)).foregroundStyle(ink.ground)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(ink.text, in: Capsule())
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .id(m)
        }
    }
}
