//
//  RawMessage+Conversion.swift
//  Minis - chat persistence (Agent/Chat)
//
//  RawMessage -> what the app shows and sends: toChatMessage (UI rows, with
//  attachment-marker / system-reminder stripping and long-text splitting) and
//  toAgentMessage (model history). The JSON helpers at the end are private
//  to this file.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

// MARK: - UI Conversion

extension RawMessage {
    /// Convert to ChatMessage for UI display.
    /// Images render from file URL — no base64 loading needed.
    func toChatMessage(mediaResolver: (MediaRef) -> URL, showThinking: Bool = true) -> ChatMessage {
        let uiRole: ChatMessageRole = role == .user ? .user : .assistant

        // Build display content from parts
        var textContent = ""
        var blocks: [AssistantBlock] = []
        var userAttachments: [AttachmentMeta] = []

        // ISO8601 parser for attachment metadata
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        /// Track the last known browser URL across tool blocks so actions like
        /// get_readable (which don't carry a url arg) can inherit it.
        var lastBrowserURL: String?

        for part in parts {
            switch part {
            case .text(let s):
                // [T-bridge-to-reminder] A bridge line the model copied into a
                // longer reply (saved before the echo guard existed). A row
                // that is ONLY a bridge is hidden whole by `isInternalBridge`.
                if role == .assistant, Self.isInternalBridgeText(s) { continue }
                if role == .assistant {
                    let visible = Self.stripSystemReminders(s)
                    if !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // [T-ios-longmsg-cell-split] Split a very long reply into
                        // several text blocks instead of one enormous cell.
                        //
                        // A contiguous assistant reply used to become exactly ONE
                        // `.text` block no matter how long, and the message list
                        // gives each block its own cell — so a 9156-char answer
                        // became a single 20615pt cell backed by one UITextView.
                        // Field log from the render-collapse report shows exactly
                        // that shape: `blocks=288` markdown blocks all inside one
                        // AssistantBlock, and `visibleCells=1` for the whole
                        // 50559pt list while dragging.
                        //
                        // Splitting keeps EVERY character — this is not a clip.
                        // It only changes how many cells carry them, which bounds
                        // each UITextView/CALayer and lets UICollectionView
                        // recycle off-screen parts (the same reasoning as
                        // PaginatedMarkdownView, whose fence-aware splitter is
                        // reused here rather than reimplemented).
                        //
                        // Load-time only, on purpose: this is the DB path, so a
                        // message is split once it is finished and persisted.
                        // The streaming path builds its blocks in memory and is
                        // untouched, which is what keeps split points from
                        // shifting under a growing message.
                        for segment in Self.splitLongAssistantText(visible) {
                            blocks.append(AssistantBlock(kind: .text, content: segment))
                        }
                    }
                }
                // Extract structured attachment metadata from <user-attached-files> XML
                // and strip it from user-visible display text
                var displayStr = s
                if role == .user, s.contains("<user-attached-files>") {
                    let openTag = "<user-attached-files>"
                    let closeTag = "</user-attached-files>"
                    if let range = s.range(of: openTag) {
                        let endBound: String.Index
                        if let endRange = s.range(of: closeTag) {
                            endBound = endRange.upperBound
                            let body = String(s[range.upperBound..<endRange.lowerBound])

                            if body.contains("<file ") {
                                // New XML format: <file path="..." url="..." size="..." modified="..." />
                                let filePattern = try? NSRegularExpression(
                                    pattern: #"<file\s+path="([^"]*)"(?:\s+url="([^"]*)")?(?:\s+size="([^"]*)")?(?:\s+modified="([^"]*)")?\s*/>"#
                                )
                                let nsBody = body as NSString
                                let matches = filePattern?.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) ?? []
                                for match in matches {
                                    let path = match.range(at: 1).location != NSNotFound ? nsBody.substring(with: match.range(at: 1)) : ""
                                    let sizeStr = match.range(at: 3).location != NSNotFound ? nsBody.substring(with: match.range(at: 3)) : "0"
                                    let modStr = match.range(at: 4).location != NSNotFound ? nsBody.substring(with: match.range(at: 4)) : ""
                                    if !path.isEmpty {
                                        userAttachments.append(AttachmentMeta(
                                            path: path,
                                            size: Int(sizeStr) ?? 0,
                                            modified: isoFormatter.date(from: modStr) ?? self.createdAt
                                        ))
                                    }
                                }
                            } else {
                                // Legacy YAML format: - path: ...
                                var currentPath: String?
                                var currentSize: Int?
                                var currentModified: Date?
                                for line in body.components(separatedBy: "\n") {
                                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                                    if trimmed.hasPrefix("- path: ") {
                                        if let path = currentPath {
                                            userAttachments.append(AttachmentMeta(
                                                path: path,
                                                size: currentSize ?? 0,
                                                modified: currentModified ?? self.createdAt
                                            ))
                                        }
                                        currentPath = String(trimmed.dropFirst("- path: ".count))
                                        currentSize = nil
                                        currentModified = nil
                                    } else if trimmed.hasPrefix("size: ") {
                                        currentSize = Int(trimmed.dropFirst("size: ".count))
                                    } else if trimmed.hasPrefix("modified: ") {
                                        currentModified = isoFormatter.date(from: String(trimmed.dropFirst("modified: ".count)))
                                    }
                                }
                                if let path = currentPath {
                                    userAttachments.append(AttachmentMeta(
                                        path: path,
                                        size: currentSize ?? 0,
                                        modified: currentModified ?? self.createdAt
                                    ))
                                }
                            }
                        } else {
                            // No closing tag — strip from opening tag to end
                            endBound = s.endIndex
                        }
                        displayStr = String(s[s.startIndex..<range.lowerBound] + s[endBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Strip model-facing attachment markers from user-visible text.
                // These are generated in AIChatViewModel when building the LLM payload
                // (`[attached image: /var/minis/...]` next to inline image data, and
                // `[image omitted to save context — ...]` when eviction replaces
                // image bytes with a text placeholder). The UI already renders the
                // real attachments via `msg.attachments` parsed from the
                // <user-attached-files> XML above, so leaving these markers in the
                // display string produces the duplicated raw-path text users see
                // after reloading history.
                if role == .user && !displayStr.isEmpty {
                    displayStr = Self.stripSystemReminders(displayStr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if role == .user && !displayStr.isEmpty {
                    displayStr = Self.stripAttachmentMarkers(displayStr)
                }
                if !displayStr.isEmpty {
                    if !textContent.isEmpty { textContent += "\n" }
                    textContent += displayStr
                }

            case .mediaRef(let ref):
                let fileURL = mediaResolver(ref)
                if role == .user {
                    // [T-paste-mediaref] Exception to the skip below: a pasted
                    // text ref has no <user-attached-files> XML entry (it is
                    // conversation content, not a picked file), so nothing else
                    // would render it. Emit an AttachmentMeta so it shows the
                    // same file card as any document — `fileName` comes from the
                    // path, and `Pasted#N.txt` already maps to the doc.text icon.
                    if PastePlaceholder.isPastedTextRef(ref) {
                        let size = ((try? FileManager.default
                            .attributesOfItem(atPath: fileURL.path)[.size]) as? Int) ?? 0
                        let pastedId = PastePlaceholder.idFromMediaRefFileName(ref.originalFileName)
                        // Exact character count for the "#N · n chars" chip —
                        // bytes ≠ characters for CJK. Pasted files are capped
                        // at the placeholder threshold, so this is a bounded
                        // small read, and only for pasted refs.
                        let charCount = (try? String(contentsOf: fileURL, encoding: .utf8).count) ?? size
                        // Re-inject the position marker the split removed from
                        // the stored text, so the reloaded bubble shows WHERE
                        // the paste sits — matching the live bubble, which now
                        // keeps the literal verbatim.
                        if let pastedId {
                            if !textContent.isEmpty { textContent += "\n" }
                            textContent += PastePlaceholder.literal(for: pastedId)
                        }
                        // Path must be under /var/minis/ for AttachmentMeta to
                        // derive a resolvable `minis://` URL — the host path
                        // would fall through minisURL's guard unchanged and the
                        // card's tap would try to open a raw filesystem path.
                        // Rebuilt from relativePath (`<sid>/attachments/<uuid>.txt`)
                        // rather than ref.linuxPath, which is deliberately nil:
                        // a pasted ref is program-read content, not a file the
                        // model's shell tools should be able to discover.
                        //
                        // The stored file is named by UUID, so the DISPLAY name
                        // comes from originalFileName (`Pasted#N.txt`) — without
                        // this the card would show a bare UUID.
                        // relativePath is `<sid>/pasted/<uuid>.txt`; the minis://
                        // resolver looks up `<base>/<sid>/<host>/<subPath>`, so
                        // host+subPath must be the REAL on-disk name (the uuid),
                        // not the display name — pointing it at `Pasted#N.txt`
                        // would 404.
                        let rel = ref.relativePath as NSString
                        let realName = rel.lastPathComponent
                        let host = (rel.deletingLastPathComponent as NSString).lastPathComponent
                        userAttachments.append(AttachmentMeta(
                            path: "/var/minis/\(host)/\(realName)",
                            size: size,
                            modified: Date(),
                            displayName: ref.originalFileName,
                            pastedId: pastedId,
                            pastedCharCount: charCount
                        ))
                    }
                    // Legacy: skip mediaRef for user messages — attachment metadata
                    // comes from <user-attached-files> XML which has the correct paths.
                    // Old sessions stored both YAML/XML + mediaRef (with different filenames), causing duplicates.
                } else {
                    let block = AssistantBlock(kind: .text, content: "")
                    block.imageFilePath = fileURL.path
                    blocks.append(block)
                }

            case .toolUse(let tu):
                let kind: AssistantBlockKind
                let content: String
                switch tu.name {
                case "shell_execute":
                    let cmd = extractCommandFromJSON(tu.input)
                    kind = .shellTool(command: cmd)
                    content = "$ \(cmd)"
                case "file_read":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileReadTool(path: path)
                    content = "Reading \(path)..."
                case "file_write":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileWriteTool(path: path)
                    content = "Writing \(path)..."
                case "file_edit":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .fileEditTool(path: path)
                    content = "Editing \(path)..."
                case "browser_use":
                    let action = extractStringParam("action", from: tu.input)
                    kind = .browserTool(action: action)
                    content = "Browser: \(action)"
                    // Restore browserURL from args or inherit from preceding browser block
                    let argURL = extractStringParam("url", from: tu.input)
                    if !argURL.isEmpty {
                        lastBrowserURL = argURL
                    }
                case "read_image":
                    let path = extractStringParam("path", from: tu.input)
                    kind = .readImageTool(path: path)
                    content = "Reading image \(path)..."
                case "memory_write", "memory_get":
                    kind = .memoryTool(action: tu.name)
                    content = tu.name == "memory_write" ? "Writing memory..." : "Reading memory..."
                case SubAgentDefinition.toolName:
                    kind = .delegateTool(title: tu.description ?? "")
                    content = "Delegating..."
                case UserAskTool.name:
                    // [T-user-ask] The card renders from the input (questions)
                    // and, once paired, the result JSON in `content`.
                    kind = .userAskTool
                    content = ""
                default:
                    kind = .shellTool(command: tu.name)
                    content = tu.name
                }
                // Seed as .running so applyToolResults (called when the paired
                // tool_result user message is processed) can recognize this block as
                // "not yet finalized". loadSession finalizes any blocks still left in
                // .running / .streaming after all messages are processed — those are
                // orphaned tool_uses (app killed / run cancelled before the result
                // was persisted) and are marked .cancelled.
                let block = AssistantBlock(kind: kind, content: content, toolStatus: .running, toolUseId: tu.toolUseId)
                block.toolSummary = tu.description
                block.toolInputArgs = tu.input
                // Restore browserURL: use arg URL or inherit from last browser block
                if case .browserTool = kind {
                    block.browserURL = lastBrowserURL
                }
                blocks.append(block)

            case .toolResult(let tr):
                // Match this result to its preceding toolUse block and update it.
                if let blockIdx = blocks.lastIndex(where: { $0.toolUseId == tr.toolUseId }) {
                    // [T-tool-title-reminder] Model-facing note, not card text.
                    blocks[blockIdx].content = ToolTitleReminder.stripForDisplay(tr.output)
                    // Prefer the explicit persisted status (distinguishes cancelled from failed);
                    // fall back to the success bool for rows written before the status field existed.
                    switch tr.status {
                    case "cancelled": blocks[blockIdx].toolStatus = .cancelled
                    case "failed":    blocks[blockIdx].toolStatus = .failed(message: "")
                    case "success":   blocks[blockIdx].toolStatus = .success
                    default:          blocks[blockIdx].toolStatus = tr.success ? .success : .failed(message: "")
                    }
                    // Restore screenshot image from persisted mediaRef
                    let ref = tr.mediaRef ?? tr.snapshot?.mediaRef
                    if let ref {
                        blocks[blockIdx].imageFilePath = mediaResolver(ref).path
                    }
                    // Restore browserURL from persisted pageURL
                    if let pageURL = tr.pageURL, !pageURL.isEmpty {
                        blocks[blockIdx].browserURL = pageURL
                        lastBrowserURL = pageURL
                    }
                } else {
                    if !textContent.isEmpty { textContent += "\n" }
                    textContent += ToolTitleReminder.stripForDisplay(tr.output)
                }
            }
        }

        // Prepend thinking block if reasoning content was stored and thinking display is enabled
        if showThinking, role == .assistant, let rc = reasoningContent, !rc.isEmpty {
            blocks.insert(AssistantBlock(kind: .thinking, content: rc), at: 0)
        }

        let msg = ChatMessage(role: uiRole, content: textContent, blocks: blocks)
        // Deduplicate attachments by path
        var seenPaths = Set<String>()
        msg.attachments = userAttachments.filter { seenPaths.insert($0.path).inserted }
        if let usage = tokenUsage {
            msg.usage = TokenUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheCreationTokens: usage.cacheCreationTokens,
                cacheReadTokens: usage.cacheReadTokens,
                latestContextTokens: usage.latestContextTokens ?? 0,
                estimatedRequestTokens: usage.estimatedRequestTokens ?? 0,
                estimatedFixedTokens: usage.estimatedFixedTokens ?? 0,
                calibrationModelId: usage.calibrationModelId,
                estimatorVersion: usage.estimatorVersion ?? 0
            )
            // [T-usage-capsule-time] Restore the completion clock from the row
            // rather than stamping Date() here — this runs on RELOAD, so a
            // fresh stamp would relabel every past turn with the time the
            // session was opened. `createdAt` is written by buildRawMessage at
            // persist time, which for an assistant turn is after it finished,
            // so it is the completion time this capsule wants. Set only
            // alongside usage, matching the live path and the capsule's own
            // render condition.
            msg.completedAt = createdAt
        }
        msg.streamInterruptCount = streamInterruptCount
        // [T-error-persist-ios] Restore the persisted error indicator so a failed
        // past turn still shows its error after session reload / app restart.
        // Treat empty/whitespace as no-error (UI gates on `error != nil`, so an
        // empty string would show a blank banner).
        if let e = errorInfo, !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msg.error = e
        }
        return msg
    }

    /// Strip model-facing attachment markers from user display text.
    /// Removes `[attached <kind>: ...]` (image / file / audio / video / …)
    /// and `[image omitted to save context — ...]` tokens produced by the
    /// send/compaction paths for the LLM; the UI surfaces real attachments
    /// via `msg.attachments` parsed from the <user-attached-files> XML, so
    /// these tokens are pure noise to the user.
    /// [T-ios-listsessions-perf] Compiled once. These two patterns were
    /// rebuilt on every call, and this runs for every session on every sidebar
    /// refresh — 69 G cycles in the profiler trace, nearly all of it
    /// `uregex_open`. NSRegularExpression is immutable and thread-safe, so a
    /// shared instance is safe for the concurrent callers here.
    private static let attachmentMarkerRes: [NSRegularExpression] = [
        #"\[attached [A-Za-z]+:[^\]]*\]"#,
        #"\[image omitted to save context[^\]]*\]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func stripAttachmentMarkers(_ s: String) -> String {
        var out = s
        // Fast path: the markers are ASCII and most messages have neither. A
        // byte scan for "[" skips both regex passes for the common case.
        if out.utf8.contains(UInt8(ascii: "[")) {
            for re in attachmentMarkerRes {
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        // Collapse blank lines left behind and trim surrounding whitespace.
        let lines = out.components(separatedBy: "\n")
        var cleaned: [String] = []
        var lastBlank = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let blank = trimmed.isEmpty
            if blank && lastBlank { continue }
            cleaned.append(line)
            lastBlank = blank
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove `<system-reminder>...</system-reminder>` segments from display text
    /// before display. Markers are kept in agentHistory so the model still sees them
    /// on resume/continue, but they should never surface in the chat bubble.
    /// [T-ios-longmsg-cell-split] Split an over-long assistant reply into
    /// paragraph-aligned segments so no single cell has to back an enormous
    /// CALayer. Returns `[text]` unchanged for normal replies.
    ///
    /// Thresholds come from measurement, not taste. The reported collapse
    /// carried 9156 chars in one block and measured 20615.3pt on the reporter's
    /// @3x device (61846px) and 20711.5pt when reproduced on an iPhone 11
    /// (41423px). Splitting at 4000 chars puts that message into ~3 cells of
    /// roughly 5-7K pt each — comfortably under any per-layer limit and, more
    /// importantly, small enough that the list stops being one giant cell
    /// (`visibleCells=1` in the field log) and can recycle normally.
    ///
    /// `splitMarkdownIntoSegments` is reused verbatim from
    /// `PaginatedMarkdownView` (T-markdown-preview-paginate), which solved the
    /// same CALayer problem for document preview in May. It is fence-aware, so
    /// a fenced code block is never cut in half, and each returned segment
    /// parses independently under cmark.
    ///
    /// Known limitation: a single markdown TABLE longer than the threshold
    /// still lands in one segment, because the splitter only breaks at blank
    /// lines outside fences and table rows carry none. Tables therefore stay
    /// exactly as they render today — no better, no worse.
    static func splitLongAssistantText(_ text: String) -> [String] {
        guard text.count > longTextSplitThreshold else { return [text] }
        let segments = splitMarkdownIntoSegments(text, targetSize: longTextSegmentTarget)
        // Defensive: never let splitting lose or empty out content. If the
        // splitter returns nothing usable, keep the original single block —
        // a too-tall cell is far better than a vanished reply.
        let rejoinedCount = segments.reduce(0) { $0 + $1.count }
        guard !segments.isEmpty, rejoinedCount >= text.count / 2 else { return [text] }
        return segments
    }

    /// Replies longer than this are split. Below it, behaviour is byte-identical
    /// to before (one block, one cell).
    private static let longTextSplitThreshold = 4000
    /// Target size per segment; the splitter overshoots to the next paragraph
    /// break, and never cuts inside a fenced code block.
    private static let longTextSegmentTarget = 4000

    /// Display only: see SystemReminderStripper. What the model receives is
    /// never passed through this.
    static func stripSystemReminders(_ text: String) -> String {
        SystemReminderStripper.strip(text)
    }
}

// BEGIN SystemReminderStripper
/// [T-user-bubble-reminder-strip] `<system-reminder>…</system-reminder>` is a
/// reserved, model-only tag: the app and the model put notes for the model in
/// it (the answer to a deferred user_ask arrives as a user message ending in
/// one). Every place that SHOWS text removes it - user bubbles, previews,
/// search snippets - through this one implementation; what is sent to the
/// model keeps it.
///
/// Handled: several tags, tags spanning lines, any letter case, tags nested
/// inside one another (the whole outer region goes), a tag that never closes
/// (a stream cut mid-note: everything from it to the end goes) and a stray
/// closing tag (the tag alone goes). A user who types the tag by hand gets the
/// same treatment: it is reserved, and showing it in one place but hiding it
/// in another would be worse.
enum SystemReminderStripper {
    private static let name = Array("system-reminder".utf8)

    /// Removes every reminder region; text without one is returned as is.
    static func strip(_ text: String) -> String {
        // Cheap guards first, no allocation for the common case: almost no
        // message carries a reminder, and most carry no "<" at all.
        guard text.utf8.contains(UInt8(ascii: "<")) else { return text }
        let bytes = Array(text.utf8)
        guard firstTag(bytes) != nil else { return text }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var depth = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<"), let t = tag(in: bytes, at: i) {
                if t.closing {
                    if depth > 0 { depth -= 1 }  // a stray closing tag is dropped alone
                } else {
                    depth += 1
                }
                i = t.end
                continue
            }
            if depth == 0 { out.append(bytes[i]) }
            i += 1
        }
        // Tags are pure ASCII, so every cut fell on a character boundary.
        return String(decoding: out, as: UTF8.self)
    }

    /// The text a user bubble shows: the message minus the attached-files
    /// metadata block and every reminder, trimmed. The bubble and its height
    /// measurement both use this, so they cannot disagree.
    static func userBubbleText(_ content: String) -> String {
        var text = content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
        }
        return strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstTag(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "<"), tag(in: bytes, at: i) != nil { return i }
            i += 1
        }
        return nil
    }

    /// `<system-reminder>` or `</system-reminder>` (any case, optional spaces
    /// before `>`) starting at `i`: whether it closes, and the index after it.
    private static func tag(in bytes: [UInt8], at i: Int) -> (closing: Bool, end: Int)? {
        guard i >= 0, i < bytes.count, bytes[i] == UInt8(ascii: "<") else { return nil }
        var j = i + 1
        var closing = false
        if j < bytes.count, bytes[j] == UInt8(ascii: "/") { closing = true; j += 1 }
        guard j + name.count <= bytes.count else { return nil }
        for k in 0..<name.count {
            var b = bytes[j + k]
            if b >= 65, b <= 90 { b += 32 }  // ASCII lowercase
            if b != name[k] { return nil }
        }
        j += name.count
        while j < bytes.count, bytes[j] == UInt8(ascii: " ") { j += 1 }
        guard j < bytes.count, bytes[j] == UInt8(ascii: ">") else { return nil }
        return (closing, j + 1)
    }
}
// END SystemReminderStripper

// MARK: - AgentMessage Conversion

extension RawMessage {
    /// Convert to an AgentMessage for rebuilding agent history on session load.
    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {
        let agentRole: AgentMessage.Role = role == .user ? .user : .assistant
        var agentParts: [AgentContentPart] = []

        for part in parts {
            switch part {
            case .text(let s):
                agentParts.append(.text(s))
            case .mediaRef(let ref):
                // [T-paste-mediaref] A pasted-text ref is conversation content,
                // not an image. Inline it as `.text` at this exact position so
                // a reloaded session sends the model the same prompt it saw
                // originally. Without this gate the UTF-8 bytes would be handed
                // to the provider as `.imageData` and base64-encoded as a
                // corrupt image — silent data loss on every app restart.
                if PastePlaceholder.isPastedTextRef(ref) {
                    if let data = try? Data(contentsOf: mediaResolver(ref)),
                       let s = String(data: data, encoding: .utf8) {
                        agentParts.append(.text(s))
                    } else {
                        // [T-paste-mediaref] The file is gone (cache purge,
                        // iCloud orphan sweep, manual delete). Emit an explicit
                        // marker rather than appending nothing: a silent drop
                        // would make the model answer as if the user had never
                        // pasted anything, with no signal that context is
                        // missing.
                        agentParts.append(.text(PastePlaceholder.unavailableMarker))
                    }
                } else if let image = Self.rebuiltImagePart(ref, mediaResolver: mediaResolver) {
                    // [T-image-real-seams] nil when the media file is gone.
                    agentParts.append(image)
                }
            case .toolUse(let tu):
                let input = parseJSONToDict(tu.input)
                agentParts.append(.toolUse(id: tu.toolUseId, name: tu.name, input: input))
            case .toolResult(let tr):
                let (imgData, imgMime) = Self.rebuiltToolResultImage(tr.mediaRef, mediaResolver: mediaResolver)
                agentParts.append(.toolResult(id: tr.toolUseId, name: "", content: tr.output, isError: !tr.success, imageData: imgData, imageMimeType: imgMime, imageLinuxPath: tr.mediaRef?.linuxPath))
            }
        }

        var msg = AgentMessage(role: agentRole, parts: agentParts)
        msg.reasoningContent = reasoningContent
        // [T-responses-echo-persist] Restore the native reasoning head. Before
        // this, `reasoningEcho` was in-memory only, so every turn rehydrated
        // from the DB reached the Responses builder with no echo and no real
        // item id — the hole the synthetic `rs_syn_` id was invented to plug
        // and then 404'd on. Items come back without `encrypted_content` by
        // design (see ReasoningEcho.persistableJSON).
        msg.reasoningEcho = ReasoningEcho(persistedJSON: reasoningEchoJSON)
        return msg
    }
}

// MARK: - Images on session reload [T-image-real-seams]

// BEGIN RebuildImageParts
extension RawMessage {
    /// A user-message image ref read back as `.imageData`, or nil when the
    /// media file is gone - toAgentMessage then drops it without a trace.
    static func rebuiltImagePart(_ ref: MediaRef, mediaResolver: (MediaRef) -> URL) -> AgentContentPart? {
        var agentParts: [AgentContentPart] = []
        if let data = try? Data(contentsOf: mediaResolver(ref)) {
            agentParts.append(.imageData(data: data, mimeType: ref.mimeType, linuxPath: ref.linuxPath))
        }
        return agentParts.first
    }

