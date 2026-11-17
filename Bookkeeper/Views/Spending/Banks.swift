import SwiftUI
import BookkeeperCore

/// How files find their account, said wherever files go in.
enum BankNaming {
    static let tip = "Name each file with its account's last four digits — “Chase checking 1234.csv”, or Chase's own “Chase1234_Activity….csv” — and every file with those digits goes into the same account."
}

/// Settings → Banks: every account, its files, and what can be done with it — renamed,
/// merged into another (repeats dropped, so nothing counts twice), or added by hand for
/// files to go into. Scrolls on its own past a handful.
struct BanksList: View {
    let store: SpendingStore
    private var ink: Ink { Look.shared.ink }
    @State private var renaming: String?
    @State private var draft = ""
    @State private var merging: (from: BankAccount, into: BankAccount)?
    @State private var removing: ImportRecord?
    @State private var adding = false
    @State private var newName = ""

    static let when: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · HH:mm"
        return f
    }()

    var body: some View {
        let groups = Dictionary(grouping: store.imports, by: \.accountId)
        let lines = Dictionary(grouping: store.transactions, by: \.accountId).mapValues(\.count)
        VStack(alignment: .leading, spacing: 8) {
            if store.accounts.isEmpty && !adding {
                Text("No banks yet — import a file, or add one.").font(HouseFont.jost(13)).foregroundStyle(ink.faint)
            } else {
                scroller {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(store.accounts, id: \.id) { a in
                            VStack(alignment: .leading, spacing: 0) {
                                header(a, lines: lines[a.id] ?? 0)
                                    .padding(.bottom, 6)
                                ForEach(groups[a.id, default: []].reversed(), id: \.importId) { r in fileRow(r) }
                            }
                        }
                        if adding { addRow }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 340)
                .background(ink.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.rule, lineWidth: 1))
            }
            HStack(spacing: 8) {
                Button { adding = true; newName = "" } label: {
                    HStack(spacing: 6) { Emoji(name: "bank", size: 15); Text("Add bank") }
                        .font(HouseFont.jost(12)).foregroundStyle(ink.text)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .overlay(Capsule().stroke(ink.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(ink.faint)
                    .help(BankNaming.tip)
                Text("Name files with the account's last four digits to sort them.")
                    .font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                    .help(BankNaming.tip)
            }
        }
        .confirmationDialog(merging.map { "Merge \($0.from.name) into \($0.into.name)?" } ?? "",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            if let m = merging {
                Button("Merge") {
                    let dropped = store.mergeAccount(m.from.id, into: m.into.id)
                    Toaster.shared.say("✓ Merged into \(m.into.name)" + (dropped > 0 ? " · \(dropped) repeats dropped" : ""), for: 4)
                    merging = nil
                }
            }
            Button("Cancel", role: .cancel) { merging = nil }
        } message: {
            Text("Its entries and files move over. Any entry already there is dropped, so nothing counts twice.")
        }
    }

    // MARK: - An account

    @ViewBuilder private func header(_ a: BankAccount, lines: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: a.colorHex)).frame(width: 8, height: 8)
            if renaming == a.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain).font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.text)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ink.ground, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: 260)
                    .onSubmit { commit(a) }
                Button("Save") { commit(a) }.buttonStyle(.plain)
                    .font(HouseFont.jost(12, 600)).foregroundStyle(ink.text)
                Button("Cancel") { renaming = nil }.buttonStyle(.plain)
                    .font(HouseFont.jost(12)).foregroundStyle(ink.muted)
            } else {
                Text(a.name).font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.text)
                Button { renaming = a.id; draft = a.name } label: {
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(ink.muted)
                }
                .buttonStyle(.plain).help("Rename")
            }
            Spacer(minLength: 8)
            Text("\(lines) \(lines == 1 ? "entry" : "entries")").font(HouseFont.jost(12)).foregroundStyle(ink.faint)
                .monospacedDigit()
            let others = store.accounts.filter { $0.id != a.id }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.id) { o in
                        Button(o.name) { merging = (a, o) }
                    }
                } label: {
                    Text("Merge into…").font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Move this account's entries and files into another")
            }
        }
    }

    private func commit(_ a: BankAccount) {
        store.renameAccount(a.id, to: draft)
        renaming = nil
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Circle().fill(ink.faint).frame(width: 8, height: 8)
            TextField("Bank or account name — e.g. Bank of America checking", text: $newName)
                .textFieldStyle(.plain).font(HouseFont.jost(13.5)).foregroundStyle(ink.text)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(ink.ground, in: RoundedRectangle(cornerRadius: 6))
                .onSubmit(add)
            Button("Add", action: add).buttonStyle(.plain).font(HouseFont.jost(12, 600)).foregroundStyle(ink.text)
            Button("Cancel") { adding = false }.buttonStyle(.plain).font(HouseFont.jost(12)).foregroundStyle(ink.muted)
        }
    }

    private func add() {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let palette = PortfolioStore.walletPalette
        store.addBank(name: newName, colorHex: palette[store.accounts.count % palette.count])
        adding = false
    }

    // MARK: - A file

    private func fileRow(_ r: ImportRecord) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(ink.rule).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(r.fileName ?? "pasted text").font(HouseFont.raw(12)).foregroundStyle(ink.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(counts(r)).font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                Text(Self.when.string(from: r.importedAt)).font(HouseFont.jost(12)).foregroundStyle(ink.faint)
                    .monospacedDigit()
                Button { removing = r } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(ink.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this file and its entries")
            }
            .padding(.vertical, 7)
        }
        .confirmationDialog("Remove \(r.fileName ?? "this file")?",
                            isPresented: Binding(get: { removing?.importId == r.importId },
                                                 set: { if !$0 { removing = nil } })) {
            Button("Remove \(r.added) \(r.added == 1 ? "entry" : "entries")", role: .destructive) {
                store.removeImport(r.importId)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("Its entries leave the ledger. Names and rules you made stay, so dropping the file again brings it back sorted.")
        }
    }

    private func counts(_ r: ImportRecord) -> String {
        var s = "+\(r.added)"
        if r.alreadyHere > 0 { s += " · \(r.alreadyHere) dup" }
        if r.toReview > 0 { s += " · \(r.toReview) review" }
        return s
    }

    /// `ImageRenderer` can't see into a ScrollView, so a snapshot gets the plain list.
    @ViewBuilder private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if SnapshotRenderer.isRendering { content() } else { ScrollView { content() } }
    }
}

