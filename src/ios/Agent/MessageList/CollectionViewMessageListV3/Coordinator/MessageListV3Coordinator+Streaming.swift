//
//  MessageListV3Coordinator+Streaming.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Subscription to the streaming (last) message: coalesced layout flushes,
//  pending snapshot flush, coalesced scroll scheduling.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +Streaming" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Streaming Subscription

        func subscribeToLastMessage(_ message: ChatMessage?) {
            guard let message, message.id != lastMessageId else { return }
            lastMessageId = message.id
            lastMessageSub?.cancel()
            lastMessageBlockCountSub?.cancel()

            guard vm?.isProcessing == true else { return }

            // Watch objectWillChange for content updates (text streaming)
            lastMessageSub = message.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak message] _ in
                    guard let self else { return }
                    guard self.vm?.isProcessing == true else {
                        // [DIAG-SUB-END] Streaming ended — this is the last
                        // objectWillChange notification. Cancel subs and do final flush.
                        // If flushStreamingLayout() is throttled here, the pending
                        // work item fires later but no more objectWillChange comes,
                        // so it's the very last chance to invalidate layout.
                        AppLogger(category: "StreamDiag").info("[StreamSub] END — isProcessing=false, cancelling subs, final flush. pendingLayout=\(self.pendingStreamingLayout != nil) tracking=\(self.viewController?.collectionView?.isTracking ?? false) decel=\(self.viewController?.collectionView?.isDecelerating ?? false)")
                        self.lastMessageSub?.cancel()
                        self.lastMessageSub = nil
                        self.lastMessageBlockCountSub?.cancel()
                        self.lastMessageBlockCountSub = nil
                        self.flushStreamingLayout()
                        // [T-ios-tooluibatch-stuck-pending-snapshot] Terminal
                        // rescue for a snapshot deferred during a streaming-UI
                        // suspend window. While `streamingUIUpdatesSuspended` was
                        // true, the blocks.count sub (bind4b) only set
                        // `hasPendingSnapshot = true` without rebuilding the
                        // diffable snapshot, so blocks added during the suspend
                        // (e.g. tools 63–80 of a long agent loop) had no cells.
                        // flushStreamingLayout() above tries to flush it, but if
                        // it is still throttled (its trailing work item) OR the
                        // suspend overlapped this terminal tick, the pending
                        // snapshot could be stranded forever once these subs are
                        // cancelled (no further objectWillChange will arrive).
                        // Force one direct flush here — this fires exactly once
                        // at stream end, so there is no per-tick / large-data
                        // cost, and applySnapshot rebuilds from the authoritative
                        // current `messages`, so no row mix-up. No-op unless a
                        // snapshot is actually pending. Gated on NOT-suspended:
                        // applying a snapshot during an active session-transition
                        // suspend is exactly what the suspend guards against, so
                        // if we're still suspended we leave `hasPendingSnapshot`
                        // set for the resume path / next $messages apply to clear.
                        AppLogger(category: "PendingSnap").info("[PendingSnap] STREAM-END terminal rescue check — hasPendingSnapshot=\(self.hasPendingSnapshot) suspended=\(self.vm?.streamingUIUpdatesSuspended == true)")
                        if self.hasPendingSnapshot, self.vm?.streamingUIUpdatesSuspended != true {
                            self.flushPendingSnapshotIfNeeded(caller: "stream-end")
                        } else if self.hasPendingSnapshot {
                            // Still suspended at stream-end: cannot safely apply here.
                            // Left for the resume path; flag it so the freeze is traceable.
                            // [T-ios-scroll-suspend-leak] This is the key symptom line:
                            // content is written to DB but the UI is waiting on a
                            // suspend that must be released (scroll settle / foreground
                            // return / the new openSession clear) before it flushes.
                            AppLogger(category: "PendingSnap").warning("[PendingSnap] ⚠️ STREAM-END left pending (still suspended) — content in DB, UI frozen until suspend-resume (or next openSession clears it)")
                        }
                        return
                    }
                    self.flushStreamingLayout()
                }

            // Watch blocks.count → rebuild snapshot when new blocks appear
            lastMessageBlockCountSub = message.$blocks
                .map(\.count)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .dropFirst()
                .sink { [weak self] count in
                    guard let self, let msgs = self.vm?.messages else { return }
                    if self.vm?.streamingUIUpdatesSuspended == true {
                        // [PendingSnap] Deferring snapshot rebuild while suspended;
                        // blocks added now (count) won't get cells until a flush.
                        AppLogger(category: "PendingSnap").info("[PendingSnap] DEFER blockCount=\(count) — suspended, set hasPendingSnapshot=true (was \(self.hasPendingSnapshot))")
                        self.hasPendingSnapshot = true
                        return
                    }
                    self.applySnapshot(messages: msgs, caller: "bind4b-blockCount")
                }
        }

        /// [T-rotate-scroll-jank] Re-run the snapshot pass after
        /// `MessageListLayout` dropped every width-dependent height (a settled
        /// rotation / split-view resize). With unchanged items that pass only
        /// re-seeds precalc / estimates and then skips the re-apply
        /// (`[SnapshotDiag] SKIP … items unchanged`), so nothing is reloaded
        /// or reconfigured. While streaming UI updates are suspended (a drag
        /// is in progress) a snapshot pass is exactly what the suspend guards
        /// against, so it is queued for the resume flush instead, which runs
        /// the same pass.
        func reseedHeightsAfterWidthPurge() {
            guard let vm else { return }
            if vm.streamingUIUpdatesSuspended {
                hasPendingSnapshot = true
                AppLogger(category: "CellSizing").info("[WidthPurge] reseed deferred — streaming UI suspended, queued for the resume flush")
                return
            }
            let start = CACurrentMediaTime()
            applySnapshot(messages: vm.messages, caller: "widthPurge-reseed")
            AppLogger(category: "CellSizing").info("[WidthPurge] reseeded \(vm.messages.count) messages in \(String(format: "%.1f", (CACurrentMediaTime() - start) * 1000))ms")
        }

        /// Flush any snapshot that was deferred while streaming UI updates were suspended.
        // fileprivate so updateUIViewController (struct, same file) can use it as
        // a backstop flush. [T-message-list-empty-on-foreground]
        func flushPendingSnapshotIfNeeded(caller: String = "?") {
            guard hasPendingSnapshot else { return }
            hasPendingSnapshot = false
            let blocks = vm?.messages.last(where: { $0.role == .assistant })?.blocks.count ?? -1
            // [T-ios-scroll-suspend-leak] Include blockCount + isProcessing so a
            // FLUSH can be matched against the DEFER that queued it — a DEFER with
            // no corresponding FLUSH (see the [SessionLoad] stale-suspend clear) is
            // the leak signature.
            AppLogger(category: "PendingSnap").info("[PendingSnap] FLUSH caller=\(caller) blockCount=\(blocks) isProcessing=\(vm?.isProcessing == true) — applying deferred snapshot")
            if let msgs = vm?.messages { applySnapshot(messages: msgs, caller: "flushPending(\(caller))") }
        }

        private func flushStreamingLayout() {
            // Check if a deferred snapshot can now be applied (sheet dismissed).
            flushPendingSnapshotIfNeeded(caller: "flushStreamingLayout")

            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout else { return }

            // Adaptive throttle: 100ms when auto-scrolling (user watching),
            // 3s when user has scrolled away (reading earlier content).
            let interval: TimeInterval = scrollMode == .autoScrolling ? 0.1 : 3.0
            let now = Date()
            if now.timeIntervalSince(lastStreamingLayoutTime) < interval {
                // Schedule a trailing fire so the final update isn't lost.
                if pendingStreamingLayout == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingStreamingLayout = nil
                        self?.doFlushStreamingLayout()
                    }
                    pendingStreamingLayout = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
                }
                return
            }
            pendingStreamingLayout?.cancel()
            pendingStreamingLayout = nil
            doFlushStreamingLayout()
        }

        /// Actually perform the streaming layout flush + scroll.
        private func doFlushStreamingLayout() {
            lastStreamingLayoutTime = Date()
            guard let layout = viewController?.messageListLayout else { return }
            // Always invalidate layout — even during scrolling. The layout's
            // invalidationContext already skips contentOffsetAdjustment when
            // isTracking/isDecelerating, so this won't cause scroll jitter.
            // Skipping invalidation entirely caused text blocks that transitioned
            // from empty to non-empty (via streaming bypass) to stay at ~0 height.
            layout.invalidateLayout()

            if scrollMode == .autoScrolling {
                scheduleCoalescedScroll()
            }
        }

        /// Coalesce rapid scroll signals into a single scroll action.
        /// Uses a short 80ms delay — just enough to batch multiple near-simultaneous
        /// signals without noticeable visual lag during streaming.
        func scheduleCoalescedScroll() {
            pendingScrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let isTracking = self.viewController?.collectionView?.isTracking ?? false
                if self.scrollMode != .autoScrolling || isTracking { return }
                self.scrollToBottomNow()
            }
            pendingScrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
}
