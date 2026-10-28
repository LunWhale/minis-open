//
//  MessageListV3Coordinator+ScrollingScreenshot.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Long-press turn screenshot: scrolls the live collection view page by page
//  and stitches the pages into one image (text selection cleared first).
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ScrollingScreenshot" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// [split seam] `Coordinator.messageId(of:)` below was written inside the
/// enclosing `extension CollectionViewMessageListV3`, where `Coordinator` was in
/// scope; this extension of the nested class does not see it.
private typealias Coordinator = CollectionViewMessageListV3.Coordinator

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Scrolling Screenshot Capture

        /// [T-ios-copy-screenshot-diag-logs] Locate the UITextView descendant
        /// (if any) that currently holds an active text-range selection in
        /// the collection view subtree. Used only by the screenshot
        /// diagnostic trace — non-destructive (does NOT clear selection).
        /// Returns the first textView found with a non-zero selectedRange,
        /// matching the depth-first walk order of `clearTextSelection`.
        @MainActor
        private func activeSelectableTextView(in cv: UICollectionView) -> UITextView? {
            var found: UITextView? = nil
            func walk(_ view: UIView) {
                if found != nil { return }
                if let tv = view as? UITextView, tv.selectedRange.length > 0 {
                    found = tv
                    return
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
            return found
        }

        /// Walk all subviews of `cv` and clear any active text selection so
        /// selection handles, magnifier loupes, focus rings and tinted ranges
        /// don't show up in screenshots.
        @MainActor
        private func clearTextSelection(in cv: UICollectionView) {
            // Dismiss keyboard / global edit menu first.
            cv.window?.endEditing(true)
            UIMenuController.shared.hideMenu()

            func walk(_ view: UIView) {
                if let tv = view as? UITextView {
                    if tv.isFirstResponder { tv.resignFirstResponder() }
                    // Collapse selection to a zero-length range (nil doesn't
                    // always clear UITextView's internal selection state).
                    if let start = tv.position(from: tv.beginningOfDocument, offset: 0) {
                        tv.selectedTextRange = tv.textRange(from: start, to: start)
                    }
                    tv.selectedTextRange = nil
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
        }

        /// Capture a conversation turn by scrolling the live collection view
        /// page by page and stitching the snapshots into a single image.
        ///
        /// Uses fixed-height pages (`usableH`). Each page is cropped to
        /// exclude the nav bar (top) and input bar (bottom) overlay areas.
        /// Original `contentOffset` is restored before returning.
        @MainActor
        func captureScrollingTurnScreenshot(userMessageId: UUID, assistantMessageId: UUID?) -> UIImage? {
            // [T-ios-copy-screenshot-diag-logs] All ChatScreenshot logs share
            // this monotonic anchor so users can read elapsed-ms deltas
            // between stages without reasoning about wall-clock timestamps.
            let t0 = CACurrentMediaTime()
            func ms() -> String { String(format: "%6.1fms", (CACurrentMediaTime() - t0) * 1000) }

            guard let cv = viewController?.collectionView,
                  let snapshot = dataSource?.snapshot() else {
                screenshotLogger.info("captureScrolling: no cv or snapshot")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — no cv or snapshot")
                return nil
            }
            let items = snapshot.itemIdentifiers

            guard let startIdx = items.firstIndex(where: {
                if case .wholeMessage(let id) = $0, id == userMessageId { return true }
                return false
            }) else {
                screenshotLogger.info("captureScrolling: user item not found")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — user message id=\(userMessageId.uuidString.prefix(8)) not found in snapshot")
                return nil
            }

            // [T-ios-copy-screenshot-missing-assistant] End the capture at the
            // LAST item belonging to the assistant message, whatever kind it is
            // — not specifically its `.assistantFooter`.
            //
            // An assistant turn is expanded into header + one item per block +
            // (conditionally) a footer. `needsFooter` is only true for the LAST
            // assistant message, or when the turn has an error / interrupt /
            // usage row (see the snapshot builder). So for every earlier turn
            // there is no `.assistantFooter` item at all, `lastIndex(where:)`
            // returned nil, and `endIdx` fell back to `startIdx` — the range
            // collapsed onto the user message alone, which is exactly the
            // reported bug: screenshotting any non-latest turn produced the
            // user's text with the model's reply missing.
            //
            // Matching on the owning message id covers all three item kinds, so
            // the range ends at the true bottom of the turn whether or not a
            // footer was emitted.
            let endIdx: Int
            if let assistantMessageId,
               let i = items.lastIndex(where: {
                   Coordinator.messageId(of: $0) == assistantMessageId
               }) {
                endIdx = i
            } else {
                endIdx = startIdx
            }

            guard endIdx >= startIdx else { return nil }

            // [Stage1-Entry] full pre-capture state dump. The most important
            // fields for the top-blank symptom are contentOffset.y vs the
            // measured user-message frame.minY — if these don't align after
            // the warming pass, the page loop's first iteration crops from
            // the wrong starting Y.
            let savedOffset = cv.contentOffset
            // [T-ios-copy-screenshot-top-blank] Suspend the auto-scroll
            // pinning machinery for the duration of the capture. When
            // the session is in `.autoScrolling` mode, the contentSize
            // KVO observer (around line 695) reacts to any layout
            // change — including the stream-driven cell-height
            // measurements that fire while we hold the runloop — by
            // resetting `cv.contentOffset.y = max(cv.contentOffset.y,
            // maxOff)`. That silently undoes our setContentOffset
            // writes during the page loop and the top of the turn
            // ends up missing from the canvas. Switch to
            // `.userBrowsing` for the capture (the same flag scrollViewWillBeginDragging
            // uses) and also clear `clampAfterSessionLoad`.
            // Restored before returning.
            let savedScrollMode = self.scrollMode
            let savedClampAfterSessionLoad = self.clampAfterSessionLoad
            self.scrollMode = .userBrowsing
            self.clampAfterSessionLoad = false
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMsg=\(userMessageId.uuidString.prefix(8)) startIdx=\(startIdx) endIdx=\(endIdx) totalItems=\(items.count) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse")→browse(suspended) clampAfterSessionLoad=\(savedClampAfterSessionLoad)→false")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.contentOffset=(\(String(format: "%.1f", savedOffset.x)),\(String(format: "%.1f", savedOffset.y)))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.bounds=\(String(format: "%.0fx%.0f", cv.bounds.width, cv.bounds.height)) cv.contentSize=\(String(format: "%.0fx%.0f", cv.contentSize.width, cv.contentSize.height))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.adjustedContentInset=(t=\(String(format: "%.1f", cv.adjustedContentInset.top)) b=\(String(format: "%.1f", cv.adjustedContentInset.bottom)))")
            // Pre-warming frame readback — these may be ESTIMATED if the
            // user-message cell was off-screen at long-press time.
            let entryFirstFrame = cv.layoutAttributesForItem(at: IndexPath(item: startIdx, section: 0))?.frame
            let entryLastFrame = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))?.frame
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) PRE-warm firstFrame=\(entryFirstFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil") lastFrame=\(entryLastFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil")")
            // Is the user message currently visible? If yes, no scroll
            // adjustment needed; if not, warming has to do real work.
            let visibleRange: ClosedRange<CGFloat>? = {
                let bounds = cv.bounds
                return savedOffset.y...(savedOffset.y + bounds.height)
            }()
            if let f = entryFirstFrame, let vr = visibleRange {
                let onScreen = f.maxY >= vr.lowerBound && f.minY <= vr.upperBound
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMessage visibleAtLongPress=\(onScreen) frameRange=[\(String(format: "%.1f", f.minY)),\(String(format: "%.1f", f.maxY))] viewportRange=[\(String(format: "%.1f", vr.lowerBound)),\(String(format: "%.1f", vr.upperBound))]")
            }
            // Active text selection state — text-selection menu path enters
            // here with selection ranges held by some UITextView descendant.
            // Knowing whether selection is held and which direction it was
            // dragged is the spec's prime suspect for the top-blank symptom.
            let activeSel = self.activeSelectableTextView(in: cv)
            if let tv = activeSel {
                let r = tv.selectedRange
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) selection ACTIVE on textView=\(String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(tv).toOpaque()))) range=(loc=\(r.location), len=\(r.length)) textLen=\(tv.textStorage.length)")
            } else {
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) no active text selection")
            }

            clearTextSelection(in: cv)
            cv.layoutIfNeeded()
            // [T-ios-copy-screenshot-top-blank] After clearing the active
            // text selection, give UIKit one runloop tick to finish
            // releasing the selection state. Without this short wait,
            // scrollToItem below sometimes no-ops or partial-commits — the
            // cv is still inside its selection-locked autoscroll state from
            // the long-press gesture that opened the menu — and the
            // measured firstFrame.minY ends up offset from where the
            // page-loop expects it, dropping the top of the user message
            // off the final canvas.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let viewportH = cv.bounds.height
            let bottomMask = max(0, cv.adjustedContentInset.bottom)
            let topMask = max(0, cv.adjustedContentInset.top)
            let navSafetyGap: CGFloat = 10
            let cropTop = topMask + navSafetyGap
            let usableH = max(1, viewportH - cropTop - bottomMask)

            chatScreenshotLogger.info("[Stage2-Warming] \(ms()) BEGIN viewportH=\(String(format: "%.1f", viewportH)) topMask=\(String(format: "%.1f", topMask)) bottomMask=\(String(format: "%.1f", bottomMask)) cropTop=\(String(format: "%.1f", cropTop)) usableH=\(String(format: "%.1f", usableH))")
            // --- Warming pass ---
            // On first session load, cells above the viewport haven't been
            // configured yet (UICollectionView lazy-loads). First scroll the
            // user message into view so its cell is created and measured,
            // then scroll page-by-page through the assistant response.
            // After this pass all layout frames reflect measured heights.
            do {
                // Step 1: bring the user message cell on screen.
                let beforeStep1 = cv.contentOffset.y
                cv.scrollToItem(at: IndexPath(item: startIdx, section: 0), at: .top, animated: false)
                cv.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                let afterStep1 = cv.contentOffset.y
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP1 scrollToItem(startIdx) offset: \(String(format: "%.1f", beforeStep1)) → \(String(format: "%.1f", afterStep1)) Δ=\(String(format: "%.1f", afterStep1 - beforeStep1))")

                // Step 2: scroll through the rest of the turn so all cells
                // between startIdx and endIdx are configured.
                let estLast = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))?.frame.maxY
                    ?? (cv.contentOffset.y + viewportH * 3)
                var warmY = cv.contentOffset.y + cropTop
                var warmCount = 0
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP2 begin estLast=\(String(format: "%.1f", estLast)) initialWarmY=\(String(format: "%.1f", warmY))")
                while warmY < estLast && warmCount < 200 {
                    warmCount += 1
                    cv.contentOffset = CGPoint(x: 0, y: warmY - cropTop)
                    cv.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    let actual = cv.contentOffset.y + cropTop
                    if actual + usableH >= estLast { break }
                    if actual <= warmY - 0.5 && warmCount > 1 { break }
                    warmY = actual + usableH
                }
                cv.layoutIfNeeded()
                screenshotLogger.info("captureScrolling: warming pass complete (\(warmCount) steps)")
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) END steps=\(warmCount) finalOffset=\(String(format: "%.1f", cv.contentOffset.y)) estLast=\(String(format: "%.1f", estLast))")
            }

            // [T-ios-copy-screenshot-top-blank] After the warming pass
            // re-anchor scroll to the user message's measured top. The
            // warming pass advances contentOffset turn-by-turn, leaving
            // the cv parked deep in the assistant response. Subsequent
            // page-loop code reads `firstAttrs.frame` for turnTopY but
            // never repositions the scroll view — so the first page
            // capture would start from wherever the warming pass left
            // off (= bottom of the turn) rather than from the user
            // message top. The page loop's per-page scrollToY corrects
            // this once it iterates, but the first frame readback
            // happens before that and prior code paths assumed
            // contentOffset already matched. Make the assumption hold
            // by explicitly scrolling startIdx back to top here.
            let beforeReAnchor = cv.contentOffset.y
            cv.scrollToItem(at: IndexPath(item: startIdx, section: 0), at: .top, animated: false)
            cv.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) scrollToItem(startIdx, .top) offset: \(String(format: "%.1f", beforeReAnchor)) → \(String(format: "%.1f", cv.contentOffset.y)) Δ=\(String(format: "%.1f", cv.contentOffset.y - beforeReAnchor))")

            // --- Read final layout frames (now measured, not estimated) ---
            let firstAttrs = cv.layoutAttributesForItem(at: IndexPath(item: startIdx, section: 0))
            let lastAttrs = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))
            guard let firstFrame = firstAttrs?.frame, let lastFrame = lastAttrs?.frame else {
                screenshotLogger.info("captureScrolling: missing layout attributes")
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ABORT — missing layout attributes (firstAttrs=\(firstAttrs == nil ? "nil" : "ok") lastAttrs=\(lastAttrs == nil ? "nil" : "ok"))")
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }
            let turnTopY = firstFrame.minY - 10
            let turnBottomY = lastFrame.maxY
            let totalH = turnBottomY - turnTopY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) MEASURED firstFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", firstFrame.minY, firstFrame.height, firstFrame.maxY)) lastFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", lastFrame.minY, lastFrame.height, lastFrame.maxY))")
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) DERIVED turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomY=\(String(format: "%.1f", turnBottomY)) totalH=\(String(format: "%.1f", totalH))")
            // KEY DIAGNOSTIC: alignment of cv.contentOffset.y vs turnTopY
            // matters because the first iteration of the page loop ASSUMES
            // a scroll has placed nextContentY (= turnTopY) at the cropTop
            // line. If contentOffset.y is far off from (turnTopY - cropTop),
            // the first scrollToY may clamp or no-op and the top of the
            // capture starts from elsewhere.
            let expectedOffsetY = turnTopY - cropTop
            let offsetDelta = cv.contentOffset.y - expectedOffsetY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ALIGN cv.contentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) expected=(turnTopY - cropTop)=\(String(format: "%.1f", expectedOffsetY)) DELTA=\(String(format: "%.1f", offsetDelta)) (positive=scrolled past top)")
            // [T-ios-copy-screenshot-top-blank] Diagnostic dump of every
            // mechanism that could be pinning the cv to bottom and
            // overriding our setContentOffset writes — without these
            // we cannot tell whether scrollMode/autoScrolling, the
            // clamp-after-session-load timer, an in-flight animated
            // scroll, an active gesture, deceleration, or some other
            // observer is rejecting the offset write.
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let nearBottom = (maxOff - cv.contentOffset.y) < 60
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) PIN-STATE scrollMode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") clampAfterSessionLoad=\(self.clampAfterSessionLoad) isAnimatingScrollToBottom=\(self.isAnimatingScrollToBottom) maxOff=\(String(format: "%.1f", maxOff)) currentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) nearBottom=\(nearBottom) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) dragging=\(cv.isDragging) GRs=\((cv.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ","))")
            // [T-ios-copy-screenshot-top-blank] Probe each scroll write
            // separately so the log records which one (if any) actually
            // moves the offset. Reading cv.contentOffset.y BEFORE every
            // setter + RIGHT AFTER (no runloop) shows whether UIKit
            // accepted the write synchronously; one runloop hop later
            // tells whether some observer rewrote it. Without this
            // breakdown we can't distinguish "setter rejected" from
            // "setter accepted but reverted".
            if abs(offsetDelta) > 1 {
                self.clearTextSelection(in: cv)
                // Disable scroll gestures temporarily — these are the
                // most visible suspect for blocking writes during a
                // selection long-press.
                let savedGRStates: [(UIGestureRecognizer, Bool)] = (cv.gestureRecognizers ?? []).map { ($0, $0.isEnabled) }
                for (gr, _) in savedGRStates { gr.isEnabled = false }

                // Attempt A: setContentOffset(animated:false)
                let pA0 = cv.contentOffset.y
                cv.setContentOffset(CGPoint(x: 0, y: max(0, expectedOffsetY)), animated: false)
                let pA1 = cv.contentOffset.y     // immediate readback (pre-runloop)
                cv.layoutIfNeeded()
                let pA2 = cv.contentOffset.y     // after layoutIfNeeded
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let pA3 = cv.contentOffset.y     // after one runloop hop — if pA3 != pA2 someone wrote it back

                // Attempt B (only if A didn't reach target): direct assignment + runloop
                var pB0: CGFloat = -1, pB1: CGFloat = -1, pB2: CGFloat = -1
                if abs(pA3 - expectedOffsetY) > 1 {
                    pB0 = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0, y: max(0, expectedOffsetY))
                    pB1 = cv.contentOffset.y
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    pB2 = cv.contentOffset.y
                }

                for (gr, wasEnabled) in savedGRStates { gr.isEnabled = wasEnabled }
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-A setContentOffset(animated:false) target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pA0)) postSet=\(String(format: "%.1f", pA1)) postLayout=\(String(format: "%.1f", pA2)) postRunloop=\(String(format: "%.1f", pA3))")
                if pB0 >= 0 {
                    chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-B contentOffset= assignment target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pB0)) postSet=\(String(format: "%.1f", pB1)) postRunloop=\(String(format: "%.1f", pB2))")
                }
                // Final state for the page loop
                let postFinal = cv.contentOffset.y
                let postDelta = postFinal - expectedOffsetY
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT FINAL offset=\(String(format: "%.1f", postFinal)) postDelta=\(String(format: "%.1f", postDelta)) (postDelta=0 means commit succeeded)")
            }
            guard totalH > 0 else {
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }

            screenshotLogger.info("captureScrolling: turn=[\(Int(turnTopY)),\(Int(turnBottomY))] totalH=\(Int(totalH)) usableH=\(Int(usableH))")

            let scale = UIScreen.main.scale
            let cvWidth = cv.bounds.width

            // --- DEBUG: log appearance state ---
            let currentStyle = cv.traitCollection.userInterfaceStyle
            let windowStyle = cv.window?.traitCollection.userInterfaceStyle
            let windowOverride = cv.window?.overrideUserInterfaceStyle
            let cvOverride = cv.overrideUserInterfaceStyle
            screenshotLogger.info("captureScrolling [DEBUG] cv.traitCollection.userInterfaceStyle=\(currentStyle.rawValue) (0=unspec,1=light,2=dark)")
            screenshotLogger.info("captureScrolling [DEBUG] window.traitCollection.userInterfaceStyle=\(windowStyle?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] window.overrideUserInterfaceStyle=\(windowOverride?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.overrideUserInterfaceStyle=\(cvOverride.rawValue)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.backgroundColor=\(String(describing: cv.backgroundColor))")

            // Check superview/host backgrounds
            var sv = cv.superview
            var depth = 0
            while let v = sv, depth < 5 {
                let resolvedBg = v.backgroundColor?.resolvedColor(with: v.traitCollection)
                screenshotLogger.info("captureScrolling [DEBUG] superview[\(depth)] \(type(of: v)) bg=\(String(describing: resolvedBg)) overrideStyle=\(v.overrideUserInterfaceStyle.rawValue)")
                sv = v.superview
                depth += 1
            }

            // Resolve bg color and log it
            let bgResolved = UIColor.systemBackground.resolvedColor(with: cv.traitCollection)
            var bgR: CGFloat = 0; var bgG: CGFloat = 0; var bgB: CGFloat = 0; var bgA: CGFloat = 0
            bgResolved.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
            screenshotLogger.info("captureScrolling [DEBUG] resolved systemBackground RGBA=(\(bgR),\(bgG),\(bgB),\(bgA))")

            // Lock the collection view's appearance to its current mode
            let savedOverride = cv.overrideUserInterfaceStyle
            cv.overrideUserInterfaceStyle = currentStyle == .dark ? .dark : .light

            // The CV and its immediate parent have backgroundColor set to
            // black-transparent (UIColor(white:0, alpha:0)). On screen this
            // is invisible because the SwiftUI HostingView behind it provides
            // the real background. But drawHierarchy renders the CV subtree
            // in isolation — the black bg composites on top of our white fill,
            // producing a black screenshot. Temporarily swap to the correct
            // background color for the capture.
            let savedCvBg = cv.backgroundColor
            let savedParentBg = cv.superview?.backgroundColor
            cv.backgroundColor = bgResolved
            cv.superview?.backgroundColor = bgResolved

            // Final canvas — Use standard-range sRGB (8 bpc) — the default
            // UIGraphicsImageRendererFormat creates a wide-color
            // ExtendedSRGB 16 bpc bitmap, and many apps (WeChat, etc.)
            // render 16 bpc PNGs as black/white.
            // opaque = true ensures a solid background (no alpha channel)
            // so pasted images don't show as transparent/white.
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let finalSize = CGSize(width: cvWidth, height: totalH)
            let bg = bgResolved

            // Scroll through the turn range one page at a time. Each page:
            //   1. Scroll so `nextContentY` lands at the `cropTop` line
            //      (= topMask + navSafetyGap from the viewport top).
            //   2. Snapshot the full cv bounds.
            //   3. Crop the snapshot to [cropTop, cropTop + sliceH].
            //   4. Blit the crop into the final canvas at dstY.
            //   5. Advance by `usableH`.
            //
            // `cropTop` is the y-coordinate inside the viewport where the
            // usable (nav-bar-free) area starts. By scrolling so that
            // `nextContentY` sits exactly at `cropTop`, the crop always
            // starts exactly where the previous page's crop ended — no gap,
            // no overlap.
            // Snapshot each page into memory BEFORE entering the final
            // canvas renderer. Nesting `drawHierarchy(afterScreenUpdates:true)`
            // inside an outer `UIGraphicsImageRenderer.image { }` block can
            // produce black snapshots: the outer context is the current
            // graphics context, and `afterScreenUpdates:true` defers
            // rendering to a screen-update cycle that doesn't reliably
            // complete inside the nested renderer. Symptom was a stitched
            // image whose top pages were solid bg-color/black with only the
            // last page (drawn via the tail-clamp recovery path) showing
            // real content. Decouple the two phases: pass 1 collects page
            // snapshots with no outer graphics context active; pass 2
            // composites the collected snapshots into the final canvas.
            struct PageSlice {
                let snap: UIImage
                let viewportContentY: CGFloat
                let contentStart: CGFloat
                let contentEnd: CGFloat
            }
            var slices: [PageSlice] = []
            var drawnEndY: CGFloat = turnTopY

            /// Snapshot the current cv viewport, fill bg first.
            func snapshotViewport() -> UIImage {
                let pageSize = cv.bounds.size
                let pageFmt = UIGraphicsImageRendererFormat()
                pageFmt.scale = scale; pageFmt.opaque = true
                pageFmt.preferredRange = .standard
                let pr = UIGraphicsImageRenderer(size: pageSize, format: pageFmt)
                return pr.image { snapCtx in
                    bg.setFill()
                    snapCtx.fill(CGRect(origin: .zero, size: pageSize))
                    cv.drawHierarchy(in: CGRect(origin: .zero, size: pageSize), afterScreenUpdates: true)
                }
            }

            chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) BEGIN turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomY=\(String(format: "%.1f", turnBottomY)) finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) scale=\(scale)")
            do {
                var nextContentY = turnTopY
                var lastActualY: CGFloat = -.greatestFiniteMagnitude
                var pageCount = 0

                while nextContentY < turnBottomY && pageCount < 200 {
                    pageCount += 1
                    let pageStart = CACurrentMediaTime()

                    // Place nextContentY at the cropTop line in the viewport.
                    let targetOffset = nextContentY - cropTop
                    let beforeOffset = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0, y: targetOffset)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    // Read back actual offset (UIKit clamps near scroll edges).
                    let actualY = cv.contentOffset.y + cropTop
                    let clampDelta = (cv.contentOffset.y) - targetOffset
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) nextContentY=\(String(format: "%.1f", nextContentY)) target=(offset=\(String(format: "%.1f", targetOffset))) before=\(String(format: "%.1f", beforeOffset)) after=\(String(format: "%.1f", cv.contentOffset.y)) clampDelta=\(String(format: "%.1f", clampDelta)) actualY=\(String(format: "%.1f", actualY))")
                    if actualY <= lastActualY + 0.5 && pageCount > 1 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — actualY=\(String(format: "%.1f", actualY)) <= lastActualY=\(String(format: "%.1f", lastActualY))+0.5 (no progress)")
                        break
                    }
                    lastActualY = actualY

                    let pageEndY = min(turnBottomY, actualY + usableH)
                    let sliceH = pageEndY - actualY
                    if sliceH <= 0 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — sliceH=\(String(format: "%.1f", sliceH)) <= 0")
                        break
                    }

                    let snapStart = CACurrentMediaTime()
                    let snap = snapshotViewport()
                    let snapMs = (CACurrentMediaTime() - snapStart) * 1000
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) slice=[\(String(format: "%.1f", actualY)),\(String(format: "%.1f", pageEndY))] sliceH=\(String(format: "%.1f", sliceH)) snap=\(String(format: "%.0fx%.0f", snap.size.width, snap.size.height)) snapTime=\(String(format: "%.1f", snapMs))ms pageTime=\(String(format: "%.1f", (CACurrentMediaTime() - pageStart) * 1000))ms")

                    if pageCount <= 2, let cg = snap.cgImage,
                       let dp = cg.dataProvider, let data = dp.data,
                       let ptr = CFDataGetBytePtr(data) {
                        let bpp = cg.bitsPerPixel / 8
                        let bpr = cg.bytesPerRow
                        let sampleY = Int((cropTop + 10) * scale)
                        let sampleX = Int(10 * scale)
                        if sampleY < cg.height && sampleX < cg.width {
                            let offset = sampleY * bpr + sampleX * bpp
                            let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                            let a = bpp >= 4 ? ptr[offset+3] : 255
                            self.screenshotLogger.info("captureScrolling [DEBUG] page\(pageCount) snap pixel(\(sampleX),\(sampleY)) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height) colorSpace=\(String(describing: cg.colorSpace?.name))")
                        }
                    }

                    slices.append(PageSlice(snap: snap, viewportContentY: actualY - cropTop,
                                            contentStart: actualY, contentEnd: pageEndY))
                    drawnEndY = max(drawnEndY, pageEndY)

                    if pageEndY >= turnBottomY { break }
                    nextContentY = actualY + usableH
                }

                // Tail-clamp recovery (see commit 97af7f35): if contentOffset
                // clamping prevented the loop from reaching turnBottomY,
                // scroll to maxScrollY and snapshot the missing range.
                if drawnEndY < turnBottomY - 0.5 {
                    let maxScrollY = max(0, cv.contentSize.height - cv.bounds.height)
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) tail-clamp NEEDED drawnEndY=\(String(format: "%.1f", drawnEndY)) < turnBottomY=\(String(format: "%.1f", turnBottomY)) maxScrollY=\(String(format: "%.1f", maxScrollY))")
                    cv.contentOffset = CGPoint(x: 0, y: maxScrollY)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    let snap = snapshotViewport()
                    let tailContentEnd = min(turnBottomY, maxScrollY + cv.bounds.height)
                    slices.append(PageSlice(snap: snap, viewportContentY: maxScrollY,
                                            contentStart: drawnEndY, contentEnd: tailContentEnd))
                    self.screenshotLogger.info("captureScrolling: tail-clamp recovery added [\(Int(drawnEndY)),\(Int(tailContentEnd))] (was missing)")
                    drawnEndY = max(drawnEndY, tailContentEnd)
                }

                self.screenshotLogger.info("captureScrolling: \(pageCount) pages → \(Int(finalSize.width))x\(Int(finalSize.height)) drawnEnd=\(Int(drawnEndY))/turnBottom=\(Int(turnBottomY))")
                chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) END pages=\(pageCount) slices=\(slices.count) drawnEnd=\(String(format: "%.1f", drawnEndY)) turnBottom=\(String(format: "%.1f", turnBottomY)) coverageGap=\(String(format: "%.1f", turnBottomY - drawnEndY))")
                // SLICE-LEVEL DIAGNOSTIC: dump every slice's content
                // start/end + viewport origin. If the symptom is top-blank,
                // the first slice's contentStart should equal turnTopY. If
                // it's > turnTopY, we know the gap exactly.
                for (i, s) in slices.enumerated() {
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) slice[\(i)] contentStart=\(String(format: "%.1f", s.contentStart)) contentEnd=\(String(format: "%.1f", s.contentEnd)) viewportContentY=\(String(format: "%.1f", s.viewportContentY)) snap=\(String(format: "%.0fx%.0f", s.snap.size.width, s.snap.size.height))")
                }
                if let firstSlice = slices.first {
                    let topGap = firstSlice.contentStart - turnTopY
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) TOP-GAP=\(String(format: "%.1f", topGap)) (first slice content start minus turnTopY; positive = top of turn missing from canvas)")
                }
            }

            // Pass 2: composite the collected page snapshots into the final
            // canvas. All page bitmaps already exist as independent
            // UIImages — no nested drawHierarchy here.
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) BEGIN finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) sliceCount=\(slices.count)")
            let image = renderer(size: finalSize, format: format, bg: bg) { _ in
                for (i, slice) in slices.enumerated() {
                    let sliceH = slice.contentEnd - slice.contentStart
                    guard sliceH > 0, let cg = slice.snap.cgImage else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] SKIP sliceH=\(String(format: "%.1f", sliceH)) hasCG=\(slice.snap.cgImage != nil)")
                        continue
                    }
                    let viewportYStart = slice.contentStart - slice.viewportContentY
                    let srcPx = CGRect(
                        x: 0,
                        y: viewportYStart * scale,
                        width: cvWidth * scale,
                        height: sliceH * scale
                    )
                    let dstY = slice.contentStart - turnTopY
                    if let cropped = cg.cropping(to: srcPx) {
                        let dst = CGRect(x: 0, y: dstY,
                                         width: cvWidth, height: sliceH)
                        UIImage(cgImage: cropped, scale: scale, orientation: .up).draw(in: dst)
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] BLIT viewportYStart=\(String(format: "%.1f", viewportYStart)) srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) dstY=\(String(format: "%.1f", dstY)) dstH=\(String(format: "%.1f", sliceH))")
                    } else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] CROP FAILED srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) cgSize=\(cg.width)x\(cg.height)")
                    }
                }
            }
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) END image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height)) scale=\(image.scale)")

            cv.overrideUserInterfaceStyle = savedOverride
            cv.backgroundColor = savedCvBg
            cv.superview?.backgroundColor = savedParentBg

            // DEBUG: sample final image pixel
            if let cg = image.cgImage,
               let dp = cg.dataProvider, let data = dp.data,
               let ptr = CFDataGetBytePtr(data) {
                let bpp = cg.bitsPerPixel / 8
                let bpr = cg.bytesPerRow
                // Sample at (10, 10) — should be the background
                let offset = 10 * bpr + 10 * bpp
                let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                let a = bpp >= 4 ? ptr[offset+3] : 255
                screenshotLogger.info("captureScrolling [DEBUG] FINAL image pixel(10,10) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height)")
            }

            cv.contentOffset = savedOffset
            cv.layoutIfNeeded()
            self.scrollMode = savedScrollMode
            self.clampAfterSessionLoad = savedClampAfterSessionLoad
            chatScreenshotLogger.info("[Stage6-Exit] \(ms()) restored cv.contentOffset=\(String(format: "%.1f", savedOffset.y)) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse") returning image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height))")

            return image
        }

        private func renderer(size: CGSize, format: UIGraphicsImageRendererFormat, bg: UIColor,
                              actions: @escaping (UIGraphicsImageRendererContext) -> Void) -> UIImage {
            let r = UIGraphicsImageRenderer(size: size, format: format)
            return r.image { ctx in
                bg.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                actions(ctx)
            }
        }
}
