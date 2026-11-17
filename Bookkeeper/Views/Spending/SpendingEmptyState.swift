import SwiftUI
import BookkeeperCore

/// No ledger yet. The release build asks for a drop; the dev app also offers its fake
/// inbox in one click (`_DevData/inbox/`, synthetic CSVs only).
struct SpendingEmptyState: View {
    let importer: SpendingImporter
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(spacing: 14) {
            Emoji(name: "inbox_tray", size: 64)
            Text("Drop a bank CSV here").font(HouseFont.fraunces(26)).foregroundStyle(ink.text)
            Text("Export transactions from your bank’s website, then drop the file anywhere on this window — or File → Import CSV…. Nothing leaves this Mac.")
                .font(HouseFont.jost(14)).foregroundStyle(ink.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if SpendingImporter.isDevApp {
                Button { importer.importDevInbox() } label: {
                    HStack(spacing: 8) {
                        Emoji(name: "package", size: 18)
                        Text("Import the fake CSVs in _DevData/inbox").font(HouseFont.jost(13.5, 600))
                    }
                    .foregroundStyle(ink.ground)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(ink.text, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                Text("dev app only · synthetic data").font(HouseFont.jost(11.5)).foregroundStyle(ink.faint)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(ink.track, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])))
    }
}
