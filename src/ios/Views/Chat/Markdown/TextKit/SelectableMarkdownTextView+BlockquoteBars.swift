//
//  SelectableMarkdownTextView+BlockquoteBars.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, blockquote bars.
//
//  draw(_:) paints the vertical bar for each blockquote nesting level, from
//  the blockquote-depth attribute the renderer writes.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownTextView {
    // MARK: Blockquote Bars

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawBlockquoteBars(in: rect)
    }

    private func drawBlockquoteBars(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let textStorage = self.textStorage as? NSTextStorage,
              let layoutManager = self.layoutManager as? MinisLayoutManager else { return }

        let theme = SelectableMarkdownTheme()
        let fullRange = NSRange(location: 0, length: textStorage.length)

        // Collect contiguous blockquote spans and compute their union bounding rects.
        // Multiple attributed-string ranges may have the same depth but different styling
        // (bold, italic, etc.), so we merge adjacent ranges into one continuous bar.
        struct BarSpan {
            let depth: Int
            var rect: CGRect
        }
        var spans: [BarSpan] = []

        // Helper: process a single non-attachment character range for bar drawing.
        //
        // Uses per-line fragment `usedRect`s (not `boundingRect(forGlyphRange:)`)
        // so the resulting span excludes trailing paragraphSpacing. Without this,
        // when a blockquote is followed by a paragraph containing inline code
        // that wraps, the bar overshoots into the next paragraph.
        func addBarSpan(depth: Int, range: NSRange) {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            var spanRect: CGRect = .null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                spanRect = spanRect.isNull ? usedRect : spanRect.union(usedRect)
            }
            guard !spanRect.isNull, spanRect.height > 0 else { return }

            if let last = spans.last, last.depth == depth,
               spanRect.minY <= last.rect.maxY + 2 {
                spans[spans.count - 1].rect = last.rect.union(spanRect)
            } else {
                spans.append(BarSpan(depth: depth, rect: spanRect))
            }
        }

        textStorage.enumerateAttribute(.blockquoteDepth, in: fullRange, options: []) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            // [T-blockquote-bar-attachment-holes] Measure the WHOLE quoted
            // range, attachment characters included. This used to split the
            // range at every attachment character, which fragmented the span
            // before it was ever drawn — a quote containing only a code block
            // produced no span at all and therefore no bar. Attachment glyphs
            // occupy real line fragments inside the quote, so including them is
            // what makes the bar span the quote's true extent.
            addBarSpan(depth: depth, range: range)
        }

        // Draw each bar as ONE continuous run.
        //
        // [T-blockquote-bar-attachment-holes] This used to punch holes wherever
        // an attachment view's frame overlapped the span *on the Y axis only* —
        // it never checked whether the attachment actually intersected the bar
        // in X (x = depth*13 + 1, width 3). That broke the bar for every
        // attachment kind: a code block indents by `quoteDepth * 13` and never
        // covers the bar at all, yet still cut it; inline math and inline
        // images punched a line-height gap nowhere near the bar; and a quote
        // holding only a code block lost its bar entirely.
        //
        // No clipping is needed. Attachments are SUBVIEWS and therefore
        // composite above `draw(_:)`, so wherever one is genuinely opaque over
        // the bar it already hides it — exactly what the punch-out did — while
        // the transparent regions (a code card's 13pt left inset) now keep the
        // continuous bar they should always have had.
        //
        // The same fix was applied to MarkdownRenderView in e235132f, but that
        // view has no call sites; this is the copy the chat actually renders
        // through, which is why OpenMinis#123 stayed reproducible after it.
        for span in spans {
            let height = span.rect.maxY - span.rect.minY
            guard height > 1 else { continue }
            context.saveGState()
            context.setFillColor(theme.blockquoteBarColor.cgColor)
            for d in 1...span.depth {
                let x = CGFloat(d - 1) * 13 + 1
                let barRect = CGRect(x: x, y: span.rect.minY, width: 3, height: height)
                context.addPath(UIBezierPath(roundedRect: barRect, cornerRadius: 2).cgPath)
            }
            context.fillPath()
            context.restoreGState()
        }
    }
}
