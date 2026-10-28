//
//  SelectableMarkdownView+FirstSeed.swift
//  Minis
//
//  [T-scroll-first-build-once] Exact height of a finished text block before
//  it is ever displayed, so its row is not measured through SwiftUI.
//
//  Measured on device (2026-10-03, iPhone 17 Pro): a row SelfSizingCell
//  measures before its first display builds its text view twice. The text
//  view made for the measure is dismantled by the first display update and a
//  new coordinator + text view renders and sizes everything again - 40-65 ms
//  for a 1-2.5k-char reply, the 50-90 ms drops while flinging through long
//  chats. On-device A/B showed it is SwiftUI's own behaviour for a hosting
//  view measured before display (any measure: Auto Layout fitting or
//  sizeThatFits; and a row that skips the measure is built once, while adding
//  one measure to it makes it rebuild too). Nothing in our view tree or
//  configuration flow causes it.
//
//  So the fix is to not measure: compute the height the representable will
//  report, exactly as `sizeThatFits` computes it for a finished block, and
//  hand it to the cell as a seed - the path that skips the hosting measure.
//  A seed is the cell's hard height, so this must be EXACT, never an
//  estimate ([T-ios-user-msg-truncate-seed-starve]):
//  - finished blocks only (cachedAttributedString or cachedContent present);
//  - the same attributed string updateUIView would assign (prebuilt when it
//    has no table, otherwise rendered by the message's shared renderer);
//  - attachments limited to tables and thematic breaks, whose heights are a
//    pure function of width (a break is a fixed 1 pt line; most long replies
//    use `---` between sections). Images, video, audio, math and code blocks
//    load or lay out asynchronously, so those blocks keep the measured path;
//  - measured in a scratch text view configured like the coordinator's
//    measureTextView (insets 4/4, no line-fragment padding), rounded the way
//    sizeThatFits rounds each path.
//  If it ever disagrees with the display, the text view's own
//  invalidateCellSizeIfNeeded corrects the row as it does for any change.
//

import UIKit

extension SelectableMarkdownView {
    /// Height the representable will report at `width`, or nil when it cannot
    /// be known exactly before display.
    @MainActor
    static func firstDisplayHeight(markdown: String,
                                   cachedContent: MarkdownContent?,
                                   cachedAttributedString: NSAttributedString?,
                                   messageId: UUID,
                                   blockId: UUID,
                                   width: CGFloat) -> CGFloat? {
        guard width > 1, !markdown.isEmpty else { return nil }
        guard cachedAttributedString != nil || cachedContent != nil else { return nil }

        let attributed: NSAttributedString
        if let prebuilt = cachedAttributedString, !containsTable(prebuilt) {
            attributed = prebuilt
        } else {
            let renderer = sharedRenderer(for: messageId)
            renderer.messageId = messageId
            renderer.blockId = blockId
            let content = cachedContent ?? MarkdownContent(prepareMarkdownForRender(markdown))
            attributed = autoreleasepool { renderer.render(blocks: content.blocks) }
        }
        guard attributed.length > 0 else { return nil }

        var hasAttachment = false
        var hasOtherAttachment = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
            guard let value else { return }
            if value is TableAttachment || value is ThematicBreakAttachment {
                hasAttachment = true
            } else {
                hasOtherAttachment = true
                stop.pointee = true
            }
        }
        guard !hasOtherAttachment else { return nil }

        let textView = firstSeedTextView
        textView.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        textView.attributedText = attributed
        defer { textView.attributedText = NSAttributedString() }
        let height = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        // sizeThatFits ceils the attachment-free path and returns any path
        // with an attachment as measured.
        return hasAttachment ? height : ceil(height)
    }

    private static func containsTable(_ string: NSAttributedString) -> Bool {
        var found = false
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length), options: []) { value, _, stop in
            if value is TableAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Configured like `Coordinator.measureTextView`.
    @MainActor private static let firstSeedTextView: SelectableMarkdownTextView = {
        let textView = SelectableMarkdownTextView()
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        return textView
    }()
}
