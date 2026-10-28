//
//  ChatStoreModels.swift
//  Minis - chat persistence (Agent/Chat)
//
//  The persisted chat data model: sessions, folders, messages (RawMessage
//  with its ContentPart parts, tool uses / results / snapshots, media refs),
//  compaction markers, stored token usage, and the sync value types
//  (SyncDevice, RemoteMemory, SyncStatus). ChatStore reads and writes these.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - Sync Data Types

struct SyncDevice: Identifiable {
    let id: String       // deviceId
    var deviceName: String
    var zoneName: String
    var lastSeen: Date
    var osVersion: String
    /// Content types this device is uploading (e.g. ["Sessions", "Skills", "Providers"])
    var uploadTypes: [String]
}

struct RemoteMemory: Identifiable {
    let id: String
    let deviceId: String
    var fileName: String
    var content: String
    var updatedAt: Date
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
    case disabled
}

// MARK: - Data Model

/// A chat session (conversation thread).
struct ChatSession: Identifiable, Codable, Hashable {
    let id: String
    var title: String?
    var category: String?
    let modelId: String
    let createdAt: Date
    var updatedAt: Date
    var lastMessage: String?
    var source: String?       // e.g. "shortcut" for Shortcuts-triggered sessions
    var lastSyncedAt: Date?   // non-nil if successfully synced to iCloud
    var remoteDeviceId: String?   // non-nil if this session came from another device via iCloud
    var remoteDeviceName: String? // human-readable name of the remote device
    var pinnedAt: Date?       // non-nil if session is pinned; timestamp of when it was pinned
    var folderId: String?     // non-nil if filed into a folder; NULL = ungrouped
    /// [T-p1-delegate-task] Non-nil ⇒ this is a hidden CHILD session (a
    /// helper run spawned by `delegate_task`, later also `minis-scheduled
    /// --target child-of-current`). Visibility is derived from this one
    /// column: nil → home list; set → reachable only from the parent.
    var parentSessionId: String?
    /// The parent's `delegate_task` tool_use id that spawned this child, or
    /// nil for a child created without a tool block (scheduled, P2).
    var parentToolUseId: String?

    /// Whether this session is a hidden child of another session.
    var isChild: Bool { parentSessionId != nil }

    /// Whether this session is from a remote device (read-only).
    var isRemote: Bool { remoteDeviceId != nil }

    /// Whether this session is pinned to the top of the list.
    var isPinned: Bool { pinnedAt != nil }

    /// Whether this session belongs to a folder.
    var isFiled: Bool { folderId != nil }

    // MARK: - Equatable / Hashable (cheap, content-via-proxy)
    //
    // [T-ios-session-list-equatable-jank] The compiler-synthesized
    // `==`/`hash` compared EVERY stored field — including the long
    // `lastMessage` / `title` strings. SwiftUI's sidebar `ForEach(groupedSessions)`
    // makes AttributeGraph deep-compare the whole `[ChatSession]` array on every
    // transaction flush (session switch, tap, foreground, iCloud inbound). In
    // DEBUG that synthesized `String.==` runs the Unicode NFC normalization
    // slow path (no inlining / ARC elision), and across a long session list it
    // pinned the main thread for 1–2s+ (HangDetector: ChatSession
    // __derived_struct_equals → _stringCompareSlow → _NFCNormalizer). Release
    // optimizes it away, which is why Release didn't stall.
    //
    // Replace with an explicit cheap comparison: identity + the short
    // change-driving fields, using `updatedAt` as the proxy for the heavy
    // `lastMessage` (and any other body content) — every content mutation bumps
    // `updatedAt`, so we never need to NFC-compare the long string to detect a
    // change. `title`/`category`/`source` ARE compared (they can change without
    // a content write, e.g. rename / categorize) but they're short. Net: the
    // sidebar diff no longer touches the long strings.
    static func == (lhs: ChatSession, rhs: ChatSession) -> Bool {
        lhs.id == rhs.id
            && lhs.updatedAt == rhs.updatedAt
            && lhs.pinnedAt == rhs.pinnedAt
            // `folderId` MUST be compared: moving a session between folders
            // changes neither `updatedAt` nor any other compared field, so
            // without this the sidebar would keep rendering the row in its old
            // section until some unrelated mutation bumped the diff.
            && lhs.folderId == rhs.folderId
            // Promotion (clearing the parent) must re-sort the list.
            && lhs.parentSessionId == rhs.parentSessionId
            && lhs.title == rhs.title
            && lhs.category == rhs.category
            && lhs.source == rhs.source
            && lhs.lastSyncedAt == rhs.lastSyncedAt
            && lhs.remoteDeviceId == rhs.remoteDeviceId
            && lhs.remoteDeviceName == rhs.remoteDeviceName
        // Intentionally NOT comparing `lastMessage` (long string; `updatedAt`
        // is its change proxy) or the immutable `modelId` / `createdAt`.
    }

