//
//  SelectableMarkdownTextView+SelectionDismissal.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, selection dismissal.
//
//  touchesBegan: a tap outside the selection clears it on the same tap
//  (instead of the first tap being swallowed), and Shift+click extends the
//  selection from the anchor. The anchor is stored in the core file.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownTextView {
    // MARK: Selection Dismissal

    /// Clear text selection on the first tap outside the selected range.
    ///
    /// By default, UITextView (isSelectable=true, isEditable=false) intercepts the
    /// first tap to manipulate the selection, so the outer SwiftUI .onTapGesture
    /// never fires — the user has to tap twice to dismiss the selection and trigger
    /// the parent's tap handler. This override detects a tap outside the current
    /// selection and immediately clears it, then lets the touch propagate normally
    /// so the parent view responds on the same tap.
    ///
    /// When Shift is held (external keyboard), extends the selection from the
    /// anchor to the tap point.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            super.touchesBegan(touches, with: event)
            return
        }

        let point = touch.location(in: self)
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let isShift = event?.modifierFlags.contains(.shift) == true

        // Tap on a link: always let UITextView handle it so the link-interaction
        // path (primaryActionFor / shouldInteractWith) fires. Otherwise a stale
        // selection from a prior interaction (which survives until SwiftUI
        // recycles the view) would cause the selection-handling branch below to
        // swallow the touch and the link would silently no-op.
        if !isShift,
           charIndex < textStorage.length,
           textStorage.attribute(.link, at: charIndex, effectiveRange: nil) != nil {
            super.touchesBegan(touches, with: event)
            return
        }

        // Shift+click: extend selection from anchor to clicked position.
        if isShift {
            let anchor = selectionAnchor ?? selectedRange.location
            let newStart = min(anchor, charIndex)
            let newEnd = max(anchor, charIndex)
            selectedRange = NSRange(location: newStart, length: newEnd - newStart)
            // Keep the original anchor so further Shift+clicks extend from the same point.
            if selectionAnchor == nil { selectionAnchor = anchor }
            return
        }

        // Non-shift click resets the anchor.
        selectionAnchor = nil

        let sel = selectedRange
        guard sel.length > 0 else {
            super.touchesBegan(touches, with: event)
            return
        }

        // If the tap lands inside or at the edge of the selected range, let UITextView
        // handle it normally (the user may be tapping or dragging a selection handle).
        let selEnd = sel.location + sel.length
        let isInOrAtEdge = NSLocationInRange(charIndex, sel) || charIndex == selEnd

        if isInOrAtEdge {
            super.touchesBegan(touches, with: event)
            return
        }

        // Also check if the touch point is geometrically close to a selection handle.
        let selGlyphRange = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        let selRect = layoutManager.boundingRect(forGlyphRange: selGlyphRange, in: textContainer)
        let handleMargin: CGFloat = 44
        if selRect.insetBy(dx: -handleMargin, dy: -handleMargin).contains(point) {
            super.touchesBegan(touches, with: event)
            return
        }

        // Tap is outside the selection — clear it immediately so this single tap
        // also propagates to the parent SwiftUI view as expected.
        selectedRange = NSRange(location: charIndex, length: 0)
        resignFirstResponder()
        // Do NOT call super: we've already cleared the selection and we want the
        // touch to fall through to the scroll view / SwiftUI gesture recognizers.
    }
}
