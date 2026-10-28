//
//  VoiceCorrectionContext.swift
//  Minis - chat page (AIChatView)
//
//  voiceCorrectionContext(from:viewport:): the conversation context handed to
//  voice-input correction (recent turns, the on-screen block, the newest
//  reply). Also used by Debug/VoiceCorrectionDebugRPC.swift.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// [voice-correction §6] Build the conversation context for a correction: the last user
/// message and the agent reply that followed it.
///
/// Reads the in-memory `messages` the chat is already rendering — §12.1 explicitly forbids
/// a DB query here, since this runs on the correction path. Both halves are truncated by
/// `ConversationContextTruncator` (500-char soft cap, extended to the next sentence
/// terminator so a quoted fragment never ends mid-sentence).
///
/// This is what lets correction work on a FRESH INSTALL. With both learned tables empty and
/// no context, the prompt has no evidence at all and the model correctly refuses to change
/// anything — which is exactly why the suggestion icon never appeared on a new device.
///
/// [T-voice-viewport-context] `viewport` adds what the user is LOOKING AT: in a long
/// session scrolled back, the recent turns above are not what is on screen. The two are
/// kept side by side — the recent turns still carry the rare terms of the latest
/// exchange, the on-screen block carries the visual context — plus the newest reply,
/// deduplicated against the screen.
func voiceCorrectionContext(from messages: [ChatMessage], viewport: ViewportSnapshot? = nil) -> ConversationContext {
    // Budgeted builder (2026-07-16): sentence-split + segment + rarity-rank the
    // recent turns, expanding the message count under a 5k-char budget, instead
    // of the original "last user + reply, first 500 chars each". §12.1 still
    // holds — this reads only the in-memory messages the chat is rendering.
    // Only real conversation turns feed the context. compactDivider and
    // systemInfo rows would otherwise be classified as "assistant" and leak
    // UI copy into the rare-terms digest.
    let source = messages
        .filter { $0.role == .user || $0.role == .assistant }
        .map { msg -> CorrectionSourceMessage in
            // Assistant turns keep their prose in `blocks` (text blocks), not
            // in `content` — reading only `content` silently dropped every AI
            // reply from the correction context. `content` can also hold a
            // stale FRAGMENT alongside full blocks (observed: a 34-char title
            // while the reply lived in blocks), so for assistant turns the
            // text blocks are the source of truth and `content` is only the
            // fallback. Tool/thinking/info blocks stay out — their payloads
            // are commands and traces, not conversational vocabulary.
            var text = msg.content
            if msg.role == .assistant, !msg.blocks.isEmpty {
                let blockText = msg.blocks
                    .filter { $0.kind == .text }
                    .map(\.content)
                    .joined(separator: "\n")
                if !blockText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = blockText
                }
            }
            return CorrectionSourceMessage(role: msg.role == .user ? .user : .assistant,
                                           text: TypedVocabularyBuilder.stripAttachmentMarkup(text))
        }
    var context = CorrectionContextBuilder.build(messages: source)

    // Newest assistant reply that has prose (a reply still running tools has none yet).
    let latest = messages.last { msg in
        msg.role == .assistant && msg.blocks.contains {
            $0.kind == .text && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    let latestReply = latest.map { msg in
        LatestReplySource(messageId: msg.id.uuidString,
                          blocks: msg.blocks.filter { $0.kind == .text }
                              .map { .init(id: $0.id.uuidString, text: $0.content) })
    }
    let onScreen = ViewportContextBuilder.build(snapshot: viewport, latestReply: latestReply)
    context.viewportLines = onScreen.lines
    context.latestReply = onScreen.latestReply
    context.mining.viewport = onScreen.report
    return context
}
