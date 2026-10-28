//
//  TableScrollView.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments / Table.
//
//  Horizontal scroller that hosts a table's grid. Re-resolves its border
//  CGColor when the trait collection changes, and reports a user's horizontal
//  scroll so a streaming rebuild of the table keeps the offset.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

/// UIScrollView subclass that re-resolves its `layer.borderColor` whenever
/// the active trait collection changes. CGColor values frozen from a
/// dynamic UIColor at view-creation time would otherwise lock in whichever
/// appearance was active when the attachment was first laid out — typically
/// before the view enters the window, so light-mode `UIColor.label`
/// resolves and renders nearly invisible against a dark message background.
final class TableScrollView: UIScrollView, UIScrollViewDelegate {
    /// Closure called every time the trait collection changes; should
    /// return a CGColor resolved for the supplied trait collection.
    var borderColorProvider: ((UITraitCollection) -> CGColor)?

    /// [T-ios-table-hscroll-stream-interrupt] One-shot callback fired when a
    /// user scroll interaction fully ends (finger lifted with no momentum, or
    /// deceleration settled). Armed by updateAttachmentViews when a streaming
    /// rebuild of this table was deferred because the view was mid-gesture;
    /// the callback replays the deferred rebuild. Cleared before invocation
    /// so a later interaction with no pending rebuild fires nothing.
    var onInteractionEnded: (() -> Void)?

    /// [T-ios-table-hscroll-offset-lost] Reports every USER-driven offset
    /// change (finger down or momentum) so the owning TableAttachment can
    /// persist the position across streaming rebuilds. Programmatic
    /// setContentOffset calls (e.g. the makeView restore) don't fire this —
    /// they run with isTracking/isDragging/isDecelerating all false — so a
    /// clamped restore can never overwrite the user's real position.
    var onUserScroll: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if isTracking || isDragging || isDecelerating {
            onUserScroll?(contentOffset)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { fireInteractionEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fireInteractionEnded()
    }

    private func fireInteractionEnded() {
        guard let callback = onInteractionEnded else { return }
        onInteractionEnded = nil
        callback()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyBorderColorForCurrentTraits()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The trait collection becomes meaningful only after the view is
        // attached to a window; resolve once at that moment so the border
        // is correct on the very first frame the user sees.
        applyBorderColorForCurrentTraits()
    }

    func applyBorderColorForCurrentTraits() {
        guard let provider = borderColorProvider else { return }
        layer.borderColor = provider(traitCollection)
    }
}

/// Minimal UITextView subclass for table cells with tappable links.
/// Intercepts link taps and routes them through the same openURL handler
/// used by the main markdown text view.
