import SwiftUI

/// Reports scroll-wheel and trackpad-scroll events over a SwiftUI view.
///
/// SwiftUI has no scroll-wheel hook on macOS 14 outside a `ScrollView`, and the wallet
/// canvas is not one — it is a field that gets panned by dragging. So the events are
/// read from AppKit directly.
///
/// A local event monitor rather than an `NSView` that overrides `scrollWheel(with:)`:
/// AppKit delivers a scroll to the view under the cursor, and the cursor here is over
/// SwiftUI's own hosting view with the wallet modules inside it. A sibling NSView layered
/// behind them would simply never be hit. The monitor sees every scroll in the process,
/// so this filters to the ones landing inside its own bounds.
///
/// The view itself is invisible and refuses hit-testing, so clicks, drags and hovers
/// carry on reaching the modules underneath as though it weren't there.
struct ScrollWheelCatcher: NSViewRepresentable {

    /// A scroll that happened over this view.
    struct Scroll {
        /// Movement since the last event, in points. Positive Y is a scroll upward.
        let deltaX: CGFloat
        let deltaY: CGFloat
        /// Where the cursor was, in the view's own coordinates, top-left origin.
        let location: CGPoint
        /// True for a trackpad or Magic Mouse, false for a wheel mouse's discrete notches.
        /// The two want opposite things from a scroll, so the distinction has to survive.
        let isPrecise: Bool
        /// ⌘ or ⌥ held — the conventional Mac "zoom instead" modifier.
        let zoomModifier: Bool
    }

    let onScroll: (Scroll) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class CatcherView: NSView {
        var onScroll: ((Scroll) -> Void)?
        private var monitor: Any?

        /// Top-left origin, so a location handed to SwiftUI needs no flipping.
        override var isFlipped: Bool { true }

        /// Invisible to the mouse: everything below keeps its clicks and drags.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // No window means the view is being torn down — drop the monitor with it
            // rather than leaving it running against a dead view.
            window == nil ? stopMonitoring() : startMonitoring()
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returning nil swallows the event, so a scroll spent zooming the canvas doesn't
        /// also scroll whatever is behind it. Anything not over this view is returned
        /// untouched — the monitor sees the whole process, not just this window.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return event }

            // An inverted device reports its deltas already negated; undoing that keeps
            // "scroll up" meaning the same thing whatever the system setting is.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onScroll?(Scroll(deltaX: event.scrollingDeltaX * sign,
                             deltaY: event.scrollingDeltaY * sign,
                             location: point,
                             isPrecise: event.hasPreciseScrollingDeltas,
                             zoomModifier: mods.contains(.command) || mods.contains(.option)))
            return nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
