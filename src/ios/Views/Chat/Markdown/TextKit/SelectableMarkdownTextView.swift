//
//  SelectableMarkdownTextView.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - the UITextView that displays a rendered message.
//
//  Non-editable, selectable UITextView over MinisLayoutManager. It shows the
//  renderer's attributed string, overlays a real UIView on every attachment
//  (+AttachmentViews), owns selection and the edit menu, and keeps the host
//  collection-view cell's height in step with its content (+CellSizing).
//
//  SelectableMarkdownTextView is split across these files:
//
//    SelectableMarkdownTextView.swift  core: stored state, init, first
//        responder and selection tracking, inline-code tap, gesture
//        arbitration with the list and code blocks
//    +EditMenu            edit-menu actions (copy variants, share, add to
//                         input, read aloud) and buildMenu
//    +SelectionDismissal  tap-outside clears the selection; Shift+click
//    +AttachmentViews     creates, positions and recycles the UIViews that
//                         draw attachments; recovery after reuse
//    +Layout              layoutSubviews and width-change handling
//    +CellSizing          tells the host collection-view cell to re-measure
//                         when content height changes
//    +BlockquoteBars      draws blockquote bars in draw(_:)
//
//  Extensions cannot hold stored properties, so every stored property is
//  declared in the core file - including the ones only an extension uses.
//
//  Upward edge: the text view reaches the bridge through
//  `delegate as? SelectableMarkdownView.Coordinator` (renderer, message id).
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - SelectableMarkdownTextView

/// Non-editable, selectable UITextView subclass for rendering Markdown as NSAttributedString.
final class SelectableMarkdownTextView: UITextView, UIGestureRecognizerDelegate {
    var attachmentViews: [UIView] = []
    /// Returns true if the text storage contains NSTextAttachment objects but no attachment views
    /// have been created yet. Used by updateUIView to detect the LazyVStack reappear case where
    /// the async updateAttachmentViews call was dropped because window was nil at the time.
    var hasUnrenderedAttachments: Bool {
        guard attachmentViews.isEmpty,
              let storage = textStorage as? NSTextStorage else { return false }
        var found = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
    /// Whether a same-markdown attachment recovery has already been scheduled/performed
    /// for the current attributedText snapshot. Prevents repeated recovery storms while
    /// LazyVStack / SwiftUI is still settling.
    var hasScheduledRecoveryForCurrentContent = false

    /// Invoked when the user picks "Share…" from the text selection menu.
    /// Set by the SwiftUI layer so the menu item can reach the owning turn.
    var onShareMessages: (() -> Void)?

    /// Coalesce guard for math-attachment `onLoad` refreshes. With hundreds of
    /// formulas each completing asynchronously, scheduling a full
    /// `refreshAttachmentViews()` per callback multiplies the cost N×; instead
    /// we set this flag, dispatch one refresh, and clear it on arrival.
    private var pendingMathRefresh = false

    /// Schedule at most one `refreshAttachmentViews()` per runloop tick from
    /// math-attachment `onLoad` callbacks. Safe to call any number of times.
    func scheduleCoalescedMathRefresh() {
        guard !pendingMathRefresh else { return }
        pendingMathRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingMathRefresh = false
            self.refreshAttachmentViews()
        }
    }

    /// Reset whenever attributedText content changes, so a future same-markdown reappear
    /// may recover once if attachments are missing/incomplete.
    func resetAttachmentRecoveryState() {
        hasScheduledRecoveryForCurrentContent = false
    }

