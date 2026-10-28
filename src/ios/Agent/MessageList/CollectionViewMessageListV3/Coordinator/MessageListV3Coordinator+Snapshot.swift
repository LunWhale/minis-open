//
//  MessageListV3Coordinator+Snapshot.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  applySnapshot: builds MessageListItems from the messages and applies the
//  diffable snapshot (ids, reconfigures, height seeding, scroll pinning).
//  Also uniqueItems and the attachment-size-changed handler it subscribes.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +Snapshot" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// [split seam] `Section` below means CollectionViewMessageListV3.Section, which
/// was in scope inside the enclosing `extension CollectionViewMessageListV3`;
/// here it would resolve to SwiftUI.Section.
private typealias Section = CollectionViewMessageListV3.Section

extension CollectionViewMessageListV3.Coordinator {

        /// The actual `.minisAttachmentSizeChanged` work, run at most once per
        /// runloop tick with every URL that arrived in that tick.
        private func handleAttachmentSizeChanged(coalescedUrls: [String]) {
            let alog = AppLogger(category: "AttachmentSize")
            guard let cv = self.viewController?.collectionView,
                  let layout = cv.collectionViewLayout as? MessageListLayout else {
                alog.warning("[AttachmentSize] infra missing")
                return
            }
            let visibleIPs = cv.indexPathsForVisibleItems.sorted()
            var cleared = 0
            for ip in visibleIPs {
                if let cell = cv.cellForItem(at: ip) as? SelfSizingCell {
                    let before = cell.frame.size.height
                    cell.clearCachedHeight()
                    layout.invalidateHeight(at: ip.item)
                    cleared += 1
                    alog.info("[AttachmentSize] clear idx=\(ip.item) frameH=\(String(format: "%.1f", before))")
                }
            }
            // [T-attachment-cell-offscreen 2026-05-24]
            // A markdown-inline video/image whose initial estimate
            // was too small (e.g. text-only block estimator
            // returning ~50pt) is pushed off-screen by the cold
            // scroll-to-bottom — the visible-cells-only invalidate
            // above then misses it, and the cell stays at the
            // 200pt placeholder until an unrelated reconfigure
            // runs many seconds later. Always invalidate the
            // layout's height cache for ALL items so the next
            // measurement pass picks up the new attachmentBounds.
            let totalItems = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
            for idx in 0..<totalItems {
                layout.invalidateHeight(at: idx)
            }
            if let snapshot = self.dataSource?.snapshot() {
                // Reconfigure every item — cheap (no diff), forces
                // every cell that gets re-displayed to re-measure.
                // We still see a visible reflow only on cells in
                // viewport; off-screen cells just get a corrected
                // cached height for next display.
                var snap = snapshot
                snap.reconfigureItems(snapshot.itemIdentifiers)
                self.dataSource?.apply(snap, animatingDifferences: false)
            }
            // [T-attachment-defer-invalidate 2026-05-24]
            // Defer invalidateLayout to the next runloop. reconfigureItems
            // schedules a SwiftUI hosting-config update on the next
            // runloop tick; calling invalidateLayout synchronously
            // makes UIKit re-query PLAF while the cell's
            // UIHostingConfiguration still wraps the STALE
            // attributedString (with the 200pt video placeholder),
            // so systemLayoutSizeFitting returns the old 375pt
            // height, caches it as lastComputedHeight, and locks
            // the cell at the wrong size until something else
            // triggers another reconfigure (10+ seconds later
            // when the user navigates back). Letting the runloop
            // turn first ensures the new attributedString is
            // mounted in the hosting view before we re-measure.
            DispatchQueue.main.async {
                // Clear cell-side caches AGAIN after the
                // reconfigure has propagated, then ask UIKit to
                // re-measure.
                for ip in cv.indexPathsForVisibleItems {
                    (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                }
                layout.invalidateLayout()
                // While we're still in the session-load clamp
                // window, re-pin to bottom — the corrected
                // heights shift the content offset and otherwise
                // leave the user looking at the wrong region.
                if self.clampAfterSessionLoad {
                    self.scrollToLastItem()
                }
            }
            alog.info("[AttachmentSize] coalesced=\(coalescedUrls.count) urls=\(coalescedUrls.map { $0.suffix(40) }.joined(separator: ",")) cleared=\(cleared)/\(visibleIPs.count) totalInvalidated=\(totalItems) clamp=\(self.clampAfterSessionLoad)")
        }

        // MARK: - Snapshot
        /// [T-messagelist-snapshot-unique-ids] `items` with every repeat of an
        /// identifier removed (first occurrence wins). Returns the input
        /// untouched in the normal, duplicate-free case.
        static func uniqueItems(_ items: [MessageListItem], caller: String) -> [MessageListItem] {
            var seen = Set<MessageListItem>()
            seen.reserveCapacity(items.count)
            var dropped: [MessageListItem] = []
            let unique = items.filter { item in
                if seen.insert(item).inserted { return true }
                dropped.append(item)
                return false
            }
            guard !dropped.isEmpty else { return items }
            AppLogger(category: "SnapshotDiag").error("[SnapshotDiag] dropped \(dropped.count) duplicate item id(s) before apply (caller=\(caller)) first=\(dropped[0])")
            return unique
        }

        func applySnapshot(messages rawMessages: [ChatMessage], caller: String = "?") {
            guard let vm, !vm.isLoadingSession else { return }

            // [T-bridge-message-ui-leak] Single UI-collection sink for EVERY
            // path that pushes messages to the list (loadSession, live inject,
            // compact rebuild, snapshot reload, rebind…). Filter the internal
            // role-alternation bridge (#579) here so it can never surface as a
            // chat bubble regardless of which path produced it — replacing the
            // former reliance on a single filter inside loadSession, which other
            // rebuild paths bypassed (the leak seen 2026-07-24).
            let messages = rawMessages.contains(where: { $0.isInternalBridge })
                ? rawMessages.filter { !$0.isInternalBridge }
                : rawMessages
            // [T-subagent-callback-visible] Every sub agent callback renders,
            // progress and final alike.
            //
            // There used to be a dedup here ([T-agent-callback-dedup]): a final
            // report was hidden whenever the parent still held the delegate
            // block for that child, since the block already shows status, tier,
            // elapsed and opens the same detail. That was defensible on its own
            // terms and still left the transcript with no record that the sub
            // agent reported back AT ALL — and the block quietly changing state
            // is not the same as seeing the hand-off happen where it happened,
            // in order, among the other turns. Progress reports were exempted
            // first (they were invisible for minutes at a time); the final
            // report now follows for the same reason.
            //
            // The scan that built the child-id set went with it: it walked
            // every message and every block on each snapshot, and nothing reads
            // the result any more.

            // Content changed (new/removed messages) — the up-button's turn-walk
            // anchor may no longer line up, so restart it on the next tap.
            lastJumpedUserId = nil

            // Subscribe to thinking block toggle notifications (once)
            if attachmentSizeChangedSub == nil {
                attachmentSizeChangedSub = NotificationCenter.default.publisher(for: .minisAttachmentSizeChanged)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        // [T-ios-image-squish-probe §2] Coalesce a same-tick
                        // burst into ONE refresh pass. A six-image message now
                        // fires up to 12 of these (header probe + decode
                        // completion per image), and the handler below is a
                        // full-list invalidate + reconfigureItems — running it
                        // per notification is 12 back-to-back relayout storms.
                        // Notifications already arrive on main; the pending
                        // flag folds every arrival within the current runloop
                        // tick into the single async pass scheduled below.
                        guard let self else { return }
                        self.pendingAttachmentSizeUrls.append((notification.object as? String) ?? "<nil>")
                        guard !self.attachmentSizeRefreshScheduled else { return }
                        self.attachmentSizeRefreshScheduled = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.attachmentSizeRefreshScheduled = false
                            let urls = self.pendingAttachmentSizeUrls
                            self.pendingAttachmentSizeUrls.removeAll()
                            self.handleAttachmentSizeChanged(coalescedUrls: urls)
                        }
                    }
            }