    func hash(into hasher: inout Hasher) {
        // Mirror ==: cheap, identity + updatedAt. Avoids hashing long strings.
        hasher.combine(id)
        hasher.combine(updatedAt)
    }
}

/// A user-created folder that groups sessions on the home list.
///
/// Named "Folder" rather than "Group" on purpose: the codebase already has
/// three other "group"s — `ModelGroup` (the LLM provider fallback group behind
/// the home FAB's "New Chat with Group"), the `__grp__` draft-session id
/// encoding (which embeds a ModelGroup id), and SwiftUI's `Group {}`.
///
/// Identity is a locally generated UUID, and `name` deliberately carries no
/// uniqueness constraint:
///
/// - **Why not key on the name.** Renaming would stop being a single-field
///   edit and become an identity change (delete old key, create new key,
///   migrate every member). That multi-row operation tears across devices: if
///   device A renames while device B files sessions under the old name, B's
///   sessions end up referencing a key that no longer exists and silently fall
///   back to ungrouped. With a UUID, a rename is one LWW field on `FolderV2`
///   and members are untouched.
/// - **Why duplicate names are allowed.** Two devices each creating "Work"
///   offline produce two distinct UUIDs, and both are kept. Auto-merging is
///   irreversible and two same-named folders are not necessarily the same
///   thing; the user can always move sessions across and dissolve the leftover.
///   Consequence: any *name-based* lookup must tolerate multiple matches (see
///   `findFolderByName`).
struct ChatFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var icon: String?         // SF Symbol name; nil = use the composed icon
    var color: String?        // theme color token
    var origin: String        // "manual" | "ai" — provenance only, no behavior
    var sortIndex: Int        // reserved for V2 drag-reorder
    var pinnedAt: Date?       // non-nil = folder pinned above unpinned folders
    /// One-sentence description (≤100 chars). Auto-grouping context; never
    /// rendered in the home list, but shown as the Move-to-Group picker row
    /// subtitle and surfaced for editing in the rename dialog.
    var desc: String?
    let createdAt: Date
    var updatedAt: Date

    var isPinned: Bool { pinnedAt != nil }

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String? = nil,
        color: String? = nil,
        origin: String = "manual",
        sortIndex: Int = 0,
        pinnedAt: Date? = nil,
        desc: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.origin = origin
        self.sortIndex = sortIndex
        self.pinnedAt = pinnedAt
        self.desc = desc
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Role for a raw message turn.
enum MessageRole: String, Codable {
    case user
    case assistant
}

/// Reference to a media file stored in Library/MinisChat/minis/<sessionId>/
struct MediaRef: Codable, Hashable {
    let id: String
    let relativePath: String
    let mimeType: String
    let originalFileName: String?
    /// iSH-visible linux path the file is mirrored to (e.g.
    /// `/var/minis/attachments/uploads/<name>`, `/var/minis/browser/<sid>/...`).
    /// Optional — older persisted rows decode with `nil` and fall back to
    /// spillover at request-budget elide time. New writes always populate
    /// this when the file is offloaded to iSH-visible storage.
    let linuxPath: String?

    init(id: String, relativePath: String, mimeType: String, originalFileName: String?, linuxPath: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.originalFileName = originalFileName
        self.linuxPath = linuxPath
    }
}

