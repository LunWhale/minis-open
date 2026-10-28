//
//  MessageListV3Coordinator+Bindings.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  View-model subscriptions: rebindViewModelIfNeeded and bindViewModel, the
//  Combine pipelines that turn AIChatViewModel changes into snapshot applies,
//  reconfigures, re-measures and scroll actions.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +Bindings" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Bindings

        /// [T-ios-scrollbtn-vm-split] Re-point the coordinator at a NEW view
        /// model instance when SwiftUI hands the (reused) representable a
        /// different AIChatViewModel for the same mounted chat view. All
        /// Combine subscriptions live in bindViewModel and are keyed to the
        /// old instance — cancel them wholesale and re-subscribe, then push
        /// the current snapshot + scroll flags into the new VM so its
        /// isNearBottom/messages state reflects reality instead of the
        /// initial defaults nobody would otherwise ever update.
        func rebindViewModelIfNeeded(_ newVM: AIChatViewModel) {
            if let current = vm, current === newVM { return }
            let hadOld = vm != nil
            #if DEBUG
            ScrollMetricsRecorder.shared.record(
                kind: "rebind", a: hadOld ? 1 : 0,
                note: Self.nbDump(viewController?.collectionView))
            #endif
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][rebind] coordinator vm \(hadOld ? "changed" : "was nil") → rebinding subscriptions + resyncing flags")
            subscriptions.removeAll()
            lastMessageSub?.cancel(); lastMessageSub = nil
            lastMessageBlockCountSub?.cancel(); lastMessageBlockCountSub = nil
            lastMessageId = nil
            vm = newVM
            bindViewModel(newVM)
            // Re-apply from the new VM's authoritative messages (identity may
            // be equal content-wise; applySnapshot no-ops on identical ids)
            // and push the CURRENT geometry into the new VM's published flags.
            if !newVM.isLoadingSession {
                applySnapshot(messages: newVM.messages, caller: "rebind")
            }
            syncScrollFlags()
        }

        func bindViewModel(_ vm: AIChatViewModel) {
            // [T-in-chat-search] Search results scroll this list.
            bindChatSearch(vm)

            // 1. Messages → snapshot
            //    Skip while isLoadingSession — binding 3 handles the post-load apply.
            //    This prevents a redundant apply when $messages and $isLoadingSession
            //    dispatch to main queue in the same runloop cycle.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    guard let self else { return }
                    // [T-message-list-empty-on-foreground] If a load is in flight,
                    // DON'T silently drop this update — applySnapshot would no-op
                    // (it early-returns while isLoadingSession). Record it as
                    // pending so binding 3's true→false edge flushes it. Dropping
                    // it was the empty-list bug: when $messages changed during a
                    // foreground-recovery reload but binding 3's edge was collapsed
                    // by removeDuplicates (or $messages landed just after loading
                    // flipped false in the same cycle), nothing ever re-applied —
                    // the list stayed on its stale/empty snapshot while the VM
                    // (and toolbar) had the full messages.
                    if self.vm?.isLoadingSession == true {
                        self.hasPendingSnapshot = true
                        return
                    }
                    self.flushPendingSnapshotIfNeeded(caller: "bind1-messages")
                    self.applySnapshot(messages: msgs, caller: "bind1-messages")
                }
                .store(in: &subscriptions)

            // 1c. [T-ios-ui-blocks-lost-suspend-resume] Suspend-resume flush.
            //     `streamingUIUpdatesSuspended` is a plain (private(set)) var on
            //     the vm — not @Published — but every state change that clears it
            //     (scroll-settle resume, session-transition resume, the SSE final
            //     flush) runs through the vm's @Published/objectWillChange surface.
            //     We piggy-back on `vm.objectWillChange` and edge-detect the
            //     true→false transition ourselves via `lastSuspendedValue`.
            //
            //     Why this is the missing path: during a long multi-tool agent
            //     loop, blocks appended while suspended only set
            //     `hasPendingSnapshot = true` (bind4b); the stream then ends and
            //     cancels the per-message subs, and the terminal rescue at
            //     stream-end skips the flush because suspend is still true (see
            //     the "STREAM-END left pending (still suspended)" log). After that
            //     nothing re-applies — `$messages` won't fire (blocks grew, the
            //     array didn't) and the block-count sub is gone. This hook fires
            //     the instant suspend lifts. Gated on `!isProcessing` so a
            //     mid-stream resume is left to the live subscriptions / settle
            //     path; only the stranded post-stream case is rescued here.
            lastSuspendedValue = vm.streamingUIUpdatesSuspended
            suspendResumeSub = vm.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let vm = self.vm else { return }
                    let now = vm.streamingUIUpdatesSuspended
                    let was = self.lastSuspendedValue
                    self.lastSuspendedValue = now
                    // Only act on a genuine true→false transition.
                    guard was, !now else { return }
                    // [T-ios-ui-frozen-on-tool-while-loop-runs] Flush REGARDLESS
                    // of isProcessing. The old `isProcessing == false` guard left
                    // a mid-loop foreground-resume unflushed: when the app returns
                    // to foreground (resumeAllStreamingUI clears the flag) while
                    // the agent loop is STILL running, the deferred snapshot was
                    // skipped and — because the loop never hits stream-end — the
                    // UI stayed frozen on the last-rendered tool for minutes while
                    // many loop turns ran un-rendered, until an unrelated
                    // sheetDismiss/settle happened to flush. Resume always runs
                    // foreground, so applying the snapshot here is safe.
                    guard self.hasPendingSnapshot else { return }
                    AppLogger(category: "PendingSnap").info("[PendingSnap] suspend-resume flush applied (hasPendingSnapshot=true, isProcessing=\(vm.isProcessing))")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
            suspendResumeSub?.store(in: &subscriptions)

            // 1c. [T-ios-ui-blocks-lost-suspend-resume] Resume hook. When the vm
            //     clears `streamingUIUpdatesSuspended` (true→false) from ANY path,
            //     rebuild a snapshot that was deferred during the suspend window.
            //     Failure chain this fixes: during a multi-tool agent loop, new
            //     blocks append while suspended → blockCountSub only sets
            //     hasPendingSnapshot=true; the stream then ends and cancels the
            //     per-message subs; the terminal rescue sees still-suspended and
            //     skips the flush; nothing else can fire it. This hook is the
            //     missing trigger when suspend finally lifts. Only flush when the
            //     loop is no longer processing (a mid-stream resume is handled by
            //     the live subscriptions / settle path).
            // [T-voice-viewport-context] Voice correction asks for the on-screen rows.
            vm.captureViewportSnapshot = { [weak self] in self?.captureViewportSnapshot() }

            vm.onStreamingUIUpdatesResumed = { [weak self] in
                guard let self else { return }
                // Always main-thread: the chokepoint runs on the main actor, but
                // hop defensively so flush never races a background caller.
                let work = {
                    // [T-ios-ui-frozen-on-tool-while-loop-runs] Flush regardless
                    // of isProcessing — see the objectWillChange sub above. A
                    // foreground-resume while the loop is still running must
                    // re-apply the deferred snapshot, or the UI freezes on the
                    // last-rendered tool until an unrelated sheetDismiss/settle.
                    guard self.hasPendingSnapshot else { return }
                    AppLogger(category: "PendingSnap").info("[PendingSnap] suspend-resume flush (hasPendingSnapshot=true, isProcessing=\(self.vm?.isProcessing == true))")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            }

            // 1b. Retry truncation signal — `retryFromToolBlock`'s sub-message
            //     path mutates `messages[i].blocks` in place without changing
            //     the messages array count, so `$messages` won't fire and the
            //     diffable snapshot keeps its pre-cut block identifiers.
            //     This signal forces a re-apply so stale blocks are removed.
            vm.retrySnapshotReloadSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self, let msgs = self.vm?.messages else { return }
                    let oldCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    self.applySnapshot(messages: msgs, caller: "retrySnapshotReload")
                    let newCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    if newCount != oldCount {
                        let totalBlocks = msgs.reduce(0) { $0 + $1.blocks.count }
                        AppLogger(category: "BlocksLost").info("[BlocksLost] SNAPSHOT REBUILT snapshotItems \(oldCount)→\(newCount) memoryBlocks=\(totalBlocks)")
                    }
                }
                .store(in: &subscriptions)

            // 2. Scroll signals
            vm.scrollToBottomSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self, self.scrollMode == .autoScrolling else { return }
                    self.scrollToBottomNow()
                }
                .store(in: &subscriptions)

            // 2b. Force scroll
            vm.forceScrollToBottom
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    let cv = self.viewController?.collectionView
                    let layout = self.viewController?.messageListLayout
                    let cachedCount = layout?.debugCachedHeightCount ?? 0
                    let precalcCount = layout?.debugPrecalcHeightCount ?? 0
                    AppLogger(category: "ScrollDiag").info("[ScrollDiag][forceScrollToBottom] window=\(cv?.window != nil) contentSize=\(String(format: "%.0f", cv?.contentSize.height ?? 0)) bounds=\(String(format: "%.0f", cv?.bounds.height ?? 0)) adjInsetBot=\(String(format: "%.0f", cv?.adjustedContentInset.bottom ?? 0)) heightCache=\(cachedCount) precalc=\(precalcCount) visibleCells=\(cv?.visibleCells.count ?? 0)")
                    self.vm?.setStreamingUIUpdatesSuspended(false)
                    self.scrollMode = .autoScrolling
                    // [T-send-composer-shrink-absorb] Sent on every send: the
                    // composer is about to shrink and rows are about to arrive.
                    self.composerShrinkAbsorbDeadline = CFAbsoluteTimeGetCurrent() + 2.0
                    // Jumping to the bottom resets the up-button's turn-walk.
                    self.lastJumpedUserId = nil
                    self.scrollToBottomNow(animated: true)
                }
                .store(in: &subscriptions)

            // 2c. Up-button: walk back one user turn at a time. Browse action —
            // do NOT re-enable auto-scroll (leave scrollMode as-is so streaming
            // doesn't yank the user back down after they jump up).
            vm.forceScrollToTop
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.scrollToPreviousUserTurn(animated: true)
                }
                .store(in: &subscriptions)

            // 3. Session load
            vm.$isLoadingSession
                .removeDuplicates()
                .dropFirst()   // skip initial false — only react to true→false after actual load
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLoading in
                    guard let self, !isLoading else { return }
                    // Switching into a session resets the up-button turn-walk.
                    self.lastJumpedUserId = nil
                    let isFirstLoad = self.previousSnapshotIds.isEmpty
                    // Only clear caches when items will actually change — prevents
                    // a duplicate dispatch from clearing caches that won't be rebuilt.
                    if let msgs = self.vm?.messages {
                        self.viewController?.messageListLayout?.clearHeightCache()
                        // [T-scroll-estimate-fidelity] Row ids are new each load.
                        self.stableHeightKeyCache.removeAll()
                        // [T-ios-listsessions-perf] attrStringHeightCache is
                        // deliberately NOT cleared here any more. Its key is
                        // (content, width, fontSize), so an entry from another
                        // session can only be returned for text that is
                        // byte-identical at the same width and font — in which
                        // case the height is correct by construction. Keeping
                        // it across the switch is what makes reopening a
                        // session you were just in avoid re-measuring the whole
                        // page, which is where the applySnapshot hangs were.
                        self.userBubbleHeightCache.removeAll()
                        // This is the authoritative post-load apply; it carries the
                        // latest messages, so any snapshot deferred during the load
                        // window (bind1 set hasPendingSnapshot) is now satisfied.
                        // [T-message-list-empty-on-foreground]
                        self.hasPendingSnapshot = false
                        self.applySnapshot(messages: msgs, caller: "bind3-sessionLoad")
                    }
                    if isFirstLoad {
                        // First load: scroll to bottom and clamp.
                        // 8s window (was 2s) so async video thumbnail
                        // generation can complete and the cell-height
                        // correction reaches the user before we release
                        // the bottom pin.
                        self.scrollMode = .autoScrolling
                        self.clampAfterSessionLoad = true
                        self.clampDeadline = Date().addingTimeInterval(8.0)
                        self.scrollToLastItem()
                    }
                    // Sync reload: keep current scroll position, just update data
                }
                .store(in: &subscriptions)

            // 4. Streaming: subscribe to last assistant message + block count changes.
            // Use the last assistant message (not msgs.last) because queued user
            // messages can be appended while an assistant is still streaming.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    let lastAssistant = msgs.last(where: { $0.role == .assistant })
                    self?.subscribeToLastMessage(lastAssistant)
                }
                .store(in: &subscriptions)

            // 4b. Re-subscribe when isProcessing transitions to true (retry/resume).
            // Retry reuses the existing assistant message without mutating the messages
            // array, so $messages won't fire. The block-count subscription was torn down
            // when processing stopped; re-establish it here.
            vm.$isProcessing
                .removeDuplicates()
                .filter { $0 }   // only on false → true transition
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.lastMessageId = nil  // force re-subscribe
                    let lastAssistant = self.vm?.messages.last(where: { $0.role == .assistant })
                    self.subscribeToLastMessage(lastAssistant)
                }
                .store(in: &subscriptions)

            // 4c. [T-fold-consecutive-tools] Turn ended: the whole message is
            //     planned now ([T-fold-at-request-end] — the catch-all for
            //     runs whose replies were too short to fold them mid-task), and
            //     anything held back while the user read above it folds too.
            vm.$isProcessing
                .removeDuplicates()
                .dropFirst()
                .filter { !$0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // [T-stream-end-scroll-overlap] Once per turn: was the
                    // user scrolling when the reply finished? That is the
                    // window where held-back text lands in one go while
                    // height corrections are deferred. Pair this line with the
                    // [DeferGrowth] ALLOW/HOLD lines that follow it.
                    if let cv = self?.viewController?.collectionView,
                       let layout = self?.viewController?.messageListLayout,
                       cv.isTracking || cv.isDecelerating || layout.deferSelfSizing {
                        AppLogger(category: "CellSize").info("[DeferGrowth] TURN-END mid-scroll — tracking=\(cv.isTracking) decel=\(cv.isDecelerating) deferSelfSizing=\(layout.deferSelfSizing) deferredHeights=\(layout.deferredHeightCount) offset=\(String(format: "%.0f", cv.contentOffset.y)) suspended=\(self?.vm?.streamingUIUpdatesSuspended == true)")
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.resnapshotIfToolFoldsChanged(caller: "toolFold-turnEnd")
                    }
                }
                .store(in: &subscriptions)

            // 4d. [T-fold-at-request-end] A request of the running task ended
            //     with a reply of at least 2 lines: fold the runs before it.
            //     The only mid-task fold trigger; `receive(on:)` already moves
            //     it out of whatever apply is in progress.
            vm.toolFoldSeparatorSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.resnapshotIfToolFoldsChanged(caller: "toolFold-requestEnd")
                }
                .store(in: &subscriptions)

            // 5. State changes → bridge updates
            Publishers.CombineLatest4(
                vm.$isProcessing, vm.$autoRetryAttempt,
                vm.$autoRetryCountdown, vm.$canResume
            )
            .removeDuplicates { a, b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLastCellBridge() }
            .store(in: &subscriptions)


            // 6. Compact finished → reconfigure all cells to update opacity/divider
            vm.$isCompacting
                .removeDuplicates()
                .dropFirst()   // skip initial value — only react to actual true→false transitions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCompacting in
                    guard let self, !isCompacting else { return }
                    // Compact just ended — apply snapshot for new divider/removed messages,
                    // then reconfigure visible cells so opacity updates. Do NOT clear height
                    // cache — compacted messages retain their measured heights to prevent
                    // scroll jitter when scrolling back into the compacted zone.
                    if let msgs = self.vm?.messages { self.applySnapshot(messages: msgs, caller: "bind6-compact") }
                    self.reconfigureVisibleCells()
                }
                .store(in: &subscriptions)

            // 7. Font size changes
            NotificationCenter.default.publisher(for: .fontSettingsMessageBaseChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.vm?.invalidateAttributedStringCaches()
                    self.reconfigureAllCells()
                }
                .store(in: &subscriptions)

            // 7b. Memory pressure — drop the measured-height LRU.
            // [T-ios-listsessions-perf] This cache now outlives session change,
            // so it needs an explicit pressure release. Dropping it is always
            // safe: every entry is a pure function of its key, so the worst
            // case is re-measuring on the next snapshot.
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let dropped = self.attrStringHeightCache.count
                    self.attrStringHeightCache.removeAll()
                    self.userBubbleHeightCache.removeAll()
                    if dropped > 0 {
                        self.heightCacheLogger.info("memory warning — dropped \(dropped) cached height(s)")
                    }
                }
                .store(in: &subscriptions)

            // 8a. Background entry — snapshot content length so we can detect
            //     whether significant content accumulated while backgrounded.
            NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // [T-ios-bg-resume-collapse] Must be the SAME metric the
                    // foreground handler compares against (`liveContentLength`),
                    // or the delta subtracts two different quantities and the
                    // gate fires on noise / misses real growth.
                    let len = self.liveContentLength()
                    self.contentLengthAtBackground = len
                    AppLogger(category: "FGLayout").info("[FGLayout] → background, snapshotLen=\(len)")
                }
                .store(in: &subscriptions)

            // 8b. Foreground return — re-measure the visible cells whose content
            //     grew while the app was backgrounded.
            //
            // [T-ios-bg-resume-collapse] Field report 2026-08-10: "it was
            // running, I switched to another app, came back, and got this" —
            // a screenshot with the collapsed "深度思考" chip printed on top of
            // the prose. Three defects in the original handler, all of which
            // let a stale mid-stream height survive the round-trip:
            //
            //  1. It cleared only the LAYOUT's height cache and relied on
            //     `reconfigureVisibleCells` for the rest. But the CELL's own
            //     `lastComputedHeight` is checked FIRST in PLAF and is only
            //     nil'd when the provider actually re-runs — see
            //     `remeasureVisibleCells`. This is the same gap 232e4194 /
            //     9dedf0db closed for `blockContentFilledSignal`; it was never
            //     applied here.
            //  2. The `accumulated >= 200` gate. Overlap needs about ONE line
            //     of growth (~20 chars at this width) — and a tool block
            //     finishing or a thinking block collapsing changes the
            //     rendered height while adding little or no content at all.
            //     A 200-char threshold skips exactly the small deltas that
            //     still shift layout. Any change now re-measures; unchanged
            //     content still short-circuits, so a plain
            //     background/foreground with no streaming stays free.
            //  3. `lastAssistantContentLength()` measured only `messages.last`,
            //     so growth on an EARLIER still-live message (6cf9f58c's
            //     running-tool case, i.e. any multi-turn agent loop) was
            //     invisible to the delta. Now `liveContentLength()`.
            //
            // Deliberately on `willEnterForeground` rather than
            // `didBecomeActive`: this must land before the first post-resume
            // layout pass, and it touches no VM state that the
            // didBecomeActive replay owns.
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    let currentLen = self.liveContentLength()
                    let bgLen = self.contentLengthAtBackground ?? currentLen
                    self.contentLengthAtBackground = nil
                    let accumulated = currentLen - bgLen
                    AppLogger(category: "FGLayout").info("[FGLayout] → foreground, bgLen=\(bgLen) currentLen=\(currentLen) accumulated=\(accumulated)")
                    // Any change at all — including a SHRINK, which a collapsed
                    // thinking block or a replaced tool placeholder produces.
                    guard accumulated != 0 else {
                        AppLogger(category: "FGLayout").info("[FGLayout] skip layout (content unchanged)")
                        return
                    }
                    // [T-ios-scenephase-active-sigkill / issue #355] Defer the
                    // re-measure by one yield instead of running it inside the
                    // notification delivery.
                    //
                    // `remeasureVisibleCells` invalidates every visible cell and
                    // re-measures it synchronously. With the text caches cold —
                    // which is the normal state after a memory warning is
                    // delivered to the suspended app, and is exactly why a
                    // healthy 18MB footprint accompanies this hang — each cell is
                    // a miss and lands on `measureAttributedStringHeight`'s
                    // near-O(n²) branch. On a CJK-heavy transcript a few such
                    // cells sum to seconds: the measured table in
                    // ChatMessageViews.swift puts 24k chars at 6.48s, and #355
                    // reported 6.3s in one uninterrupted block, then a watchdog
                    // SIGKILL.
                    //
                    // Same treatment the rest of the app's foreground-resume work
                    // already gets (MinisApp.swift scenePhase→.active,
                    // BackgroundKeepAliveManager.willEnterForeground): yielding
                    // first lets the view-graph transition settle and gives this
                    // pass its own runloop turn with a full frame budget. The
                    // `:2199` intent is preserved — it still lands before the
                    // first user-visible layout, just not inside the transition
                    // tick.
                    //
                    // The delta above is captured SYNCHRONOUSLY on purpose:
                    // `contentLengthAtBackground` is consumed here, so reading it
                    // after the yield would race a bg→fg→bg cycle that re-armed
                    // it. Only the expensive work moves.
                    Task { @MainActor in
                        await Task.yield()
                        // Re-check after the yield: a rapid fg→bg flip may have
                        // re-backgrounded us, and re-measuring while not active is
                        // both wasted and the case UIKit can apply incompletely.
                        guard UIApplication.shared.applicationState != .background else {
                            AppLogger(category: "FGLayout").info("[FGLayout] skip layout (re-backgrounded before yield)")
                            return
                        }
                        self.remeasureVisibleCells(reason: "foreground(delta=\(accumulated))")
                    }
                }
                .store(in: &subscriptions)

            // 8c. [T-fg-touch-probe] Foreground return - record which view takes
            //     a touch on each visible text block and table.
            //
            // Field report (iOS 26.6, 2026-10-07): after switching away and back,
            // long-press text selection and markdown-table horizontal scroll
            // sometimes stop working while the list itself still scrolls. It
            // has not reproduced on the vphone (90 s / 5 min in the background,
            // keyboard open), and no lifecycle handler found in the code leaves
            // these views disabled or covered. This one line per return names
            // the blocker the next time it happens: the view a hit test lands
            // on instead of the text view / table, a stuck gesture recognizer,
            // an ancestor with interaction off, or a view overflowing its cell.
            // Read-only: it never changes view or gesture state.
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // Off the notification ([T-ios-scenephase-active-sigkill]) and
                    // after the post-resume layout and re-measure have landed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.probeTouchTargetsAfterForeground()
                    }
                }
                .store(in: &subscriptions)

            // 9. Text block filled — reconfigure the cell so UIHostingConfiguration
            //    re-measures height after transitioning from empty to non-empty.
            vm.blockContentFilledSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] (messageId, blockId) in
                    guard let self,
                          let ds = self.dataSource else { return }
                    // [T-fold-at-request-end] Deliberately no fold trigger here:
                    // a reply starting to stream no longer folds the tool runs
                    // above it; the end of its request does (see 4d).
                    let item = MessageListItem.assistantBlock(messageId, blockId)
                    var snapshot = ds.snapshot()
                    let items = snapshot.itemIdentifiers
                    guard let idx = items.firstIndex(of: item) else { return }

                    // Invalidate the height cache BEFORE reconfiguring so the
                    // layout doesn't reuse the stale empty-content height.
                    // Without this, the cell briefly keeps its ~0pt height from
                    // the empty block, causing overlap with the tool block above.
                    //
                    // [T-first-text-scroll-jump] ...but never drop the row to
                    // the EMPTY block's 0pt estimate. The signal reaches here
                    // ~70ms after the text, and by then the cell has usually
                    // self-sized to its first line already (device log:
                    // `CELL GREW FROM ~0: idx=13 0→22pt` at .350, signal at
                    // .421). `invalidateHeight` threw that 22pt away and the row
                    // fell back to the snapshot's 0pt estimate until the next
                    // streaming re-measure ~0.3s later (`0→56pt` at .705). With
                    // the list pinned to the bottom, that missing line is the
                    // reported jump: everything above the reply moved down
                    // 22pt (66px in the 120fps recording) the moment the first
                    // characters appeared, held for ~0.32s, then came back,
                    // with the text drawn over the composer strip meanwhile.
                    // Only a reply that STARTS with text hits it: thinking and
                    // tool blocks are created populated and never take this
                    // path, and the typing indicator they replace is about the
                    // same height. So: a real height (>= 4pt, the cache rule's
                    // floor for "not an empty block") is kept until the
                    // re-measure below replaces it; otherwise the row falls
                    // back to the text estimate for its current content, not 0.
                    if let layout = self.viewController?.messageListLayout {
                        let held = layout.cachedHeight(at: idx)
                        layout.invalidateHeight(at: idx)
                        if let held, held >= 4 {
                            layout.setMeasuredHeight(held, at: idx)
                        } else if let vm = self.vm {
                            let width = self.viewController?.collectionView.bounds.width ?? 390
                            layout.setEstimatedHeight(
                                Self.estimateItemHeight(item, messages: vm.messages, width: width), at: idx)
                        }
                    }

                    // [T-ios-empty-block-fill-cell-cache] Clear on BOTH sides of
                    // the apply — same shape as the `.thinkingBlockToggled`
                    // handler below (see the `DispatchQueue.main.async` re-clear
                    // there). Before, so no layout pass between the
                    // `invalidateHeight` above and the provider re-run can answer
                    // from the stale cache; after, for the cases where the
                    // provider never ran (below).
                    if let cv = self.viewController?.collectionView {
                        let ip = IndexPath(item: idx, section: 0)
                        (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    }

                    snapshot.reconfigureItems([item])
                    ds.apply(snapshot, animatingDifferences: false)

                    // Why the cell-side clear is needed at all: `SelfSizingCell`
                    // keeps its OWN `lastComputedHeight`, and since b4268586
                    // dropped that cache's 50ms bound it is reused forever while
                    // the width matches — its dedup short-circuit is the FIRST
                    // thing `preferredLayoutAttributesFitting` checks, ahead of
                    // the interaction (e9d167c2) and streaming (81e43b58) guards.
                    // A cell still holding the height it measured while this
                    // block was empty therefore keeps answering with it, and
                    // `contentView.clipsToBounds` crops the arriving text while
                    // the following blocks stack from the too-short frame — the
                    // reported tool-capsule / prose overlap.
                    //
                    // Scope honestly: the reconfigure usually fixes this by
                    // itself, since the cell provider calls
                    // `applyContentConfiguration`, which nils that cache. This
                    // second clear covers the case where the provider never ran —
                    // `configureCell`'s `.assistantBlock` branch returns early on
                    // a messageIndex / blockId miss (the SnapshotDiag MISS logs),
                    // leaving the old configuration and its height in place.
                    //
                    // Cost is a `cellForItem` lookup plus three nil writes, at
                    // most once per text block per turn: both senders gate on a
                    // `wasEmpty` edge and `block.content` is a monotonic
                    // full-text replacement, so this is one-shot per block, never
                    // per token. It cannot loop — a re-measure writes only
                    // cell-private fields and two unobserved layout dictionaries,
                    // and nothing on that path can re-emit this signal.
                    if let cv = self.viewController?.collectionView {
                        let ip = IndexPath(item: idx, section: 0)
                        (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
                    }

                }
                .store(in: &subscriptions)

            // Re-snapshot when toggleUsage inserts/removes a footer cell.
            //
            // [T-ios-plaf-cache-footer-staleness] `applySnapshot` alone is only
            // enough when the toggle INSERTS or REMOVES the footer — diffable
            // re-runs the cell provider (and so `applyContentConfiguration`,
            // which nils the height cache) for inserted/moved items only. When
            // the footer cell ALREADY exists — the common case, since
            // `needsFooter` is true for every last assistant message — the item
            // identifier is unchanged, the diff is empty, and UIKit never
            // touches the cell: no prepareForReuse, no applyContentConfiguration,
            // no clearCachedHeight. The SwiftUI body still re-renders (showUsage
            // is @Published) so the content grows, but
            // `preferredLayoutAttributesFitting` keeps returning the cached
            // height and `contentView.clipsToBounds` crops the usage row.
            //
            // Before b4268586 the 50ms bound on that cache healed this within a
            // frame or two; with the bound gone it is permanent. So invalidate
            // the footer cells explicitly here, mirroring the
            // `.thinkingBlockToggled` handler below.
            NotificationCenter.default.publisher(for: .messageListNeedsResnapshot)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let vm = self.vm else { return }
                    self.invalidateFooterHeightCaches()
                    self.applySnapshot(messages: vm.messages)
                }
                .store(in: &subscriptions)

            // [T-user-ask-notsent-merge] A rejected user_ask joined a run of
            // not-sent calls: its row leaves the list (the run's lead shows the
            // count). Same deferral as a tool-fold re-plan while streaming
            // updates are suspended.
            NotificationCenter.default.publisher(for: .userAskNotSentRegrouped)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let vm = self.vm, !vm.isLoadingSession else { return }
                    if vm.streamingUIUpdatesSuspended {
                        self.hasPendingSnapshot = true
                        return
                    }
                    self.applySnapshot(messages: vm.messages, caller: "userAskNotSent")
                }
                .store(in: &subscriptions)
        }
}

