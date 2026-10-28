//
//  MinisLayoutManager.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit.
//
//  NSLayoutManager subclass for glyph-level drawing that attributes alone
//  cannot express - chiefly the rounded inline-code pills
//  (fillBackgroundRectArray). Reads the custom keys and colour defined in
//  Support/MarkdownTheme.swift.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - MinisLayoutManager

/// Custom NSLayoutManager subclass. Originally added for inline-code rounded
/// background rendering (see `fillBackgroundRectArray` below). Kept as a
/// dedicated class so other layout-manager hooks can be added in one place.
final class MinisLayoutManager: NSLayoutManager {

    /// [T-ios-inline-code-quote-band] Breathing room painted past the last
    /// visible glyph on a wrapped line. Mirrors the ~0.5-1pt of slack the
    /// unclamped rect carries on a tight single-line span, so a wrapped line's
    /// pill doesn't look clipped against its final character.
    private static let inlineCodeTrailingInset: CGFloat = 2

    /// [T-ios-inline-code-wrap-gap] Corner radius of the inline-code pill.
    /// Named because the multi-line joining below has to reason about it: a
    /// radius applied to an interior edge is what makes two stacked pills read
    /// as separate chips rather than one block.
    private static let inlineCodeCornerRadius: CGFloat = 5

    /// [T-in-chat-search] Character ranges filled with the search highlight
    /// (see SelectableMarkdownTextView+SearchHighlight). Drawing only.
    var searchHighlightRanges: [NSRange] = []
    var searchHighlightCurrent: NSRange?
    var searchHighlightDimmed = false
    /// [T-in-chat-search] Told after every storage edit, so highlights are
    /// found again in the new text. Nil unless a search highlight is bound.
    var onTextStorageEdited: (() -> Void)?

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
        onTextStorageEdited?()
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        drawSearchHighlights(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: UIColor) {
        // Check if this range has inline code background
        guard let textStorage = self.textStorage else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        var hasInlineCode = false
        if charRange.location + charRange.length <= textStorage.length {
            textStorage.enumerateAttribute(.inlineCodeBackground, in: charRange, options: []) { value, _, _ in
                if value != nil { hasInlineCode = true }
            }
        }

        guard hasInlineCode, let context = UIGraphicsGetCurrentContext() else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        // [T-inline-code-dark-bg-ios] Same dynamic color as the theme; resolve
        // against the current traits explicitly so the CGColor is correct even
        // if UITraitCollection.current isn't the drawing view's during this
        // TextKit callback.
        let bgColor = minisInlineCodeBackgroundColor.resolvedColor(with: UITraitCollection.current)
        context.saveGState()
        context.setFillColor(bgColor.cgColor)

        let glyphRange = self.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)