/// A tool call requested by the assistant.
struct ToolUse: Codable, Hashable {
    let toolUseId: String
    let name: String
    let input: String
    let description: String?
    let thoughtSignature: String?  // Gemini 3.x thought signature
}

/// A snapshot captured from a tool execution result.
struct ToolSnapshot: Codable, Hashable {
    enum SnapshotType: String, Codable, Hashable {
        case text
        case image
    }
    let type: SnapshotType
    let text: String?        // For .text snapshots (last N lines of output)
    let mediaRef: MediaRef?  // For .image snapshots (browser screenshot)
    let duration: TimeInterval?  // Execution duration in seconds
}

/// Result of executing a tool.
struct ToolResult: Codable, Hashable {
    let toolUseId: String
    let output: String
    let success: Bool
    let mediaRef: MediaRef?
    let snapshot: ToolSnapshot?
    /// Final page URL after browser tool execution (for display in tool detail sheet).
    /// Truncated to ≤512 characters if the original was longer.
    let pageURL: String?
    /// Terminal execution status: "success" | "failed" | "cancelled".
    /// Optional for backward compatibility with rows written before this field existed;
    /// when nil, callers fall back to `success` (which cannot distinguish failed from cancelled).
    let status: String?

    /// Truncate a URL to at most `maxLength` characters by eliding the middle.
    /// Returns the original if it's already short enough.
    static func truncateURL(_ url: String, maxLength: Int = 512) -> String {
        guard url.count > maxLength else { return url }
        let marker = "…[truncated]…"
        let keep = (maxLength - marker.count) / 2
        let head = String(url.prefix(keep))
        let tail = String(url.suffix(keep))
        return head + marker + tail
    }
}

/// A single content part within a message — the atomic unit.
enum ContentPart: Codable, Hashable {
    case text(String)
    case mediaRef(MediaRef)
    case toolUse(ToolUse)
    case toolResult(ToolResult)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum PartType: String, Codable {
        case text
        case mediaRef
        case toolUse
        case toolResult
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try container.encode(PartType.text, forKey: .type)
            try container.encode(s, forKey: .value)
        case .mediaRef(let ref):
            try container.encode(PartType.mediaRef, forKey: .type)
            try container.encode(ref, forKey: .value)
        case .toolUse(let tu):
            try container.encode(PartType.toolUse, forKey: .type)
            try container.encode(tu, forKey: .value)
        case .toolResult(let tr):
            try container.encode(PartType.toolResult, forKey: .type)
            try container.encode(tr, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let partType = try container.decode(PartType.self, forKey: .type)
        switch partType {
        case .text:
            self = .text(try container.decode(String.self, forKey: .value))
        case .mediaRef:
            self = .mediaRef(try container.decode(MediaRef.self, forKey: .value))
        case .toolUse:
            self = .toolUse(try container.decode(ToolUse.self, forKey: .value))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .value))
        }
    }
}

/// A compact boundary marker in a session's message history.
/// Represents the point where older messages were summarized to save context.
///
/// Identity model (post Phase A):
///   - `firstKeptMessageId` is the authoritative active-region start.
///   - `lastCompactedMessageId` is the last message in the compacted range.
///   - Sort-order fields (`firstKeptSortOrder`, `uiBoundarySortOrder`) and
///     `boundaryMessageId` are retained for legacy markers and cross-device
///     sync compatibility with older builds, used only as fallbacks.
struct CompactMarker: Identifiable, Codable {
    let id: String
    let sessionId: String
    /// LLM-generated summary of the compacted messages.
    let summary: String
    /// LEGACY: sort_order of the first message AFTER the compacted range.
    /// Only used as fallback when firstKeptMessageId resolution fails.
    let firstKeptSortOrder: Int
    /// Number of raw messages that were compacted. UI display only.
    let compactedCount: Int
    let createdAt: Date
    /// LEGACY: sort_order of the UI boundary message.
    /// Only used as fallback for divider positioning on legacy markers.
    let uiBoundarySortOrder: Int?
    /// LEGACY: DB message ID of the boundary message (pre-Phase A name for firstKeptMessageId).
    /// Kept for cross-device sync compatibility with older builds.
    let boundaryMessageId: String?
    /// PRIMARY: DB message ID of the first kept (active-region) message.
    /// All restore / compact logic resolves boundaries through this id.
    /// Optional only for legacy markers written before Phase A.
    let firstKeptMessageId: String?
    /// PRIMARY: DB message ID of the last compacted message (right edge of the
    /// compacted range). Used by prune protection to avoid deleting marker anchors.
    /// Optional only for legacy markers written before Phase A.
    let lastCompactedMessageId: String?
    /// Marker schema version. 1 = legacy multi-field model (firstKept/boundary/
    /// sortOrder fallback chain). 2 = simplified id-only model: only
    /// `lastCompactedMessageId` is authoritative; everything before it (incl.)
    /// is the compacted range, everything after it is "live anchor + new msgs".
    /// `compactedCount` and `summary` are still meaningful for UI; all other
    /// columns are ignored for v2 markers.
    var version: Int = 1
}

