import SwiftUI
import BookkeeperCore

/// The line-edit drawer, titled with the line's own name — from the right, Empower's spot-by-spot model ported from
/// the mockup's `openEditor` / `renderEditor`: a name, what the line counts as (Spending ·
/// Income · Internal transfer), its category or kind of income, then **Just this one** or
/// **All like this** — every line whose bank text holds the cleaned core as whole words
/// (`MerchantCore.core`, word-aware per `MerchantRule.contains`), each with a tick, plus
/// the near-misses (`MR KALEIDOSCOPE` under `MR KALE`) shown unticked so it's plain why
/// they're left out. Save goes through `SpendingStore.apply(edit:to:scope:)`.
struct TransactionEditor: View {
    let store: SpendingStore
    let transactionId: String
    /// True for `--snapshot`: no ScrollView or AppKit field, which `ImageRenderer` can't draw.
    var rendering = false
    var onClose: () -> Void
    /// Opens another line in this drawer — a month picked on the history chart.
    var onOpen: ((String) -> Void)? = nil

    @Environment(\.ink) private var ink

    private enum Scope { case one, all }

    private let preview: EditPreview?
    /// Newest first, worked out once — the pattern doesn't change while the drawer is open.
    private let likeThis: [BankTransaction]
    /// Lines holding the core's letters but not as whole words: never caught, shown off.
    private let decoys: [BankTransaction]

    @State private var name: String
    @State private var kind: TransactionKind
    @State private var categoryId: String
    @State private var scope: Scope
    @State private var unticked: Set<String> = []
    /// Opens read-only — what the line is, its history — and becomes a form on **Edit**.
    @State private var editing = false
    /// How the line shows now. The name box opens on the cleaned suggestion instead, so a
    /// raw bank name (`PIER 6 OYSTER BAR BROOKLYN`) already counts as a change to save.
    private let start: (name: String, kind: TransactionKind, categoryId: String)
    private let suggested: String

    init(store: SpendingStore, transactionId: String, rendering: Bool = false,
         startsAllLikeThis: Bool = false, startsEditing: Bool = false,
         onOpen: ((String) -> Void)? = nil, onClose: @escaping () -> Void) {
        self.store = store; self.transactionId = transactionId
        self.rendering = rendering; self.onClose = onClose; self.onOpen = onOpen
        _editing = State(initialValue: startsEditing)
        let p = store.editPreview(transactionId)
        preview = p
        let like = (p?.likeThis ?? []).reversed() as [BankTransaction]
        likeThis = like
        if let core = p?.core, !core.isEmpty {
            let caught = Set(like.map(\.id))
            decoys = store.transactions.reversed().filter {
                !caught.contains($0.id) && $0.rawDescription.uppercased().contains(core)
            }
        } else {
            decoys = []
        }
        let t = p?.transaction
        _name = State(initialValue: p?.suggestedName ?? "")
        _kind = State(initialValue: t?.effectiveKind ?? .spend)
        _categoryId = State(initialValue: t?.effectiveCategoryId ?? CategoryBook.fallbackId)
        _scope = State(initialValue: startsAllLikeThis ? .all : .one)
        start = (t?.displayName ?? "", t?.effectiveKind ?? .spend, t?.effectiveCategoryId ?? CategoryBook.fallbackId)
        suggested = p?.suggestedName ?? ""
    }

    /// Something differs from how the line opened — only then is there anything to apply,
    /// so only then are "Just this one / All like this" and Save shown.
    private var changed: Bool {
        name.trimmingCharacters(in: .whitespaces) != start.name || kind != start.kind
            || (kind != .transfer && categoryId != start.categoryId)
    }

