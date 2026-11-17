import SwiftUI
import BookkeeperCore

/// What the colour drawer edits: a token, or a network (which wears its token's colour,
/// so editing it edits that token — or, for a network with no token, its logo's colour).
enum ColorTarget: Identifiable, Equatable {
    case token(Token)
    case network(Network, held: [Token])

    var id: String {
        switch self {
        case .token(let t): return "t:" + (IconCache.key(for: t) ?? t.symbol)
        case .network(let n, _): return "n:" + n.name
        }
    }

    static func == (a: ColorTarget, b: ColorTarget) -> Bool { a.id == b.id }
}

/// The colour drawer, in the look of Banking's category drawer: a preview, then the
/// logo's own main colours to choose from (up to four), and Automatic to go back to the
/// logo's dominant one. A pick is stored with the icons (`IconCache.pick`) and every
/// view that wears the colour — rings, rows, tabs, Crypto 1 — follows it.
@MainActor
struct ColorEditor: View {
    let target: ColorTarget
    var onClose: () -> Void
    @Environment(\.ink) private var ink
    @State private var choice: String?
    @State private var started = false

    /// The token whose icon and colour this is, and the key its colour is stored under.
    private var token: Token? {
        switch target {
        case .token(let t): return t
        case .network(let n, let held): return NetworkTint.coin(for: n, among: held)
        }
    }
    private var key: String? {
        if let t = token { return IconCache.key(for: t) }
        if case .network(let n, _) = target { return IconCache.networkKey(n) }
        return nil
    }
    private var name: String {
        switch target {
        case .token(let t): return t.symbol
        case .network(let n, _): return n.name
        }
    }
    private var image: NSImage? {
        if let t = token { return IconCache.shared.image(for: t) }
        if case .network(let n, _) = target { return IconCache.shared.image(forNetwork: n) }
        return nil
    }
    private var palette: [String] {
        guard let img = image else { return [] }
        return ColorExtract.palette(of: img).map(Self.hex)
    }
    /// The logo's own colour, what Automatic gives back.
    private var automatic: String? { image.flatMap(ColorExtract.dominantRGB).map(Self.hex) }
    private var current: String? { key.flatMap { IconCache.shared.picked[$0] } }
    private var shown: String { choice ?? current ?? automatic ?? "#8C9196" }

    static func hex(_ c: ColorExtract.RGB) -> String {
        String(format: "#%02X%02X%02X", Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
    }

    var body: some View {
        Group {
            if SnapshotRenderer.isRendering { form } else { ScrollView { form }.scrollIndicators(.never) }
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ink.card)
        .overlay(alignment: .leading) { Rectangle().fill(ink.rule).frame(width: 1) }
        .shadow(color: ink.shadow, radius: 24, y: 8)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    label(target.isNetwork ? "Edit network colour" : "Edit token colour")
                    Text(name).font(HouseFont.fraunces(22)).foregroundStyle(ink.text)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 14) {
                Circle().fill(Color(hex: shown).opacity(0.22)).frame(width: 52, height: 52)
                    .overlay(mark(30))
                VStack(alignment: .leading, spacing: 8) {
                    Text(name).font(HouseFont.jost(17, 600)).foregroundStyle(ink.text)
                    Capsule(style: .continuous)
                        .fill(Color(hex: shown)).frame(width: 180, height: Look.barHeight)
                }
            }
            .padding(.top, 18).padding(.bottom, 4)

            field("Colour — from its icon") {
                if palette.isEmpty {
                    Text("Its icon hasn't arrived yet — the colours to pick from come out of it.")
                        .font(HouseFont.jost(12.5)).foregroundStyle(ink.muted)
                } else {
                    HStack(spacing: 12) {
                        ForEach(palette, id: \.self) { h in
                            Button { choice = h } label: {
                                Circle().fill(Color(hex: h)).frame(width: 52, height: 52)
                                    .overlay(Circle().strokeBorder(h == shown ? ink.text : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button { choice = automatic } label: {
                    HStack(spacing: 8) {
                        Circle().strokeBorder(current == nil && (choice == nil || choice == automatic) ? ink.text : ink.faint,
                                              lineWidth: 1.5).frame(width: 14, height: 14)
                        Text("Automatic — the icon's main colour").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                Text("Every ring, row and tab that wears \(name) follows the colour picked here.")
                    .font(HouseFont.jost(12)).foregroundStyle(ink.muted).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: save) {
                    Text("Save").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Button(action: onClose) {
                    Text("Cancel").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
    }

    @ViewBuilder private func mark(_ size: CGFloat) -> some View {
        switch target {
        case .token(let t): TokenGlyph(token: t, size: size)
        case .network(let n, let held): NetworkMark(network: n, among: held, size: size)
        }
    }

    private func save() {
        guard let key else { onClose(); return }
        // Automatic (or the logo's own colour picked by hand) clears the pick.
        if let choice, choice != automatic { IconCache.shared.pick(choice, forKey: key) }
        else if choice == automatic { IconCache.shared.pick(nil, forKey: key) }
        onClose()
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
    }

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            content()
        }
        .padding(.top, 20)
    }
}

extension ColorTarget {
    var isNetwork: Bool { if case .network = self { return true } else { return false } }
}