// MARK: - [T-fg-touch-probe] Foreground touch probe

extension CollectionViewMessageListV3.Coordinator {
        /// Hit-tests the middle of every visible message text view and table
        /// and logs where the touch would land. See subscription 8c.
        func probeTouchTargetsAfterForeground() {
            guard UIApplication.shared.applicationState == .active,
                  let cv = viewController?.collectionView, let window = cv.window else { return }
            let listRect = cv.convert(cv.bounds, to: window)
            var samples: [ForegroundTouchProbe.Sample] = []
            for cell in cv.visibleCells {
                for (kind, target) in Self.touchProbeTargets(in: cell.contentView) {
                    guard samples.count < ForegroundTouchProbe.maxSamples else { break }
                    let visible = target.convert(target.bounds, to: window).intersection(listRect)
                    guard visible.width >= 8, visible.height >= 8 else { continue }
                    let point = CGPoint(x: visible.midX, y: visible.midY)
                    let hit = window.hitTest(point, with: nil)
                    let inCell = target.convert(target.bounds, to: cell)
                    samples.append(ForegroundTouchProbe.Sample(
                        kind: kind,
                        hitInsideTarget: hit.map { $0 === target || $0.isDescendant(of: target) } ?? false,
                        hitChain: Self.classChain(of: hit),
                        nonInteractiveAncestor: Self.firstNonInteractive(from: target, upTo: window),
                        activeRecognizers: Self.activeRecognizers(from: target, upTo: window, list: cv),
                        overflowBelowCell: max(0, inCell.maxY - cell.bounds.maxY)))
                }
            }
            // Window-level recognizers (the Always On activity observer, a
            // promoted table cell's dismiss tap) only matter while stuck mid-gesture.
            let windowRecognizers = (window.gestureRecognizers ?? [])
                .filter { $0.state == .began || $0.state == .changed }
                .map { "\(type(of: $0)):state=\($0.state.rawValue)" }
            let responder = UIResponder.minisCurrentFirstResponder().map { String(describing: type(of: $0)) }
            // A sheet or cover over the chat legitimately takes the touch; name
            // it so such a line is not mistaken for the bug.
            var top = window.rootViewController
            while let next = top?.presentedViewController { top = next }
            let presented = top === window.rootViewController ? nil : top.map { String(describing: type(of: $0)) }
            for line in ForegroundTouchProbe.summarize(samples: samples, windowRecognizers: windowRecognizers,
                                                       firstResponder: responder, presented: presented) {
                AppLogger(category: "FGTouch").info(line)
            }
        }

