//
//  TableCellViews.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments / Table - cell views of TableAttachment's grid.
//
//  - TableCellLabel: the cheap steady-state cell (a UILabel). A long press
//    swaps it for a TableCellTextView so the text can be selected, and the
//    label comes back when the selection is dismissed.
//  - TableCellTextView: the selectable cell (links, edit menu, read aloud).
//
//  Both were `private` while the module was one file; internal now so
//  TableAttachment.swift can build them.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

final class TableCellTextView: UITextView, UITextViewDelegate {
    var onOpenURL: ((URL) -> Void)?
    /// Called when the text view resigns first responder (selection dismissed).
    var onResignFirstResponder: (() -> Void)?
    /// Closure that copies the entire table. Set by TableCellLabel when promoting.
    var copyTableAction: (() -> Void)?
    /// [T-ios-copy-table-image] Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        self.delegate = self
    }

    /// [T-ios-table-inline-code-rounded] TextKit1 stack backed by a
    /// MinisLayoutManager so inline-code spans (marked with
    /// `.inlineCodeBackground`) draw the same rounded background as body
    /// inline code via fillBackgroundRectArray. The default UITextView layout
    /// manager only paints square `.backgroundColor`.
    convenience init() {
        let textStorage = NSTextStorage()
        let layoutManager = MinisLayoutManager()
        let textContainer = NSTextContainer()
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        self.init(frame: .zero, textContainer: textContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // [T-ios-table-cell-image-menu] iOS 16 ONLY: drop the system
    // UIContextMenuInteraction so a promoted table cell never pops the
    // "Copy Image" / "Save to Camera Roll" preview menu for the cell's inline
    // attachments. Same rationale as SelectableMarkdownTextView.addInteraction;
    // iOS 17+ keeps the (handled) system menu.
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0), interaction is UIContextMenuInteraction {
            return
        }
        super.addInteraction(interaction)
    }

    // [T-ios-preapply-endediting] Responder changes are synchronous again.
    // The deferred-resign guard that used to live here (c1fd59e1f) returned
    // `false` mid-batch-update, which violates UIKit's rebase contract and
    // fired the NSInternalInconsistencyException in
    // _resignOrRebaseFirstResponderViewWithIndexPathMapping: (TestFlight
    // 1.13(15)). The invariant is now enforced one level up: applySnapshot
    // calls endEditing BEFORE the structural apply, so by the time a batch
    // update runs there is no first responder to resign or rebase — which
    // also removes the AttributeGraph re-entry the deferral was built for.
    // `become` registers this view as the tracked responder so that gate
    // knows when it must act.
    override func becomeFirstResponder() -> Bool {
        let cv = findCollectionView()
        cv?.offsetLocked = true
        let result = super.becomeFirstResponder()
        cv?.offsetLocked = false
        if result { cv?.trackedTextResponder = self }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let cv = findCollectionView()
        if cv?.isApplyingSnapshot == true {
            // Should be unreachable: applySnapshot ends editing before the
            // apply. If some path still gets here, run `super` synchronously —
            // the pre-c1fd59e1f behavior. In this window a synchronous super
            // is an OCCASIONAL AttributeGraph crash while returning false is a
            // GUARANTEED rebase assertion, so synchronous strictly dominates.
            // WARN so any hit is visible in logs.
            responderLogger.warning("[Responder] table-cell resignFirstResponder DURING applySnapshot — pre-apply endEditing missed this responder")
        }
        cv?.offsetLocked = true
        let result = super.resignFirstResponder()
        cv?.offsetLocked = false
        if cv?.trackedTextResponder === self { cv?.trackedTextResponder = nil }
        onResignFirstResponder?()
        return result
    }

    private func findCollectionView() -> NoAnimationCollectionView? {
        var view: UIView? = superview
        while let v = view {
            if let cv = v as? NoAnimationCollectionView { return cv }
            view = v.superview
        }
        return nil
    }

    // MARK: Edit menu — append "Copy Table" + "Add to Chat Input" alongside the standard items.

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Allow our own table commands first — copyTableImage's selector name
        // contains "image", so it must be whitelisted BEFORE the iOS-16 image
        // filter below or it would be swallowed.
        if action == #selector(copyTable) { return copyTableAction != nil }
        if action == #selector(copyTableImage) { return copyTableImageAction != nil }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length > 0
        }
        if action == #selector(readSelectedAloud) { return selectedRange.length > 0 }
        if action == #selector(readAllAloud) { return !text.isEmpty }
        // Read-only: never offer edit actions. Also block system Speak
        // (we provide our own TTS via VoiceOutputPlayer).
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:",
                                     "_speak:", "_accessibilitySpeak:"]
        let actionName = NSStringFromSelector(action)
        if actionName.contains("speak") || actionName.contains("Speak") { return false }
        if blocked.contains(actionName) { return false }
        // iOS 16: a table cell that lays out an inline NSTextAttachment with a
        // transparent placeholder image makes UIKit add system "Copy Image" /
        // "Save to Camera Roll" / "Share Image" items — with a black preview,
        // since the placeholder is 1×1 transparent. Copying that is meaningless
        // (the real action is "Copy Table Image"). Filter the system image
        // selectors so only the text/table actions remain. iOS 17+ uses
        // UIEditMenuInteraction and doesn't surface these. Mirrors the same
        // guard in SelectableMarkdownTextView.canPerformAction.
        if actionName.localizedCaseInsensitiveContains("image") {
            return false
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func copyTable() {
        copyTableAction?()
    }

    @objc func copyTableImage() {
        copyTableImageAction?()
    }

    @objc func readSelectedAloud() {
        guard selectedRange.length > 0,
              let range = Range(selectedRange, in: text) else { return }
        VoiceOutputPlayer.shared.stopAll()
        Self.activateReadAloudState()
        VoiceOutputPlayer.shared.enqueueSegmented(String(text[range]), sessionId: VoiceOutputPlayer.manualOwnerId)
    }

    @objc func readAllAloud() {
        VoiceOutputPlayer.shared.stopAll()
        Self.activateReadAloudState()
        VoiceOutputPlayer.shared.enqueueSegmented(text, sessionId: VoiceOutputPlayer.manualOwnerId)
    }

    /// Menu-triggered read-aloud bypasses AIChatViewModel's reply-TTS flow, so
    /// mirror `readReplyFromStart`'s pre-flight here: force the global
    /// read-replies switch ON (runtime state + persisted pref, un-muting if
    /// needed) and push "reading" to the capsule — via the active chat VM when
    /// one is registered, else directly on the global state object.
    static func activateReadAloudState() {
        // [T-tts-external-pause-stuck] Explicit read-aloud overrides a leftover
        // external-audio pause (see VoiceOutputPlayer.clearPauseForExplicitReadAloud).
        VoiceOutputPlayer.shared.clearPauseForExplicitReadAloud()
        let state = VoiceOutputState.shared
        if !state.isEnabled { state.isEnabled = true }   // didSet persists to prefs
        if state.isMuted { state.isMuted = false }
        if let vm = state.activeController as? AIChatViewModel {
            vm.isReadingAloud = true
            vm.speechPaused = false
            vm.syncSpeechStateToGlobal(registerActive: true)
        } else {
            state.syncState(reading: true, paused: false,
                            speed: VoiceOutputPreferences.speedMultiplier)
        }
    }

    /// Same as SelectableMarkdownTextView.addSelectionToChatInput — posts a
    /// `chatInputAppendRequested` notification with the selected cell text.
    /// AIChatView listens and routes to `AIChatViewModel.appendToInputText`.
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        // [T-selection-add-to-input-attachments] Cells can hold inline math
        // attachments; expand them instead of passing a bare U+FFFC.
        let snippet = SelectionTextExpander.expand(attributedText ?? NSAttributedString(),
                                                   in: selectedRange, includeCode: true)
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        resignFirstResponder()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Build ONE inline menu so the order is explicit and stable, then insert
        // it after the system edit menu. Desired order (top→bottom):
        //   Add to Chat Input  →  Copy Table  →  Copy Table Image
        // i.e. the high-frequency "Add to Chat Input" sits first, with the table
        // copy actions after it. [T-ios-copy-table-menu-order]
        var children: [UICommand] = []
        if selectedRange.length > 0 {
            children.append(
                UICommand(
                    title: AppLocalized("Add to Chat Input"),
                    image: UIImage(systemName: "text.insert"),
                    action: #selector(addSelectionToChatInput(_:))
                )
            )
        }
        if copyTableAction != nil {
            children.append(
                UICommand(
                    title: AppLocalized("Copy Table"),
                    image: UIImage(systemName: "tablecells"),
                    action: #selector(copyTable)
                )
            )
            // [T-ios-copy-table-image] Offer copying the whole table as an image.
            if copyTableImageAction != nil {
                children.append(
                    UICommand(
                        title: AppLocalized("Copy Table Image"),
                        image: UIImage(systemName: "tablecells.badge.ellipsis"),
                        action: #selector(copyTableImage)
                    )
                )
            }
        }
        // TTS actions — read selected or read all via VoiceOutputPlayer.
        if selectedRange.length > 0 {
            children.append(
                UICommand(
                    title: AppLocalized("Read Selected Aloud"),
                    image: UIImage(systemName: "speaker.wave.2"),
                    action: #selector(readSelectedAloud)
                )
            )
        }
        children.append(
            UICommand(
                title: AppLocalized("Read All Aloud"),
                image: UIImage(systemName: "play.circle"),
                action: #selector(readAllAloud)
            )
        )
        // Remove system Speak menu if present.
        builder.remove(menu: .speech)
        let menu = UIMenu(title: "", options: .displayInline, children: children)
        builder.insertSibling(menu, afterMenu: .standardEdit)
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction, let onOpenURL {
            onOpenURL(URL)
            return false
        }
        return true
    }
}

