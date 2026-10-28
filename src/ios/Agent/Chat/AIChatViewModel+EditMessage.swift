//
//  AIChatViewModel+EditMessage.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, editing: append to the input text, edit / cancel editing a
//  sent message, and locating / cutting at a user bubble (UserBubbleSpan,
//  cutAtUserBubble) - the cut retry and edit share.
//
//  Map of the AIChatViewModel files: AIChatViewModel.swift.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {
    /// Append text to the chat input, separated by a single space on each side
    /// of an existing draft so quoted snippets stay visually distinct. A
    /// trailing space is always appended so the caret lands after a separator
    /// when the input regains focus. Whitespace-only inserts are dropped.
    ///
    /// Wired up to the `chatInputAppendRequested` notification posted by the
    /// long-press selection menu's "Add to Chat Input" action across markdown
    /// bubbles, table cells, etc.
    func appendToInputText(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // [T-ios-append-to-input-eats-draft] Trim the incoming SNIPPET only.
        // The old code trimmed `inputText` too and assigned the trimmed copy
        // back, so "Add to input" silently rewrote the user's existing draft:
        // a deliberate trailing newline (paragraph break they had just typed)
        // was swallowed and replaced by the separator space. The draft is the
        // user's own text and must come back byte-for-byte.
        //
        // The emptiness test still runs on a trimmed view — a draft of only
        // whitespace should be treated as empty rather than producing a
        // leading blank run — but that trimmed value is used for the decision
        // ONLY, never for the assignment.
        // [T-selection-add-to-input-attachments] A snippet that opens or closes
        // with a code fence must keep the fence on its own line, or the draft
        // text glued onto it turns the block back into inline text.
        let startsWithFence = trimmed.hasPrefix("```")
        let tail = trimmed.hasSuffix("```") ? "\n" : " "
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = trimmed + tail
        } else {
            // Preserve the draft verbatim; only add a separator when it does
            // not already end in whitespace (a trailing newline is already a
            // separator, and appending a space after it would re-indent the
            // new line).
            let separator: String
            if startsWithFence {
                separator = inputText.hasSuffix("\n") ? "" : "\n"
            } else {
                separator = (inputText.last?.isWhitespace ?? false) ? "" : " "
            }
            inputText += separator + trimmed + tail
        }
    }

    /// Populate the input bar with the content of a user message for editing.
    /// The next call to send() will truncate the conversation from this message
    /// and re-run the agent loop with the edited content.
    func editMessage(_ messageId: UUID) {
        guard !isProcessing else { return }
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].role == .user else { return }

        let msg = messages[idx]

        // Strip <user-attached-files> XML from content to get clean user text
        let text = Self.editableText(of: msg.content)

        // [T-paste-mediaref] Re-hydrate pasted content into the draft.
        //
        // Since the paste is stored as a `.mediaRef` and the `[Pasted#N]`
        // literal is NOT kept in the stored `.text`, `msg.content` carries only
        // the surrounding prose. Editing such a message would therefore drop
        // the pasted content entirely — the user edits one sentence and
        // silently loses the 8000 characters they pasted. Restore each ref into
        // the buffer under a FRESH id (ids are per-vm-lifetime and the old one
        // may now be taken) and append its literal so the placeholder chip
        // reappears and send() can re-split it.
        // [T-paste-mediaref] KNOWN GAP, deliberately not papered over.
        //
        // A paste is stored as a `.mediaRef` and its `[Pasted#N]` literal is not
        // kept in the stored `.text`, so `msg.content` — the only thing this
        // function can see — carries just the surrounding prose. Editing such a
        // message therefore cannot re-hydrate the paste into the draft.
        //
        // ChatMessage has no link back to its RawMessage (no db id, no parts),
        // and the candidates for guessing one are all unsound: matching "the
        // longest history text part not in content" mis-fires on ordinary long
        // messages, and index-mapping messages→agentHistory has no maintained
        // correspondence. Rather than silently drop the user's pasted content
        // or restore the wrong text, surface the gap and leave the original
        // message intact until a real message↔parts link exists.
        if messageHasPastedRef(idx) {
            errorMessage = AppLocalized(
                "This message contains pasted content that can't be edited yet. Send a new message instead."
            )
            return
        }

        inputText = text
        editingMessageIndex = idx
        editingMessageId = msg.id
        editingOriginalText = text

        // Restore attachments: convert AttachmentMeta back to InputAttachment
        // by locating the files in the session uploads directory.
        if !msg.attachments.isEmpty, let sid = sessionId {
            let uploadsDir = Self.minisUploadsDir(for: sid)
            var restored: [InputAttachment] = []
            for meta in msg.attachments {
                let fileName = (meta.path as NSString).lastPathComponent
                let fileURL = uploadsDir.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
                // Copy to Caches so the normal send() flow works
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("InputAttachments")
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let cacheURL = cacheDir.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: cacheURL)
                try? FileManager.default.copyItem(at: fileURL, to: cacheURL)

                let ext = (fileName as NSString).pathExtension.lowercased()
                let kind: InputAttachment.Kind
                if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) {
                    kind = .image
                } else if ["mp4", "mov", "m4v"].contains(ext) {
                    kind = .video
                } else {
                    kind = .document
                }
                restored.append(InputAttachment(fileName: fileName, cacheURL: cacheURL, kind: kind))
            }
            attachments = restored
        }

        scrollToBottomSignal.send()
        logger.info("✏️ editMessage idx=\(idx) text=\(text.count)ch attachments=\(msg.attachments.count)")
    }

    func cancelEdit() {
        clearEditingState()
        inputText = ""
        attachments = []
        logger.info("✏️ cancelEdit")
    }

    func clearEditingState() {
        editingMessageIndex = nil
        editingMessageId = nil
        editingOriginalText = nil
    }

    /// A user bubble's text as the composer shows it when editing: the
    /// `<user-attached-files>` block stripped. Shared by editMessage() and the
    /// edit anchor check so both compare the same string.
    static func editableText(of content: String) -> String {
        guard let start = content.range(of: "<user-attached-files>") else { return content }
        let end = content.range(of: "</user-attached-files>")
        let endBound = end?.upperBound ?? content.endIndex
        return String(content[content.startIndex..<start.lowerBound] + content[endBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// [T-bubble-span] Re-find the bubble being edited. By id first — the
    /// stored index can shift between Edit and Send. A DB reload re-creates
    /// rows with new ids, so the stored index is trusted only while that row
    /// still holds the text the edit started from.
    func resolveEditedBubbleIndex() -> Int? {
        if let id = editingMessageId, let i = messages.firstIndex(where: { $0.id == id }) {
            return i
        }
        if let i = editingMessageIndex, i < messages.count, messages[i].role == .user,
           Self.editableText(of: messages[i].content) == (editingOriginalText ?? "") {
            return i
        }
        return nil
    }

    /// [T-bubble-span] Where a user bubble lives in agentHistory.
    enum UserBubbleSpan: Equatable {
        /// Linked by anchor: its entry is agentHistory[entry]; the bubbles at
        /// messages[firstBubble...lastBubble] that share the anchor were merged
        /// into that one entry by a queue drain (first == last otherwise).
        case linked(entry: Int, firstBubble: Int, lastBubble: Int)
        /// send() showed the bubble but has not appended its entry yet.
        case pending
        /// No usable link: the ordinal rule (the n-th user bubble is the n-th
        /// bubble entry). entry nil = not found.
        case unlinked(entry: Int?)
    }

    // [T-bubble-span] The ONE locator shared by retry, delete-from-here and
    // edit. It used to be three copies of an ordinal count ("the n-th user
    // bubble is the n-th bubble entry"), which breaks whenever the chat and
    // agentHistory are not 1:1 — a queue drain folds several queued bubbles
    // into one entry. Then edit kept the pre-edit message in the model's
    // context (the field report), retry re-ran with turns the chat had
    // removed, and delete left "deleted" turns in context. Every user bubble
    // is now linked to its entry by anchor (ChatMessage.historyAnchorId ↔
    // AgentMessage.anchorId, written where the entry is created); the ordinal
    // rule survives only as the fallback for an unlinked bubble.
    // Kept byte-identical with MinisTests/Standalone/BubbleSpanTests.swift.
    // BEGIN locateUserBubble
    static func locateUserBubble(at idx: Int, uiRows: [(isUser: Bool, anchor: UUID?)], pending: Bool,
                                 historyRows: [(anchor: UUID, isBubble: Bool)]) -> UserBubbleSpan {
        if let anchor = uiRows[idx].anchor,
           let entry = historyRows.firstIndex(where: { $0.anchor == anchor }) {
            let group = uiRows.indices.filter { uiRows[$0].isUser && uiRows[$0].anchor == anchor }
            return .linked(entry: entry, firstBubble: group.first ?? idx, lastBubble: group.last ?? idx)
        }
        if pending { return .pending }
        let n = uiRows[...idx].filter { $0.isUser }.count
        var seen = 0
        for (i, row) in historyRows.enumerated() where row.isBubble {
            seen += 1
            if seen == n { return .unlinked(entry: i) }
        }
        return .unlinked(entry: nil)
    }
    // END locateUserBubble

    // [T-bubble-span] Where a span cuts. uiFrom: first `messages` index to
    // remove. historyFrom: first agentHistory index to remove (nil = none).
    // keptEntry (for retry): the entry re-run from. keepBubble (retry) keeps
    // the bubble's group and entry; otherwise (delete, edit) they go too.
    // A pending bubble has nothing in history yet; an unlinked one that even
    // the ordinal rule cannot place fails OPEN — history kept whole.
    // Kept byte-identical with MinisTests/Standalone/BubbleSpanTests.swift.
    // BEGIN cutPoints
    static func cutPoints(for span: UserBubbleSpan, at idx: Int, keepBubble: Bool,
                          historyCount: Int) -> (uiFrom: Int, historyFrom: Int?, keptEntry: Int?) {
        switch span {
        case .linked(let entry, let first, let last):
            return (keepBubble ? last + 1 : first, keepBubble ? entry + 1 : entry, entry)
        case .pending:
            return (keepBubble ? idx + 1 : idx, nil, nil)
        case .unlinked(let entry?):
            return (keepBubble ? idx + 1 : idx, keepBubble ? entry + 1 : entry, entry)
        case .unlinked(nil):
            return (keepBubble ? idx + 1 : idx, nil, historyCount - 1)
        }
    }
    // END cutPoints

    /// [T-bubble-span] Cut the chat and agentHistory at the user bubble at
    /// `idx`. keepBubble (retry) keeps the bubble and its entry — for a merged
    /// entry, through the group's LAST bubble — and removes what follows.
    /// Otherwise (delete, edit) the bubble and its entry go too — for a merged
    /// entry, from the group's FIRST bubble — so the chat always shows exactly
    /// what the model keeps. Returns the span and, for keepBubble, the index of
    /// the kept entry (nil = pending, nothing of it in history yet).
    /// The caller trims the DB (agentHistory.count is 1:1 with its rows).
    @discardableResult
    func cutAtUserBubble(_ idx: Int, keepBubble: Bool, site: String) -> (span: UserBubbleSpan, keptEntry: Int?) {
        let span = Self.locateUserBubble(
            at: idx,
            uiRows: messages.map { ($0.role == .user, $0.role == .user ? $0.historyAnchorId : nil) },
            pending: messages[idx].awaitingHistoryEntry,
            historyRows: agentHistory.map { ($0.anchorId, Self.isUserBubbleEntry($0)) })
        let (uiFrom, historyFrom, keptEntry) = Self.cutPoints(for: span, at: idx, keepBubble: keepBubble,
                                                              historyCount: agentHistory.count)
        if case .unlinked(let entry) = span {
            logger.warning("[BubbleSpan] \(site): bubble idx=\(idx) is UNLINKED — ordinal fallback entry=\(entry.map(String.init) ?? "not found")")
        }
        if uiFrom < messages.count {
            // A removed bubble whose send() has not landed its entry yet must
            // not land it later, behind this cut.
            for msg in messages[uiFrom...] where msg.role == .user && msg.awaitingHistoryEntry {
                abandonedPendingSendIds.insert(msg.id)
            }
            messages.removeSubrange(uiFrom...)
        }
        if let historyFrom, historyFrom < agentHistory.count {
            agentHistory.removeSubrange(historyFrom...)
        }
        logger.info("[BubbleSpan] \(site): idx=\(idx) span=\(String(describing: span)) keepBubble=\(keepBubble) → messages=\(messages.count) history=\(agentHistory.count)")
        return (span, keptEntry)
    }
}
