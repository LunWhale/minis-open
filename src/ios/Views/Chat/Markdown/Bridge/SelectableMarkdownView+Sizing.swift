//
//  SelectableMarkdownView+Sizing.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Bridge - SelectableMarkdownView, height measurement.
//
//  sizeThatFits(_:uiView:context:) answers SwiftUI's height queries: cached per
//  width in the Coordinator, measured on a separate text view when the binding
//  is ahead of what the live view shows, with a CoreText fast path
//  (ctFramesetterHeight) for attachment-free text.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownView {
    /// [T-ios-longreply-boundingRect-watchdog] Measure attributed-string height with
    /// bare CoreText `CTFramesetter` instead of `NSAttributedString.boundingRect`
    /// (which wraps TextKit1 / `NSLayoutManager` and has near-O(n²) cost in line
    /// count — 100 lines ≈ 1.7s, 1000 lines ≈ 17.7s, the 8.7–10.8s SLOW MEASUREs
    /// behind the 0x8BADF00D watchdog kills). `CTFramesetter` uses the same CoreText
    /// typesetter foundation with no TextKit wrapper: 100 lines ≈ 24ms (71×), 1000
    /// lines ≈ 24ms (738×), and it barely grows with line count.
    ///
    /// Only valid for **attachment-free** text — `CTFramesetter` cannot see the
    /// custom `attachmentBounds` of TableAttachment/CodeBlockAttachment/ImageAttachment
    /// (those need TextKit to invoke the line-fragment typesetter), so callers MUST
    /// gate on "no attachments" before using this. Returns the text height only;
    /// callers add `textContainerInset` (top+bottom) to match `UITextView.sizeThatFits`.
    static func ctFramesetterHeight(for attrStr: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attrStr.length > 0, width > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        let constraint = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),   // 0 length = whole string
            nil,
            constraint,
            nil
        )
        return ceil(size.height)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableMarkdownTextView, context: Context) -> CGSize? {
        #if DEBUG
        // [T-scroll-jitter-fold-diag] Slow markdown measurements.
        let sizingStart = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - sizingStart) * 1000
            if ms >= 2, ScrollMetricsRecorder.shared.isEnabled {
                ScrollMetricsRecorder.shared.record(kind: "mdv", a: ms, b: Double(proposal.width ?? -1),
                    src: "size", note: "chars=\(uiView.textStorage.length)")
            }
        }
        #endif
        let width = proposal.width ?? UIScreen.main.bounds.width
        // [T-table-layout-true-width] With no proposed width this measures at the
        // screen width, and once the view is laid out a proposal that differs
        // from its bounds is SwiftUI's outer-width probe ([JitterFix]). Neither
        // is the width the text renders at, so tables laid out during this call
        // must not persist a layout for it — that 402pt layout used to be reused
        // at the 369pt text column and pin the cell ~50pt short.
        let renderWidthNow = uiView.bounds.width
        let isNonRenderWidth = proposal.width == nil
            || (renderWidthNow > 0 && abs(width - renderWidthNow) >= 0.5)
        if isNonRenderWidth { TableAttachment.nonRenderWidthMeasureDepth += 1 }
        defer { if isNonRenderWidth { TableAttachment.nonRenderWidthMeasureDepth -= 1 } }
        // Key the size cache on the SwiftUI binding length, not
        // uiView.textStorage.length. Within a single render pass SwiftUI calls
        // sizeThatFits BEFORE updateUIView, so textStorage still reflects the
        // previous commit. Streaming providers that push tokens in bursts with
        // pauses (DeepSeek V4 especially) would otherwise hit cached heights
        // keyed on the stale length, locking the cell at the old size and
        // clipping the newly arrived characters until the cell was recycled.
        let bindingLen = (markdown as NSString).length
        let storageLen = uiView.textStorage.length

        let coord = context.coordinator
        coord.sizeThatFitsCallCount &+= 1
        let callIdx = coord.sizeThatFitsCallCount
        let t0 = CFAbsoluteTimeGetCurrent()

        // Cache key includes the width bucket (1pt precision) AND the binding
        // length. Multi-width cache survives SwiftUI's recursive sizeThatFits
        // probing where the same view is measured at 2–3 nearby widths during
        // a single preferredLayoutAttributesFitting pass.
        let widthKey = Int(width.rounded())
        if bindingLen == coord.cachedSizeMarkdownCount,
           let cachedHeight = coord.cachedSizes[widthKey] {
            coord.sizeThatFitsCacheHitCount &+= 1
            if callIdx % 50 == 0 {
            }
            return CGSize(width: width, height: cachedHeight)
        }

        // [T-ios-markdown-table-double-render] Near-width cache hit for FULLY
        // COMMITTED (non-streaming) content. During a deceleration glide UIKit
        // probes a cell's sizeThatFits several times at WIDTHS that differ by
        // 1–2pt of rounding (preferredLayoutAttributesFitting passes), so the
        // exact-`widthKey` hit above misses each time and we fall through to the
        // off-screen measure path — which renders the markdown again (the [RND]
        // burst). For a message whose binding is fully laid into storage
        // (`bindingLen == storageLen`, i.e. NOT mid-stream), a height measured
        // 1–2pt away is correct to the pixel for our purposes; reuse it and skip
        // the re-render entirely. This was the table-message "rendered 6×/decel"
        // cost (measure renderer ×3 + display renderer ×3). Gated to non-streaming so token growth
        // (bindingLen != storageLen) is unaffected, and to a tight ±2pt window so
        // a genuine width change (rotation / sidebar) still re-measures. No new
        // measurement happens — we return a height the SAME content already
        // produced — so this cannot reintroduce the historical
        // sizeThatFits→fillLayoutHole typesetter loop.
        if bindingLen == coord.cachedSizeMarkdownCount,
           bindingLen == storageLen,
           !coord.cachedSizes.isEmpty {
            var nearestHeight: CGFloat?
            var nearestDelta = Int.max
            for (bucket, h) in coord.cachedSizes {
                let delta = abs(bucket - widthKey)
                if delta <= 2, delta < nearestDelta {
                    nearestDelta = delta
                    nearestHeight = h
                }
            }
            if let nearestHeight {
                coord.sizeThatFitsCacheHitCount &+= 1
                // Memoize at the exact requested width so the next identical
                // probe takes the exact-hit fast path above (and a flapping
                // width sequence still respects the 4-bucket cap below).
                coord.cachedSizes[widthKey] = nearestHeight
                if coord.cachedSizes.count > 4, let firstKey = coord.cachedSizes.keys.first {
                    coord.cachedSizes.removeValue(forKey: firstKey)
                }
                return CGSize(width: width, height: nearestHeight)
            }
        }

        // HangFix(2026-05-14) — streaming-aware approximate cache hit.
        // If we have a recent full-measurement anchor at this width, and the
        // binding has only grown by a small amount (typical streaming
        // delta), extrapolate the new height linearly to avoid an expensive
        // off-screen measurement. This avoids the 0x8BADF00D watchdog
        // crash on iPhone 17 Pro Max where every token chunk used to spawn
        // a 50-200ms typesetter pass.
        //
        // Strict guards to avoid runaway estimates (the very-tall-table
        // bug seen 2026-05-14 20:21: prevLen=2 prevH=14 → 7pt/char → 200
        // chars later 1547pt) — the anchor must be substantial enough to
        // give a meaningful per-char rate, the delta must be modest, the
        // estimate is bounded by an absolute cap, and the estimate is NOT
        // written back to cachedSizes so a later sizeThatFits at the same
        // length doesn't reuse it.
        let useMeasureTextView = bindingLen != storageLen
        // [T-ios-streaming-est-attachment-clip] STREAM-EST disabled again.
        // It was restored in de4d3df6 to kill visible-streaming hangs, but the
        // linear pxPerChar extrapolation under-measures cells that contain
        // fixed-height attachments (tool capsules, code/shell blocks, images):
        // those blocks don't grow with character count, so the estimate came
        // out too short and the NEXT cell overlapped the tail of a finished
        // message (user report, macOS, "Minis Feedback Review" — the shell
        // preview + tool capsule covered the body text of the last message).
        // Gate it back off so every streaming sizeThatFits takes a real
        // measurement; the hang de4d3df6 fixed is the tradeoff to revisit with
        // an attachment-aware estimate rather than this whole-cell linear one.
        let disableStreamEst = true
        if !disableStreamEst,
           useMeasureTextView,
           let prevHeight = coord.lastFullMeasureHeight[widthKey],
           coord.lastFullMeasureBindingLen >= 64,                        // anchor must represent enough characters
           prevHeight >= 30,                                              // and a real laid-out block
           bindingLen > coord.lastFullMeasureBindingLen,
           bindingLen - coord.lastFullMeasureBindingLen < 128 {           // tighter delta window
            let prevLen = coord.lastFullMeasureBindingLen
            let pxPerChar = prevHeight / CGFloat(prevLen)
            let delta = CGFloat(bindingLen - prevLen)
            // Cap the extrapolated growth to 1.5× the anchor and to an
            // absolute ceiling matching the on-screen viewport (avoids
            // table/code blocks blowing the estimate past the screen).
            let rawEstimate = prevHeight + delta * pxPerChar
            let estimated = min(rawEstimate, prevHeight * 1.5, 1200)
            // DO NOT write `estimated` to `cachedSizes` — that would let
            // the next sizeThatFits at the same bindingLen think it has a
            // real measurement and skip re-measurement entirely. Just
            // return the estimate for this probe; the next probe will
            // re-enter and either compute a real value (storage catches
            // up) or extrapolate again (delta still in range).
            return CGSize(width: width, height: estimated)
        }

        // If the binding length changed, the old cache is invalid — flush all
        // width buckets. Otherwise we're just adding a new width bucket.
        if bindingLen != coord.cachedSizeMarkdownCount {
            coord.cachedSizes.removeAll(keepingCapacity: true)
            coord.cachedSizeMarkdownCount = bindingLen
        }

        // If textStorage hasn't caught up to the binding yet (SwiftUI's
        // sizeThatFits-before-updateUIView ordering), measure against an
        // off-screen textView. Previously we committed the pending
        // attributedText into `uiView` here so its own sizeThatFits saw the
        // new content — but that rebuilds attachment subviews and calls
        // `addSubview` / `setNeedsLayout` on the live textView during
        // SwiftUI's measurement pass, which causes SwiftUI to re-invoke
        // `sizeThatFits` recursively. The resulting watchdog hang is
        // recorded in `Minis-2026-05-13-084827.ips` (depth=9 recursion at
        // `LayoutEngineBox.sizeThatFits`). Measuring on a detached textView
        // keeps the live view's state stable until the subsequent
        // `updateUIView` runs.
        // (`useMeasureTextView` already declared above in the streaming
        // approximate-cache fast path.)
        let measuringTextView: SelectableMarkdownTextView
        // REPRO-FIX(2026-05-16): when storage doesn't have the latest content
        // yet, we used to write `pending` to an off-screen measureTextView
        // and call its sizeThatFits — but that triggers full _fillLayoutHole
        // + tcSize churn for every stream chunk. Replace with
        // NSAttributedString.boundingRect when pending is attachment-free
        // (boundingRect uses CoreText and never invalidates UIKit layout
        // state). When pending has attachments, TableAttachment /
        // CodeBlockAttachment / ImageAttachment custom `attachmentBounds`
        // is needed for correct heights, so we still fall back to mtv.
        if useMeasureTextView {
            // [TablePathFix] When the prebuilt attributed string contains a
            // TableAttachment we must NOT use it — the cached path comes
            // from `AIChatViewModel.cacheAttributedString(for:)` which uses
            // a fresh `MarkdownNSRenderer` and creates new TableAttachment
            // objects every flush. During streaming this detaches live
            // attachments from the coordinator's `tableAttachmentCache`
            // (which `update()` mutates with `contentGeneration` bumps
            // that the UAV dedup fingerprint relies on).
            let preHasTable: Bool = {
                guard let pre = cachedAttributedString, pre.length > 0 else { return false }
                var found = false
                pre.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pre.length), options: []) { value, _, stop in
                    if value is TableAttachment { found = true; stop.pointee = true }
                }
                return found
            }()
            let pending: NSAttributedString
            if let pre = cachedAttributedString, !preHasTable {
                pending = pre
            } else {
                // REPRO-FIX(2026-05-16): split off any in-flight (`|`-row
                // not yet terminated by `\n`) table block at the buffer's
                // tail. cmark gets only the stable prefix; the in-flight
                // tail is appended as plain attributed text using the body
                // font. This avoids the per-chunk `TableAttachment` rebuild
                // + `_fillLayoutHole` storm that hangs iPhone 17 Pro Max.
                //
                // Skip the split once the message has finished streaming
                // (the presence of `cachedAttributedString` or
                // `cachedContent` is the finalised signal): a message
                // whose final row never gets a trailing `\n` must still
                // be rendered as a real table after stream-end.
                let _isFinalisedSTF = cachedAttributedString != nil || cachedContent != nil
                let split = _isFinalisedSTF
                    ? (prefix: markdown, plainSuffix: "")
                    : splitStreamingTableTail(markdown)
                let preparedPrefix = prepareMarkdownForRender(split.prefix)
                let blocks = MarkdownContent(preparedPrefix).blocks
                coord.renderer.messageId = messageId
                coord.renderer.blockId = blockId
                let rendered = autoreleasepool { coord.renderer.render(blocks: blocks) }
                if split.plainSuffix.isEmpty {
                    pending = rendered
                } else {
                    let mut = NSMutableAttributedString(attributedString: rendered)
                    let suffixAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                        .foregroundColor: UIColor.label,
                    ]
                    mut.append(NSAttributedString(string: split.plainSuffix, attributes: suffixAttrs))
                    pending = mut
                }
            }
            // REPRO-FIX(2026-05-16): scan pending for ANY .attachment.
            // No-attachment case: take the CoreText boundingRect fast path
            // (verified across 14 streaming rounds in commit 01939f7:
            // MAIN HANG = 0, avg processMs = 0.5). Attachments require
            // the legacy mtv path because their custom `attachmentBounds`
            // depends on TextKit invoking it through the line fragment
            // typesetter.
            var hasAnyAttachment = false
            pending.enumerateAttribute(.attachment, in: NSRange(location: 0, length: pending.length), options: []) { v, _, stop in
                if v != nil { hasAnyAttachment = true; stop.pointee = true }
            }
            if !hasAnyAttachment {
                // [T-ios-decel-inv-estimate-calibration] FINALIZED content takes
                // the real-engine measure: CTFramesetter over-measures blocks
                // with inline-code/bold spans by +2..+36pt vs the actual TextKit
                // render (per-cell trajectory traces: first display grew the
                // cell mid-decel, then a later re-measure shrank it back — the
                // user-visible scroll jitter AND oscillation). An offscreen
                // SelectableMarkdownTextView measure matches the final render
                // by construction. Gated to finalized (non-streaming) content
                // and ≤8000 chars — streaming keeps the CT fast path (per-chunk
                // cost), and huge blocks avoid TextKit1's near-O(n²) wall
                // (T-ios-longreply-boundingRect-watchdog).
                let finalizedSTF = cachedAttributedString != nil || cachedContent != nil
                let h: CGFloat
                if finalizedSTF, pending.length <= 8000,
                   let mtv = coord.measureTextView as? SelectableMarkdownTextView {
                    mtv.attributedText = pending
                    h = ceil(mtv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
                } else {
                    // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead of
                    // NSAttributedString.boundingRect — same CoreText result (±1pt) but
                    // 70–700× faster on many-line text (boundingRect's TextKit1 wrapper
                    // is near-O(n²) in line count). Attachment-free is already asserted
                    // above, so it's safe here.
                    let textHeight = Self.ctFramesetterHeight(for: pending, width: width)
                    // [BoundingRectInset 2026-05-16] CoreText measurement
                    // omits UITextView.textContainerInset (configured top=4
                    // bottom=4 in init, line ~3597). Diagnostic confirmed
                    // UITextView.sizeThatFits returns text height +
                    // exactly inset.top + inset.bottom (=8) consistently
                    // across CJK + inline-code multi-paragraph blocks.
                    // Without this addition cell.frame is 7-8pt short and
                    // the last visual line of every multi-line markdown
                    // cell gets clipped at its descender.
                    let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
                    h = textHeight + inset
                }
                coord.cachedSizes[widthKey] = h
                coord.cachedSizeMarkdownCount = bindingLen
                if bindingLen > 0 {
                    coord.lastFullMeasureBindingLen = bindingLen
                    coord.lastFullMeasureHeight[widthKey] = h
                    coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
                }
                let _renderW = uiView.bounds.width
                if _renderW <= 0 || abs(width - _renderW) < 0.5 {
                    uiView.lastComputedHeight = h
                }
                return CGSize(width: width, height: h)
            }
            // Fallback: pending has attachments — use mtv path so
            // attachmentBounds is invoked through TextKit.
            let mtv = coord.measureTextView as? SelectableMarkdownTextView ?? coord.measureTextView as! SelectableMarkdownTextView
            mtv.attributedText = pending
            #if DEBUG
            // [T-attachment-zero-origin] Snapshot the moment after attributedText
            // is assigned to the off-screen measureTextView. This is exactly when
            // TextKit runs setGlyphs:properties: — if textContainer.size.width is
            // still 0 here, attachment glyphs get classified as controlCharacter
            // (the bug we're hunting). The snapshot captures glyphProperty for
            // every attachment so we can see the bad classification directly.
            MarkdownSnapshotCollector.captureIfEnabled(
                textView: mtv,
                phase: "afterMtv.setAttributedText",
                messageId: context.coordinator.renderer.messageId?.uuidString,
                isMeasureView: true
            )
            #endif
            measuringTextView = mtv
        } else {
            measuringTextView = uiView

            // [T-ios-longreply-boundingRect-watchdog] Non-streaming fast path.
            // For a fully-committed (bindingLen == storageLen) attachment-free
            // text block, measure with CTFramesetter instead of falling through
            // to `uiView.sizeThatFits` below — that call runs TextKit1's
            // near-O(n²) layout and is the source of the 8.7–10.8s SLOW MEASURE /
            // WatchdogProbe 2000ms window / 0x8BADF00D watchdog kills on the
            // 29k-char / ~1500-line reply. CTFramesetter is 70–700× faster and
            // returns the same height (±1pt). Attachments (table/code/image) still
            // take the TextKit path so their custom attachmentBounds is honored.
            let liveStorage = uiView.textStorage
            if liveStorage.length > 0 {
                var hasAnyAttachment = false
                liveStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: liveStorage.length), options: []) { v, _, stop in
                    if v != nil { hasAnyAttachment = true; stop.pointee = true }
                }
                if !hasAnyAttachment {
                    // [T-ios-decel-inv-estimate-calibration] Same real-engine
                    // routing as the pre-commit branch above: committed
                    // attachment-free content ≤8000 chars measures on the
                    // offscreen SelectableMarkdownTextView (matches the render
                    // exactly); CT stays for huge blocks (watchdog wall).
                    // FINALIZED-ONLY: during streaming, bindingLen catches up to
                    // storageLen between chunks, so without this gate every
                    // post-commit probe would pay the mtv measure (1.4-11ms vs
                    // CT's 0.3ms) per chunk — the exact per-chunk typesetter
                    // cost de4d3df6 / REPRO-FIX(2026-05-16) fought to remove.
                    let finalizedCommitted = cachedAttributedString != nil || cachedContent != nil
                    let h: CGFloat
                    if finalizedCommitted, liveStorage.length <= 8000,
                       let mtv = coord.measureTextView as? SelectableMarkdownTextView {
                        mtv.attributedText = liveStorage
                        h = ceil(mtv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
                    } else {
                        let textHeight = Self.ctFramesetterHeight(for: liveStorage, width: width)
                        // Match UITextView.sizeThatFits: add textContainerInset (top+bottom).
                        let inset = uiView.textContainerInset.top + uiView.textContainerInset.bottom
                        h = textHeight + inset
                    }
                    coord.cachedSizes[widthKey] = h
                    if coord.cachedSizes.count > 4, let firstKey = coord.cachedSizes.keys.first {
                        coord.cachedSizes.removeValue(forKey: firstKey)
                    }
                    coord.cachedSizeMarkdownCount = bindingLen
                    if bindingLen > 0 {
                        coord.lastFullMeasureBindingLen = bindingLen
                        coord.lastFullMeasureHeight[widthKey] = h
                        coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
                        if coord.lastFullMeasureHeight.count > 4, let firstKey = coord.lastFullMeasureHeight.keys.first {
                            coord.lastFullMeasureHeight.removeValue(forKey: firstKey)
                        }
                    }
                    let renderW = uiView.bounds.width
                    if renderW <= 0 || abs(width - renderW) < 0.5 {
                        uiView.lastComputedHeight = h
                    }
                    let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    coord.sizeThatFitsTotalMs += totalMs
                    #if DEBUG
                    Self.recordSTF(elapsedMs: totalMs, msgId: messageId, attrLen: bindingLen)
                    #endif
                    return CGSize(width: width, height: h)
                }
            }
        }

        // CRITICAL FIX: Only touch textContainer.size when the width ACTUALLY
        // changed. On iOS 26 TextKit1, assigning the same CGSize still triggers
        // -[NSLayoutManager textContainerChangedGeometry:] which invalidates the
        // entire layout and forces a full _fillLayoutHole pass. Time Profiler
        // showed this single line causing 8+ second hangs during CollectionView
        // bounds-change re-measurement on large messages.
        //
        // [JitterFix] SwiftUI drives sizeThatFits at TWO widths per layout
        // pass: the inner content width (~370) and the cell's outer width
        // (~402). Committing both into the live textContainer corrupts
        // render state — the next render uses whichever width "won" most
        // recently, producing a 23pt height oscillation. Only commit when
        // the probe width matches the live bounds.width (the width the cell
        // will actually render at). Other-width probes still measure
        // correctly via UITextView.sizeThatFits, but don't mutate state.
        let tc = measuringTextView.textContainer
        let oldWidth = tc.size.width
        let renderW = measuringTextView.bounds.width
        let isRenderWidth = renderW > 0 && abs(width - renderW) < 0.5
        let widthChanged = abs(width - oldWidth) > 0.5
        // For the off-screen measureTextView (renderW == 0), always sync
        // the width so it measures at the requested fitting width.
        if widthChanged && (isRenderWidth || renderW <= 0 || useMeasureTextView) {
            tc.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }

        // Let UITextView.sizeThatFits drive layout lazily. Removing the
        // surrounding explicit lm.ensureLayout(for:) calls — they were
        // running a second and third full typesetting pass on top of the
        // one UITextView.sizeThatFits already does internally.
        let tSize = CFAbsoluteTimeGetCurrent()
        let size = measuringTextView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let sizeMs = (CFAbsoluteTimeGetCurrent() - tSize) * 1000

        // Restore the unbounded height so the layout manager keeps all glyphs
        // laid out for drawing. UITextView.sizeThatFits clamps this internally.
        // Only when actually clamped — see layoutSubviews for the rationale.
        if tc.size.height < CGFloat.greatestFiniteMagnitude {
            tc.size.height = CGFloat.greatestFiniteMagnitude
        }

        // Keep lastComputedHeight in sync so invalidateCellSizeIfNeeded()
        // can detect real deltas. Without this, lastComputedHeight stays 0
        // after the initial sizeThatFits, causing the guard to skip layout
        // invalidation when images load asynchronously and change the height.
        //
        // [JitterFix] Only commit when probe width matches render width;
        // otherwise the outer-width probe (402) clobbers the correct
        // inner-width measurement (370 → ~611) with a 23pt-smaller value.
        // Per-width caching still works via coord.cachedSizes below.
        if isRenderWidth || renderW <= 0 {
            uiView.lastComputedHeight = size.height
        }

        // Cache the new result by width bucket. Cap at 4 buckets to bound
        // memory; evict the first inserted entry when overflowing.
        coord.cachedSizes[widthKey] = size.height
        if coord.cachedSizes.count > 4 {
            if let firstKey = coord.cachedSizes.keys.first {
                coord.cachedSizes.removeValue(forKey: firstKey)
            }
        }

        // HangFix(2026-05-14) — record this real measurement as the
        // anchor for subsequent streaming approximations. Only the live-
        // view path (storage == binding) produces a fully accurate
        // height; the off-screen measureTextView path also produces a
        // real measurement so we anchor on it too (storeLen tracks
        // binding inside useMeasureTextView).
        if bindingLen > 0 && size.height > 0 {
            coord.lastFullMeasureBindingLen = bindingLen
            coord.lastFullMeasureHeight[widthKey] = size.height
            coord.lastFullMeasureAt = CFAbsoluteTimeGetCurrent()
            // Bound the same-width-bucket count to 4 so a flapping width
            // sequence doesn't grow without bound; reuse the same cap as
            // `cachedSizes` above.
            if coord.lastFullMeasureHeight.count > 4 {
                if let firstKey = coord.lastFullMeasureHeight.keys.first {
                    coord.lastFullMeasureHeight.removeValue(forKey: firstKey)
                }
            }
        }

        let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        coord.sizeThatFitsTotalMs += totalMs

        // Only log MISS on slow paths or periodically — every-token MISS during
        // streaming was a primary noise source.
        if totalMs >= 50 || callIdx % 100 == 0 {
            let widthDelta = Int((width - oldWidth).rounded())
            let level: String
            if totalMs >= 200 { level = "🔥🔥" }
            else if totalMs >= 50 { level = "🔥" }
            else { level = "" }
            Self.stfLogger.info("[STF] #\(callIdx) MISS\(level) w=\(widthKey) (Δ\(widthDelta)) len=\(bindingLen) wChg=\(widthChanged ? 1 : 0) stf=\(String(format: "%.1f", sizeMs))ms total=\(String(format: "%.1f", totalMs))ms buckets=\(coord.cachedSizes.count) cumulative=\(String(format: "%.0f", coord.sizeThatFitsTotalMs))ms hits=\(coord.sizeThatFitsCacheHitCount)/\(callIdx)")
        }

        if bindingLen >= 10_000 && totalMs >= 100 {
            Self.stfLogger.warning("[STF] ⚠️ LONG-TEXT SLOW len=\(bindingLen) totalMs=\(String(format: "%.1f", totalMs)) — repeated calls of this size can trigger 0x8BADF00D")
        }

        #if DEBUG
        // [WatchdogProbe] STF window probe — watchdog kills at 10s wall clock.
        // Track cumulative STF time per main-runloop iteration; when the same
        // runloop hop has already burned >2s in TextKit measurement, emit a
        // critical warning. This is the strongest pre-watchdog signal — a
        // single runloop iteration is what FRONTBOARD measures.
        Self.recordSTF(elapsedMs: totalMs, msgId: messageId, attrLen: bindingLen)
        #endif

        #if DEBUG
        // [T-attachment-zero-origin] Snapshot the textView used for measurement.
        // For attachment-bearing markdown this is the off-screen measureTextView
        // (where the lineFrag.width=10M bug surfaces); for attachment-free
        // content it's the live uiView itself.
        let stfMid = context.coordinator.renderer.messageId?.uuidString
        let isMeasure = (measuringTextView !== uiView)
        MarkdownSnapshotCollector.captureIfEnabled(
            textView: measuringTextView,
            phase: isMeasure ? "afterSizeThatFits.mtv" : "afterSizeThatFits.live",
            messageId: stfMid,
            isMeasureView: isMeasure,
            sizeThatFitsResult: CGSize(width: width, height: size.height)
        )
        #endif

        return CGSize(width: width, height: size.height)
    }

    private static let stfLogger = AppLogger(category: "SelectableMarkdownSTF")
    #if DEBUG
    static let watchdogProbe = AppLogger(category: "WatchdogProbe")
    #endif
}
