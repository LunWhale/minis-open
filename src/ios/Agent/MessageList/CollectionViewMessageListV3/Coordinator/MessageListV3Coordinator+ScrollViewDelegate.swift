//
//  MessageListV3Coordinator+ScrollViewDelegate.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  UICollectionViewDataSourcePrefetching and UIScrollViewDelegate callbacks,
//  scroll-decel instrumentation, and the post-interaction settle pass.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ScrollViewDelegate" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - UICollectionViewDataSourcePrefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let vm, let layout = viewController?.messageListLayout else { return }
            // Items below come from previousSnapshotIds (snapshot-locked) — the
            // messages they're resolved against must be the SAME locked array,
            // or a concurrent loadSession() swap makes every lookup miss and
            // estimates collapse to the 44pt fallback. [T-ios-blocks-lost-render]
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth
            for indexPath in indexPaths {
                let index = indexPath.item
                // Skip if we already have a measured or precalculated height.
                // estimateItemHeight calls NSAttributedString.boundingRect which invokes
                // CoreText font shaping (GSUB lookups) — for complex markdown blocks this
                // can take hundreds of ms per cell and accumulate into a watchdog crash
                // when the user scrolls back through long history. See 3a9fb98 for the
                // matching configureCell guard.
                guard layout.cachedHeight(at: index) == nil,
                      !layout.hasPrecalcHeight(at: index) else { continue }
                guard index < previousSnapshotIds.count else { continue }
                let item = previousSnapshotIds[index]
                let est = Self.estimateItemHeight(item, messages: messages, width: width)
                layout.setEstimatedHeight(est, at: index)
            }
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][willBeginDragging] offset=\(String(format: "%.0f", scrollView.contentOffset.y)) contentSize=\(String(format: "%.0f", scrollView.contentSize.height)) visibleCells=\(viewController?.collectionView?.visibleCells.count ?? -1)")
            #if DEBUG
            // [DecelDisplayLink] Safety: if the user grabs again mid-decel, stop
            // the previous link so it doesn't keep ticking under the new gesture.
            stopDecelDisplayLink()
            #endif
            scrollMode = .userBrowsing
            // Cancel session-load clamp immediately — user has started interacting.
            clampAfterSessionLoad = false
            // A manual drag breaks the up-button's turn-walk chain: the next tap
            // should re-anchor to wherever the user landed, not continue the old
            // sequence.
            lastJumpedUserId = nil
            viewController?.messageListLayout?.deferSelfSizing = true
            vm?.setStreamingUIUpdatesSuspended(true)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // [ScrollDecel] Fires the instant the finger lifts and UIKit has
            // projected where the deceleration will land. Logs the launch
            // velocity + projected target so the upcoming decel can be
            // correlated to the content region it's about to render.
            decelTargetOffset = targetContentOffset.pointee.y
            #if DEBUG
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][willEndDragging] vy=\(String(format: "%.0f", velocity.y))pt/s offset=\(String(format: "%.0f", scrollView.contentOffset.y)) → target=\(String(format: "%.0f", decelTargetOffset)) projDist=\(String(format: "%.0f", decelTargetOffset - scrollView.contentOffset.y)) cs=\(String(format: "%.0f", scrollView.contentSize.height))")
            #endif
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                settleAfterInteraction(scrollView)
            }
        }

        func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION START — the marker the analysis hangs
            // off. Every subsequent slow frame is logged as "+Xms into decel".
            let now = CACurrentMediaTime()
            decelStartTime = now
            decelLastFrameTime = now
            decelStartOffset = scrollView.contentOffset.y
            decelFrameCount = 0
            decelSlowFrameCount = 0
            #if DEBUG
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][BEGIN] offset=\(String(format: "%.0f", decelStartOffset)) target=\(String(format: "%.0f", decelTargetOffset)) decelDist=\(String(format: "%.0f", decelTargetOffset - decelStartOffset)) visibleCells=\(visibleN) deferSelfSizing=\((viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
            // [DecelDisplayLink] Start the real-frame-rate meter only for this
            // decel phase. Drops/summary go to the log; CADisplayLink is removed
            // in scrollViewDidEndDecelerating below.
            startDecelDisplayLink()
            #endif
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION END — summarize the phase: total
            // duration, frames, how many were slow (dropped), final offset.
            if decelStartTime > 0 {
                #if DEBUG
                let dur = (CACurrentMediaTime() - decelStartTime) * 1000
                AppLogger(category: "ScrollDecel").info("[ScrollDecel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))")
                // [DecelDisplayLink] Print the REAL frame-rate summary for this
                // decel and stop the link. If actualFps≈vsync and drops=0 the
                // visual "jitter" wasn't a dropped frame at all.
                logDecelDisplayLinkSummary()
                stopDecelDisplayLink()
                #endif
                decelStartTime = 0
            }
            DispatchQueue.main.async { [weak self] in
                self?.settleAfterInteraction(scrollView)
            }
        }

        /// [ScrollDecel] Called from scrollViewDidScroll. While decelerating,
        /// measures the gap since the previous frame; a gap above the threshold
        /// is a dropped/janky frame and gets logged with how far into the decel
        /// it happened, the current offset/scroll direction, and how many cells
        /// are on screen (heavy cells = expensive sizeThatFits). This is the
        /// "which stage of the decel started the costly render" signal.
        private func logDecelFrameIfSlow(_ scrollView: UIScrollView) {
            #if DEBUG
            guard decelStartTime > 0, scrollView.isDecelerating else { return }
            let now = CACurrentMediaTime()
            let gap = now - decelLastFrameTime
            decelLastFrameTime = now
            decelFrameCount += 1
            guard gap > decelSlowFrameThreshold else { return }
            decelSlowFrameCount += 1
            let sinceStart = (now - decelStartTime) * 1000
            let off = scrollView.contentOffset.y
            let dir = off >= decelStartOffset ? "↓" : "↑"
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").warning("[ScrollDecel][SLOW-FRAME] +\(String(format: "%.0f", sinceStart))ms into decel gap=\(String(format: "%.0f", gap * 1000))ms offset=\(String(format: "%.0f", off))\(dir) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - off)) visibleCells=\(visibleN) frame#\(self.decelFrameCount)")
            #endif
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [T-scroll-sync-defer] Hold back sync refreshes while the user flings.
            if scrollView.isTracking || scrollView.isDecelerating {
                ChatScrollActivity.noteMoving()
            }
            // [T-ios-wheel-scroll-pin-fight] Leave auto-follow when the user
            // scrolls up with an INDIRECT pointer (mouse wheel, trackpad,
            // iPhone Mirroring).
            //
            // `scrollViewWillBeginDragging` is the only ordinary way out of
            // `.autoScrolling` (the other two are scroll-to-top and the
            // screenshot pass), and indirect scrolling never fires it -- it is
            // not a touch drag. So the mode stayed `.autoScrolling` no matter
            // how far the user scrolled, and the contentSize KVO re-pinned the
            // viewport on every self-sizing tick: at the bottom, where cells
            // are still measuring, that reads as the view repeatedly yanking
            // itself back down. (The `[KVO] PIN-WHILE-SCROLLING ... MODE SHOULD
            // BE userBrowsing` line exists for exactly this case.)
            //
            // Scoped to INDIRECT scrolling only, so a touch-only device cannot
            // reach this at all and its behaviour is bit-for-bit unchanged --
            // see `isIndirectScroll`. Within that scope the trigger is the
            // offset moving up, and every other condition is a veto. Each guard
            // below protects one behaviour that must survive:
            //
            //   - moved up by more than noise -> streaming (offset grows) and
            //     cell self-sizing jitter (a few pt) can never trigger it;
            //   - not animating to bottom -> the scroll-to-bottom button's
            //     animation travels upward and must not cancel itself;
            //   - not in the session-load clamp -> the first-load settle window
            //     adjusts the offset on its own and is not user intent.
            //
            // The way back in is untouched: `settleAfterInteraction` re-acquires
            // auto-scroll only within `reacquireAutoScrollThreshold` (4pt) of the
            // bottom, the tight rule [T-ios-trackpad-scroll-jitter] already
            // settled on. Touch dragging is unaffected -- it still goes through
            // `scrollViewWillBeginDragging` and gets there first.
            let offsetY = scrollView.contentOffset.y
            if scrollMode == .autoScrolling,
               Self.isIndirectScroll(scrollView),
               !isAnimatingScrollToBottom,
               !clampAfterSessionLoad,
               offsetY < lastDidScrollOffsetY - indirectScrollExitThreshold {
                AppLogger(category: "ScrollDiag").info("[ScrollDiag][indirectScrollExit] offset \(String(format: "%.0f", lastDidScrollOffsetY))→\(String(format: "%.0f", offsetY)) panState=\(scrollView.panGestureRecognizer.state.rawValue) touches=\(scrollView.panGestureRecognizer.numberOfTouches) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating) — auto→browse")
                scrollMode = .userBrowsing
                // Same follow-ups willBeginDragging performs for a touch drag.
                lastJumpedUserId = nil
                viewController?.messageListLayout?.deferSelfSizing = true
            }
            lastDidScrollOffsetY = offsetY

            // [ScrollDecel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gap exceeded).
            logDecelFrameIfSlow(scrollView)
            #if DEBUG
            // [T-ios-scroll-metrics-ring] Per-frame offset/contentSize sample —
            // lets the pulled trace reconstruct exactly when visible content
            // shifted vs when the offset moved (jitter = the two disagreeing).
            ScrollMetricsRecorder.shared.record(
                kind: "scroll", a: scrollView.contentOffset.y,
                b: scrollView.contentSize.height,
                pos: scrollView.isDecelerating ? "decel" : (scrollView.isTracking ? "drag" : "idle"),
                offset: scrollView.contentOffset.y)
            #endif
            if let vm {
                // IMPORTANT: only write when the value actually changes.
                // `isNearBottom` is `@Published`, and every write broadcasts
                // `objectWillChange` to every SwiftUI view observing the VM —
                // triggering a full AttributeGraph invalidation+re-evaluation
                // pass on the SwiftUI update thread. On iPhone 8 this was
                // burning 100% of one CPU core every scroll frame.
                let nb = isNearBottom()
                if vm.isNearBottom != nb {
                    #if DEBUG
                    // Diagnostics: record every isNearBottom TRANSITION with the
                    // scroll position and the user-turn the viewport is in, plus
                    // the resulting up/down-button visibility (!messages.empty &&
                    // !isNearBottom). Only fires on change, so it stays off the
                    // per-frame hot path. ScrollMetricsRecorder is DEBUG-only.
                    let turn = currentViewportUserTurn()
                    ScrollMetricsRecorder.shared.record(kind: "nbChange",
                        idx: turn.index, a: nb ? 1 : 0, b: Double(turn.total),
                        pos: "buttonsVisible=\(!vm.messages.isEmpty && !nb)",
                        offset: Double(scrollView.contentOffset.y),
                        note: Self.nbDump(viewController?.collectionView))
                    #endif
                    vm.isNearBottom = nb
                }
                let atTop = isAtContentTop()
                if vm.isAtFirstTurn != atTop { vm.isAtFirstTurn = atTop }
                vm.contentOffsetYSignal.send(scrollView.contentOffset.y)
            }
            // Detect offset jumps right after settle
            if settleJustFinished {
                let delta = scrollView.contentOffset.y - lastLoggedOffset
                if abs(delta) > 2 {
                    AppLogger(category: "Settle").debug("[Settle] POST-SETTLE JUMP offset \(String(format: "%.1f→%.1f", lastLoggedOffset, scrollView.contentOffset.y)) delta=\(String(format: "%.1f", delta)) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating) contentSize=\(String(format: "%.1f", scrollView.contentSize.height))")
                    settleJustFinished = false
                }
            }
            // [ScrollStall] Per-second scroll trajectory: offset, distance moved
            // since last flush, mode, tracking/decel state. Helps correlate
            // hitches with offset bursts.
            scrollSamples += 1
            let now = CACurrentMediaTime()
            if now - lastScrollFlush > 1.0 {
                let off = scrollView.contentOffset.y
                let dist = abs(off - lastScrollFlushOffset)
                AppLogger(category: "ScrollStall").debug("[SCR] last1s samples=\(scrollSamples) offset=\(String(format: "%.0f", off)) Δdist=\(String(format: "%.0f", dist)) cs=\(String(format: "%.0f", scrollView.contentSize.height)) mode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") tracking=\(scrollView.isTracking ? 1 : 0) decel=\(scrollView.isDecelerating ? 1 : 0) deferred=\((self.viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
                scrollSamples = 0
                lastScrollFlushOffset = off
                lastScrollFlush = now
            }
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isAnimatingScrollToBottom = false
            // Final clamp: ensure offset doesn't exceed actual content bounds
            // after the animation completes (contentSize may have changed mid-flight).
            guard let cv = viewController?.collectionView else { return }
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            if cv.contentOffset.y > maxOff {
                cv.contentOffset.y = maxOff
            }
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            scrollMode = .userBrowsing
        }

        /// [T-ios-defer-retry-never-consumed] Recursively walks a cell's subview
        /// tree and applies `body` to every hosted `SelectableMarkdownTextView`.
        /// Mirrors `invalidateTableAttachmentsInSubviews` in
        /// MessageListInfrastructure — the markdown view is nested several
        /// levels inside the UIHostingConfiguration's view tree, so there is no
        /// direct handle on it from the cell.
        private static func forEachMarkdownTextView(in view: UIView,
                                                    _ body: (SelectableMarkdownTextView) -> Void) {
            if let tv = view as? SelectableMarkdownTextView { body(tv) }
            for sub in view.subviews { forEachMarkdownTextView(in: sub, body) }
        }

        private func settleAfterInteraction(_ scrollView: UIScrollView) {
            // Re-acquire auto-scroll only when the user settled essentially at
            // the bottom (tight threshold), not merely "near" it. This stops
            // small trackpad scrolls on iPad from snapping back to the bottom
            // and jittering. [T-ios-trackpad-scroll-jitter]
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }

            let deferredCount = layout.deferredHeightCount
            AppLogger(category: "Settle").debug("[Settle] BEGIN mode=\(scrollMode == .autoScrolling ? "auto" : "browse") nearBottom=\(nearBottom) offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height)) deferredHeights=\(deferredCount) hasPendingSnapshot=\(hasPendingSnapshot)")

            // Re-enable self-sizing so future layout passes use real heights.
            layout.deferSelfSizing = false

            // [T-ios-defer-retry-never-consumed] Now that the defer window is
            // genuinely closed, let every visible markdown view apply a
            // correction it had to skip while the window was open.
            //
            // `SelectableMarkdownTextView.invalidateCellSizeIfNeeded` bails out
            // when `deferSelfSizing` is true, logging "will retry" and arming a
            // 0.6s timer. That timer is not a reliable consumer: it can fire
            // while the user is still dragging (landing back in the same bail),
            // and once the stream stops mutating the text storage the
            // fingerprint early-exit swallows the re-measure entirely — the
            // correction is then lost until the session is re-entered. Field
            // repro 2026-08-09: three skips in one session, none consumed; the
            // 11:01:27 one left a ~197pt error on screen for the remaining 38s
            // of the log, which is why the user could screenshot the overlap.
            //
            // Only views that actually owe a correction do any work — the call
            // is an early `guard` on a Bool for everyone else, so this adds no
            // measurement to the normal settle path.
            for cell in cv.visibleCells {
                Self.forEachMarkdownTextView(in: cell) { $0.consumeDeferredCorrectionIfNeeded() }
            }

            // [SettleJitter] Evidence capture (H1): the flush below re-flows
            // frames from corrected heights but restores only the numeric
            // offset — if cells ABOVE the viewport changed height, the same
            // offset now shows different content. Anchor on the top visible
            // cell's screen-relative y before/after to quantify the jump the
            // user actually sees at decel end.
            let anchorIP = cv.indexPathsForVisibleItems.min()
            let anchorPreY = anchorIP.flatMap { layout.layoutAttributesForItem(at: $0)?.frame.minY }

            let savedOffset = cv.contentOffset.y
            isFlushing = true
            layout.applyDeferredHeights()

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            isFlushing = false

            // Restore offset
            if scrollMode == .userBrowsing {
                cv.contentOffset.y = savedOffset
            }

            // [SettleJitter] Post-flush: same anchor item, new frame. screenΔ
            // is the on-screen displacement of the content the user is looking
            // at (0 = no visible jitter from the settle flush).
            if let ip = anchorIP, let preY = anchorPreY {
                cv.layoutIfNeeded()
                let postY = layout.layoutAttributesForItem(at: ip)?.frame.minY ?? preY
                let screenDelta = (postY - cv.contentOffset.y) - (preY - savedOffset)
                #if DEBUG
                // [T-ios-scroll-metrics-ring]
                ScrollMetricsRecorder.shared.record(
                    kind: "settle", idx: ip.item, a: screenDelta, b: postY - preY,
                    offset: Double(cv.contentOffset.y),
                    note: String(format: "savedOff=%.0f", savedOffset))
                #endif
                if abs(screenDelta) > 0.5 {
                    AppLogger(category: "SettleJitter").info("[SettleJitter][settle-shift] anchor=idx\(ip.item) screenΔ=\(String(format: "%+.1f", screenDelta)) frameY \(String(format: "%.0f", preY))→\(String(format: "%.0f", postY)) offset \(String(format: "%.0f", savedOffset))→\(String(format: "%.0f", cv.contentOffset.y))")
                }
            }

            vm?.setStreamingUIUpdatesSuspended(false)

            if hasPendingSnapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "settle")
                }
            }

            lastLoggedOffset = cv.contentOffset.y
            settleJustFinished = true
            // Auto-clear after 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.settleJustFinished = false
            }
            AppLogger(category: "Settle").debug("[Settle] END offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height))")
        }
}
