import SwiftUI
import BookkeeperCore

/// The category drawer: rename a category, give it one of 24 joyful Nippon colours, swap its
/// emoji, with a live preview. Save goes through `SpendingStore.updateCategory`, so the
/// change reaches the ring, the strip and every line at once. A colour too close to a
/// ring neighbour warns — never refuses.
struct CategoryEditor: View {
    let store: SpendingStore
    let categoryId: String
    var onClose: () -> Void

    /// False for `--snapshot`: `ImageRenderer` can't see inside a ScrollView.
    var scrolls = true

    @Environment(\.ink) private var ink
    @State private var name: String
    @State private var color: String
    @State private var icon: String

    /// Seeded here, not in `onAppear`, so an offscreen render shows the real values.
    init(store: SpendingStore, categoryId: String, scrolls: Bool = true, onClose: @escaping () -> Void) {
        self.store = store; self.categoryId = categoryId; self.scrolls = scrolls; self.onClose = onClose
        let c = store.categories.category(categoryId)
        _name = State(initialValue: c?.name ?? "")
        _color = State(initialValue: c?.colorHex ?? "#8C9196")
        _icon = State(initialValue: c?.icon ?? "package")
    }

    /// The 24 colours a category can wear — the very list wallets choose from, so Banking
    /// and Crypto offer one palette.
    static var swatches: [String] { PortfolioStore.walletColors.map(\.hex) }

    private var icons: [String] {
        var seen = Set<String>()
        let all = store.categories.categories.map(\.icon) + store.categories.incomeCategories.map(\.icon)
            + ["coin", "money_bag", "receipt", "calendar"]
        return all.filter { seen.insert($0).inserted }
    }

    private var original: SpendingCategory? { store.categories.category(categoryId) }

    var body: some View {
        Group {
            if scrolls { ScrollView { form }.scrollIndicators(.never) } else { form }
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
                        label("Edit category")
                        Text(original?.name ?? name).font(HouseFont.fraunces(22))
                            .foregroundStyle(ink.text)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                    }
                    .buttonStyle(.plain)
                }

                preview.padding(.top, 18).padding(.bottom, 4)

                field("Name") {
                    // AppKit-backed fields draw as a placeholder offscreen; the render shows the text.
                    Group {
                        if scrolls { TextField("", text: $name).textFieldStyle(.plain) }
                        else { Text(name).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                        .font(HouseFont.jost(16))
                        .foregroundStyle(ink.text)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }

                field("Colour — Nippon, the joyful half") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                        ForEach(Self.swatches, id: \.self) { h in
                            Button { color = h } label: {
                                Circle().fill(Color(hex: h))
                                    .overlay(Circle().strokeBorder(h == color ? ink.text : .clear, lineWidth: 3))
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(warning ?? "Neighbours on the ring are checked as you pick — a colour too close to the slice beside it gets a warning, not a refusal.")
                        .font(HouseFont.jost(12)).foregroundStyle(warning == nil ? ink.muted : ink.warm)
                        .lineSpacing(3).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }

                field("Emoji") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                        ForEach(icons, id: \.self) { n in
                            Button { icon = n } label: {
                                Emoji(name: n, size: 28)
                                    .padding(7)
                                    .frame(maxWidth: .infinity)
                                    .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(n == icon ? ink.text : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if original?.fixed == true {
                    field("Counts as") {
                        Text("A fixed cost — set aside in the Everyday view, back with “+ rent & bills”.")
                            .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                    }
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
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Circle().fill(Color(hex: color).opacity(0.22))
                .frame(width: 52, height: 52)
                .overlay(Emoji(name: icon, size: 30))
            VStack(alignment: .leading, spacing: 8) {
                Text(name.isEmpty ? " " : name).font(HouseFont.jost(17, 600)).foregroundStyle(ink.text)
                Capsule(style: .continuous)
                    .fill(Color(hex: color))
                    .frame(width: 180, height: 8)
            }
        }
    }

    /// The ring neighbour this colour sits too close to, if any (CIE76 ΔE under 10).
    private var warning: String? {
        let ring = store.categories.categories
        guard let i = ring.firstIndex(where: { $0.id == categoryId }), ring.count > 2, !color.isEmpty else { return nil }
        let neighbours = [ring[(i + ring.count - 1) % ring.count], ring[(i + 1) % ring.count]]
        guard let close = neighbours.first(where: { Lab(hex: $0.colorHex).distance(to: Lab(hex: color)) < 10 })
        else { return nil }
        return "Close to \(close.name), right beside it on the ring — fine to keep; the emoji and names still tell them apart."
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let c = original else { onClose(); return }
        store.updateCategory(categoryId,
                             name: trimmed.isEmpty || trimmed == c.name ? nil : trimmed,
                             colorHex: color == c.colorHex ? nil : color,
                             icon: icon == c.icon ? nil : icon)
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

/// CIE L*a*b* from an sRGB hex, for the neighbour check.
struct Lab {
    let l: Double, a: Double, b: Double

    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        func lin(_ v: UInt64) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(rgb >> 16), g = lin(rgb >> 8), bl = lin(rgb)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        l = 116 * f(y) - 16; a = 500 * (f(x) - f(y)); b = 200 * (f(y) - f(z))
    }

    func distance(to o: Lab) -> Double { sqrt(pow(l - o.l, 2) + pow(a - o.a, 2) + pow(b - o.b, 2)) }
}
