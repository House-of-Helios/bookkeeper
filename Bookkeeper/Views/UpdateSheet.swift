import SwiftUI
import BookkeeperCore

/// What the update pill opens: every version newer than this one, newest first, with its
/// notes — then Later, or Install & restart.
struct UpdateSheet: View {
    let update: UpdateInfo
    let current: String
    /// For `--snapshot`: no ScrollView, which `ImageRenderer` can't see into.
    var rendering = false
    var onLater: () -> Void
    var onInstall: () -> Void
    @Environment(\.ink) private var ink

    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                EmojiDisc(icon: "inbox_tray", tint: RootView.updateGreen, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bookkeeper \(update.version)").font(HouseFont.fraunces(26)).foregroundStyle(ink.text)
                    Text("You have \(current)").font(HouseFont.jost(13)).foregroundStyle(ink.muted)
                }
            }
            .padding(.bottom, 20)

            Text("WHAT'S NEW").font(HouseFont.jost(10.5, 500)).tracking(2).foregroundStyle(ink.faint)
                .padding(.bottom, 10)
            Group {
                if rendering { notes } else { ScrollView { notes } .frame(maxHeight: 320) }
            }
            .overlay(alignment: .top) { Rectangle().fill(ink.rule).frame(height: 1) }

            HStack(spacing: 12) {
                Spacer()
                Button(action: onLater) {
                    Text("Later").font(HouseFont.jost(14, 500)).foregroundStyle(ink.muted)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: onInstall) {
                    Text("Install & restart").font(HouseFont.jost(14, 600)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(RootView.updateGreen, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: Self.width)
        .background(ink.card)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(update.changes(since: current)) { n in
                VStack(alignment: .leading, spacing: 4) {
                    Text(n.version).font(HouseFont.jost(12.5, 600)).foregroundStyle(ink.muted)
                    Text(n.notes.isEmpty ? "Small fixes." : n.notes)
                        .font(HouseFont.jost(14)).foregroundStyle(ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(ink.rule).frame(height: 1) }
            }
        }
    }
}
