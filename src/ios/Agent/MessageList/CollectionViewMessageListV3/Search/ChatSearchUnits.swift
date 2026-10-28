//
//  ChatSearchUnits.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] Which texts of a conversation "Search in Chat" looks at,
//  and the strings those texts are. Rule: what the list shows is searchable,
//  what it hides is not.
//
//    searched                              not searched
//    --------------------------------      --------------------------------
//    user bubble (reminders stripped)      thinking
//    user file tile names                  compact summary (only in its sheet)
//    assistant text (rendered, not md)     tool command / output (detail sheet)
//    tool capsule line                     usage, timestamps, buttons, labels
//    sub agent card title + status line    a not-sent user_ask's member rows
//    answered user_ask topic / answer      an open user_ask card (see below)
//    info block lines
//    compact divider, system info row
//    agent callback title
//    footer error
//    compacted history (same rows, dimmed)
//
//  `ChatSearchDisplayText` holds the strings that a view and the search must
//  agree on character for character; the views call these functions instead
//  of keeping their own copy (a drifting copy would make the highlighter miss
//  occurrences the counter counted).
//
//  An open (pending) user_ask card pages through its questions one at a time
//  and its options sit behind that pager, so what it shows depends on view
//  state the search cannot see; it is left out until that state moves into
//  the model.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import Foundation
import SwiftUI

// MARK: - Shared display text

@MainActor
enum ChatSearchDisplayText {
    /// The tool capsule's single line (ToolCapsuleView): a sub agent control
    /// call's own summary, else the model's tool title, else the command /
    /// file / action.
    static func toolCapsule(_ block: AssistantBlock) -> String {
        if let control = HelperBlockInfo.controlSummary(block) { return control }
        if let summary = block.toolSummary, !summary.isEmpty { return summary }
        return block.toolDescription
    }

    /// The user bubble's text: no attachment markup, no `<system-reminder>`.
    nonisolated static func userBubble(_ content: String) -> String {
        SystemReminderStripper.userBubbleText(content)
    }

    /// An info block's lines as AssistantBlockView draws them: the "⚠️"
    /// reason lines (the middle elided past nine), then the "switched to"
    /// line.
    struct InfoLines {
        let reasons: [String]
        let switched: String?
    }

    static func infoLines(_ content: String) -> InfoLines {
        let allLines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
        let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
        let displayReasons: [String] = {
            if reasonLines.count <= 9 { return reasonLines }
            return Array(reasonLines.prefix(4)) + [AppLocalized("⋯ \(reasonLines.count - 8) more")] + Array(reasonLines.suffix(4))
        }()
        return InfoLines(reasons: displayReasons, switched: switchedLine)
    }

    /// The agent callback card's headline: "<kind> · <title>". Only the title
    /// part is searched; `titleOffset` is where it starts (in Characters).
    static func callbackHeadline(_ callback: AgentCallback) -> (text: String, titleOffset: Int) {
        let kindLabel: String = switch callback.kind {
        case .finished: AppLocalized("Agent result")
        case .progress: AppLocalized("Agent progress")
        case .scheduled: AppLocalized("Scheduled task")
        }
        if callback.title.isEmpty { return (kindLabel, kindLabel.count) }
        let prefix = "\(kindLabel) · "
        return (prefix + callback.title, prefix.count)
    }

    /// The sub agent card's second line text, when it is the agent's own
    /// words (a running activity) or its status; nil for the fixed
    /// "starting" / "working…" placeholders.
    static func helperSecondLine(_ info: HelperBlockInfo) -> String? {
        switch info.phase {
        case .starting: return nil
        case .running(_, let activity, _): return activity.isEmpty ? nil : activity
        case .finished: return info.statusText
        }
    }

    /// An answered user_ask card's topic: the question (or, for several,
    /// their header tags).
    nonisolated static func userAskTopic(_ questions: [UserAskQuestion]) -> String {
        if questions.count == 1 { return questions[0].question }
        return questions.map { q in
            if let h = q.header, !h.isEmpty { return h }
            return q.question
        }.joined(separator: " · ")
    }