        // Count how many line fragments the code span covers (single vs multi-line)
        var lineFragCount = 0
        enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineFragCount += 1
        }

        // [T-ios-inline-code-wrap-gap] Accumulated across the loop so the
        // joining pass can see every line's pill at once.
        var pillRects: [CGRect] = []

        // [T-ios-inline-code-multiline-rect] TextKit does NOT hand over one
        // rect per line: for a span wrapping across 3+ lines it passes the
        // first line's partial rect, ONE rect covering every full middle line,
        // and the last line's partial rect (measured: a 232-char code span
        // over 9 lines came as 3 rects, the middle one 154pt tall). Everything
        // below assumes one line per rect, so split first.
        var lineFragRects: [CGRect] = []
        enumerateLineFragments(forGlyphRange: glyphRange) { lineFragRect, _, _, _, _ in
            lineFragRects.append(lineFragRect)
        }
        let perLineRects = Self.splitRectsPerLine(
            (0..<rectCount).map { rectArray[$0] }, lineFragments: lineFragRects)

        for var rawRect in perLineRects {
            guard rawRect.width > 2 else { continue }

            // Check if the code span's text on this line has visible (non-whitespace)
            // characters. When word wrap pushes the code span to the next line, the
            // previous line may retain only a leading space with .backgroundColor,
            // producing an empty background rect.
            var hasVisibleText = false
            // correctedOriginY / correctedHeight: the closure captures rawRect
            // by value, so we write back corrections through these vars.
            var correctedOriginY: CGFloat = rawRect.minY
            var correctedHeight: CGFloat = rawRect.height
            // [T-ios-inline-code-quote-band] Trailing edge of the last VISIBLE
            // glyph on this line. See the clamp below for why rawRect's own
            // width can't be trusted on a wrapped line.
            var visibleMaxX: CGFloat = .nan
            // [T-ios-inline-code-list-indent] Leading edge of the first glyph
            // on this line — the counterpart to visibleMaxX. TextKit reports
            // the background rect of a WRAPPED line as starting at the text
            // container's origin (x=0), ignoring the paragraph's headIndent,
            // so inside a list the pill ran back to the bubble's left edge
            // while the text it belongs to sat one indent level in.
            var visibleMinX: CGFloat = .nan
            enumerateLineFragments(forGlyphRange: glyphRange) { lineFragRect, usedRect, _, lineGlyphRange, _ in
                guard lineFragRect.midY >= rawRect.minY && lineFragRect.midY <= rawRect.maxY else { return }
                let overlapStart = max(glyphRange.location, lineGlyphRange.location)
                let overlapEnd = min(NSMaxRange(glyphRange), NSMaxRange(lineGlyphRange))
                guard overlapEnd > overlapStart else { return }
                let overlapCharRange = self.characterRange(forGlyphRange: NSRange(location: overlapStart, length: overlapEnd - overlapStart), actualGlyphRange: nil)
                guard overlapCharRange.length > 0 else { return }
                let overlapText = (textStorage.string as NSString).substring(with: overlapCharRange)
                if !overlapText.trimmingCharacters(in: .whitespaces).isEmpty {
                    hasVisibleText = true

                    // [T-ios-inline-code-quote-band] Measure out to the last
                    // non-whitespace character of this line's slice. A wrapped
                    // line keeps the space it broke on inside its used rect, so
                    // the rect TextKit hands us reaches past the final glyph —
                    // and in a blockquote (headIndent set, no tailIndent) that
                    // is the container's full width, which is the right-hand
                    // band in the report. The last line has no break space and
                    // is already tight, which is why only the earlier lines
                    // looked wrong.
                    // [T-ios-inline-code-pad-gap] The span's U+200A padding
                    // is not a break space and stays inside the pill.
                    let trailingWS = Self.trailingBreakWhitespaceCount(overlapText)
                    let visibleCharRange = NSRange(location: overlapCharRange.location,
                                                   length: max(0, overlapCharRange.length - trailingWS))
                    if visibleCharRange.length > 0 {
                        let visibleGlyphRange = self.glyphRange(forCharacterRange: visibleCharRange,
                                                                actualCharacterRange: nil)
                        // Bound by the text container so a trailing glyph that
                        // TextKit lays out past the edge can't re-widen the pill.
                        if let tc = self.textContainer(forGlyphAt: visibleGlyphRange.location,
                                                       effectiveRange: nil) {
                            let box = self.boundingRect(forGlyphRange: visibleGlyphRange, in: tc)
                            visibleMaxX = visibleMaxX.isNaN ? box.maxX : max(visibleMaxX, box.maxX)
                            // [T-ios-inline-code-list-indent] Same measurement,
                            // other edge. boundingRect honours headIndent, which
                            // is exactly what the rect TextKit handed us does not.
                            visibleMinX = visibleMinX.isNaN ? box.minX : min(visibleMinX, box.minX)
                        }
                    }

                    // Clamp rect to usedRect (excludes lineSpacing) so the
                    // inline-code background aligns with the text, not the
                    // bloated lineFragRect that includes paragraph spacing.
                    if rawRect.height > usedRect.height + 2 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                    // Fix last-line height issue: TextKit may pass a shorter rect
                    // for the final line. Only correct for single-line spans to
                    // avoid mis-firing on multi-line wrapped code.
                    if lineFragCount == 1 && rawRect.height < usedRect.height * 0.8 {
                        correctedOriginY = usedRect.minY
                        correctedHeight = usedRect.height
                    }
                }
            }
            guard hasVisibleText else { continue }

            // Apply corrected origin and height from the closure above.
            rawRect = CGRect(x: rawRect.minX, y: correctedOriginY, width: rawRect.width, height: correctedHeight)

            // [T-ios-inline-code-quote-band] Shrink (never grow) to the visible
            // glyph extent. Clamping only downward keeps this inert for spans
            // TextKit already measured tightly — single-line code, the final
            // line of a wrapped span — so short inline code and body text are
            // untouched, and the long-path wrap fix (T-ios-inline-code-long-
            // path-wrap) still decides WHERE the break happens; this only
            // decides how far the pill is painted afterwards.
            //
            // A small trailing inset keeps the pill from sitting flush against
            // its last glyph. The `padded < rawRect.maxX` test is what makes
            // this shrink-only: a line TextKit already measured tightly (a
            // single-line span, or the last line of a wrapped one, where
            // visibleMaxX == rawRect.maxX) keeps its original rect untouched.
            // [T-ios-inline-code-list-indent] Pull the LEADING edge in to the
            // first glyph before the trailing clamp runs, so the width below is
            // computed from the corrected origin.
            //
            // On a wrapped line TextKit reports the background rect from the
            // container origin, dropping the paragraph's headIndent — so in a
            // list the pill started at the bubble's left edge while its text
            // began one indent level in. boundingRect does honour the indent,
            // so the glyph extent measured above is the truth.
            //
            // Shrink-only, exactly like the trailing clamp: a line TextKit
            // already measured tightly has visibleMinX == rawRect.minX and is
            // left untouched. Never move the edge LEFT — that would let a
            // mis-measured span paint outside the rect TextKit reserved.
            if !visibleMinX.isNaN, visibleMinX > rawRect.minX, visibleMinX < rawRect.maxX {
                rawRect.size.width -= visibleMinX - rawRect.minX
                rawRect.origin.x = visibleMinX
            }

            if !visibleMaxX.isNaN, visibleMaxX > rawRect.minX {
                let padded = visibleMaxX + Self.inlineCodeTrailingInset
                if padded < rawRect.maxX {
                    rawRect.size.width = padded - rawRect.minX
                }
            }

            // Vertically center the background within the line.
            // rawRect height reflects the full usedRect (dominated by the tallest
            // font on the line). The inline code font is shorter, so we compute
            // the background height from the actual glyph bounding box and center
            // it within rawRect to avoid the "floats to top" misalignment.
            let codeFont = textStorage.attribute(.font, at: charRange.location, effectiveRange: nil) as? UIFont
            let fontLineHeight = codeFont?.lineHeight ?? rawRect.height
            let bgPaddingV: CGFloat = 2   // top + bottom padding inside the pill
            let bgHeight = min(fontLineHeight + bgPaddingV * 2, rawRect.height)
            let bgY = rawRect.midY - bgHeight / 2 - 0.5
            let rect = CGRect(x: rawRect.minX - 0.5, y: bgY, width: rawRect.width + 1, height: bgHeight)
            // [T-ios-inline-code-wrap-gap] Collected rather than filled here —
            // the joining pass below needs to see the whole set to know which
            // edges are interior. See `paintInlineCodeRects`.
            pillRects.append(rect)
        }

        Self.paintInlineCodeRects(pillRects, in: context)
        context.fillPath()
        context.restoreGState()
    }

    // BEGIN trailingBreakWhitespaceCount
    /// [T-ios-inline-code-pad-gap] How many characters at the end of a code
    /// span's line slice the visible-glyph clamp may cut off: the whitespace a
    /// wrapped line broke on, but NOT the U+200A the renderer appends as the
    /// span's padding.
    ///
    /// The renderer pads every span with a U+200A on each side. In Menlo (the
    /// inline code font) that "hair" space is a full 0.6em cell, ~8.4pt at
    /// body size. The clamp used to strip all trailing whitespace, U+200A
    /// included, so on every span's last line the pill ended 2pt past the
    /// final glyph and the trailing pad sat outside it: ~8.4pt of bare space
    /// plus the source's own space before the next word, while the leading
    /// pad stayed inside the pill. Keeping the pad visible leaves the pill
    /// edge where TextKit measured it, so the clamp shrinks only lines that
    /// end on a break space, which is the case it exists for.
    static func trailingBreakWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for ch in text.reversed() {
            guard ch.isWhitespace, ch != "\u{200A}" else { break }
            count += 1
        }
        return count
    }
    // END trailingBreakWhitespaceCount

    // BEGIN splitRectsPerLine
    /// [T-ios-inline-code-multiline-rect] Split each background rect TextKit
    /// passed into one rect per line fragment it covers (by the fragment's
    /// vertical midpoint), keeping the rect's horizontal extent and taking the
    /// fragment's vertical one. A rect covering a single line - every rect of a
    /// one- or two-line span - comes back unchanged, so those paths are
    /// bit-identical to before.
    ///
    /// Without this, the per-rect pass treated the multi-line middle rect as
    /// one line: its height correction took the usedRect of the LAST line it
    /// saw, collapsing the block to that line, and the joining pass then
    /// stretched the FIRST line's pill down over the gap with the first line's
    /// x-range - lines 2-3 of the report lost the background on their left
    /// half while lines 4+ looked right.
    static func splitRectsPerLine(_ rects: [CGRect], lineFragments: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for raw in rects {
            let covered = lineFragments.filter { $0.midY >= raw.minY && $0.midY <= raw.maxY }
            guard covered.count > 1 else {
                out.append(raw)
                continue
            }
            for line in covered {
                out.append(CGRect(x: raw.minX, y: line.minY, width: raw.width, height: line.height))
            }
        }
        return out
    }
    // END splitRectsPerLine

    /// [T-ios-inline-code-wrap-gap] Draw the pills for ONE inline-code span,
    /// joining them vertically when the span wrapped across lines.
    ///
    /// The bug: each line's pill is sized to the code font
    /// (`fontLineHeight + padding`) and centred in its line box. That is right
    /// for a single-line span — it stops a short chip from inheriting the full
    /// leading of a line whose tallest glyph is body text. But across a wrapped
    /// span it means consecutive pills are shorter than the line pitch, so a
    /// horizontal band of background shows between every pair of lines. In the
    /// report that reads as the highlight "breaking" in the middle, while the
    /// first and last lines look correct.
    ///
    /// The fix has two halves, and both are needed:
    ///
    ///  * **Close the vertical gap.** Sort by y and stretch each adjacent pair
    ///    to meet at their midpoint. Only ever GROWS a pill, and only toward a
    ///    neighbour that already exists, so a single-line span (one rect, no
    ///    pairs) is bit-identical to before.
    ///
    ///  * **Square the interior corners.** Once two pills touch, rounding the
    ///    joined edges carves notches out of the seam — visually worse than the
    ///    gap it replaced. The first pill keeps its top corners, the last keeps
    ///    its bottom, and everything in between is a plain rectangle.
    ///
    /// Deliberately NOT done as one union path: the lines have different widths
    /// (the last is usually short), so a union outline would need mitred joins
    /// between differing edges — far more geometry for no visual gain, since
    /// the fill colour is flat and opaque.
    static func paintInlineCodeRects(_ rects: [CGRect], in context: CGContext) {
        guard !rects.isEmpty else { return }
        let radius = inlineCodeCornerRadius

        guard rects.count > 1 else {
            context.addPath(UIBezierPath(roundedRect: rects[0], cornerRadius: radius).cgPath)
            return
        }

        // Top-to-bottom. TextKit hands rects in layout order already, but the
        // pairing below is only correct if that holds, so make it explicit.
        var ordered = rects.sorted { $0.minY < $1.minY }

        // Grow each adjacent pair until they meet halfway. Guarded on a real
        // gap so already-touching or overlapping rects are left alone.
        for i in 0..<(ordered.count - 1) {
            let gap = ordered[i + 1].minY - ordered[i].maxY
            guard gap > 0 else { continue }
            let meet = ordered[i].maxY + gap / 2
            ordered[i].size.height = meet - ordered[i].minY
            let nextBottom = ordered[i + 1].maxY
            ordered[i + 1].origin.y = meet
            ordered[i + 1].size.height = nextBottom - meet
        }

        for (i, rect) in ordered.enumerated() {
            let corners: UIRectCorner
            switch i {
            case 0: corners = [.topLeft, .topRight]
            case ordered.count - 1: corners = [.bottomLeft, .bottomRight]
            default: corners = []
            }
            let path = corners.isEmpty
                ? UIBezierPath(rect: rect)
                : UIBezierPath(roundedRect: rect,
                               byRoundingCorners: corners,
                               cornerRadii: CGSize(width: radius, height: radius))
            context.addPath(path.cgPath)
        }
    }
}
