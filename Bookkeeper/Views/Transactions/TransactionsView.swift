import SwiftUI
import BookkeeperCore

/// Every line, newest first, grouped by month under sticky month headers ("October 2026
/// · $3,756 spent"). Search (name, bank text, amount) and the kind filter narrow it; a tap
/// opens the edit drawer from the right. Ported from the mockup's `#s-tx` — `renderTx`,
/// `txMatches`, `rowIcon` — behaviour as well as look.
///
/// The list is a `LazyVStack`, so a ledger of thousands of lines only builds the rows on
/// screen.
struct TransactionsView: View {
    let store: SpendingStore
    let importer: SpendingImporter
    let model: TransactionsModel
    /// For `--snapshot`: no ScrollView, no AppKit field, and only the first screenful.
    var rendering = false

    private var ink: Ink { Ink.resolve(store.settings.theme, systemIsDark: SystemAppearance.shared.isDark) }

    var body: some View {
        let lines = model.lines(store)
        Group {
            if rendering { page(lines) } else { ScrollView { page(lines) } }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(ink.ground)
        .overlay(alignment: .bottomTrailing) {
            ReviewPill(store: store) { withAnimation(.easeOut(duration: 0.2)) { model.filter = .review } }
        }
        .overlay { if model.editing != nil { Scrim { model.editing = nil } } }
        .overlay(alignment: .trailing) { editor }
        .environment(\.ink, ink)
        .environment(\.colorScheme, ink.colorScheme)
        .dropDestination(for: URL.self) { urls, _ in
            importer.importFiles(urls.filter { $0.pathExtension.lowercased() == "csv" })
            return true
        }
        .animation(.easeOut(duration: 0.22), value: model.editing)
    }

    private func page(_ lines: [BankTransaction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.transactions.isEmpty {
                SpendingEmptyState(importer: importer)
            } else {
                bar(count: lines.count).padding(.bottom, 18)
                list(lines)
            }
        }
        .frame(maxWidth: 1360)
        .padding(.top, 24).padding(.horizontal, 40).padding(.bottom, 96)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Search + filter

    private func bar(count: Int) -> some View {
        HStack(spacing: 14) {
            search
            Seg(options: TransactionsModel.Filter.allCases, selected: model.filter, help: nil) { f in
                model.filter = f
            } label: { f in
                Text(f.rawValue).font(HouseFont.jost(13))
            }
            Text("\(count) \(count == 1 ? "line" : "lines")").font(HouseFont.jost(12.5)).foregroundStyle(ink.faint)
            Spacer()
        }
    }

    private var search: some View {
        @Bindable var model = model
        return Group {
            if rendering {
                Text(model.query.isEmpty ? "Search — kale, coffee, 23.18 …" : model.query)
                    .foregroundStyle(model.query.isEmpty ? ink.faint : ink.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.query,
                          prompt: Text("Search — kale, coffee, 23.18 …").foregroundStyle(ink.faint))
                    .textFieldStyle(.plain)
                    .foregroundStyle(ink.text)
            }
        }
        .font(HouseFont.jost(13.5))
        .padding(.horizontal, 16).padding(.vertical, 9)
        .frame(width: 300)
        .background(ink.card, in: Capsule())
        .overlay(Capsule().stroke(ink.rule, lineWidth: 1))
    }

    // MARK: - The list

    @ViewBuilder private func list(_ lines: [BankTransaction]) -> some View {
        let all = TransactionsModel.months(lines)
        // Offscreen: the first screenful only, each month still totalled in full.
        let months = rendering ? TransactionsModel.firstLines(all, 24) : all
        if months.isEmpty {
            Text("Nothing matches.").font(HouseFont.jost(14)).foregroundStyle(ink.faint)
                .padding(.horizontal, 8).padding(.vertical, 30)
        } else if rendering {
            VStack(alignment: .leading, spacing: 0) { sections(months) }
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) { sections(months) }
        }
    }

    private func sections(_ months: [TransactionsModel.MonthGroup]) -> some View {
        let book = store.categories
        return ForEach(months) { g in
            Section {
                ForEach(g.lines, id: \.id) { t in
                    TransactionRow(line: t, book: book, selected: model.editing == t.id) {
                        model.editStartsAllLikeThis = false
                        model.editOpensForm = false
                        model.editing = t.id
                    }
                }
            } header: {
                monthHeader(g)
            }
        }
    }

    private func monthHeader(_ g: TransactionsModel.MonthGroup) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Fmt.monthLong(g.month)).font(HouseFont.fraunces(17)).foregroundStyle(ink.text)
            Spacer()
            Text("\(Fmt.usd(g.spent)) spent").font(HouseFont.jost(14)).monospacedDigit().foregroundStyle(ink.muted)
        }
        .padding(.horizontal, 8).padding(.top, 22).padding(.bottom, 8)
        .background(ink.ground)
    }

    // MARK: - Drawer

    @ViewBuilder private var editor: some View {
        if let id = model.editing {
            TransactionEditor(store: store, transactionId: id, rendering: rendering,
                              startsAllLikeThis: model.editStartsAllLikeThis, startsEditing: model.editOpensForm,
                              onOpen: { other in
                                  model.editStartsAllLikeThis = false
                                  model.editOpensForm = true
                                  model.editing = other
                              }) { model.editing = nil }
                .id(id)
                .transition(.move(edge: .trailing))
        }
    }
}