/// Lightweight UILabel used for table cells without links.
/// On long-press the label is swapped out for a UITextView so the user can select text,
/// then swapped back when the selection is dismissed — keeping the steady-state cost
/// at ~1-2 KB instead of ~35 KB per UITextView.
final class TableCellLabel: UILabel, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    /// The attributed string to hand off to the UITextView when activated.
    var selectableAttributedText: NSAttributedString?
    /// Closure that copies the entire parent table. Set during `makeView`.
    var copyTableAction: (() -> Void)?
    /// [T-ios-copy-table-image] Closure that copies the full table as a PNG image.
    var copyTableImageAction: (() -> Void)?
    /// Currently promoted UITextView (if any). Kept to clean up on dealloc/reuse.
    private weak var activeTextView: TableCellTextView?
    /// Window-level tap gesture used to dismiss the promoted text view.
    private var dismissTap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.4
        addGestureRecognizer(lp)

        // Double-tap selects the cell text and shows the edit menu — mirrors
        // the long-press and right-click flows so users on iPad without a
        // trackpad can reach Copy quickly.
        let dt = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        dt.numberOfTapsRequired = 2
        addGestureRecognizer(dt)

        // Right-click (external mouse / trackpad secondary) promotes the cell
        // to a selectable UITextView so the native edit menu can appear.
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeDismissTap()
        activeTextView?.removeFromSuperview()
    }

    // MARK: Rounded inline-code background

    // [T-ios-table-inline-code-rounded] The label has no NSLayoutManager, so
    // the body painter (fillBackgroundRectArray) can't reach it. Setting the
    // standard `.backgroundColor` would paint SQUARE corners. Instead we strip
    // `.backgroundColor` from the displayed text (keeping `.inlineCodeBackground`
    // as the range marker) and paint rounded rects ourselves in drawText.
    // `selectableAttributedText` is left untouched — the promoted UITextView
    // keeps `.backgroundColor` so its MinisLayoutManager painter still fires.

    override var attributedText: NSAttributedString? {
        get { super.attributedText }
        set { super.attributedText = newValue.map(Self.strippingSquareCodeBackground) }
    }

    /// Returns a copy with `.backgroundColor` removed from any inline-code
    /// range (ranges carrying `.inlineCodeBackground`), leaving other
    /// background colors — if any — intact.
    private static func strippingSquareCodeBackground(_ attr: NSAttributedString) -> NSAttributedString {
        let full = NSRange(location: 0, length: attr.length)
        var hasCode = false
        attr.enumerateAttribute(.inlineCodeBackground, in: full, options: []) { value, _, stop in
            if value != nil { hasCode = true; stop.pointee = true }
        }
        guard hasCode else { return attr }
        let mutable = NSMutableAttributedString(attributedString: attr)
        attr.enumerateAttribute(.inlineCodeBackground, in: full, options: []) { value, range, _ in
            if value != nil { mutable.removeAttribute(.backgroundColor, range: range) }
        }
        return mutable
    }

    override func drawText(in rect: CGRect) {
        paintInlineCodeBackgrounds()
        super.drawText(in: rect)
    }

    /// Lay the attributed text out in a transient TextKit1 stack matching the
    /// label's bounds, then fill a rounded rect behind each inline-code range.
    private func paintInlineCodeBackgrounds() {
        guard let attr = super.attributedText, attr.length > 0,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let full = NSRange(location: 0, length: attr.length)
        var codeRanges: [NSRange] = []
        attr.enumerateAttribute(.inlineCodeBackground, in: full, options: []) { value, range, _ in
            if value != nil { codeRanges.append(range) }
        }
        guard !codeRanges.isEmpty else { return }

        let storage = NSTextStorage(attributedString: attr)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        // Vertically center the laid-out text the same way UILabel does so the
        // painted rects line up with the glyphs super draws.
        let usedHeight = manager.usedRect(for: container).height
        let yOffset = max(0, (bounds.height - usedHeight) / 2)

        let bgColor = minisInlineCodeBackgroundColor.resolvedColor(with: traitCollection)
        ctx.saveGState()
        ctx.setFillColor(bgColor.cgColor)
        for range in codeRanges {
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rectPtr, _ in
                let r = rectPtr.offsetBy(dx: 0, dy: yOffset).insetBy(dx: -1, dy: -0.5)
                guard r.width > 2 else { return }
                let path = UIBezierPath(roundedRect: r, cornerRadius: 5)
                ctx.addPath(path.cgPath)
            }
        }
        ctx.fillPath()
        ctx.restoreGState()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        promoteToTextView()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        promoteToTextView()
    }

    // MARK: UIContextMenuInteractionDelegate

    /// Right-click (external mouse / trackpad) promotes the cell to a
    /// selectable UITextView with its text already selected — matching the
    /// long-press flow. Returning nil suppresses UIKit's default context menu
    /// so UITextView's native edit menu (Copy / Look Up / etc.) takes over.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        promoteToTextView()
        return nil
    }

    /// Replace this label with a selectable UITextView and immediately activate selection.
    private func promoteToTextView() {
        guard let parent = superview, activeTextView == nil else { return }

        let tv = TableCellTextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = selectableAttributedText ?? attributedText

        // Give the text view a taller frame than the label so the selection
        // handles have enough touch area. Vertically pad around the text so
        // the content stays visually centered at the label's original position.
        let extraPad: CGFloat = 12
        tv.frame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y - extraPad,
            width: frame.width,
            height: frame.height + extraPad * 2
        )
        tv.textContainerInset = UIEdgeInsets(top: extraPad, left: 0, bottom: extraPad, right: 0)

        // When the user taps away or the copy menu closes, the text view resigns
        // first responder. Swap back to the lightweight label at that point.
        tv.onResignFirstResponder = { [weak self] in
            self?.demoteTextView()
        }

        // Pass through the "Copy Table" action so it appears in the edit menu.
        tv.copyTableAction = copyTableAction
        tv.copyTableImageAction = copyTableImageAction

        activeTextView = tv
        isHidden = true
        parent.addSubview(tv)

        // Register the custom menu items, then select all and show the menu.
        // Order matches buildMenu: Add to Chat Input → Copy Table → Copy Table
        // Image. [T-ios-copy-table-menu-order]
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: AppLocalized("Add to Chat Input"), action: #selector(TableCellTextView.addSelectionToChatInput(_:))),
            UIMenuItem(title: AppLocalized("Copy Table"), action: #selector(TableCellTextView.copyTable)),
            // [T-ios-copy-table-image]
            UIMenuItem(title: AppLocalized("Copy Table Image"), action: #selector(TableCellTextView.copyTableImage)),
        ]

        // Select all text after a run-loop turn so TextKit finishes layout.
        DispatchQueue.main.async { [weak self, weak tv] in
            guard let tv else { return }
            tv.becomeFirstResponder()
            tv.selectedRange = NSRange(location: 0, length: tv.attributedText?.length ?? 0)

            // Show the edit menu over the text view.
            UIMenuController.shared.showMenu(from: tv, rect: tv.bounds)

            // Install the dismiss-tap after a short delay so it doesn't
            // immediately interfere with the menu presentation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.installDismissTap()
            }
        }
    }

    /// Adds a tap recognizer to the window so that tapping *anywhere* outside
    /// the edit menu dismisses the promoted text view.
    private func installDismissTap() {
        guard let window = activeTextView?.window, dismissTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleDismissTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        dismissTap = tap
    }

    private func removeDismissTap() {
        if let tap = dismissTap {
            tap.view?.removeGestureRecognizer(tap)
            dismissTap = nil
        }
    }

    @objc private func handleDismissTap(_ gesture: UITapGestureRecognizer) {
        // Let the text view resign naturally — this triggers demoteTextView()
        // via onResignFirstResponder. Calling demoteTextView() directly here
        // would remove the text view before a menu action (e.g. Copy) completes.
        activeTextView?.resignFirstResponder()
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Don't let the dismiss tap fire while the edit menu is visible —
        // otherwise it kills the text view before Copy can execute.
        if gestureRecognizer === dismissTap, UIMenuController.shared.isMenuVisible {
            return false
        }
        return true
    }

    /// Remove the promoted UITextView and show the label again.
    private func demoteTextView() {
        removeDismissTap()
        activeTextView?.onResignFirstResponder = nil
        activeTextView?.removeFromSuperview()
        activeTextView = nil
        isHidden = false
        UIMenuController.shared.menuItems = nil
    }
}
