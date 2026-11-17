import SwiftUI
import BookkeeperCore

/// The way in. First a beat of the mark alone on the desktop — the window itself see-through
/// (`RootView`), as old apps opened — a ring drawing itself round it; then the landing — the name, big, and the sides of the app as three
/// doors. Stocks stands among them, dimmed, not yet open.
struct OpeningView: View {
    enum Stage { case splash, landing }
    let stage: Stage
    /// A newer build waiting in the update folder: offered under the doors.
    var update: UpdateInfo? = nil
    var onInstall: () -> Void = {}
    /// How far an install has got, 0…1, once Install is pressed.
    var installing: Double? = nil
    var onSettled: () -> Void
    var onPick: (Mode) -> Void
    @Environment(\.ink) private var ink
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            switch stage {
            case .splash: splash.transition(.opacity)
            case .landing:
                ZStack {
                    ink.ground.ignoresSafeArea()
                    landing
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var splash: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 6)
                Circle().trim(from: 0, to: drawn)
                    .stroke(Color(hex: "#7BA05B"), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image("app-mark").resizable().interpolation(.high).frame(width: 96, height: 96)
            }
            .frame(width: 136, height: 136)
            // White with a soft shadow: it has to read on whatever wallpaper is behind it.
            Text("Bookkeeper").font(HouseFont.fraunces(30)).foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        .task {
            // Five seconds on purpose: the old-school open is the show.
            withAnimation(.easeInOut(duration: 4.6)) { drawn = 1 }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            onSettled()
        }
    }

    private var landing: some View {
        VStack(spacing: 56) {
            // The mark on both sides of the name, as the top bar's wordmark wears it.
            HStack(spacing: 20) {
                Image("app-mark").resizable().interpolation(.high).frame(width: 64, height: 64)
                Text("Bookkeeper").font(HouseFont.fraunces(76)).foregroundStyle(ink.text)
                Image("app-mark").resizable().interpolation(.high).frame(width: 64, height: 64)
            }
            HStack(spacing: 28) {
                door(.spending)
                door(.crypto2)
                door(.stocks, soon: true)
            }
            if let update { updateCard(update) }
        }
        .padding(40)
    }

    /// The newer build, and the one button that installs it and reopens the app.
    private func updateCard(_ u: UpdateInfo) -> some View {
        HStack(spacing: 16) {
            Emoji(name: "inbox_tray", size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Bookkeeper \(u.version) is ready").font(HouseFont.jost(16, 600)).foregroundStyle(ink.text)
                if let n = u.notes, !n.isEmpty {
                    Text(n).font(HouseFont.jost(13)).foregroundStyle(ink.muted).lineLimit(2)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            Button(action: onInstall) {
                Text(installing.map { "Installing… \(Int($0 * 100))%" } ?? "Install & restart")
                    .font(HouseFont.jost(14, 600)).foregroundStyle(ink.ground).monospacedDigit()
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(ink.text, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(hex: "#7BA05B"), lineWidth: 1.5))
    }

    private func door(_ m: Mode, soon: Bool = false) -> some View {
        Button { onPick(m) } label: {
            // Icon and name centred in the door, equal room above and below; "Coming soon"
            // hangs under the name without moving them.
            VStack(spacing: 18) {
                Emoji(name: m.emoji, size: 96)
                Text(m.label).font(HouseFont.fraunces(30)).foregroundStyle(ink.text)
                    .overlay(alignment: .bottom) {
                        if soon {
                            Text("Coming soon").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                                .fixedSize().offset(y: 26)
                        }
                    }
            }
            .frame(width: 250, height: 270)
            .background(ink.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(ink.rule, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(DoorStyle())
        .opacity(soon ? 0.45 : 1)
        .disabled(soon)
    }
}

/// A door lifts a little under the pointer and gives under a press.
private struct DoorStyle: ButtonStyle {
    @State private var over = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : over ? 1.03 : 1)
            .shadow(color: .black.opacity(over ? 0.25 : 0), radius: 18, y: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: over)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { over = $0 }
    }
}
