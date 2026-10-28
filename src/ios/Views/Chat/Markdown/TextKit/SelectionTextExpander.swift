//
//  SelectionTextExpander.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit.
//
//  Plain-text form of a rendered range, for Copy, Read Selection and Add to
//  Chat Input. Attachment characters (U+FFFC) are expanded: tables as
//  tab-separated cells, math as $...$ / $$...$$, code blocks as fenced blocks;
//  media has no text form and is dropped. A new attachment kind that has a
//  text form needs a case here.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

/// Plain-text form of a rendered markdown range, for Copy, Read Selection and
/// Add to Chat Input. Block content is drawn by NSTextAttachments, whose
/// characters in the string are a lone U+FFFC, so each kind is expanded here:
/// tables as tab-separated cells, math as `$…$` / `$$…$$`, code blocks as a
/// fenced block (optional: TTS skips them). Any other attachment (image,
/// video, audio, rule) has no text form and is dropped rather than leaking
/// U+FFFC into the clipboard or the input bar.
enum SelectionTextExpander {
    static func expand(_ attr: NSAttributedString, in range: NSRange, includeCode: Bool) -> String {
        guard range.location >= 0, NSMaxRange(range) <= attr.length else {
            return attr.string
        }
        var out = ""
        var afterFence = false
        attr.enumerateAttribute(.attachment, in: range, options: []) { value, subRange, _ in
            // The closing fence must end its line: break before whatever
            // follows unless that already starts with a newline.
            if afterFence {
                afterFence = false
                let next = value == nil ? (attr.string as NSString).substring(with: subRange) : ""
                if !next.hasPrefix("\n") { out += "\n" }
            }
            if let table = value as? TableAttachment {
                out += table.plainText()
            } else if let math = value as? MathAttachment {
                // [T-ios-math-copy-latex-delimiters] Emit LaTeX with $...$ / $$...$$.
                if math.isBlock {
                    out += "$$\(math.latex)$$"
                } else {
                    out += "$\(math.latex)$"
                }
            } else if let code = value as? CodeBlockAttachment {
                guard includeCode else { return }
                // [T-selection-add-to-input-attachments] A fence needs its own
                // lines; the attachment usually sits after a newline already.
                if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
                out += fenced(code.code, language: code.language)
                afterFence = true
            } else if value != nil {
                return
            } else {
                out += (attr.string as NSString).substring(with: subRange)
            }
        }
        // [T-md-cjk-emphasis-pairs] Strip the invisible spacers the markdown
        // pre-pass injects to fix CommonMark flanking around CJK punctuation
        // (ZWSP now; hair space from the pre-2026-05 fixers may survive in
        // cached attributed strings) — they must not leak into the clipboard
        // or the TTS text.
        return out
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200A}", with: "")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// Fence longer than any backtick run inside the code, so the block cannot
    /// be closed early by its own content.
    static func fenced(_ code: String, language: String?) -> String {
        var longest = 0, run = 0
        for ch in code {
            run = ch == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = code.hasSuffix("\n") ? code : code + "\n"
        return "\(fence)\(language ?? "")\n\(body)\(fence)"
    }
}
