//
//  CollectionViewMessageListV3.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Entry point: the UIViewControllerRepresentable the chat screen embeds, plus
//  the two Notification.Names the list listens for. Holds the SwiftUI-side
//  configuration (callbacks, insets, width) and hands everything else to the
//  Coordinator.
//
//  FILE MAP (T-messagelist-v3-split, split from one 6.8k-line file; code moved
//  verbatim, in original order):
//    CollectionViewMessageListV3.swift      representable, Section, notifications
//    Cells/
//      BridgedAssistantHeaderV3.swift       "✦ <name>" row atop an assistant turn
//      BridgedToolGroupV3.swift             folded "Ran N tools" row
//      BridgedAssistantBlockV3.swift        one assistant block (text/thinking/tool)
//                                           + its long-press menu
//      BridgedAssistantFooterV3.swift       typing / error / resume / usage footer row
//      BridgedWholeMessageV3.swift          user / divider / system-info message row
//      MessageListV3Cells.swift             per-type SelfSizingCell subclasses (reuse)
//    Support/MessageListV3HeightCache.swift HeightCacheKey + HeightLRU
//    Coordinator/
//      MessageListV3Coordinator.swift       class declaration, ALL stored properties,
//                                           deinit, ScrollMode
//      +Setup                 attach(to:vm:): data source, layout, presenters
//      +CellConfiguration     cell provider body, first-display seed, bridges
//      +BridgeUpdates         per-cell CellStateBridgeV2 refresh, footer shape
//      +Bindings              view-model subscriptions (bindViewModel)
//      +FooterHeight          footer height cache invalidation
//      +ContentLength         content-length gates for re-measure
//      +Streaming             last-message streaming subscription + flushes
//      +Snapshot              applySnapshot (diffable data source), attachments
//      +ToolFolding           tool-call folding plan, toggle, reconfigure helpers
//      +HeightMeasurement     exact text / user-bubble height precalc
//      +HeightEstimation      cache keys, estimates for unmeasured items
//      +Scroll                scroll state, jumps, bottom pin, sub-viewport inset
//      +ScrollingScreenshot   long-press turn screenshot (scroll + stitch)
//      +ScrollViewDelegate    prefetching + UIScrollViewDelegate, settle
//      +DecelDisplayLink      DEBUG CADisplayLink dropped-frame meter
//    Sheets/
//      MessageListV3SheetPresenters.swift   tool-detail / compact-summary sheet
//                                           presenters + SheetOverlayView
//      RetryLogSheet.swift                  retry marker + retry log sheet
//
//  RULES that keep the split working:
//    - New Coordinator stored properties go in MessageListV3Coordinator.swift
//      (extensions cannot hold stored state); put them under the "Stored state
//      of +<Concern>" seam of the file that uses them.
//    - Members used across files are internal (no `private`); keep a helper
//      `private` only if every caller is in its own file.
//    - The folder is a synchronized group: new files here join the Minis target
//      with no project.pbxproj edit. Swift file names must stay unique in the
//      module, hence the MessageListV3 prefixes.
//    - Tests read the whole folder (messageListV3Source() in each test).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by toggleUsage to tell the Coordinator to re-snapshot so the
    /// footer cell is inserted or removed on demand.
    static let messageListNeedsResnapshot = Notification.Name("messageListNeedsResnapshot")

    /// [T-ios-user-attach-mount-invalidate #182-followup] Posted by the send
    /// queue's drain when it mounts processed attachments onto an
    /// already-inserted user message (`chatMsg.attachments = attMetas`).
    /// `object` is the message's UUID.
    ///
    /// The mount is a +70pt-per-row in-place content change on a cell whose
    /// item identity does not move, so nothing on the normal invalidation path
    /// (reconfigure / prepareForReuse) runs. Device forensics (2026-08-08)
    /// showed the failure chain when the cell's
    /// FIRST real self-size lands inside the pre-mount window: the tile-less
    /// height (~68pt) enters `heightCache`, every later correct re-seed is
    /// rejected by `setPrecalcHeight`'s occupied-slot guard, and the
    /// width-matched cell cache + streaming-window short-circuit serve the
    /// stale height for the rest of the turn — the bubble truncates to one
    /// line with the tile seemingly detached above it. The Coordinator's
    /// handler breaks the chain with a TARGETED invalidation of that one cell.
    static let minisUserAttachmentsMounted = Notification.Name("minisUserAttachmentsMounted")
}