/// Token usage stats stored with a message.
struct StoredTokenUsage: Codable, Hashable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    var latestContextTokens: Int?
    /// [T-ctx-measure-outbound] See TokenUsage.estimatedRequestTokens. Optional
    /// so rows written before this field decode as nil, and so older builds and
    /// Android's backup reader (ignoreUnknownKeys) skip it.
    var estimatedRequestTokens: Int? = nil
    var estimatedFixedTokens: Int? = nil
    var calibrationModelId: String? = nil
    /// [T-ctx-count-reasoning] ContextSizeMeter.estimatorVersion at the time
    /// `estimatedRequestTokens` was taken. Optional for the same reasons as the
    /// fields above: rows written before it decode as nil (= version 1, skipped
    /// on calibration replay), an older build ignores the key, and the key name
    /// matches Android's `estimatorVersion`. The whole struct travels as one
    /// JSON string (messages.token_usage, SyncedMessage.tokenUsageJson, backup),
    /// so it needs no column, no sync field and no backup change.
    var estimatorVersion: Int? = nil
}

/// A single message in the conversation (one "turn").
struct RawMessage: Identifiable, Codable, Hashable {
    let id: String
    let sessionId: String
    let role: MessageRole
    let parts: [ContentPart]
    let createdAt: Date
    var tokenUsage: StoredTokenUsage?
    /// Reasoning content from thinking models (Kimi, DeepSeek, QwQ, etc.) — must be echoed back.
    var reasoningContent: String?
    /// Number of mid-stream auto-retries that occurred before this message completed successfully.
    /// 0 means no interruption. Persisted to DB for display after session reload.
    var streamInterruptCount: Int = 0
    /// Database sort_order value. Populated during loadMessages, used for compact boundary tracking.
    var sortOrder: Int = 0
    /// [T-error-persist-ios] Device-local error string for a failed assistant
    /// turn. Mirrors ChatMessage.error; persisted to the messages.error_info
    /// column so the error indicator survives reload. nil = no error.
    var errorInfo: String? = nil

    /// [T-token-attribution-snapshot] The model that ACTUALLY produced this
    /// message, snapshotted when it was written.
    ///
    /// Snapshot rather than a reference to resolve later: usage is a record of
    /// what happened, and it must not change when the configuration it once
    /// pointed at changes. `modelDisplayName` / `providerType` travel with the
    /// id so a deleted provider does not make history unreadable.
    ///
    /// nil on rows written before these columns existed — the signal the Usage
    /// page uses to mark a row estimated rather than measured.
    var modelId: String? = nil
    var modelDisplayName: String? = nil
    /// `ProviderType` **rawValue** (e.g. `openAI`), never a display name.
    var providerType: String? = nil

