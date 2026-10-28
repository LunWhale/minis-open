//
//  MarkdownNSRenderer.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Rendering.
//
//  Turns [BlockNode] (from Agent/Markdown/MinisMarkdownParser) into the
//  NSAttributedString shown by SelectableMarkdownTextView. Text becomes
//  attributed runs; anything TextKit cannot draw by itself (code blocks,
//  tables, math, images, video, audio, rules) becomes an NSTextAttachment
//  subclass from Attachments/.
//
//  Attachments are cached on the renderer instance (per content key or slot)
//  so a streaming re-render reuses the same attachment objects - and therefore
//  the same on-screen views. The bridge keeps one renderer per message
//  (rendererCache in Bridge/SelectableMarkdownView.swift); dropping a renderer
//  drops those caches.
//
//  A new block type is rendered here; if it needs a live view, add an
//  attachment - see the checklist in the module map.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - MarkdownNSRenderer

/// Converts `[BlockNode]` → `NSMutableAttributedString` for display in a UITextView.
final class MarkdownNSRenderer {
    private(set) var theme: SelectableMarkdownTheme

    /// Assistant message this renderer belongs to. Set by `SelectableMarkdownView`
    /// before each `render(blocks:)` call so inline image attachments can route
    /// tap gestures back to a paged gallery of all sibling images in the message.
    /// nil for contexts that don't provide a message (e.g. standalone previews).
    var messageId: UUID?
    /// Block identity for table slot-cache disambiguation. Set per render()
    /// call; when non-nil the slot key is simply messageId:blockId — immune
    /// to content collisions between tables with identical rows.
    var blockId: UUID?

    init(baseFontSize: CGFloat? = nil) {
        self.theme = SelectableMarkdownTheme(baseFontSize: baseFontSize)
    }

    func updateFontSize(_ size: CGFloat) {
        theme = SelectableMarkdownTheme(baseFontSize: size)
    }
    private var bodyLineSpacing: CGFloat { theme.baseFontSize * 0.25 }
    /// minisChat list item: .em(0.25) top margin
    private var listItemTopMargin: CGFloat { theme.baseFontSize * 0.25 }
    /// minisChat headings: .em(1) top and bottom
    private var headingTopMargin: CGFloat { theme.baseFontSize }
    private var headingBottomMargin: CGFloat { theme.baseFontSize }

    /// Reuse existing media attachments across re-renders to avoid reload flicker during streaming.
    var imageAttachmentCache: [String: ImageAttachment] = [:]
    var videoAttachmentCache: [String: VideoAttachment] = [:]
    var audioAttachmentCache: [String: AudioAttachment] = [:]
    /// Reuse code block attachments by index to preserve ObjectIdentifier across streaming re-renders.
    var codeBlockAttachmentCache: [Int: CodeBlockAttachment] = [:]
    /// Content hashes for code blocks, keyed by sequential index.
    var codeBlockContentHashes: [Int: Int] = [:]
    /// Reuse table attachments by content hash so the same table layout
    /// can be reused even when re-rendered in a different message slot
    /// or after the renderer was wiped for an unrelated reason.
    ///
    /// HangFix(2026-05-14): the previous `[Int: …]` keyed by streaming
    /// index meant that whenever `isNewMessage` triggered a renderer wipe
    /// (e.g. when the cell is reused with a different assistant message),
    /// every TableAttachment was rebuilt and its `cachedLayout` reset to
    /// nil — forcing typesetter to run a full per-cell `boundingRect`
    /// pass on each `attachmentBounds` query. On a 6-table message that
    /// was 27 s of main-thread typesetter pin (ips Minis-2026-05-14-094312).
    /// Keying by contentHash lets re-rendered identical tables hit the
    /// previously-built attachment + its `cachedLayout`.
    var tableAttachmentCache: [Int: TableAttachment] = [:]
    /// LRU eviction order for `tableAttachmentCache` so the cache can't
    /// grow without bound when the user scrolls through long history.
    /// Most-recently-touched contentHash sits at the end.
    var tableAttachmentLRU: [Int] = []
    private let tableAttachmentCacheCap = 64
    /// HangFix(2026-05-14) — per-slot identity preservation for in-progress
    /// streaming tables. When a table at the same `tableIndex` keeps
    /// growing row-by-row, its content hash changes every flush but it's
    /// the *same* visual table. Calling `update()` on the existing
    /// TableAttachment instance preserves NSTextAttachment identity, which
    /// keeps `updateUIView`'s prefix-equality fast path alive and lets
    /// `updateAttachmentViews` swap only the affected TableScrollView in
    /// place rather than tearing down every attachment view. Without this,
    /// every streamed token rebuilds every attachment subview → flicker +
    /// O(N) work per flush.
    /// Key: "<messageUUID>:<tableIndex>". Without messageId, two different
    /// messages that both have a table at idx=2 would falsely share a
    /// slot during render — the new message's first render would call
    /// `update()` on the previous message's table data. Tracking by
    /// (messageId, idx) keeps streaming-growth detection scoped to the
    /// single message that's actually growing.
    var tableSlotCache: [String: TableAttachment] = [:]
    /// Map TableAttachment instance → its current contentHash key in
    /// `tableAttachmentCache` so we can re-key when `update()` mutates an
    /// in-place attachment. Keyed by ObjectIdentifier hashValue.
    var tableAttachmentReverseKey: [ObjectIdentifier: Int] = [:]
    var mathAttachmentCache: [String: MathAttachment] = [:]
    private var codeBlockIndex = 0
    private var tableIndex = 0

