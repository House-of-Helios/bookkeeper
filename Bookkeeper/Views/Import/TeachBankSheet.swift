import SwiftUI
import BookkeeperCore

/// One dropped file no recipe fits, waiting to be taught.
struct TeachRequest: Identifiable {
    let id = UUID()
    let file: SpendingImporter.DroppedFile
    /// The first rows — a header (if it has one) and five data rows.
    let preview: ColumnPreview
    /// Every non-blank row below any header.
    let rowCount: Int
    var suggestedName: String

    init(file: SpendingImporter.DroppedFile, suggestedName: String = "My bank") {
        self.file = file
        self.suggestedName = suggestedName
        preview = ColumnPreview(text: file.text, limit: 6)
        let rows = CSV.parse(file.text).filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        rowCount = max(0, rows.count - (preview.firstRowLooksLikeHeader ? 1 : 0))
    }
}

/// "New bank shape — show me which column is which, once." Shown when a dropped CSV
/// matches no recipe: the file's first rows with a role picker above each column, which
/// way money out is signed, the date format read from the cells, and a live preview of
/// how Bookkeeper reads the file under the mapping so far. Save remembers the recipe in
/// `recipes.json` and imports the file; the next file of the same shape goes straight in.
/// Ported from the mockup's `#s-teach` / `renderMap`.
struct TeachBankSheet: View {
    let importer: SpendingImporter
    let request: TeachRequest
    /// For `--snapshot`: no ScrollView, menus or AppKit field.
    var rendering = false

    @Environment(\.ink) private var ink
    @State private var mapping: TeachMapping
    @State private var name: String
    private let recipeId = "taught-" + UUID().uuidString.prefix(8).lowercased()

    /// The sheet's content width — the mockup's `.sheet { max-width: 1000px }`.
    static let width: CGFloat = 1000

    init(importer: SpendingImporter, request: TeachRequest, rendering: Bool = false) {
        self.importer = importer; self.request = request; self.rendering = rendering
        _mapping = State(initialValue: request.preview.suggestedMapping())
        _name = State(initialValue: request.suggestedName)
    }

    private var preview: ColumnPreview { request.preview }

