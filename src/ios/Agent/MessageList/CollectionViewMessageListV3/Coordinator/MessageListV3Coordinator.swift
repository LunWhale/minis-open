//
//  MessageListV3Coordinator.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  The Coordinator class: callbacks, ScrollMode, every stored property (in
//  original declaration order, so the object layout is unchanged), and deinit.
//  All behaviour lives in the MessageListV3Coordinator+<Concern>.swift
//  extensions next to this file.
//
//  Seams: "// MARK: Stored state of +<Concern>  [split seam]" groups the
//  properties that used to sit inside that concern's section. Properties above
//  the first seam were the class prelude and are shared by several concerns.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - V3 Coordinator

extension CollectionViewMessageListV3 {

    /// Scroll mode: the only two states V3 needs.
    enum ScrollMode {
        /// Content growth pins offset to bottom. Self-sizing accepted normally.
        case autoScrolling
        /// User is reading above the bottom. Layout changes preserve offset.
        case userBrowsing
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UIScrollViewDelegate, UICollectionViewDataSourcePrefetching {
        // Callbacks
        var onRetryMessage: ((UUID) -> Void)?
        var onOpenSoulSettings: (() -> Void)?
        var onRetryLast: (() -> Void)?
        var onEdit: ((UUID) -> Void)?
        var onDeleteFrom: ((UUID) -> Void)?
        var onWithdraw: ((UUID) -> Void)?
        var onResume: (() -> Void)?
        var onStop: (() -> Void)?
        var onCompact: ((UUID) -> Void)?
        var onRevertCompact: (() -> Void)?
        var onForceSync: (() -> Void)?
        var onShareMessages: ((UUID) -> Void)?
        var maxContentWidth: CGFloat = 0
        var lastInputFocused: Bool = false

        #if DEBUG
        deinit {
            // [DecelDisplayLink] CADisplayLink retains its target — must
            // invalidate on Coordinator teardown to break the cycle.
            decelDisplayLink?.invalidate()
        }
        #endif

        // === Scroll mode (replaces V2's 6+ mechanisms) ===
        var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // Mirror to the layout so its invalidationContext can glue the
                // streaming cell's bottom to the viewport while pinned (smooth
                // grow) and skip that adjustment while the user browses.
                // [T-ios-stream-natural-transitions]
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
                // [T-ios-wheel-scroll-pin-fight] Re-seed the indirect-scroll
                // baseline whenever the mode changes. Entering `.autoScrolling`
                // is always followed by a jump to the bottom (button, first
                // load, new turn), and that jump's first `scrollViewDidScroll`
                // would otherwise be compared against a stale offset from
                // wherever the user had browsed to — a large apparent upward
                // move that would immediately bounce the mode back out.
                // Seeding at the single choke point covers every jump site.
                if let cv = viewController?.collectionView {
                    lastDidScrollOffsetY = cv.contentOffset.y
                }
                // [T-fold-consecutive-tools] Back at the bottom: fold the runs
                // that were held back while the user was reading above them.
                if scrollMode == .autoScrolling, oldValue != .autoScrolling, toolFoldDeferred {
                    DispatchQueue.main.async { [weak self] in
                        self?.resnapshotIfToolFoldsChanged(caller: "toolFold-backToBottom")
                    }
                }
            }
        }
        /// True during settleAfterInteraction flush — suppresses contentSize KVO offset changes.
        var isFlushing = false
        /// True while an animated setContentOffset is in flight. KVO grow events must not
        /// directly mutate contentOffset during this window — UIKit animation interpolation
        /// can produce a corrupted final offset. Instead, defer via scheduleCoalescedScroll().
        var isAnimatingScrollToBottom = false

        // === O(1) Lookup Indices ===
        var messageIndex: [UUID: Int] = [:]
        var itemToIndex: [MessageListItem: Int] = [:]

        // === Snapshot State ===
        var previousSnapshotIds: [MessageListItem] = []

