import SwiftUI
import AppKit

/// Hands the window a view sits in to `found`, once it's in one.
struct WindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(found: found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}

extension NSWindow {
    /// See-through, shadowless and without its traffic lights — the window gone, so what it
    /// shows seems to sit on the desktop itself — or back to an ordinary window.
    func seeThrough(_ on: Bool, ground: NSColor) {
        isOpaque = !on
        backgroundColor = on ? .clear : ground
        hasShadow = !on
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = on
        }
        invalidateShadow()
    }

    /// Dead centre of its screen's usable area (`center()` sits a little high, by design).
    func centreOnScreen() {
        guard let area = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2))
    }
}
