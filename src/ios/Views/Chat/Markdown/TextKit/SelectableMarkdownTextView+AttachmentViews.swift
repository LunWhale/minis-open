//
//  SelectableMarkdownTextView+AttachmentViews.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, attachment views.
//
//  Creates, positions, reuses and removes the UIView drawn over each
//  NSTextAttachment (makeView(width:) on the attachment), keyed by attachment
//  identity, plus the recovery paths for a view re-entering the window after
//  the list recycled it. Dispatches on the concrete attachment classes; a new
//  attachment kind needs a branch here.
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
    // MARK: Attachment Views

    /// Remove all attachment subviews and clear tracking state.
    /// Called when SwiftUI recycles this view for a different message.
    func clearAllAttachmentViews() {
        for view in attachmentViews { view.removeFromSuperview() }
        attachmentViews.removeAll()
        attachmentViewMap.removeAll()
        codeBlockViewCache.removeAll()
        // Reset dedupe fingerprint so the next updateAttachmentViews fully runs.
        lastUAVStorageLen = -1
        lastUAVWidth = -1
        lastUAVViewCount = -1
        // [T-ios-refresh-teardown-guard] Also drop the refresh fingerprint. The
        // `!attachmentViewMap.isEmpty` term already makes the in-place path
        // unreachable right after this call, but clearing it here keeps the
        // invariant explicit: a cleared view set never counts as "same
        // content", whichever site did the clearing.
        lastRefreshStorageLen = -1
        lastRefreshWidth = -1
    }

    /// [issue #117-4] Exact on-screen origin for an INLINE attachment overlay.
    ///
    /// `boundingRect(forGlyphRange:)` reports the glyph's LINE rect vertically:
    /// x/width are the glyph's own, but y/height describe the whole line
    /// fragment. Block attachments own their line, so the two coincide and
    /// nobody noticed — but an inline formula shares its line with text, and
    /// pinning its overlay at the line's top floats it above where TextKit
    /// actually typeset it. The gap is the line's ascent minus the formula's
    /// own height, so SMALL formulas float MOST (measured ≈13pt for `x` inside
    /// a quote block, versus ≈7pt for `x²`) — the "some formulas look higher
    /// than others" report.
    ///
    /// Rebuild the rect from the glyph origin instead. `location(forGlyphAt:)`
    /// returns the glyph's origin ON the baseline, relative to its line
    /// fragment, so baseline_y = lineFragment.minY + glyphLocation.y, and the
    /// attachment's top edge is that baseline minus (bounds.origin.y + height)
    /// — the same geometry TextKit itself uses when it draws an attachment.
    ///
    /// Returns nil when the caller should keep using `boundingRect` (block
    /// attachments, or a layout state too raw to trust).
    func inlineAttachmentOrigin(
        for attachment: NSTextAttachment,
        characterRange range: NSRange,
        glyphRange: NSRange,
        layoutManager: NSLayoutManager
    ) -> CGPoint? {
        guard let mathAttach = attachment as? MathAttachment, !mathAttach.isBlock else { return nil }
        guard glyphRange.length > 0 else { return nil }
        let glyphIndex = glyphRange.location
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineFragment.height > 0 else { return nil }
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let bounds = mathAttach.attachmentBounds(
            for: self.textContainer,
            proposedLineFragment: lineFragment,
            glyphPosition: glyphLocation,
            characterIndex: range.location
        )
        guard bounds.height > 0 else { return nil }
        // Vertical geometry, measured on-device (log [MathPos]/[MathBase],
        // 4 formulas × 17.49pt): for an ATTACHMENT glyph,
        // `location(forGlyphAt:)` does NOT return the text baseline the way it
        // does for a normal glyph — it returns the attachment's TOP-OF-ASCENT,
        // i.e. `baseline − bounds.origin.y` (bounds.origin.y is ≤0 for a
        // formula that descends below the baseline). Confirmed by the
        // invariant: `glyphLoc.y + bounds.origin.y` came out at exactly
        // 16.653 for all four formulas — one shared baseline — while
        // glyphLoc.y itself ranged 17.0–23.1.
        //
        // Hence the attachment's top edge is simply:
        //     top = glyphLoc.y − height
        // and the baseline lands `-bounds.origin.y` up from the image bottom,
        // which is exactly the descent captured at render time. Reading the
        // top directly also means we do NOT have to re-enter
        // `attachmentBounds` for the y (TextKit has already applied it).
        // `lineFragmentRect` / `location(forGlyphAt:)` are TEXT CONTAINER
        // coordinates; view frames are VIEW coordinates. UITextView offsets the
        // container by `textContainerInset` (this view sets top: 4 — the
        // T-dot-clip fix at init). `boundingRect(forGlyphRange:)`, which the
        // non-math attachments still use, comes back already offset, which is
        // why nothing needed this before; the glyph-level APIs do not.
        // Omitting it put every inline formula exactly 4pt too high — the
        // residual that survived the first pass of this fix.
        return CGPoint(
            x: lineFragment.minX + glyphLocation.x + bounds.origin.x + textContainerInset.left,
            y: lineFragment.minY + glyphLocation.y - bounds.height + textContainerInset.top
        )
    }

    func updateAttachmentViews() {
        // [AttachHotPath] Dedupe: when nothing relevant changed since the last
        // successful call AND the existing view map already covers every
        // attachment in storage, there is nothing to do — every branch in the
        // enumeration below would land in `reuse` and just re-set the same
        // frame. This skip eliminates the redundant 2nd/3rd UAV call per
        // BIG-CELL onscreen (window=nil → window-set chain that SwiftUI
        // UIHostingConfiguration triggers on cell reuse).
        if let storage = self.textStorage as? NSTextStorage,
           storage.length == lastUAVStorageLen,
           abs(self.textContainer.size.width - lastUAVWidth) < 0.5,
           !attachmentViewMap.isEmpty,
           attachmentViewMap.count == lastUAVViewCount {
            // Verify every attachment in storage is in the map, AND that
            // each TableAttachment's contentGeneration matches what we saw
            // at the last successful UAV pass.
            // [TableDedupBug] During streaming, a TableAttachment occupies a
            // single character in the attributed string; rows grow via
            // `update()` which mutates the attachment in place (object
            // identity preserved) but does NOT change `storage.length`.
            // The previous fingerprint (storageLen + width + viewCount) was
            // therefore satisfied on every streamed token, causing
            // `updateAttachmentViews` to return early without rebuilding
            // the TableScrollView. Visible symptom: the table cell stays
            // pinned at its first-row rendering even as cell height grows
            // to accommodate later rows the layout manager already knows
            // about — the "table is mostly empty space" report.
            var allMapped = true
            var currentTableGenSum: UInt64 = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { v, _, stop in
                guard let att = v as? NSTextAttachment else { return }
                if attachmentViewMap[ObjectIdentifier(att)] == nil {
                    allMapped = false
                    stop.pointee = true
                }
                if let table = v as? TableAttachment {
                    currentTableGenSum &+= table.contentGeneration
                }
            }
            if allMapped && currentTableGenSum == lastUAVTableGenSum {
                AppLogger(category: "AttachHotPath").info("[UAV][SKIP-DEDUPE] storageLen=\(storage.length) tcW=\(String(format: "%.0f", self.textContainer.size.width)) views=\(self.attachmentViewMap.count) tableGen=\(currentTableGenSum) — fingerprint match, nothing to do")
                return
            }
        }
        // [AttachHotPath] One log per call. If imageAttachmentCount > 0, this
        // is in the hot path during streaming.
        let imageAttachmentCount: Int = {
            guard let storage = self.textStorage as? NSTextStorage else { return 0 }
            var n = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { v, _, _ in
                if v is ImageAttachment { n += 1 }
            }
            return n
        }()
        if imageAttachmentCount > 0 {
            AppLogger(category: "AttachHotPath").info("[UAV] enter imgAttach=\(imageAttachmentCount) prevViews=\(self.attachmentViews.count) tcW=\(String(format: "%.0f", self.textContainer.size.width))")
        }
        let previousViewMap = attachmentViewMap
        var newViews: [UIView] = []
        var newViewMap: [ObjectIdentifier: UIView] = [:]
        var reusedIds: Set<ObjectIdentifier> = []

        guard let textStorage = self.textStorage as? NSTextStorage,
              let layoutManager = self.layoutManager as? MinisLayoutManager else {
            for view in attachmentViews { view.removeFromSuperview() }
            attachmentViews.removeAll()
            attachmentViewMap.removeAll()
            lastUAVStorageLen = -1
            lastUAVWidth = -1
            lastUAVViewCount = -1
            return
        }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let containerWidth = self.textContainer.size.width

        // Ensure TextKit has laid out all glyphs including trailing attachments.
        // UIKit may have clamped textContainer height to the current bounds, which
        // causes glyphs beyond that height to have zero bounding rects. Temporarily
        // expand to infinite height for both ensureLayout and boundingRect queries.
        let savedContainerHeight = self.textContainer.size.height
        if savedContainerHeight < CGFloat.greatestFiniteMagnitude {
            self.textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        // [T-attachment-zero-origin 2026-05-23] Invalidate glyph properties
        // (not just layout) for the full range before ensureLayout. Otherwise
        // TextKit retains stale glyphProp=controlCharacter cached during an
        // earlier zero/narrow textContainer pass, leaving attachment glyphs
        // with `boundingRect.origin == .zero` even after layout settles — the
        // attachment view then gets pinned at (0,0) overlaying the cell's
        // first text line. Reproducible on iPhone 15 Pro Max (tcW=370);
        // iPad (tcW=900) escapes because its width never narrowed enough
        // to trip the controlCharacter fallback. Pairs with the explicit
        // `view.frame.origin = boundingRect.origin` write below.
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.ensureLayout(forCharacterRange: fullRange)
        // NOTE: we restore savedContainerHeight AFTER enumeration, not here

        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            let existingView = previousViewMap[ObjectIdentifier(attachment)]
            // TextKit may return zero-width rects when layout is invalidated but
            // not yet recalculated (e.g. during refreshAttachmentViews after an
            // async image load). Fall back to the text container width so
            // attachment views are created at a usable size.
            if boundingRect.width < 1 || (containerWidth > 0 && boundingRect.width > containerWidth) {
                boundingRect.size.width = containerWidth
            }
            // [issue #117-4] Inline formulas: replace the line-level y with the
            // glyph-derived one (see inlineAttachmentOrigin). nil for every
            // other attachment kind, which keeps their existing behaviour.
            let inlineOrigin = self.inlineAttachmentOrigin(
                for: attachment, characterRange: range,
                glyphRange: glyphRange, layoutManager: layoutManager)

            let attachId = ObjectIdentifier(attachment)
            let view: UIView

            // For attachments that are cached (same object identity), reuse existing UIView
            // — but discard stale placeholders if the attachment has since loaded its content.
            if let existingView = previousViewMap[attachId] {
                var stale = false
                if let imageAttach = attachment as? ImageAttachment {
                    // File was rewritten since last load — force a rebuild
                    // so the new bitmap reaches the UIImageView inside.
                    if imageAttach.needsViewRebuild {
                        AppLogger(category: "AttachHotPath").info("[IMG][UAV] STALE-needsRebuild src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF)")
                        stale = true
                        imageAttach.needsViewRebuild = false
                    }
                    // Only (re-)arm onLoad and kick loading if the image isn't
                    // loaded yet. Otherwise a `NativeMediaImageCache` hit inside
                    // `beginLoadingIfNeeded` could fire `onLoad` synchronously
                    // and recurse back into `refreshAttachmentViews` during
                    // `updateAttachmentViews`. [AttachHang defensive guard]
                    if imageAttach.loadedImage == nil {
                        imageAttach.onLoad = { [weak self] in
                            DispatchQueue.main.async { self?.refreshAttachmentViews() }
                        }
                        imageAttach.beginLoadingIfNeeded()
                    } else if !stale {
                        // [T-img-placeholder-stuck-diag] The reported case: the
                        // bitmap IS loaded and the existing view is reused as-is
                        // (`stale == false`), so nothing rebuilds the subview. If
                        // that view was built while the image was still missing,
                        // it is a placeholder and stays one — height correct,
                        // content blank. Logged so a repro shows whether the
                        // reuse actually kept a placeholder view.
                        AppLogger(category: "AttachHotPath")
                            .info("[IMG][REUSE-LOADED] src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — image present, view NOT rebuilt")
                        imageAttach.onLoad = nil
                    } else {
                        // Clear any stale onLoad so a later invalidation path
                        // doesn't surface a synchronous refresh from an earlier
                        // incarnation of this attachment view.
                        imageAttach.onLoad = nil
                    }
                    if !stale && imageAttach.loadedImage != nil {
                        let hasImageView = existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                        if !hasImageView {
                            AppLogger(category: "AttachHotPath").info("[IMG][UAV] STALE-placeholderToLoaded src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — replacing placeholder with image view")
                            stale = true
                        }
                    }
                } else if let videoAttach = attachment as? VideoAttachment {
                    videoAttach.onLoad = { [weak self] in
                        DispatchQueue.main.async { self?.refreshAttachmentViews() }
                    }
                    videoAttach.beginLoadingIfNeeded()
                    if videoAttach.thumbnail != nil {
                        stale = !existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                    }
                } else if let mathAttach = attachment as? MathAttachment {
                    // [T-ios-math-invisible-dark-mode] The bitmap was dropped
                    // for a light/dark flip, so the overlay built from it holds
                    // the old (now invisible) glyph color. Must be checked
                    // BEFORE `beginRenderingIfNeeded` re-renders: once the new
                    // image lands, the `renderedImage != nil` branch below sees
                    // an existing UIImageView and concludes the view is fine.
                    if mathAttach.needsViewRebuild {
                        stale = true
                        mathAttach.needsViewRebuild = false
                    }
                    mathAttach.onLoad = { [weak self] in
                        self?.scheduleCoalescedMathRefresh()
                    }
                    mathAttach.beginRenderingIfNeeded()
                    if !stale, mathAttach.renderedImage != nil {
                        stale = !existingView.subviews.contains(where: { $0 is UIImageView || ($0.subviews.contains(where: { $0 is UIImageView })) })
                    }
                } else if let codeBlock = attachment as? CodeBlockAttachment {
                    // Code block with same object identity (content unchanged) — just track for future reuse
                    codeBlockViewCache[codeBlock.blockIndex] = existingView
                } else if let tableAttach = attachment as? TableAttachment {
                    // In-place content update during streaming markdown: the
                    // TableAttachment object identity is preserved (so the
                    // SelectableMarkdownView fast-path stays alive) but the
                    // rendered TableScrollView still holds the old rows.
                    // Force a rebuild so the user sees the new content.
                    //
                    // [T-ios-table-hscroll-stream-interrupt] EXCEPT while the
                    // user is actively scrolling THIS table horizontally.
                    // A rebuild removes the live TableScrollView from the
                    // hierarchy, which cancels the in-flight pan gesture —
                    // preservedScrollOffset keeps the position but not the
                    // gesture, so during streaming every chunk killed the drag
                    // after a few points. Defer instead: leave
                    // needsViewRebuild pending for the next streaming pass and
                    // arm a one-shot end-of-interaction callback so the
                    // rebuild still lands if the stream finishes mid-drag.
                    let liveScroll = TableAttachment.tableScrollView(in: existingView)
                    let sizeMismatch = abs(existingView.frame.size.height - boundingRect.height) > 1
                        || abs(existingView.frame.size.width - boundingRect.width) > 1
                    if let liveScroll,
                       liveScroll.isTracking || liveScroll.isDragging || liveScroll.isDecelerating {
                        if tableAttach.needsViewRebuild || sizeMismatch {
                            liveScroll.onInteractionEnded = { [weak self] in
                                DispatchQueue.main.async { self?.refreshAttachmentViews() }
                            }
                        }
                        // stale stays false — reuse the live view this pass.
                    } else if tableAttach.needsViewRebuild {
                        stale = true
                        tableAttach.needsViewRebuild = false
                    } else if sizeMismatch {
                        // [TableFrameFix] Even when `needsViewRebuild` is
                        // false (because the previous stale path already
                        // consumed it), the cached TableScrollView's inner
                        // stack/cells are sized against an out-of-date
                        // (typically smaller) layout. Trigger a rebuild
                        // whenever the existing view's size disagrees with
                        // the typesetter's boundingRect.
                        stale = true
                    }
                }

                if stale {
                    // Content loaded since last render — recreate the view
                    existingView.removeFromSuperview()
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger(category: "AttachHotPath").info("[IMG][UAV] RECREATE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — same attachment, but stale view → makeView")
                        view = imageAttach.makeView(width: boundingRect.width)
                    } else if let videoAttach = attachment as? VideoAttachment {
                        view = videoAttach.makeView(width: boundingRect.width)
                    } else if let mathAttach = attachment as? MathAttachment {
                        view = mathAttach.makeView(width: boundingRect.width)
                    } else if let tableAttach = attachment as? TableAttachment {
                        // Belt-and-suspenders capture of the live position
                        // right before teardown (onUserScroll normally keeps
                        // preservedScrollOffset current). Only when x > 0 —
                        // a transient 0 here (restore not yet applied) must
                        // not clobber the user's real preserved position.
                        if let oldScroll = TableAttachment.tableScrollView(in: existingView),
                           oldScroll.contentOffset.x > 0 {
                            tableAttach.preservedScrollOffset = oldScroll.contentOffset
                        }
                        // Re-wire onOpenURL on the new view (mirrors the new-attachment branch below).
                        tableAttach.onOpenURL = { [weak self] url in
                            if let coordinator = self?.delegate as? SelectableMarkdownView.Coordinator,
                               let openURL = coordinator.openURL {
                                openURL(url)
                            } else {
                                UIApplication.shared.open(url)
                            }
                        }
                        view = tableAttach.makeView(width: boundingRect.width)
                    } else {
                        view = existingView
                    }
                } else {
                    // Reuse: just update position and size
                    if let imageAttach = attachment as? ImageAttachment {
                        AppLogger(category: "AttachHotPath").info("[IMG][UAV] REUSE src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — view kept, only frame updated")
                    }
                    view = existingView
                }
                reusedIds.insert(attachId)
                view.frame = CGRect(origin: inlineOrigin ?? boundingRect.origin, size: view.frame.size)
            } else if let codeBlock = attachment as? CodeBlockAttachment {
                // New attachment object (content changed or first time).
                // Try to reuse the previous view at the same index via updateExistingView.
                if let previousView = codeBlockViewCache[codeBlock.blockIndex] {
                    codeBlock.updateExistingView(previousView)
                    view = previousView
                    // Trust the height computed by updateExistingView from the
                    // real code content. TextKit's boundingRect can be stale
                    // (glyph layout cached against a clamped textContainer
                    // height) and would otherwise collapse the view to the
                    // previous, smaller size.
                    view.frame = CGRect(
                        origin: boundingRect.origin,
                        size: CGSize(width: boundingRect.width, height: view.frame.size.height)
                    )
                } else {
                    view = codeBlock.makeView(width: boundingRect.width)
                }
                codeBlockViewCache[codeBlock.blockIndex] = view
            } else if let table = attachment as? TableAttachment {
                // Re-wire every render: the prior closure may have captured a
                // since-deallocated coordinator (`[weak self] → nil`), in which
                // case taps fell through to UIApplication.open and minis://
                // links failed silently. Closure assignment is cheap.
                table.onOpenURL = { [weak self] url in
                    if let coordinator = self?.delegate as? SelectableMarkdownView.Coordinator,
                       let openURL = coordinator.openURL {
                        openURL(url)
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
                view = table.makeView(width: boundingRect.width)
            } else if let thematicBreak = attachment as? ThematicBreakAttachment {
                view = thematicBreak.makeView(width: boundingRect.width)
            } else if let imageAttach = attachment as? ImageAttachment {
                AppLogger(category: "AttachHotPath").info("[IMG][UAV] NEW src=\(ImageAttachment.shortSrc(imageAttach.source)) ptr=\(attachId.hashValue & 0xFFFFFF) — no previous view (first render OR ObjectIdentifier changed) → makeView")
                // Same guard as the reused-attachment branch above: only arm
                // onLoad when the image isn't already loaded, so a memory-cache
                // hit during beginLoadingIfNeeded can't synchronously recurse
                // into refreshAttachmentViews. [AttachHang defensive guard]
                if imageAttach.loadedImage == nil {
                    imageAttach.onLoad = { [weak self] in
                        DispatchQueue.main.async { self?.refreshAttachmentViews() }
                    }
                    imageAttach.beginLoadingIfNeeded()
                } else {
                    imageAttach.onLoad = nil
                }
                view = imageAttach.makeView(width: boundingRect.width)
            } else if let videoAttach = attachment as? VideoAttachment {
                videoAttach.onLoad = { [weak self] in
                    DispatchQueue.main.async { self?.refreshAttachmentViews() }
                }
                videoAttach.beginLoadingIfNeeded()
                view = videoAttach.makeView(width: boundingRect.width)
            } else if let audioAttach = attachment as? AudioAttachment {
                view = audioAttach.makeView(width: boundingRect.width)
            } else if let mathAttach = attachment as? MathAttachment {
                mathAttach.onLoad = { [weak self] in
                    self?.scheduleCoalescedMathRefresh()
                }
                mathAttach.beginRenderingIfNeeded()
                view = mathAttach.makeView(width: boundingRect.width)
            } else {
                return
            }

            // [T-attachment-zero-origin 2026-05-23] Per-attachment retry: even
            // after the up-front invalidateGlyphs(fullRange), TextKit can still
            // return boundingRect.origin == .zero on the first query for an
            // attachment glyph in a narrow textContainer (iPhone tcW≈370 +
            // CJK paragraph). The diagnostic experiment showed a SECOND
            // invalidate+ensureLayout consistently returns the real origin
            // (e.g. (0, 99.4, 369x254)). Pinning a fresh attachment view at
            // (0,0) overlays the cell's first text line, and the
            // layoutSubviews fallback (line ~4677) refuses to move it
            // because both the cached origin and boundingRect.origin are
            // zero — so the only chance to land it correctly is right here.
            // [issue #117-4] Re-derive the inline origin after a retry: the
            // retry re-runs layout, so the value computed before it describes
            // a superseded glyph position.
            var resolvedInlineOrigin = inlineOrigin
            if boundingRect.origin == .zero {
                layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
                let retryGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let retry = layoutManager.boundingRect(forGlyphRange: retryGlyphRange, in: self.textContainer)
                if retry.origin != .zero {
                    boundingRect = retry
                    resolvedInlineOrigin = self.inlineAttachmentOrigin(
                        for: attachment, characterRange: range,
                        glyphRange: retryGlyphRange, layoutManager: layoutManager)
                }
            }
            view.frame.origin = resolvedInlineOrigin ?? boundingRect.origin
            if view.superview !== self {
                self.addSubview(view)
            }
            newViews.append(view)
            newViewMap[attachId] = view
        }

        // Remove views that are no longer present.
        // Views reused via codeBlockViewCache may appear under a new ObjectIdentifier
        // (content changed → new attachment), so also check newViewMap.values before removing.
        let newViewSet = Set(newViewMap.values.map { ObjectIdentifier($0) })
        for (id, view) in previousViewMap where !reusedIds.contains(id) && newViewMap[id] == nil {
            if newViewSet.contains(ObjectIdentifier(view)) { continue }
            view.removeFromSuperview()
        }

        // Restore textContainer height after all boundingRect queries are done.
        // Only when it actually changed — see layoutSubviews for why we avoid
        // redundant setSize: calls.
        if self.textContainer.size.height != savedContainerHeight {
            self.textContainer.size.height = savedContainerHeight
        }

        attachmentViews = newViews
        attachmentViewMap = newViewMap
        // [AttachHotPath] Refresh dedupe fingerprint so the next UAV call
        // can short-circuit when storage / width / view count are unchanged.
        if let storage = self.textStorage as? NSTextStorage {
            lastUAVStorageLen = storage.length
            // [TableDedupBug] Snapshot the current sum of TableAttachment
            // contentGeneration so the next dedupe check can detect a
            // streaming `update()` that didn't change storage.length.
            var sum: UInt64 = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { v, _, _ in
                if let table = v as? TableAttachment { sum &+= table.contentGeneration }
            }
            lastUAVTableGenSum = sum
        }
        lastUAVWidth = self.textContainer.size.width
        lastUAVViewCount = newViewMap.count
        // Force redraw so blockquote bars are painted with correct attachment
        // exclusion rects. draw() may fire before attachmentViews are populated,
        // causing bars to overlap tables on initial layout.
        setNeedsDisplay()
        #if DEBUG
        // [T-attachment-zero-origin] Capture immediately after attachment views
        // have been rebuilt — async image/video load completes also lands here
        // (via refreshAttachmentViews), so this is the most likely site where
        // table container frame gets reset to (0,0).
        MessageListSnapshotCollector.captureIfEnabled(
            from: self,
            trigger: "mtv.updateAttachmentViews",
            triggerDetail: String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )
        #endif
    }

    /// Re-layout attachment views after an async image/video load completes.
    ///
    /// [T-ios-reuse-cachewipe] Method B — burst coalescing. A cell holding N
    /// LaTeX formulas gets N separate completion callbacks, and each one
    /// re-typesets the whole storage and invalidates the cell size. Field logs
    /// showed 7 height rewrites inside 200ms oscillating 7733↔8066 without
    /// converging, because every commit landed while later formulas were still
    /// rendering. Coalesce a burst into a single commit on the next runloop
    /// turn: correctness is unaffected (the work is idempotent — it rebuilds
    /// from current state, it does not accumulate), and the cell now resizes
    /// once, after the burst, instead of once per formula.
    func refreshAttachmentViews() {
        guard !isCoalescingRefresh else {
            coalescedRefreshPending = true
            return
        }
        isCoalescingRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCoalescingRefresh = false
            let hadBurst = self.coalescedRefreshPending
            self.coalescedRefreshPending = false
            if hadBurst {
                AppLogger(category: "AttachHotPath").info("[REFRESH] burst coalesced — collapsed into a single updateAttachmentViews + invalidateCellSize")
            }
            self.performRefreshAttachmentViews()
        }
    }

    private func performRefreshAttachmentViews() {
        AppLogger(category: "AttachHotPath").info("[REFRESH] entry — async media-load callback fired (image/video/math finished loading); will run updateAttachmentViews + invalidateCellSize")
        guard window != nil else {
            // Detached from window — defer the refresh until re-attach so an
            // async image load that completed mid-recycle still grows the
            // cell. Replayed in `didMoveToWindow`. (T-multi-image-last
            // d8a51f73)
            pendingRefreshAfterWindowAttach = true
            return
        }
        // Re-entry guard: `invalidateCellSizeIfNeeded` below triggers
        // `collectionViewLayout.invalidateLayout()`, which can synchronously
        // re-enter `layoutSubviews` → `refreshAttachmentViews` if the cell's
        // width changed. [AttachHang defensive guard]
        if isRefreshingAttachments {
            reentryGuardHits &+= 1
            attachLogger.warning("[AttachHang][Refresh] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) window=\(self.window != nil) attachmentViews=\(self.attachmentViews.count)")
            return
        }
        isRefreshingAttachments = true
        defer { isRefreshingAttachments = false }
        // [T-table-zero-y 2026-05-23] When an async-loaded attachment (Video
        // thumbnail / Image) finishes loading, its attachmentBounds height
        // changes (e.g. Video 200pt placeholder → 231pt thumbnail-aware). We
        // need (a) the typesetter to re-query attachmentBounds and (b) the
        // cell to grow before the typesetter can fit the new layout.
        //
        // (a) invalidate the layout so ensureLayout will re-typeset.
        if let layoutManager = self.layoutManager as? MinisLayoutManager,
           let textStorage = self.textStorage as? NSTextStorage {
            let full = NSRange(location: 0, length: textStorage.length)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
            // [T-ios-math-height-measured-from-placeholders] Invalidating alone
            // is NOT enough — it only MARKS the range dirty. TextKit re-typesets
            // lazily, so the very next `systemLayoutSizeFitting` can still be
            // answered from the previous layout, i.e. with every formula still
            // contributing its 44pt (block) / 20pt (inline) PLACEHOLDER height
            // instead of its rendered size.
            //
            // Device evidence for this being the live path: on a build where the
            // scheduler logged `burst done rendered=42/42`, every [MemoWrite]
            // AFTER that line still recorded h=9501.5 while the text canvas
            // measured 11433.5 — a 1931.5pt (17%) deficit that no amount of
            // cache invalidation moved. On the field device the same shape was
            // 6166 vs 7154.7 across 31 display formulas: 988.7 / 31 = 31.9pt
            // short EACH, i.e. a rendered display formula (~76pt) being counted
            // as the 44pt placeholder.
            //
            // Forcing the re-typeset here means the measure that follows sees
            // the real `attachmentBounds`. Cost is bounded: this runs on the
            // coalesced async-media callback (at most one per runloop tick via
            // `scheduleCoalescedMathRefresh`), not per formula.
            if let container = self.textContainer as NSTextContainer? {
                layoutManager.ensureLayout(for: container)
            }
        }
        // (b) reset the sizeThatFits fingerprint so invalidateCellSizeIfNeeded
        // below cannot DEDUPE-SKIP. textStorage.length and measureWidth are
        // unchanged after Video.onLoad (the Video glyph is still 1 char), but
        // the attachment's intrinsic height changed — we MUST re-measure. The
        // cascade is: sizeThatFits → newH includes the larger Video → write
        // coordinator cache → collectionView self-sizing → cell grows →
        // live textView.bounds grows → tcH grows (UIKit clamps tcH to
        // bounds.h − inset) → subsequent layoutSubviews can fit the new
        // attachment height inside the container.
        lastSizedStorageLen = -1
        lastSizedWidth = -1
        lastComputedHeight = 0

        // [T-ios-refresh-teardown-guard] Only tear the attachment views down
        // when the CONTENT actually changed. Previously this ran
        // unconditionally on every async media-load callback.
        //
        // Why the unconditional teardown is harmful: with hundreds of formulas
        // each completing asynchronously (see `scheduleCoalescedMathRefresh`),
        // this path fires repeatedly — the field log shows 4 full
        // teardown+rebuild cycles inside ONE second. Each cycle destroys every
        // attachment view and recreates it, so any pass that lands while the
        // layout is mid-flight republishes every attachment at a freshly
        // computed origin. That is the window in which the reported overlap
        // (assistant header / tool capsule / attachment card drawn across the
        // prose) becomes possible.
        //
        // Why skipping the teardown is SAFE for the growth case — which is the
        // regression this must not cause ("image/video/math loads but the cell
        // never grows"):
        //   * `updateAttachmentViews` already REUSES and REPOSITIONS existing
        //     views through `previousViewMap` (see the `existingView` branches)
        //     and removes orphans at the end of that same pass. The teardown
        //     only DEFEATS that reuse by emptying the map first.
        //   * The three `lastSized*` resets above are untouched, so
        //     `invalidateCellSizeIfNeeded` below still cannot dedupe-skip and
        //     the cell still re-measures and grows. Growth comes from those
        //     resets plus the layoutManager invalidation, NOT from destroying
        //     subviews.
        //   * The UAV dedupe fingerprint is still reset, so the reposition pass
        //     runs in full rather than early-exiting.
        //
        // The discriminator is deliberately the same signal the rest of this
        // class already trusts: an async media load changes NEITHER
        // `storage.length` (the attachment is still a single
        // NSAttachmentCharacter) NOR the container width — only the
        // attachment's intrinsic size. So "same length, same width" means
        // "same content, a resource just finished loading" and the cheap
        // in-place path is correct. Anything else (content rewritten, width
        // changed, first pass) still takes the full teardown.
        let storageLen = (self.textStorage as? NSTextStorage)?.length ?? -1
        let widthNow = self.textContainer.size.width
        let sameContent = storageLen >= 0
            && storageLen == lastRefreshStorageLen
            && abs(widthNow - lastRefreshWidth) < 0.5
            && !attachmentViewMap.isEmpty
        lastRefreshStorageLen = storageLen
        lastRefreshWidth = widthNow

        if sameContent {
            AppLogger(category: "AttachHotPath").info("[REFRESH] in-place — same content (len=\(storageLen) w=\(String(format: "%.0f", widthNow))), repositioning \(self.attachmentViewMap.count) attachment view(s) without teardown")
        } else {
            // Remove old attachment subviews before clearing tracking state,
            // otherwise updateAttachmentViews sees an empty previousViewMap
            // and cannot clean up orphaned views — causing duplication/overlap.
            for view in attachmentViews { view.removeFromSuperview() }
            attachmentViews.removeAll()
            attachmentViewMap.removeAll()
            codeBlockViewCache.removeAll()
        }
        // Reset dedupe fingerprint so the next updateAttachmentViews fully runs.
        // Done in BOTH branches: the in-place path still needs the reposition
        // pass to run rather than early-exit on an unchanged fingerprint.
        lastUAVStorageLen = -1
        lastUAVWidth = -1
        lastUAVViewCount = -1
        updateAttachmentViews()
        // [T-ios-memo-key-ignores-render-state] Drop this block's memoised
        // height. This callback IS the moment an async attachment (math /
        // image) finished rendering and the block's true height changed, and it
        // was the one place on that path that never touched the memo — the
        // height stored before the render stayed authoritative and got seeded
        // back onto the cell on every later reuse.
        //
        // Belt-and-braces with the render-qualified key: the qualification
        // means the stale entry can no longer be FOUND, this makes sure it is
        // not merely orphaned in the dictionary. Cheap — one dictionary removal
        // on a callback that already does a full attachment reposition.
        if let cell = enclosingSelfSizingCell(),
           let cv = cell.superview as? UICollectionView,
           let layout = cv.collectionViewLayout as? MessageListLayout,
           let key = cell.contentKey {
            layout.invalidateMemo(forKey: SelfSizingCell.renderQualifiedKey(key, for: cell))
            layout.invalidateMemo(forKey: key)
        }
        // [T-ios-math-height-measured-from-placeholders] Drop the SwiftUI
        // representable's own size cache too.
        //
        // `sizeThatFits` memoises into `coord.cachedSizes[widthKey]`, keyed on
        // (markdown character count, width bucket) — and until now that cache
        // was only ever cleared on a WIDTH CHANGE. An async math render changes
        // the height while leaving both key components identical, so a height
        // computed from 44pt/20pt placeholders stayed servable forever and was
        // handed back on the next reuse.
        //
        // This is the same class of bug as the layout memo fixed in 22df168cf,
        // one level up: character count cannot see a formula rendering. It is
        // the route that survived that fix — measured on device as a cell still
        // reading 1462 against a 2089 canvas (+627) after scrolling, even
        // though the first display had been corrected to −4.5.
        if let coord = self.delegate as? SelectableMarkdownView.Coordinator {
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizeMarkdownCount = -1
        }
        // invalidateIntrinsicContentSize() alone is NOT enough for
        // UICollectionView self-sizing — it marks the intrinsic size dirty
        // but doesn't trigger preferredLayoutAttributesFitting. We must
        // go through invalidateCellSizeIfNeeded() which clears the
        // SelfSizingCell cache and invalidates the collection view layout.
        invalidateCellSizeIfNeeded()
    }

    /// [T-ios-memo-key-ignores-render-state] Walk up to the owning
    /// `SelfSizingCell`, if this text view is hosted in one.
    private func enclosingSelfSizingCell() -> SelfSizingCell? {
        var v: UIView? = self
        while let cur = v {
            if let cell = cur as? SelfSizingCell { return cell }
            v = cur.superview
        }
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
        // [T-scroll-cell-build-diag] Pairs with `mkv`: a text view that never
        // reaches a window was built only to be measured.
        if ScrollMetricsRecorder.shared.isEnabled {
            ScrollMetricsRecorder.shared.record(kind: "tvwin", a: window == nil ? 0 : 1,
                key: SelectableMarkdownView.diagId(self))
        }
        #endif
        if window == nil {
            // Release CALayer backing stores when removed from view tree
            layer.contents = nil
            for sub in attachmentViews {
                sub.layer.contents = nil
            }
        } else {
            // Replay any refresh dropped while we were detached. The
            // canonical case is the LAST image of a multi-image message
            // finishing its async load between scroll-out and scroll-in:
            // without this replay the cell stays at its pre-load size,
            // clipping the final image. Async so the rebind / collection
            // view's own layout pass settles first. (T-multi-image-last
            // d8a51f73)
            if pendingRefreshAfterWindowAttach {
                pendingRefreshAfterWindowAttach = false
                DispatchQueue.main.async { [weak self] in
                    self?.refreshAttachmentViews()
                }
            }
            // [T-ios-defer-debt-offscreen] Same replay for an unpaid HEIGHT
            // correction. The debt is created in `invalidateCellSizeIfNeeded`
            // when `deferSelfSizing` is active, and it has exactly two
            // consumers today:
            //
            //   1. `armDeferredRemeasureBackstop` — gives up after
            //      `maxDeferredRemeasureAttempts` (~6s of continuous drag) and
            //      explicitly hands the debt to "the settle hook";
            //   2. `settleAfterInteraction` — but that walks
            //      `cv.visibleCells` ONLY.
            //
            // So a cell that owes a correction and scrolls OFF-SCREEN before
            // the drag settles is seen by neither: the backstop has bowed out,
            // and settle cannot reach a view that is no longer a visible cell.
            // `deferredCorrectionPending` is cleared only where the debt is
            // actually paid (both sites are inside
            // `invalidateCellSizeIfNeeded`), so the flag correctly survives the
            // recycle — it just had nobody to act on it until now.
            //
            // This is the same shape as `pendingRefreshAfterWindowAttach`
            // directly above (T-multi-image-last d8a51f73), which already
            // replays a dropped async-load refresh on re-attach; the height
            // debt simply never got its counterpart. Async for the same reason:
            // let the rebind / collection view layout pass settle first.
            //
            // Cost on the happy path is one Bool test per re-attach.
            if deferredCorrectionPending {
                DispatchQueue.main.async { [weak self] in
                    self?.consumeDeferredCorrectionIfNeeded()
                }
            }
        }
    }
}