        /// [T-ios-first-block-footer-gap] Per-message block count as of the last
        /// applied snapshot, used to detect the 0 -> >=1 edge that collapses the
        /// footer. Tracked in the DATA layer on purpose: the first attempt hung
        /// this off `blockContentFilledSignal`, which only fires for TEXT blocks
        /// going empty -> non-empty. A tool block is created already populated
        /// and never takes that path, so the footer was not invalidated until
        /// some later text block happened to stream — long after the gap was on
        /// screen. Counting blocks covers every kind (tool, thinking, text).
        var lastBlockCountByMessage: [UUID: Int] = [:]

        /// [T-ios-first-block-footer-gap] Footer shape as of the previous
        /// `updateBridge` call, per message. Needed because the shape now
        /// includes fields read from `ChatMessage`, which this function does not
        /// mutate — the transition to detect happens between calls, not within
        /// one. Pruned alongside `cellBridges`.
        var lastFooterShapeByMessage: [UUID: FooterHeightShape] = [:]
        var snapshotMessages: [ChatMessage] = []

        // === Bridges ===
        var cellBridges: [UUID: CellStateBridgeV2] = [:]

        // === Height Measurement Cache ===
        /// [T-ios-listsessions-perf] Caches measureAttributedStringHeight
        /// results by CONTENT, in an LRU that survives session change.
        ///
        /// This used to be `[ObjectIdentifier: CGFloat]` keyed on the identity
        /// of the NSAttributedString. That made every re-render a guaranteed
        /// miss even when the text was byte-identical — a streaming block
        /// finalizing, a re-parse after compaction and a session reload all
        /// mint a new attributed string object — and the cache was cleared
        /// outright on session change. The result was the 0.42-0.73 s
        /// main-thread hangs the CPU Profiler trace recorded on applySnapshot
        /// (4 of them), where a page of long assistant blocks was measured
        /// from cold through the near-O(n^2) `sizeThatFits` path.
        ///
        /// Keyed and bounded per `HeightCacheKey` / `HeightLRU` below.
        var attrStringHeightCache = HeightLRU(capacity: 300)

        /// [T-ios-listsessions-perf] Per-applySnapshot instrumentation for the
        /// height cache. Counted in every build (the arithmetic is three
        /// increments) but only LOGGED in DEBUG — the on-device pass reads
        /// these numbers to confirm or refute the hit-rate assumption that
        /// motivated the content-keyed cache.
        var heightCacheHits = 0
        var heightCacheMisses = 0
        var heightMeasureSeconds: CFAbsoluteTime = 0
        let heightCacheLogger = AppLogger(category: "HeightCache")
        /// [T-ios-user-msg-estimate-tail-jitter] Caches accurate user-bubble
        /// heights keyed by "content|width|fontsize" (user text has no
        /// cachedAttributedString identity to key on).
        ///
        /// Still cleared on session change / font change, unlike
        /// attrStringHeightCache: this one is a plain unbounded dictionary, so
        /// clearing is what bounds it. [T-ios-listsessions-perf] gave the
        /// assistant-side cache an LRU and a font-aware key so it could stop
        /// being cleared; the same could be done here if user bubbles ever show
        /// up in a profile, but they measure with a cheap UILabel rather than
        /// the near-O(n^2) sizeThatFits path, so there is no evidence it matters.
        var userBubbleHeightCache: [String: CGFloat] = [:]

        /// [T-ios-earlier-stream-seed-freeze] Memo for
        /// `liveAssistantIds(in:isProcessing:)`. `configureCell` runs per cell
        /// and the underlying rule walks every message's blocks, so without
        /// this the seed path would go O(cells x messages x blocks) on exactly
        /// the busiest frames (mid-stream, many visible cells). Keyed by the
        /// cheap (identity of last message, message count, isProcessing) tuple
        /// — every transition that can change the answer moves at least one of
        /// them, because a message becoming/ceasing to be live is always
        /// accompanied by `isProcessing` flipping or the block set changing
        /// within the same streaming generation, which `streamGeneration`
        /// tracks.
        var liveIdsMemo: (key: String, ids: Set<UUID>)?

