//
//  SelectableMarkdownTextView+Layout.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, layout.
//
//  layoutSubviews: reacts to width changes (re-lays out attachments and asks
//  for a re-measure) and, in DEBUG, reports a table whose text overflows its
//  cell. The DEBUG signature it dedups on is stored in the core file.
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
    // MARK: Layout

    #if DEBUG

    /// [T-table-layout-true-width] DEBUG check for the 2026-09-29 overlap: a text
    /// view holding a table whose laid-out text ends below the bottom of its
    /// collection-view cell, i.e. the cell was sized for a different table
    /// layout and the next message draws over the tail. Logged once per
    /// (length, cell height, overflow) so a stable overflow is not repeated.
    private func reportTableCellShortIfNeeded() {
        let length = textStorage.length
        guard length > 0, window != nil else { return }
        var hasTable = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: []) { value, _, stop in
            if value is TableAttachment { hasTable = true; stop.pointee = true }
        }
        guard hasTable else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UICollectionViewCell) { ancestor = view.superview }
        guard let cell = ancestor as? UICollectionViewCell else { return }
        let used = layoutManager.usedRect(for: textContainer)
        let contentBottom = textContainerInset.top + used.maxY + textContainerInset.bottom
        let bottomInCell = convert(CGPoint(x: 0, y: contentBottom), to: cell).y
        let overflow = bottomInCell - cell.bounds.height
        guard overflow >= 1 else {
            lastTableCellShortSignature = nil
            return
        }
        let signature = "\(length):\(Int(cell.bounds.height)):\(Int(overflow))"
        guard signature != lastTableCellShortSignature else { return }
        lastTableCellShortSignature = signature
        let key = (cell as? SelfSizingCell)?.contentKey ?? "-"
        AppLogger(category: "CellSizing").warning(
            "[TableCellShort] key=\(key) cellH=\(String(format: "%.1f", cell.bounds.height)) "
            + "contentBottom=\(String(format: "%.1f", bottomInCell)) overflow=\(String(format: "%.1f", overflow)) "
            + "tvH=\(String(format: "%.1f", bounds.height)) tcW=\(String(format: "%.0f", textContainer.size.width)) storageLen=\(length)")
    }
    #endif

    override func layoutSubviews() {
        // TEMP(2026-05-13) — layoutSubviews slow-path probe. Most layout
        // work is fast; emit a direct-write line when a single
        // layoutSubviews pass takes >=50ms so a watchdog hang can be
        // attributed to a specific text view + its content.
        let layoutStart = CACurrentMediaTime()
        defer {
            let elapsed = (CACurrentMediaTime() - layoutStart) * 1000
            #if DEBUG
            // [T-scroll-cell-build-diag] TextKit layout + attachment views per pass.
            if elapsed >= 2, ScrollMetricsRecorder.shared.isEnabled {
                ScrollMetricsRecorder.shared.record(kind: "tvl", a: elapsed, b: Double(bounds.height),
                    key: SelectableMarkdownView.diagId(self),
                    note: "len=\(textStorage.length) win=\(window == nil ? 0 : 1) w=\(Int(bounds.width))")
            }
            #endif
            if elapsed >= 50 {
                let attrLen = self.textStorage.length
                let head = attrLen > 0
                    ? (self.textStorage.string as NSString)
                        .substring(to: min(40, attrLen))
                        .replacingOccurrences(of: "\n", with: "⏎")
                    : ""
                let ptr = String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
                LoggingManager.shared.writeRawLine(
                    category: "MarkdownLayout",
                    level: "WARN",
                    message: "[HangFix][LayoutSubviews] 💀 \(String(format: "%.0f", elapsed))ms tv=\(ptr) attrLen=\(attrLen) bounds=\(String(format: "%.0fx%.0f", self.bounds.width, self.bounds.height)) head=\"\(head)\""
                )
                LoggingManager.shared.flush()
            }
        }
        super.layoutSubviews()

        // UIKit clamps textContainer.size.height to the view's bounds during
        // layout. For a non-scrolling text view (isScrollEnabled=false), this
        // causes NSLayoutManager to exclude text that extends beyond the
        // current bounds, making trailing paragraphs invisible. Reset to
        // unconstrained so the full text is always laid out and drawn.
        //
        // Only assign when the current value is NOT already unconstrained.
        // Unconditional assignment goes through `-[NSTextContainer setSize:]`
        // → `textContainerChangedGeometry:` → `_invalidateLayoutForExtended
        // CharacterRange:` → `_fillLayoutHoleAtIndex:` even when the value
        // is identical, because UIKit doesn't equality-check size on
        // NSTextContainer. In the BoundsChangeFading path that's the
        // recursion seed for the watchdog hang seen in
        // Minis-2026-05-13-084827.ips: every layout pass re-triggers a full
        // fillLayoutHole on tables, which calls back into attachmentBounds,
        // which re-enters typesetting.
        if textContainer.size.height < CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        // [T-in-chat-search] Code block / table outlines follow the layout.
        if searchHighlightLayer != nil { updateSearchAttachmentOutlines() }

        #if DEBUG
        reportTableCellShortIfNeeded()
        #endif

        let currentWidth = textContainer.size.width

        // If the textContainer width changed (rotation, size class change, etc.),
        // fully rebuild attachment views so they get the new width via makeView(width:).
        // Use a 0.5pt threshold — matching the sizeThatFits-path guard in
        // `SelectableMarkdownView.sizeThatFits` — so sub-pt float jitter from
        // cell self-sizing doesn't repeatedly kick `refreshAttachmentViews`.
        let widthDelta = abs(currentWidth - lastLayoutWidth)
        if currentWidth > 0 && widthDelta > 0.5 {
            lastLayoutWidth = currentWidth
            // [RotationFix] On a real width change (rotation / size class), the
            // Coordinator's per-width size cache may hold a stale entry for
            // this width that was written before content settled (e.g. while
            // a table attachment was still computing). Clearing forces the
            // next sizeThatFits to recompute, which is required for the
            // trailing-paragraph truncation seen on rotation back to portrait.
            // Also reset the invalidateCellSizeIfNeeded fingerprint so it
            // doesn't short-circuit when the storage length is unchanged.
            if let coord = (self.delegate as? SelectableMarkdownView.Coordinator) {
                coord.cachedSizes.removeAll(keepingCapacity: true)
            }
            lastSizedStorageLen = -1
            lastSizedWidth = -1
            // [RotationTableFix] Reset every TableAttachment's cached layout so
            // `computeLayout`'s "reuse cached columnWidths at new width"
            // branch doesn't keep returning the old portrait-width columns
            // when the bubble has expanded for the new orientation. Without
            // this, the rendered table view sticks at the pre-rotation width.
            // Also invalidate the layoutManager for each attachment's char
            // range so ensureLayout asks for fresh `attachmentBounds`.
            if let storage = self.textStorage as? NSTextStorage, storage.length > 0 {
                var ranges: [NSRange] = []
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
                    if let table = value as? TableAttachment {
                        table.invalidateCachedLayoutForWidthChange()
                        ranges.append(range)
                    }
                }
                if !ranges.isEmpty, let lm = self.layoutManager as? MinisLayoutManager {
                    for r in ranges {
                        lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
                    }
                }
            }
            if !attachmentViews.isEmpty {
                refreshAttachmentViews()
            } else if hasUnrenderedAttachments {
                // Width just became available (e.g. UIHostingConfiguration finished layout)
                // but updateAttachmentViews was skipped earlier because width was 0.
                updateAttachmentViews()
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfNeeded()
            } else {
                // No attachments — still need a fresh measurement so the cell
                // resizes for the new width. Without this, attachment-free
                // messages keep their pre-rotation height and clip trailing
                // lines.
                invalidateIntrinsicContentSize()
                invalidateCellSizeIfNeeded()
            }
            return
        }

        // Width unchanged — just re-position attachment views so their origins
        // match the freshly computed glyph bounding rects.  This corrects the
        // first-load case where updateAttachmentViews() runs before sizeThatFits
        // has set the correct textContainer size.
        guard !attachmentViews.isEmpty,
              let layoutManager = self.layoutManager as? MinisLayoutManager,
              let textStorage = self.textStorage as? NSTextStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)

        // textContainer.size.height is already unconstrained (set above after
        // super.layoutSubviews), so boundingRect queries return correct positions
        // for all attachments including those near the end of the text.
        textStorage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let attachId = ObjectIdentifier(attachment)
            guard let view = attachmentViewMap[attachId] else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            // [T-attachment-zero-origin 2026-05-23] Mirror the per-attachment
            // retry from updateAttachmentViews. If TextKit returns
            // boundingRect.origin == .zero here (stale controlCharacter glyph
            // property), an invalidateGlyphs + ensureLayout consistently
            // yields the real origin on the second query.
            var inlineOrigin = self.inlineAttachmentOrigin(
                for: attachment, characterRange: range,
                glyphRange: glyphRange, layoutManager: layoutManager)
            if boundingRect.origin == .zero {
                layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))
                let retryGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let retry = layoutManager.boundingRect(forGlyphRange: retryGlyphRange, in: self.textContainer)
                if retry.origin != .zero {
                    boundingRect = retry
                    // [issue #117-4] Re-derive after the relayout — see the
                    // matching comment in updateAttachmentViews.
                    inlineOrigin = self.inlineAttachmentOrigin(
                        for: attachment, characterRange: range,
                        glyphRange: retryGlyphRange, layoutManager: layoutManager)
                }
            }
            // Only reposition if boundingRect has a valid origin (non-zero rect).
            // A zero rect means layout hasn't been computed yet — keep current position.
            // [issue #117-4] The gate stays keyed on boundingRect (the
            // "is layout ready" signal); only the value written changes.
            if boundingRect.origin != .zero || view.frame.origin == .zero {
                let target = inlineOrigin ?? boundingRect.origin
                if view.frame.origin != target {
                    view.frame.origin = target
                }
            }
        }
        #if DEBUG
        // [T-attachment-zero-origin] Capture render snapshot — disabled by default.
        let msgId = (self.delegate as? SelectableMarkdownView.Coordinator)?.renderer.messageId?.uuidString.prefix(8)
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: self,
            phase: "afterLayoutSubviews",
            messageId: msgId.map(String.init),
            isMeasureView: false
        )
        // Also: full message-list capture so we can see the entire collection
        // state at the same moment a cell's textView finished layout.
        MessageListSnapshotCollector.captureIfEnabled(
            from: self,
            trigger: "mtv.layoutSubviews",
            triggerDetail: String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()))
        )
        #endif
    }
}
