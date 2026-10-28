//
//  MessageListV3Coordinator+ContentLength.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Content-length helpers used to decide whether a background/foreground
//  transition needs a re-measure (live assistant turns included).
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +ContentLength" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Content Length Helper

        /// Total character count across all blocks of the last assistant message.
        private func lastAssistantContentLength() -> Int {
            guard let msg = vm?.messages.last(where: { $0.role == .assistant }) else { return 0 }
            return msg.blocks.reduce(0) { $0 + $1.content.count }
        }

        /// [T-ios-bg-resume-collapse] Total content length across EVERY message
        /// that can still be growing, not just `messages.last`.
        ///
        /// The background/foreground gate used to measure only the last
        /// assistant message. But `liveAssistantMessageIds` (6cf9f58c)
        /// established that an EARLIER assistant turn keeps receiving output
        /// through a running/streaming tool block while a newer turn streams —
        /// growth on such a message contributed 0 to the delta, so the gate
        /// concluded "nothing changed" and skipped the re-measure for exactly
        /// the multi-turn agent loop this bug is reported against.
        func liveContentLength() -> Int {
            guard let vm else { return 0 }
            let msgs = vm.messages
            let liveIds = Self.liveAssistantMessageIds(messages: msgs,
                                                       isProcessing: vm.isProcessing)
            // When the loop is not processing, `liveIds` is empty by design;
            // fall back to the last assistant message so a turn that ENDED
            // while backgrounded (the SIGKILL / detached-loop case) is still
            // compared against something meaningful.
            let considered = liveIds.isEmpty
                ? msgs.last(where: { $0.role == .assistant }).map { [$0] } ?? []
                : msgs.filter { liveIds.contains($0.id) }
            return considered.reduce(0) { acc, m in
                acc + m.blocks.reduce(0) { $0 + $1.content.count }
            }
        }

        /// [T-ios-bg-resume-collapse] Re-measure every visible cell from
        /// scratch: drop BOTH height layers, then reconfigure.
        ///
        /// Clearing the layout's index cache alone is not enough, and this is
        /// the defect the field report ("run a loop, switch away, come back →
        /// blocks printed on top of each other") lands on. `SelfSizingCell`
        /// keeps its OWN `lastComputedHeight`, and since b4268586 dropped that
        /// cache's 50ms bound it is reused forever while the width matches —
        /// its dedup short-circuit is the FIRST thing
        /// `preferredLayoutAttributesFitting` checks, ahead of the layout's
        /// caches and of the interaction/streaming guards. A cell that
        /// measured mid-stream before the app was backgrounded therefore keeps
        /// answering with that too-short height after the content grew, so
        /// `prepare()` stacks every following cell from it (the overlap) and
        /// `contentView.clipsToBounds` crops the cell's own text (the
        /// "cut off at the bottom").
        ///
        /// `reconfigureItems` does NOT reliably fix this by itself: it only
        /// nils the cell cache when the provider actually re-runs, and
        /// `configureCell`'s `.assistantBlock` branch returns early on a
        /// messageIndex / blockId miss — the same escape hatch documented on
        /// the `blockContentFilledSignal` handler. Clearing explicitly on both
        /// sides of the apply covers the provider-never-ran case.
        ///
        /// Scope: VISIBLE cells only (FB13213926 discipline — every entry into
        /// the hosting graph is a crash surface, so no whole-list sweep), and
        /// only on an actual foreground/resume edge, i.e. at most once per
        /// background round-trip. Off-screen cells are re-measured when they
        /// scroll in, because their layout entry was invalidated too.
        func remeasureVisibleCells(reason: String) {
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout else { return }
            let visible = cv.indexPathsForVisibleItems
            for ip in visible {
                layout.invalidateHeight(at: ip.item)
                (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
            }
            layout.invalidateLayout()
            reconfigureVisibleCells()
            // Second clear, after the reconfigure has propagated — the mirror
            // of the `blockContentFilledSignal` handler's both-sides clear.
            for ip in cv.indexPathsForVisibleItems {
                (cv.cellForItem(at: ip) as? SelfSizingCell)?.clearCachedHeight()
            }
            AppLogger(category: "FGLayout").info(
                "[FGLayout] remeasure reason=\(reason) visibleCells=\(visible.count)")
        }
}