    /// [T-ios-math-invisible-dark-mode] Re-render formula bitmaps when the
    /// light/dark style flips.
    ///
    /// Math images bake in a concrete text color, so they are style-specific
    /// (`SwiftMathRenderer.interfaceStyle` explains why they cannot stay
    /// dynamic). Text, code and table attachments all keep resolving their
    /// colors normally through UIKit; only the rasterised formulas are stuck,
    /// so this drops just those and lets the existing coalesced refresh redraw
    /// them.
    ///
    /// `hasDifferentColorAppearance` rather than a raw style comparison: it is
    /// the check UIKit intends here, and it filters out the many trait changes
    /// (size class, dynamic type, layout direction) that must NOT trigger a
    /// re-render storm across every formula on screen.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection),
              let storage = textStorage as? NSTextStorage else { return }
        var invalidated = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if let math = value as? MathAttachment {
                math.invalidateRenderForInterfaceStyleChange()
                invalidated += 1
            }
        }
        guard invalidated > 0 else { return }
        AppLogger(category: "MathSync").info("[MathSync] interface style changed — re-rendering \(invalidated) formula(s)")
        scheduleCoalescedMathRefresh()
    }

    var needsAttachmentRecovery: Bool {
        guard let storage = textStorage as? NSTextStorage else { return false }

        var expected = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
            if value != nil { expected += 1 }
        }

        guard expected > 0 else { return false }

        if attachmentViews.count != expected {
            return true
        }

        if attachmentViews.contains(where: { $0.superview !== self }) {
            return true
        }

        return false
    }

    /// Maps attachment identity (ObjectIdentifier) to its current UIView, for reuse during streaming.
    var attachmentViewMap: [ObjectIdentifier: UIView] = [:]

    /// Fingerprint of the last successful updateAttachmentViews invocation.
    /// Tuple = (textStorage.length, textContainer.size.width, attachmentViewMap.count).
    /// When the next call sees the same fingerprint AND every attachment in
    /// storage is already in attachmentViewMap, we can skip the full
    /// enumeration — there's nothing to do. This eliminates the redundant
    /// 2nd/3rd UAV call SwiftUI's UIHostingConfiguration triggers per BIG-CELL
    /// onscreen (window=nil → window-set → layoutSubviews chain).
    var lastUAVStorageLen: Int = -1
    var lastUAVWidth: CGFloat = -1
    var lastUAVViewCount: Int = -1
    /// [TableDedupBug] Tracks the sum of all TableAttachments' contentGeneration
    /// at the moment of the last successful `updateAttachmentViews` pass.
    /// Without this term the per-token streaming attachment mutations (which
    /// preserve textStorage length) defeat the (storageLen+width+viewCount)
    /// fingerprint and the table view never gets re-rendered with the new
    /// rows. See the entry-block dedup in `updateAttachmentViews` for the
    /// matching consumer.
    var lastUAVTableGenSum: UInt64 = 0
    /// Maps code block sequential index to its current UIView, for reuse when content changes
    /// (new attachment object but same visual position). Allows `updateExistingView` instead of full rebuild.
    var codeBlockViewCache: [Int: UIView] = [:]
    /// Tracks the last textContainer width used for layout, to detect rotation/size changes.
    var lastLayoutWidth: CGFloat = 0
    /// Tracks the last computed intrinsic content height to detect when height changes
    /// and the parent collection view cell needs to re-self-size.
    var lastComputedHeight: CGFloat = 0

    /// Fingerprint inputs that produced `lastComputedHeight`. Used by
    /// `invalidateCellSizeIfNeeded` to skip the costly sizeThatFits + collection
    /// view layout invalidation when nothing observable changed since the last
    /// measurement. Refreshed after a successful sizeThatFits.
    /// [T-ios-refresh-teardown-guard] Content fingerprint of the last
    /// `performRefreshAttachmentViews` pass. When the next async media-load
    /// callback arrives with the SAME storage length and width, the content did
    /// not change — only an attachment's intrinsic size did — so the views can
    /// be repositioned in place instead of destroyed and rebuilt.
    var lastRefreshStorageLen: Int = -1
    var lastRefreshWidth: CGFloat = -1

    var lastSizedStorageLen: Int = -1
    var lastSizedWidth: CGFloat = -1
    /// Sum of every TableAttachment's `contentGeneration` at the moment of
    /// the last successful sizeThatFits. Streaming tables mutate their rows
    /// in place without changing textStorage.length, so without this extra
    /// term the `(storageLen, width)` dedup fingerprint would falsely report
    /// "unchanged" and the cell would never re-measure — visible to the
    /// user as the table rendering only its first column / first row(s)
    /// even though the markdown source already contains the full table.
    var lastSizedTableGenSum: UInt64 = 0
    /// Raw markdown source for "Copy Markdown" action.
    var rawMarkdown: String = ""

    // MARK: Attachment-layout re-entry guards (defensive — image-attachment hang)
    /// Set while `refreshAttachmentViews` is executing. Same-runloop re-entry
    /// (e.g. `beginLoadingIfNeeded` synchronously firing `onLoad` from the
    /// `NativeMediaImageCache` hit path) would otherwise recurse into itself.
    var isRefreshingAttachments = false
    /// Set while `invalidateCellSizeIfNeeded` is executing. The collection-view
    /// `invalidateLayout()` it triggers can synchronously re-enter
    /// `preferredLayoutAttributesFitting` → `sizeThatFits` → `invalidateCellSizeIfNeeded`.
    var isInvalidatingCellSize = false
    /// [T-ios-lastcell-clip-defer-lost] Armed when a REAL height change was
    /// detected during a deferSelfSizing window and the correction had to be
    /// skipped. Guarantees one post-settle retry of invalidateCellSizeIfNeeded
    /// even if no further UAV/measure call arrives after the glide ends.
    var pendingDeferredRemeasure = false
    /// [T-ios-defer-retry-never-consumed] Set alongside `pendingDeferredRemeasure`
    /// when a correction is skipped inside a deferSelfSizing window. Two jobs:
    ///
    ///  1. It lets the retry BYPASS the `[SKIP-DEDUPE]` fingerprint early-exit.
    ///     The skip path deliberately does not consume the measurement, on the
    ///     assumption (see the comment there) that "token growth mutates storage
    ///     length, which already defeats the fingerprint". That holds only WHILE
    ///     the stream is running. In the field repro the skip landed 43ms before
    ///     `isProcessing=false`, so the storage stopped changing, the fingerprint
    ///     matched forever, and every retry early-exited before re-measuring —
    ///     the correction was lost for good (log evidence: 128 `SKIP-DEDUPE`
    ///     lines in the session, zero after the skip).
    ///  2. It is consumed by `consumeDeferredCorrectionIfNeeded()`, which the
    ///     Coordinator calls the moment `deferSelfSizing` is actually cleared at
    ///     settle — instead of guessing with a fixed 0.6s timer that can (and
    ///     did) fire while the user is still dragging, landing straight back in
    ///     the same skip branch.
    var deferredCorrectionPending = false
    /// Records the last time the layout loop tripped the re-entry guard, for
    /// watchdog diagnostics. If this fires many times per second we know the
    /// loop is hot even if we successfully short-circuit it.
    var reentryGuardHits: Int = 0

    /// Set when `refreshAttachmentViews` was dropped because the view was
    /// detached from window (`window == nil`). Replayed from
    /// `didMoveToWindow` once the view is re-attached so an async image load
    /// that completed while off-screen still gets its cell-size grow.
    ///
    /// Background: when an assistant message contains multiple inline images
    /// that load asynchronously, the LAST image's `onLoad` callback can
    /// arrive after the cell has been briefly recycled out of window (scroll
    /// off-screen, then user immediately scrolls back). With the
    /// `window != nil` guard at the top of `refreshAttachmentViews` the
    /// refresh is silently dropped, leaving the cell sized to the last
    /// known attachment bounds (where the final image was still a 200pt
    /// placeholder). Scrolling back never re-triggers the refresh, so the
    /// last image renders clipped or empty until the user exits + re-enters
    /// the chat. (T-multi-image-last d8a51f73.)
    var pendingRefreshAfterWindowAttach = false

    /// [T-ios-reuse-cachewipe] Method B burst-coalescing state — see
    /// `refreshAttachmentViews()`. `isCoalescingRefresh` is set while a
    /// commit is already scheduled for the next runloop turn;
    /// `coalescedRefreshPending` records that more async completions landed
    /// during that window (used only to log that a burst was absorbed).
    var isCoalescingRefresh = false
    var coalescedRefreshPending = false

    init() {
        // Use TextKit 1 for reliable NSLayoutManager overrides
        let textStorage = NSTextStorage()
        let layoutManager = MinisLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: textContainer)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        // [T-ios-datadetector-hardening] State the detector policy instead of
        // inheriting it. This matches TerminalTextView / LogTextView /
        // MinisTextView, which already set it explicitly.
        //
        // DEFENSIVE ONLY — this does NOT fix the DataDetectorsUI/Calculate
        // watchdog crash seen in 1.14(8). That hang is inside
        // DDConversionAction.calculateResult while the SYSTEM builds an
        // edit-menu item's title, with zero Minis frames in the stack, and it
        // is reached from a user-initiated selection rather than from an
        // automatic detector pass. UITextView already defaults this property
        // to [] (verified: rawValue 0), so this line changes no behavior
        // today; it guards against a future SDK changing that default.
        dataDetectorTypes = []
        // Symmetric 4pt top/bottom inset. Bottom was there originally to keep
        // emoji and Latin descenders (g, p, y) off the clipping edge under
        // TextKit 1; without a matching TOP inset the ascender of glyphs
        // whose mark extends above cap-height — the dot on "i" / "j",
        // accents, the curl on "f" — gets sliced by `clipsToBounds = true`
        // when the first line's `lineFragmentRect` starts at y=0. T-dot-clip
        // 8d2c7f4a.
        //
        // 4pt matches the bottom inset and fits the heightForBlock precalc's
        // existing `bounds.height + 8` buffer (4 top + 4 bottom = 8), so no
        // change is needed in the height-cache layer.
        textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        backgroundColor = .clear
        // [T-multi-select-share] No Writing Tools on replies: the text is read-only,
        // and the selection menu's last slot goes to "Share Chat…" instead.
        if #available(iOS 18.0, *) { writingToolsBehavior = .none }
        textContainer.lineBreakMode = .byWordWrapping
        // Prevent UITextView from inserting extra padding
        contentInset = .zero
        clipsToBounds = true
        textDragInteraction?.isEnabled = false
        linkTextAttributes = [
            .foregroundColor: SelectableMarkdownTheme().linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        // Tap gesture for inline code copy
        let codeTap = UITapGestureRecognizer(target: self, action: #selector(handleInlineCodeTap(_:)))
        codeTap.delegate = self
        addGestureRecognizer(codeTap)
        inlineCodeTapGesture = codeTap

        // [T-ios-text-selection-autoscroll-followthrough] A non-cancelling,
        // zero-duration long-press that simply TRACKS the live touch during a
        // selection-handle drag. It never consumes the touch (cancelsTouchesInView
        // = false, recognizes simultaneously with everything) so UIKit's own
        // selection knobs keep working; we only read its location to drive the
        // collection view's edge auto-scroll while the finger is held. Unlike the
        // first cut, this gives us a real drag lifecycle (.ended/.cancelled =
        // finger lift) and a per-frame touch position, so holding still at the
        // edge keeps scrolling.
        let tracker = UILongPressGestureRecognizer(target: self, action: #selector(handleSelectionDragTrack(_:)))
        tracker.minimumPressDuration = 0
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesBegan = false
        tracker.delaysTouchesEnded = false
        tracker.delegate = self
        addGestureRecognizer(tracker)
        selectionDragTracker = tracker
    }

    // [T-ios-table-cell-image-menu] iOS 16 ONLY: UITextView attaches a built-in
    // UIContextMenuInteraction that, when an inline NSTextAttachment carries an
    // image (our TableAttachment / CodeBlockAttachment / MathAttachment all use a
    // transparent placeholder image for layout), long-press pops the system
    // image preview menu — "Copy Image" / "Save to Camera Roll" over an all-black
    // (transparent-placeholder) preview. There is no delegate hook to suppress
    // it on iOS 16 (the UITextItem.menuConfiguration API is iOS 17+, which is why
    // 17/18 are handled in menuConfigurationFor and 16 slipped through). We strip
    // the system context-menu interaction as UIKit installs it; the app's own
    // affordances don't depend on it — text selection/copy uses the edit menu
    // (UIMenuController) and table cells promote to TableCellTextView with their
    // own Copy Table / Copy Table Image menu. Gated to iOS <17 so 17+ keeps the
    // (handled) system menu and link/text-item previews.
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0), interaction is UIContextMenuInteraction {
            return
        }
        super.addInteraction(interaction)
    }

    private weak var selectionDragTracker: UILongPressGestureRecognizer?

    private weak var inlineCodeTapGesture: UITapGestureRecognizer?
    /// Called when the user taps a blank (non-link, non-code) area.
    /// The CGPoint is the tap location in **window coordinates**.
    var onTapBlank: ((CGPoint) -> Void)?
    /// [#414] When set, a blank tap reaches `onTapBlank` only if this returns
    /// true at tap time (this block is the text block the usage capsule sits
    /// under) AND the tap lies in the block's last `UsageTapBand.lineCount`
    /// visual lines. nil keeps the old rule: any blank tap.
    var blankTapEligible: (() -> Bool)?

    /// Track whether we have an active (non-empty) text selection and notify
    /// the parent NoAnimationCollectionView.
    private var hadSelection = false
    /// Offsets (from beginningOfDocument) of the previous selection's start/end,
    /// so we can tell which handle is the one being dragged this change.
    /// [T-ios-text-selection-collectionview-autoscroll]
    private var prevSelStartOffset: Int?
    private var prevSelEndOffset: Int?

    func updateSelectionState() {
        let hasSelection = selectedTextRange.map { !$0.isEmpty } ?? false
        let cv = findCollectionView()
        if hasSelection != hadSelection {
            hadSelection = hasSelection
            cv?.hasActiveTextSelection = hasSelection
        }
        // [T-ios-text-selection-collectionview-autoscroll] On every selection
        // change while a selection is active (the user is dragging a handle),
        // report the MOVING handle's caret to the collection view so it can
        // auto-scroll when that handle nears an edge. UITextView's own
        // auto-scroll only moves the text view, not the outer list.
        guard let cv else { return }
        guard hasSelection, let range = selectedTextRange else {
            prevSelStartOffset = nil
            prevSelEndOffset = nil
            cv.stopSelectionAutoScroll()
            return
        }
        let startOff = offset(from: beginningOfDocument, to: range.start)
        let endOff = offset(from: beginningOfDocument, to: range.end)
        // The handle that moved since last change is the dragging one. On the
        // first change of a new selection (no prev), default to the end handle.
        let draggingEnd: UITextPosition
        if let pe = prevSelEndOffset, endOff != pe {
            draggingEnd = range.end
        } else if let ps = prevSelStartOffset, startOff != ps {
            draggingEnd = range.start
        } else {
            draggingEnd = range.end
        }
        prevSelStartOffset = startOff
        prevSelEndOffset = endOff
        // [T-ios-text-selection-autoscroll-followthrough] Remember which handle
        // (start vs end) is the one being dragged so the auto-scroll step can
        // extend THAT end to the content scrolled under the finger.
        draggingHandleIsEnd = (draggingEnd === range.end)
    }

    /// Which selection handle the user is currently dragging (true = end/right,
    /// false = start/left). Used to extend the correct end while auto-scrolling.
    private var draggingHandleIsEnd = true

    /// Tracks the live selection-handle drag touch and drives the collection
    /// view's edge auto-scroll off it. [T-ios-text-selection-autoscroll-followthrough]
    @objc private func handleSelectionDragTrack(_ g: UILongPressGestureRecognizer) {
        guard let cv = findCollectionView() else { return }
        switch g.state {
        case .began, .changed:
            // Only drive auto-scroll while a real (non-empty) selection exists —
            // i.e. the user is dragging a selection handle, not just touching.
            let hasSelection = selectedTextRange.map { !$0.isEmpty } ?? false
            guard hasSelection else { cv.stopSelectionAutoScroll(); return }
            // Feed the live touch Y in the collection view's coordinate space and
            // wire the per-frame selection-follow callback.
            let touchPoint = g.location(in: cv)
            cv.onAutoScrollStep = { [weak self, weak cv] pt in
                guard let self, let cv else { return }
                self.extendSelectionToTouch(pointInCollectionView: pt, cv: cv)
            }
            cv.updateSelectionAutoScroll(touchPoint: touchPoint)
        case .ended, .cancelled, .failed:
            cv.onAutoScrollStep = nil
            cv.stopSelectionAutoScroll()
        default:
            break
        }
    }

    /// After an auto-scroll step, extend the dragging end of the selection to the
    /// document position now under the held touch, so the range follows the
    /// scrolled-in content (the iMessage-style behavior).
    private func extendSelectionToTouch(pointInCollectionView pt: CGPoint, cv: NoAnimationCollectionView) {
        // [T-ios-selection-autoscroll-edge-flicker] Convert the REAL touch point
        // (both X and Y) into this text view's coordinates. The earlier version
        // used the text view's mid-X, so the caret it computed sat at a
        // different in-line position than UIKit's own native caret (driven by
        // the real touch X). The two then overwrote `selectedTextRange` with
        // different ranges on alternating frames — the handle/highlight redrew
        // back and forth = the reported edge flicker. Using the real X makes our
        // computed caret agree with UIKit's, so they no longer fight.
        let pointInSelf = cv.convert(pt, to: self)
        guard let touchPos = closestPosition(to: pointInSelf),
              let current = selectedTextRange else { return }
        let newRange: UITextRange?
        if draggingHandleIsEnd {
            // Dragging the end handle downward: anchor = start, moving = touch.
            newRange = textRange(from: current.start, to: touchPos)
        } else {
            // Dragging the start handle upward: anchor = end, moving = touch.
            newRange = textRange(from: touchPos, to: current.end)
        }
        guard let r = newRange, !r.isEmpty else { return }
        // [T-ios-selection-autoscroll-edge-flicker] Skip the write when the range
        // is unchanged — re-assigning the same selection still forces UITextView
        // to redraw its handles/highlight, adding to the per-frame churn.
        // UITextPosition is a reference type, so compare by document offset
        // rather than identity.
        if let cur = selectedTextRange,
           compare(cur.start, to: r.start) == .orderedSame,
           compare(cur.end, to: r.end) == .orderedSame {
            return
        }
        selectedTextRange = r
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        // Momentarily lock the collection view's contentOffset during
        // becomeFirstResponder to block UIKit's _adjustContentOffsetIfNecessary.
        // [T-ios-resign-first-responder-graph-reentry] Deliberately NOT guarded.
        // The crash walks in through -[UITextView resignFirstResponder] during
        // UIKit's responder REBASE; the _UIHostingView.canBecomeFirstResponder
        // frame in that stack is UIKit interrogating a candidate mid-walk, not
        // an entry into this override. Deferring here bought no crash coverage
        // and did cost behaviour: the table-cell promotion path at
        // `promoteTextView` calls becomeFirstResponder() and then immediately
        // sets a selection and shows the edit menu, so returning false and
        // completing a turn later left the menu addressing a view that was not
        // yet first responder.
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.becomeFirstResponder()
        cv?.offsetLocked = false
        // [T-ios-preapply-endediting] Register as the tracked responder so
        // applySnapshot's pre-apply endEditing gate knows a responder exists
        // inside the list without walking the subview tree.
        if result { cv?.trackedTextResponder = self }
        return result
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        // Momentarily lock during resignFirstResponder too.
        let cv = findCollectionView()
        // [T-ios-preapply-endediting] History, because two TestFlight crash
        // families met in this method:
        //
        //  1. crash C4wXLBpem (1.13(4), 8/17): `super.resignFirstResponder()`
        //     INSIDE `dataSource.apply`'s batch update walks the responder
        //     chain → _UIHostingView.canBecomeFirstResponder →
        //     ViewRendererHost.responderNode → AGGraphGetInputValue — a fresh
        //     AttributeGraph read mid-transaction → AG::precondition_failure →
        //     abort() (not catchable).
        //  2. c1fd59e1f fixed (1) by deferring `super` and returning false.
        //     That refusal violates UIKit's rebase contract: TestFlight
        //     1.13(15) then asserted in
        //     _resignOrRebaseFirstResponderViewWithIndexPathMapping:.
        //
        // Both require a live first responder at apply time, so the fix moved
        // up a level: applySnapshot calls endEditing BEFORE the structural
        // apply, outside the transaction, where a synchronous `super` is the
        // ordinary, safe path. This override is synchronous again and never
        // returns false while actually still responder.
        if cv?.isApplyingSnapshot == true {
            // Should be unreachable (see above). Synchronous super here is an
            // occasional graph crash; returning false was a guaranteed
            // assertion — synchronous strictly dominates. WARN for visibility.
            responderLogger.warning("[Responder] resignFirstResponder DURING applySnapshot — pre-apply endEditing missed this responder")
        }
        cv?.offsetLocked = true
        let result = super.resignFirstResponder()
        cv?.offsetLocked = false
        if cv?.trackedTextResponder === self { cv?.trackedTextResponder = nil }
        clearSelectionStateOnResign(cv)
        return result
    }

    /// Selection/auto-scroll teardown that must happen whenever this text view
    /// loses focus, independent of whether `super` ran synchronously or was
    /// deferred. [T-ios-resign-first-responder-graph-reentry]
    private func clearSelectionStateOnResign(_ cv: NoAnimationCollectionView?) {
        // Safety net: always clear selection lock when losing focus.
        if hadSelection {
            hadSelection = false
            cv?.hasActiveTextSelection = false
        }
        // [T-ios-text-selection-collectionview-autoscroll] Losing focus ends any
        // selection drag — stop the edge auto-scroll ticker immediately.
        prevSelStartOffset = nil
        prevSelEndOffset = nil
        cv?.stopSelectionAutoScroll()
    }

    /// Walk the superview chain to find the parent NoAnimationCollectionView.
    func findCollectionView() -> NoAnimationCollectionView? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? NoAnimationCollectionView { return cv }
            view = v.superview
        }
        return nil
    }

    /// Walk up the view hierarchy to find the enclosing UICollectionViewCell.
    func findCell() -> UICollectionViewCell? {
        var view: UIView? = superview
        while let v = view {
            if let cell = v as? UICollectionViewCell { return cell }
            view = v.superview
        }
        return nil
    }

    @objc private func handleInlineCodeTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: self)
        let windowPoint = self.convert(point, to: nil)

        // Check if tap is inside an attachment view (code block, table, image, etc.)
        for subview in attachmentViews {
            if subview.frame.contains(point) {
                tapLogger.debug("[tap] hit attachment view at \(String(format: "%.0f,%.0f", point.x, point.y)) — ignored")
                return
            }
        }

        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )

        // Determine if the tap is actually over rendered text or in empty space.
        let isBeyondText = charIndex >= textStorage.length
        let isInGlyphRect: Bool
        if !isBeyondText {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            isInGlyphRect = lineRect.contains(point)
        } else {
            isInGlyphRect = false
        }
        let isBlankArea = isBeyondText || !isInGlyphRect

        tapLogger.debug("[tap] point=\(String(format: "%.0f,%.0f", point.x, point.y)) charIdx=\(charIndex) len=\(textStorage.length) fraction=\(String(format: "%.2f", fraction)) inGlyph=\(isInGlyphRect) isBlank=\(isBlankArea) hasOnTapBlank=\(onTapBlank != nil)")

        if isBlankArea {
            // [#414] Only the usage capsule's band responds; anywhere else a
            // blank tap does nothing, exactly as with no handler.
            guard blankTapPassesUsageBand(point) else {
                tapLogger.debug("[tap] blank area outside the usage band — ignored")
                return
            }
            if let onTapBlank {
                tapLogger.debug("[tap] blank area → calling onTapBlank windowPt=\(String(format: "%.0f,%.0f", windowPoint.x, windowPoint.y))")
                onTapBlank(windowPoint)
            } else {
                tapLogger.debug("[tap] blank area but no onTapBlank handler")
            }
            return
        }

        // Inline code: copy it
        if let codeText = textStorage.attribute(.inlineCodeText, at: charIndex, effectiveRange: nil) as? String {
            tapLogger.debug("[tap] inline code → copy")
            UIPasteboard.general.string = codeText
            showCopiedFeedback(at: charIndex)
            return
        }

        // Link or plain text — don't intercept
        let isLink = textStorage.attribute(.link, at: charIndex, effectiveRange: nil) != nil
        tapLogger.debug("[tap] on text content (link=\(isLink)) — not handled")
    }

    private let tapLogger = AppLogger(category: "MarkdownTap")

    private func showCopiedFeedback(at charIndex: Int) {
        var effectiveRange = NSRange()
        guard textStorage.attribute(.inlineCodeText, at: charIndex, effectiveRange: &effectiveRange) != nil else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        let flash = UIView(frame: rect.insetBy(dx: -2, dy: -1))
        flash.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        flash.layer.cornerRadius = 4
        flash.isUserInteractionEnabled = false
        addSubview(flash)

        // Show "Copied" toast near the code
        let toast = UILabel()
        toast.text = "Copied"
        toast.font = .systemFont(ofSize: 11, weight: .medium)
        toast.textColor = .white
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        toast.textAlignment = .center
        toast.layer.cornerRadius = 4
        toast.clipsToBounds = true
        toast.sizeToFit()
        toast.frame.size.width += 12
        toast.frame.size.height += 4
        toast.center = CGPoint(x: rect.midX, y: rect.minY - toast.frame.height / 2 - 4)
        // Keep toast within text view bounds
        if toast.frame.minX < 0 { toast.frame.origin.x = 0 }
        if toast.frame.maxX > bounds.width { toast.frame.origin.x = bounds.width - toast.frame.width }
        toast.alpha = 0
        addSubview(toast)

        UIView.animate(withDuration: 0.15) { toast.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 0.8, options: []) {
            flash.alpha = 0
            toast.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
            toast.removeFromSuperview()
        }
    }

    // Allow code block UITextViews to handle horizontal pans.
    // The outer text view's panGestureRecognizer can intercept touches
    // even when isScrollEnabled=false; reject horizontal pans that
    // originate inside a scrollable code block subview.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer == self.panGestureRecognizer {
            let location = gestureRecognizer.location(in: self)
            // Check if touch is inside any code block UITextView subview
            for subview in attachmentViews {
                if subview.frame.contains(location) {
                    // [T-codeblock-hide-idle-scrollbars] Ask the code block's
                    // SCROLL VIEW what it can actually scroll.
                    //
                    // This used to look at `findCodeTextView(...).isScrollEnabled`,
                    // but that inner UITextView is created with
                    // `isScrollEnabled = false` on purpose ("scrollView handles
                    // scrolling"), so the condition was never true and the whole
                    // branch was dead — the outer view never yielded a pan.
                    //
                    // Yield only on the axis the block can really scroll, which
                    // is what keeps a fitted (non-scrolling) block from stealing
                    // the drag and making the message list feel stuck.
                    if let codeScroll = findCodeScrollView(in: subview) {
                        let vel = self.panGestureRecognizer.velocity(in: self)
                        let horizontal = abs(vel.x) > abs(vel.y)
                        // Usable height excludes the bottom contentInset, the
                        // same way syncScrollability measures it.
                        let usableH = codeScroll.bounds.height - codeScroll.contentInset.bottom
                        let canScrollH = codeScroll.contentSize.width > codeScroll.bounds.width + 0.5
                        let canScrollV = codeScroll.contentSize.height > usableH + 0.5
                        if (horizontal && canScrollH) || (!horizontal && canScrollV) {
                            return false
                        }
                    }
                }
            }
        }
        // Inline code tap / blank area tap: allow unless tapping a link or attachment view
        if gestureRecognizer === inlineCodeTapGesture {
            // Don't interfere with active text selection
            if let sel = selectedTextRange, !sel.isEmpty { return false }
            let point = gestureRecognizer.location(in: self)
            // Don't interfere with attachment views (code blocks, tables, images)
            for subview in attachmentViews {
                if subview.frame.contains(point) { return false }
            }
            let idx = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            let isBeyondText = idx >= textStorage.length
            let isInGlyphRect: Bool
            if !isBeyondText {
                let gi = layoutManager.glyphIndexForCharacter(at: idx)
                let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: gi, effectiveRange: nil)
                isInGlyphRect = lineRect.contains(point)
            } else {
                isInGlyphRect = false
            }
            let isBlankArea = isBeyondText || !isInGlyphRect
            // Blank area → allow if handler exists and (#414) the tap is in the
            // usage band; outside it the gesture does not begin, the same as
            // a blank tap with no handler.
            if isBlankArea { return onTapBlank != nil && blankTapPassesUsageBand(point) }
            // On a link → don't begin (UITextView handles it)
            if textStorage.attribute(.link, at: idx, effectiveRange: nil) != nil { return false }
            // On inline code → allow
            if textStorage.attribute(.inlineCodeText, at: idx, effectiveRange: nil) != nil { return true }
            // On plain text → don't intercept (let text selection work)
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// [#414] Whether a blank tap at `point` (this view's coordinates) may
    /// toggle the usage capsule. No gate configured → true (old behaviour).
    func blankTapPassesUsageBand(_ point: CGPoint) -> Bool {
        guard let eligible = blankTapEligible else { return true }
        return UsageTapBand.contains(point: point, lineRects: visualLineRects(),
                                     blockTop: bounds.minY, blockBottom: bounds.maxY,
                                     isLastTextBlock: eligible())
    }

    /// [#414] Every visual line (soft-wrapped line fragment) of the laid-out
    /// text, in this view's coordinates. Taken from TextKit, so it follows the
    /// fonts, paragraph line heights and Dynamic Type actually in effect.
    func visualLineRects() -> [CGRect] {
        let glyphs = layoutManager.glyphRange(for: textContainer)
        guard glyphs.length > 0 else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            rects.append(rect.offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top))
        }
        return rects
    }

    // Allow our tap gesture to coexist with other tap gestures (e.g. link taps),
    // but NOT with long-press or pan gestures used for text selection.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // [T-ios-text-selection-autoscroll-followthrough] The selection-drag
        // tracker is a pure observer — it must run alongside UIKit's selection
        // knobs and everything else, and never blocks another gesture.
        if gestureRecognizer === selectionDragTracker || otherGestureRecognizer === selectionDragTracker {
            return true
        }
        if gestureRecognizer === inlineCodeTapGesture {
            return otherGestureRecognizer is UITapGestureRecognizer
        }
        return false
    }

    // When the user is actively selecting text (selection range exists and is non-zero),
    // don't let our tap gesture interfere with the selection handles.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === inlineCodeTapGesture,
           otherGestureRecognizer is UILongPressGestureRecognizer {
            // [T-ios-inline-code-tap-blocked-by-selection-tracker] The
            // selection-drag tracker is a `minimumPressDuration = 0` long-press,
            // so it SUCCEEDS on touch-down and never fails. Requiring it to fail
            // (the blanket `is UILongPressGestureRecognizer` rule) permanently
            // blocked codeTap, so tapping inline code did nothing. Only require a
            // *real* long-press (text selection) to fail; never the tracker.
            if otherGestureRecognizer === selectionDragTracker { return false }
            return true  // a real long press must fail before our tap can begin
        }
        return false
    }

    /// [T-codeblock-hide-idle-scrollbars] The code block's own UIScrollView —
    /// the view that actually scrolls (the UITextView inside it is created with
    /// `isScrollEnabled = false`). Used by `gestureRecognizerShouldBegin` to
    /// decide whether yielding the pan would accomplish anything.
    private func findCodeScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let found = findCodeScrollView(in: sub) { return found }
        }
        return nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Stored state used by the extension files
    //
    // Swift extensions cannot declare stored properties, so the state the
    // SelectableMarkdownTextView+*.swift files need is declared here, in the
    // order it had when the class was a single file.

    // Used by SelectableMarkdownTextView+EditMenu.swift.
    /// Read the WHOLE reply from the start via the Minis TTS stack
    /// (vm.readReplyFromStart). Plumbed from the cell bridge; nil while the
    /// reply is still streaming (would clash with live streaming TTS).
    var onReadAloud: (() -> Void)?
    /// Speak an arbitrary text snippet via the Minis TTS stack (vm.speakText).
    var onSpeakText: ((String) -> Void)?
    /// [T-in-chat-search] "Search in Chat" from the selection menu; receives
    /// the selected text (nil when nothing is selected) as the query.
    var onSearchInChat: ((String?) -> Void)?

    // Used by SelectableMarkdownTextView+SearchHighlight.swift.
    /// [T-in-chat-search] The search highlight of the block shown here, the
    /// occurrences found in the displayed text, and the outline layer drawn
    /// over code blocks / tables holding a match.
    var searchHighlightToken: ChatSearchHighlightToken?
    var searchHighlightSub: AnyCancellable?
    var searchHighlightDimmed = false
    var searchHighlightRefreshScheduled = false
    var searchHits: [ChatSearchHit] = []
    var searchHighlightCurrentOrdinal: Int?
    var searchHighlightLayer: CAShapeLayer?

    // Used by SelectableMarkdownTextView+SelectionDismissal.swift.
    /// Anchor character index for Shift+Click range selection.
    var selectionAnchor: Int?

    // Used by SelectableMarkdownTextView+Layout.swift.
    #if DEBUG
    var lastTableCellShortSignature: String?
    #endif

    // Used by SelectableMarkdownTextView+CellSizing.swift.
    /// Called after content changes to detect height growth and invalidate the
    /// parent UICollectionView cell's self-sizing so the layout re-measures it.
    /// Without this, UIHostingConfiguration may not propagate height changes
    /// caused by nested @ObservedObject updates (e.g. AssistantBlock.content
    /// growing from 1 line to 2 lines during streaming).
    let cellSizeLogger = AppLogger(category: "CellSize")
}