            if attachMountSub == nil {
                attachMountSub = NotificationCenter.default.publisher(for: .minisUserAttachmentsMounted)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        let alog = AppLogger(category: "AttachMount")
                        guard let self,
                              let msgId = notification.object as? UUID,
                              let cv = self.viewController?.collectionView,
                              let layout = self.viewController?.messageListLayout,
                              let ds = self.dataSource else { return }
                        // Targeted, O(1): only the mounted message's own cell.
                        // Mirrors the .thinkingBlockToggled handler — clear BOTH
                        // height layers (the layout's index cache, so the next
                        // seed's corrected precalc can land past the
                        // occupied-slot guard, and the cell's width-matched
                        // cache, so PLAF stops short-circuiting to the stale
                        // tile-less height), then reconfigure so the hosting
                        // view re-measures with the tiles actually mounted.
                        // Deliberately NOT a visible-cells sweep — one message
                        // mounted, one cell invalidated (FB13213926 discipline:
                        // no extra hosting-graph re-entries).
                        let snapshot = ds.snapshot()
                        let item = MessageListItem.wholeMessage(msgId)
                        guard let idx = snapshot.itemIdentifiers.firstIndex(of: item) else {
                            alog.info("[AttachMount] msg=\(msgId.uuidString.prefix(8)) not in snapshot — nothing to invalidate")
                            return
                        }
                        let ip = IndexPath(item: idx, section: 0)
                        (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                        layout.invalidateHeight(at: idx)
                        var snap = snapshot
                        snap.reconfigureItems([item])
                        ds.apply(snap, animatingDifferences: false)
                        layout.invalidateLayout()
                        alog.info("[AttachMount] msg=\(msgId.uuidString.prefix(8)) idx=\(idx) invalidated + reconfigured")
                    }
            }