    /// An answered user_ask card's answer line.
    static func userAskDigest(_ results: [UserAskCardModel.Result], dismissed: Bool) -> String {
        guard !dismissed else { return "" }
        let parts: [String] = results.compactMap { r in
            switch r.status {
            case .answered, .other:
                let a = r.answer.joined(separator: ", ")
                return a.isEmpty ? nil : a
            case .delegated:
                return results.count > 1 ? AppLocalized("Left to Minis") : nil
            case .denied:
                let n = r.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return n.isEmpty ? nil : n
            default:
                return nil
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Snapshot

/// One unit's text, or what is needed to work it out off the main thread.
enum ChatSearchUnitSource {
    case plain(String)
    /// An assistant text block. `finalised` mirrors SelectableMarkdownView:
    /// a block with a prebuilt parse or attributed string renders its full
    /// markdown; a streaming one renders its prefix and shows the unparsed
    /// table tail as plain text.
    case markdown(raw: String, blocks: [BlockNode]?, finalised: Bool)
}

struct ChatSearchPendingUnit {
    let key: ChatSearchUnitKey
    let source: ChatSearchUnitSource
}

/// Cached search text of one assistant text block.
struct ChatSearchTextCacheEntry {
    let length: Int
    let finalised: Bool
    let text: String
}

enum ChatSearchUnitBuilder {
    /// Reads every searchable text off the live models, in display order.
    /// Main thread: `ChatMessage` / `AssistantBlock` are observable objects
    /// the UI mutates. Only copies strings (and an already-parsed block tree);
    /// parsing and searching happen later on a background task.
    @MainActor
    static func snapshot(messages: [ChatMessage]) -> [ChatSearchPendingUnit] {
        var out: [ChatSearchPendingUnit] = []
        out.reserveCapacity(messages.count * 2)
        func add(_ messageId: UUID, _ blockId: UUID?, _ field: ChatSearchField, _ text: String) {
            guard !text.isEmpty else { return }
            out.append(ChatSearchPendingUnit(key: ChatSearchUnitKey(messageId: messageId, blockId: blockId, field: field),
                                             source: .plain(text)))
        }
        for message in messages {
            let mid = message.id
            switch message.role {
            case .user:
                if let callback = message.agentCallback {
                    add(mid, nil, .title, callback.title)
                    continue
                }
                // File tiles sit above the bubble (UserAttachmentList.fileTile:
                // images, videos and pasted-text cards show no name).
                for (i, meta) in message.attachments.enumerated()
                where !meta.isImage && !meta.isVideo && meta.pastedId == nil {
                    add(mid, nil, .attachmentName(i), meta.fileName)
                }
                add(mid, nil, .body, ChatSearchDisplayText.userBubble(message.content))
            case .assistant:
                for block in message.blocks {
                    if case .member = UserAskNotSentStore.shared.role(block.id) { continue }
                    let bid = block.id
                    switch block.kind {
                    case .thinking:
                        continue
                    case .text:
                        guard !block.content.isEmpty else { continue }
                        let finalised = block.cachedAttributedString != nil || block.cachedMarkdown != nil
                        out.append(ChatSearchPendingUnit(
                            key: ChatSearchUnitKey(messageId: mid, blockId: bid, field: .body),
                            source: .markdown(raw: block.content, blocks: block.cachedMarkdown?.blocks,
                                              finalised: finalised)))
                    case .info:
                        let lines = ChatSearchDisplayText.infoLines(block.content)
                        for (i, line) in lines.reasons.enumerated() { add(mid, bid, .line(i), line) }
                        if let switched = lines.switched { add(mid, bid, .title, switched) }
                    case .userAskTool:
                        addUserAsk(block, messageId: mid, add: add)
                    case .delegateTool where HelperBlockInfo.controlSummary(block) == nil:
                        let info = HelperBlockInfo.parse(block)
                        add(mid, bid, .title, info.title)
                        if let second = ChatSearchDisplayText.helperSecondLine(info) {
                            add(mid, bid, .activity, second)
                        }
                    default:
                        add(mid, bid, .body, ChatSearchDisplayText.toolCapsule(block))
                    }
                }
                if let error = message.error { add(mid, nil, .footerError, error) }
            case .compactDivider, .systemInfo:
                add(mid, nil, .body, message.content)
            }
        }
        return out
    }

    /// An answered user_ask card (UserAskResolvedCard): topic, answer line,
    /// and the questions while the card is expanded.
    @MainActor
    private static func addUserAsk(_ block: AssistantBlock, messageId: UUID,
                                   add: (UUID, UUID?, ChatSearchField, String) -> Void) {
        let live = UserAskCenter.shared.ask(forToolUseId: block.toolUseId)
        let request = UserAskCardModel.request(block)
        let phase = UserAskCardPhase.resolve(
            livePending: live?.state == .pending,
            liveTerminal: live?.state.isTerminal == true,
            hasContent: !block.content.isEmpty,
            requestParses: request != nil,
            callEnded: UserAskCardPhase.callEnded(block.toolStatus))
        let questions: [UserAskQuestion]
        let results: [UserAskCardModel.Result]
        let dismissed: Bool
        switch phase {
        case .resolvedLive:
            guard let live else { return }
            questions = live.questions
            results = UserAskCardModel.results(live.resultJSON ?? "")
            dismissed = live.dismissReason != nil
        case .resolvedStored:
            guard let request else { return }
            questions = request.questions
            results = UserAskCardModel.results(block.content)
            dismissed = false
        case .pending, .notAsked, .waiting:
            return
        }
        let bid = block.id
        add(messageId, bid, .title, ChatSearchDisplayText.userAskTopic(questions))
        add(messageId, bid, .activity, ChatSearchDisplayText.userAskDigest(results, dismissed: dismissed))
        if block.isThinkingExpanded {
            for (i, q) in questions.enumerated() { add(messageId, bid, .question(i), q.question) }
        }
    }

    /// Search text of an assistant text block, the way its cell renders it.
    /// Background-safe: parses with the same preparation as the view.
    static func resolveMarkdown(raw: String, blocks: [BlockNode]?, finalised: Bool) -> String {
        let split = finalised ? (prefix: raw, plainSuffix: "") : splitStreamingTableTail(raw)
        let hasSuffix = !split.plainSuffix.isEmpty
        let parsed = (hasSuffix ? nil : blocks) ?? MarkdownContent(prepareMarkdownForRender(split.prefix)).blocks
        return ChatSearchMarkdownText.text(blocks: parsed, plainSuffix: split.plainSuffix)
    }

    /// Turns the snapshot into searchable units, reusing (and refreshing)
    /// the per-block text cache. Background-safe.
    static func resolve(_ pending: [ChatSearchPendingUnit],
                        cache: [UUID: ChatSearchTextCacheEntry],
                        isCancelled: () -> Bool) -> (units: [ChatSearchUnit], cache: [UUID: ChatSearchTextCacheEntry])? {
        var units: [ChatSearchUnit] = []
        units.reserveCapacity(pending.count)
        var newCache: [UUID: ChatSearchTextCacheEntry] = [:]
        for (i, p) in pending.enumerated() {
            if i % 32 == 0, isCancelled() { return nil }
            switch p.source {
            case .plain(let text):
                units.append(ChatSearchUnit(key: p.key, text: text))
            case .markdown(let raw, let blocks, let finalised):
                guard let blockId = p.key.blockId else { continue }
                let length = raw.utf16.count
                let text: String
                if let hit = cache[blockId], hit.length == length, hit.finalised == finalised {
                    text = hit.text
                } else {
                    text = resolveMarkdown(raw: raw, blocks: blocks, finalised: finalised)
                }
                newCache[blockId] = ChatSearchTextCacheEntry(length: length, finalised: finalised, text: text)
                units.append(ChatSearchUnit(key: p.key, text: text))
            }
        }
        return (units, newCache)
    }
}
