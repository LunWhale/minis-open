//
//  SelectableMarkdownTextView+EditMenu.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: TextKit - SelectableMarkdownTextView, edit menu.
//
//  canPerformAction filtering, the menu actions (Copy Markdown, rich text,
//  full text, Share, Add to Chat Input, Read Aloud / Read Selection) and
//  buildMenu, which swaps the system speech items for the Minis TTS ones.
//  The read-aloud closures are stored in the core file.
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
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // Block edit-related actions since we're read-only; allow everything else
        // (select, copy, look up, share, Copy Markdown, etc.)
        let blocked: Set<String> = ["paste:", "cut:", "delete:", "_addShortcut:"]
        if blocked.contains(NSStringFromSelector(action)) {
            return false
        }
        // iOS 16: long-pressing inline NSTextAttachment objects that carry a
        // transparent placeholder UIImage (TableAttachment, CodeBlockAttachment,
        // MathAttachment, etc.) makes the system add "Copy Image" / "Save
        // Image" / "Share Image" entries to UIMenuController. The image is a
        // 1×1 transparent placeholder used so UIKit doesn't render a default
        // "?" glyph — copying it is meaningless. Filter the relevant
        // selectors so the menu only surfaces actions that work on the
        // underlying text. iOS 17+ uses UIEditMenuInteraction and doesn't
        // present these by default.
        let actionName = NSStringFromSelector(action)
        if actionName.localizedCaseInsensitiveContains("image") {
            return false
        }
        // [T-multi-select-share] The system share item (pre-iOS 16 edit menu path).
        if actionName == "_share:" || actionName == "share:" {
            return false
        }
        if action == #selector(copyMarkdown(_:))
            || action == #selector(copyRichText(_:))
            || action == #selector(shareMessagesFromMenu(_:)) {
            return true
        }
        if action == #selector(searchInChatFromMenu(_:)) {
            return onSearchInChat != nil
        }
        if action == #selector(addSelectionToChatInput(_:)) {
            return selectedRange.length > 0
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Append the currently-selected text to the active chat's input field
    /// via the `chatInputAppendRequested` notification. AIChatView listens
    /// and routes to `AIChatViewModel.appendToInputText`, which handles the
    /// `<existing> <selected> ` / `<selected> ` formatting.
    @objc func addSelectionToChatInput(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        // [T-selection-add-to-input-attachments] Code blocks, tables and math
        // are NSTextAttachments, so `text` holds only a U+FFFC per block and
        // the input bar received nothing for them. Expand them the same way
        // Copy does (which also strips the inline-code / CJK spacers).
        let snippet = plainTextWithTables(in: selectedRange)
        NotificationCenter.default.post(
            name: .chatInputAppendRequested,
            object: nil,
            userInfo: ["text": snippet]
        )
        // Drop the selection / dismiss the edit menu so the user sees the
        // result land in the input. Mirrors the system Copy behaviour.
        resignFirstResponder()
    }

    /// Copies the raw Markdown source to the pasteboard.
    @objc func copyMarkdown(_ sender: Any?) {
        // [T-ios-math-copy-latex-delimiters] Normalize LaTeX delimiters to the
        // $...$ / $$...$$ form that most LaTeX editors expect. LLM output often
        // uses the \(...\) / \[...\] alternate delimiters which are valid LaTeX
        // but not recognized by many markdown renderers.
        var md = rawMarkdown
        md = md.replacingOccurrences(of: "\\(", with: "$")
        md = md.replacingOccurrences(of: "\\)", with: "$")
        md = md.replacingOccurrences(of: "\\[", with: "$$")
        md = md.replacingOccurrences(of: "\\]", with: "$$")
        UIPasteboard.general.string = md
    }

    /// Override the standard Copy so selections spanning tables include table
    /// cell text instead of a single space (the default attachment fallback).
    override func copy(_ sender: Any?) {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: attributedText.length)
        UIPasteboard.general.string = plainTextWithTables(in: range)
    }

    /// Invokes the Share… closure plumbed through from SwiftUI.
    @objc func shareMessagesFromMenu(_ sender: Any?) {
        onShareMessages?()
    }

    /// [T-in-chat-search] Opens the chat's search bar. A selection becomes the
    /// query - its first line, at most 100 characters, so selecting a whole
    /// paragraph does not paste the paragraph into the search field.
    @objc func searchInChatFromMenu(_ sender: Any?) {
        var prefill: String?
        if selectedRange.length > 0 {
            let selected = plainTextWithTables(in: selectedRange, includeCode: true)
            let firstLine = selected.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            prefill = trimmed.isEmpty ? nil : String(trimmed.prefix(100))
        }
        let callback = onSearchInChat
        resignFirstResponder()
        callback?(prefill)
    }

    // MARK: - [T-selection-menu-minis-tts] Minis TTS menu actions

    @objc func readReplyFromMenu(_ sender: Any?) {
        onReadAloud?()
    }

    @objc func readSelectionFromMenu(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        // plainTextWithTables expands table/math attachments into speakable text.
        // Code blocks stay silent, as before: reading source aloud is noise.
        onSpeakText?(plainTextWithTables(in: selectedRange, includeCode: false))
    }

    /// Copies the rendered rich text (RTF) to the pasteboard.
    @objc func copyRichText(_ sender: Any?) {
        let range = selectedRange.length > 0 ? selectedRange : NSRange(location: 0, length: attributedText.length)
        let subAttr = attributedText.attributedSubstring(from: range)
        if let rtfData = try? subAttr.data(from: NSRange(location: 0, length: subAttr.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            UIPasteboard.general.setData(rtfData, forPasteboardType: "public.rtf")
        }
        // Also write plain-text fallback that includes table cell content (the
        // RTF substring's NSTextAttachment for tables collapses to a space when
        // pasted into plain-text targets).
        UIPasteboard.general.string = plainTextWithTables(in: range)
    }

    /// [T-ios-copy-full-scope] Whole-reply rich text.
    ///
    /// Separate from `copyRichText` rather than a parameter on it: that one is
    /// selection-aware by design (it backs the standard selection copy path and
    /// falls back to the full range only when nothing is selected). The "Copy
    /// Full Reply" submenu promises the entire reply regardless of what happens
    /// to be highlighted, so it must not consult `selectedRange` at all —
    /// reusing the old method would have silently copied just the selection
    /// whenever the long-press left one behind, which is the exact confusion
    /// this menu was restructured to remove.
    @objc func copyFullRichText(_ sender: Any?) {
        let full = NSRange(location: 0, length: attributedText.length)
        let subAttr = attributedText.attributedSubstring(from: full)
        if let rtfData = try? subAttr.data(from: NSRange(location: 0, length: subAttr.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            UIPasteboard.general.setData(rtfData, forPasteboardType: "public.rtf")
        }
        // Plain-text fallback for targets that ignore RTF (same reason as
        // copyRichText: a table's NSTextAttachment collapses to a space).
        UIPasteboard.general.string = plainTextWithTables(in: full)
    }

    /// [T-ios-copy-full-scope] Whole reply as plain text: paragraph structure
    /// only, no markdown syntax.
    ///
    /// This is the RENDERED text, not `rawMarkdown` with the markup stripped.
    /// The distinction matters — the attributed string is what the user is
    /// looking at, so headings, list items and blockquotes arrive as the lines
    /// they appear to be, with no `#`, `-`, `**` or `>` to clean up. Tables and
    /// math still expand through `plainTextWithTables` (tab-separated cells,
    /// `$…$` for formulae) because dropping them entirely would lose content
    /// rather than formatting.
    @objc func copyFullPlainText(_ sender: Any?) {
        let full = NSRange(location: 0, length: attributedText.length)
        UIPasteboard.general.string = plainTextWithTables(in: full)
    }

    /// Returns the plain-text representation of `range`, expanding any
    /// `TableAttachment` runs into tab-separated cell text so multi-block
    /// selections that span a table preserve table content on copy.
    private func plainTextWithTables(in range: NSRange, includeCode: Bool = true) -> String {
        SelectionTextExpander.expand(attributedText ?? NSAttributedString(), in: range, includeCode: includeCode)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // [T-selection-menu-minis-tts] Remove the SYSTEM speech menu ("Speak…"
        // / "Spell") — it reads with the OS voice, bypassing the Minis TTS
        // stack (provider voices, sanitizer, fail-over). Replaced below with
        // our own Read Selection / Read Reply entries.
        builder.remove(menu: .speech)
        // [T-multi-select-share] Remove the SYSTEM "Share" (共享) entry: sharing a
        // reply goes through "Share Chat…" (the picker), and two share items side
        // by side read as the same action.
        builder.remove(menu: .share)
        // [T-ios-copy-full-scope] Scope first, format second.
        //
        // This menu is raised by a long-press that usually ALSO produces a
        // selection, and it sits beside "Read Selection" — so a top-level
        // "Copy Markdown" reads as "copy what I highlighted" when it actually
        // copies the whole reply. Putting the formats behind one "Copy Full
        // Reply" entry states the scope ONCE, in the item the user taps first,
        // and leaves the submenu free to talk only about format. It also keeps
        // the top level short: three format entries inline would crowd out
        // Add to Chat Input / the read-aloud pair.
        let copyFull = UIMenu(
            title: AppLocalized("Copy Full Reply"),
            image: UIImage(systemName: "doc.on.doc"),
            children: [
                UICommand(
                    title: AppLocalized("Copy as Markdown"),
                    image: UIImage(systemName: "text.quote"),
                    action: #selector(copyMarkdown(_:))
                ),
                UICommand(
                    title: AppLocalized("Copy as Rich Text"),
                    image: UIImage(systemName: "doc.richtext"),
                    action: #selector(copyFullRichText(_:))
                ),
                UICommand(
                    title: AppLocalized("Copy as Plain Text"),
                    image: UIImage(systemName: "text.alignleft"),
                    action: #selector(copyFullPlainText(_:))
                ),
            ]
        )
        var extras: [UIMenuElement] = [copyFull]
        // [T-selection-menu-minis-tts] Minis-owned read-aloud entries. "Read
        // Selection" speaks just the selected range; "Read from Start" replays
        // the whole reply — both through the in-app TTS stack.
        // Matching speaker glyph family so the two read-aloud entries read as
        // one feature: selection = plain speaker, whole reply = speaker+waves.
        if selectedRange.length > 0, onSpeakText != nil {
            extras.append(UICommand(
                title: AppLocalized("Read Selection"),
                image: UIImage(systemName: "speaker.wave.1"),
                action: #selector(readSelectionFromMenu(_:))
            ))
        }
        if onReadAloud != nil {
            extras.append(UICommand(
                title: AppLocalized("Read from Start"),
                image: UIImage(systemName: "speaker.wave.2"),
                action: #selector(readReplyFromMenu(_:))
            ))
        }
        let extrasMenu = UIMenu(title: "", options: .displayInline, children: extras)
        // insertSibling(afterMenu: .standardEdit) pushes successive inserts
        // toward the anchor — i.e. the LAST inserted sibling lands closest to
        // standardEdit. Insert the secondary copy commands first so the
        // high-frequency "Add to Chat Input" action ends up immediately after
        // the system Copy item.
        builder.insertSibling(extrasMenu, afterMenu: .standardEdit)
        if selectedRange.length > 0 {
            let addToInput = UIMenu(title: "", options: .displayInline, children: [
                UICommand(
                    title: AppLocalized("Add to Chat Input"),
                    image: UIImage(systemName: "text.insert"),
                    action: #selector(addSelectionToChatInput(_:))
                )
            ])
            builder.insertSibling(addToInput, afterMenu: .standardEdit)
        }
        // [T-multi-select-share] "Share Chat…" is the menu's LAST item, where the
        // system's Writing Tools entry used to be (disabled on the view via
        // writingToolsBehavior = .none, which keeps it out of this menu).
        // [T-in-chat-search] "Search in Chat" sits with "Share Chat…": both act
        // on the whole conversation rather than on the selection.
        var chatWide: [UIMenuElement] = []
        if onSearchInChat != nil {
            chatWide.append(UICommand(
                title: AppLocalized("Search in Chat"),
                image: UIImage(systemName: "magnifyingglass"),
                action: #selector(searchInChatFromMenu(_:))
            ))
        }
        if onShareMessages != nil {
            chatWide.append(UICommand(
                title: AppLocalized("Share Chat…"),
                image: UIImage(systemName: "square.and.arrow.up"),
                action: #selector(shareMessagesFromMenu(_:))
            ))
        }
        if !chatWide.isEmpty {
            builder.insertChild(UIMenu(title: "", options: .displayInline, children: chatWide), atEndOfMenu: .root)
        }
    }
}