        private static func touchProbeTargets(in root: UIView) -> [(ForegroundTouchProbe.Kind, UIView)] {
            var found: [(ForegroundTouchProbe.Kind, UIView)] = []
            var stack: [UIView] = [root]
            while let v = stack.popLast(), found.count < ForegroundTouchProbe.maxSamples {
                if v.isHidden || v.alpha < 0.01 { continue }
                if v is SelectableMarkdownTextView { found.append((.text, v)) }
                if v is TableScrollView { found.append((.table, v)) }
                stack.append(contentsOf: v.subviews)
            }
            return found
        }

        private static func classChain(of view: UIView?) -> [String] {
            var chain: [String] = []
            var v = view
            while let cur = v, chain.count < 4 {
                chain.append(String(describing: type(of: cur)))
                v = cur.superview
            }
            return chain
        }

        private static func firstNonInteractive(from view: UIView, upTo window: UIWindow) -> String? {
            var v: UIView? = view
            while let cur = v, cur !== window {
                if !cur.isUserInteractionEnabled { return String(describing: type(of: cur)) }
                v = cur.superview
            }
            return nil
        }

        /// Recognizers that can keep a new long-press or pan from starting:
        /// any on the path still mid-gesture (.began / .changed with no finger
        /// down), a disabled one on the target itself, and a disabled list pan.
        /// UIKit disables plenty of recognizers by design (a non-scrolling
        /// text view's own pan, multi-select), so those are not reported.
        private static func activeRecognizers(from view: UIView, upTo window: UIWindow,
                                              list: UICollectionView) -> [String] {
            var notes: [String] = []
            var v: UIView? = view
            while let cur = v, cur !== window {
                for gr in cur.gestureRecognizers ?? [] {
                    let stuck = gr.state == .began || gr.state == .changed
                    let byDesign = (cur as? UIScrollView).map { !$0.isScrollEnabled && ($0.panGestureRecognizer === gr || String(describing: type(of: gr)).contains("DelayedTouchesBegan")) } ?? false
                    let disabledHere = !gr.isEnabled && cur === view && !byDesign
                    let listPanOff = !gr.isEnabled && gr === list.panGestureRecognizer
                    guard stuck || disabledHere || listPanOff else { continue }
                    notes.append("\(type(of: cur)).\(type(of: gr)):\(gr.isEnabled ? "state=\(gr.state.rawValue)" : "disabled")")
                }
                v = cur.superview
            }
            return notes
        }
}