        /// Bumped whenever block content/status changes in a way that can flip
        /// which messages are live, so `liveIdsMemo` recomputes.
        var streamGeneration: Int = 0

        // === Thinking Block Toggle ===
        var thinkingToggleSub: AnyCancellable?

        /// The runs folded in the last applied snapshot, per message.
        var toolFoldRunsByMessage: [UUID: [ToolFoldRun]] = [:]
        /// Same runs, by first block id — what a `.toolGroup` item carries.
        var toolFoldRunByFirstBlock: [UUID: ToolFoldRun] = [:]
        /// Keys of the runs the user opened. In memory only: reopening the
        /// session shows every run folded again.
        var expandedToolGroups: Set<String> = []
        /// Keys of runs that have been shown folded at least once. Once a run
        /// is folded it stays folded; only a run's FIRST fold may be held back.
        var presentedToolGroupKeys: Set<String> = []
        /// [T-fold-tool-notes] `.toolGroup` rows whose run changed in the latest
        /// plan while keeping their identity; reconfigured on the next apply.
        var changedToolGroupItems: [MessageListItem] = []
        /// True when the last plan held back a run (see `planToolFolds`), so
        /// the next return to the bottom / end of the turn re-plans.
        var toolFoldDeferred = false
        /// The session the two sets above belong to.
        var toolFoldSessionId: String?
        var toolGroupToggleSub: AnyCancellable?

        // === Attachment mount invalidation ===
        // [T-ios-user-attach-mount-invalidate] Drain mounts attachments onto an
        // already-inserted user message; see .minisUserAttachmentsMounted.
        var attachMountSub: AnyCancellable?

        // === Async attachment size invalidate ===
        // [T-attachment-size-invalidate 2026-05-21] Image / video / thumbnail
        // async loads cause cell SwiftUI body to grow from placeholder to fit
        // size, but SelfSizingCell's broad-width cache short-circuits
        // preferredLayoutAttributesFitting so the cell never re-measures —
        // bottom of content gets clipped until the chat is re-entered.
        var attachmentSizeChangedSub: AnyCancellable?
        /// [T-ios-image-squish-probe §2] Same-runloop-tick coalescing for
        /// `.minisAttachmentSizeChanged` bursts (a six-image message fires up
        /// to 12: header probe + decode completion per image). The handler is
        /// a full-list invalidate + reconfigure, so one pass per tick is the
        /// budget.
        var attachmentSizeRefreshScheduled = false
        var pendingAttachmentSizeUrls: [String] = []

        // === Foreground/Background Content Tracking ===
        /// Total character count of the last assistant message's blocks when the app entered background.
        /// Used to decide whether layout invalidation is needed on foreground return.
        var contentLengthAtBackground: Int?

        // === Streaming ===
        var lastMessageId: UUID?
        var lastMessageSub: AnyCancellable?
        var lastMessageBlockCountSub: AnyCancellable?

        /// [T-ios-ui-blocks-lost-suspend-resume] Last observed value of the vm's
        /// `streamingUIUpdatesSuspended`, tracked so the vm-state subscription can
        /// detect a true→false transition and flush a snapshot deferred during the
        /// suspend window (see `suspendResumeSub`).
        var lastSuspendedValue: Bool = false
        /// [T-ios-ui-blocks-lost-suspend-resume] Watches the vm for the moment
        /// `streamingUIUpdatesSuspended` clears, then flushes the pending snapshot.
        var suspendResumeSub: AnyCancellable?

        /// Adaptive streaming throttle: last time flushStreamingLayout actually ran.
        var lastStreamingLayoutTime: Date = .distantPast
        /// Trailing-edge work item so the final streaming update isn't lost.
        var pendingStreamingLayout: DispatchWorkItem?


        /// Scroll coalescing: batches rapid scroll signals into one 80ms action.
        var pendingScrollWork: DispatchWorkItem?

        // === Session Load ===
        /// When true, contentSize KVO keeps pinning to bottom until layout stabilizes.
        var clampAfterSessionLoad: Bool = false
        /// Hard deadline to stop clamping (2s after session load).
        var clampDeadline: Date = .distantPast

