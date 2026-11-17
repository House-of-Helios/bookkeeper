import SwiftUI
import BookkeeperCore

/// Spending — "where does the money go?" in one space. Top to bottom: the range strip
/// (presets + drag), the range sentence, then the two rings beside the focus panel.
/// Tap a slice or its emoji to zoom into that category; the back bar, Esc or a tap on
/// the ring's middle comes back out. Ported from `_Plan/2026-10-20-spending-mockups.html`
/// (direction C, mockup v3) — behaviour as well as look.
///
/// Wears its own theme (`Ink`, from `spending/settings.json`), not the v1 screens' black.
struct SpendingView: View {
    let store: SpendingStore
    let importer: SpendingImporter
    @State private var model: SpendingScreenModel
    @Namespace private var ns

    /// For `--snapshot`: draw without the ScrollViews `ImageRenderer` can't see into.
    var rendering = false

    /// The review pill: Transactions, filtered to To review.
    var onReview: () -> Void = {}

    init(store: SpendingStore, importer: SpendingImporter, model: SpendingScreenModel? = nil,
         rendering: Bool = false, onReview: @escaping () -> Void = {}) {
        self.store = store
        self.importer = importer
        self.rendering = rendering
        self.onReview = onReview
        _model = State(initialValue: model ?? SpendingScreenModel(store: store))
    }

    private var ink: Ink { Ink.resolve(store.settings.theme, systemIsDark: SystemAppearance.shared.isDark) }

    var body: some View {
        Group {
            page
        }
        // minHeight 0: offscreen the page is taller than the canvas, and the pill and
        // drawer must pin to the canvas, not to the page's bottom.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(ink.ground)
        .overlay(alignment: .bottomTrailing) { ReviewPill(store: store, onTap: onReview) }
        // Anything floating closes on a click outside it, without saving.
        .overlay { if floating { Scrim(action: closeFloating) } }
        .overlay { if let l = model.list { listWindow(l) } }
        .overlay(alignment: .trailing) { editor }
        .environment(\.ink, ink)
        .environment(\.colorScheme, ink.colorScheme)
        .dropDestination(for: URL.self) { urls, _ in
            importer.importFiles(urls.filter { $0.pathExtension.lowercased() == "csv" })
            return true
        }
        .onChange(of: importer.generation) { _, _ in model.ledgerChanged() }
        .animation(.easeOut(duration: 0.22), value: model.editing)
        .animation(.easeOut(duration: 0.22), value: model.editingLine)
    }

    private var floating: Bool { model.editing != nil || model.editingLine != nil || model.list != nil }

    private func closeFloating() {
        if model.editing != nil || model.editingLine != nil {
            model.editing = nil; model.editingLine = nil
        } else {
            model.list = nil
        }
    }

    private func listWindow(_ l: FocusList) -> some View {
        FocusListWindow(model: model, list: l, rendering: rendering,
                        onEditLine: editLine,
                        onEditMerchant: editMerchant,
                        onDrill: { id in model.list = nil; drillIn(id) },
                        onClose: { model.list = nil })
            .padding(.vertical, 40)
            // Grows in, but leaves at once: a window fading out kept its scroll view under
            // the pointer, and the page behind would not scroll until clicked.
            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.transactions.isEmpty {
                SpendingEmptyState(importer: importer)
            } else {
                stripHead.padding(.bottom, 4)
                // Above the stage, so a bar's hover card floats over the ring and the panel.
                RangeStrip(model: model).zIndex(1)
                GeometryReader { g in stage(g.size) }
            }
        }
        // One screen, no page scroll: the ring shrinks to the height there is, and only
        // the panel scrolls if its lists run long.
        .frame(maxWidth: 1360, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20).padding(.horizontal, 40).padding(.bottom, 64)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Strip head + range sentence