// MARK: - CollectionViewMessageListV3

/// V3 message list: builds on V2's cell-per-block model but simplifies
/// the scroll stability architecture:
///
/// - **Single height source**: UIKit self-sizing only (no GeometryReader)
/// - **3-tier height resolution**: measured cache → precalc (NSAttributedString) → estimate
/// - **2-state scroll model**: autoScrolling / userBrowsing (replaces V2's 6+ mechanisms)
/// - **O(1) message lookup**: UUID index rebuilt on each snapshot
struct CollectionViewMessageListV3: UIViewControllerRepresentable {
    @ObservedObject var vm: AIChatViewModel
    var inputFocused: Bool
    var onRetryMessage: ((UUID) -> Void)?
    var onRetryLast: (() -> Void)?
    /// [T-ios-assistant-header-open-soul] Tap on the assistant identity row.
    var onOpenSoulSettings: (() -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onDeleteFrom: ((UUID) -> Void)?
    var onWithdraw: ((UUID) -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    /// [T-p2-shared-workspace] Human takeover of a browser tab from a tool
    /// sheet opened in THIS list (parent or helper mirror). Pauses that vm's
    /// loop; `onTakeoverDone` resumes it.
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    var onCompact: ((UUID) -> Void)?
    var onRevertCompact: (() -> Void)?
    var onForceSync: (() -> Void)?
    /// [T-multi-select-share] "Share…" on a message: opens the share picker with
    /// the unit containing this message selected.
    var onShareMessages: ((UUID) -> Void)?
    var maxContentWidth: CGFloat
    var floatingBarHeight: CGFloat
    var inputBarHeight: CGFloat
    /// [T-scheduled-banner] Height of a banner pinned under the navigation bar
    /// that the list must start below. Only non-zero on iOS 26, where the chat
    /// content extends behind the bar (liquid glass) and so behind the banner;
    /// on earlier iOS the banner's safe-area inset already moves the list down.
    var extraTopInset: CGFloat = 0
    /// [T-send-composer-shrink-absorb] The composer's undebounced height, so
    /// rows appended right after a send can take the space a shrinking composer
    /// releases (see `ComposerShrinkAbsorption`). nil = no composer.
    var composerLiveHeight: ComposerLiveHeight? = nil

    func makeUIViewController(context: Context) -> MessageListViewController {
        let vc = MessageListViewController()
        context.coordinator.attach(to: vc, vm: vm)
        // Drops are handled exclusively by the SwiftUI `.onDrop` on the chat
        // root view. Previously a UIDropInteraction here intercepted drops on
        // top of the collection view, which (a) suppressed SwiftUI's
        // isTargeted highlight on the first drop and (b) on iPadOS 26.5 left
        // SwiftUI's drop session state half-tracked, sticking the highlight
        // on the second drag. See T-filedrop GH#12.
        return vc
    }

    func updateUIViewController(_ vc: MessageListViewController, context: Context) {
        let coord = context.coordinator
        // [T-ios-scrollbtn-vm-split] The coordinator captured `vm` once in
        // makeUIViewController → attach. SwiftUI reuses this representable's
        // platform VC (and coordinator) across AIChatView re-creations, so when
        // the ViewModelCache hands the re-created view a NEW AIChatViewModel
        // instance for the same session, the coordinator kept driving the OLD
        // one: every isNearBottom write landed on a VM nothing was observing,
        // while the overlay's VM stayed at its initial isNearBottom=true — the
        // floating ↑/↓ buttons never appeared again for the whole session
        // (device ring trace: coordinator vm read false at every sync while
        // the buttons stayed hidden at diff≈2700pt from the bottom).
        coord.rebindViewModelIfNeeded(vm)
        coord.onRetryMessage = onRetryMessage
        coord.onOpenSoulSettings = onOpenSoulSettings
        coord.onRetryLast = onRetryLast
        coord.onEdit = onEdit
        coord.onDeleteFrom = onDeleteFrom
        coord.onWithdraw = onWithdraw
        coord.onResume = onResume
        coord.onStop = onStop
        coord.sheetPresenter.onBrowserTakeover = onBrowserTakeover
        coord.sheetPresenter.onTakeoverDone = onTakeoverDone
        coord.onCompact = onCompact
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onShareMessages = onShareMessages
        coord.maxContentWidth = maxContentWidth

        // Bottom inset base = input bar + tool bar overlay height + breathing room.
        // applySubViewportCompensation is the only writer of cv.contentInset.bottom;
        // it reads coord.baseBottomInset and adds overflow on top when needed.
        //
        // [T-bottom-occluded 0a6d3c92] introduced +16 to fix a perceived
        // clip of the last bubble's bottom text. That report turned out
        // to be the cell-height bug fixed in [ClipFix 2026-05-16]
        // (boundingRect / mtv missing textContainerInset). With cell
        // heights now accurate the +16 breathing room becomes pure
        // dead space — observed as ~100pt gap between the last bubble
        // and the composer top. Restored to the historical +8.
        //
        // [T-send-composer-shrink-absorb] `inputBarHeight` is debounced. Any
        // part of a shrink the composer has already reported and appended rows
        // have already consumed is taken out here too, so a re-render between
        // the absorption and the debounce's commit does not put it back. When
        // the commit lands, `noteCommitted` clears it and the two agree.
        if coord.composerLiveHeight !== composerLiveHeight {
            coord.composerLiveHeight?.onChange = nil
            coord.composerLiveHeight = composerLiveHeight
            composerLiveHeight?.onChange = { [weak coord] in coord?.composerLiveHeightDidChange() }
        }
        coord.composerShrink.noteCommitted(inputBarHeight)
        let bottomPad: CGFloat = inputBarHeight + floatingBarHeight + 8 - coord.composerShrink.absorbed
        let baseChanged = abs(coord.baseBottomInset - bottomPad) > 0.5
        if baseChanged {
            let cv = vc.collectionView!
            let previousBase = coord.baseBottomInset
            let wasSmaller = previousBase < bottomPad
            let offsetBeforeBaseChange = cv.contentOffset.y
            // Capture follow-intent BEFORE mutating the inset: enlarging the
            // inset enlarges maxOffset, so a user pinned at the bottom would
            // measure as >20pt away from it and fail the isNearBottom() guard.
            let wasNearBottomBefore = coord.isNearBottom()
            coord.baseBottomInset = bottomPad
            // Apply the base immediately so contentInset.bottom reflects the
            // new base before applySubViewportCompensation runs (which may
            // further inflate it). Compensation will overwrite if needed.
            cv.contentInset.bottom = bottomPad
            // [T-inputbar-shrink-content-bump] Re-pin on BOTH directions, not just
            // growth.
            //
            // The old condition was `wasSmaller && …`, so only an ENLARGING inset
            // re-pinned. A shrink was left to UIKit — and UIKit's response to
            // `maxContentOffset` dropping below the current `contentOffset` is to
            // clamp it, which reads on screen as the whole conversation jerking
            // UPWARD by exactly the shrink amount, then settling back when the next
            // scroll/settle re-pins it.
            //
            // Field trace (first message + tool card): inputBarHeight went
            // 115.36 → 193.36 → 115.36 as the tool-execution card expanded and
            // collapsed. baseBottomInset therefore moved 123.36 → 201.36 → 123.36,
            // i.e. maxContentOffset fell by 78pt on the way back down. Pinned at the
            // bottom, the offset was 78pt past the new maximum and got clamped —
            // the reported "content bumps up a bit, then returns".
            //
            // Growth still needs the re-pin for the documented reason (a larger
            // inset enlarges maxOffset, so a pinned user would otherwise be left
            // 78pt short of the bottom). Shrink needs it to hide the clamp. The
            // follow-intent gate is unchanged, so a user who has scrolled away is
            // still never yanked to the bottom by a composer resize.
            if coord.scrollMode == .autoScrolling || wasNearBottomBefore {
                if !wasSmaller {
                    AppLogger(category: "ScrollDiag").info("[ScrollDiag][baseInsetShrink] \(String(format: "%.2f", previousBase))→\(String(format: "%.2f", bottomPad)) inputBar=\(String(format: "%.2f", inputBarHeight)) offset=\(String(format: "%.1f", cv.contentOffset.y)) — re-pinning to hide the UIKit clamp")
                }
                coord.scrollMode = .autoScrolling
                coord.scrollToBottomNow(animated: false)
                // [T-send-composer-shrink-absorb] A shrink no appended row
                // absorbed (composer collapsed with nothing new below it):
                // the content still has to come down to the composer, but as a
                // glide, not as a one-frame drop 380 ms after the fact.
                if !wasSmaller {
                    coord.glideContentDown(fromOffsetY: offsetBeforeBaseChange)
                }
            }
        }

        // [T-first-msg-top-gap 2026-07-18] Apply the top inset. User report
        // (iOS 16 screenshot): the first user bubble sat flush against the
        // opaque navbar — common to ALL of iOS 16-18, because
        // `baseContentInsetTop` (designed as "8pt manual padding on older
        // iOS", see its doc) was defined but never written into
        // cv.contentInset.top anywhere; the legacy nav layout doesn't extend
        // content behind the bar, so the collection view's own top edge IS
        // the navbar bottom and the first row rendered with zero breathing
        // room. iOS 26 returns 0 here (liquid-glass + .automatic adjustment
        // already position content), so this is a no-op there.
        let cvTop = vc.collectionView!
        coord.extraTopInset = extraTopInset
        if abs(cvTop.contentInset.top - coord.baseContentInsetTop) > 0.5 {
            cvTop.contentInset.top = coord.baseContentInsetTop
        }

        coord.applySubViewportCompensation(caller: "updateUIVC")

        // [T-message-list-empty-on-foreground] Backstop: if a snapshot was
        // deferred during a load (bind1) but binding 3's true→false edge was
        // missed (removeDuplicates collapse, or $isLoadingSession settling in
        // the same runloop cycle the snapshot was deferred), the list would be
        // stranded empty while the VM has messages. updateUIViewController runs
        // on every SwiftUI re-render (e.g. the toolbar updating — exactly the
        // observed "toolbar updates, list blank" symptom), so flush here once
        // loading has finished. Gated on NOT being in a streaming-suspend window
        // so we never pre-empt the suspend-resume machinery (which intentionally
        // holds hasPendingSnapshot during scroll-settle / background streaming);
        // that path has its own flush on resume. flushPendingSnapshotIfNeeded
        // no-ops when nothing is pending, so this is free on the happy path.
        if !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended {
            coord.flushPendingSnapshotIfNeeded(caller: "updateUIVC-backstop")
        }

        if inputFocused != coord.lastInputFocused {
            let wasNearBottom = coord.scrollMode == .autoScrolling && coord.isNearBottom()
            coord.lastInputFocused = inputFocused
            if wasNearBottom {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak coord] in
                    coord?.scrollToBottomNow(animated: true)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    enum Section { case main }
}