            if thinkingToggleSub == nil {
                thinkingToggleSub = NotificationCenter.default.publisher(for: .thinkingBlockToggled)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        let tlog = AppLogger(category: "ThinkingCollapse")
                        guard let self else {
                            tlog.warning("[ThinkingCollapse] sink fired but self gone")
                            return
                        }
                        guard let blockId = notification.object as? UUID else {
                            tlog.warning("[ThinkingCollapse] notif object not UUID: \(String(describing: notification.object))")
                            return
                        }
                        guard let cv = self.viewController?.collectionView,
                              let layout = cv.collectionViewLayout as? MessageListLayout,
                              let snapshot = self.dataSource?.snapshot() else {
                            tlog.warning("[ThinkingCollapse] block=\(blockId.uuidString.prefix(8)) infra missing: cv=\(self.viewController?.collectionView != nil) ds=\(self.dataSource != nil)")
                            return
                        }
                        // [T-thinking-collapse-blank] The layout-side
                        // `invalidateHeight` only wipes the MessageListLayout
                        // `heightCache`, not the per-cell `lastComputedHeight`
                        // on SelfSizingCell. Without also clearing the
                        // cell-side cache, the next
                        // `preferredLayoutAttributesFitting` short-circuits
                        // via the broad-width cache and returns the OLD
                        // expanded height (~300pt) for a cell whose SwiftUI
                        // body now renders just the 36pt header — producing
                        // a tall empty gap below the collapsed pill (user
                        // screenshot 2026-05-19). Clear both caches here
                        // and reconfigure so UIHostingConfiguration
                        // re-measures from scratch. Trace each step so a
                        // future report can be diagnosed from logs alone.
                        var matched = false
                        let anchorTop = notification.userInfo?[ToggleAnchorMath.anchorTopKey] as? Bool == true
                        for (i, item) in snapshot.itemIdentifiers.enumerated() {
                            if case .assistantBlock(_, let bid) = item, bid == blockId {
                                matched = true
                                if anchorTop {
                                    let request = notification.userInfo?[ToggleAnchorMath.toggleRequestKey] as? ToggleRequest
                                    self.remeasureKeepingTop(item: item, index: i, blockId: blockId, request: request)
                                    break
                                }
                                let beforeLayout = layout.cachedHeight(at: i)
                                let beforePrecalc = layout.precalcHeight(at: i)
                                let ip = IndexPath(item: i, section: 0)
                                let cellOpt = cv.cellForItem(at: ip) as? SelfSizingCell
                                let frameH = cellOpt?.frame.size.height ?? -1
                                if let cell = cellOpt {
                                    cell.clearCachedHeight()
                                }
                                layout.invalidateHeight(at: i)
                                var snap = snapshot
                                snap.reconfigureItems([item])
                                self.dataSource?.apply(snap, animatingDifferences: false)
                                layout.invalidateLayout()
                                tlog.info("[ThinkingCollapse] HIT block=\(blockId.uuidString.prefix(8)) idx=\(i) cellFound=\(cellOpt != nil) frameH=\(String(format: "%.1f", frameH)) beforeLayout=\(beforeLayout.map { String(format: "%.1f", $0) } ?? "nil") beforePrecalc=\(beforePrecalc.map { String(format: "%.1f", $0) } ?? "nil")")
                                // Defer one runloop tick to capture the
                                // post-reconfigure measurement and confirm
                                // the cell actually shrank/grew. If the
                                // delta is small the cache invalidation
                                // didn't take — that's the case to escalate.
                                DispatchQueue.main.async { [weak cv, weak layout] in
                                    let cv = cv
                                    let layout = layout
                                    let after = cv?.cellForItem(at: ip)?.frame.size.height ?? -1
                                    let afterLayout = layout?.cachedHeight(at: i)
                                    tlog.info("[ThinkingCollapse] POST block=\(blockId.uuidString.prefix(8)) idx=\(i) frameH=\(String(format: "%.1f", after)) layoutCache=\(afterLayout.map { String(format: "%.1f", $0) } ?? "nil") delta=\(String(format: "%.1f", after - frameH))")
                                }
                                break
                            }
                        }
                        if !matched {
                            tlog.warning("[ThinkingCollapse] MISS block=\(blockId.uuidString.prefix(8)) not in snapshot (items=\(snapshot.itemIdentifiers.count))")
                        }
                    }
            }

            if toolGroupToggleSub == nil {
                toolGroupToggleSub = NotificationCenter.default.publisher(for: .toolGroupToggled)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        guard let self, let firstBlockId = notification.object as? UUID else { return }
                        self.toggleToolGroup(firstBlockId: firstBlockId)
                    }
            }

            // [T-fold-consecutive-tools] Decide the folded runs before building
            // items, and publish them before the apply below — configureCell
            // reads them for every `.toolGroup` cell it builds.
            if toolFoldSessionId != vm.sessionId {
                toolFoldSessionId = vm.sessionId
                expandedToolGroups.removeAll()
                presentedToolGroupKeys.removeAll()
            }
            let toolFolds = planToolFolds(messages: messages)
            let previousFoldRuns = toolFoldRunByFirstBlock
            toolFoldRunsByMessage = toolFolds.runs
            toolFoldRunByFirstBlock = Dictionary(
                toolFolds.runs.values.flatMap { $0 }.map { ($0.firstBlockId, $0) },
                uniquingKeysWith: { first, _ in first })
            // [T-fold-tool-notes] A run can now GROW under the same row (a
            // remark turns into a note once the model calls another tool, and
            // the calls after it join), and its row keeps its identity — so
            // the diff alone never re-renders it with the new count / time.
            changedToolGroupItems = toolFoldRunByFirstBlock.compactMap { first, run in
                guard let old = previousFoldRuns[first], old != run else { return nil }
                return MessageListItem.toolGroup(run.messageId, first)
            }
            presentedToolGroupKeys.formUnion(toolFoldRunByFirstBlock.values.map(\.key))
            toolFoldDeferred = toolFolds.deferred
            #if DEBUG
            // [T-scroll-jitter-fold-diag] Runs folded / unfolded by THIS apply,
            // recorded with the structural diff below.
            let foldsAdded = Set(toolFoldRunByFirstBlock.keys).subtracting(previousFoldRuns.keys).count
            let foldsRemoved = Set(previousFoldRuns.keys).subtracting(toolFoldRunByFirstBlock.keys).count
            #endif

            // Rebuild O(1) lookup indices
            messageIndex.removeAll(keepingCapacity: true)
            for (i, msg) in messages.enumerated() {
                messageIndex[msg.id] = i
            }

            // Clean up bridges
            let currentIds = Set(messages.map(\.id))
            let removedIds = Set(cellBridges.keys).subtracting(currentIds)
            for id in removedIds { bridgeSheetSubs.removeValue(forKey: id) }
            cellBridges = cellBridges.filter { currentIds.contains($0.key) }
            lastFooterShapeByMessage = lastFooterShapeByMessage.filter { currentIds.contains($0.key) }

            // Build items
            var newItems: [MessageListItem] = []
            // [T-ios-orphan-user-tail GH#262/#263] The Resume banner lives in
            // the assistant FOOTER cell, and a user row never gets one — so a
            // transcript ending on a user turn that never received a reply had
            // canResume=true with nowhere to draw the button. Emit a footer
            // after that trailing user row, reusing the cell that already knows
            // how to size and render the banner rather than teaching the user
            // bubble (whose contentKey and height estimate are content-only) to
            // grow one. Scoped to the LAST message and to canResume, so an
            // ordinary user turn mid-history is untouched.
            let orphanTailUserId: UUID? = {
                guard vm.canResume, !vm.isProcessing,
                      let last = messages.last, last.role == .user else { return nil }
                return last.id
            }()
            // [T-assistant-header-dedup] The avatar + name header opens a
            // reply to the PERSON: it is emitted only for the first assistant
            // message after a real user turn. Consecutive assistant messages
            // (tool-result message → text summary) share one header, and an
            // agent callback — user role on the wire, but written by the
            // system — does not restart the sequence either. compactDivider /
            // systemInfo are not turns, so they leave the state untouched.
            // The first message of a transcript gets a header (nothing to
            // compare against).
            var lastSpeakerWasUser = true
            for message in messages {
                switch message.role {
                case .user, .compactDivider, .systemInfo:
                    newItems.append(.wholeMessage(message.id))
                    if message.id == orphanTailUserId {
                        newItems.append(.assistantFooter(message.id))
                    }
                    if message.role == .user, message.agentCallback == nil {
                        lastSpeakerWasUser = true
                    }
                case .assistant:
                    if lastSpeakerWasUser {
                        newItems.append(.assistantHeader(message.id))
                    }
                    lastSpeakerWasUser = false
                    // [T-subagent-control-row] Control calls are no longer
                    // skipped here. They used to be: rendering one as an
                    // EmptyView was not enough, because each block is its
                    // own cell and an empty one still measured full height,
                    // leaving a band of blank space. They now draw a real
                    // real tool capsule, so the cell has content matching
                    // its height and the gap cannot recur.
                    //
                    // [T-fold-consecutive-tools] A folded run becomes one
                    // `.toolGroup` row; its blocks follow that row only
                    // while it is expanded.
                    let runs = toolFolds.runs[message.id] ?? []
                    var nextRun = 0
                    var bi = 0
                    let blocks = message.blocks
                    while bi < blocks.count {
                        if nextRun < runs.count, runs[nextRun].firstBlockId == blocks[bi].id {
                            let run = runs[nextRun]
                            nextRun += 1
                            newItems.append(.toolGroup(message.id, run.firstBlockId))
                            if expandedToolGroups.contains(run.key) {
                                newItems.append(contentsOf: run.memberIds.map { .assistantBlock(message.id, $0) })
                            }
                            bi += run.memberIds.count
                            continue
                        }
                        // [T-user-ask-notsent-merge] A not-sent user_ask after the
                        // first of its run gets no row: the run shows once, on
                        // its lead, with the count. Left out rather than drawn
                        // empty, so no zero-height cell is ever measured.
                        if case .member = UserAskNotSentStore.shared.role(blocks[bi].id) {
                            bi += 1
                            continue
                        }
                        newItems.append(.assistantBlock(message.id, blocks[bi].id))
                        bi += 1
                    }
                    // Only emit a footer cell when it will actually render
                    // content. A footer with zero visible content (no typing
                    // indicator, no error, no resume, no usage) was leaving a
                    // phantom 4pt gap above the next user message. When the
                    // footer IS needed later (e.g. showUsage toggled by
                    // double-tap), the toggle triggers a snapshot refresh
                    // which re-evaluates this condition.
                    let isLastAssistant = (message.id == messages.last(where: { $0.role == .assistant })?.id)
                    let needsFooter = isLastAssistant
                        || message.error != nil
                        || (cellBridges[message.id]?.showUsage == true)
                    if needsFooter {
                        newItems.append(.assistantFooter(message.id))
                    }
                }
            }

            // [T-messagelist-snapshot-unique-ids] Diffable data sources abort
            // (NSInternalInconsistencyException, "identifiers are not unique")
            // when an item appears twice. That needs only one duplicated
            // message or block id in `messages` — e.g. a sync merge or reload
            // race leaving the same row twice — and it takes the whole app
            // down (field crash: build 25, iOS 16.0.3, inside this apply). Keep
            // the first occurrence and log, so a data glitch costs one hidden
            // duplicate row instead of a crash.
            newItems = Self.uniqueItems(newItems, caller: caller)

            // Remap height cache + set accurate estimates for ALL item types
            if let layout = viewController?.messageListLayout {
                #if DEBUG
                // [T-scroll-jitter-fold-diag] Every structural apply, so a jump in
                // the per-frame offsets can be tied to what changed the list:
                // rows removed / inserted, runs folded now, and whether the
                // user's finger was down (pos) at that moment.
                if ScrollMetricsRecorder.shared.isEnabled, let cv = viewController?.collectionView {
                    let oldSet = Set(previousSnapshotIds), newSet = Set(newItems)
                    ScrollMetricsRecorder.shared.record(kind: "snap",
                        a: Double(previousSnapshotIds.count), b: Double(newItems.count),
                        pos: scrollStateTag(cv), offset: Double(cv.contentOffset.y),
                        note: "caller=\(caller) rm=\(oldSet.subtracting(newSet).count) ins=\(newSet.subtracting(oldSet).count) foldNew=\(foldsAdded) foldGone=\(foldsRemoved) foldDeferred=\(toolFolds.deferred) csH=\(Int(cv.contentSize.height))")
                }
                #endif
                layout.updateCacheForSnapshot(oldIds: previousSnapshotIds, newIds: newItems)

                // [T-ios-first-block-footer-gap] Collapse the footer the moment
                // a turn's FIRST block appears.
                //
                // While the block set is empty the footer legitimately renders a
                // TypingIndicator and measures ~48pt. As soon as any block
                // exists, `hasVisibleContent` flips true — its `default` arm
                // covers tool and thinking blocks — so `showTyping` goes false
                // and the footer body renders nothing, padding included. Nothing
                // told the layout: the existing invalidation (127b546c9) waits
                // for the `isProcessing` true->false edge, which is still far
                // away mid-turn. The stale ~48pt frame is the blank strip
                // reported under the first tool card, confirmed in the view
                // debugger as an `AssistantFooterCellV3` on an empty frame, and
                // in the log as `stale-height held=48.0 needs=22.0`.
                //
                // Detected here, in the data layer, rather than from a SwiftUI
                // observer: a previous attempt hung this off
                // `blockContentFilledSignal`, which only fires for TEXT blocks
                // transitioning empty -> non-empty. Tool blocks are created
                // already populated and never take that path, so the footer was
                // only fixed later, when some unrelated text block streamed —
                // by which point the gap had been visible for seconds. Counting
                // blocks covers every block kind and cannot be skipped by a
                // same-update-cycle observer (the failure mode behind the
                // thinking-collapse bug).
                for message in messages where message.role == .assistant {
                    let count = message.blocks.count
                    let previous = lastBlockCountByMessage[message.id]
                    lastBlockCountByMessage[message.id] = count
                    guard previous == 0, count >= 1,
                          let footerIdx = newItems.firstIndex(of: .assistantFooter(message.id))
                    else { continue }
                    layout.invalidateHeight(at: footerIdx)
                    if let cv = viewController?.collectionView {
                        let fip = IndexPath(item: footerIdx, section: 0)
                        (cv.cellForItem(at: fip) as? SelfSizingCell)?.clearCachedHeight()
                    }
                    AppLogger(category: "BottomGapDiag").info(
                        "[BottomGapDiag][footer-collapse] msg=\(message.id.uuidString.prefix(8)) "
                        + "blocks 0→\(count) footerIdx=\(footerIdx) — invalidated (typing indicator just unmounted)")

                    // [T-ios-first-block-footer-gap] Clearing the caches is not
                    // enough on its own — the cell must also be told to
                    // re-measure, or UIKit keeps presenting the frame it already
                    // has and nothing ever asks SwiftUI for a new size.
                    //
                    // Three earlier attempts each fixed a real but insufficient
                    // piece: the seed (an estimate, only consulted when no
                    // measured height exists), the block-count edge (this hook,
                    // which cleared caches), and `FooterHeightShape` (which never
                    // ran at all — `updateBridge` is driven by
                    // `CombineLatest4(isProcessing, autoRetryAttempt,
                    // autoRetryCountdown, canResume)`, and a block arriving moves
                    // none of those four, so the comparison was dead code for
                    // this transition; that is why `[footer-shape]` logged zero
                    // times in the last capture).
                    //
                    // Deferred to the next runloop turn: this runs inside
                    // `applySnapshot`, and calling `reconfigureItems` +
                    // `dataSource.apply` re-entrantly during an apply is exactly
                    // the hazard the surrounding code documents. By then the
                    // footer cell is realised, so `invalidateFooterHeightCaches`
                    // can also clear the cell-side `lastComputedHeight` — which
                    // it could not do a moment ago, since `cellForItem` returns
                    // nil for a cell that has not been dequeued yet.
                    // Also refresh the bridge so `FooterHeightShape` sees this
                    // transition. Without it the shape comparison added for this
                    // bug can never fire on a block arrival, since nothing else
                    // calls `updateBridge` at that moment.
                    if let bridge = cellBridges[message.id] {
                        updateBridge(bridge, message: message, in: messages)
                    }

                    let mid = message.id
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let ds = self.dataSource else { return }
                        self.invalidateFooterHeightCaches(messageId: mid)
                        var snap = ds.snapshot()
                        let footerItem = MessageListItem.assistantFooter(mid)
                        guard snap.itemIdentifiers.contains(footerItem) else { return }
                        snap.reconfigureItems([footerItem])
                        ds.apply(snap, animatingDifferences: false)
                        AppLogger(category: "BottomGapDiag").info(
                            "[BottomGapDiag][footer-reconfig] msg=\(mid.uuidString.prefix(8)) "
                            + "— caches cleared + cell reconfigured, footer must re-measure now")
                    }
                }
                // Drop entries for messages no longer present so the map cannot
                // grow without bound across a long session.
                let liveIds = Set(messages.map(\.id))
                lastBlockCountByMessage = lastBlockCountByMessage.filter { liveIds.contains($0.key) }

                // [T-ios-earlier-stream-seed-freeze] New snapshot => block set
                // / tool statuses may have changed, so the live-message memo
                // must not be reused across it. This runs once per flush, not
                // per cell.
                streamGeneration &+= 1

                let cvWidth = viewController?.collectionView.bounds.width ?? 390
                // [T-ios-listsessions-perf] Reset the height-cache tally for
                // this pass; the summary is logged once the loop finishes.
                heightCacheHits = 0
                heightCacheMisses = 0
                heightMeasureSeconds = 0
                // [T-stream-precalc-freeze] Messages that can still grow (the
                // live turn, earlier turns with a running tool) - same rule as
                // configureCell's seed exclusion. No precalc for their rows: any
                // height known now is outgrown by the next chunk, and precalc is
                // only rewritten when a snapshot applies.
                let growingIds = Self.liveAssistantMessageIds(messages: messages, isProcessing: vm.isProcessing)
                for (i, item) in newItems.enumerated() {
                    // [T-ios-scroll-decel-height-drift] Register the stable
                    // content key for this index so a later self-size writes the
                    // real height back under the key, and seed precalc from any
                    // previously-measured real height. This kills the estimate→
                    // real "settle jitter" for .wholeMessage (user) cells, whose
                    // estimate is a coarse char-count heuristic (±13–52pt off),
                    // on every re-entry after the first measurement. NO new
                    // measurement happens here — we reuse the height UIKit
                    // already computed (see MessageListLayout.invalidationContext).
                    let contentKey = itemContentKey(for: item, messages: messages)
                    layout.setContentKey(contentKey, at: i)
                    // [T-scroll-estimate-fidelity] Link the row to its content
                    // hash, so its measurement also feeds the cross-load memo.
                    let stableKey = stableHeightKey(for: item, messages: messages)
                    if let stableKey { layout.setStableHeightKey(stableKey, forContentKey: contentKey) }

                    // [T-ios-footer-hug] Content-aware spacing policy — must run
                    // BEFORE the cachedHeight guard below, or footers that
                    // already measured would skip it and fall back to the
                    // default hug, re-gluing a prominent banner on the next
                    // prepare(). Hug ONLY when the footer shows the quiet
                    // meta/usage row (or nothing); error banner / resume banner
                    // / typing indicator keep the full itemSpacing (user report
                    // 2026-07-21). Mirrors BridgedAssistantFooterV3's sections.
                    // [T-interrupt-banner-gap] The policy itself lives in
                    // `isFooterProminent` (+FooterHeight), shared with
                    // `updateBridge`, which re-applies it when the footer's
                    // shape flips without a snapshot apply (Stop → resume banner).
                    var footerProminent = false
                    if case .assistantFooter(let footerMsgId) = item {
                        let footerMsg = messageIndex[footerMsgId].flatMap {
                            $0 < messages.count ? messages[$0] : nil
                        }
                        footerProminent = isFooterProminent(footerMsgId, footerMessage: footerMsg,
                                                            messages: messages, vm: vm)
                        layout.setFooterHug(!footerProminent, at: i)
                    }

                    guard layout.cachedHeight(at: i) == nil else { continue }

                    // [T-stream-precalc-freeze] A row of a still-growing message
                    // keeps only an estimate (set below) and is measured live;
                    // drop any precalc an earlier snapshot left on this index.
                    let isGrowing = Self.messageId(of: item).map { growingIds.contains($0) } ?? false
                    if isGrowing { layout.clearPrecalcHeight(at: i) }

                    // Re-entry seed: if we have a real measured height for this
                    // exact content key at this width, use it as precalc — the
                    // cell lands at its true height with zero on-screen jump.
                    if !isGrowing, let memo = layout.measuredHeight(forKey: contentKey, width: cvWidth) {
                        layout.setPrecalcHeight(memo, at: i)
                        continue
                    }
                    // [T-scroll-estimate-fidelity] Same content measured in an
                    // earlier load (row ids are new each load, so the memo above
                    // misses): its real height as the estimate. Precalc only - the
                    // cell still self-sizes, so a stale entry is just a correction.
                    // Not for a growing row: its content key is content-derived, so
                    // a new EMPTY text block matched every earlier empty block's
                    // ~32 pt - the height the live block then froze at.
                    if !isGrowing, let stableKey, let remembered = CrossLoadHeightMemo.shared.height(for: stableKey, width: cvWidth) {
                        layout.setPrecalcHeight(remembered, at: i)
                        continue
                    }

                    switch item {
                    case .assistantHeader:
                        // Header is always a fixed "icon + name" label row.
                        // Was 28 when the icon was 18pt and the .body text
                        // (20.3pt line) set the height; at 22pt the icon is
                        // now the taller element, adding 1.67pt. Seeding 30
                        // keeps the estimate on the same side of the real
                        // height as before rather than under-seeding every
                        // assistant turn.
                        // [T-scroll-estimate-fidelity] Measured on device it is
                        // 26 pt (icon 22 + top padding 4), so the fixed 30
                        // shrank every header by 4 pt as it scrolled into view.
                        // Now: the learned real height, else the layout formula.
                        layout.setEstimatedHeight(layout.headerEstimate(width: cvWidth), at: i)

                    case .assistantFooter:
                        // Prominent banners (error/resume/typing) measure
                        // ~44-56pt; the quiet meta footer is ~0-4pt. Seeding
                        // closer to the real height keeps the first-display
                        // correction (and its scroll shift) small.
                        // (footerProminent computed above, pre-guard.)
                        layout.setEstimatedHeight(footerProminent ? 48 : 4, at: i)
                        #if DEBUG
                        // [BottomGapDiag] The footer is the item DIRECTLY BELOW
                        // the last block of the live assistant turn — i.e.
                        // exactly where the user reports the gap, under "the
                        // first tool card after sending".
                        //
                        // It is also the only item whose height is driven by
                        // transient state rather than content: 48pt while
                        // `isProcessing` (typing indicator / resume / error
                        // banner), ~4pt once quiet. If it is seeded at 48 and
                        // the real content turns out shorter — or the estimate
                        // is never corrected because the cell is off-screen when
                        // the state flips — the surplus reads as dead space
                        // under that first card, and stays until something else
                        // forces a re-measure. That matches "only the first one
                        // is wrong, later ones are fine": later blocks push the
                        // footer down and out of the suspect position.
                        //
                        // Log the seed, the state that chose it, and whatever
                        // real height the layout already holds, so the estimate
                        // can be compared against the truth.
                        AppLogger(category: "BottomGapDiag").info(
                            "[BottomGapDiag][footer] idx=\(i) seeded=\(footerProminent ? 48 : 4) "
                            + "prominent=\(footerProminent) isProcessing=\(vm.isProcessing) "
                            + "cached=\(layout.cachedHeight(at: i).map { String(format: "%.1f", $0) } ?? "-") "
                            + "precalc=\(layout.precalcHeight(at: i).map { String(format: "%.1f", $0) } ?? "-")")
                        #endif

                    case .assistantBlock(let msgId, let blockId):
                        guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { continue }
                        let msg = messages[msgIdx]
                        guard let block = msg.blocks.first(where: { $0.id == blockId }) else { continue }

                        switch block.kind {
                        case .text:
                            // Use TextKit layout for accurate height pre-calculation.
                            // [T-ios-listsessions-perf] Cached by CONTENT (see
                            // HeightCacheKey) rather than by the attributed
                            // string's identity, so a re-render of unchanged
                            // text — stream finalize, compaction re-parse,
                            // session reload — hits instead of re-measuring
                            // through the near-O(n^2) sizeThatFits path.
                            if !isGrowing, let attrStr = block.cachedAttributedString {
                                let textWidth = max(cvWidth - 32, 100)
                                let key = HeightCacheKey(
                                    content: block.content,
                                    width: textWidth,
                                    // 16.5 = the base size MarkdownNSRenderer is
                                    // built with for assistant markdown
                                    // (SelectableMarkdownView:387). Must track
                                    // the RENDERER's size, not the list's own
                                    // `scale` (16), or a Dynamic Type change
                                    // would collide instead of missing.
                                    fontSize: FontSettings.shared.scaledMessage(16.5)
                                )
                                // Never cache a string that carries attachments. An
                                // image's height is decided at LAYOUT time by
                                // attachmentBounds from NativeMediaImageCache —
                                // 200 pt placeholder until the bitmap's size is
                                // known — so the SAME content measures differently
                                // before and after decode. Cached, that placeholder
                                // height would be re-seeded by every later precalc
                                // (handleAttachmentSizeChanged invalidates the
                                // layout height, and the next pass re-reads this
                                // cache), and now that the cache outlives session
                                // change it would follow the message into its next
                                // open. Images are rare in text blocks; measuring
                                // them every pass is the pre-5c behaviour.
                                let cacheable = !attrStr.containsAttachments(
                                    in: NSRange(location: 0, length: attrStr.length))
                                let height: CGFloat
                                if cacheable, let cached = attrStringHeightCache[key] {
                                    height = cached
                                    heightCacheHits += 1
                                } else {
                                    let t0 = CFAbsoluteTimeGetCurrent()
                                    height = Self.measureAttributedStringHeight(attrStr, width: textWidth)
                                    heightMeasureSeconds += CFAbsoluteTimeGetCurrent() - t0
                                    if cacheable { attrStringHeightCache[key] = height }
                                    heightCacheMisses += 1
                                }
                                // height includes the text view's 8pt insets;
                                // +4 = the SwiftUI wrapper's .padding(.vertical, 2)
                                // that the historical "+8" never accounted for
                                // (the constant +5 first-measure growth in the
                                // debug.scrollMetrics traces = this 4pt + ceil).
                                layout.setPrecalcHeight(height + 4, at: i)
                                #if DEBUG
                                // [T-ios-scroll-metrics-ring] Record content
                                // features at the seed site (the only place the
                                // block object and its precalc height coexist) so
                                // the pulled trace can attribute ct-precalc
                                // mismatches to specific markdown constructs.
                                if ScrollMetricsRecorder.shared.isEnabled {
                                    let c = block.content
                                    let feats = "code=\(c.contains("```") ? 1 : 0)|tbl=\(c.contains("|") ? 1 : 0)|list=\(c.range(of: #"(?m)^\s*[-*+] "#, options: .regularExpression) != nil ? 1 : 0)|head=\(c.range(of: #"(?m)^#{1,6} "#, options: .regularExpression) != nil ? 1 : 0)|icode=\(c.contains("`") ? 1 : 0)|bold=\(c.contains("**") ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)"
                                    ScrollMetricsRecorder.shared.record(
                                        kind: "seed", idx: i, a: height + 4,
                                        key: contentKey, src: "tv", note: feats,
                                        tag: Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex))
                                }
                                #endif
                            } else if block.content.isEmpty {
                                // [T-ios-empty-textblock-gap] A content-less text
                                // block renders EmptyView (AssistantBlockView gates
                                // on !content.isEmpty), so it must occupy 0pt — the
                                // heuristic's one-line floor made it a phantom
                                // blank row above the next tool capsule while
                                // streaming defers the corrective measure. When
                                // content arrives, blockContentFilledSignal
                                // invalidates the height and reconfigures the cell.
                                layout.setEstimatedHeight(0, at: i)
                            } else {
                                // Streaming text — no cachedAttributedString yet,
                                // so use the char-count heuristic.
                                //
                                // [T-ios-stream-bubble-spacing] The measured path
                                // above adds +8 (the bubble's .padding(.vertical, 2)
                                // plus the TextKit↔SwiftUI line-height delta). The
                                // heuristic's estimateTextBlockHeight only seeds
                                // `total = 4`, so a streaming text cell came out
                                // ~4pt short on its vertical padding — the bubble
                                // looked cramped/edge-to-edge until a later layout
                                // pass ran the real systemLayoutSizeFitting measure
                                // (which includes the padding) and "snapped" the
                                // spacing back. Add the same +4 here so the first
                                // streamed frame already reserves that padding.
                                // The +4 padding compensation now lives inside
                                // estimateTextBlockHeight, so all estimate paths
                                // agree — no per-call-site fudge here.
                                let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth)
                                layout.setEstimatedHeight(est, at: i)
                            }
                        case .thinking:
                            // Estimator returns 36pt collapsed (matches header-only rendering),
                            // or header + capped content height when expanded. Hard-coded 88
                            // caused a -48pt correction per cell on first render, producing a
                            // contentSize-shrink jitter chain when scrolling through history.
                            let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth)
                            layout.setEstimatedHeight(est, at: i)
                        case .readImageTool:
                            // In V3 block cells, readImageTool renders as a
                            // ToolCapsuleView (36pt), same as other tool types.
                            layout.setEstimatedHeight(36, at: i)
                        case .info:
                            let infoLines = max(1, block.content.components(separatedBy: "\n").count)
                            layout.setEstimatedHeight(CGFloat(20 + infoLines * 16), at: i)
                        case .userAskTool, .delegateTool:
                            // [T-user-ask-estimate] Cards, not 36pt capsules: the
                            // estimator knows their real shapes (answered user_ask
                            // 64, pending ~260, sub agent card 58). Falling to the
                            // 36pt default made every one correct by +22..+28pt
                            // the first time it scrolled into view. Estimate only:
                            // no measuring, and a memoized height wins above.
                            layout.setEstimatedHeight(
                                Self.estimateItemHeight(item, messages: messages, width: cvWidth), at: i)
                        default:
                            // Tool capsules (execute, browser, etc.) are 36pt
                            layout.setEstimatedHeight(36, at: i)
                        }

                    case .toolGroup:
                        // [T-fold-consecutive-tools] Fixed-height row, so the
                        // estimate is the real height.
                        layout.setEstimatedHeight(ToolGroupRowView.rowHeight, at: i)

                    case .wholeMessage(let msgId):
                        // [T-ios-user-msg-estimate-tail-jitter] Accurate TextKit
                        // precalc for USER message bubbles. The "stops then
                        // twitches" decel-tail jank traced to user (wholeMessage)
                        // cells whose coarse
                        // char-count estimate was ~10pt short (idx150: est 77 →
                        // real 87): when such a cell scrolled into view during the
                        // decel tail it re-measured taller, grew contentSize, and
                        // misaligned UIKit's already-computed decel target → 30fps
                        // micro-correction near the stop + a POST-SETTLE offset
                        // jump. The user bubble is a plain SwiftUI Text (no
                        // cachedAttributedString), so it never got the accurate
                        // precalc the .text blocks do. Measure it with the SAME
                        // font + wrap width + paddings as the real render so the
                        // cell lands at its true height and contentSize stays
                        // stable through the glide. Falls back to the coarse
                        // estimator for compactDivider / systemInfo / empty.
                        if let msg = messages.first(where: { $0.id == msgId }),
                           msg.role == .user {
                            // Real wrap is bounded by maxContentWidth (the
                            // .frame(maxWidth:) on BridgedWholeMessageV3); using
                            // the wider cvWidth would under-wrap → under-estimate
                            // on iPad. Use the effective width.
                            let effWidth = maxContentWidth > 0 ? min(cvWidth, maxContentWidth) : cvWidth
                            let h = Self.measureUserBubbleHeight(for: msg, cvWidth: effWidth,
                                                                 cache: &userBubbleHeightCache)
                            if let h {
                                layout.setPrecalcHeight(h, at: i)
                                #if DEBUG
                                // [T-ios-scroll-metrics-ring] Feature capture for
                                // the +7 user-bubble subset attribution.
                                if ScrollMetricsRecorder.shared.isEnabled {
                                    let c = msg.content
                                    let cjk = c.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
                                    let feats = "cjk=\(cjk ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)|att=\(msg.attachments.count)|inAtt=\(msg.inputAttachments.count)|tag=\(c.contains("<user-attached-files>") ? 1 : 0)"
                                    ScrollMetricsRecorder.shared.record(
                                        kind: "seed", idx: i, a: h,
                                        key: Self.contentKey(for: item, messages: messages, messageIndex: messageIndex),
                                        src: "bubble", note: feats,
                                        tag: Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex))
                                }
                                #endif
                            } else {
                                // empty text (attachment-only) — coarse estimate
                                layout.setEstimatedHeight(
                                    Self.estimateItemHeight(item, messages: messages, width: cvWidth), at: i)
                            }
                        } else {
                            // compactDivider / systemInfo — coarse estimate is fine
                            let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth)
                            layout.setEstimatedHeight(est, at: i)
                        }
                    }
                }

                #if DEBUG
                // [T-ios-listsessions-perf] One line per snapshot pass. This is
                // the evidence the on-device run reads to confirm (or refute)
                // that the identity-keyed cache was missing on re-render — the
                // assumption behind switching to a content key. A healthy
                // steady state is hits >> misses with measured_ms near zero;
                // misses staying high would mean the key is still too specific.
                let measured = heightCacheHits + heightCacheMisses
                if measured > 0 {
                    let ms = heightMeasureSeconds * 1000
                    let rate = Int((Double(heightCacheHits) / Double(measured)) * 100)
                    heightCacheLogger.debug(
                        "caller=\(caller) items=\(measured) hits=\(heightCacheHits) "
                        + "misses=\(heightCacheMisses) hitRate=\(rate)% "
                        + "measured=\(String(format: "%.1f", ms))ms "
                        + "cacheSize=\(attrStringHeightCache.count)")
                }
                #endif
            }

            // Rebuild item→index lookup
            itemToIndex.removeAll(keepingCapacity: true)
            for (i, item) in newItems.enumerated() {
                itemToIndex[item] = i
            }

            // Track streaming cell ranges so layout doesn't adjust offset for
            // them. [T-stream-hover-earlier-streaming] Not just the LAST
            // assistant message: with queued-turn interrupts an EARLIER
            // assistant message can still be receiving content (running /
            // streaming tool blocks) while the newest turn streams text. Every
            // such message's item span must be excluded from the visible-cell
            // offset adjustment, or browse-mode hovering over it gets dragged
            // down by each flush's growth delta.
            if vm.isProcessing {
                // [T-ios-earlier-stream-seed-freeze] Shared with the seed/memo
                // exclusion in configureCell — these two had drifted (that one
                // still tested only `messages.last`), which is what let a
                // growing earlier message be frozen at a stale height. One
                // rule, one implementation.
                let streamingIds = Array(Self.liveAssistantMessageIds(messages: messages,
                                                                     isProcessing: true))
                var ranges: [Range<Int>] = []
                for id in streamingIds {
                    // [T-assistant-header-dedup] A message without its own
                    // header starts at its first block.
                    guard let start = newItems.firstIndex(where: {
                        $0 == .assistantHeader(id) || Self.item($0, belongsTo: id)
                    }) else { continue }
                    var end = start + 1
                    while end < newItems.count, Self.item(newItems[end], belongsTo: id) {
                        end += 1
                    }
                    ranges.append(start..<end)
                }

                // [T-ios-compacting-row-vanishes-on-scroll] The live
                // "Compacting conversation… (N chars)" row counts as streaming
                // too, even though it is a `systemInfo` row rather than an
                // assistant turn.
                //
                // Its text is rewritten on every SSE delta, exactly like
                // streamed assistant text. But `SelfSizingCell`'s interaction
                // guard short-circuits any NON-streaming cell that has a cached
                // height while `deferSelfSizing || streamingActive` — it returns
                // the cached height and skips `super` entirely, so the cell's
                // `UIHostingConfiguration` is never re-rendered. Compaction sets
                // `isProcessing = true`, so `streamingActive` is already true;
                // once the user drags, `deferSelfSizing` is set as well. The row
                // therefore froze at whatever it last displayed and the spinner
                // stopped updating — reported as the indicator "disappearing"
                // mid-compaction while the work carried on in the background.
                //
                // Registering it here is the same fix the earlier-streaming
                // regression used ([T-ios-earlier-stream-seed-freeze]): one
                // rule, expressed in the one place that decides which cells may
                // skip measuring. Scoped to rows still marked
                // `isCompactLoading`, so a finished/failed/cancelled status row
                // settles back to the cheap path immediately.
                for msg in messages where msg.role == .systemInfo && msg.isCompactLoading {
                    if let idx = newItems.firstIndex(of: .wholeMessage(msg.id)) {
                        ranges.append(idx..<(idx + 1))
                    }
                }
                ranges.sort { $0.lowerBound < $1.lowerBound }
                viewController?.messageListLayout?.streamingCellRanges = ranges
            } else {
                viewController?.messageListLayout?.streamingCellRanges = []
            }
            // Keep the layout's pin flag in sync here too — the scrollMode
            // didSet may have fired before the layout existed (initial value).
            // [T-ios-stream-natural-transitions]
            viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            let oldCount = previousSnapshotIds.count
            // Lock the messages array the snapshot (and messageIndex, rebuilt
            // above) was built from. configureCell / prefetch MUST read this
            // same array: reading vm.messages there instead can race a
            // concurrent loadSession() that replaced the array with freshly
            // created ChatMessage/AssistantBlock objects (new UUIDs) — the
            // snapshot's block IDs then match nothing and the cell configures
            // EMPTY (silent `guard ... else return`). Updated BEFORE the
            // skip-return below so it stays in lockstep with messageIndex.
            // [T-ios-blocks-lost-render]
            snapshotMessages = messages
            // Skip diffable-data-source apply when items haven't changed —
            // avoids expensive UIKit cell creation/layout on redundant snapshots.
            if newItems == previousSnapshotIds {
                // [T-fold-tool-notes] Same items, but a run's count or time may
                // have changed under its row. Group rows have a fixed height,
                // so a plain reconfigure is enough — no height invalidation.
                if !changedToolGroupItems.isEmpty, let ds = dataSource {
                    var snap = ds.snapshot()
                    snap.reconfigureItems(changedToolGroupItems.filter { snap.indexOfItem($0) != nil })
                    changedToolGroupItems = []
                    ds.apply(snap, animatingDifferences: false)
                }
                AppLogger(category: "SnapshotDiag").info("[SnapshotDiag] SKIP caller=\(caller) items unchanged (count=\(newItems.count)) — no re-apply")
                // [T-ios-bg-resume-collapse] …but a SKIP is exactly wrong for a
                // flush that was DEFERRED across a suspend window. While
                // suspended, block content grows IN PLACE: the text of an
                // existing block gets longer, a tool capsule's placeholder is
                // replaced by its output. None of that changes the item
                // identifiers, so `newItems == previousSnapshotIds` holds and
                // this early return fires — no diff, no `reconfigureItems`, no
                // `applyContentConfiguration`, and therefore nothing that would
                // drop the visible cells' `lastComputedHeight`. Those cells go
                // on answering PLAF with the height they measured BEFORE the
                // app was backgrounded, while their SwiftUI content is now
                // taller: `prepare()` stacks the following cells from the stale
                // frame (the reported overlap) and `clipsToBounds` crops the
                // cell's own text.
                //
                // [T-ios-double-loadsession-stale-cells] `bind3-sessionLoad` is
                // the SAME hazard, arriving by a different route, and the field
                // log (sid=A57908B6, 2026-08-10) shows it is the one that
                // actually fired. loadSession() ran TWICE 90s apart on one
                // session: a cold start at 16:02:49 that built cells from
                // INCOMPLETE data (lastTextLen=23, the agent loop was still
                // running server-side), then a reload at 16:04:35 after the
                // iCloud sync-hold released, with the complete data
                // (lastTextLen=226). Both times the trace is identical:
                //
                //   16:02:49.722  caller=flushPending(updateUIVC-backstop) totalItems=77
                //   16:02:49.818  SKIP caller=bind3-sessionLoad (count=77)
                //   16:04:35.504  caller=flushPending(updateUIVC-backstop) totalItems=83
                //   16:04:35.536  SKIP caller=bind3-sessionLoad (count=83)
                //
                // The b897a71a backstop wins the race to apply the item list by
                // 30-100ms, so by the time bind3 — the AUTHORITATIVE post-load
                // apply — runs, `previousSnapshotIds` already matches and it
                // SKIPs. That is destructive here in a way it is not for other
                // callers: bind3 has just called `clearHeightCache()` on the
                // line above, wiping heightCache / precalcHeights /
                // measuredHeightByContentKey. The seed loop upstream re-seeds
                // the layout side, but the SKIP returns before any
                // `reconfigureItems`, so `applyContentConfiguration` never runs
                // and the CELLS keep the `lastComputedHeight` they measured
                // against the PREVIOUS generation's content. PLAF checks that
                // cell-side cache FIRST, so those cells keep answering with the
                // 23-char height while the data source holds the 226-char
                // content — cross-generation reuse, and the collapse the user
                // photographed at 16:08:37.
                //
                // Gated to the callers that can leave stale cells behind — the
                // deferred flushes and the post-load apply — so the
                // redundant-snapshot fast path this SKIP exists for (many per
                // second mid-stream, caller=bind1-messages / bind4b) keeps
                // returning immediately and pays nothing.
                if caller.hasPrefix("flushPending") || caller.hasPrefix("suspend-resume")
                    || caller == "bind3-sessionLoad" {
                    remeasureVisibleCells(reason: "skip-after-defer(\(caller))")
                }
                return
            }
            let oldSet = Set(previousSnapshotIds)
            let inserted = newItems.filter { !oldSet.contains($0) }
            previousSnapshotIds = newItems

            // Per-block dump of the last assistant message. `debug` rather than
            // `info` for two reasons: it fired on every apply (1,503 times on
            // 2026-08-11, most of them several lines each), and `tail` puts RAW
            // message content — shell commands, tool output, anything the user
            // or a tool produced — into a log file that gets exported.
            //
            // `AppLogger.debug` is `#if DEBUG` internally AND takes an
            // @autoclosure, so in Release neither the log nor the string
            // interpolation that builds it exists.
            let snapLog = AppLogger(category: "SnapshotDiag")
            let blockItems = newItems.filter { if case .assistantBlock = $0 { return true }; return false }
            if let lastAssistant = messages.last(where: { $0.role == .assistant }) {
                snapLog.debug("[SnapshotDiag] caller=\(caller) totalItems=\(newItems.count) blockItems=\(blockItems.count) lastAssistantBlocks=\(lastAssistant.blocks.count) msgCount=\(messages.count)")
                for (i, block) in lastAssistant.blocks.enumerated() {
                    let contentLen = block.content.count
                    let tail = String(block.content.suffix(20))
                    snapLog.debug("[SnapshotDiag]   block[\(i)] kind=\(block.kind) id=\(block.id.uuidString.prefix(8)) contentLen=\(contentLen) tail=\"\(tail)\"")
                }
            }

            var snapshot = NSDiffableDataSourceSnapshot<Section, MessageListItem>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newItems, toSection: .main)
            // [T-fold-tool-notes] Rows kept across this apply whose run changed.
            let regroupedRows = changedToolGroupItems.filter { oldSet.contains($0) && snapshot.indexOfItem($0) != nil }
            if !regroupedRows.isEmpty { snapshot.reconfigureItems(regroupedRows) }
            changedToolGroupItems = []
            // Suppress contentOffsetAdjustment during snapshot application so that
            // rapid cell self-sizing doesn't cause visible content jumps. After layout
            // settles, pin to bottom if autoScrolling.
            let snapshotLayout = viewController?.messageListLayout
            snapshotLayout?.suppressContentOffsetAdjustment = true
            isFlushing = true
            cellConfigCount = 0
            // [T-ios-preapply-endediting] End editing BEFORE the structural
            // apply, outside the batch-update transaction. Both TestFlight
            // crash families need a live first responder inside the list at
            // apply time: the AttributeGraph re-entry (synchronous
            // super.resignFirstResponder mid-transaction, C4wXLBpem 1.13(4))
            // and the _resignOrRebaseFirstResponderViewWithIndexPathMapping:
            // assertion (deferred resign returning false, 1.13(15)). Resigning
            // here removes the shared precondition for both. Cost: an active
            // text selection is dismissed when a structural update lands (new
            // block/message); reconfigure-only applies don't come through here
            // and leave selection alone.
            //
            // Deliberately NOT excluded for callers that run inside a SwiftUI
            // render pass (flushPending(updateUIVC-backstop), rebind). On
            // those paths the whole `dataSource.apply` below ALREADY runs in
            // the render pass — pre-8/17 code did the responder-chain walk
            // INSIDE the resulting batch update there, which is the precise
            // context of the C4wXLBpem stack. Moving the walk here keeps it in
            // the same pass but outside the batch-update/hosted-cell update
            // window, which is strictly earlier and strictly safer than what
            // shipped before; excluding a caller instead would keep a live
            // responder into the batch update — the exact window both crash
            // families live in. Verified live on updateUIVC-backstop with an
            // active selection (2026-08-22, iPhone 11/iOS 27).
            if let cv = viewController?.collectionView as? NoAnimationCollectionView,
               let responder = cv.trackedTextResponder, responder.isFirstResponder {
                AppLogger(category: "Responder").info("[Responder] pre-apply endEditing (caller=\(caller))")
                cv.endEditing(true)
            }
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            // [ToolLifecycle] Stage 5: log newly-inserted tool blocks now in the
            // applied snapshot. Only fires for inserts, so volume stays proportional
            // to actual new tool blocks appearing in the chat UI.
            if !inserted.isEmpty {
                let sid = vm.sessionId?.prefix(8) ?? "nil"
                let appState = UIApplication.shared.applicationState == .active ? "fg" : "bg"
                let suspended = vm.streamingUIUpdatesSuspended
                let processing = vm.isProcessing
                for item in inserted {
                    if case .assistantBlock(let msgId, let blockId) = item,
                       let msgIdx = messageIndex[msgId],
                       msgIdx < messages.count,
                       let block = messages[msgIdx].blocks.first(where: { $0.id == blockId }),
                       block.toolUseId != nil {
                        let toolName: String = switch block.kind {
                        case .shellTool: "shell_execute"
                        case .fileReadTool: "file_read"
                        case .fileWriteTool: "file_write"
                        case .fileEditTool: "file_edit"
                        case .browserTool: "browser_use"
                        case .readImageTool: "read_image"
                        case .memoryTool: "memory"
                        case .delegateTool: SubAgentDefinition.toolName
                        case .userAskTool: UserAskTool.name
                        default: "unknown"
                        }
                        AppLogger(category: "ToolLC").verbose("[ToolLifecycle] RENDERED_CHATUI toolId=\(block.toolUseId?.prefix(20) ?? "nil") tool=\(toolName) sid=\(sid) appState=\(appState) suspended=\(suspended) isProcessing=\(processing) caller=\(caller)")
                    }
                }
            }
            // Re-mark layout dirty: isApplyingSnapshot suppressed the layoutSubviews()
            // that dataSource.apply() triggered internally, so UIKit thinks layout is
            // already done. Without this, layoutIfNeeded() below is a no-op and cells
            // won't be created until the next touch/scroll.
            viewController?.collectionView.setNeedsLayout()

            if let cv = viewController?.collectionView {
                // Clear stale height cache for newly inserted items. During
                // dataSource.apply(), UIKit may trigger preferredLayoutAttributesFitting
                // on OLD cells still occupying the indices where new items will go,
                // writing the old cell's height into heightCache at the new item's index.
                // This causes the new cell to inherit the old cell's height (e.g. a 28pt
                // footer height applied to a new text block), leading to overlap.
                if !inserted.isEmpty, let layout = snapshotLayout {
                    for item in inserted {
                        if let idx = newItems.firstIndex(of: item) {
                            layout.invalidateHeight(at: idx)
                        }
                    }
                }

                // [T-ios-plaf-cache-footer-typing-staleness] Fourth footer gap.
                //
                // The typing indicator's visibility is
                //   `bridge.isActiveMessage && (!hasVisibleContent || message.isAwaitingModelResponse)`
                // and BOTH of those inner terms are derived from `message`, not
                // from the bridge — `hasVisibleContent` walks `message.blocks`.
                // `FooterHeightShape` only samples bridge fields, and
                // `updateBridge` is not called when the trigger is a new block
                // arriving, so the shape comparison never runs for this
                // transition.
                //
                // Meanwhile the footer's item identity is `.assistantFooter(msgId)`,
                // which does not change when a block is appended, so the diff is
                // empty for it and UIKit never re-configures the cell (same
                // mechanism as gap 1 in cd50865c). The footer therefore keeps the
                // TALLER height it measured while "Minis is thinking…" was
                // showing, and once the first tool block lands the indicator
                // disappears but the reserved space does not — the blank strip
                // above the tool row that the user reported. It healed only on
                // re-entering the session, i.e. on a cold re-measure.
                //
                // Targeted on purpose: only the footer of the message that just
                // gained a block is invalidated (O(1) per insert, visible cells
                // only, via the same clearCachedHeight + invalidateHeight pair
                // used by the other three gaps). No new full traversal — that
                // would add main-thread hosting-graph re-entries and cut against
                // the FB13213926 series (b4268586 / 81e43b58 / e9d167c2).
                var footerDirtyMessageIds = Set<UUID>()
                for item in inserted {
                    if case .assistantBlock(let msgId, _) = item {
                        footerDirtyMessageIds.insert(msgId)
                    }
                }
                for msgId in footerDirtyMessageIds {
                    invalidateFooterHeightCaches(messageId: msgId)
                }

                cv.layoutIfNeeded()
                snapshotLayout?.suppressContentOffsetAdjustment = false
                isFlushing = false
                // [T-send-composer-shrink-absorb] The sent bubble and the
                // typing row land here: let them take the space the composer
                // is giving up before the pin below scrolls for them.
                if scrollMode == .autoScrolling && newItems.count >= oldCount {
                    absorbPendingComposerShrink(caller: "snapshot")
                }
                let rawMaxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
                let maxOff = max(0, rawMaxOff)
                if newItems.count < oldCount && cv.contentOffset.y > maxOff {
                    cv.setContentOffset(CGPoint(x: 0, y: maxOff), animated: false)
                    // After shrink, content may fall into the sub-viewport
                    // overflow region — re-evaluate compensation so any
                    // previously-inflated top inset relaxes back to base.
                    // Shrink (delete/clear) — contentSize dropped, any inset
                    // accumulated from streaming-time GROW is no longer needed
                    // and would leave a permanent blank gap at the bottom.
                    // forceRelax bypasses the monotonic guard.
                    applySubViewportCompensation(caller: "snapshot-shrink", forceRelax: true)
                } else if scrollMode == .autoScrolling && maxOff > 0 {
                    cv.contentOffset.y = maxOff
                    // Deferred pin-to-bottom: UIHostingConfiguration self-sizing may
                    // complete asynchronously after layoutIfNeeded(), updating contentSize
                    // via KVO. But if another applySnapshot starts before that KVO fires,
                    // isFlushing suppresses it. The coalesced scroll (80ms) catches the
                    // final contentSize and corrects any undershoot.
                    scheduleCoalescedScroll()
                } else {
                    // Sub-viewport (rawMaxOff <= 0) or non-autoScrolling: keep
                    // the top-inset compensation tracking contentSize so the
                    // last cell stays pinned to the overlay top.
                    applySubViewportCompensation(caller: "snapshot-subVP")
                }
                // Sync isNearBottom after snapshot apply. applySnapshot runs
                // under isFlushing=true, which suppresses the contentSize KVO
                // observer — so the KVO-side sync we added doesn't run here.
                // Without this, contentSize can grow past the visible area
                // (sub-viewport overflow) without anyone updating vm.isNearBottom,
                // leaving the scroll-to-bottom button hidden when it should appear.
                if let vm = self.vm {
                    let nb = isNearBottom()
                    if vm.isNearBottom != nb {
                        vm.isNearBottom = nb
                    }
                }
                syncScrollFlags()
            } else {
                snapshotLayout?.suppressContentOffsetAdjustment = false
                isFlushing = false
            }
        }
}
