import SwiftUI
import BookkeeperCore

/// One rule, opened from Settings → Rules: the bank words it looks for, the name and
/// category it gives what it catches, and how many entries that is — counted live as the
/// words change. Save re-reads the ledger under the edited rule; Remove takes it away.
struct RuleEditor: View {
    let store: SpendingStore
    let rule: MerchantRule
    var onClose: () -> Void
    @Environment(\.ink) private var ink

    @State private var pattern: String
    @State private var name: String
    @State private var kind: TransactionKind
    @State private var categoryId: String
    @State private var confirmRemove = false
    /// What the category picker opened on, so a change from it shows Save.
    private let startCategory: String
    /// What the kind picker opened on.
    private let startKind: TransactionKind

    init(store: SpendingStore, rule: MerchantRule, onClose: @escaping () -> Void) {
        self.store = store; self.rule = rule; self.onClose = onClose
        _pattern = State(initialValue: rule.pattern)
        _name = State(initialValue: rule.name ?? "")
        // A rule that only picks a kind of income (Paycheck) is an income rule.
        let k = rule.kind ?? (rule.categoryId.map(CategoryBook.isIncomeId) == true ? .income : .spend)
        startKind = k
        _kind = State(initialValue: k)
        startCategory = rule.categoryId ?? (k == .income ? CategoryBook.incomeFallbackId : CategoryBook.fallbackId)
        _categoryId = State(initialValue: startCategory)
    }

    /// Entries the words as typed would catch, less the ones unticked when it was made.
    private var reach: Int {
        store.matches(for: pattern, match: rule.match, direction: rule.direction)
            .filter { !rule.excludedTransactionIds.contains($0.id) }.count
    }

    /// A payment app's rule keeps to money one way.
    private var way: String {
        switch rule.direction { case .moneyIn: return ", money in only,"; case .moneyOut: return ", money out only,"; case nil: return "" }
    }

    private var changed: Bool {
        pattern.trimmingCharacters(in: .whitespaces) != rule.pattern || name != (rule.name ?? "")
            || kind != (rule.kind ?? .spend)
            || (kind != .transfer && categoryId != startCategory)
    }

    var body: some View {
        let n = reach
        VStack(alignment: .leading, spacing: 0) {
            Text("Rule").font(HouseFont.fraunces(22)).foregroundStyle(ink.text)

            field("Bank words") {
                input($pattern, raw: true)
                Text(n == 0 ? "Catches no entries — check the words against a bank line."
                            : "Catches \(n) \(n == 1 ? "entry" : "entries")\(way) now, and every future import.")
                    .font(HouseFont.jost(12)).foregroundStyle(n == 0 ? ink.warm : ink.muted)
            }
            field("Name") { input($name, raw: false) }

            field("Counts as") {
                HStack(spacing: 6) {
                    ForEach(Self.kinds, id: \.0) { k, title, icon in
                        choice(on: kind == k, centred: true) { pick(k) } label: {
                            Emoji(name: icon, size: 18)
                            Text(title).font(HouseFont.jost(12.5))
                        }
                    }
                }
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

            HStack(spacing: 10) {
                Button(action: save) {
                    Text("Save").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!changed || n == 0)
                .opacity(changed && n > 0 ? 1 : 0.4)
                Button(action: onClose) {
                    Text("Cancel").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button { confirmRemove = true } label: {
                    Text("Remove rule").font(HouseFont.jost(13)).foregroundStyle(ink.warm)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 480)
        .background(ink.card)
        .confirmationDialog("Remove the rule for \(rule.pattern)?", isPresented: $confirmRemove) {
            Button("Remove rule", role: .destructive) { store.removeRule(rule.id); onClose() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its entries go back to the bank’s own name and category, and new files stop following it. Entries you changed one at a time keep their change.")
        }
    }

    private func save() {
        let typed = name.trimmingCharacters(in: .whitespaces)
        // Kind and category stay unset when they were unset and weren't touched, so the
        // rule keeps leaving them to the bank and the defaults.
        let k: TransactionKind? = rule.kind == nil && kind == startKind ? nil : kind
        let c: String? = kind == .transfer || (rule.categoryId == nil && categoryId == startCategory) ? nil : categoryId
        store.updateRule(rule.id, pattern: pattern, name: typed.isEmpty ? nil : typed, categoryId: c, kind: k)
        Toaster.shared.say("✓ Rule saved · \(reach) \(reach == 1 ? "entry" : "entries")", for: 3)
        onClose()
    }

    // MARK: - Pieces, in the line drawer's look

    private static let kinds: [(TransactionKind, String, String)] = [
        (.spend, "Spending", "receipt"), (.income, "Income", "money_with_wings"),
        (.transfer, "Internal transfer", "left-right_arrow"),
    ]

    /// A kind change keeps the category only if it belongs to the new kind's list.
    private func pick(_ k: TransactionKind) {
        kind = k
        if k == startKind { categoryId = startCategory; return }
        let book = store.categories
        if k == .income, !book.incomeCategories.contains(where: { $0.id == categoryId }) {
            categoryId = CategoryBook.incomeFallbackId
        }
        if k == .spend, !book.categories.contains(where: { $0.id == categoryId }) {
            categoryId = CategoryBook.fallbackId
        }
    }

    private func input(_ text: Binding<String>, raw: Bool) -> some View {
        TextField("", text: text).textFieldStyle(.plain)
            .font(raw ? HouseFont.raw(14) : HouseFont.jost(16)).foregroundStyle(ink.text)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(ink.ground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
    }

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

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(HouseFont.jost(11, 500)).tracking(1.5).foregroundStyle(ink.faint)
            content()
        }
        .padding(.top, 20)
    }
}