    private var recipe: ImportRecipe? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return mapping.recipe(id: recipeId, name: n.isEmpty ? "My bank" : n,
                              header: preview.header, columnCount: preview.columnCount)
    }

    /// How many rows the mapping reads in the whole file.
    private var readable: Int { recipe.map { $0.parse(text: request.file.text).rows.count } ?? 0 }

    var body: some View {
        Group {
            if rendering { content } else { ScrollView { content }.scrollIndicators(.never) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ink.ground)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TEACH A BANK · UNKNOWN FILE").font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            Text("New bank shape — show me which column is which, once.")
                .font(HouseFont.fraunces(22)).foregroundStyle(ink.text)
                .padding(.top, 8).padding(.bottom, 6)
            Text("No recipe fits this file (built in: Chase, Bank of America, Wells Fargo, Capital One, Amex, Citi, Discover, Apple Card). \(preview.firstRowLooksLikeHeader ? "This one has a header row." : "This one has no header row.") Change a dropdown — the preview below re-reads the file live.")
                .font(HouseFont.jost(13.5)).foregroundStyle(ink.muted).lineSpacing(5)
                .frame(maxWidth: 760, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            fileLine.padding(.vertical, 20)
            table
            options.padding(.vertical, 24)
            Text("PREVIEW — HOW BOOKKEEPER READS IT").font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
            previewRows
            actions.padding(.top, 24)
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private var fileLine: some View {
        HStack(spacing: 12) {
            Emoji(name: "package", size: 26)
            Text(request.file.name).font(HouseFont.jost(14, 600)).foregroundStyle(ink.text)
            Text("\(preview.columnCount) columns · \(preview.firstRowLooksLikeHeader ? "header row" : "no header row") · \(request.rowCount) rows")
                .font(HouseFont.jost(14)).foregroundStyle(ink.muted)
            Text("no recipe matched").font(HouseFont.jost(12.5)).foregroundStyle(ink.warm)
        }
    }

    // MARK: - The columns

    /// Column widths in proportion to their longest cell, like an HTML table's auto layout.
    private var widths: [CGFloat] {
        let n = preview.columnCount
        guard n > 0 else { return [] }
        let weights = (0..<n).map { c -> CGFloat in
            let longest = preview.rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
            return CGFloat(min(40, max(14, longest)))
        }
        let room = Self.width - CGFloat(n - 1) * 12
        let total = weights.reduce(0, +)
        return weights.map { room * $0 / total }
    }

    private var table: some View {
        let w = widths
        let data = Array(preview.dataRows.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<preview.columnCount, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        RolePicker(role: mapping.roles[c], rendering: rendering) { setRole($0, c) }
                        if let header = preview.header, c < header.count {
                            Text(header[c]).font(HouseFont.jost(11)).foregroundStyle(ink.faint).lineLimit(1)
                        }
                    }
                    .frame(width: w[c], alignment: .leading)
                }
            }
            .padding(.bottom, 10)
            ForEach(Array(data.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(0..<preview.columnCount, id: \.self) { c in
                        let v = c < row.count ? row[c].trimmingCharacters(in: .whitespaces) : ""
                        Group {
                            if v.isEmpty { Text("empty").opacity(0.4) } else { Text(v) }
                        }
                        .font(HouseFont.raw(12))
                        .foregroundStyle(mapping.roles[c] == .ignore ? ink.faint : ink.text)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: w[c], alignment: .leading)
                    }
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
            }
        }
    }

    /// One role per column; giving a column a role another column holds frees that one.
    private func setRole(_ role: ColumnRole, _ column: Int) {
        if role != .ignore, let other = mapping.roles.firstIndex(of: role), other != column {
            mapping.roles[other] = .ignore
        }
        mapping.roles[column] = role
        if role == .date { mapping.dateFormat = preview.dateFormat(column: column) ?? mapping.dateFormat }
    }

    // MARK: - Sign + date

    private var options: some View {
        HStack(spacing: 36) {
            HStack(spacing: 10) {
                if mapping.column(.amount) != nil {
                    Text("Money out shows as").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                    Seg(options: [true, false], selected: mapping.moneyOutIsNegative, help: nil) {
                        mapping.moneyOutIsNegative = $0
                    } label: { neg in
                        Text(neg ? "− negative" : "+ positive").font(HouseFont.jost(13))
                    }
                } else {
                    Text("Money out and money in sit in their own columns — no sign to choose.")
                        .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                }
            }
            HStack(spacing: 8) {
                Text("Date looks like").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                if let c = mapping.column(.date), preview.dateFormat(column: c) != nil {
                    Text(mapping.dateFormat.uppercased()).font(HouseFont.raw(13)).foregroundStyle(ink.text)
                } else {
                    Text("— pick the date column").font(HouseFont.jost(13)).foregroundStyle(ink.warm)
                }
            }
        }
    }

    // MARK: - Live preview

    private var previewRows: some View {
        let parsed = recipe.map { preview.apply($0) } ?? Array(repeating: nil, count: preview.rows.count)
        let headerAt = preview.firstRowLooksLikeHeader ? 0 : -1
        let shown = preview.rows.indices.filter { $0 != headerAt }.prefix(5)
        let desc = mapping.column(.description)
        return VStack(spacing: 0) {
            ForEach(Array(shown), id: \.self) { i in
                let row = parsed[i]
                let raw = preview.rows[i]
                HStack(spacing: 16) {
                    Text(row.map { Fmt.dayShort($0.date) } ?? "?").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                        .frame(width: 90, alignment: .leading)
                    Text(desc.flatMap { $0 < raw.count ? raw[$0] : nil } ?? "—")
                        .font(HouseFont.raw(12.5)).foregroundStyle(ink.text).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.map { Fmt.signedCents($0.amount.double) } ?? "?")
                        .font(HouseFont.jost(14)).monospacedDigit()
                        .foregroundStyle((row?.amount ?? 0) > 0 ? ink.up : ink.text)
                        .frame(width: 120, alignment: .trailing)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }
            }
        }
    }

    // MARK: - Save

    private var actions: some View {
        HStack(spacing: 10) {
            Group {
                if rendering { Text(name).frame(maxWidth: .infinity, alignment: .leading) }
                else { TextField("Name this bank", text: $name).textFieldStyle(.plain) }
            }
            .font(HouseFont.jost(13.5)).foregroundStyle(ink.text)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: 240)
            .background(ink.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))

            Button(action: save) {
                Text("Save recipe & import \(recipe == nil ? request.rowCount : readable)")
                    .font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.ground)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(recipe == nil)
            .opacity(recipe == nil ? 0.4 : 1)
            .keyboardShortcut(.defaultAction)
            .help(recipe == nil ? "Pick a Date, a Description and an Amount (or Money out + Money in)" : "")

            Button { importer.skipTeaching() } label: {
                Text("Not now").font(HouseFont.jost(13.5, 600)).foregroundStyle(ink.muted)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(ink.track, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private func save() {
        guard let r = recipe else { return }
        importer.teach(request, recipe: r)
    }
}

/// The mockup's `<select>` above each column: the chosen role, a chevron, and a menu of
/// the seven roles. Offscreen it draws as the closed control.
struct RolePicker: View {
    let role: ColumnRole
    var rendering = false
    var pick: (ColumnRole) -> Void
    @Environment(\.ink) private var ink

    var body: some View {
        if rendering {
            face
        } else {
            Menu {
                ForEach(ColumnRole.allCases, id: \.self) { r in
                    Button { pick(r) } label: {
                        if r == role { Label(r.rawValue, systemImage: "checkmark") } else { Text(r.rawValue) }
                    }
                }
            } label: { face }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private var face: some View {
        HStack {
            Text(role.rawValue).font(HouseFont.jost(12.5)).foregroundStyle(ink.text)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(ink.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.track, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
