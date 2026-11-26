import SwiftUI

/// Every timing of the open / close choreography in one place.
/// Faster = smaller `response` and shorter delays. Damping 1.0 = no overshoot.
enum Motion {
    // Pointer
    /// Hover this long on the notch before it opens.
    static let hoverDelay: TimeInterval = 0.09
    /// Grace after the pointer leaves before it closes.
    static let leaveGrace: TimeInterval = 0.18

    // Opening
    static let openWidth = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let openHeight = Animation.spring(response: 0.32, dampingFraction: 0.84)
    /// Alerts keep a small bounce.
    static let openHeightAlert = Animation.spring(response: 0.34, dampingFraction: 0.68)
    /// Header and cards start once the shape is about two-thirds open.
    static let contentDelay: UInt64 = 95_000_000 // ns
    static let headerFade = Animation.easeOut(duration: 0.16)
    static let card = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let cardStagger: Double = 0.03

    // Closing
    static let contentOut = Animation.easeOut(duration: 0.07)
    static let close = Animation.spring(response: 0.24, dampingFraction: 1.0).delay(0.03)

    /// After a state change, the edge fuse waits this long for the shape to settle.
    static let edgeSettle: TimeInterval = 0.32

    // Small states
    static let compactIn = Animation.easeOut(duration: 0.15).delay(0.08)
    static let alertIn = Animation.easeOut(duration: 0.16).delay(0.1)
}
