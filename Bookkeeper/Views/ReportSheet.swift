import SwiftUI
import AppKit
import BookkeeperCore

/// "Send feedback / Report a problem": the whole report on screen, editable, before anything
/// leaves. Copy and Save work now; Send waits for `ReportSender`.
struct ReportSheet: View {
    let facts: ProblemReport.Facts
    /// For `--snapshot`: a plain Text, since `ImageRenderer` can't draw a TextEditor.
    var rendering = false
    var onClose: () -> Void
    @Environment(\.ink) private var ink

    @State private var note: String
    @State private var text: String
    /// What `build` last produced, so a typed-over report is not overwritten by the note.
    @State private var built: String
    @State private var copied = false
    @State private var sending = false
    @State private var sent: Int?
    @State private var failure: String?

    static let width: CGFloat = 560

    init(facts: ProblemReport.Facts, rendering: Bool = false, onClose: @escaping () -> Void) {
        self.facts = facts; self.rendering = rendering; self.onClose = onClose
        let first = ProblemReport.build(facts)
        _note = State(initialValue: facts.note)
        _text = State(initialValue: first)
        _built = State(initialValue: first)
    }

    /// The facts as the sheet gathers them from the app.
    static func facts(store: PortfolioStore, spending: SpendingStore, note: String = "") -> ProblemReport.Facts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return ProblemReport.Facts(
            version: RootView.currentVersion,
            macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", arch: arch,
            theme: spending.settings.theme.rawValue, torOn: TorService.shared.enabled,
            wallets: store.hasRealWallets ? store.wallets.count : 0, banks: spending.accounts.count,
            logLines: ProblemReport.recentLog(), note: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Send feedback").font(HouseFont.fraunces(26)).foregroundStyle(ink.text)
            Text("No amounts, wallets, bank lines, paths or addresses — read it all before it goes.")
                .font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4).padding(.bottom, 20)

            label("WHAT HAPPENED?")
            noteField
            label("WHAT WOULD BE SENT").padding(.top, 18)
            reportField

            HStack(spacing: 12) {
                pill("Copy", copied ? "Copied" : nil, action: copy)
                pill("Save…", action: save)
                Spacer()
                Button(action: onClose) {
                    Text("Cancel").font(HouseFont.jost(14, 500)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: send) {
                    Text(sending ? "Sending…" : sent != nil ? "Sent" : "Send")
                        .font(HouseFont.jost(14, 600)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(RootView.updateGreen, in: Capsule())
                        .opacity(ReportSender.ready && !sending && sent == nil ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!ReportSender.ready || sending || sent != nil)
            }
            .padding(.top, 20)
            Text(footnote)
                .font(HouseFont.jost(11.5)).foregroundStyle(failure == nil ? ink.faint : ink.warm)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(width: Self.width)
        .background(ink.card)
        .onChange(of: note) { _, n in
            guard text == built else { return }
            var f = facts; f.note = n
            built = ProblemReport.build(f); text = built
        }
    }

    private var footnote: String {
        if let failure { return failure }
        if let sent { return "Sent, sealed for the House, through Tor to \(sent) relay\(sent == 1 ? "" : "s"). Thank you." }
        if sending { return "Through Tor; this can take a minute." }
        return ReportSender.ready ? "Send seals it so only the House can read it, and sends it through Tor."
                                  : "Sending arrives in the next version. Until then, Copy or Save and pass it on."
    }

    private func send() {
        sending = true; failure = nil
        let kind = facts.note.hasPrefix("Bookkeeper closed unexpectedly") ? "crash" : "problem"
        Task {
            switch await ReportSender.send(text: text, kind: kind, version: facts.version) {
            case .success(let n): sent = n
            case .failure(let f): failure = f.why
            }
            sending = false
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint).padding(.bottom, 8)
    }

    @ViewBuilder private var noteField: some View {
        Group {
            if rendering {
                Text(note).font(HouseFont.jost(14)).foregroundStyle(ink.text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $note).font(HouseFont.jost(14)).foregroundStyle(ink.text)
                    .scrollContentBackground(.hidden)
            }
        }
        .padding(10).frame(height: 84, alignment: .top)
        .background(ink.ground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.rule, lineWidth: 1))
    }

    @ViewBuilder private var reportField: some View {
        Group {
            if rendering {
                Text(text).font(HouseFont.raw(11)).foregroundStyle(ink.text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $text).font(HouseFont.raw(11)).foregroundStyle(ink.text)
                    .scrollContentBackground(.hidden)
            }
        }
        .padding(10).frame(height: rendering ? 340 : 260, alignment: .top)
        .background(ink.ground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.rule, lineWidth: 1))
    }

    private func pill(_ title: String, _ done: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(done ?? title).font(HouseFont.jost(14, 500)).foregroundStyle(ink.text)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(ink.pill, in: Capsule()).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bookkeeper-report.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