    /// A tool result's image read back from its mediaRef: the file's bytes and
    /// their sniffed MIME (falling back to the stored one), or (nil, nil) when
    /// there is no ref or the file is gone.
    static func rebuiltToolResultImage(_ mediaRef: MediaRef?, mediaResolver: (MediaRef) -> URL) -> (data: Data?, mimeType: String?) {
        var imgData: Data? = nil
        var imgMime: String? = nil
        if let ref = mediaRef {
            let fileURL = mediaResolver(ref)
            if let data = try? Data(contentsOf: fileURL) {
                imgData = data
                // Sniff actual image format — stored mimeType may be wrong (e.g. png for jpeg data)
                imgMime = Self.sniffImageMimeType(data) ?? ref.mimeType
            }
        }
        return (imgData, imgMime)
    }

    /// Detect actual image format from file magic bytes.
    private static func sniffImageMimeType(_ data: Data) -> String? {
        guard data.count >= 3 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if data.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }
        if data.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "image/gif"
        }
        if data.count >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "image/webp"
        }
        return nil
    }
}
// END RebuildImageParts

// MARK: - JSON Helpers for UI Conversion

private func extractCommandFromJSON(_ json: String) -> String {
    extractStringParam("command", from: json)
}

private func extractStringParam(_ key: String, from json: String) -> String {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = dict[key] as? String else {
        return ""
    }
    return value
}
