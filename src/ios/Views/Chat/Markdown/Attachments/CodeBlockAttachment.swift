//
//  CodeBlockAttachment.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments.
//
//  Fenced code block: a horizontally scrolling code view with a language
//  header and copy button, sized by attachmentBounds. While a reply streams,
//  each chunk swaps in a fresh attachment at the same character; its content
//  fingerprint is folded into the text view's cell-size fingerprint
//  (SelectableMarkdownTextView+CellSizing) so that growth is not deduplicated
//  away.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Code Block Attachment

final class CodeBlockAttachment: NSTextAttachment {
    var code: String
    let language: String?
    let theme: SelectableMarkdownTheme
    let quoteDepth: Int
    /// Sequential index for view reuse across re-renders (set by MarkdownNSRenderer).
    var blockIndex: Int = 0
    /// [CodeGenDedup] Hash of (code, language), computed once by the renderer
    /// at creation. Folded into the invalidateCellSizeIfNeeded dedupe
    /// fingerprint so in-place code growth during streaming — which changes
    /// neither textStorage.length nor width — still defeats [SKIP-DEDUPE]
    /// and re-invalidates the host cell's height (the TableGenDedup
    /// counterpart for code blocks).
    let contentFingerprint: Int

    /// Left inset for blockquote nesting (matches text indent).
    var leftInset: CGFloat { CGFloat(quoteDepth) * 13 }

