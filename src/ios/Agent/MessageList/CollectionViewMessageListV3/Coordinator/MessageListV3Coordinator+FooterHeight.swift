//
//  MessageListV3Coordinator+FooterHeight.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Targeted invalidation of footer height caches for visible footers.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +FooterHeight" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Footer spacing policy

        /// [T-ios-footer-hug] Whether a footer shows prominent content (error
        /// banner, resume banner, typing indicator) and so keeps the full
        /// itemSpacing above it, instead of hugging the block above like the
        /// quiet meta/usage row. Mirrors BridgedAssistantFooterV3's sections.
        ///
        /// [T-interrupt-banner-gap] One function for both callers: the snapshot
        /// seed loop and `updateBridge` (via `refreshFooterHug`).
        func isFooterProminent(_ footerMsgId: UUID, footerMessage footerMsg: ChatMessage?,
                               messages: [ChatMessage], vm: AIChatViewModel) -> Bool {
            let isLastMsg = messages.last?.id == footerMsgId
            let hasError = footerMsg?.error != nil
            let showsResume = isLastMsg && !hasError
                && vm.canResume && !vm.isProcessing
            // [T-ios-first-block-footer-gap] `isActive` must mirror
            // the VIEW's typing-indicator condition VERBATIM, which
            // is `bridge.isActiveMessage && !hasVisibleContent`.
            // The `hasVisibleContent` half was missing here, so this
            // seed said "prominent" (48pt) for the whole turn while
            // `BridgedAssistantFooterV3` had already stopped drawing
            // the indicator the moment the first block appeared.
            //
            // That mismatch is why invalidating the footer was not
            // enough: the log shows `[footer-collapse] … invalidated`
            // immediately followed by `[footer] seeded=48
            // prominent=true` in the SAME pass — the seed re-applied
            // the stale 48pt a few lines later, so the frame never
            // actually shrank and `stale-height held=48 needs=22`
            // kept firing.
            //
            // [T-ios-typing-indicator-scope] Same single source of
            // truth the view uses, so the seeded height and the
            // rendered row can never disagree.
            //
            // [T-queued-candidate-spacing] "Active" is the live
            // tail, like the bridge: with a queued candidate
            // below, `isLastMsg` is false for the reply in
            // progress, so its "is thinking…" row was seeded as a
            // quiet footer and glued to the tool row above it.
            let isLiveTail = Self.liveTailMessage(in: messages)?.id == footerMsgId
            let isActive = isLiveTail && vm.isProcessing
                && (footerMsg?.shouldShowTypingIndicator ?? false)
            return hasError || showsResume || isActive
        }

        /// [T-interrupt-banner-gap] Re-apply the hug policy for one footer
        /// outside a snapshot apply.
        ///
        /// The policy used to be written only by the snapshot seed loop. Stop
        /// sets `canResume` AFTER the last apply of the turn (which, with the
        /// item list unchanged, is skipped anyway), so the resume banner kept
        /// the "quiet footer" policy and sat glued to the row above (~2pt gap
        /// instead of the 8pt itemSpacing) until the session was reopened and
        /// a fresh apply re-evaluated it.
        func refreshFooterHug(messageId: UUID, message: ChatMessage, in messages: [ChatMessage]) {
            guard let vm,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource,
                  let idx = ds.snapshot().itemIdentifiers.firstIndex(of: .assistantFooter(messageId))
            else { return }
            let prominent = isFooterProminent(messageId, footerMessage: message, messages: messages, vm: vm)
            guard layout.setFooterHug(!prominent, at: idx) else { return }
            layout.invalidateLayout()
            AppLogger(category: "BottomGapDiag").info(
                "[BottomGapDiag][footer-hug] msg=\(messageId.uuidString.prefix(8)) idx=\(idx) "
                + "prominent=\(prominent) — spacing policy refreshed outside a snapshot apply")
        }

        // MARK: - Footer height invalidation

        /// [T-ios-plaf-cache-footer-staleness] Drop the cached height of every
        /// VISIBLE assistant-footer cell, both cell-side and layout-side.
        ///
        /// Needed because the footer's height is driven by `@Published` state on
        /// `CellStateBridgeV2` (`showUsage`, `isActiveMessage`, `canResume`,
        /// the auto-retry fields) rather than by the message content that forms
        /// the diffable item identity. Those flips re-render the SwiftUI body
        /// in place without changing the snapshot, so nothing on the normal
        /// invalidation path (applyContentConfiguration / prepareForReuse) ever
        /// runs and `SelfSizingCell`'s now-unbounded height cache goes stale.
        ///
        /// Deliberately scoped to `visibleCells`: an off-screen footer will be
        /// configured from scratch when it scrolls back in (cell provider →
        /// applyContentConfiguration), so it needs nothing here.
        ///
        /// `messageId == nil` invalidates every visible footer; passing an id
        /// narrows it to that message's footer.
        func invalidateFooterHeightCaches(messageId: UUID? = nil) {
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else { return }
            let items = ds.snapshot().itemIdentifiers
            for (i, item) in items.enumerated() {
                guard case .assistantFooter(let mid) = item else { continue }
                if let messageId, mid != messageId { continue }
                let ip = IndexPath(item: i, section: 0)
                let cellForFooter = cv.cellForItem(at: ip) as? SelfSizingCell

                // [T-ios-footer-extra-gap] DEFENSIVE, not a root-cause fix.
                //
                // `invalidateHeight` needs no cell, so it should not sit behind
                // the cell lookup — the old `guard let cell … else { continue }`
                // skipped the layout-side invalidate whenever the footer was not
                // currently realised. Field logs (2026-08-10 09:30:06, idx=179)
                // confirm that branch does fire, though in that instance nothing
                // was cached and the skip was harmless.
                //
                // Kept separate deliberately: the cell clear still requires a
                // cell, the layout invalidate no longer does. This closes the
                // asymmetry without claiming it explains the reported gap.
                cellForFooter?.clearCachedHeight()
                layout.invalidateHeight(at: i)
            }
        }
}
