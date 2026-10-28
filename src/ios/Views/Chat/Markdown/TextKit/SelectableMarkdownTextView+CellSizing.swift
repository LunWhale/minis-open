//
//  SelectableMarkdownTextView+CellSizing.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, cell self-sizing.
//
//  invalidateCellSizeIfNeeded() and friends: when the content height changes
//  (streaming text, attachments finishing an async render, in-place table or
//  code growth), invalidate the host cell so the collection view re-measures
//  it - deduplicated on a fingerprint of storage length, width and attachment
//  generations, and deferred while the user is dragging. Its logger is stored
//  in the core file.
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
    // MARK: Cell Self-Sizing Invalidation

    /// Sum of `TableAttachment.contentGeneration` over every table attachment
    /// currently in `textStorage`, PLUS every `CodeBlockAttachment`'s
    /// `contentFingerprint`. Used as part of the cell-size dedup fingerprint
    /// so in-place attachment mutations defeat the early-exit even when
    /// textStorage.length is constant.
    ///
    /// [CodeGenDedup] Code blocks stream inside a single NSAttachmentCharacter
    /// exactly like tables: each chunk swaps in a fresh CodeBlockAttachment
    /// (new content hash) while storage length and width stay fixed, so the
    /// (storageLen, width, tableGenSum) fingerprint matched on every chunk and
    /// [SKIP-DEDUPE] pinned the host cell at its pre-stream height — the code
    /// view kept growing past the cell bounds and overlapped the neighbouring
    /// cell for the whole stream.
    private func currentTableGenerationSum() -> UInt64 {
        guard let storage = textStorage as? NSTextStorage, storage.length > 0 else { return 0 }
        var sum: UInt64 = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let table = value as? TableAttachment {
                sum &+= table.contentGeneration
            } else if let code = value as? CodeBlockAttachment {
                sum &+= UInt64(bitPattern: Int64(code.contentFingerprint))
            }
        }
        return sum
    }

    /// [T-ios-memo-key-ignores-render-state] How much vertical space this
    /// block's ASYNC attachments currently occupy, quantised to a stable
    /// integer.
    ///
    /// The height memo (`measuredHeightByContentKey`) is keyed on
    /// `block.content.count`. A LaTeX formula does not change that count when
    /// it renders — the markdown source `$P_A$` is byte-identical before and
    /// after MathJax turns it into a tall glyph — so a height measured while
    /// the formulas were still blank placeholders is stored under the SAME key
    /// as the finished layout, and is then seeded back onto the cell forever.
    /// Measured on device: cell frame 6166pt vs text canvas 7154.7pt, a 989pt
    /// (16%) deficit that never re-measured because the seed short-circuits
    /// `preferredLayoutAttributesFitting` before the real measure runs.
    ///
    /// Summing the rendered heights makes the key move exactly when the
    /// rendered geometry moves: 0 while every formula is an unrendered
    /// placeholder, non-zero and stable once they have all resolved. Rounded to
    /// whole points so sub-pixel jitter cannot churn the key.
    func asyncAttachmentRenderSignal() -> Int {
        guard let storage = textStorage as? NSTextStorage, storage.length > 0 else { return 0 }
        var total: CGFloat = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let math = value as? MathAttachment {
                total += math.renderedSize.height
            } else if let img = value as? ImageAttachment {
                // [T-ios-image-squish-memo-blind] Use the LOADED bitmap's
                // intrinsic height, not `img.bounds.height`. `bounds` is
                // NSTextAttachment's stored property — ImageAttachment only
                // overrides the attachmentBounds(for:) METHOD and never writes
                // the property, so it is permanently .zero and every image
                // contributed 0 here regardless of load state. The memo key
                // therefore never changed when images finished loading, and
                // MessageListLayout kept serving the height measured while the
                // images were still 200pt placeholders — the multi-image
                // "text overlaps the pictures" squish, the exact analogue of
                // the math bug this signal was built to fix (22df168cf).
                // The intrinsic height is 0 until loaded, non-zero and stable
                // once the bitmap is in (a later re-downsample changes it and
                // costs one extra re-measure, which is harmless).
                total += img.loadedImage?.size.height ?? 0
            } else if let video = value as? VideoAttachment {
                // [T-ios-video-squish] Same signal contract as images: the
                // thumbnail's intrinsic height is 0 until AVAssetImageGenerator
                // finishes, stable non-zero after. Without this branch the memo
                // key never moved when a video thumbnail landed — the exact
                // signal blindness 0d34dfa6c fixed for images, and worse here
                // because thumbnail generation is slower than image decode.
                total += video.thumbnail?.size.height ?? 0
            } else if let table = value as? TableAttachment {
                // [T-table-layout-true-width] Tables were missing from this
                // signal, so the memo key read `:r0` for every table cell and a
                // height measured with one table layout (the 2026-09-29 report:
                // 1690pt against a 402pt-planned table) was seeded back — and
                // the real measure skipped — after the table was laid out
                // differently. Add the height of the table's persisted (render-
                // width) layout, 0 before it has one: a changed table layout
                // changes the key, so the cell measures again.
                total += table.persistedLayoutHeight
            }
        }
        return Int(total.rounded())
    }

    func invalidateCellSizeIfNeeded() {
        guard textContainer.size.width > 1 else {
            return
        }
        // Re-entry guard: `cv.collectionViewLayout.invalidateLayout()` below
        // can synchronously re-enter `preferredLayoutAttributesFitting` →
        // `sizeThatFits` → `invalidateCellSizeIfNeeded`. Without this guard
        // a height that is still settling can spin for the full watchdog
        // window. [AttachHang defensive guard]
        if isInvalidatingCellSize {
            reentryGuardHits &+= 1
            cellSizeLogger.warning("[AttachHang][CellSize] RE-ENTRY BLOCKED hits=\(self.reentryGuardHits) tcW=\(String(format: "%.0f", self.textContainer.size.width)) lastH=\(String(format: "%.1f", self.lastComputedHeight))")
            return
        }
        // Fingerprint early-exit: when textStorage and width are unchanged
        // from the last successful measurement, the height can't have moved.
        // The full path below pays for `sizeThatFits` (~2-4ms on long
        // attributed strings) before discovering NOOP. Skipping here saves
        // that cost on every repeated call (SwiftUI reuse / didMoveToWindow
        // bursts each trigger an UAV chain that includes this).
        // [JitterFix] Measure at the actual render width (bounds.width) when
        // available. textContainer.size.width can be transiently set to the
        // outer-cell probe width (~402) by SwiftUI's preferredLayoutAttributes
        // pass — measuring at that wrong width would write a 23pt-too-small
        // height into lastComputedHeight, producing the streaming spike.
        let measureWidth: CGFloat = bounds.width > 1 ? bounds.width : textContainer.size.width
        // [TableGenDedup] Compute the sum of every TableAttachment's generation
        // counter. Streaming tables mutate rows in place without changing
        // textStorage.length, so the (storageLen, width) fingerprint alone
        // can't detect those mutations and would short-circuit the remeasure
        // — visible as a streaming table rendering only its first column
        // until the entire message stops streaming.
        let tableGenSum = currentTableGenerationSum()
        // [T-ios-defer-retry-never-consumed] A pending deferred correction must
        // NOT be swallowed by the fingerprint. The skip path left
        // `lastComputedHeight` at the stale value on purpose, so "fingerprint
        // matches" here does not mean "height is right" — it means the content
        // stopped changing (stream ended) while the height was still wrong.
        // Fall through to the real `sizeThatFits` so the correction can land.
        if lastSizedStorageLen >= 0,
           !deferredCorrectionPending,
           textStorage.length == lastSizedStorageLen,
           abs(measureWidth - lastSizedWidth) < 0.5,
           tableGenSum == lastSizedTableGenSum,
           lastComputedHeight > 0 {
            cellSizeLogger.info("[invalidateCell][SKIP-DEDUPE] storageLen=\(textStorage.length) measureW=\(String(format: "%.0f", measureWidth)) tcW=\(String(format: "%.0f", textContainer.size.width)) lastH=\(String(format: "%.1f", lastComputedHeight)) tableGen=\(tableGenSum) — fingerprint match, skipping sizeThatFits")
            return
        }
        isInvalidatingCellSize = true
        defer { isInvalidatingCellSize = false }
        let newHeight = sizeThatFits(CGSize(width: measureWidth, height: .greatestFiniteMagnitude)).height
        // sizeThatFits clamps textContainer.size.height — restore it (only
        // when actually clamped, to avoid a redundant setSize: → fillLayoutHole).
        if textContainer.size.height < CGFloat.greatestFiniteMagnitude {
            textContainer.size.height = CGFloat.greatestFiniteMagnitude
        }
        let previousHeight = lastComputedHeight
        if abs(newHeight - previousHeight) <= 1 {
            // Unchanged — refresh the fingerprint so subsequent calls can
            // SKIP-DEDUPE, exactly as before.
            lastSizedStorageLen = textStorage.length
            lastSizedWidth = measureWidth
            lastSizedTableGenSum = tableGenSum
            // [T-ios-defer-retry-never-consumed] Do NOT clear
            // `deferredCorrectionPending` here. Reaching this branch means the
            // TEXT VIEW's own height is stable, but the debt we owe is on the
            // HOST CELL: the skip path returned before `cell.clearCachedHeight()`
            // + `invalidateLayout()`, so SelfSizingCell may still be serving the
            // pre-correction height even though this view now measures fine.
            // Clearing here is what made the first attempt at this fix a no-op —
            // the 0.6s backstop timer landed in this branch ~250ms before settle,
            // dropped the flag, and every subsequent `[SettleConsume]` reported
            // `pending=0` while the cell stayed wrong (device trace 11:25:50).
            // The debt is settled only where the correction is actually applied.
            if deferredCorrectionPending {
                // Clear the debt ONLY if the correction actually landed.
                // `applyCellCorrection` refuses while deferSelfSizing is open,
                // because its `invalidateLayout()` mid-scroll is exactly what
                // 879ce867's skip guards against. When it refuses, keep the flag
                // so the settle hook consumes it the moment the window closes —
                // the same "wait, don't drop it" contract the backstop timer
                // follows. Dropping it here regardless is what made the first
                // version of this fix a silent no-op.
                if applyCellCorrection() {
                    cellSizeLogger.info("[invalidateCell] deferred debt CONSUMED — view height stable at \(String(format: "%.1f", newHeight)), cell invalidated")
                    deferredCorrectionPending = false
                } else {
                    cellSizeLogger.info("[invalidateCell] deferred debt HELD — view height stable at \(String(format: "%.1f", newHeight)) but deferSelfSizing still open; leaving it to settle")
                    armDeferredRemeasureBackstop()
                }
            }
            return
        }
        let delta = newHeight - previousHeight

        // [T-ios-lastcell-clip-defer-lost] Height genuinely moved. Decide the
        // defer-skip BEFORE consuming the measurement. The old order refreshed
        // the dedup fingerprint + lastComputedHeight first and THEN bailed on
        // deferSelfSizing / first-measure — after which every later call hit
        // [SKIP-DEDUPE] and the correction could never fire again. Combined
        // with SelfSizingCell's unbounded same-width height cache (which never
        // re-enters SwiftUI on its own), the cell stayed frozen at the
        // too-short first-commit height and clipsToBounds cropped the tail —
        // the "last message truncated mid-sentence, survives restart" repro
        // (A71D8A0D: CTFramesetter first-commit under-measured the 839-char
        // CJK block by ~1 line vs TextKit's later authoritative measure; the
        // cold-open auto-scroll glide kept deferSelfSizing=true at exactly the
        // moment this correction tried to run).
        let cvOpt = findCollectionView()
        let layout = cvOpt?.collectionViewLayout as? MessageListLayout
        let isDeferred = layout?.deferSelfSizing ?? false

        // When deferSelfSizing is active (user scrolling), skip the full layout
        // invalidation — it causes contentSize changes that push the streaming
        // cell into other cells during deceleration. The height change will be
        // picked up naturally via preferredLayoutAttributesFitting when the
        // deferred heights are flushed after scrolling ends.
        //
        // EXCEPTION: image-attachment placeholder→loaded transition. On cold
        // enter the auto `scrollToBottom` triggers a decel (deferSelfSizing=true)
        // *while* the inline images are still placeholders at 200pt. When an
        // image resolves from the memory cache (synchronous) and refreshes
        // attachments, sizeThatFits now returns the real height (e.g. 327pt).
        // If we skip invalidation here, the cell stays frozen at the 240pt
        // placeholder height and the UIImageView — which was laid out at the
        // correct 280pt by updateAttachmentViews — is clipped by the cell's
        // bounds, producing the "bottom truncated" symptom. The condition is
        // narrow: image attachment present AND a large growth (>30pt). This
        // preserves the existing defer behaviour for streaming text growth.
        // [AttachHang image-attachment defer escape]
        if isDeferred {
            // [T-ios-video-squish] Videos join the escape: a thumbnail landing
            // mid-scroll produces the same placeholder→real large delta as an
            // image load, and it used to be swallowed here (image-only check),
            // leaving the cell pinned short with content overlapping the
            // thumbnail. Video windows are longer (AVAssetImageGenerator),
            // so mid-scroll completion is MORE likely, not less.
            let cellHasGrowableMediaAttachment: Bool = {
                var found = false
                textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length), options: []) { value, _, stop in
                    if value is ImageAttachment || value is VideoAttachment {
                        found = true
                        stop.pointee = true
                    }
                }
                return found
            }()
            let isLargeGrowth = delta > 30
            // [T-stream-end-scroll-overlap] Where the host cell sits relative
            // to the viewport right now. Computed only on this deferred path
            // (a scroll is in progress AND the height moved), never per token.
            let placement = Self.viewportPlacement(of: findCell(), in: cvOpt)
            if cellHasGrowableMediaAttachment && isLargeGrowth {
                cellSizeLogger.info("[AttachHang][CellSize] ALLOW through defer — media attachment placeholder→loaded growth prev=\(String(format: "%.1f", previousHeight))→new=\(String(format: "%.1f", newHeight)) delta=\(String(format: "%+.1f", delta))")
                // Fall through to the normal invalidate path below.
            } else if delta > 0, placement.position == "inside" {
                // [T-stream-end-scroll-overlap] A VISIBLE cell grew while the
                // user is scrolling. Typical trigger: the reply finishes
                // mid-scroll, the text held back during the scroll lands in
                // one go, and the text view becomes hundreds of points taller
                // than its frozen cell (device log 2026-10-05 22:37:32: cell
                // held 2224.7pt, content 2680pt, for ~1.4s until settle). The
                // hosting view overflows its frame and draws over the
                // neighbouring cells — the overlap users see.
                //
                // Growth is let through, exactly like the media escape above,
                // and for the same reason MessageListLayout's
                // shouldInvalidateLayout already lets growth through during
                // deferSelfSizing: a cell taller than its frame overlaps its
                // neighbours. Growth extends the cell downward from its own
                // top, so what the user is reading above it does not move.
                // Shrinks stay deferred (they only leave a temporary gap), and
                // so does growth of a cell above or below the viewport: there
                // the overlap is not visible, and a cell above would push the
                // visible content mid-glide with no offset compensation.
                cellSizeLogger.info("[DeferGrowth] ALLOW visible growth through defer — prev=\(String(format: "%.1f", previousHeight))→new=\(String(format: "%.1f", newHeight)) delta=\(String(format: "%+.1f", delta)) \(placement.summary) owedBefore=\(self.deferredCorrectionPending)")
                // Fall through to the normal invalidate path below.
            } else {
                // [T-stream-end-scroll-overlap] Record why a correction is
                // being parked, so a remaining overlap report can be matched
                // to the cell and its position at that moment.
                cellSizeLogger.info("[DeferGrowth] HOLD — delta=\(String(format: "%+.1f", delta)) \(placement.summary) reason=\(delta > 0 ? "growth-not-visible" : "shrink")")
                // [T-ios-lastcell-clip-defer-lost] Return WITHOUT touching the
                // fingerprint / lastComputedHeight / coord cache — the
                // correction is NOT consumed, so the next call re-measures and
                // retries. Streaming cost is unchanged: token growth mutates
                // storage length, which already defeats the fingerprint today.
                // Arm one guaranteed post-settle retry in case no further
                // measure call arrives after the glide ends.
                cellSizeLogger.info("[invalidateCell] SKIPPED — deferSelfSizing active (correction NOT consumed, delta=\(String(format: "%+.1f", delta)); will retry)")
                // [T-ios-defer-retry-never-consumed] Remember that a real
                // correction is owed. The authoritative consumer is
                // `consumeDeferredCorrectionIfNeeded()`, invoked the moment
                // `settleAfterInteraction` clears deferSelfSizing. The timer is
                // only a backstop for the mid-drag window (stream finishes while
                // the finger is still down), and it re-arms itself while that
                // window stays open — see armDeferredRemeasureBackstop.
                // [T-ios-defer-debt-offscreen] Mark WHEN the debt was created so
                // an unpaid one can be attributed later. `wasPending` shows the
                // debt is being re-owed (an earlier correction was still
                // outstanding), which is the signature of a long drag over
                // async-rendering content.
                let wasPending = deferredCorrectionPending
                cellSizeLogger.info("[DeferDebt] OWED delta=\(String(format: "%+.1f", delta)) attached=\(self.window != nil) reOwed=\(wasPending)")
                deferredCorrectionPending = true
                armDeferredRemeasureBackstop()
                return
            }
        }

        // Commit the measurement: fingerprint + authoritative height + the
        // Coordinator's sizeThatFits width-bucket cache. Streaming code blocks /
        // tables grow inside a single NSAttachmentCharacter, so `textLen` stays
        // fixed and the `(width, textLen)`-keyed cache would otherwise return
        // the previous (smaller) height, pinning the cell. We already paid for
        // a real `sizeThatFits` here; sharing the result costs zero additional
        // TextKit work and lets the next `preferredLayoutAttributesFitting`
        // probe HIT the fresh value without another full relayout (the 8s hang
        // `d0d3ffc` fixed).
        lastSizedStorageLen = textStorage.length
        lastSizedWidth = measureWidth
        lastSizedTableGenSum = tableGenSum
        lastComputedHeight = newHeight
        // [T-ios-defer-retry-never-consumed] The correction is being committed
        // for real here, so the debt is settled. Clearing it re-arms the
        // fingerprint early-exit for subsequent calls (no permanent extra cost).
        if deferredCorrectionPending {
            deferredCorrectionPending = false
            cellSizeLogger.info("[invalidateCell] DEFERRED CORRECTION CONSUMED newH=\(String(format: "%.1f", newHeight)) delta=\(String(format: "%+.1f", delta))")
        }
        if let coord = self.delegate as? SelectableMarkdownView.Coordinator {
            // [JitterFix] Key by render width (measureWidth), matching the
            // SwiftUI sizeThatFits cache key. Using textContainer.size.width
            // here would insert under whichever stale probe width was last
            // committed, missing future render-width cache lookups.
            // [T-ios-lastcell-clip-defer-lost] REPLACE the whole bucket dict
            // instead of upserting one key: stale near-width buckets (±2pt
            // probe rounding) written by the CTFramesetter fast path would
            // otherwise be copied back over this authoritative TextKit height
            // by sizeThatFits' near-width reuse, re-pinning the cell short.
            let widthKey = Int(measureWidth.rounded())
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizes[widthKey] = newHeight
            // [T-ios-lastcell-clip-defer-lost] Key the cache generation by the
            // RAW MARKDOWN length — sizeThatFits gates hits on
            // `bindingLen == cachedSizeMarkdownCount`, and bindingLen is the
            // raw `markdown` binding's NSString length. The old write used
            // textStorage.length (the RENDERED length), which never equals
            // bindingLen once markdown syntax is stripped — so this
            // authoritative TextKit height was permanently unreachable and the
            // correction re-measure fell back to the CTFramesetter path (the
            // short height), re-pinning the cell.
            let bindingLenForKey = rawMarkdown.isEmpty
                ? textStorage.length
                : (rawMarkdown as NSString).length
            coord.cachedSizeMarkdownCount = bindingLenForKey
        }

        // First measurement (previousHeight == 0): normally the layout queries
        // the cell naturally during the initial pass and no invalidation is
        // needed. BUT if the host cell has ALREADY committed a conflicting
        // height (cold-load: the SwiftUI sizeThatFits probe committed a
        // CTFramesetter-measured height that disagrees with this TextKit
        // measure by a line), that commit is frozen by SelfSizingCell's
        // same-width cache and MUST be invalidated here — this is the only
        // correction point. Threshold 8pt: above the ~4pt vertical padding
        // delta between the markdown view and its cell, below one text line.
        if previousHeight <= 0 {
            guard let cell = findCell() as? SelfSizingCell,
                  cell.bounds.height > 4,
                  abs(cell.bounds.height - newHeight) > 8 else { return }
            cellSizeLogger.info("[invalidateCell] FIRST-MEASURE CORRECTION cellH=\(String(format: "%.1f", cell.bounds.height)) newH=\(String(format: "%.1f", newHeight)) — cell committed a conflicting height, invalidating")
        }

        // Clear SelfSizingCell's cached height so preferredLayoutAttributesFitting
        // re-measures instead of returning the stale cached value. Without this,
        // the precalcHeight-based initial measurement (from applySnapshot) gets
        // locked in, even though the actual TextKit layout produced a different height.
        if let cell = findCell() as? SelfSizingCell {
            cell.clearCachedHeight()
        }

        cvOpt?.collectionViewLayout.invalidateLayout()
    }

    /// [T-ios-defer-retry-never-consumed] Backstop for the settle-driven
    /// consumer, and the reason the 0.6s timer is kept rather than deleted.
    ///
    /// `deferSelfSizing` has exactly one setter — `scrollViewWillBeginDragging`
    /// — and both exits of that gesture (`didEndDragging(willDecelerate:false)`
    /// and `didEndDecelerating`) run `settleAfterInteraction`, which clears the
    /// flag and immediately calls `consumeDeferredCorrectionIfNeeded()`. So the
    /// event path covers the normal case. What it does NOT cover is the window
    /// while the finger is still down: if the stream finishes mid-drag, the
    /// correction would otherwise wait for the user to lift their finger.
    ///
    /// The original timer (879ce867) fired exactly once. If it landed while the
    /// drag was still in progress it hit the same skip branch, cleared
    /// `pendingDeferredRemeasure`, and never re-armed — so the backstop silently
    /// gave up precisely when it was needed. Re-schedule instead while the
    /// window is still open, bounded so a stuck flag cannot tick forever.
    private func armDeferredRemeasureBackstop(attempt: Int = 0) {
        guard !pendingDeferredRemeasure else { return }
        guard attempt < Self.maxDeferredRemeasureAttempts else {
            cellSizeLogger.info("[invalidateCell] backstop GAVE UP after \(attempt) attempts — leaving the debt to the settle hook")
            return
        }
        pendingDeferredRemeasure = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.pendingDeferredRemeasure = false
            // Debt already paid (settle got there first, or a natural measure
            // call consumed it) — nothing to do.
            guard self.deferredCorrectionPending else { return }
            let stillDeferred = (self.findCollectionView()?.collectionViewLayout
                as? MessageListLayout)?.deferSelfSizing ?? false
            if stillDeferred {
                // Window still open: re-measuring now would just hit the same
                // skip branch. Wait another interval instead of giving up.
                self.armDeferredRemeasureBackstop(attempt: attempt + 1)
                return
            }
            self.invalidateCellSizeIfNeeded()
        }
    }

    /// [T-stream-end-scroll-overlap] Where `cell` sits relative to the
    /// collection view's viewport: "above" / "inside" / "below", or "unknown"
    /// when the view is not hosted in a cell (yet). `summary` is a log-ready
    /// string with the numbers behind the decision, plus the scroll phase.
    static func viewportPlacement(of cell: UICollectionViewCell?, in cv: UICollectionView?)
        -> (position: String, summary: String) {
        guard let cell, let cv else { return ("unknown", "pos=unknown cell=\(cell != nil) cv=\(cv != nil)") }
        let frame = cell.frame
        let viewport = cv.bounds
        let position: String
        if frame.maxY <= viewport.minY {
            position = "above"
        } else if frame.minY >= viewport.maxY {
            position = "below"
        } else {
            position = "inside"
        }
        let phase = cv.isDecelerating ? "decel" : (cv.isTracking ? "drag" : "idle")
        let idx = cv.indexPath(for: cell)?.item ?? -1
        let summary = "pos=\(position) idx=\(idx) phase=\(phase) cellY=\(String(format: "%.0f", frame.minY)) cellH=\(String(format: "%.1f", frame.height)) viewport=\(String(format: "%.0f", viewport.minY))..\(String(format: "%.0f", viewport.maxY))"
        return (position, summary)
    }

    /// Bound on `armDeferredRemeasureBackstop` re-arming (~6s of drag). Past
    /// that the settle hook is the only consumer, which is correct: a drag that
    /// long always ends in `settleAfterInteraction`.
    private static let maxDeferredRemeasureAttempts = 10

    /// [T-ios-defer-retry-never-consumed] Drop the host cell's frozen height and
    /// ask the layout to re-flow. Same two statements the normal commit path
    /// ends with, extracted so the "view height already stable, but the CELL is
    /// still stale" case can apply the correction without pretending to
    /// re-measure. That case is real: after a skip, SwiftUI may re-render the
    /// text view to the right height on its own while `SelfSizingCell` keeps
    /// serving the pre-correction value from its width-matched cache (which
    /// b4268586 made unbounded), so the cell never asks again.
    ///
    /// Returns false when the deferSelfSizing window is still open, in which
    /// case NOTHING was applied and the caller must keep the debt.
    ///
    /// The guard lives here rather than at the call site so it covers every
    /// caller, including future ones. It is not optional politeness: this method
    /// ends in `invalidateLayout()`, and 879ce867's skip exists precisely because
    /// a full layout invalidation mid-scroll "causes contentSize changes that
    /// push the streaming cell into other cells during deceleration" — i.e.
    /// running it inside the window can produce the very overlap this whole
    /// change set is removing. The `abs(delta) <= 1` caller sits ~40 lines ABOVE
    /// the `isDeferred` gate in `invalidateCellSizeIfNeeded`, so it does not
    /// inherit that protection, and `updateUIView` calls into that path on every
    /// SwiftUI re-render — including while a finger is down mid-stream.
    @discardableResult
    private func applyCellCorrection() -> Bool {
        let deferred = (findCollectionView()?.collectionViewLayout
            as? MessageListLayout)?.deferSelfSizing ?? false
        guard !deferred else { return false }
        if let cell = findCell() as? SelfSizingCell {
            cell.clearCachedHeight()
        }
        findCollectionView()?.collectionViewLayout.invalidateLayout()
        return true
    }

    /// [T-ios-defer-retry-never-consumed] Consume a correction that was skipped
    /// during a deferSelfSizing window. Called by the message list's Coordinator
    /// at settle, right after it sets `deferSelfSizing = false` — the first
    /// moment the correction can actually be applied.
    ///
    /// This is what makes the "will retry" promise real. The 0.6s timer alone
    /// could not keep it: it fires on a fixed delay that may still land inside
    /// the drag, and even when it lands correctly the fingerprint early-exit
    /// swallows it once the stream has stopped changing the text storage.
    /// `deferredCorrectionPending` bypasses that early-exit, so this call
    /// re-measures for real.
    func consumeDeferredCorrectionIfNeeded() {
        guard deferredCorrectionPending else { return }
        // [T-ios-defer-debt-offscreen] `attached` distinguishes the two
        // consumers in the log: settle (window != nil, the cell was visible)
        // vs the new re-attach replay (this view just came back on screen
        // still owing a correction — the case that previously had no consumer).
        cellSizeLogger.info("[DeferDebt] CONSUME — paying deferred correction attached=\(self.window != nil)")
        invalidateCellSizeIfNeeded()
    }
}