    private struct RenderedBlock {
        let attributed: NSAttributedString
        let topMargin: CGFloat?
        let bottomMargin: CGFloat?
        let isBlockAttachment: Bool

        init(attributed: NSAttributedString, topMargin: CGFloat?, bottomMargin: CGFloat?, isBlockAttachment: Bool = false) {
            self.attributed = attributed
            self.topMargin = topMargin
            self.bottomMargin = bottomMargin
            self.isBlockAttachment = isBlockAttachment
        }
    }

    func render(blocks: [BlockNode]) -> NSAttributedString {
        codeBlockIndex = 0
        tableIndex = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let tableCountBefore = tableAttachmentCache.count

        let result = renderBlockSequence(blocks, listDepth: 0, quoteDepth: 0, tightSpacing: false).attributed
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // Only log noisy cases to keep signal-to-noise high: slow renders, or
        // renders that touched tables (streaming table bug suspect).
        if elapsed >= 20 || tableIndex > 0 {
            let level = elapsed >= 100 ? "🔥" : ""
            // [T-ios-markdown-rerender-burst] Include messageId + rendererPtr so
            // we can distinguish "1 textView rendering N times" from "N
            // different textViews rendering the same content" (cell reuse vs
            // SwiftUI re-invalidation of the same coordinator).
            let mid = messageId?.uuidString.prefix(8) ?? "?"
            let rId = String(ObjectIdentifier(self).hashValue & 0xFFFFFF, radix: 16)
            Self.rendererLogger.info("[RND]\(level) mid=\(mid) rnd=\(rId) blocks=\(blocks.count) tables=\(tableIndex) codeBlocks=\(codeBlockIndex) attrLen=\(result.length) \(String(format: "%.1f", elapsed))ms tableCache=\(tableCountBefore)→\(tableAttachmentCache.count)")
        }
        return result
    }

    fileprivate static let rendererLogger = AppLogger(category: "MarkdownRenderer")

    // MARK: Block Rendering