private extension UIResponder {
    private static weak var minisProbeFound: UIResponder?
    @objc private func minisProbeCapture(_ sender: Any?) { UIResponder.minisProbeFound = self }
    static func minisCurrentFirstResponder() -> UIResponder? {
        minisProbeFound = nil
        UIApplication.shared.sendAction(#selector(minisProbeCapture(_:)), to: nil, from: nil, for: nil)
        return minisProbeFound
    }
}

// BEGIN ForegroundTouchProbe
/// [T-fg-touch-probe] Turns the foreground hit-test samples into log lines:
/// one "ok" line when every target takes its own touch, otherwise one WARN
/// line per blocked target naming what took the touch instead.
enum ForegroundTouchProbe {
    static let maxSamples = 12

    enum Kind: String { case text, table }

    struct Sample {
        let kind: Kind
        /// The hit test at the target's visible middle landed on it or inside it.
        let hitInsideTarget: Bool
        /// The view the hit test returned, then up to three ancestors.
        let hitChain: [String]
        /// First view from the target up whose user interaction is off.
        let nonInteractiveAncestor: String?
        /// Disabled or mid-gesture recognizers between the target and the window.
        let activeRecognizers: [String]
        /// How far the target hangs below its cell (touches there miss it).
        let overflowBelowCell: CGFloat
    }