// BEGIN UsageTapBand
/// [#414] Where a blank tap may toggle a reply's token-usage capsule.
///
/// The capsule sits right after the reply's final text block. Only blank taps
/// in that block's last `lineCount` visual lines respond - not anywhere in the
/// reply, which made reading a long answer open and close the capsule by
/// accident. Same rule as Android's BlankTapGeometry band.
///
///   - bottom of the band = bottom of the block (where the capsule is);
///   - top = top of the `lineCount`-th visual line from the end; a block with
///     fewer lines responds over its whole height (top = block top);
///   - "visual line" = a laid-out line fragment (soft wraps count), so the
///     band follows the real fonts and line heights, Dynamic Type included.
///     Where line heights differ (a heading, a code block, a list), the band
///     is the actual extent of those last lines, i.e. what `lineCount` times
///     "the line height" means for that text - Android takes the same last
///     lines from TextLayoutResult;
///   - a block that is not the capsule's text block has no band at all.
/// The existing blank-area test still applies inside the band.
enum UsageTapBand {
    static let lineCount = 5

    /// The responding vertical range, or nil when the block has no lines.
    static func band(lineRects: [CGRect], blockTop: CGFloat, blockBottom: CGFloat) -> ClosedRange<CGFloat>? {
        // One entry per visual line, top to bottom.
        var tops: [CGFloat: CGRect] = [:]
        for r in lineRects where r.height > 0 { tops[r.minY] = tops[r.minY].map { $0.union(r) } ?? r }
        let lines = tops.values.sorted { $0.minY < $1.minY }
        guard let last = lines.last else { return nil }
        let top = lines.count < lineCount ? blockTop : lines[lines.count - lineCount].minY
        let bottom = max(blockBottom, last.maxY)
        return min(top, bottom)...bottom
    }

    static func contains(point: CGPoint, lineRects: [CGRect], blockTop: CGFloat, blockBottom: CGFloat,
                         isLastTextBlock: Bool) -> Bool {
        guard isLastTextBlock,
              let range = band(lineRects: lineRects, blockTop: blockTop, blockBottom: blockBottom) else { return false }
        return range.contains(point.y)
    }
}
// END UsageTapBand