        // === Sheet Presenters ===
        let sheetPresenter = ToolSheetPresenter()
        let compactSummaryPresenter = CompactSummaryPresenter()
        var sheetOverlayHost: UIHostingController<SheetOverlayView>?

        // === References ===
        weak var viewController: MessageListViewController?
        weak var vm: AIChatViewModel?
        var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!
        var subscriptions = Set<AnyCancellable>()
        var contentSizeObservation: NSKeyValueObservation?

        // MARK: Stored state of +CellConfiguration  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+CellConfiguration.swift.

        let screenshotLogger = AppLogger(category: "TurnScreenshot")
        /// [T-ios-copy-screenshot-diag-logs] Verbose stage-by-stage trace of
        /// captureScrollingTurnScreenshot used to chase the "top blank when
        /// long-press from middle/bottom" symptom that the first repair
        /// (5e3c6160) didn't fully eliminate. Separate category from
        /// TurnScreenshot so users can `grep ChatScreenshot` cleanly to
        /// pull just the diagnostic frames without the noisier turn-level
        /// summary lines.
        let chatScreenshotLogger = AppLogger(category: "ChatScreenshot")
        /// Counts cells configured since last applySnapshot to detect first-cell timing.
        var cellConfigCount: Int = 0
        var firstCellConfigTime: CFAbsoluteTime = 0

        /// Subscriptions for bridge detailBlock → sheet presenter forwarding.
        var bridgeSheetSubs: [UUID: AnyCancellable] = [:]

        // MARK: Stored state of +Snapshot  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+Snapshot.swift.

        /// When a snapshot is deferred (e.g. streaming UI updates suspended),
        /// set to true so we know to re-apply later.
        var hasPendingSnapshot: Bool = false

        // MARK: Stored state of +HeightEstimation  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+HeightEstimation.swift.

        /// [T-scroll-estimate-fidelity] Content-hash key of a row for the
        /// cross-load height memo, or nil for rows it does not cover. Only rows
        /// whose height follows from their content alone: user messages
        /// (text + attachment count), text blocks, thinking blocks (with their
        /// expanded state). Tool cards and footers also depend on runtime state.
        /// The hash is cached per row and redone only when the length changes,
        /// so a streaming block does not rehash on every snapshot.
        var stableHeightKeyCache: [MessageListItem: (signature: Int, key: String)] = [:]

        // MARK: Stored state of +Scroll  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+Scroll.swift.

        let nearBottomThreshold: CGFloat = 20

        /// Tighter threshold for *re-acquiring* `.autoScrolling` after a
        /// deliberate user interaction settles. `nearBottomThreshold` (20pt)
        /// is right for *maintaining* the bottom-pin during streaming, but
        /// reusing it to re-arm auto-scroll caused trackpad jitter on iPad:
        /// a tiny two-finger scroll up leaves the offset well within 20pt of
        /// the bottom, so settle flipped straight back to `.autoScrolling`,
        /// the contentSize KVO re-pinned to the bottom, and that fought the
        /// next small scroll — the scrollbar darted up and down. Requiring the
        /// content to be essentially flush with the bottom (≤4pt) means a
        /// deliberate small scroll stays in `.userBrowsing`, while a scroll
        /// that genuinely lands at the bottom still resumes follow-along.
        /// [T-ios-trackpad-scroll-jitter]
        let reacquireAutoScrollThreshold: CGFloat = 4

        /// [T-ios-wheel-scroll-pin-fight] How far the offset must move UP in one
        /// callback before it counts as the user scrolling away from the bottom.
        ///
        /// Sized to sit above self-sizing noise and below one wheel notch: cells
        /// at the bottom re-measure by roughly +/-1-5pt while TextKit lays out,
        /// images load and tables reflow, and treating that as intent would drop
        /// auto-follow mid-stream. A wheel notch or trackpad flick moves far more.
        let indirectScrollExitThreshold: CGFloat = 10

        /// Previous `scrollViewDidScroll` offset, for the comparison above.
        /// Seeded on every mode change and programmatic jump so the first
        /// callback after one cannot read as a large upward move.
        var lastDidScrollOffsetY: CGFloat = 0