/// Before anything is imported: each file, the bank it was read as, and the account it
/// goes to — Automatic (its last four digits, else the best guess, named beside it), any
/// account there is, or a new one.
struct ImportPlanSheet: View {
    let importer: SpendingImporter
    @State var plan: SpendingImporter.ImportPlan
    @Environment(\.ink) private var ink
    @Environment(\.dismiss) private var dismiss

    init(importer: SpendingImporter, plan: SpendingImporter.ImportPlan) {
        self.importer = importer
        _plan = State(initialValue: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import \(plan.files.count) \(plan.files.count == 1 ? "file" : "files")")
                .font(HouseFont.fraunces(22)).foregroundStyle(ink.text)
            Text(BankNaming.tip).font(HouseFont.jost(12)).foregroundStyle(ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6).padding(.bottom, 16)

            ForEach($plan.files) { $f in
                VStack(spacing: 0) {
                    Rectangle().fill(ink.rule).frame(height: 1)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.file.name).font(HouseFont.raw(12)).foregroundStyle(ink.text)
                                .lineLimit(1).truncationMode(.middle)
                            Text(f.recipe.name).font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
                        }
                        Spacer(minLength: 10)
                        Picker("", selection: $f.destination) {
                            Text("Automatic — \(f.guess)").tag(SpendingImporter.Destination.automatic)
                            Divider()
                            ForEach(importer.store.accounts, id: \.id) { a in
                                Text(a.name).tag(SpendingImporter.Destination.account(a.id))
                            }
                            Divider()
                            Text("New account").tag(SpendingImporter.Destination.new)
                        }
                        .labelsHidden()
                        .frame(width: 280)
                    }
                    .padding(.vertical, 10)
                }
            }
            Rectangle().fill(ink.rule).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importer.confirm(plan) }
                    .keyboardShortcut(.defaultAction)
            }
            .font(HouseFont.jost(13.5, 600))
            .padding(.top, 18)
        }
        .padding(28)
        .frame(width: 640)
        .background(ink.card)
    }
}