    static func summarize(samples: [Sample], windowRecognizers: [String], firstResponder: String?,
                          presented: String? = nil) -> [String] {
        let blocked = samples.filter { !$0.hitInsideTarget || $0.nonInteractiveAncestor != nil }
        let texts = samples.filter { $0.kind == .text }.count
        let tables = samples.count - texts
        var lines: [String] = []
        let head = "[FGTouch] foreground probe: \(samples.count) target(s) (text=\(texts) table=\(tables)), blocked=\(blocked.count)"
            + ", firstResponder=\(firstResponder ?? "none")"
            + (presented.map { ", presented=\($0)" } ?? "")
            + (windowRecognizers.isEmpty ? "" : ", windowRecognizers=[\(windowRecognizers.joined(separator: ","))]")
        lines.append(blocked.isEmpty && windowRecognizers.isEmpty ? head + " - ok" : head)
        for s in samples {
            let notes = blockNotes(s)
            guard !notes.isEmpty else { continue }
            lines.append("[FGTouch] WARN \(s.kind.rawValue) " + notes.joined(separator: " "))
        }
        return lines
    }

    private static func blockNotes(_ s: Sample) -> [String] {
        var notes: [String] = []
        if !s.hitInsideTarget { notes.append("hit=\(s.hitChain.isEmpty ? "nil" : s.hitChain.joined(separator: "<"))") }
        if let off = s.nonInteractiveAncestor { notes.append("interactionOff=\(off)") }
        if !s.activeRecognizers.isEmpty { notes.append("recognizers=[\(s.activeRecognizers.joined(separator: ","))]") }
        if s.overflowBelowCell >= 1 { notes.append("overflowBelowCell=\(Int(s.overflowBelowCell))pt") }
        return notes
    }
}
// END ForegroundTouchProbe
