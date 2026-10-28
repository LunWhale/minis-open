//
//  ComposerShrinkAbsorption.swift
//  MinisApp
//
//  [T-send-composer-shrink-absorb] Bookkeeping that lets a just-sent message
//  land in the space the composer gives up, instead of the list jumping up for
//  the new rows and then snapping back down. Pure: it sees heights only, so the
//  rule is unit-tested without the list
//  (MinisTests/Standalone/ComposerShrinkAbsorptionTests).
//

import CoreGraphics

/// The composer's height as layout last reported it - NOT debounced.
///
/// The message list's bottom inset is built from `inputBarHeight`, a SwiftUI
/// state that follows the composer through a 380 ms trailing debounce (see
/// AIChatView+InputBar; the debounce is what keeps transitional heights out of
/// the inset). This box carries the same measurement the moment it is made, so
/// the list can tell that a shrink is on its way before the state lands.
/// A reference type on purpose: writing it does not re-evaluate any view body.
/// Main thread only.
final class ComposerLiveHeight {
    private(set) var value: CGFloat = 0
    /// Called after `value` changed. Set by the message list.
    var onChange: (() -> Void)?

    func report(_ height: CGFloat) {
        guard height > 0, abs(height - value) > 0.5 else { return }
        value = height
        onChange?()
    }
}

/// Which part of a composer shrink that the debounce has not committed yet has
/// already been taken out of the list's bottom inset.
///
/// Sending from the voice panel shrinks the composer twice within half a
/// second (the transcript is cleared, then the panel collapses to its compact
/// form), while the sent bubble and the "is thinking…" row are appended. With
/// the inset still at the pre-send height, each appended row was pinned against
/// a line that no longer existed and pushed the conversation up by its own
/// height; when the debounce landed, the whole shrink was applied in one frame
/// and the conversation dropped back - up 118 pt, then down 106 pt in the
/// recording that reported it, for a net move of 12 pt.
///
/// Rule: when a pin is about to scroll the content up by `reach` points and the
/// composer is known to be shorter than the inset assumes, take up to `reach`
/// points of that shrink out of the inset first. The new rows then fill the
/// space the composer released and the content above them stays where it is.
/// Never more than `reach`: the content must not move DOWN on a height the
/// composer has only reported - its collapse may still be animating on screen,
/// and rows pinned to the final line would sit under it.
struct ComposerShrinkAbsorption {
    /// The debounced composer height the list's base inset is built from.
    private(set) var committed: CGFloat = 0
    /// Points of a not-yet-committed shrink already removed from the inset.
    private(set) var absorbed: CGFloat = 0

    /// The debounced height as the list sees it on every update. When it
    /// changes it is the truth again and nothing is outstanding.
    mutating func noteCommitted(_ height: CGFloat) {
        guard abs(height - committed) > 0.5 else { return }
        committed = height
        absorbed = 0
    }

    /// Shrink the composer has reported and no row has consumed yet.
    func pending(live: CGFloat) -> CGFloat {
        guard live > 0 else { return 0 }
        return max(0, committed - live - absorbed)
    }

    /// A pin is about to scroll the content up by `reach`. Returns how many
    /// points to take out of the bottom inset before it does (0 = none).
    mutating func absorb(live: CGFloat, reach: CGFloat) -> CGFloat {
        let take = min(pending(live: live), reach)
        guard take > 0.5 else { return 0 }
        absorbed += take
        return take
    }

    /// The live height changed. If the composer grew back above what was
    /// absorbed against, returns the points to give back to the inset.
    mutating func release(live: CGFloat) -> CGFloat {
        let allowed = live > 0 ? max(0, committed - live) : 0
        guard absorbed > allowed + 0.5 else { return 0 }
        let give = absorbed - allowed
        absorbed = allowed
        return give
    }
}
