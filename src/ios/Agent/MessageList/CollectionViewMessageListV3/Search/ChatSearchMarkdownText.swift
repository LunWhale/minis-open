//
//  ChatSearchMarkdownText.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] The text an assistant reply SHOWS, worked out from its
//  parsed markdown without rendering it - so "Search in Chat" can search every
//  reply, including the ones no cell has drawn yet, on a background thread.
//
//  It mirrors MarkdownNSRenderer piece by piece: the same paragraph separator,
//  list bullets, numbers and checkboxes, link text without its URL, inline
//  code without the backticks. The renderer turns code blocks and tables into
//  attachments drawn by their own views; here they contribute their visible
//  text (the code; the cells), and the other attachments (images, math, rules)
//  contribute nothing. The cell's highlighter rebuilds the same string from
//  the attributed string it displays (SelectableMarkdownTextView+SearchHighlight)
//  using `normalized` and `tableText` below, so occurrence N here is occurrence
//  N there.
//
//  Depends only on BlockNode / InlineNode (Agent/Markdown/MinisMarkdownParser);
//  MinisTests/Standalone/ChatSearchEngineTests compiles it against those types.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import Foundation

// BEGIN chat-search-markdown-text

enum ChatSearchMarkdownText {
    /// Visible text of `blocks`, plus a streaming reply's not-yet-parsed tail
    /// (`splitStreamingTableTail`'s plain suffix, which the view appends to
    /// the rendered body as plain text).
    static func text(blocks: [BlockNode], plainSuffix: String = "") -> String {
        var out = ""
        appendSequence(blocks, listDepth: 0, to: &out)
        if !plainSuffix.isEmpty { appendNormalized(plainSuffix, to: &out) }
        return out
    }

    /// Characters the renderer inserts that no reader sees, and their stand-in
    /// in search text: zero-width and hair spaces (CJK emphasis fix, breakable
    /// inline code, inline code padding) vanish; a line separator (around
    /// tables, beside images) reads as a line break; the attachment character
    /// itself is replaced by the attachment's text by the caller.
    static func normalizedScalar(_ s: Unicode.Scalar) -> Unicode.Scalar?? {
        switch s.value {
        case 0x200B, 0x200A, 0xFFFC: return .some(nil)
        case 0x2028: return .some("\n")
        default: return nil
        }
    }

    /// `text` with the invisible characters above removed / mapped.
    static func appendNormalized(_ text: String, to out: inout String) {
        var scalars = String.UnicodeScalarView()
        var changed = false
        for s in text.unicodeScalars {
            if let mapped = normalizedScalar(s) {
                changed = true
                if let m = mapped { scalars.append(m) }
            } else {
                scalars.append(s)
            }
        }
        out += changed ? String(scalars) : text
    }

    static func normalized(_ text: String) -> String {
        var out = ""
        appendNormalized(text, to: &out)
        return out
    }

    /// A table's visible text: cells separated by a tab, rows by a newline.
    /// Used for the renderer's TableAttachment by both sides.
    static func tableText(rows: [RawTableRow], columnCount: Int) -> String {
        rows.map { row in
            row.cells.prefix(columnCount).map { normalized(inlineText($0.content)) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// A code block's visible text: its content without the final newline
    /// (MarkdownNSRenderer.renderCodeBlockAttachment trims it the same way).
    static func codeText(_ content: String) -> String {
        content.hasSuffix("\n") ? String(content.dropLast()) : content
    }

    /// Inline text as the renderer writes it, before normalisation.
    static func inlineText(_ inlines: [InlineNode]) -> String {
        var out = ""
        for (i, node) in inlines.enumerated() {
            switch node {
            case .text(let t): out += t
            case .code(let c): out += c
            case .emphasis(let ch), .strong(let ch), .strikethrough(let ch), .link(_, let ch):
                out += inlineText(ch)
            case .image, .inlineMath:
                // Drawn by an attachment with no text form.
                break
            case .html(let h): out += h
            case .softBreak:
                // [T-md-image-own-line] A soft break touching an image becomes
                // a line separator in the renderer.
                out += isImage(at: i - 1, in: inlines) || isImage(at: i + 1, in: inlines) ? "\n" : " "
            case .lineBreak: out += "\n"
            }
        }
        return out
    }

    private static func isImage(at index: Int, in inlines: [InlineNode]) -> Bool {
        guard inlines.indices.contains(index), case .image = inlines[index] else { return false }
        return true
    }

    private static func appendSequence(_ blocks: [BlockNode], listDepth: Int, to out: inout String) {
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += "\n" }
            appendBlock(block, listDepth: listDepth, to: &out)
        }
    }

    private static func appendBlock(_ block: BlockNode, listDepth: Int, to out: inout String) {
        switch block {
        case .paragraph(let content), .heading(_, let content):
            appendNormalized(inlineText(content), to: &out)
        case .codeBlock(_, let content):
            out += codeText(content)
        case .blockquote(let children):
            appendSequence(children, listDepth: listDepth, to: &out)
        case .bulletedList(_, let items):
            // Same glyphs by depth as renderBulletedList.
            let glyph: String
            switch listDepth {
            case 0: glyph = "\u{2022}"
            case 1: glyph = "\u{25E6}"
            default: glyph = "\u{25AA}"
            }
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += glyph + "  "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .numberedList(_, let start, let items):
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += "\(start + i). "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .taskList(_, let items):
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += item.isCompleted ? "\u{2611} " : "\u{2610} "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .table(let alignments, let rows):
            // U+2028 + attachment + U+2028 in the renderer.
            out += "\n" + tableText(rows: rows, columnCount: alignments.count) + "\n"
        case .thematicBreak, .mathBlock:
            break
        case .htmlBlock(let content):
            appendNormalized(content, to: &out)
        }
    }
}

// END chat-search-markdown-text
