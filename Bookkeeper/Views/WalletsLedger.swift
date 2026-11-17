import SwiftUI
import BookkeeperCore

/// **Wallet modules**, in the sheets' language.
///
/// Each wallet is a self-contained module: a banner carrying its name, its total beneath,
/// the caption line, then holdings grouped by network with a letter tab down the side.
/// Modules are laid out across the width — roughly three at a full window — and can be
/// picked up and rearranged, so wallets can be clumped however they're actually thought
/// about rather than in the order they were added.
struct WalletsLedger: View {
    let store: PortfolioStore
    /// Optional hook for a caller that wants to know. The screen opens the token itself,
    /// so it doesn't depend on being given one.
    var onSelect: (Token) -> Void = { _ in }
    /// One wallet's module alone, no board — Crypto 2's wallet panel. Nil = every wallet.
    var only: String? = nil

    @State private var editingCard: String?      // nickname whose name/colour bubble is open
    @State private var editingRows: Set<String> = []   // wallets in row-edit mode
    @State private var draft = ""
    @State private var didCenter = false
    @State private var addingWallet = false

    /// Banner colours a wallet can be given. The default cycles so two modules on screen
    /// read apart without anyone choosing anything. Owned by the store, so the portfolio
    /// rings default a wallet exactly the way its module does.
    static let palette = PortfolioStore.walletPalette

    private func bannerColor(_ wallet: Wallet) -> Color {
        Color(hex: store.walletTintHex(wallet.nickname))
    }

    // MARK: Banner — a bubble for the name and colour

    private func banner(_ wallet: Wallet, color: Color) -> some View {
        LedgerBanner(text: wallet.nickname.uppercased(), fill: color, size: 19)
            .contentShape(Rectangle())
            .onTapGesture {
                draft = wallet.nickname
                editingCard = wallet.nickname
            }
            .help("Click to rename or recolour")
            // A popover closes itself the moment anything else is clicked, including
            // empty canvas — the inline panel used to sit there until another wallet
            // was opened.
            .popover(isPresented: Binding(
                get: { editingCard == wallet.nickname },
                set: { if !$0 && editingCard == wallet.nickname { commitRename(from: wallet.nickname) } }
            ), arrowEdge: .top) {
                bubble(wallet)
            }
    }

    private func bubble(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NAME").font(Ledger.mono(9)).tracking(1.4).foregroundStyle(Palette.ink.opacity(0.5))
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Ledger.mono(15)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Look.shared.ink.pill)
                .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
                .onSubmit { commitRename(from: wallet.nickname) }