    init(code: String, language: String?, theme: SelectableMarkdownTheme, quoteDepth: Int = 0, contentFingerprint: Int = 0) {
        self.code = code
        self.language = language
        self.theme = theme
        self.quoteDepth = quoteDepth
        self.contentFingerprint = contentFingerprint
        super.init(data: nil, ofType: nil)
        // Provide a transparent image so UIKit doesn't draw a default placeholder
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    static let topMargin: CGFloat = 6
    static let bottomMargin: CGFloat = 4

    /// Associated-object key retaining the copy-tap gesture target
    /// for the button's lifetime (see makeView).
    static var copyTapHandlerKey: UInt8 = 0

    /// Target object for the fallback tap gesture on the copy button —
    /// UITapGestureRecognizer needs an @objc target/action pair.
    final class CodeCopyTapHandler: NSObject {
        private let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
        @objc func handleTap() { perform() }
    }

    /// [T-ios17-codeblock-copy-dead] Reference box for the double-fire guard:
    /// with both the control event AND the fallback gesture bound (see
    /// makeView), a version where the control path still works would invoke
    /// the copy twice per tap without it.
    final class CopyDebounce { var last = Date.distantPast }

    /// Cached content height from sizeThatFits, keyed by code hash + width.
    private var cachedContentHeight: (hash: Int, height: CGFloat)?

    /// Measure actual code text height using the same approach as makeView.
    private func measureCodeHeight() -> CGFloat {
        let codeHash = code.hashValue
        if let cached = cachedContentHeight, cached.hash == codeHash {
            return cached.height
        }
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let attrStr = NSAttributedString(string: code, attributes: [
            .font: theme.codeBlockFont,
            .paragraphStyle: codeStyle,
        ])
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.attributedText = attrStr
        let h = tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
        cachedContentHeight = (hash: codeHash, height: h)
        return h
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = lineFrag.width
        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        let contentHeight = measureCodeHeight()
        let bottomPadding: CGFloat = 12
        let maxCodeHeight: CGFloat = 400 - topOffset - bottomPadding
        let scrollHeight = min(contentHeight, maxCodeHeight)
        let totalHeight = topOffset + scrollHeight + bottomPadding
        let height = totalHeight + Self.topMargin + Self.bottomMargin
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// [T-codeblock-hide-idle-scrollbars] Turn each scroll axis' indicator —
    /// and its bounce — off when that axis has nothing to scroll.
    ///
    /// The scroll view is created with both indicators and both bounces on
    /// unconditionally, so a 3-line snippet that fits entirely inside the box
    /// still showed a vertical scrollbar and rubber-banded when dragged. Most
    /// code blocks fit, so the common case was the wrong one.
    ///
    /// Compared against `scrollHeight`, NOT `bounds.height`: the frame is
    /// `scrollHeight + bottomPadding` tall with a matching `contentInset.bottom`,
    /// so the genuinely usable height is `scrollHeight`. Using the frame height
    /// would count that padding as usable space and call a block scroll-free
    /// when its last line is actually clipped.
    ///
    /// The 0.5pt tolerance absorbs sub-pixel noise from `sizeThatFits`, which
    /// otherwise leaves a scrollbar on a block that fits exactly.
    private static func syncScrollability(_ scrollView: UIScrollView,
                                          contentSize: CGSize,
                                          visibleWidth: CGFloat,
                                          scrollHeight: CGFloat) {
        let canScrollV = contentSize.height > scrollHeight + 0.5
        let canScrollH = contentSize.width > visibleWidth + 0.5
        scrollView.showsVerticalScrollIndicator = canScrollV
        scrollView.showsHorizontalScrollIndicator = canScrollH
        // Bouncing on an axis that cannot scroll reads as a glitch, and the
        // rubber-band also competes with the enclosing message list's pan.
        scrollView.alwaysBounceVertical = canScrollV
        scrollView.alwaysBounceHorizontal = canScrollH
        // When NEITHER axis can move, stop scrolling entirely rather than
        // leaving an inert scroll view in the way. Its pan recognizer would
        // still claim the touch and then do nothing with it, which is what
        // makes dragging the message list over a code block feel like it
        // catches — the list only starts moving after the finger leaves the
        // block. `isScrollEnabled = false` removes the recognizer from
        // arbitration, so the pan reaches the list immediately.
        //
        // Text selection inside the block is unaffected: that is the
        // UITextView's own long-press/selection gestures, not this pan.
        scrollView.isScrollEnabled = canScrollV || canScrollH
        // [T-codeblock-offset-reset] A reused block (codeBlockViewCache /
        // updateExistingView) can shrink to content that fits. Its old
        // scroll position would then stay applied with scrolling switched
        // off: the content shows clipped and cannot be scrolled back.
        var offset = scrollView.contentOffset
        if !canScrollH { offset.x = 0 }
        if !canScrollV { offset.y = 0 }
        if offset != scrollView.contentOffset { scrollView.contentOffset = offset }
    }

    func makeView(width: CGFloat) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let inset = leftInset
        let contentWidth = width - inset

        let container = UIView()
        container.backgroundColor = theme.codeBlockBackground
        container.layer.cornerRadius = theme.codeBlockCornerRadius
        container.clipsToBounds = true

        var topOffset: CGFloat = 12

        // Language label
        if let language, !language.isEmpty {
            let langLabel = UILabel()
            langLabel.text = language.lowercased()
            langLabel.font = .systemFont(ofSize: 11, weight: .medium)
            langLabel.textColor = .white.withAlphaComponent(0.4)
            langLabel.frame = CGRect(x: 12, y: 8, width: contentWidth - 60, height: 16)
            container.addSubview(langLabel)
            topOffset = 28
        }

        // Scrollable code area (own the pan gesture here for reliable horizontal scroll)
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.clipsToBounds = true
        // [T-chat-statusbar-scrolltotop-mistap] Opt OUT of the status-bar tap
        // here, so that the message list can reliably opt IN.
        //
        // This looks like the setting that was reverted on the collection view,
        // but it does the opposite job. UIKit scrolls NOTHING when more than
        // one eligible (`scrollsToTop == true`) scroll view is visible — it
        // cannot tell which one the user meant. Every rendered code block is
        // its own scroll view, so leaving this at the default would make the
        // gesture work only while no code block happened to be on screen, and
        // silently do nothing otherwise.
        //
        // Keeping it off leaves the message list as the sole candidate, which
        // is what makes "tap the status bar -> jump to the top of the chat"
        // behave the same way every time. It costs nothing: a status-bar tap is
        // never a request to scroll a code snippet.
        scrollView.scrollsToTop = false

        let codeTextView = UITextView()
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false // scrollView handles scrolling
        codeTextView.backgroundColor = .clear
        codeTextView.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainer.lineBreakMode = .byClipping

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let codeAttr = NSAttributedString(string: code, attributes: [
            .font: theme.codeBlockFont,
            .foregroundColor: theme.codeBlockTextColor,
            .paragraphStyle: codeStyle,
        ])
        codeTextView.attributedText = codeAttr

        // Measure content size (unconstrained width)
        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let contentHeight = fitting.height
        let fittingWidth = fitting.width
        codeTextView.frame = CGRect(x: 0, y: 0, width: fittingWidth, height: contentHeight)

        let maxCodeHeight: CGFloat = 400 - topOffset - 12
        let scrollHeight = min(contentHeight, maxCodeHeight)
        let bottomPadding: CGFloat = 12
        scrollView.frame = CGRect(x: 0, y: topOffset, width: contentWidth, height: scrollHeight + bottomPadding)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomPadding, right: 0)
        scrollView.scrollIndicatorInsets = .zero
        scrollView.addSubview(codeTextView)
        scrollView.contentSize = CGSize(width: fittingWidth, height: contentHeight)
        Self.syncScrollability(scrollView,
                               contentSize: scrollView.contentSize,
                               visibleWidth: contentWidth,
                               scrollHeight: scrollHeight)

        // Auto-scroll to bottom during streaming
        let bottomY = scrollView.contentSize.height - scrollView.bounds.height
        if bottomY > 0 {
            scrollView.contentOffset = CGPoint(x: 0, y: bottomY)
        }

        container.addSubview(scrollView)

        let totalHeight = topOffset + scrollHeight + bottomPadding
        container.frame = CGRect(x: inset, y: 0, width: contentWidth, height: totalHeight)

        // Copy button — 44x44 hit area per Apple HIG, icon stays small visually
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let copyButton = UIButton(type: .system)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
        copyButton.tintColor = .white.withAlphaComponent(0.5)
        copyButton.frame = CGRect(x: contentWidth - 44, y: 0, width: 44, height: 44)
        let debounce = CopyDebounce()
        let performCopy: () -> Void = { [weak codeTextView, weak copyButton] in
            // [T-ios17-codeblock-copy-dead] Double-fire guard: on versions
            // where the control event still works, a single tap now arrives
            // through BOTH the control path and the fallback gesture below.
            // The copy itself is idempotent, but guard anyway so the action
            // runs exactly once per physical tap.
            guard Date().timeIntervalSince(debounce.last) > 0.3 else { return }
            debounce.last = Date()
            // Read directly from the UITextView so we always copy the latest
            // content, even after updateExistingView replaced the attributed text.
            UIPasteboard.general.string = codeTextView?.text
            copyButton?.setImage(UIImage(systemName: "checkmark", withConfiguration: iconConfig), for: .normal)
            copyButton?.tintColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copyButton?.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
                copyButton?.tintColor = .white.withAlphaComponent(0.5)
            }
        }
        copyButton.addAction(UIAction { _ in performCopy() }, for: .touchUpInside)
        // [T-ios16-codeblock-copy-regression] [T-ios17-codeblock-copy-dead]
        // ALWAYS also bind an independent tap gesture on the button, on every
        // OS version. History of this line:
        //   • iOS 16: .touchUpInside stopped firing (regressed between TF26
        //     and TF28) — the host text view's gesture/interaction graph
        //     cancels the control's touches. Fallback added, gated <17 on the
        //     assumption "iOS 17+ button works".
        //   • iOS 17: field report proved that assumption wrong — same dead
        //     button. The likely toucher is visible one screen up:
        //     addInteraction(_:) DROPS UIContextMenuInteraction on iOS 16 but
        //     KEEPS it on 17+, so 17 is exactly the version where the
        //     interaction's gesture graph exists AND no fallback was bound
        //     (18+ reworked the text-interaction stack and doesn't cancel).
        // A UITapGestureRecognizer attached to the button recognizes through
        // the gesture system rather than the control-event path, so it
        // survives the cancellation on every affected version. The version
        // gate is gone for good: it encoded a per-version guess that has now
        // been wrong twice, and the debounce in performCopy makes the
        // double-bind harmless where the control path does work.
        let tapHandler = CodeCopyTapHandler(perform: performCopy)
        let tap = UITapGestureRecognizer(target: tapHandler, action: #selector(CodeCopyTapHandler.handleTap))
        tap.cancelsTouchesInView = false
        copyButton.addGestureRecognizer(tap)
        objc_setAssociatedObject(copyButton, &Self.copyTapHandlerKey, tapHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.addSubview(copyButton)

        container.frame.origin.y = Self.topMargin
        wrapper.addSubview(container)
        wrapper.frame = CGRect(x: 0, y: 0, width: width, height: totalHeight + Self.topMargin + Self.bottomMargin)

        return wrapper
    }

    /// Update the code text in an existing view created by `makeView(width:)` without recreating.
    func updateExistingView(_ wrapper: UIView) {
        guard let container = wrapper.subviews.first else { return }
        guard let scrollView = container.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView else { return }
        guard let codeTextView = scrollView.subviews.first(where: { $0 is UITextView }) as? UITextView else { return }

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let codeAttr = NSAttributedString(string: code, attributes: [
            .font: theme.codeBlockFont,
            .foregroundColor: theme.codeBlockTextColor,
            .paragraphStyle: codeStyle,
        ])
        codeTextView.attributedText = codeAttr

        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        codeTextView.frame.size = fitting
        scrollView.contentSize = fitting

        // Recalculate heights to match attachmentBounds logic
        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        let maxCodeHeight: CGFloat = 400 - topOffset - 12
        let scrollHeight = min(fitting.height, maxCodeHeight)
        let bottomPadding: CGFloat = 12
        let newScrollFrame = CGRect(x: 0, y: topOffset, width: container.frame.width, height: scrollHeight + bottomPadding)
        let totalHeight = topOffset + scrollHeight + bottomPadding

        // [CodeBlockGrow] Animate the visible code-frame growing taller as more
        // lines stream in, instead of snapping. The wrapper's LOGICAL height is
        // set immediately (synchronously) because the caller reads
        // `view.frame.size.height` right after this returns to lay out the
        // TextKit attachment slot + the enclosing cell — animating that would
        // desync the code frame from the text flow. Only the wrapper's visible
        // children (the rounded background container + its scroll view) animate
        // their height, so the box smoothly extends while layout stays exact.
        // [T-codeblock-hide-idle-scrollbars] Re-evaluate on every update: a block
        // that fitted a moment ago starts scrolling once streaming pushes it past
        // maxCodeHeight, and a re-render with less content goes back to fitting.
        Self.syncScrollability(scrollView,
                               contentSize: fitting,
                               visibleWidth: container.frame.width,
                               scrollHeight: scrollHeight)

        let heightGrew = totalHeight > container.frame.size.height + 0.5
        wrapper.frame.size.height = totalHeight + Self.topMargin + Self.bottomMargin
        let applyChildFrames = {
            scrollView.frame = newScrollFrame
            container.frame.size.height = totalHeight
        }
        if heightGrew {
            UIView.animate(withDuration: 0.20,
                           delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                           animations: applyChildFrames)
        } else {
            applyChildFrames()
        }

        // Auto-scroll to bottom during streaming
        let bottomY = scrollView.contentSize.height - scrollView.bounds.height
        if bottomY > 0 {
            scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: bottomY)
        }
    }
}