    /// [T-responses-echo-persist] Serialized `ReasoningEcho` for this assistant
    /// turn — the OpenAI Responses `reasoning` head (item ids + summaries) plus
    /// the upstream that minted them.
    ///
    /// Stored as JSON in `messages.reasoning_echo` rather than as typed columns
    /// because it is a small, provider-shaped payload that only the provider
    /// layer interprets.
    ///
    /// `encrypted_content` is deliberately NOT persisted: it is large (base64),
    /// endpoint-bound, and worthless once the session may resume against a
    /// different upstream. Dropping it degrades to an id-only replay, which the
    /// live endpoint accepts (measured 200 with `store:false`) and which
    /// `upstreamIdentity` already makes safe.
    ///
    /// nil on rows written before this column existed, and on turns that
    /// genuinely produced no reasoning.
    var reasoningEchoJSON: String? = nil
    /// Diagnostics / disambiguation only; the UI never resolves through it.
    var providerInstanceId: String? = nil

    /// True if this message contains only tool results (no user text).
    /// These are internal agent loop messages that shouldn't render as user bubbles.
    var isToolResultOnly: Bool {
        role == .user && !parts.isEmpty && parts.allSatisfy {
            if case .toolResult = $0 { return true }
            return false
        }
    }

    /// [T-bridge-message-ui-leak] The internal assistant "bridge" row older
    /// builds inserted when a queued user message interrupted a tool loop
    /// (#579), to keep …user(tool_result) → assistant(bridge) → user(queued)…
    /// from being merged. Detected by content match rather than a schema
    /// flag, so rows persisted by any build are recognized.
    ///
    /// [T-bridge-to-reminder] NO LONGER WRITTEN. An assistant-role line in
    /// history is something the model learns to say: with several of these
    /// in a long session the model produced this exact text itself at the end
    /// of a turn (sid AA40533E, 262 chars, no injection in the log), it
    /// rendered (one text block of a 12-block reply) and was persisted as a
    /// further example. The note now rides as `queuedInterruptReminderText`
    /// at the end of the queued user message. The constants stay so old rows
    /// are hidden, dropped from requests (`isLegacyBridgeRow`) and caught if
    /// the model echoes them (`strippingInternalBridgeEcho`).
    static let internalBridgeText =
        "(Interrupted mid-task by a new user message. Decide based on the new message and overall context whether the prior task should continue — do not forget or abandon it unless the user explicitly says to stop, or the new message makes clear it is no longer needed.)"

    /// Every bridge text this app has ever generated. A row persisted by an
    /// OLDER build carries the PREVIOUS wording; matching the current constant
    /// alone would fail and leak that row into the UI (the exact regression seen
    /// after the 2026-07-23 wording change, d2e111e9). Match against the full
    /// set so old and new persisted bridges are both recognized. Prefix-match
    /// (not equality) tolerates trailing-whitespace / normalization drift from
    /// DB round-trips.
    static let internalBridgeTexts: [String] = [
        internalBridgeText,
        // [T-scheduled-preempt] Bridge before a scheduled fire inserted between
        // two tool steps of a running task.
        scheduledInsertBridgeText,
        // Pre-d2e111e9 wording.
        "(Interrupted mid-task to handle your new message. Will return to the prior task after.)",
    ]

    /// [T-scheduled-preempt] The assistant-side bridge older builds wrote when
    /// a scheduled fire was inserted into a running task at a tool boundary.
    /// [T-bridge-to-reminder] No longer written, for the same reason as
    /// `internalBridgeText`; the fire's own `<system-reminder>`
    /// (`ScheduledInsertText.midTaskReminder`) now says to resume the task.
    static let scheduledInsertBridgeText =
        "(A scheduled task fired while this task was still in progress. It is shown next; after handling it, continue the task above — it is not finished.)"

    /// [T-bridge-to-reminder] Appended as the LAST text part of a queued user
    /// message delivered between two tool steps (the tail was
    /// user(tool_result)), in place of the old assistant bridge row. User-side
    /// and wrapped in <system-reminder>, so it is a note the model reads, not
    /// a line it learns to say, and every display path strips it.
    static let queuedInterruptReminderText =
        "<system-reminder>This note is from the system, not something the user wrote. The user sent the message above while you were in the middle of a task. Decide from that message and the conversation so far whether the earlier task should continue; do not forget or abandon it unless the user explicitly asks you to stop or the message makes clear it is no longer needed. Do not repeat or mention this note.</system-reminder>"