        /// The user-message id the up-button last jumped to, so a repeated tap
        /// walks one turn further back. Reset (nil) whenever the anchoring
        /// context changes — manual drag, jump-to-bottom, snapshot change, or
        /// session load — so the next tap re-anchors to the current viewport
        /// instead of continuing from a stale turn.
        var lastJumpedUserId: UUID?

        /// [T-scheduled-banner] See `CollectionViewMessageListV3.extraTopInset`.
        var extraTopInset: CGFloat = 0

        /// Base contentInset.bottom = inputBarHeight + floatingBarHeight + 8.
        /// Set by updateUIViewController; the actual cv.contentInset.bottom
        /// equals this plus the current sub-viewport compensation (if any).
        /// `applySubViewportCompensation` is the only place that writes
        /// contentInset.bottom — it reads this base and adds overflow.
        var baseBottomInset: CGFloat = 0

        // MARK: Stored state of the composer-shrink absorption  [T-send-composer-shrink-absorb]
        /// See `ComposerShrinkAbsorption`. `baseBottomInset` already has
        /// `composerShrink.absorbed` taken out of it.
        var composerShrink = ComposerShrinkAbsorption()
        /// The composer's height as layout last reported it (not debounced).
        /// nil for lists with no composer (the sub agent transcript).
        var composerLiveHeight: ComposerLiveHeight?
        /// Absorption only runs for a short while after the user sent a message
        /// (or asked to follow the bottom): that is when the composer shrinks
        /// AND rows are appended. Outside it the debounced height alone drives
        /// the inset, as before, so a one-frame composer height glitch while a
        /// reply streams cannot reach the list.
        var composerShrinkAbsorbDeadline: CFAbsoluteTime = 0

        // MARK: Stored state of +Search  [split seam]
        // [T-in-chat-search] True while the search bar is open. The composer
        // and the tool preview are hidden then, so the bottom inset they
        // reserve (`baseBottomInset`) is given back to the list - with the
        // keyboard up that space is most of what is left on screen.
        var searchHidesComposer = false
        var searchActiveSub: AnyCancellable?

        // MARK: Stored state of +DecelDisplayLink  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+DecelDisplayLink.swift.

        #if DEBUG
        var decelDisplayLink: CADisplayLink?
        var decelDLLastTimestamp: CFTimeInterval = 0
        var decelDLFrames: Int = 0
        var decelDLDrops: Int = 0
        var decelDLMinGapMs: Double = .infinity
        var decelDLMaxGapMs: Double = 0
        var decelDLExpectedMs: Double = 16.67

        #endif

        // MARK: Stored state of +ScrollViewDelegate  [split seam]
        // Declared here because extensions cannot hold stored properties. The
        // code these sat next to is in MessageListV3Coordinator+ScrollViewDelegate.swift.

        /// Track last logged offset to detect jumps after settle.
        var lastLoggedOffset: CGFloat = 0
        var settleJustFinished = false

        var scrollSamples = 0
        var lastScrollFlushOffset: CGFloat = 0
        var lastScrollFlush: CFTimeInterval = 0

        // [ScrollDecel] Deceleration-phase instrumentation. Lets us pin a
        // dropped frame to "Xms into the decel, at offset Y" so the
        // scroll-jank trace's micro-hangs can be aligned to the exact moment
        // and content region where the costly render started.
        var decelStartTime: CFTimeInterval = 0
        var decelStartOffset: CGFloat = 0
        var decelTargetOffset: CGFloat = 0
        var decelLastFrameTime: CFTimeInterval = 0
        var decelFrameCount = 0
        var decelSlowFrameCount = 0
        /// A frame gap above this (seconds) during deceleration is a dropped
        /// frame worth logging. ~32ms ≈ two missed frames at 60Hz / several at
        /// 120Hz — low enough to catch the jitter, high enough to stay quiet
        /// on smooth scrolls.
        let decelSlowFrameThreshold: CFTimeInterval = 0.032

    }
}