    private var stripHead: some View {
        HStack(alignment: .bottom) {
            stripTitle
            Spacer()
            HStack(spacing: 2) {
                ForEach(SpendingScreenModel.Preset.allCases) { p in
                    let on = model.preset == p
                    Button { model.applyPreset(p) } label: {
                        Text(p.rawValue).font(HouseFont.jost(12))
                            .foregroundStyle(on ? ink.text : ink.muted)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? ink.pill : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var stripTitle: some View {
        if let d = model.drill, let c = model.category(d) {
            HStack(spacing: 8) {
                EmojiDisc(c, size: 26)
                (Text(c.name).foregroundStyle(ink.text).fontWeight(.medium) + Text(" · monthly"))
            }
            .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
        } else {
            HStack(spacing: 5) {
                Text("Monthly").font(HouseFont.jost(13, 500)).foregroundStyle(ink.text)
                Text("· each month's top 3")
            }
            .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
        }
    }

    // MARK: - Stage: rings + focus

    /// Lined up on the strip above: everything starts at the first bar's left edge, the
    /// panel starts at the left edge of the eighth bar from the right, and the ring is
    /// centred in the room between.
    private func stage(_ size: CGSize) -> some View {
        let w = size.width
        let n = max(1, model.stripMonths.count)
        let slot = w / CGFloat(n)
        let inset = (slot - min(46, slot - 12)) / 2
        let panelX = n >= 9 ? CGFloat(n - 8) * slot + inset : w * 0.56
        let left = panelX - inset
        // A breath under the strip; under the ring, room for the way back, the pill and the
        // lines beneath it (`under`), no more.
        let say: CGFloat = 22, under: CGFloat = 92
        // The ring's highest reach (a badge's top) stands level with the panel title's top.
        let room = size.height - say - 6
        let ring = Rings.size(width: left - 40, room: room, under: under, air: Rings.bankingAir)

        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: say)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    SpendingRings(model: model, size: ring, namespace: ns,
                                  onDrillIn: drillIn, onDrillOut: drillOut, onMerchant: editMerchant)
                        .padding(.top, Rings.top(ring: ring, air: Rings.bankingAir))
                    self.under.padding(.top, 4)
                }
                // Zoomed, the way back out runs along the panel title's line, above the ring.
                .overlay(alignment: .topLeading) { backBar.frame(height: Rings.backRow) }
                .frame(width: left)
                .padding(.leading, inset)
                // Above the panel, so a slice's tooltip floats over the lists, not under them.
                .zIndex(1)
                Group {
                    if rendering { panel } else { ScrollView { panel }.scrollIndicators(.never) }
                }
                .frame(width: max(320, w - panelX - inset), height: max(0, size.height - say - 6), alignment: .top)
            }
        }
    }

    private var panel: some View {
        FocusPanel(model: model, onEdit: { model.editing = $0 }, onEditLine: editLine, onEditMerchant: editMerchant,
                   onSeeAll: { l in withAnimation(.easeOut(duration: 0.18)) { model.list = l } },
                   onDrill: drillIn)
    }

    @ViewBuilder private var backBar: some View {
        if let d = model.drill, model.category(d) != nil {
            HStack(spacing: 10) {
                Button(action: drillOut) { MiniRing(items: model.ringCategories, lit: d) }
                    .buttonStyle(.plain).help("Back to all spending")
                Button(action: drillOut) {
                    Text(model.income ? "← All income" : "← All spending").font(HouseFont.jost(13)).foregroundStyle(ink.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(ink.pill, in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(model.editing == nil && model.editingLine == nil && model.list == nil ? .cancelAction : nil)
                Spacer()
            }
            .font(HouseFont.jost(14))
        }
    }

    /// Under the ring: the lens pill, what's left out.
    private var under: some View {
        VStack(spacing: 10) {
            Seg(options: SpendingScreenModel.Lens.allCases, selected: model.lens, help: nil) { v in
                withAnimation(.easeOut(duration: 0.3)) {
                    model.lens = v
                    model.drill = nil   // switching what counts always lands on the whole ring
                }
            } label: { v in
                HStack(spacing: 7) {
                    switch v {
                    case .everyday: EmojiDisc(icon: "steaming_bowl", tint: v.discTint(ink), size: 26); Text("Spending")
                    case .all:      EmojiDisc(icon: "house", tint: v.discTint(ink), size: 26); Text("Total")
                    case .income:   EmojiDisc(icon: "briefcase", tint: v.discTint(ink), size: 26); Text("Income")
                    }
                }
                .font(HouseFont.jost(13))
            }
            HStack(spacing: 4) {
                if model.everyday {
                    Text("fixed costs excluded \(Fmt.usd(model.setAside)) ·")
                        .help(store.categories.categories.filter(\.fixed).map(\.name).joined(separator: ", ") + " — counted under Total")
                }
                Emoji(name: "left-right_arrow", size: 15)
                Text("transfers excluded \(Fmt.usd(model.transfersLeftOut))")
            }
            .font(HouseFont.jost(12)).foregroundStyle(ink.faint)
            if model.drill == nil {
                Text(model.income ? "inner: kinds · outer: payers" : "inner: categories · outer: merchants")
                    .font(HouseFont.jost(12)).foregroundStyle(ink.faint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Drill

    private func drillIn(_ id: String) {
        guard model.drill == nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            model.drill = id
            model.focus = id
        }
    }

    private func drillOut() {
        guard model.drill != nil else { return }
        withAnimation(.easeOut(duration: 0.28)) { model.drill = nil }
    }

    // MARK: - Floating: the drawers

    private func editLine(_ id: String) {
        model.editingMerchant = false
        model.editingOpensForm = false
        model.editingLine = id
    }

    private func editMerchant(_ name: String, in categoryId: String) {
        guard let t = model.newestLine(merchant: name, in: categoryId) else { return }
        model.editingMerchant = true
        model.editingOpensForm = false
        model.editingLine = t.id
    }

    @ViewBuilder private var editor: some View {
        if let id = model.editing {
            CategoryEditor(store: store, categoryId: id, scrolls: !rendering) { model.editing = nil }
                .id(id)
                .transition(.move(edge: .trailing))
        } else if let id = model.editingLine {
            TransactionEditor(store: store, transactionId: id, rendering: rendering,
                              startsAllLikeThis: model.editingMerchant, startsEditing: model.editingOpensForm,
                              onOpen: { other in
                                  model.editingMerchant = false
                                  model.editingOpensForm = true
                                  model.editingLine = other
                              }) { model.editingLine = nil }
                .id(id)
                .transition(.move(edge: .trailing))
        }
    }
}

/// A click-catcher behind a drawer or window: dims the screen, and a click on it closes
/// what floats above without saving.
struct Scrim: View {
    let action: () -> Void
    @Environment(\.ink) private var ink
    var body: some View {
        ink.scrim
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .transition(.opacity)
    }
}

/// The mockup's `.seg`: a pill track with the chosen option lifted onto `active`.
struct Seg<T: Hashable, L: View>: View {
    let options: [T]
    let selected: T
    let help: String?
    let pick: (T) -> Void
    @ViewBuilder let label: (T) -> L
    @Environment(\.ink) private var ink

    init(options: [T], selected: T, help: String?, pick: @escaping (T) -> Void, @ViewBuilder label: @escaping (T) -> L) {
        self.options = options; self.selected = selected; self.help = help; self.pick = pick; self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                let on = o == selected
                Button { pick(o) } label: {
                    label(o)
                        .foregroundStyle(on ? ink.text : ink.muted)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(on ? ink.active : .clear, in: Capsule())
                        .shadow(color: on ? .black.opacity(0.12) : .clear, radius: 1.5, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(ink.pill, in: Capsule())
        .help(help ?? "")
    }
}
