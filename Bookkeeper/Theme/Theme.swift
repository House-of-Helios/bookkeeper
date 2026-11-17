import SwiftUI

/// The app's ground colours.
///
/// This was a `Theme` per design direction, chosen at runtime while four of them were
/// being compared. One was picked, so the others and the machinery for switching between
/// them are gone: a value read from one place beats an enum, a stored preference and a
/// switcher in the sidebar for a choice nobody makes any more.
enum Theme {
    /// Pure black field. Colour is carried by the cells and the rings, never by the page.
    static var ground: Color { Look.shared.ink.ground }
    static var raised: Color { Look.shared.ink.active }
    static var ink: Color { Look.shared.ink.text }
    static var dim: Color { Look.shared.ink.muted }
    static var rule: Color { Look.shared.ink.track }
    static var positive: Color { Look.shared.ink.up }
    static let negative = Color(hex: "#D0021B")
}
