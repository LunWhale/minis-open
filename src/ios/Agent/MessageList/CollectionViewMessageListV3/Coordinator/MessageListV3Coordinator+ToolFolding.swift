//
//  MessageListV3Coordinator+ToolFolding.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Tool-call folding [T-fold-consecutive-tools]: ToolFoldRun, the fold plan,
//  group toggle with anchored re-measure, and the reconfigure-all/visible
//  helpers that sat in this section.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ToolFolding" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // === Tool call folding [T-fold-consecutive-tools] ===
        /// One folded run of tool calls in the current snapshot.
        struct ToolFoldRun: Equatable {
            let messageId: UUID
            /// Expanded-state key: the first member's provider `toolUseId`,
            /// which survives a session reload (block ids are regenerated on
            /// every load); the block id when there is none.
            let key: String
            let firstBlockId: UUID
            let memberIds: [UUID]
            let group: ToolFoldPlanner.Group
            /// [T-fold-tool-duration] Summed execution time of the folded
            /// tool calls; nil when none of them recorded one.
            let duration: TimeInterval?
        }
        // MARK: - Tool call folding [T-fold-consecutive-tools]

        /// The runs of tool calls to fold in `messages` right now (see
        /// `ToolFoldPlanner` for the rule). Empty while the setting is off.
        ///
        /// [T-fold-at-request-end] WHEN: the message the agent loop is writing
        /// into (`vm.toolFoldRunningMessageId`) is planned only up to its fold
        /// horizon — the last block of the latest request that ended with a
        /// reply of at least 2 lines (`vm.toolFoldSeparators`). So nothing
        /// folds while a reply streams or a tool runs, and a run already folded
        /// cannot grow mid-task (blocks past the horizon are not planned). Every
        /// other message — a finished task, history — is planned whole, without
        /// the line rule.
        ///
        /// Folding swaps several rows for one. At the bottom that reads as the
        /// capsules above the reply closing up. While the user is scrolled up
        /// reading, though, removing rows would shift what they are looking
        /// at, so a run that has never been folded is held back (`deferred`)
        /// when it belongs to the running message OR its blocks are on the
        /// list right now as separate rows; it folds on the next plan after
        /// they return to the bottom. [T-fold-browse-hold] The second half
        /// covers the end of a task: every run of the finished message folds
        /// then, and one above the viewport used to pull the reply the user
        /// was reading up by its height (the list does not compensate rows
        /// removed above the viewport). A session just opened has never shown
        /// those rows (fresh block ids), so it still folds at once.
        func planToolFolds(messages: [ChatMessage])
            -> (runs: [UUID: [ToolFoldRun]], deferred: Bool) {
            guard ToolFoldPlanner.isEnabled, let vm else { return ([:], false) }
            let browsing = scrollMode == .userBrowsing
            let runningId = vm.toolFoldRunningMessageId
            var runsByMessage: [UUID: [ToolFoldRun]] = [:]
            var deferred = false
            // [T-fold-browse-hold] The rows on the list before this plan, built
            // only when a not-yet-folded run is met while browsing (never on
            // the common paths: not browsing, or every run already folded).
            var shownRows: Set<MessageListItem>?
            func isShownUnfolded(_ messageId: UUID, _ blockId: UUID) -> Bool {
                if shownRows == nil { shownRows = Set(previousSnapshotIds) }
                return shownRows?.contains(.assistantBlock(messageId, blockId)) ?? false
            }
            for message in messages where message.role == .assistant {
                let isRunning = message.id == runningId
                let horizon = ToolFoldPlanner.foldHorizon(for: message, runningMessageId: runningId,
                                                          separators: vm.toolFoldSeparators)
                guard horizon > 0 else { continue }
                // [T-share-fold-tools] The same runs the share export folds.
                let folded = ToolFoldPlanner.foldedRuns(in: Array(message.blocks.prefix(horizon)))
                guard !folded.isEmpty else { continue }
                var runs: [ToolFoldRun] = []
                for run in folded {
                    if ToolFoldPlanner.holdsBack(browsing: browsing,
                                                 alreadyFolded: presentedToolGroupKeys.contains(run.key),
                                                 inRunningMessage: isRunning,
                                                 shownAsRows: { isShownUnfolded(message.id, run.firstBlockId) }) {
                        deferred = true
                        continue
                    }
                    runs.append(ToolFoldRun(messageId: message.id, key: run.key, firstBlockId: run.firstBlockId,
                                            memberIds: run.memberIds, group: run.group,
                                            duration: run.duration))
                }
                if !runs.isEmpty { runsByMessage[message.id] = runs }
            }
            return (runsByMessage, deferred)
        }

        #if DEBUG
        /// [T-scroll-jitter-fold-diag] Scroll state for diagnostics events:
        /// mode, finger down (trk), decelerating (dec).
        func scrollStateTag(_ cv: UICollectionView) -> String {
            (scrollMode == .autoScrolling ? "auto" : "browse")
                + (cv.isTracking ? "+trk" : "") + (cv.isDecelerating ? "+dec" : "")
        }
        #endif

        /// Re-apply the snapshot if the fold plan no longer matches the list.
        ///
        /// Folding depends on things that do not otherwise re-snapshot: a
        /// request ending with a long-enough reply, the turn ending, the user
        /// returning to the bottom ([T-fold-at-request-end]). Comparing plans
        /// first keeps these triggers free when nothing would change.
        func resnapshotIfToolFoldsChanged(caller: String) {
            guard let vm, !vm.isLoadingSession else { return }
            let messages = vm.messages.filter { !$0.isInternalBridge }
            let planned = planToolFolds(messages: messages)
            #if DEBUG
            // [T-scroll-jitter-fold-diag] Every re-plan, including the ones that
            // change nothing or are held back while the user browses.
            if ScrollMetricsRecorder.shared.isEnabled, let cv = viewController?.collectionView {
                let outcome = planned.runs == toolFoldRunsByMessage ? "unchanged"
                    : (vm.streamingUIUpdatesSuspended ? "pending" : "apply")
                ScrollMetricsRecorder.shared.record(kind: "fold",
                    a: Double(toolFoldRunsByMessage.values.reduce(0) { $0 + $1.count }),
                    b: Double(planned.runs.values.reduce(0) { $0 + $1.count }),
                    pos: scrollStateTag(cv), offset: Double(cv.contentOffset.y),
                    note: "caller=\(caller) outcome=\(outcome) deferred=\(planned.deferred)")
            }
            #endif
            guard planned.runs != toolFoldRunsByMessage else {
                toolFoldDeferred = planned.deferred
                return
            }
            if vm.streamingUIUpdatesSuspended {
                hasPendingSnapshot = true
                return
            }
            AppLogger(category: "ToolFold").info("[ToolFold] re-plan caller=\(caller) runs=\(toolFoldRunByFirstBlock.count)→\(planned.runs.values.reduce(0) { $0 + $1.count })")
            applySnapshot(messages: vm.messages, caller: caller)
        }

        /// Open or close one folded run, keeping its row where it is on screen.
        ///
        /// Two changes happen at once. The run's blocks enter or leave the list
        /// (a structural apply), and the row itself re-renders — chevron, and a
        /// different content key — so it goes through the same full
        /// invalidation as a thinking block toggle ([T-thinking-collapse-blank]):
        /// clear the cell's own height cache, invalidate the layout's, then
        /// reconfigure, apply, and invalidate the layout.
        func toggleToolGroup(firstBlockId: UUID) {
            let log = AppLogger(category: "ToolFold")
            guard let vm, let run = toolFoldRunByFirstBlock[firstBlockId],
                  let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else {
                log.warning("[ToolFold] toggle MISS group=\(firstBlockId.uuidString.prefix(8))")
                return
            }
            let item = MessageListItem.toolGroup(run.messageId, firstBlockId)
            guard let oldIdx = ds.snapshot().indexOfItem(item) else {
                log.warning("[ToolFold] toggle MISS group=\(firstBlockId.uuidString.prefix(8)) not in snapshot")
                return
            }
            // Where the row sits in the viewport now, to put it back there.
            let oldIp = IndexPath(item: oldIdx, section: 0)
            let anchorY = (cv.layoutAttributesForItem(at: oldIp)?.frame.minY ?? cv.contentOffset.y) - cv.contentOffset.y

            let expanding = !expandedToolGroups.contains(run.key)
            if expanding {
                expandedToolGroups.insert(run.key)
            } else {
                expandedToolGroups.remove(run.key)
            }
            // Without this, a list pinned to the bottom keeps the bottom in
            // place and the newly opened calls push the row up and out of
            // sight — the tap would look like it did nothing.
            scrollMode = .userBrowsing

            applySnapshot(messages: vm.messages, caller: "toolGroupToggle")

            guard let idx = ds.snapshot().indexOfItem(item) else { return }
            let ip = IndexPath(item: idx, section: 0)
            (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
            layout.invalidateHeight(at: idx)
            var snap = ds.snapshot()
            snap.reconfigureItems([item])
            ds.apply(snap, animatingDifferences: false)
            layout.invalidateLayout()
            cv.layoutIfNeeded()

            if let newMinY = cv.layoutAttributesForItem(at: ip)?.frame.minY {
                let minOff = -cv.adjustedContentInset.top
                let maxOff = max(minOff, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                let target = min(max(newMinY - anchorY, minOff), maxOff)
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
                }
            }
            if isNearBottom() { scrollMode = .autoScrolling }
            log.info("[ToolFold] toggle group=\(firstBlockId.uuidString.prefix(8)) expanded=\(expanding) members=\(run.memberIds.count) idx=\(oldIdx)→\(idx) anchorY=\(String(format: "%.1f", anchorY))")
        }

        /// [T-user-ask-toggle-drift] A cell the user tapped open or shut
        /// (an answered user_ask card) changes height in place: its top stays
        /// where it was on screen and only its bottom moves.
        ///
        /// The plain `.thinkingBlockToggled` path re-measures through the
        /// estimate - the collapse to it lands in prepare() with no offset
        /// change (top fixed), the growth back to the real height goes through
        /// the layout's visible-cell compensation (bottom fixed). An expand
        /// therefore grew upward and a collapse shrank downward, and each pair
        /// moved the list up by the cell's height change (user recording:
        /// -6pt on expand, -142pt on collapse, every cycle).
        ///
        /// Same shape as `toggleToolGroup`: a tap is reading, not following,
        /// so the bottom pin must not move the list; re-measure now, put the
        /// top back, then - after an expansion only - one short scroll so the
        /// opened content is visible without losing the top.
        func remeasureKeepingTop(item: MessageListItem, index i: Int, blockId: UUID,
                                         request: ToggleRequest? = nil) {
            guard let cv = viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout,
                  let ds = dataSource else {
                request?.run()
                return
            }
            let log = AppLogger(category: "ThinkingCollapse")
            let ip = IndexPath(item: i, section: 0)
            let oldFrame = cv.layoutAttributesForItem(at: ip)?.frame
            let anchorY = (oldFrame?.minY ?? cv.contentOffset.y) - cv.contentOffset.y
            let oldHeight = oldFrame?.height ?? 0
            // [T-user-ask-expand-anim] Reduce Motion: the same single pass,
            // just without animation.
            let duration = ToggleAnchorMath.animationDuration(reduceMotion: UIAccessibility.isReduceMotionEnabled)

            scrollMode = .userBrowsing
            layout.topAnchoredIndex = i
            var newFrame: CGRect?
            var reveal: CGFloat = 0

            // Everything that changes what is on screen happens in this one
            // pass, in one runloop turn: the content switches state AND the
            // cell gets its new height before the next frame is drawn. The
            // flicker came from the two landing a frame apart (content first,
            // size a runloop later through the async notification hop), with
            // the content centred in the stale cell for that frame.
            let changes = {
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell,
                   let attrs = layout.layoutAttributesForItem(at: ip)?.copy() as? UICollectionViewLayoutAttributes {
                    // [T-user-ask-expand-overlap] Flip the state AND hand the
                    // cell a fresh hosting configuration in the same step, then
                    // measure. Measuring right after the flip alone returned the
                    // OLD height (the hosting view only picks the new state up
                    // on its next update): that stale height became the cell's
                    // cache, and while a message streams the cell serves its
                    // cache to every later pass - so a card opened under a
                    // streaming/thinking reply kept its collapsed height and
                    // overlapped the text above and the thinking row below.
                    // configureCell clears the cell's height cache; the fresh
                    // root view reads the new state, so the measure is real -
                    // and that correct height is what streaming passes reuse.
                    withAnimation(duration.map { .easeOut(duration: $0) }) {
                        _ = request?.run()
                        // [T-user-ask-history-seed] Drop this row's cached and
                        // memoized height BEFORE configureCell. The memo is keyed
                        // by content, not by expanded state, so configureCell
                        // would otherwise seed the height measured for the OLD
                        // state, and the seed makes the measure below return it
                        // without measuring (device log on a finished message:
                        // `[MemoSeed] … h=64.0` then `ANCHORED h=64.0→64.0`, the
                        // opened card overlapping its neighbours). Streaming
                        // messages are never seeded, which is why this only
                        // showed up in history. The new height is memoized by
                        // that measure, so scrolling back still skips it.
                        layout.invalidateHeight(at: i)
                        self.configureCell(cell, item: item, indexPath: ip)
                    }
                    // The hosting view applies a new root view on its next
                    // update; run that update now (a layout pass of the cell's
                    // content) so the measure below sees the new state rather
                    // than the previous render (device log: measured heights
                    // lagged one tap behind without this).
                    cell.contentView.setNeedsLayout()
                    cell.contentView.layoutIfNeeded()
                    cell.clearCachedHeight()
                    let fitted = cell.preferredLayoutAttributesFitting(attrs)
                    layout.setMeasuredHeight(fitted.size.height, at: i)
                } else {
                    _ = request?.run()
                    // Cell not on screen: the old re-measure path.
                    (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateHeight(at: i)
                    var snap = ds.snapshot()
                    snap.reconfigureItems([item])
                    ds.apply(snap, animatingDifferences: false)
                }
                layout.invalidateLayout()
                // The list strips UIKit animations from its layout passes
                // (NoAnimationCollectionView); let this one pass animate so the
                // rows around the card move with it instead of jumping.
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = duration != nil
                cv.layoutIfNeeded()
                (cv as? NoAnimationCollectionView)?.animatesNextLayoutPass = false

                guard let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return }
                newFrame = frame
                let minOff = -cv.adjustedContentInset.top
                let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                var target = ToggleAnchorMath.anchoredOffset(newMinY: frame.minY, anchorY: anchorY,
                                                             minOffset: minOff, maxOffset: maxOff)
                if frame.height > oldHeight + 0.5 {
                    let visibleTop = target + cv.adjustedContentInset.top
                    let visibleBottom = target + cv.bounds.height - cv.adjustedContentInset.bottom
                    reveal = ToggleAnchorMath.revealShift(cellMinY: frame.minY, cellMaxY: frame.maxY,
                                                          visibleTop: visibleTop, visibleBottom: visibleBottom)
                    reveal = min(reveal, max(0, max(minOff, maxOff) - target))
                    target += reveal
                }
                if abs(target - cv.contentOffset.y) > 0.5 {
                    cv.contentOffset = CGPoint(x: cv.contentOffset.x, y: target)
                }
            }
            let finish = { [weak self, weak layout] in
                guard let self else { return }
                if self.isNearBottom() { self.scrollMode = .autoScrolling }
                // Keep the anchor through the next runloop turns: a late
                // SwiftUI re-measure of the same cell must not take the
                // visible-cell compensation either.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if layout?.topAnchoredIndex == i { layout?.topAnchoredIndex = nil }
                }
            }
            if let duration {
                // Short ease-out, no spring overshoot; a tap during the
                // animation starts from where things are on screen.
                UIView.animate(withDuration: duration, delay: 0,
                               options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                               animations: changes, completion: { _ in finish() })
            } else {
                changes()
                finish()
            }
            log.info("[ThinkingCollapse] ANCHORED block=\(blockId.uuidString.prefix(8)) idx=\(i) h=\(String(format: "%.1f→%.1f", oldHeight, newFrame?.height ?? -1)) anchorY=\(String(format: "%.1f", anchorY)) offset→\(String(format: "%.1f", cv.contentOffset.y)) reveal=\(String(format: "%.1f", reveal)) animated=\(duration != nil) request=\(request != nil)")
            // [T-crash-breadcrumbs] Numbers only. A user toggle / end-of-stream
            // collapse, not a per-frame path.
            CrashBreadcrumbs.record("think.toggle",
                                    detail: "idx=\(i) h=\(Int(oldHeight))->\(Int(newFrame?.height ?? -1)) offset=\(Int(cv.contentOffset.y)) animated=\(duration != nil ? 1 : 0)")
        }

        func reconfigureAllCells() {
            viewController?.messageListLayout?.clearHeightCache()
            // [T-ios-listsessions-perf] Not cleared: the font size is IN the
            // key, so the post-change measurements miss and re-measure while
            // the pre-change entries simply age out of the LRU. Clearing would
            // throw away every other session's still-valid heights to solve a
            // problem the key already solves.
            userBubbleHeightCache.removeAll()
            reconfigureVisibleCells()
        }

        /// Reconfigure all cells without clearing the height cache.
        /// Used after compact to update opacity without losing measured heights.
        func reconfigureVisibleCells() {
            var snapshot = dataSource.snapshot()
            let items = snapshot.itemIdentifiers
            guard !items.isEmpty else { return }
            snapshot.reconfigureItems(items)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
        }
}