    var body: some View {
        Group {
            if rendering { form } else { ScrollView { form }.scrollIndicators(.never) }
        }
        .frame(width: 460)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ink.card)
        .overlay(alignment: .leading) { Rectangle().fill(ink.rule).frame(width: 1) }
        .shadow(color: ink.shadow, radius: 24, y: 8)
    }

    @ViewBuilder private var form: some View {
        if let p = preview {
            content(p)
        } else {
            VStack { Text("This line is gone.").font(HouseFont.jost(14)).foregroundStyle(ink.muted) }
                .padding(28)
        }
    }

    private func content(_ p: EditPreview) -> some View {
        let t = p.transaction
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    label("\(editing ? "Edit · " : "")\(Fmt.dayShort(t.date)) \(t.date.year) · \(Fmt.signedCents(t.amount.double))")
                    // Whole, however long: the name wraps rather than trails off.
                    Text(t.displayName).font(HouseFont.fraunces(22)).foregroundStyle(ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // The bank's own text, only when it says something the name doesn't.
                    if Self.squash(t.rawDescription) != Self.squash(t.displayName) {
                        Text("from the bank: \(t.rawDescription)").font(HouseFont.raw(12)).foregroundStyle(ink.faint)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain)
            }

            MerchantHistory(store: store, line: t, onOpen: onOpen).padding(.top, 20)

            if editing { form(p) } else { summary }
        }
        .padding(.horizontal, 28).padding(.top, 28).padding(.bottom, 30)
    }

    /// Upper-cased letters and digits only — so `ZELLE PAYMENT TO JANE` and
    /// `Zelle payment to Jane` read as the same words.
    private static func squash(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Read-only: how the line counts now, and the way into the form.
    private var summary: some View {
        let cat = kind == .transfer ? nil : store.categories.category(categoryId)
        let k = Self.kinds.first { $0.0 == kind }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                field("Counts as") {
                    HStack(spacing: 7) {
                        Emoji(name: k?.2 ?? "receipt", size: 20)
                        Text(k?.1 ?? "").font(HouseFont.jost(15)).foregroundStyle(ink.text)
                    }
                }
                if let cat {
                    field(kind == .income ? "Kind of income" : "Category") {
                        HStack(spacing: 7) {
                            EmojiDisc(cat, size: 28)
                            Text(cat.name).font(HouseFont.jost(15)).foregroundStyle(ink.text)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { editing = true } label: {
                    HStack(spacing: 6) {
                        Emoji(name: "pencil", size: 16)
                        Text("Edit").font(HouseFont.jost(13.5, 600))
                    }
                    .foregroundStyle(ink.ground)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Button(action: onClose) {
                    Text("Close").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 28)
        }
    }

    /// The form: name, counts as, category — then, once something has changed, which
    /// lines it applies to, and Save.
    private func form(_ p: EditPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            field("Name") {
                Group {
                    if rendering { Text(name).frame(maxWidth: .infinity, alignment: .leading) }
                    else { TextField("", text: $name).textFieldStyle(.plain) }
                }
                .font(HouseFont.jost(16)).foregroundStyle(ink.text)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
            }

            field("Counts as") {
                HStack(spacing: 6) {
                    ForEach(Self.kinds, id: \.0) { k, title, icon in
                        choice(on: kind == k, centred: true) { pick(k) } label: {
                            Emoji(name: icon, size: 18)
                            Text(title).font(HouseFont.jost(12.5))
                        }
                    }
                }
                Text(help).font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                    .lineSpacing(3).padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if kind != .transfer {
                field(kind == .income ? "Kind of income" : "Category") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(kind == .income ? store.categories.incomeCategories : store.categories.categories) { c in
                            choice(on: categoryId == c.id, centred: false) { categoryId = c.id } label: {
                                EmojiDisc(c, size: 26)
                                Text(c.name).font(HouseFont.jost(12.5)).lineLimit(1)
                            }
                        }
                    }
                }
            }

            if changed {
                field("Change") {
                    VStack(spacing: 8) {
                        scopeOption(.one) { Text("Just this one") }
                        // Only when the pattern catches this line itself — else it would
                        // save a rule that changes nothing.
                        if canAll {
                            scopeOption(.all) {
                                Text(allLikeThisLabel(p.core))
                            }
                        }
                    }
                    if scope == .all && canAll { matchList(p.core) }
                }
            }

            HStack(spacing: 10) {
                if changed {
                    Button(action: save) {
                        Text("Save").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                Button(action: cancelEdit) {
                    Text("Cancel").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 24)
        }
    }

    /// The pattern catches this line itself, so "All like this" means something.
    private var canAll: Bool { likeThis.contains { $0.id == transactionId } }

    /// Back to the read-only view, with nothing kept.
    private func cancelEdit() {
        name = suggested; kind = start.kind; categoryId = start.categoryId
        unticked = []
        editing = false
    }

    // MARK: - Counts as

    private static let kinds: [(TransactionKind, String, String)] = [
        (.spend, "Spending", "receipt"), (.income, "Income", "money_with_wings"),
        (.transfer, "Internal transfer", "left-right_arrow"),
    ]

    private var help: String {
        switch kind {
        case .transfer: return "Money moving between your own accounts — a card payment, a move to savings. Never counted as spending or income."
        case .income: return "Money in — pay, or a refund you want counted as income."
        case .spend: return "Counts toward the ring, in the category below."
        }
    }

    /// A kind change keeps the category only if it belongs to the new kind's list.
    private func pick(_ k: TransactionKind) {
        kind = k
        // Back to the kind it opened as: back to its own category, not a fallback.
        if k == start.kind { categoryId = start.categoryId; return }
        let book = store.categories
        if k == .income, !book.incomeCategories.contains(where: { $0.id == categoryId }) {
            categoryId = CategoryBook.incomeFallbackId
        }
        if k == .spend, !book.categories.contains(where: { $0.id == categoryId }) {
            categoryId = CategoryBook.fallbackId
        }
    }

    // MARK: - Change: just this one / all like this

    private func allLikeThisLabel(_ core: String) -> AttributedString {
        var head = AttributedString("All \(likeThis.count) \(likeThis.count == 1 ? "entry" : "entries") with ")
        var pat = AttributedString("\u{2009}\(core)\u{2009}")
        pat.font = HouseFont.raw(12)
        pat.backgroundColor = ink.pill
        // A payment app's rule keeps to one way: say which.
        let way = preview?.direction.map { $0 == .moneyIn ? ", money in" : ", money out" } ?? ""
        let tail = AttributedString("\(way) — and future imports")
        head.append(pat); head.append(tail)
        return head
    }

    private func scopeOption<L: View>(_ s: Scope, @ViewBuilder label: () -> L) -> some View {
        let on = scope == s
        return Button { scope = s } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().strokeBorder(on ? ink.text : ink.faint, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().fill(on ? ink.text : .clear).frame(width: 6, height: 6))
                    .padding(.top, 2)
                label().font(HouseFont.jost(13.5)).foregroundStyle(ink.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? ink.text : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func matchList(_ core: String) -> some View {
        Text(decoys.isEmpty ? "Untick anything that doesn't belong."
                            : "Untick anything that doesn't belong. Greyed entries only share letters — they stay as they are.")
            .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
        let rows = VStack(spacing: 0) {
            ForEach(likeThis, id: \.id) { x in matchRow(x, core: core, decoy: false) }
            ForEach(decoys, id: \.id) { x in matchRow(x, core: core, decoy: true) }
        }
        Group {
            if rendering { rows.frame(maxHeight: 230, alignment: .top).clipped() }
            else { ScrollView { rows }.frame(maxHeight: 230) }
        }
        .padding(.top, 10)
    }

    private func matchRow(_ x: BankTransaction, core: String, decoy: Bool) -> some View {
        let on = !decoy && !unticked.contains(x.id)
        return Button {
            guard !decoy else { return }
            if unticked.contains(x.id) { unticked.remove(x.id) } else { unticked.insert(x.id) }
        } label: {
            HStack(spacing: 8) {
                CheckBox(on: on).frame(width: 22, alignment: .leading)
                Text(Fmt.dayShort(x.date)).font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                    .frame(width: 52, alignment: .leading)
                Text(highlighted(x.rawDescription, core: core, wholeWords: !decoy))
                    .font(HouseFont.raw(11)).foregroundStyle(ink.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Fmt.usdCents(x.amount.double)).font(HouseFont.jost(12)).monospacedDigit()
                    .foregroundStyle(ink.text)
                    .frame(width: 72, alignment: .trailing)
            }
            .padding(.vertical, 5).padding(.horizontal, 2)
            .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
            .opacity(on ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(decoy)
        .help(decoy ? "Shares the letters, not the words — not caught by this rule" : "")
    }

    /// The bank text with the core underlined in warm — matched word-aware for the lines
    /// the rule catches (`MR. KALE` holds `MR KALE`), as plain letters for a decoy.
    private func highlighted(_ raw: String, core: String, wholeWords: Bool) -> AttributedString {
        var s = AttributedString(raw)
        let words = core.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return s }
        let body = words.joined(separator: "[^A-Za-z0-9]+")
        let pattern = wholeWords ? "(?<![A-Za-z0-9])\(body)(?![A-Za-z0-9])" : body
        guard let r = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              let a = AttributedString.Index(r.lowerBound, within: s),
              let b = AttributedString.Index(r.upperBound, within: s) else { return s }
        s[a..<b].underlineStyle = Text.LineStyle(pattern: .solid, color: ink.warm)
        return s
    }

    // MARK: - Save

    private func save() {
        guard let p = preview else { onClose(); return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Only what was changed: a rename must not pin every matched line to the category
        // this one happened to open with.
        let edit = TransactionEdit(name: trimmed.isEmpty || trimmed == start.name ? nil : trimmed,
                                   categoryId: kind == .transfer || categoryId == start.categoryId ? nil : categoryId,
                                   kind: kind == start.kind ? nil : kind)
        let n: Int
        switch canAll ? scope : .one {
        case .one:
            n = store.apply(edit: edit, to: transactionId, scope: .justThisOne)
        case .all:
            n = store.apply(edit: edit, to: transactionId,
                            scope: .allLikeThis(pattern: p.core, match: .contains, unticked: unticked,
                                                direction: p.direction))
        }
        let what: String
        switch kind {
        case .transfer: what = "internal transfer — left out of spending"
        case .income, .spend: what = store.categories.category(categoryId)?.name ?? ""
        }
        let who = trimmed.isEmpty ? p.suggestedName : trimmed
        Toaster.shared.say("✓ \(n == 1 ? "1 entry" : "\(n) entries") now “\(who)” · \(what)\(scope == .all && canAll ? " · future imports too" : "")")
        onClose()
    }

    // MARK: - Pieces

    private func choice<L: View>(on: Bool, centred: Bool, action: @escaping () -> Void,
                                 @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: centred ? 6 : 7) { label() }
                .foregroundStyle(ink.text)
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                .padding(.horizontal, 8).padding(.vertical, centred ? 9 : 8)
                .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? ink.text : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// A tick box drawn by hand, so it renders offscreen too.
struct CheckBox: View {
    let on: Bool
    @Environment(\.ink) private var ink

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(on ? ink.text : .clear)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? ink.text : ink.faint, lineWidth: 1.2))
            .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(ink.ground).opacity(on ? 1 : 0))
            .frame(width: 14, height: 14)
    }
}

/// One merchant month by month across the whole ledger — the range strip in small, for
/// the name this line goes by. Messy bank text starts as a lone bar; once "All like this"
/// folds it into one name, its whole habit shows: how often, how much, the average.
struct MerchantHistory: View {
    let store: SpendingStore
    let line: BankTransaction
    /// A click on a month opens its entry to edit — or, for a month of several, lists them.
    var onOpen: ((String) -> Void)? = nil
    @Environment(\.ink) private var ink
    @State private var hover: Int?
    /// The month clicked, when it holds more than one entry.
    @State private var picked: Month?

    private let height: CGFloat = 92, base: CGFloat = 74

    var body: some View {
        let income = line.effectiveKind == .income
        let all = store.monthlyTotals(merchant: line.displayName, income: income)
        // From its first month on: a shop opened in June doesn't average in the empty spring.
        let data = Array(all.drop { entries(in: $0.month, income: income).isEmpty })
        let values = data.map { max(0, $0.total.double) }
        let paid = values.reduce(0, +)
        let count = store.transactions(TransactionFilter(kind: income ? .income : .spend, merchant: line.displayName)).count
        let avg = data.isEmpty ? 0 : paid / Double(data.count)
        let color = Color(hex: store.categories.category(line.effectiveCategoryId)?.colorHex ?? "#8C9196")

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("HISTORY").font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
                Spacer()
                Group {
                    if let h = hover, data.indices.contains(h) {
                        let k = entries(in: data[h].month, income: income).count
                        Text("\(Fmt.monthYear(data[h].month)) · \(Fmt.usd(values[h]))\(k > 1 ? " · ×\(k)" : "")").foregroundStyle(ink.text)
                    } else {
                        Text("avg \(Fmt.usd(avg))/mo · ×\(count) · \(Fmt.usd(count > 0 ? paid / Double(count) : 0)) each")
                    }
                }
                .font(HouseFont.jost(12)).foregroundStyle(ink.muted).monospacedDigit()
            }
            GeometryReader { g in
                let w = g.size.width
                let n = max(1, data.count)
                let slot = w / CGFloat(n)
                let bw = max(2, min(22, slot - 4))
                let top = max(avg, values.max() ?? 1, 1)
                Canvas { ctx, _ in
                    for (i, v) in values.enumerated() {
                        let h = CGFloat(v / top) * (base - 6)
                        let x = CGFloat(i) * slot + (slot - bw) / 2
                        let rect = CGRect(x: x, y: base - h, width: bw, height: h)
                        let on = hover.map { $0 == i } ?? picked.map { $0 == data[i].month } ?? true
                        if h > 0 { ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, bw / 2)), with: .color(color.opacity(on ? 1 : 0.4))) }
                        let label = data[i].month.month == 1 || i == 0 || i == n - 1
                        if label {
                            let m = data[i].month
                            let t = ctx.resolve(Text(m.month == 1 || i == 0 ? "\(Fmt.monthShort(m)) ’\(String(m.year).suffix(2))" : Fmt.monthShort(m))
                                .font(HouseFont.jost(10.5)).foregroundStyle(ink.faint))
                            ctx.draw(t, at: CGPoint(x: min(max(x + bw / 2, 18), w - 18), y: height), anchor: .bottom)
                        }
                    }
                    var floor = Path(); floor.move(to: CGPoint(x: 0, y: base + 0.5)); floor.addLine(to: CGPoint(x: w, y: base + 0.5))
                    ctx.stroke(floor, with: .color(ink.rule), lineWidth: 1)
                    if avg > 0 {
                        let y = level(avg, top)
                        var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: w, y: y))
                        ctx.stroke(line, with: .color(ink.muted), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hover = max(0, min(n - 1, Int(p.x / slot))) } else { hover = nil }
                }
                .onTapGesture { p in
                    guard onOpen != nil, !data.isEmpty else { return }
                    open(data[max(0, min(n - 1, Int(p.x / slot)))].month, income: income)
                }
                .help(onOpen == nil ? "" : "Click a month to edit its entry")
            }
            .frame(height: height)

            if let m = picked {
                let lines = entries(in: m, income: income)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.monthYear(m).uppercased()).font(HouseFont.jost(10.5, 500)).tracking(1.5)
                        .foregroundStyle(ink.faint).padding(.bottom, 4)
                    ForEach(lines, id: \.id) { t in
                        Button { onOpen?(t.id) } label: {
                            HStack {
                                Text(Fmt.dayShort(t.date)).foregroundStyle(ink.muted).frame(width: 56, alignment: .leading)
                                Text(store.categories.category(t.effectiveCategoryId)?.name ?? "").foregroundStyle(ink.faint)
                                Spacer()
                                Text(Fmt.signedCents(t.amount.double)).foregroundStyle(t.id == line.id ? ink.faint : ink.text)
                            }
                            .font(HouseFont.jost(12.5)).monospacedDigit()
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(t.id == line.id)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// This merchant's entries in one month, newest first.
    private func entries(in m: Month, income: Bool) -> [BankTransaction] {
        store.transactions(TransactionFilter(range: m...m, kind: income ? .income : .spend, merchant: line.displayName))
            .reversed()
    }

    private func open(_ m: Month, income: Bool) {
        let lines = entries(in: m, income: income)
        if lines.count == 1, let t = lines.first {
            if t.id != line.id { onOpen?(t.id) }
            picked = nil
        } else {
            picked = picked == m || lines.isEmpty ? nil : m
        }
    }

    private func level(_ v: Double, _ top: Double) -> CGFloat { base - CGFloat(v / top) * (base - 6) }
}