            Text("COLOUR").font(Ledger.mono(9)).tracking(1.4).foregroundStyle(Palette.ink.opacity(0.5))
            // Six across rather than four: the list went from eight colours to
            // twenty-four, and at four wide the swatches ran off the bottom of the
            // popover instead of reading as one block you can scan.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 5), count: 6),
                      spacing: 5) {
                ForEach(PortfolioStore.walletColors, id: \.hex) { colour in
                    let chosen = store.walletColorHex(wallet.nickname) == colour.hex
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: colour.hex))
                        .frame(width: 22, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Palette.ink.opacity(chosen ? 0.9 : 0), lineWidth: 1.5))
                        // Each colour is a real one with a real name — worth saying so
                        // for anyone who hovers.
                        .help(colour.name)
                        .onTapGesture { store.setWalletColor(wallet.nickname, hex: colour.hex) }
                }
            }

            Divider().overlay(Palette.ink.opacity(0.15))
            Button {
                editingCard = nil
                Task { await store.removeWallet(nickname: wallet.nickname) }
            } label: {
                Label("Remove wallet", systemImage: "trash")
                    .font(Ledger.mono(11)).foregroundStyle(Theme.negative)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 190)
        .background(Look.shared.ink.card)
    }

    private func commitRename(from old: String) {
        let new = draft.trimmingCharacters(in: .whitespaces)
        editingCard = nil
        guard !new.isEmpty, new != old else { return }
        Task { await store.renameWallet(from: old, to: new) }
    }

    // MARK: A module

    /// The network a row belongs to, as stored. Editing has to name it, or the same
    /// symbol held on two chains gets edited through whichever one was found first.
    static func network(of token: Token) -> String {
        token.manualNetwork ?? token.chain?.displayName ?? ""
    }


    private func module(_ wallet: Wallet, index: Int) -> some View {
        let rows = store.rows(forWallet: wallet.id)
        let total = rows.reduce(Decimal(0)) { $0 + ($1.usdValue ?? 0) }
        let color = bannerColor(wallet)

        let editing = editingRows.contains(wallet.nickname)

        return VStack(spacing: 12) {
            banner(wallet, color: color)
                .overlay(alignment: .trailing) {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if editing { editingRows.remove(wallet.nickname) }
                            else { editingRows.insert(wallet.nickname) }
                        }
                    } label: {
                        Image(systemName: editing ? "checkmark" : "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ledger.ink(on: color))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.black.opacity(editing ? 0.35 : 0.18)))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 7)
                    .help(editing ? "Done editing" : "Edit amounts and remove tokens")
                }

            Text(Money.usd(total))
                .font(Ledger.mono(26)).foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)

            LedgerHeader()

            VStack(spacing: 14) {
                ForEach(Array(store.groupedRows(forWallet: wallet.id).enumerated()), id: \.offset) { _, g in
                    LedgerNetworkGroup(
                        network: g.network, rows: g.rows, onSelect: select,
                        editing: editing,
                        isEditable: { store.isEditable(walletId: wallet.id,
                                                       symbol: $0.token.symbol,
                                                       network: Self.network(of: $0.token)) },
                        onAmount: { r, v in
                            Task { await store.setManualAmount(walletId: wallet.id,
                                                               symbol: r.token.symbol, amount: v,
                                                               network: Self.network(of: r.token)) }
                        },
                        networks: { r in
                            // Every hand-entered token, not just the ones held by id.
                            // A contract told us where the token was FOUND; it does not
                            // tell us which chain these particular coins are sitting on,
                            // and only the holder knows that. A scanned balance still
                            // can't move — the chain reported it, so the chain is right.
                            let here = Self.network(of: r.token)
                            guard store.manualHolding(walletId: wallet.id,
                                                      symbol: r.token.symbol,
                                                      network: here) != nil else { return [] }
                            var names = TokenLocator.chains.map(\.name)
                            if !here.isEmpty, !names.contains(here) { names.insert(here, at: 0) }
                            return names
                        },
                        currentNetwork: { Self.network(of: $0.token) },
                        onNetwork: { r, name in
                            Task {
                                await store.setManualNetwork(walletId: wallet.id,
                                                             symbol: r.token.symbol,
                                                             from: Self.network(of: r.token),
                                                             to: name)
                            }
                        },
                        onRemove: { r in
                            // A hand-entered token is deleted outright; a scanned balance
                            // can only be hidden, since the chain will report it again.
                            let net = Self.network(of: r.token)
                            if store.isEditable(walletId: wallet.id, symbol: r.token.symbol,
                                                network: net) {
                                Task { await store.removeManualToken(walletId: wallet.id,
                                                                     symbol: r.token.symbol,
                                                                     network: net) }
                            } else {
                                store.hideToken(r.token)
                            }
                        })
                }
            }

            AddTokenForm(store: store, fixedWallet: wallet.id)
                .padding(.top, 2)
        }
        .frame(width: LedgerCol.tableWidth)
        .padding(10)
        .background(Palette.canvas.opacity(0.001))   // a drag target across the gaps
    }

    // MARK: Add a wallet

    /// Adding a wallet is a command, not a thing on the board — so it sits in the
    /// corner and stays put through any pan or zoom, rather than being a tile that
    /// drifts off with everything else.
    private var addButton: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { addingWallet.toggle() } } label: {
            HStack(spacing: 10) {
                Text(addingWallet ? "×" : "+")
                    .font(Ledger.mono(22)).foregroundStyle(Palette.canvas)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.ink))
                Text("ADD WALLET").font(Ledger.mono(11)).tracking(1.6)
                    .foregroundStyle(Palette.ink)
            }
            .padding(.leading, 5).padding(.trailing, 14).padding(.vertical, 5)
            .background(Look.shared.ink.pill)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addPanel: some View {
        VStack(spacing: 0) {
            addButton
            if addingWallet {
                AddWalletForm(store: store) { addingWallet = false }
                    .frame(width: LedgerCol.tableWidth)
                    .padding(14)
                    .background(Look.shared.ink.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - The canvas

    /// Modules live at free positions rather than in a grid. A grid decides where things
    /// go and re-flows them when one changes size, which is what made two neighbouring
    /// modules sit at different heights and refuse to be aligned by hand.
    ///
    /// Positions are held in state and written to disk only when a drag ends. Reading
    /// them from the secret file inside `body` meant a file read per module per frame
    /// while dragging, which is most of why it stuttered.
    @State private var positions: [String: CGPoint] = [:]
    /// Measured module sizes. Centring has to know what the board actually occupies,
    /// and a module's height depends on how many tokens and networks it holds, so it is
    /// measured rather than estimated.
    @State private var sizes: [String: CGSize] = [:]
    @State private var dragging: String?
    @State private var dragTranslation: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    @State private var pinch: PinchStart?

    /// What the field looked like when a pinch began. Zooming has to be computed from
    /// the state at the start of the gesture, not accumulated frame by frame, or the
    /// rounding drifts and the point under the cursor slowly slides away.
    private struct PinchStart {
        let zoom: CGFloat
        let pan: CGSize
        let point: CGPoint
    }

    /// A fixed reference frame for drag measurement.
    private static let space = "wallet-canvas"

    /// 100% is the close view; half of it is as far out as the board needs to go.
    private static let minZoom: CGFloat = 0.5
    private static let maxZoom: CGFloat = 1.0
    /// A sanity guard against a runaway coordinate, NOT a usable edge. At -400 it
    /// behaved as an invisible wall: modules dragged past the top-left were pulled back
    /// to the same clamped point and stacked on top of each other. The field is free
    /// within this; the numbers only exist so a glitch can't strand a module again.
    private static let bounds: ClosedRange<Double> = -40000...40000

    private static func defaultPosition(_ index: Int) -> CGPoint {
        let perRow = 3
        return CGPoint(x: Double(index % perRow) * (LedgerCol.tableWidth + 40) + 20,
                       y: Double(index / perRow) * 420 + 20)
    }

    private static func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.lowerBound), bounds.upperBound),
                y: min(max(p.y, bounds.lowerBound), bounds.upperBound))
    }

    /// Read stored positions once. A stored value outside the field is treated as lost
    /// and returned to its default slot rather than left unreachable.
    private func loadPositions() {
        var out: [String: CGPoint] = [:]
        for (i, w) in store.orderedWallets.enumerated() {
            if let p = store.walletPosition(w.nickname) {
                let pt = CGPoint(x: p.x, y: p.y)
                out[w.nickname] = Self.bounds.contains(p.x) && Self.bounds.contains(p.y)
                    ? pt : Self.defaultPosition(i)
            } else {
                out[w.nickname] = Self.defaultPosition(i)
            }
        }
        positions = out
    }

    private func origin(_ wallet: Wallet, index: Int) -> CGPoint {
        positions[wallet.nickname] ?? Self.defaultPosition(index)
    }

    /// The rectangle every module fits inside, in board coordinates.
    private var boardBounds: CGRect? {
        var union: CGRect?
        for (i, w) in store.orderedWallets.enumerated() {
            let size = sizes[w.nickname] ?? CGSize(width: LedgerCol.tableWidth, height: 320)
            let r = CGRect(origin: origin(w, index: i), size: size)
            union = union.map { $0.union(r) } ?? r
        }
        return union
    }

    /// Bring the camera to the whole board: fit it, then centre it. Moves the view, not
    /// the modules — an arrangement is the user's and shouldn't be rearranged to be seen.
    private func center(in viewport: CGSize) {
        guard let b = boardBounds, b.width > 0, b.height > 0 else { return }
        let margin: CGFloat = 60
        let fit = min((viewport.width - margin * 2) / b.width,
                      (viewport.height - margin * 2) / b.height)
        let z = min(Self.maxZoom, max(Self.minZoom, fit))
        zoom = z
        pan = CGSize(width: viewport.width / 2 - b.midX * z,
                     height: viewport.height / 2 - b.midY * z)
        panAnchor = pan
    }

    /// Zoom about a point, keeping whatever sits under that point exactly where it is.
    ///
    /// The content is scaled from the top-left, so scaling alone pulls everything toward
    /// the origin — which is why zooming used to walk the board up and to the left
    /// instead of moving in on what you were looking at. Counter-panning by the amount
    /// the focus point would have travelled pins it in place.
    private func setZoom(_ target: CGFloat, about point: CGPoint,
                         from startZoom: CGFloat, startPan: CGSize) {
        let next = min(Self.maxZoom, max(Self.minZoom, target))
        let k = next / startZoom
        pan = CGSize(width: point.x - (point.x - startPan.width) * k,
                     height: point.y - (point.y - startPan.height) * k)
        zoom = next
    }

    /// A scroll over the canvas.
    ///
    /// A wheel mouse has no pinch, so on a desktop the wheel IS the zoom — about the
    /// cursor, exactly as the pinch is. A trackpad does have a pinch, and its two-finger
    /// scroll means "move the paper" everywhere else on the Mac, so there it pans. ⌘ or ⌥
    /// forces zoom either way, which is the conventional escape hatch and the only zoom a
    /// Magic Mouse (precise deltas, no pinch) can reach.
    private func handleScroll(_ s: ScrollWheelCatcher.Scroll) {
        if s.isPrecise, !s.zoomModifier {
            pan = CGSize(width: pan.width + s.deltaX, height: pan.height + s.deltaY)
            panAnchor = pan
            return
        }
        // Multiplicative, so a notch is the same proportion of the current zoom at
        // either end of the range — additive steps crawl when zoomed out and leap when
        // zoomed in. A wheel notch reports about 1 line; a precise device reports points,
        // which are far larger numbers and need scaling down to match.
        let step = s.isPrecise ? s.deltaY * 0.01 : s.deltaY
        guard step != 0 else { return }
        setZoom(zoom * pow(1.12, step), about: s.location, from: zoom, startPan: pan)
        panAnchor = pan
    }

    private func zoomBar(in size: CGSize) -> some View {
        // The buttons have no cursor to work from, so they zoom about the middle of
        // the viewport — the nearest thing to "what you are looking at".
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    setZoom(zoom - 0.15, about: centre, from: zoom, startPan: pan)
                }
                panAnchor = pan
            } label: {
                Text("−").font(Ledger.mono(15)).foregroundStyle(Palette.ink).frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            Text("\(Int(zoom * 100))%").font(Ledger.mono(11))
                .foregroundStyle(Palette.ink.opacity(0.75)).frame(width: 46)
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    setZoom(zoom + 0.15, about: centre, from: zoom, startPan: pan)
                }
                panAnchor = pan
            } label: {
                Text("+").font(Ledger.mono(15)).foregroundStyle(Palette.ink).frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            Button { withAnimation(.easeOut(duration: 0.28)) { center(in: size) } } label: {
                Text("CENTER").font(Ledger.mono(10)).tracking(1.2)
                    .foregroundStyle(Palette.ink.opacity(0.7))
                    .padding(.horizontal, 8).frame(height: 24)
            }
            .buttonStyle(.plain)
            .help("Bring every wallet into view")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Look.shared.ink.pill)
        .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
        .overlay(RoundedRectangle(cornerRadius: Ledger.radius)
            .strokeBorder(Palette.ink.opacity(0.12), lineWidth: 1))
    }

    /// The field itself. The pan gesture lives HERE, behind the modules — on the whole
    /// view it also fired while dragging a module, so the module moved and the field
    /// moved under it at the same time. That doubling is what shook, and then threw the
    /// module off the screen.
    private var field: some View {
        Look.shared.ink.hover   // a shade off the ground, so the board reads as a surface
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { g in
                        pan = CGSize(width: panAnchor.width + g.translation.width,
                                     height: panAnchor.height + g.translation.height)
                    }
                    .onEnded { _ in panAnchor = pan }
            )
    }

    /// The drag is measured in a NAMED coordinate space that the drag itself never
    /// moves. Measured in the default space, each frame's translation was read against a
    /// frame the previous frame had already shifted — the value fed back into itself and
    /// ran away exponentially, which is how a module ended up saved at x=2.7e11.
    private func dragGesture(_ wallet: Wallet, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if dragging != wallet.nickname { dragging = wallet.nickname }
                // Translation arrives in screen points; the field is scaled, so divide
                // or the module slides out from under the cursor when zoomed.
                dragTranslation = CGSize(width: g.translation.width / zoom,
                                         height: g.translation.height / zoom)
            }
            .onEnded { g in
                let base = origin(wallet, index: index)
                let moved = Self.clamp(CGPoint(x: base.x + g.translation.width / zoom,
                                               y: base.y + g.translation.height / zoom))
                positions[wallet.nickname] = moved
                store.setWalletPosition(wallet.nickname, x: moved.x, y: moved.y)
                dragging = nil
                dragTranslation = .zero
            }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(store.orderedWallets.enumerated()), id: \.element.id) { i, w in
                let held = dragging == w.nickname
                let base = origin(w, index: i)
                let live = held ? dragTranslation : .zero

                module(w, index: i)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ModuleSizeKey.self,
                                               value: [w.nickname: g.size])
                    })
                    // Picked-up state: lifts, brightens, and casts a shadow, so it's
                    // obvious which module is in hand.
                    .scaleEffect(held ? 1.03 : 1, anchor: .center)
                    .shadow(color: Look.shared.ink.shadow.opacity(held ? 1 : 0), radius: held ? 22 : 0, y: held ? 10 : 0)
                    .overlay(RoundedRectangle(cornerRadius: Ledger.radius + 4)
                        .strokeBorder(Palette.ink.opacity(held ? 0.35 : 0), lineWidth: 1))
                    .offset(x: base.x + live.width, y: base.y + live.height)
                    .zIndex(held ? 100 : 0)
                    .animation(.easeOut(duration: 0.12), value: held)
                    .gesture(dragGesture(w, index: i))
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(ModuleSizeKey.self) { sizes = $0 }
    }

    var content: some View {
        canvas
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(pan)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @State private var selectedToken: Token?

    /// Tapping a row opens that token here. This used to call `onSelect` only, which the
    /// window passed an empty closure for — so after the design switcher went, tapping a
    /// row did nothing at all.
    private func select(_ token: Token) {
        selectedToken = token
        onSelect(token)
    }

    var body: some View {
        if let only, let i = store.orderedWallets.firstIndex(where: { $0.id == only }) {
            module(store.orderedWallets[i], index: i)
                .sheet(item: $selectedToken) { token in
                    TokenDetailView(token: token, store: store) { selectedToken = nil }
                }
        } else if SnapshotRenderer.isRendering {
            canvas.padding(20)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    field                  // pan target, behind everything
                    content
                }
                .coordinateSpace(name: Self.space)
                // Behind the content and hit-test-transparent, so it reads scrolls
                // without taking a single click away from the modules.
                .background(ScrollWheelCatcher(onScroll: handleScroll))
                .gesture(
                    MagnifyGesture()
                        .onChanged { g in
                            // Pinch centre, in this view's own space — zoom moves in on
                            // where the cursor is rather than on the origin.
                            let start = pinch ?? PinchStart(zoom: zoom, pan: pan,
                                                            point: g.startLocation)
                            if pinch == nil { pinch = start }
                            setZoom(start.zoom * g.magnification, about: start.point,
                                    from: start.zoom, startPan: start.pan)
                        }
                        .onEnded { _ in
                            pinch = nil
                            panAnchor = pan
                        }
                )
                .overlay(alignment: .topTrailing) { addPanel.padding(16) }
                .overlay(alignment: .bottomTrailing) { zoomBar(in: geo.size).padding(16) }
                .clipped()
                // Open on the whole board. Modules keep the positions they were left in;
                // only the camera moves. Waits for the first measurement, since the
                // bounding box isn't known until the modules have been laid out once.
                .onChange(of: sizes.count) { _, count in
                    guard !didCenter, count >= store.orderedWallets.count, count > 0 else { return }
                    didCenter = true
                    center(in: geo.size)
                }
            }
            .onAppear { loadPositions() }
            .overlay {
                if let token = selectedToken {
                    ZStack {
                        Theme.ground.opacity(0.78).ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { selectedToken = nil }
                        TokenDetailView(token: token, store: store) { selectedToken = nil }
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Look.shared.ink.shadow, radius: 30, y: 10)
                    }
                }
            }
            // A wallet added, removed or renamed needs a slot; existing ones keep theirs.
            .onChange(of: store.orderedWallets.map(\.nickname)) { _, _ in loadPositions() }
        }
    }
}