    /// [T-scheduled-preempt] The one-shot, hidden user turn sent when the model
    /// answered an inserted scheduled fire and then stopped, although the task
    /// it was interrupted in had not finished. It exists only for the model:
    /// never rendered, recognized by exact text like the bridges above.
    static let scheduledResumeNudgeText =
        "<system-reminder>The scheduled task above has been handled. If the task you were working on before it arrived is not finished yet, continue it now from where you left off; if it is already complete, reply briefly and stop.</system-reminder>"

    /// [T-user-ask-fallback] The one-shot hidden user turn sent when a run that
    /// has user_ask ends with a reply asking the user to decide something in
    /// text (UserAskTextAsk) without having asked with the tool. Never rendered.
    static let userAskTextAskNudgeText =
        "<system-reminder>If you are waiting on the user to decide something, ask it with user_ask.</system-reminder>"

    /// [T-user-ask-notsent-retry] The hidden user turn sent when the user taps
    /// Retry on a "Question not sent" row. Written by the app, not the user:
    /// it answers no question and authorizes nothing, and says so, so the
    /// model neither reads it as a reply nor as consent. Never rendered.
    static let userAskRetryNudgeText =
        "<system-reminder>This note is from the app, not from the user. Your last user_ask call was not sent: its arguments were empty or incomplete, so the user saw no question. The user tapped Retry. Call user_ask again now with `questions` filled in completely. This note is not an answer to any question and does not approve or authorize any action.</system-reminder>"

    /// [T-subagent-termination] The one-shot hidden user turn a sub agent gets
    /// when a turn ends with neither tool calls nor text: without it the run
    /// ends with no deliverable and the parent receives nothing. Sent with the
    /// tools withdrawn, so the only possible answer is the report. Never rendered.
    static let helperClosingNudgeText =
        "<system-reminder>This note is from the app, not from the delegating agent. Your last reply contained no text, so the delegating agent has received nothing from you. Tools are no longer available. Write your final answer now from what you already have: the deliverable itself, what you finished, what failed (including any tool error above) and what is left. Mark anything you could not verify as unverified.</system-reminder>"

    /// Hidden USER-role rows (see `scheduledResumeNudgeText`).
    static let internalUserNudgeTexts: [String] = [scheduledResumeNudgeText, userAskTextAskNudgeText, userAskRetryNudgeText, helperClosingNudgeText]

    static func isInternalUserNudgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalUserNudgeTexts.contains { trimmed == $0 }
    }

    /// True when `text` is any known internal-bridge string. Shared by
    /// RawMessage and ChatMessage so every layer recognizes the same rows.
    static func isInternalBridgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalBridgeTexts.contains { trimmed == $0 }
    }

    /// [T-bridge-echo-drop] nil when `text` does not start with a known bridge
    /// text; otherwise what follows it (trimmed, possibly empty). Catches the
    /// model reproducing a bridge it saw in history.
    static func strippingInternalBridgeEcho(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bridge in internalBridgeTexts where trimmed.hasPrefix(bridge) {
            return String(trimmed.dropFirst(bridge.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// [T-bridge-to-reminder] An assistant row that is nothing but a bridge
    /// text — what older builds persisted. Kept out of every request
    /// (`AIChatViewModel.droppingLegacyBridgeRows`) so it stops serving as an
    /// example; the hidden user nudge is NOT one of these.
    static func isLegacyBridgeRow(_ msg: AgentMessage) -> Bool {
        guard msg.role == .assistant, msg.parts.count == 1, case .text(let s) = msg.parts[0] else { return false }
        return isInternalBridgeText(s)
    }

    var isInternalBridge: Bool {
        guard parts.count == 1, case .text(let s) = parts[0] else { return false }
        switch role {
        case .assistant: return Self.isInternalBridgeText(s)
        // [T-scheduled-preempt] The hidden resume nudge is a user row.
        case .user: return Self.isInternalUserNudgeText(s)
        }
    }
}