    private func renderBlock(_ block: BlockNode, listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        switch block {
        case .paragraph(let content):
            return renderParagraph(content, quoteDepth: quoteDepth)
        case .heading(let level, let content):
            return renderHeading(level: level, content: content, quoteDepth: quoteDepth)
        case .codeBlock(let fenceInfo, let content):
            return renderCodeBlockAttachment(fenceInfo: fenceInfo, content: content, quoteDepth: quoteDepth)
        case .blockquote(let children):
            return renderBlockquote(children: children, listDepth: listDepth, quoteDepth: quoteDepth)
        case .bulletedList(let isTight, let items):
            return renderBulletedList(isTight: isTight, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .numberedList(let isTight, let start, let items):
            return renderNumberedList(isTight: isTight, start: start, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .taskList(let isTight, let items):
            return renderTaskList(isTight: isTight, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .table(let alignments, let rows):
            return renderTableAttachment(alignments: alignments, rows: rows)
        case .thematicBreak:
            return renderThematicBreakAttachment()
        case .htmlBlock(let content):
            return renderHTMLBlock(content, quoteDepth: quoteDepth)
        case .mathBlock(let content):
            return renderMathBlockAttachment(latex: content)
        }
    }

    private func renderBlockSequence(_ blocks: [BlockNode], listDepth: Int, quoteDepth: Int, tightSpacing: Bool) -> RenderedBlock {
        mergeRenderedBlocks(
            blocks.map { renderBlock($0, listDepth: listDepth, quoteDepth: quoteDepth) },
            tightSpacing: tightSpacing
        )
    }

    private func mergeRenderedBlocks(_ blocks: [RenderedBlock], tightSpacing: Bool) -> RenderedBlock {
        guard let first = blocks.first else {
            return RenderedBlock(attributed: NSAttributedString(), topMargin: nil, bottomMargin: nil)
        }

        let result = NSMutableAttributedString(attributedString: first.attributed)
        for i in 1..<blocks.count {
            let previous = blocks[i - 1]
            let current = blocks[i]
            let suppressBottom = tightSpacing && !previous.isBlockAttachment && !current.isBlockAttachment
            let previousBottom = suppressBottom ? 0 : (previous.bottomMargin ?? 0)
            let spacing = max(current.topMargin ?? 0, previousBottom)
            // Apply spacing as paragraphSpacing on the last paragraph of the accumulated result
            addSpacingAfterBlock(result, spacing: spacing)
            result.append(blockSeparator(height: spacing))
            result.append(current.attributed)
        }

        return RenderedBlock(
            attributed: result,
            topMargin: first.topMargin,
            bottomMargin: blocks.last?.bottomMargin
        )
    }

    private func blockSeparator(height: CGFloat) -> NSAttributedString {
        // Strategy: inject paragraphSpacing (after) on the previous block's trailing \n,
        // rather than trying to create an independent spacer paragraph.
        // This is handled by addSpacingAfterLastParagraph on the previous block.
        // Here we just return a plain \n to separate paragraphs.
        let separator = NSMutableAttributedString(string: "\n")
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        separator.addAttributes([
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: 1))
        return separator
    }

    /// Sets `paragraphSpacing` on the last paragraph of the attributed string
    /// so TextKit adds space after it.
    private func addSpacingAfterBlock(_ attrStr: NSMutableAttributedString, spacing: CGFloat) {
        guard attrStr.length > 0 else { return }
        // Find the last paragraph's range
        let text = attrStr.string as NSString
        let lastParaRange = text.paragraphRange(for: NSRange(location: max(text.length - 1, 0), length: 0))
        let style: NSMutableParagraphStyle
        if let existing = attrStr.attribute(.paragraphStyle, at: lastParaRange.location, effectiveRange: nil) as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.paragraphSpacing = spacing
        attrStr.addAttribute(.paragraphStyle, value: style, range: lastParaRange)
    }

    // MARK: Paragraph

    private func renderParagraph(_ inlines: [InlineNode], quoteDepth: Int) -> RenderedBlock {
        var baseAttrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        baseAttrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(inlines, baseAttributes: baseAttrs),
            topMargin: 0,
            bottomMargin: 12
        )
    }

    // MARK: Heading

    private func renderHeading(level: Int, content: [InlineNode], quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        attrs[.font] = theme.headingFont(level: level)
        let style = NSMutableParagraphStyle()
        // minisChat doesn't set relativeLineSpacing for headings
        style.lineSpacing = 0
        if quoteDepth > 0 {
            style.headIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel
            style.firstLineHeadIndent = style.headIndent
        }
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(content, baseAttributes: attrs),
            topMargin: headingTopMargin,
            bottomMargin: headingBottomMargin
        )
    }

    // MARK: Code Block (NSTextAttachment)

    private func renderCodeBlockAttachment(fenceInfo: String?, content: String, quoteDepth: Int = 0) -> RenderedBlock {
        // [T-ios-codeblock-default-text-lang] A fence with no info string (a bare
        // ``` block) has no language. Default it to "text" so every code block
        // shows a language label (and reserves the header space) uniformly —
        // an unlabeled block now reads as "text" instead of being blank.
        let parsedLang = fenceInfo?.split(separator: " ").first.map(String.init)
        let language = (parsedLang?.isEmpty == false) ? parsedLang : "text"
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let idx = codeBlockIndex
        codeBlockIndex += 1

        var hasher = Hasher()
        hasher.combine(trimmed)
        hasher.combine(language)
        let contentHash = hasher.finalize()

        let attachment: CodeBlockAttachment
        if let cached = codeBlockAttachmentCache[idx], codeBlockContentHashes[idx] == contentHash {
            // Exact same content — reuse object so TextKit skips attachmentBounds recalc
            cached.blockIndex = idx
            attachment = cached
        } else {
            // Content changed or first time — create fresh object so TextKit recalculates bounds.
            // The previous view will be updated in-place by updateAttachmentViews via codeBlockViewCache.
            attachment = CodeBlockAttachment(code: trimmed, language: language, theme: theme, quoteDepth: quoteDepth, contentFingerprint: contentHash)
            attachment.blockIndex = idx
            codeBlockAttachmentCache[idx] = attachment
            codeBlockContentHashes[idx] = contentHash
        }

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(
            attributed: result,
            topMargin: 6,
            bottomMargin: 4,
            isBlockAttachment: true
        )
    }

    // MARK: Blockquote

    private func renderBlockquote(children: [BlockNode], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        let newDepth = quoteDepth + 1
        let renderedChildren = renderBlockSequence(children, listDepth: listDepth, quoteDepth: newDepth, tightSpacing: false)
        let result = NSMutableAttributedString(attributedString: renderedChildren.attributed)
        // Mark the entire range with blockquote depth for bar drawing
        let fullRange = NSRange(location: 0, length: result.length)
        if fullRange.length > 0 {
            // Only fill in ranges that are missing a depth or carry a
            // shallower one. Children have already been rendered at
            // `newDepth + 1`…, so a blanket addAttribute (replace semantics)
            // used to stomp a nested quote's depth=2 back down to the outer
            // depth=1 — the text still indented for two levels (paragraph
            // style records that separately) but only one bar was drawn.
            var deeperRanges: [NSRange] = []
            result.enumerateAttribute(.blockquoteDepth, in: fullRange, options: []) { value, range, _ in
                let existing = (value as? Int) ?? 0
                if existing < newDepth { deeperRanges.append(range) }
            }
            for range in deeperRanges {
                result.addAttribute(.blockquoteDepth, value: newDepth, range: range)
            }
            // minisChat blockquote uses secondaryText color
            result.addAttribute(.foregroundColor, value: theme.secondaryLabelColor, range: fullRange)
        }
        // Blockquote inherits margins from children (no explicit markdownMargin in minisChat)
        return RenderedBlock(
            attributed: result,
            topMargin: renderedChildren.topMargin,
            bottomMargin: renderedChildren.bottomMargin
        )
    }

    // MARK: Bulleted List

    private func renderBulletedList(isTight: Bool, items: [RawListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        // HangFix(2026-05-13, re-restored 2026-05-14 with .ips evidence) —
        // Bullet glyphs MUST be Unicode characters, NOT NSTextAttachments.
        // Build 13 reverted bullets to SF-symbol NSTextAttachments per
        // user request to restore visual size — within 90s of install the
        // device hit a fresh 0x8BADF00D watchdog (ips Minis-2026-05-14-
        // 163330). Main-thread frame #1: `NSConcreteTextStorage
        // attribute:atIndex:effectiveRange:` — fillLayoutHole scanning
        // attribute runs. A 6-item list produces 6 image-attachment runs;
        // typesetter cost is O(glyphs × runs) and explodes whenever
        // setSize: forces a full re-layout.
        //
        // To keep bullets visually prominent (the original complaint about
        // "list got smaller") without paying the attachment-run tax, render the
        // Unicode glyph at 1.25× baseFont with bold weight + a small
        // baseline offset so it reads as an emphasized punctuation mark.
        // Depth → glyph:
        //   0  filled circle   "•"  U+2022
        //   1  hollow circle   "◦"  U+25E6
        //   2+ filled square   "▪"  U+25AA
        let bulletGlyph: String
        switch listDepth {
        case 0: bulletGlyph = "\u{2022}"   // •
        case 1: bulletGlyph = "\u{25E6}"   // ◦
        default: bulletGlyph = "\u{25AA}"  // ▪
        }
        let bulletColor = quoteDepth > 0 ? theme.secondaryLabelColor : theme.labelColor
        var bulletAttrs = baseAttributes(quoteDepth: quoteDepth)
        bulletAttrs[.foregroundColor] = bulletColor
        // 1.25× bold makes the Unicode bullet read at roughly the same
        // visual weight as the prior SF-symbol filled circle.
        bulletAttrs[.font] = UIFont.systemFont(ofSize: theme.baseFontSize * 1.25, weight: .bold)
        // Small negative baseline offset so the bullet sits near the
        // body text's x-height rather than its cap-height.
        bulletAttrs[.baselineOffset] = -theme.baseFontSize * 0.05

        for item in items {
            let itemResult = NSMutableAttributedString()
            itemResult.append(NSAttributedString(string: bulletGlyph, attributes: bulletAttrs))
            itemResult.append(NSAttributedString(string: "  ", attributes: baseAttributes(quoteDepth: quoteDepth)))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    // MARK: Numbered List

    private func renderNumberedList(isTight: Bool, start: Int, items: [RawListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        for (i, item) in items.enumerated() {
            let number = "\(start + i). "
            let itemResult = NSMutableAttributedString(string: number, attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    // MARK: Task List

    private func renderTaskList(isTight: Bool, items: [RawTaskListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        for item in items {
            let checkbox = item.isCompleted ? "☑ " : "☐ "
            let itemResult = NSMutableAttributedString(string: checkbox, attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    private func renderListItemChildren(_ children: [BlockNode], listDepth: Int, quoteDepth: Int, isTight: Bool) -> RenderedBlock {
        renderBlockSequence(children, listDepth: listDepth, quoteDepth: quoteDepth, tightSpacing: isTight)
    }

    private func applyListIndent(to attributed: NSMutableAttributedString, firstLineIndent: CGFloat, continuationIndent: CGFloat) {
        guard attributed.length > 0 else { return }

        let text = attributed.string as NSString
        let total = NSRange(location: 0, length: text.length)
        var cursor = total.location
        var isFirstParagraph = true

        while cursor < NSMaxRange(total) {
            let paragraphRange = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let effectiveRange = NSIntersectionRange(paragraphRange, total)
            guard effectiveRange.length > 0 else { break }

            let style: NSMutableParagraphStyle
            if let existing = attributed.attribute(.paragraphStyle, at: effectiveRange.location, effectiveRange: nil) as? NSParagraphStyle {
                style = existing.mutableCopy() as! NSMutableParagraphStyle
            } else {
                style = NSMutableParagraphStyle()
            }
            style.lineSpacing = max(style.lineSpacing, bodyLineSpacing)
            style.headIndent = max(style.headIndent, continuationIndent)
            if isFirstParagraph {
                style.firstLineHeadIndent = max(style.firstLineHeadIndent, firstLineIndent)
                isFirstParagraph = false
            } else {
                style.firstLineHeadIndent = max(style.firstLineHeadIndent, continuationIndent)
            }
            attributed.addAttribute(.paragraphStyle, value: style, range: effectiveRange)

            cursor = NSMaxRange(paragraphRange)
        }
    }

    // MARK: Table (NSTextAttachment)

    private func renderTableAttachment(alignments: [RawTableColumnAlignment], rows: [RawTableRow]) -> RenderedBlock {
        let idx = tableIndex
        tableIndex += 1

        var hasher = Hasher()
        hasher.combine(alignments)
        hasher.combine(rows)
        let contentHash = hasher.finalize()

        // [ios_session_open_last_cell_occluded] Slot key. The slot cache (Step 2
        // below) keeps a TableAttachment's identity stable while its content GROWS
        // during streaming, so a still-arriving table updates in place instead of
        // rebuilding every token. It must therefore be keyed by something that:
        //   (a) stays the SAME as one table streams in, but
        //   (b) DIFFERS between two genuinely distinct tables in the same message.
        //
        // The old key was "messageId:tableIndex". `tableIndex` resets to 0 at the
        // top of every `render(blocks:)` call — and in the V3 cell-per-block list
        // each assistant block (each table) is rendered by its OWN render() call,
        // so every table got tableIndex == 0. Two different tables in one message
        // therefore collided on "messageId:0", shared one attachment via Step 2,
        // and `update()`-overwrote each other → the on-screen table showed another
        // table's content (correct on first paint, swapped after a reuse pass):
        // two distinct tables in one message both keyed "<msgId>:0", same slot,
        // same shared TableAttachment, content flipping between them.
        //
        // Fix: always include tableIndex in the slot key. tableIndex
        // increments within a single render() call, so two tables in the
        // same block (same render pass) always get distinct keys — even if
        // their content is byte-for-byte identical.
        //
        // When blockId is available (V3 cell-per-block), include it to
        // also disambiguate tables across blocks that happen to share the
        // same tableIndex (e.g. each block's render() resets idx to 0).
        //
        // tableIndex resets per render() call, which is the right scope:
        // a streaming re-render of the same block sees the same table at
        // the same idx, so the slot key stays stable for in-place update.
        let slotKey = "\(messageId?.uuidString ?? "nil"):\(blockId?.uuidString ?? "_"):\(idx)"

        let attachment: TableAttachment
        // Step 1: same-content cache (any slot, any message). Lets the
        // SAME identical table that already lives in another cell share
        // its precomputed `cachedLayout` — the historical-message hang
        // fix from the 27s ips capture.
        if let cached = tableAttachmentCache[contentHash] {
            attachment = cached
            // Refresh LRU position.
            if let pos = tableAttachmentLRU.firstIndex(of: contentHash) {
                tableAttachmentLRU.remove(at: pos)
            }
            tableAttachmentLRU.append(contentHash)
            // Also pin this attachment to the current (message,slot) so
            // subsequent streaming growth at this slot updates it in
            // place rather than creating a new attachment instance.
            tableSlotCache[slotKey] = cached
            tableAttachmentReverseKey[ObjectIdentifier(cached)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE HIT rows=\(rows.count) cols=\(alignments.count) hash=\(contentHash)")
        } else if let slotAttachment = tableSlotCache[slotKey] {
            // Step 2: streaming growth — same (message,slot), new content
            // hash. Mutate in place to keep NSTextAttachment identity
            // stable so the updateUIView prefix-equality fast path stays
            // alive and updateAttachmentViews swaps only this attachment's
            // TableScrollView (not every attachment view in the cell).
            // Without this, every streamed token would rebuild every
            // attachment subview — flicker + O(N) work per flush.
            slotAttachment.update(alignments: alignments, rows: rows)
            attachment = slotAttachment
            // Re-key the by-content cache: drop the old hash entry (if
            // any), insert under the new hash, refresh LRU.
            if let oldHash = tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] {
                if let pos = tableAttachmentLRU.firstIndex(of: oldHash) {
                    tableAttachmentLRU.remove(at: pos)
                }
                tableAttachmentCache.removeValue(forKey: oldHash)
            }
            tableAttachmentCache[contentHash] = slotAttachment
            tableAttachmentLRU.append(contentHash)
            tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE UPDATE rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash)")
        } else {
            // Step 3: brand new — neither same content nor same slot
            // recognized. Create a fresh TableAttachment.
            attachment = TableAttachment(alignments: alignments, rows: rows, theme: theme)
            tableAttachmentCache[contentHash] = attachment
            tableAttachmentLRU.append(contentHash)
            tableSlotCache[slotKey] = attachment
            tableAttachmentReverseKey[ObjectIdentifier(attachment)] = contentHash
            // LRU evict — keep the by-content cache bounded.
            while tableAttachmentLRU.count > tableAttachmentCacheCap {
                let evict = tableAttachmentLRU.removeFirst()
                if let dropped = tableAttachmentCache.removeValue(forKey: evict) {
                    tableAttachmentReverseKey.removeValue(forKey: ObjectIdentifier(dropped))
                    // Drop matching slot entries that point at the same
                    // attachment we just evicted — keeps tableSlotCache
                    // consistent with tableAttachmentCache.
                    for (slot, att) in tableSlotCache where att === dropped {
                        tableSlotCache.removeValue(forKey: slot)
                    }
                }
            }
            Self.rendererLogger.info("[RND] table#\(idx) CACHE MISS rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash) cacheSize=\(tableAttachmentCache.count)")
        }

        // Wrap the table attachment with U+2028 (LINE SEPARATOR) on both
        // sides. This forces TextKit1 to place the attachment in its own
        // line fragment and prevents `_fillLayoutHole` from trying to merge
        // it with adjacent content. Without these separators, when a tall
        // table (observed at ≥ 9 rows ~ 400pt) arrives via streaming,
        // TextKit1's line-break-fitting routine enters an infinite loop
        // inside `_performTextKit1LayoutCalculation` and hangs the main
        // thread long enough to trip the 10s scene-update watchdog
        // (0x8BADF00D). The U+2028 wrap was verified to work around this
        // on iOS 26 TextKit1. Replace with TextKit2 long-term.
        let result = NSMutableAttributedString()
        let separatorPara = NSMutableParagraphStyle()
        separatorPara.paragraphSpacing = 0
        separatorPara.paragraphSpacingBefore = 0
        separatorPara.lineSpacing = 0
        // Tiny font collapses the U+2028 line fragment to ~0pt. The separator's
        // only job is to force TextKit1 to place the table attachment in its own
        // line fragment (workaround for the 9+-row _fillLayoutHole hang); it
        // should not contribute visible vertical space. Previously used
        // theme.baseFont (16.5pt), which ate ~20pt above and below every table.
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: separatorPara,
        ]
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        let attachPart = NSMutableAttributedString(attachment: attachment)
        attachPart.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: attachPart.length))
        result.append(attachPart)
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        return RenderedBlock(
            attributed: result,
            topMargin: theme.baseFontSize * 0.6,
            bottomMargin: theme.baseFontSize * 0.6,
            isBlockAttachment: true
        )
    }

    // MARK: Thematic Break (NSTextAttachment)

    private func renderThematicBreakAttachment() -> RenderedBlock {
        let attachment = ThematicBreakAttachment(theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(attributed: result, topMargin: 16, bottomMargin: 16, isBlockAttachment: true)
    }

    // MARK: HTML Block

    private func renderHTMLBlock(_ content: String, quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: NSAttributedString(string: content, attributes: attrs),
            topMargin: 0,
            bottomMargin: 16
        )
    }

    // MARK: Media Attachments (inline .image nodes rendered as block-level attachments)

    private func renderImageAttachment(source: String) -> NSAttributedString {
        let attachment: ImageAttachment
        if let cached = imageAttachmentCache[source] {
            AppLogger(category: "AttachHotPath").info("[IMG][RENDER] REUSE src=\(ImageAttachment.shortSrc(source)) ptr=\(ObjectIdentifier(cached).hashValue & 0xFFFFFF) loaded=\(cached.loadedImage != nil)")
            imgLogger.info("[MinisImage][RenderAttach] REUSE cached attachment src=\(source) loaded=\(cached.loadedImage != nil) imgSize=\(cached.loadedImage.map { "\($0.size.width)x\($0.size.height)" } ?? "nil")")
            // Keep messageId fresh on reused attachments — the same renderer
            // instance may survive across different messages during cell reuse.
            cached.messageId = messageId
            // Fingerprint check: if the underlying file has been rewritten
            // since we last loaded (size or mtime changed), drop the
            // cached bitmap so the next draw re-reads from disk.
            let currentFp = minisMediaCacheKey(for: source)
            if let loadedFp = cached.loadedFingerprint, loadedFp != currentFp {
                AppLogger(category: "AttachHotPath").info("[IMG][RENDER] FINGERPRINT-DROP src=\(ImageAttachment.shortSrc(source)) old=\(loadedFp) new=\(currentFp) — bitmap invalidated, will reload")
                imgLogger.info("[MinisImage][RenderAttach] FINGERPRINT CHANGED src=\(source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                cached.invalidateLoadedImage()
            }
            attachment = cached
        } else {
            AppLogger(category: "AttachHotPath").info("[IMG][RENDER] CREATE src=\(ImageAttachment.shortSrc(source)) cacheCount=\(self.imageAttachmentCache.count) — fresh ImageAttachment, ObjectIdentifier changed, view WILL be rebuilt")
            imgLogger.info("[MinisImage][RenderAttach] CREATE new ImageAttachment src=\(source) cacheCount=\(self.imageAttachmentCache.count)")
            attachment = ImageAttachment(source: source, theme: theme, messageId: messageId)
            imageAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func renderVideoAttachment(source: String) -> NSAttributedString {
        let attachment: VideoAttachment
        if let cached = videoAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = VideoAttachment(source: source, theme: theme)
            videoAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func renderAudioAttachment(source: String) -> NSAttributedString {
        let attachment: AudioAttachment
        if let cached = audioAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = AudioAttachment(source: source, theme: theme)
            audioAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Inline Rendering

    /// Build the URL stored in a markdown link's `.link` attribute, undoing a
    /// double percent-encoding when present.
    ///
    /// [T-ios-file-preview-stale-cache] file_write returns a singly-encoded
    /// minis_url (e.g. `minis://workspace/GitHub%E7%83%AD….md`). When the model
    /// embeds it in `[text](url)` and it passes through the markdown render
    /// pipeline, the literal `%` can get re-encoded to `%25`, yielding a
    /// double-encoded destination (`…%25E7…`). `URL(string:).path` then only
    /// peels one layer, leaving `%E7…`, which matches no file on disk — so the
    /// tap falls through to the parent workspace folder (the reported `.bin`
    /// folder symptom) instead of previewing the file. Detect that case and
    /// decode one extra layer before building the URL, so the `.link` carries
    /// the correct singly-encoded URL the tap handler / resolver expects. The
    /// resolver-side `subPathCandidates` tolerance stays as a backstop.
    private func normalizedLinkURL(from destination: String) -> URL? {
        let fallback = URL(string: destination)
        // Only minis:// links are affected; everything else is untouched.
        guard destination.hasPrefix("minis://") else {
            return fallback
        }
        // [T-minis-url-fullwidth-pipe-ios] URL(string:) returned nil — on iOS
        // Foundation this happens when the destination carries raw non-ASCII in
        // the path (e.g. a filename with U+FF5C `｜`, CJK, emoji that the LLM
        // emitted unencoded inside a minis:// link). The link would otherwise be
        // dead (no .link attribute → not tappable). Percent-encode the path
        // portion segment-by-segment and retry. Idempotent: a segment that is
        // ALREADY validly encoded is left untouched, so an already-%EF%BD%9C URL
        // is never double-encoded (it also wouldn't reach here, since URL(string:)
        // accepts it — this is belt-and-suspenders).
        guard let base = fallback else {
            return encodeRawMinisURL(destination)
        }
        // A correctly singly-encoded minis_url decodes cleanly: `base.path`
        // contains no stray `%`. A double-encoded one (`%25E7…`) peels only one
        // layer here, leaving a literal `%E7…` in `.path`. That residual `%` is
        // the double-encoding signal — decode one more layer. A filename that
        // legitimately contains `%` is recovered to the same path either way
        // (the `%XX` of a real byte can't reappear), and the resolve-time
        // existence check (subPathCandidates) remains the final disambiguator.
        guard base.path.contains("%"),
              let once = destination.removingPercentEncoding,
              once.hasPrefix("minis://"),
              let fixed = URL(string: once) else {
            return base
        }
        return fixed
    }


    private func renderInlines(_ inlines: [InlineNode], baseAttributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (i, inline) in inlines.enumerated() {
            // [T-md-image-own-line] An image written on its own line under a caption
            // ("**① Title**\n![](…)") is one paragraph joined by a soft break, which
            // renders as a space. On a phone the image never fits beside the text, so
            // it wrapped onto its own line; at iPad width it fits, and sat beside the
            // caption on the caption's baseline — at an x that varied with the
            // caption's length. A soft break touching an image becomes a line
            // separator (U+2028: new line, same paragraph, no paragraph spacing), so
            // images always start their own line, left-aligned, at any width.
            if case .softBreak = inline, Self.isImage(at: i - 1, in: inlines) || Self.isImage(at: i + 1, in: inlines) {
                result.append(NSAttributedString(string: "\u{2028}", attributes: attrs))
                continue
            }
            result.append(renderInline(inline, attributes: attrs))
        }
        return result
    }

    private static func isImage(at index: Int, in inlines: [InlineNode]) -> Bool {
        guard inlines.indices.contains(index), case .image = inlines[index] else { return false }
        return true
    }

    /// [T-ios-inline-code-long-path-wrap] Insert zero-width spaces after the
    /// separators inside an inline code span so TextKit can wrap a long token.
    ///
    /// Problem: a path like `/tmp/project_release_checklist_draft_2026.md` is
    /// a single unbreakable "word" under `.byWordWrapping` except at `/`. On a
    /// narrow screen TextKit therefore breaks after `/tmp/` — leaving half the
    /// first line empty and a full-width background pill around four visible
    /// characters — and then, since the 45-char remainder still overflows, it
    /// falls back to breaking mid-token, stranding a character or two on a
    /// third line. That is exactly the reported rendering.
    ///
    /// Fix: give TextKit legal break opportunities at the separators a reader
    /// already perceives as segment boundaries (`/ _ - .`), so a long span
    /// fills each line and breaks where a human would. U+200B is zero-width, so
    /// the rendered span is pixel-identical when it does NOT need to wrap —
    /// verified equal to 3 decimal places against the unmodified string — and
    /// short spans keep laying out on one line exactly as before.
    ///
    /// Copy safety: `plainTextWithTables` (the single choke point for selection
    /// copy, Read Selection and Add to Chat Input) already strips U+200B and
    /// U+200A, because the CJK emphasis pre-pass [T-md-cjk-emphasis-pairs]
    /// injects the same character. Tap-to-copy is unaffected either way — it
    /// reads the pristine string from `.inlineCodeText`, which is deliberately
    /// still set from the ORIGINAL `code`, not this padded form.
    ///
    /// Scope: body inline code only. Table-cell inline code (`renderCellInline`)
    /// is left alone — cell width is driven by measured content rather than a
    /// fixed container, so it has neither the symptom nor the same wrap model.
    static func breakableInlineCode(_ code: String) -> String {
        // Nothing to gain on spans that cannot overflow a line; skip the work
        // and keep the string byte-identical for the overwhelmingly common case.
        guard code.count > 24 else { return code }
        var out = ""
        out.reserveCapacity(code.count * 2)
        for ch in code {
            out.append(ch)
            // Only after a separator, never before: breaking before `/` would
            // orphan the separator onto the next line, which reads worse.
            if ch == "/" || ch == "_" || ch == "-" || ch == "." {
                out.append("\u{200B}")
            }
        }
        return out
    }

    private func renderInline(_ node: InlineNode, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attrs)

        case .code(let code):
            var codeAttrs = attrs
            // [T-md-inline-code-context-font] Scale to the surrounding font
            // (heading vs body) and center the code span's x-height on the
            // context's x-height — Menlo's x-height ratio differs from SF's,
            // so pure baseline alignment reads visually low in big headings.
            let contextFont = attrs[.font] as? UIFont
            let codeFont = theme.inlineCodeFont(matching: contextFont)
            codeAttrs[.font] = codeFont
            if let ctx = contextFont {
                let offset = (ctx.xHeight - codeFont.xHeight) / 2
                if abs(offset) > 0.25 { codeAttrs[.baselineOffset] = offset }
            }
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.inlineCodeText] = code
            // Set .backgroundColor to trigger fillBackgroundRectArray in MinisLayoutManager
            // The actual color is drawn there with rounded corners; this just triggers the callback.
            codeAttrs[.backgroundColor] = theme.inlineCodeBackground
            // Add hair spaces for visual padding inside the background highlight.
            // (In Menlo U+200A is a full 0.6em cell, so this is ~8pt a side.)
            let span = NSAttributedString(string: "\u{200A}\(Self.breakableInlineCode(code))\u{200A}",
                                          attributes: codeAttrs)
            // [T-ios-inline-code-pad-gap] A full-width punctuation mark
            // ("：", "，") directly followed by the Menlo run makes TextKit
            // (iOS 26.5 and macOS 27, measured) squeeze the mark to half width
            // (16.4 -> 8.3pt) and add ~7pt to the LAST glyph of the code run,
            // so the chip sits in a ~21pt gap instead of ~13pt. One hair
            // space in the surrounding font between them stops it (0.8pt);
            // a zero-width character does not. It carries no code attributes,
            // so the pill and tap-to-copy are unchanged, and copy / search
            // already drop U+200A.
            let joined = NSMutableAttributedString(string: "\u{200A}", attributes: attrs)
            joined.append(span)
            return joined

        case .emphasis(let children):
            var emphAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                emphAttrs[.font] = font.withTraits(.traitItalic)
            }
            return renderInlines(children, baseAttributes: emphAttrs)

        case .strong(let children):
            var strongAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                let descriptor = font.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
                ])
                strongAttrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            return renderInlines(children, baseAttributes: strongAttrs)

        case .strikethrough(let children):
            var strikeAttrs = attrs
            strikeAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children, baseAttributes: strikeAttrs)

        case .link(let destination, let children):
            var linkAttrs = attrs
            if let url = normalizedLinkURL(from: destination) {
                linkAttrs[.link] = url
            }
            linkAttrs[.foregroundColor] = theme.linkColor
            linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children, baseAttributes: linkAttrs)

        case .image(let source, let children):
            let ext = URL(string: source)?.pathExtension.lowercased() ?? ""
            let altText = children.plainText
            imgLogger.info("[MinisImage][InlineParse] .image node src=\(source) ext=\(ext) alt=\(altText)")
            if nativeAudioExts.contains(ext) {
                return renderAudioAttachment(source: source)
            } else if nativeVideoExts.contains(ext) {
                return renderVideoAttachment(source: source)
            } else if nativeImageExts.contains(ext) || ext.isEmpty {
                imgLogger.info("[MinisImage][InlineParse] routing to IMAGE attachment src=\(source)")
                return renderImageAttachment(source: source)
            } else {
                // Unknown extension — render as image attachment (best guess)
                imgLogger.info("[MinisImage][InlineParse] unknown ext=\(ext), routing to IMAGE attachment (best guess) src=\(source)")
                return renderImageAttachment(source: source)
            }

        case .html(let html):
            return NSAttributedString(string: html, attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)

        case .inlineMath(let latex):
            return renderInlineMathAttachment(latex: latex)
        }
    }

    // MARK: Helpers

    /// Per-depth indent: 3pt bar + 10pt leading padding (matches minisChat blockquote padding)
    private static let quoteIndentPerLevel: CGFloat = 13
    private static let listIndentPerLevel: CGFloat = 24

    private func baseAttributes(quoteDepth: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.baseFont,
            .foregroundColor: quoteDepth > 0 ? theme.secondaryLabelColor : theme.labelColor,
        ]
        if quoteDepth > 0 {
            attrs[.blockquoteDepth] = quoteDepth
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineSpacing = bodyLineSpacing
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    // MARK: Math Attachments

    private func renderMathBlockAttachment(latex: String) -> RenderedBlock {
        let key = "D:\(Int(theme.baseFontSize)):" + latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex, isBlock: true, theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(attributed: result, topMargin: bodyLineSpacing, bottomMargin: bodyLineSpacing, isBlockAttachment: true)
    }

    private func renderInlineMathAttachment(latex: String) -> NSAttributedString {
        let key = "I:\(Int(theme.baseFontSize)):" + latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex, isBlock: false, theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }
}