/// The add-wallet module: a nickname, and an address when there is one to scan.
struct AddWalletForm: View {
    let store: PortfolioStore
    var done: () -> Void

    @State private var nickname = ""
    @State private var working = false
    @FocusState private var nameFocused: Bool

    /// A wallet is a name and nothing more — its tokens are added to it afterwards.
    private var canAdd: Bool {
        !nickname.trimmingCharacters(in: .whitespaces).isEmpty && !working
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(Ledger.mono(12))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(Look.shared.ink.pill)
            .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
    }

    var body: some View {
        VStack(spacing: 8) {
            LedgerBanner(text: "NEW WALLET", fill: Ledger.wash(0.29), size: 15)
            field("nickname", $nickname)
                .focused($nameFocused)
            HStack(spacing: 8) {
                Button { done() } label: {
                    Text("Cancel").font(Ledger.mono(12)).foregroundStyle(Palette.ink.opacity(0.6))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    working = true
                    let nick = nickname.trimmingCharacters(in: .whitespaces)
                    Task {
                        await store.addWallet(nickname: nick)
                        working = false
                        done()
                    }
                } label: {
                    Text(working ? "Adding…" : "Add").font(Ledger.mono(12))
                        .foregroundStyle(canAdd ? Palette.canvas : Palette.ink.opacity(0.4))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(canAdd ? Palette.ink : Look.shared.ink.track)
                        .clipShape(RoundedRectangle(cornerRadius: Ledger.radius))
                }
                .buttonStyle(.plain).disabled(!canAdd)
            }
        }
        // Same reasoning as the add-token form: opening it is the intent, so the cursor
        // is already where the first word goes.
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }
}


/// Collects each module's rendered size so the camera can be fitted to the board.
private struct ModuleSizeKey: PreferenceKey {
    static let defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}
