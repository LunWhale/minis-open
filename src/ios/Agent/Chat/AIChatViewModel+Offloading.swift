import Foundation
import ImageIO
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Context Window Offloading

extension AIChatViewModel {

    // MARK: - Context Window Offloading

    /// Marker that opens every offload stub written into `agentHistory`.
    ///
    /// [T-offload-placeholder-write-guard issue #374] Shared with the write-tool
    /// gate in +ConcurrentTools.swift, which refuses a file_write / file_edit
    /// whose payload IS a stub: offloading rewrites a historical file_write's
    /// `content` argument to this text, so a call re-issued from that rewritten
    /// history would put the ~130-char placeholder on disk over the real file.
    /// Mirrors Android `ContextOffload.OFFLOADED_PREFIX`.
    nonisolated static let offloadedStubPrefix = "[CONTEXT OFFLOADED]"

    /// [T-offload-stub-system-reminder issue #374] Marker for the current stub
    /// format. The pruned-argument notice is now wrapped in a
    /// `<system-reminder>` envelope carrying this tag, so the model reads it as
    /// a meta-instruction about a REMOVED argument rather than as content it may
    /// copy into its next call. The old plain-text form read like content
    /// ("Content (~N tokens…) saved to: …"), which is exactly why a model
    /// re-issuing its own earlier `file_write` pasted the placeholder back in.
    ///
    /// Mirrors Android `ContextOffload.SYSTEM_NOTICE_TAG`.
    nonisolated static let offloadedStubNoticeTag = "[Minis System Notice]"

    /// Envelope opener for the current stub format. Kept separate from the tag
    /// so detection can require BOTH (a bare `<system-reminder>` is a legitimate
    /// thing for other subsystems to emit — see the persona reminder).
    nonisolated static let offloadedStubEnvelope = "<system-reminder>"

    /// True when `value` is an offload placeholder in EITHER format.
    ///
    /// Both are recognised on purpose and neither branch may be dropped:
    ///   • the `<system-reminder>` + `[Minis System Notice]` form is what the
    ///     offloader writes now;
    ///   • the bare `[CONTEXT OFFLOADED]` form is still present in every
    ///     session persisted before this change, and in iCloud-synced history
    ///     from a peer on an older build. Those stubs keep arriving for as long
    ///     as such histories exist, so the legacy test is not transitional.
    ///
    /// Leading whitespace is trimmed first: a provider may prefix a newline.
    /// The test is anchored at the start, not `contains`, so prose that merely
    /// discusses the marker is still written normally.
    ///
    /// Mirrors Android `ContextOffload.isOffloadPlaceholder`.
    nonisolated static func isOffloadedStub(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(offloadedStubPrefix) { return true }
        return trimmed.hasPrefix(offloadedStubEnvelope)
            && trimmed.contains(offloadedStubNoticeTag)
    }

    /// The pruned-argument notice handed to the model in place of a `file_write`
    /// / `file_edit` payload that was moved to disk. Mirrors Android
    /// `ContextOffload.stub`.
    nonisolated static func offloadedStubNotice(tokens: Int, bytes: Int, linuxPath: String) -> String {
        """
        \(offloadedStubEnvelope)
        \(offloadedStubNoticeTag) The original content (~\(tokens) tokens, \(bytes) bytes) \
        of this tool argument has been pruned to save context and offloaded to: \(linuxPath)

        CRITICAL: This is a placeholder notice, NOT actual file content. NEVER pass this \
        placeholder or reuse it in subsequent file_write or file_edit calls. If you need the \
        original content, call file_read on the offloaded path first.
        </system-reminder>
        """
    }

    /// Save context content to disk for later retrieval via file_read.
    /// Returns the Linux-visible path where the file was saved.
    /// Derive a short unique suffix from a tool ID for use in file names.
    /// Anthropic IDs are `toolu_01XXXX...` (prefix is always `toolu_01`),
    /// so we take the last 12 characters to guarantee uniqueness.
    private nonisolated static func shortToolId(_ toolId: String) -> String {
        String(toolId.suffix(12))
    }

    func offloadContextContent(_ content: String, toolId: String, toolName: String, ext: String = "txt") -> String {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"
        let persistDir = Self.minisOffloadsPersistentDir(for: sid)
            .appendingPathComponent("tools", isDirectory: true)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let sanitizedName = toolName.isEmpty ? "tool" : toolName.replacingOccurrences(of: "/", with: "_")
        let shortId = Self.shortToolId(toolId)
        let fileName = "\(sanitizedName)_\(shortId).\(ext)"
        let persistPath = persistDir.appendingPathComponent(fileName)
        try? content.write(to: persistPath, atomically: true, encoding: .utf8)

        return "\(Self.minisOffloadsLinuxDir)/tools/\(fileName)"
    }

    /// Save context image data to disk for later retrieval.
    /// Returns the Linux-visible path where the file was saved.
    private func offloadContextImage(_ data: Data, toolId: String, mimeType: String) -> String {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"
        let persistDir = Self.minisOffloadsPersistentDir(for: sid)
            .appendingPathComponent("tools", isDirectory: true)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let ext: String
        switch mimeType {
        case "image/png": ext = "png"
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "bin"
        }

        let shortId = Self.shortToolId(toolId)
        let fileName = "image_\(shortId).\(ext)"
        let persistPath = persistDir.appendingPathComponent(fileName)
        try? data.write(to: persistPath)

        return "\(Self.minisOffloadsLinuxDir)/tools/\(fileName)"
    }

    /// Decode the pixel dimensions of an image blob without fully decoding it.
    /// Returns (width, height) or nil on failure.
    private static func imagePixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f
    }()

    /// Build the text placeholder that replaces an image omitted from the
    /// sent context. Dimensions + byte size give the model enough semantic
    /// context to recognize the image from memory, and the path hints let
    /// it re-fetch the bytes via `read_image` when needed.
    ///
    /// Two forms:
    /// - Stable original (no snapshot needed): `originalPath` set,
    ///   `snapshotPath` nil.
    /// - Volatile original (snapshot written as fallback): both set.
    static func imagePlaceholderText(
        data: Data,
        originalPath: String?,
        snapshotPath: String?
    ) -> String {
        let size = byteFormatter.string(fromByteCount: Int64(data.count))
        let dims: String
        if let (w, h) = imagePixelSize(data) { dims = "\(w)×\(h), \(size)" }
        else { dims = size }

        switch (originalPath, snapshotPath) {
        case let (orig?, snap?):
            return "[image omitted to save context — \(dims) — original: \(orig); snapshot: \(snap), use read_image on snapshot if original is unavailable]"
        case let (orig?, nil):
            return "[image omitted to save context — \(dims) — original: \(orig), use read_image to view again]"
        case let (nil, snap?):
            return "[image omitted to save context — \(dims) — saved to \(snap), use read_image to view again]"
        case (nil, nil):
            return "[image omitted to save context — \(dims)]"
        }
    }

    /// Decide whether a file path (Linux view) or minis:// URL is backed by
    /// persistent session storage under `/var/minis/*`. Paths in those
    /// locations survive shell restarts, session reloads, and cross-day
    /// reopens, so we don't need to write a snapshot copy of the bytes.
    ///
    /// Anything else (`/tmp/*`, absent, unknown prefix) is considered
    /// volatile and must be snapshotted before the original is dropped from
    /// context.
    private static func isPersistentMinisPath(_ path: String) -> Bool {
        // Linux view: bind-mounted persistent directories under /var/minis
        if path.hasPrefix("/var/minis/workspace/") { return true }
        if path.hasPrefix("/var/minis/browser/") { return true }
        if path.hasPrefix("/var/minis/attachments/") { return true }
        if path.hasPrefix("/var/minis/offloads/") { return true }
        // minis:// URL view maps 1:1 to the directories above
        if path.hasPrefix("minis://workspace/") { return true }
        if path.hasPrefix("minis://browser/") { return true }
        if path.hasPrefix("minis://attachments/") { return true }
        if path.hasPrefix("minis://offloads/") { return true }
        return false
    }

    /// [T-offload-readback-loop] GH#343. True when `path` points into the
    /// offload store — i.e. reading it returns content the offloader itself
    /// wrote, not new information from the world.
    ///
    /// Deliberately narrower than `isPersistentMinisPath`, which also accepts
    /// workspace / browser / attachments. Those are legitimate sources whose
    /// results SHOULD be offloadable when they are large; only the offload
    /// directory creates the read → offload → read cycle.
    ///
    /// `static` and `nonisolated` so the tool layer can call it while building
    /// a result, off the main actor.
    nonisolated static func isOffloadStorePath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("/var/minis/offloads/") || p.hasPrefix("minis://offloads/")
    }

    /// Extract the original accessible path of an image produced by a known
    /// tool, so the placeholder can reference it as a semantic hint (and,
    /// when the path is persistent, skip writing a snapshot copy).
    ///
    /// Returns nil when no path is recoverable — the caller must write a
    /// snapshot in that case.
    ///
    /// - `toolName`: the tool that produced the result. May be empty when
    ///   the message was rehydrated from persistence (ChatStore drops the
    ///   name on reload); callers pass the tool_use name they recovered
    ///   from the matching `tool_use` block.
    /// - `input`: the `tool_use` input JSON for this call.
    /// - `content`: the textual `tool_result` body. Used to recover paths
    ///   that only the tool knows at runtime (e.g. browser screenshot URLs
    ///   emitted as `minis_url: minis://...`).
    private static func originalImagePath(
        toolName: String,
        input: [String: Any]?,
        content: String
    ) -> String? {
        // read_image: absolute path is the first positional argument.
        if toolName == "read_image", let path = input?["path"] as? String, !path.isEmpty {
            return path
        }
        // browser_use (any action) appends `minis_url: minis://...` to the
        // result content when it persists a screenshot or fetched file to
        // /var/minis/browser/. Extract that URL.
        if toolName == "browser_use" || toolName.isEmpty {
            if let urlRange = content.range(of: #"minis://\S+"#, options: .regularExpression) {
                return String(content[urlRange])
            }
        }
        return nil
    }

    /// Trim old images from `agentHistory` so at most `kImageContextKeepCount`
    /// images remain in the context sent to the model. Older images are
    /// replaced with a text placeholder.
    ///
    /// Snapshot policy: an image is **not** copied to offloads when its
    /// original path lives under `/var/minis/*` (workspace, browser,
    /// attachments, offloads) — those directories are persistent and the
    /// placeholder's path hint is enough for the model to re-fetch via
    /// `read_image`. Any other origin — volatile (`/tmp/*`), unknown, or a
    /// standalone user attachment with no path at all — is snapshotted
    /// via `offloadContextImage` so inference can continue even if the
    /// original is lost. When a snapshot is taken alongside a volatile
    /// original path, both are surfaced in the placeholder so the model
    /// prefers the semantic original and falls back to the snapshot.
    ///
    /// This is a destructive in-place rewrite of `agentHistory` (same
    /// contract as `offloadContextIfNeeded`). It runs *before* token-based
    /// offloading so image bytes are removed first, reducing the pressure on
    /// the subsequent token-window offload decision.
    func trimOldImagesFromHistory() {
        let keep = Self.kImageContextKeepCount

        // First pass: index tool_use calls by id (for name + input lookup)
        // and count total images across the history. Rehydrated messages
        // lose the name on `.toolResult`, so the index is the canonical
        // source of truth for tool metadata.
        var toolCallById: [String: (name: String, input: [String: Any])] = [:]
        var totalImages = 0
        for msg in agentHistory {
            for part in msg.parts {
                switch part {
                case .toolUse(let id, let name, let input, _):
                    toolCallById[id] = (name: name, input: input)
                case .toolResult(_, _, _, _, let imgData, _, _, _, _):
                    if imgData != nil { totalImages += 1 }
                case .imageData:
                    totalImages += 1
                default:
                    break
                }
            }
        }
        guard totalImages > keep else { return }

        // Evict the oldest `totalImages - keep` images so the most recent
        // `keep` remain as real bytes.
        let evictCount = totalImages - keep
        var evicted = 0
        var snapshotsWritten = 0

        for mi in agentHistory.indices {
            if evicted >= evictCount { break }
            let parts = agentHistory[mi].parts
            var newParts = parts
            var mutated = false

            for pi in parts.indices {
                if evicted >= evictCount { break }
                switch parts[pi] {
                case .toolResult(let id, let name, let content, let isError, let imgData, let mime, let pageURL, _, let isReadback):
                    guard let data = imgData else { continue }

                    let call = toolCallById[id]
                    let effectiveName = !name.isEmpty ? name : (call?.name ?? "")
                    let originalPath = Self.originalImagePath(
                        toolName: effectiveName,
                        input: call?.input,
                        content: content
                    )

                    // Decide whether to snapshot: only skip the copy when the
                    // original path is under /var/minis/* (persistent).
                    let snapshotPath: String?
                    if let op = originalPath, Self.isPersistentMinisPath(op) {
                        snapshotPath = nil
                    } else {
                        snapshotPath = offloadContextImage(data, toolId: id, mimeType: mime ?? "image/jpeg")
                        snapshotsWritten += 1
                    }

                    let placeholder = Self.imagePlaceholderText(
                        data: data,
                        originalPath: originalPath,
                        snapshotPath: snapshotPath
                    )
                    let newContent = content.isEmpty ? placeholder : "\(content)\n\n\(placeholder)"
                    newParts[pi] = .toolResult(
                        id: id, name: name, content: newContent,
                        isError: isError, imageData: nil, imageMimeType: nil, pageURL: pageURL,
                        // [T-offload-readback-loop] Carry the flag across the rebuild.
                        imageLinuxPath: nil, isOffloadReadback: isReadback
                    )
                    mutated = true
                    evicted += 1

                case .imageData(let data, let mime, _):
                    // Standalone image (user attachment) — no tool id, no
                    // recoverable original path. Always snapshot.
                    let synthId = "img-\(sessionId ?? "s")-\(mi)-\(pi)"
                    let snap = offloadContextImage(data, toolId: synthId, mimeType: mime)
                    snapshotsWritten += 1
                    let placeholder = Self.imagePlaceholderText(
                        data: data, originalPath: nil, snapshotPath: snap
                    )
                    newParts[pi] = .text(placeholder)
                    mutated = true
                    evicted += 1

                default:
                    break
                }
            }

            if mutated {
                // [T-history-rebuild-keeps-ids] Replace the parts in place.
                // Rebuilding the message dropped `dbMessageId` and
                // `reasoningEcho`: when the evicted image sat in the v2
                // compaction anchor, the anchor lookup then failed and
                // effectiveAgentHistory fell back to the FULL history (the
                // compaction silently undone), and reasoning echo was lost.
                agentHistory[mi].parts = newParts
            }
        }

        if evicted > 0 {
            logger.info("🖼️ Context image trim: evicted \(evicted) old image(s) (snapshots: \(snapshotsWritten)), kept last \(keep) (total was \(totalImages))")
        }
    }

    /// Check if context is approaching the model's window limit and offload old tool content.
    ///
    /// Uses a **subtraction method**: starts from the real `lastContextTokens` reported by the API,
    /// and subtracts each offloaded part's token count until the context drops to the policy's
    /// offload target. The per-part count is ContextSizeMeter's calibrated estimate — the same
    /// scale the context meter reports — not BPE: tokenizing every candidate on the main thread
    /// froze the UI for 8-9 s in long chats [T-offload-scan-cache].
    /// Estimate total agentHistory token count using character-based heuristic.
    /// Uses ~3.5 chars/token for mixed English/CJK/code content (conservative).
    /// Also accounts for image data tokens (~85 tokens per 1KB of base64).
    ///
    /// Estimates against `effectiveAgentHistory()` — the slice that actually
    /// reaches the model — not the raw `agentHistory`. After compact-v2
    /// (90ac63e8), the raw history is preserved while marker overlay trims
    /// what's sent; estimating against the raw log made post-compact usage
    /// look unchanged and fired the "near capacity" prompt before every send.
    func estimateContextTokens(_ caller: String = #function) -> Int {
        var totalChars = 0
        var imageTokens = 0
        let slice = effectiveAgentHistory()
        // DIAG: per-message breakdown so we can see EXACTLY what occupies the
        // post-compact context. Logs every message's role + part summary +
        // token estimate; lets us tell whether bloat comes from the injected
        // summary, pre-anchor warm-up turns, or post-anchor tool results.
        var perMsg: [String] = []
        var biggest: [(kind: String, chars: Int, msgIdx: Int)] = []
        for (idx, msg) in slice.enumerated() {
            var msgChars = 0
            var msgImgTok = 0
            var partTags: [String] = []
            for part in msg.parts {
                var partChars = 0
                var partKind = ""
                switch part {
                case .text(let t):
                    partChars = t.count
                    let isSummary = t.contains("<context-summary>")
                    partKind = isSummary ? "SUMMARY" : "text"
                case .toolUse(_, let name, let input, _):
                    if let data = try? JSONSerialization.data(withJSONObject: input) {
                        partChars = data.count
                    }
                    partKind = "tu:\(name)"
                case .toolResult(_, _, let content, _, let imgData, _, _, _, _):
                    partChars = content.count
                    if let imgData = imgData {
                        let it = BPETokenizer.shared.countImageTokens(imgData)
                        imageTokens += it
                        msgImgTok += it
                    }
                    partKind = "tr"
                case .imageData(let data, _, _):
                    let it = BPETokenizer.shared.countImageTokens(data)
                    imageTokens += it
                    msgImgTok += it
                    partKind = "img"
                }
                msgChars += partChars
                totalChars += partChars
                partTags.append("\(partKind)=\(partChars)c")
                if partChars >= 2000 {
                    biggest.append((partKind, partChars, idx))
                }
            }
            let msgTok = Int(Double(msgChars) / 3.5) + msgImgTok
            let dbId = msg.dbMessageId?.prefix(8) ?? "----"
            perMsg.append("[\(idx) \(msg.role.rawValue) db=\(dbId) ~\(msgTok)tok | \(partTags.joined(separator: ","))]")
        }
        let totalTokens = Int(Double(totalChars) / 3.5) + imageTokens
        biggest.sort { $0.chars > $1.chars }
        let top = biggest.prefix(5).map { "[\($0.msgIdx)\($0.kind)=\($0.chars)c]" }.joined(separator: " ")
        logger.verbose("[CompactDiag] estimate caller=\(caller) slice=\(slice.count) total=\(totalTokens)tok (\(totalChars)chars+\(imageTokens)imgTok) bigParts(≥2kc): \(top)")
        logger.verbose("[CompactDiag] estimate perMsg: \(perMsg.joined(separator: " "))")
        return totalTokens
    }

    /// - `force`: When true, skip the threshold check and offload all eligible candidates
    ///   regardless of current context usage. Used after compaction to unconditionally slim down
    ///   the kept messages.
    func offloadContextIfNeeded(model: LLMModel, lastContextTokens: Int, force: Bool = false) {
        // [T-ctx-user-cap] Build the policy the same way the capacity guards do,
        // or a 32K user cap lands in the native small-window tier and disables
        // offload (offloadThreshold == 0) for a model with ample room for it.
        let resolved = resolvedContextWindow(for: model)
        let contextWindow = resolved.window
        let policy = ContextPolicy(contextWindow: contextWindow, isUserCap: resolved.isUserCap)

        // Policy disables offloading for this context window tier
        if !force && policy.offloadThreshold == 0 {
            logger.debug("Context offload: disabled for window \(contextWindow) tokens")
            return
        }

        // [T-offload-scan-cache] Wall-clock of the whole call, logged at the end
        // so a device log shows directly whether an offload still stalls.
        let offloadStart = CFAbsoluteTimeGetCurrent()

        // When no baseline is passed (the post-compact FORCE call), measure the
        // outbound request the same way the per-iteration call does. It is the
        // cached, calibrated meter — `estimateContextTokens()` re-counted every
        // character of the effective history and built a per-message diagnostic
        // string on the main thread, on the one path that also offloads the most.
        var effectiveTokens = lastContextTokens
        if lastContextTokens == 0 {
            effectiveTokens = measureOutboundContextTokens()
            if !force {
                if effectiveTokens < policy.offloadThreshold {
                    let remaining = contextWindow - effectiveTokens
                    logger.debug("Context offload: skipped (estimate \(effectiveTokens)/\(contextWindow), remaining ~\(remaining) tokens)")
                    return
                }
            }
            logger.info("Context offload: no API baseline — using outbound measurement: ~\(effectiveTokens) tokens")
        }

        let pct = Int(Double(effectiveTokens) / Double(contextWindow) * 100)

        if !force {
            guard effectiveTokens >= policy.offloadThreshold else {
                let remaining = contextWindow - effectiveTokens
                logger.debug("Context offload: below threshold — \(effectiveTokens)/\(contextWindow) (\(pct)%), remaining ~\(remaining) tokens")
                return
            }
        }

        // When forced (post-compact), offload everything eligible — no early stop target.
        let targetTokens = force ? 0 : policy.offloadTarget
        let beforeTokens = effectiveTokens
        var currentTokens = effectiveTokens

        let source = force ? "post-compact" : (lastContextTokens > 0 ? "API" : "estimate")
        let remaining = contextWindow - beforeTokens
        logger.info("━━━ Context Offload Triggered ━━━")
        logger.info("  Model: \(model.id) (window: \(contextWindow) tokens)")
        logger.info("  Before: \(beforeTokens) tokens (\(pct)% of window, ~\(remaining) remaining) [source: \(source)]")
        if force {
            logger.info("  Mode: FORCE (post-compact) — offloading all eligible candidates")
        } else {
            logger.info("  Threshold: \(policy.offloadThreshold) — Target: \(targetTokens)")
            logger.info("  Need to free: ~\(beforeTokens - targetTokens) tokens")
        }
        logger.info("  Agent history: \(self.agentHistory.count) messages")

        // Protect the last 4 messages from offloading
        let protectedCount = min(4, agentHistory.count)
        // [T-offload-scan-cache] Start after the compaction anchor: what lies
        // before it never reaches the model (see `offloadScanStartIndex`).
        let scanStart = min(offloadScanStartIndex(), agentHistory.count - protectedCount)
        let candidateRange = scanStart..<(agentHistory.count - protectedCount)
        logger.info("  Scanning messages \(candidateRange.lowerBound)..<\(candidateRange.upperBound) (last \(protectedCount) protected, \(scanStart) before the compaction anchor skipped)")

        // Collect offload candidates. `tokens` is ContextSizeMeter's estimate —
        // the same one the context meter (and so `lastContextTokens`) is built
        // from — so ranking and the "enough freed" check need no BPE at all.
        struct OffloadCandidate {
            let msgIdx: Int
            let partIdx: Int
            let tokens: Int
            let bytes: Int
            let toolId: String
            let toolName: String
            let cacheKey: String
        }
        let cache = offloadScanCache
        cache.beginScan()
        // Calibrated like `measureOutboundContextTokens`, so freed tokens are
        // on the same scale as the usage they are subtracted from.
        let calibrationRatio = contextCalibrationRatio(for: model.id)

        var candidates: [OffloadCandidate] = []
        var skippedAlreadyOffloaded = 0
        var skippedTooSmall = 0
        /// [T-offload-readback-loop] Parts skipped because they are the
        /// offloader's own output read back in. Counted separately from
        /// `skippedAlreadyOffloaded` so the log distinguishes "we already
        /// shrank this" from "this came back out of the store" — the second is
        /// the loop, and it used to be silent.
        var skippedOffloadReadback = 0
        /// [T-offload-toolinput-guards issue #374] Tool-use ids that already have
        /// a matching tool_result anywhere in history — i.e. calls that have
        /// demonstrably finished. Only their arguments may be pruned. Collected
        /// over the WHOLE history, not `candidateRange`, because a call inside
        /// the range is answered by a result that often sits outside it.
        var skippedUnanswered = 0
        var answeredToolUseIds: Set<String> = []
        // [T-offload-warmup-scan] The warm-up before the anchor is sent too;
        // scan the parts of it that survive the send-time prune.
        let warmUp = offloadWarmUpScanPlan()
        let warmUpIndices = warmUp.indices.filter { $0 < scanStart }
        let answeredFrom = min(warmUpIndices.first ?? scanStart, scanStart)
        // A call in the range is answered by a result after it, so starting at
        // the range start loses nothing.
        for msg in agentHistory[answeredFrom...] {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part {
                    answeredToolUseIds.insert(id)
                }
            }
        }

        if !warmUpIndices.isEmpty {
            logger.info("  Warm-up before the anchor: scanning \(warmUpIndices.count) sent message(s) (\(warmUp.prunedToolIds.count) pruned tool id(s) skipped)")
        }
        for msgIdx in warmUpIndices + Array(candidateRange) {
            let msg = agentHistory[msgIdx]
            let inWarmUp = msgIdx < scanStart
            for (partIdx, part) in msg.parts.enumerated() {
                // [T-offload-warmup-scan] Parts the send-time prune drops from
                // the warm-up never reach the model: offloading them would
                // "free" nothing and replace a dropped part with a sent stub.
                if inWarmUp {
                    switch part {
                    case .toolResult(let id, _, _, _, _, _, _, _, _), .toolUse(let id, _, _, _):
                        if warmUp.prunedToolIds.contains(id) { continue }
                    default: break
                    }
                }
                switch part {
                case .toolResult(let id, let name, let content, _, let imgData, _, _, _, let isReadback):
                    // [T-offload-scan-cache] Reuse the last verdict when the
                    // part is unchanged; an offload rewrite changes its size
                    // and stub flag, so a rewritten part is judged afresh.
                    let key = "r:\(id)"
                    let fp = OffloadScanCache.fingerprint(content: content, extraBytes: imgData?.count ?? 0,
                                                          flag: isReadback)
                    if let hit = cache.lookup(key, fingerprint: fp) {
                        switch hit.verdict {
                        case .readback: skippedOffloadReadback += 1
                        case .alreadyOffloaded: skippedAlreadyOffloaded += 1
                        case .tooSmall: skippedTooSmall += 1
                        case .candidate:
                            candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: hit.tokens, bytes: hit.bytes, toolId: id, toolName: name, cacheKey: key))
                        }
                        continue
                    }
                    // [T-offload-readback-loop] GH#343. Skip content this
                    // offloader produced and `file_read` merely fetched back.
                    //
                    // The prefix test below cannot catch it: a read-back carries
                    // the ORIGINAL payload, so it has no stub prefix and looked
                    // like brand-new material. Offloading it wrote a second file
                    // whose stub the model read, and round it went. Checked
                    // first because it is the cheaper and more specific test.
                    if isReadback {
                        skippedOffloadReadback += 1
                        cache.store(key, fingerprint: fp, verdict: .readback)
                        continue
                    }
                    // Skip already-offloaded parts. Routed through the shared
                    // predicate so the new <system-reminder> stub is recognised
                    // too — a bare hasPrefix check on the legacy marker silently
                    // stopped matching when the format changed.
                    if Self.isOffloadedStub(content) {
                        skippedAlreadyOffloaded += 1
                        cache.store(key, fingerprint: fp, verdict: .alreadyOffloaded)
                        continue
                    }
                    // Only offload substantial content (>500 chars) or large images (>1KB)
                    let hasLargeContent = content.count > 500
                    let hasLargeImage = (imgData?.count ?? 0) > 1024
                    guard hasLargeContent || hasLargeImage else {
                        skippedTooSmall += 1
                        cache.store(key, fingerprint: fp, verdict: .tooSmall)
                        continue
                    }

                    let bytes = content.utf8.count + (imgData?.count ?? 0)
                    let tokens = ContextSizeMeter.estimateTokens(part)
                    cache.store(key, fingerprint: fp, verdict: .candidate, bytes: bytes, tokens: tokens)
                    candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: bytes, toolId: id, toolName: name, cacheKey: key))

                case .toolUse(let id, let name, let input, let isOffloadedArgument):
                    // Offload large file_write/file_edit tool inputs
                    guard name == "file_write" || name == "file_edit" else { continue }

                    // [T-offload-scan-cache] A call that has not finished is
                    // neither offloaded NOR cached. The call's assistant message
                    // enters history before its tools run; its results are
                    // appended only once the whole batch completes (`agentHistory
                    // .append(toolResultMessage)` in the tool loop), so "has a
                    // result" is exactly "finished". Checked before any cache
                    // access: no lookup, no store — an in-flight call's argument
                    // is never judged, and nothing about it can go stale.
                    // (A `.toolResult` part, by the same token, only ever exists
                    // for a finished call, so that branch caches freely.)
                    //
                    // [T-offload-toolinput-guards issue #374] Pruning the
                    // argument of a call that has no tool_result would rewrite
                    // something still in flight. Today both offload triggers run
                    // at the top of a loop iteration, outside the
                    // append->dispatch window, and dispatch reads its arguments
                    // from the freshly parsed stream rather than from history —
                    // so this cannot bite yet. It is asserted here anyway so the
                    // invariant is local to the scanner instead of resting on
                    // call-site ordering a later refactor could change silently.
                    guard answeredToolUseIds.contains(id) else {
                        skippedUnanswered += 1
                        continue
                    }

                    let argument = input["content"] as? String
                    let key = "u:\(id)"
                    let fp = OffloadScanCache.fingerprint(content: argument ?? "", extraBytes: 0,
                                                          flag: isOffloadedArgument)
                    if let hit = cache.lookup(key, fingerprint: fp) {
                        switch hit.verdict {
                        case .alreadyOffloaded: skippedAlreadyOffloaded += 1
                        case .readback, .tooSmall: skippedTooSmall += 1
                        case .candidate:
                            candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: hit.tokens, bytes: hit.bytes, toolId: id, toolName: name, cacheKey: key))
                        }
                        continue
                    }

                    // [T-offload-toolinput-guards issue #374] The guards the
                    // `.toolResult` branch above has always had (the "not yet
                    // answered" one is the first check of this case, above).
                    //
                    // 1. Already pruned. The flag is authoritative (only the
                    //    offloader sets it); the text test covers history
                    //    persisted before the flag existed, and stubs arriving
                    //    from an older peer over iCloud sync. Re-pruning one
                    //    would write a second file whose notice replaces the
                    //    first, losing the path to the real content.
                    if isOffloadedArgument {
                        skippedAlreadyOffloaded += 1
                        cache.store(key, fingerprint: fp, verdict: .alreadyOffloaded)
                        continue
                    }
                    if let content = argument, Self.isOffloadedStub(content) {
                        skippedAlreadyOffloaded += 1
                        cache.store(key, fingerprint: fp, verdict: .alreadyOffloaded)
                        continue
                    }

                    if let content = argument, content.count > 500 {
                        let bytes = content.utf8.count
                        let tokens = ContextSizeMeter.estimateTokens(part)
                        cache.store(key, fingerprint: fp, verdict: .candidate, bytes: bytes, tokens: tokens)
                        candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: bytes, toolId: id, toolName: name, cacheKey: key))
                    } else {
                        cache.store(key, fingerprint: fp, verdict: .tooSmall)
                    }

                case .imageData(let data, _, _):
                    guard data.count > 1024 else {
                        skippedTooSmall += 1
                        continue
                    }
                    // Size alone decides an image's verdict; its token count
                    // (pixel-based — the image header has to be decoded) is
                    // what is worth caching, keyed to the message + slot.
                    let key = "i:\(msg.dbMessageId ?? "idx\(msgIdx)"):\(partIdx)"
                    let fp = OffloadScanCache.fingerprint(data: data)
                    let tokens: Int
                    if let hit = cache.lookup(key, fingerprint: fp) {
                        tokens = hit.tokens
                    } else {
                        tokens = ContextSizeMeter.estimateTokens(part)
                        cache.store(key, fingerprint: fp, verdict: .candidate, bytes: data.count, tokens: tokens)
                    }
                    candidates.append(OffloadCandidate(msgIdx: msgIdx, partIdx: partIdx, tokens: tokens, bytes: data.count, toolId: "img\(msgIdx)_\(partIdx)", toolName: "image", cacheKey: key))

                case .text:
                    continue
                }
            }
        }

        // [T-offload-scan-cache] Largest first by ESTIMATED tokens. BPE-encoding
        // every candidate just to rank them was the whole cost of a slow
        // offload (device log: 578 candidates, ~610k tokens on the main thread,
        // 8-9 s, to offload the first handful). Not raw bytes either: an image
        // is megabytes but ~1-2k tokens (pixel-based), and CJK text is 3 bytes
        // per ~1 token, so bytes would rank both far too high.
        candidates.sort { $0.tokens > $1.tokens }
        cache.endScan()

        let totalCandidateTokens = candidates.reduce(0) { $0 + $1.tokens }
        logger.info("  Candidates: \(candidates.count) parts (~\(totalCandidateTokens) est. tokens) — scan cache hits=\(cache.hits) misses=\(cache.misses) entries=\(cache.count)")
        logger.info("  Skipped: \(skippedAlreadyOffloaded) already offloaded, \(skippedOffloadReadback) offload readback, \(skippedTooSmall) too small, \(skippedUnanswered) unanswered tool calls")
        if !candidates.isEmpty {
            let top = candidates.prefix(5)
            for (i, c) in top.enumerated() {
                logger.info("  Candidate #\(i + 1): [\(c.toolName)] id:\(c.toolId.prefix(8)) msg[\(c.msgIdx)] ~\(c.tokens) est. tokens (\(c.bytes) bytes)")
            }
            if candidates.count > 5 {
                logger.info("  ... and \(candidates.count - 5) more candidates")
            }
        }

        var offloadedCount = 0
        var freedTokens = 0

        // [T-offload-scan-cache] Time budget. Each offload writes a file on
        // the main thread (a few ms on an iPhone 8); the post-compact FORCE call
        // offloads every eligible part, which in a long chat can be hundreds of
        // files — enough on its own to cross a second. Stop after the budget
        // (always taking at least one part): what is left is picked up by the
        // next trigger, and after a compaction the context is already below
        // the offload threshold, so nothing needs it urgently.
        let offloadBudget: CFAbsoluteTime = 0.3
        var stoppedByBudget = false
        for candidate in candidates {
            guard currentTokens > targetTokens else { break }
            if offloadedCount > 0, CFAbsoluteTimeGetCurrent() - offloadStart > offloadBudget {
                stoppedByBudget = true
                break
            }

            let part = agentHistory[candidate.msgIdx].parts[candidate.partIdx]
            let candidateTokens = ContextSizeMeter.calibrated(candidate.tokens, ratio: calibrationRatio)
            var linuxPath = ""

            switch part {
            case .toolResult(let id, let name, let content, let isError, let imgData, let imgMime, let pageURL, _, let isReadback):
                // Offload text content
                if content.count > 500 {
                    linuxPath = offloadContextContent(content, toolId: id, toolName: name)
                }
                // Offload image data
                if let imgData = imgData, imgData.count > 1024 {
                    let imgPath = offloadContextImage(imgData, toolId: id, mimeType: imgMime ?? "image/png")
                    if linuxPath.isEmpty { linuxPath = imgPath }
                }

                let stub = "\(Self.offloadedStubPrefix) Content (~\(candidateTokens) tokens, \(candidate.bytes) bytes) saved to: \(linuxPath)\nUse file_read tool to retrieve if needed."
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .toolResult(
                    id: id, name: name, content: stub, isError: isError,
                    pageURL: pageURL,
                    // [T-offload-readback-loop] Carry the tag across the
                    // rebuild, like every other rebuild site does. The scanner
                    // already excludes read-backs from the candidate list, so
                    // this is belt-and-braces — but a rebuild that drops the
                    // tag is exactly how a reminder laundered one before, and
                    // the invariant is free to keep. `imageLinuxPath` is nil
                    // because the image bytes (if any) just moved to the
                    // offload path named in the stub.
                    imageLinuxPath: nil, isOffloadReadback: isReadback
                )

            case .toolUse(let id, let name, let input, _):
                if let content = input["content"] as? String {
                    linuxPath = offloadContextContent(content, toolId: id, toolName: name)
                }
                var newInput = input
                // [T-offload-stub-system-reminder issue #374] A pruned ARGUMENT
                // gets the <system-reminder> notice, not the old content-shaped
                // text: this value is read back by the model as its own prior
                // call, and the old wording invited it to copy the placeholder
                // into the next write.
                newInput["content"] = Self.offloadedStubNotice(
                    tokens: candidateTokens, bytes: candidate.bytes, linuxPath: linuxPath
                )
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .toolUse(
                    id: id, name: name, input: newInput, isOffloadedArgument: true
                )

            case .imageData(let data, let mime, _):
                linuxPath = offloadContextImage(data, toolId: candidate.toolId, mimeType: mime)
                let stub = "\(Self.offloadedStubPrefix) Image (~\(candidateTokens) tokens, \(candidate.bytes) bytes) saved to: \(linuxPath)\nUse file_read tool to retrieve if needed."
                agentHistory[candidate.msgIdx].parts[candidate.partIdx] = .text(stub)

            case .text:
                continue
            }

            currentTokens -= candidateTokens
            freedTokens += candidateTokens
            offloadedCount += 1
            let afterPct = Int(Double(currentTokens) / Double(contextWindow) * 100)
            logger.info("  ✂ Offloaded #\(offloadedCount): [\(candidate.toolName)] id:\(candidate.toolId.prefix(8)) ~\(candidateTokens) tokens (\(candidate.bytes) bytes) → \(linuxPath) [now \(currentTokens) (\(afterPct)%)]")
        }

        if offloadedCount > 0 {
            let afterPct = Int(Double(currentTokens) / Double(contextWindow) * 100)
            logger.info("━━━ Context Offload Complete ━━━")
            logger.info("  Parts offloaded: \(offloadedCount)")
            logger.info("  Tokens freed: ~\(freedTokens)")
            logger.info("  Before: \(beforeTokens)/\(contextWindow) (\(pct)%)")
            logger.info("  After:  \(currentTokens)/\(contextWindow) (\(afterPct)%)")
            logger.info("  Delta:  -\(beforeTokens - currentTokens) tokens (-\(pct - afterPct)pp)")

            // [T-offload-scan-cache] Count only. Listing the top 20 by
            // recency stat'ed and sorted every file in the directory (hundreds
            // in a long chat) on the main thread, on every offload, for a log.
            let sid = sessionId ?? "unknown"
            let toolsDir = Self.minisOffloadsPersistentDir(for: sid)
                .appendingPathComponent("tools", isDirectory: true)
            let fileCount = (try? FileManager.default.contentsOfDirectory(atPath: toolsDir.path).count) ?? 0
            logger.info("  /var/minis/offloads/tools/ — \(fileCount) files")
            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - offloadStart) * 1000)
        logger.info("[OffloadTiming] \(elapsedMs)ms scanned=\(candidateRange.count) candidates=\(candidates.count) offloaded=\(offloadedCount) budgetStop=\(stoppedByBudget) cacheHits=\(cache.hits) cacheMisses=\(cache.misses) force=\(force)")
    }

    /// Remove persistent minis data for a given session.
    private func cleanupMinis(for sid: String) {
        let fm = FileManager.default
        let persistDir = Self.minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
        try? fm.removeItem(at: persistDir)
    }

    /// Sync a single minis subdirectory bidirectionally between persistent storage and iSH-visible path.
    /// One-time migration: moves old `Library/MinisChat/offloads/<sid>/` to
    /// `Library/MinisChat/minis/<sid>/offloads/`.
    func migrateOffloadsIfNeeded(for sid: String) {
        let fm = FileManager.default
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let oldDir = lib.appendingPathComponent("MinisChat/offloads/\(sid)", isDirectory: true)
        guard fm.fileExists(atPath: oldDir.path) else { return }

        let newDir = Self.minisOffloadsPersistentDir(for: sid)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // Move each file from old location to new
        if let files = try? fm.contentsOfDirectory(atPath: oldDir.path) {
            for file in files {
                let src = oldDir.appendingPathComponent(file)
                let dst = newDir.appendingPathComponent(file)
                try? fm.moveItem(at: src, to: dst)
            }
        }

        // Remove old directory
        try? fm.removeItem(at: oldDir)
        logger.info("Migrated offloads for session \(sid) to new minis path")
    }

    /// Bind-mount a session's minis directories into iSH-visible /var/minis/.
    /// Delegates to ISHExecutionCoordinator for serialized mount management.
    func mountMinis(for sid: String) {
        // Always ensure symlinks exist in data/ for the file browser,
        // even when the iSH kernel isn't booted yet.
        ensureMinisSymlinks(for: sid)
        Task { await ISHExecutionCoordinator.shared.mountForSession(sid) }
    }

    /// [T-ish-container-identity GH#99] One-shot per launch: detect an iOS
    /// data-container migration (the UUID rotates on EVERY app update /
    /// reinstall; contents migrate). All /var/minis symlinks carry absolute
    /// paths from the previous container, so right after an update — before
    /// the first session mounts and re-points them — the shell sees dangling
    /// links / empty dirs, which users read as data loss. Log the migration
    /// explicitly so that window is diagnosable from the log alone.
    private static var containerMigrationChecked = false
    private static func noteContainerMigrationIfNeeded() {
        guard !containerMigrationChecked else { return }
        containerMigrationChecked = true
        let current = URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent
        let key = "lastKnownDataContainerUUID"
        let previous = UserDefaults.standard.string(forKey: key)
        if let previous, previous != current {
            AppLogger(category: "MinisSymlink").warning("[MinisSymlink] Data container migrated \(previous.prefix(8))… → \(current.prefix(8))… (normal after an app update; contents were migrated by iOS). Session symlinks will be re-pointed as sessions mount.")
        }
        if previous != current {
            UserDefaults.standard.set(current, forKey: key)
        }
    }

    /// Create symlinks in the fakefs data/ directory so the file browser
    /// can access minis directories without requiring the iSH kernel to be booted.
    /// [T-minis-symlink-placeholder-dir issue #380] Remove a real directory that
    /// is squatting where a symlink belongs, escalating until it is gone.
    ///
    /// `/var/minis/mcp-servers` and its siblings are symlinks into the App Group.
    /// When a guest process wins the race and creates a plain directory there
    /// (the guest CLI used to `mkdir -p` it unconditionally), the host's App Group
    /// becomes unreachable from the sandbox: the app writes an OAuth bridge file
    /// the guest can never read. Clearing the squatter is what restores the link,
    /// so a silent failure here is not acceptable.
    ///
    /// Ladder, cheapest first:
    ///   1. `removeItem` — succeeds for an empty or fully-owned directory.
    ///   2. Delete the remaining children individually, then `rmdir`. This is the
    ///      case a plain remove loses to: one undeletable child aborts the whole
    ///      recursive delete, and the caller is left with a directory it believes
    ///      it removed.
    ///
    /// Returns true when the path is clear (or was never there). `nonisolated` +
    /// `static` so a test can drive it against a real temporary directory.
    nonisolated static func forceRemovePlaceholderDirectory(
        at path: URL, logger: AppLogger, label: String
    ) -> Bool {
        let fm = FileManager.default
        if (try? fm.removeItem(at: path)) != nil { return true }

        // Second pass: clear children one by one so a single stubborn entry
        // cannot abort the whole delete, then drop the directory itself.
        var failedChildren = 0
        if let contents = try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
            for child in contents {
                do { try fm.removeItem(at: child) } catch {
                    failedChildren += 1
                    logger.error("[MinisSymlink] \(label): cannot delete \(child.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if rmdir(path.path) == 0 {
            logger.info("[MinisSymlink] \(label): placeholder dir cleared via rmdir after emptying it")
            return true
        }

        // Still there. Report why, including whether children blocked it.
        var buf = stat()
        if lstat(path.path, &buf) != 0 { return true }   // vanished under us — fine
        logger.error("[MinisSymlink] \(label): rmdir failed (errno=\(errno), undeletable children=\(failedChildren))")
        return false
    }

    private func ensureMinisSymlinks(for sid: String) {
        let fm = FileManager.default
        let dataPath = RootfsManager.shared.dataPath
        Self.noteContainerMigrationIfNeeded()

        // Ensure /var/minis/ exists in data/
        let minisDataDir = dataPath.appendingPathComponent("var/minis")
        try? fm.createDirectory(at: minisDataDir, withIntermediateDirectories: true)

        let mappings: [(persistDir: URL, linuxDir: String)] = [
            (Self.minisOffloadsPersistentDir(for: sid), Self.minisOffloadsLinuxDir),
            (Self.minisAttachmentsPersistentDir(for: sid), Self.minisAttachmentsLinuxDir),
            (Self.minisWorkspacePersistentDir(for: sid), Self.minisWorkspaceLinuxDir),
            (Self.minisBrowserPersistentDir(for: sid), Self.minisBrowserLinuxDir),
            (Self.minisMemoryPersistentDir, Self.minisMemoryLinuxDir),
            (Self.minisSkillsPersistentDir, Self.minisSkillsLinuxDir),
            (Self.minisSharedPersistentDir, Self.minisSharedLinuxDir),
            (Self.minisMcpServersPersistentDir, Self.minisMcpServersLinuxDir),
        ]

        for (persistDir, linuxDir) in mappings {
            try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)
            let hostPath = dataPath.appendingPathComponent(String(linuxDir.dropFirst()))

            var lstatBuf = stat()
            let exists = lstat(hostPath.path, &lstatBuf) == 0

            if exists && (lstatBuf.st_mode & S_IFMT) == S_IFLNK {
                // Already a symlink — check if target is correct.
                // Use resolvingSymlinksInPath on both sides to normalize aliases
                // (e.g. GroupContainersAlias vs "Group Containers" on iOS).
                let resolved = hostPath.resolvingSymlinksInPath().standardized.path
                let expected = persistDir.resolvingSymlinksInPath().standardized.path
                if resolved == expected { continue }
                logger.info("[MinisSymlink] \(linuxDir): stale symlink (-> \(resolved), want \(expected)), replacing")
                unlink(hostPath.path)
            } else if exists && (lstatBuf.st_mode & S_IFMT) == S_IFDIR {
                // Real directory found where a symlink should be.
                // Migrate any existing content to the persistent directory,
                // then remove the real directory so we can create a symlink.
                // This handles the case where the directory was created before
                // the persistent storage location changed (e.g. shared -> App Group).
                var moved = 0, skipped = 0
                if let contents = try? fm.contentsOfDirectory(at: hostPath, includingPropertiesForKeys: nil) {
                    for item in contents {
                        let dest = persistDir.appendingPathComponent(item.lastPathComponent)
                        if !fm.fileExists(atPath: dest.path) {
                            do {
                                try fm.moveItem(at: item, to: dest)
                                moved += 1
                            } catch {
                                logger.error("[MinisSymlink] \(linuxDir): migrate FAILED for \(item.lastPathComponent): \(error.localizedDescription)")
                            }
                        } else {
                            skipped += 1
                        }
                    }
                }
                logger.info("[MinisSymlink] \(linuxDir): real dir -> persistDir migration, moved=\(moved) skipped(existing)=\(skipped)")

                // [T-minis-symlink-placeholder-dir issue #380] The removal must
                // actually succeed, or the symlink below cannot be created and the
                // guest keeps reading a local empty directory that shadows the App
                // Group — which is exactly how #380 presents: the host writes a
                // bridge file the sandbox can never see.
                //
                // `try? removeItem` swallowed the failure, so a directory that
                // still held un-migrated entries (a name collision above, or a file
                // the move could not take) left a real dir in place and the next
                // line failed too. Both errors were logged at different sites and
                // read as unrelated.
                //
                // Recovery ladder: plain remove, then clear whatever survived and
                // rmdir the now-empty directory. Anything left after that is
                // reported loudly rather than silently degrading.
                if !Self.forceRemovePlaceholderDirectory(at: hostPath, logger: logger, label: linuxDir) {
                    logger.error("[MinisSymlink] \(linuxDir): could not clear placeholder dir at \(hostPath.path) — guest will keep seeing a shadowed local dir")
                    continue
                }
            } else if exists {
                // Regular file — unexpected, remove
                logger.info("[MinisSymlink] \(linuxDir): unexpected regular file at \(hostPath.path), removing")
                unlink(hostPath.path)
            }

            // Create symlink
            do {
                try fm.createSymbolicLink(at: hostPath, withDestinationURL: persistDir)
                logger.info("[MinisSymlink] \(linuxDir): symlink created -> \(persistDir.path)")
            } catch {
                // [issue #380] Read back what is actually there. "createSymbolicLink
                // failed" alone does not say whether the path is now a stale dir, a
                // file, or nothing — and that distinction is the whole diagnosis.
                var after = stat()
                let kind: String
                if lstat(hostPath.path, &after) != 0 {
                    kind = "nothing"
                } else {
                    switch after.st_mode & S_IFMT {
                    case S_IFDIR: kind = "a real directory (guest is shadowed)"
                    case S_IFLNK: kind = "a symlink"
                    default: kind = "a regular file"
                    }
                }
                logger.error("[MinisSymlink] \(linuxDir): createSymbolicLink FAILED: \(error.localizedDescription) — path now holds \(kind)")
            }
        }

        // Ensure user-mounted external folders are symlinked too.
        Self.refreshMountedFolderSymlinks()
    }

    /// Create/refresh `/var/minis/mounts/<name>` symlinks for every entry in
    /// `MountedFoldersManager`. Removes stale symlinks whose mounts were deleted.
    ///
    /// Called from:
    ///   - `ensureMinisSymlinks` on each session mount
    ///   - `MountedFoldersManager` after add/rename/remove
    ///   - App launch after `activateAll`
    ///
    /// Safe to call before the iSH kernel is booted — writes only into `data/`.
    ///
    /// **Must not do filesystem work on the main thread.** A mount's resolved
    /// `target` can be a network- or FileProvider-backed volume (SMB share,
    /// iCloud Drive vault). Any path-resolving call on such a URL —
    /// `resolvingSymlinksInPath()`, `appendingPathComponent` on a `file:` URL,
    /// `resourceValues(forKeys:)` — becomes a `getattrlist(2)` that traps into
    /// a synchronous XPC round-trip to the owning provider. When the volume is
    /// slow or unreachable that parks the calling thread indefinitely; doing it
    /// on the main thread from the launch `.onAppear` tripped the 10s
    /// `scene-update` watchdog and iOS SIGKILLed the app (0x8BADF00D).
    /// So: snapshot the manager state on the main actor (cheap dictionary
    /// reads only), then do every filesystem touch on a detached task.
    nonisolated static func refreshMountedFolderSymlinks() {
        if Thread.isMainThread {
            let snapshot = MainActor.assumeIsolated { mountedFolderSymlinkSnapshot() }
            Task.detached(priority: .utility) {
                performMountedFolderSymlinkRefresh(snapshot: snapshot)
            }
        } else {
            Task.detached(priority: .utility) {
                let snapshot = await MainActor.run { mountedFolderSymlinkSnapshot() }
                performMountedFolderSymlinkRefresh(snapshot: snapshot)
            }
        }
    }

    /// One mount's desired symlink state, captured on the main actor.
    /// `target` is nil for entries that failed activation (stale bookmark,
    /// permission denied, contents unavailable) — those get their leftover
    /// symlink removed so FileBrowserView doesn't show a broken entry.
    struct MountedFolderSymlinkSpec: Sendable {
        let name: String
        let targetPath: String?
    }

    /// Cheap main-actor snapshot: reads `entries` and the `activeURLs`
    /// dictionary. Deliberately does **no** filesystem I/O — `url.path` is a
    /// pure string accessor, unlike `resolvingSymlinksInPath()`.
    @MainActor
    private static func mountedFolderSymlinkSnapshot() -> [MountedFolderSymlinkSpec] {
        let manager = MountedFoldersManager.shared
        return manager.entries.map { entry in
            MountedFolderSymlinkSpec(
                name: entry.name,
                targetPath: manager.resolvedURL(for: entry.id)?.path
            )
        }
    }

    /// Reconcile `/var/minis/mounts/<name>` against `snapshot`. Runs entirely
    /// off the main thread — see `refreshMountedFolderSymlinks` for why.
    nonisolated private static func performMountedFolderSymlinkRefresh(
        snapshot: [MountedFolderSymlinkSpec]
    ) {
        let fm = FileManager.default
        let dataPath = RootfsManager.shared.dataPath
        let mountsDir = dataPath.appendingPathComponent("var/minis/mounts", isDirectory: true)
        try? fm.createDirectory(at: mountsDir, withIntermediateDirectories: true)

        let desiredNames = Set(snapshot.map(\.name))

        // 1. Remove symlinks for mounts that no longer exist.
        if let existing = try? fm.contentsOfDirectory(atPath: mountsDir.path) {
            for entry in existing where !desiredNames.contains(entry) {
                let stalePath = mountsDir.appendingPathComponent(entry)
                var buf = stat()
                if lstat(stalePath.path, &buf) == 0,
                   (buf.st_mode & S_IFMT) == S_IFLNK {
                    unlink(stalePath.path)
                }
            }
        }

        // 2. Create or fix symlinks for active mounts.
        for spec in snapshot {
            let link = mountsDir.appendingPathComponent(spec.name)
            guard let targetPath = spec.targetPath else {
                // Inactive (stale/denied) — remove any leftover symlink so the
                // user doesn't see a broken entry in FileBrowserView.
                var buf = stat()
                if lstat(link.path, &buf) == 0 { unlink(link.path) }
                continue
            }

            var buf = stat()
            let exists = lstat(link.path, &buf) == 0
            if exists && (buf.st_mode & S_IFMT) == S_IFLNK {
                // Compare the symlink's *stored* destination rather than
                // resolving both sides. `destinationOfSymbolicLink` is a plain
                // readlink(2) against the local fakefs — it never touches the
                // mount's backing volume, so an unreachable SMB/FileProvider
                // target can't stall us here. The previous
                // `resolvingSymlinksInPath()` comparison on both sides was the
                // watchdog-kill site. We write the link with `target.path`
                // below, so a byte-equal destination means it's already correct.
                let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
                if current == targetPath { continue }
                unlink(link.path)
            } else if exists {
                // Non-symlink in the way — unexpected, remove.
                unlink(link.path)
            }
            try? fm.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: targetPath
            )
        }
    }

    /// Save an attachment (image, media) to the session's persistent attachments directory.
    /// With bind mounts, writing to persistent storage is automatically visible to iSH.
    /// Returns a `minis://attachments/<filename>` URL string, or nil on failure.
    func saveAttachment(_ data: Data, filename: String) -> String? {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"

        // Write to persistent storage (bind-mounted, so iSH sees it automatically)
        let persistDir = Self.minisAttachmentsPersistentDir(for: sid)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let persistPath = persistDir.appendingPathComponent(filename)
        guard (try? data.write(to: persistPath)) != nil else { return nil }

        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return "minis://attachments/\(encoded)"
    }

}

// MARK: - [T-offload-scan-cache] Scan range + per-part verdict cache

extension AIChatViewModel {
    /// First raw `agentHistory` index the offload scanner needs to look at.
    ///
    /// Compact-v2 keeps the raw history and overlays a marker; what reaches the
    /// model is `effectiveAgentHistory()` — a short warm-up before the anchor
    /// (whose tool results over 1000 chars are already pruned there) plus
    /// everything after it. Scanning from 0 walked the compacted half too
    /// (device log: 2252 scanned vs 1104 sent), and offloading those parts
    /// "freed" tokens that were never being sent, so the real usage barely
    /// moved and the offload fired again minutes later.
    ///
    /// Mirrors `effectiveAgentHistoryUncounted`'s anchor resolution; any case it
    /// degrades to full history (no marker, v1, unresolved anchor) returns 0 —
    /// the previous behaviour.
    func offloadScanStartIndex() -> Int {
        guard let marker = cachedLatestMarker, marker.version >= 2,
              let anchorId = marker.lastCompactedMessageId,
              let anchorIdx = agentHistory.lastIndex(where: { $0.dbMessageId == anchorId }) else { return 0 }
        return anchorIdx + 1
    }

    /// [T-offload-warmup-scan] Raw `agentHistory` indices of the pre-anchor
    /// warm-up messages that `effectiveAgentHistory` actually sends, plus the
    /// tool ids whose parts it prunes there.
    ///
    /// `offloadScanStartIndex` starts AFTER the anchor, but compact-v2 still
    /// sends up to three user turns before it. That warm-up is only pruned of
    /// tool_results over 1000 chars (and their calls): file_write arguments,
    /// 501–1000-char results and images there were sent on every request yet
    /// could no longer be offloaded. Mirrors effectiveAgentHistoryUncounted's
    /// steps (walk back, prune > 1000, drop emptied messages, peel leading
    /// non-user, drop the per-marker warm-up trim) so nothing unsent is
    /// scanned. Empty when there is no resolvable v2 marker.
    func offloadWarmUpScanPlan() -> (indices: [Int], prunedToolIds: Set<String>) {
        guard let marker = cachedLatestMarker, marker.version >= 2,
              let anchorId = marker.lastCompactedMessageId,
              let anchorIdx = agentHistory.lastIndex(where: { $0.dbMessageId == anchorId }) else { return ([], []) }
        let walkBack = walkBackUserTurnsBounded(anchorIdx: anchorIdx,
                                                maxUserTextTurns: Self.compactKeepRecentUserTurns,
                                                maxMessages: 100)
        // [T-ctx-pin-request] A round over the cap sends only the user's
        // request from before the anchor (see effectiveHistory).
        if walkBack.priorIdx == nil, walkBack.stopReason == "messageCapWouldExceed",
           let pinned = Self.lastRealUserTextIndex(in: agentHistory, upToIncluding: anchorIdx) {
            return ([pinned], [])
        }
        guard let priorIdx = walkBack.priorIdx, priorIdx <= anchorIdx else { return ([], []) }
        var pruned: Set<String> = []
        for i in priorIdx...anchorIdx {
            for part in agentHistory[i].parts {
                if case .toolResult(let id, _, let content, _, _, _, _, _, _) = part, content.count > 1000 {
                    pruned.insert(id)
                }
            }
        }
        var kept: [Int] = []
        for i in priorIdx...anchorIdx {
            let survives = agentHistory[i].parts.contains { part in
                switch part {
                case .toolUse(let id, _, _, _): return !pruned.contains(id)
                case .toolResult(let id, _, _, _, _, _, _, _, _): return !pruned.contains(id)
                default: return true
                }
            }
            if survives { kept.append(i) }
        }
        while let first = kept.first, agentHistory[first].role != .user { kept.removeFirst() }
        if let drop = warmUpDropByMarker[marker.id] {
            kept = Array(kept.dropFirst(min(drop, kept.count)))
        }
        return (kept, pruned)
    }
}

/// Per-part verdicts of the context-offload scanner, keyed by the part's own
/// identity (`r:`/`u:` + tool-use id, `i:` + message id + slot for images —
/// `AgentMessage` has no stable id of its own) and validated by a fingerprint
/// of the content, so an edited or offloaded part is never answered from a
/// stale entry. Holds verdicts, sizes and token estimates, never content.
///
/// A fingerprint collision (a provider reusing tool-use ids, or two same-size
/// images) can only reuse another part's verdict/estimate for a part that
/// looks identical in length, flags and first + last 32 bytes; the worst case
/// is a slightly wrong estimate in the offload accounting, never lost content.
///
/// Memory: one entry ≈ 150 B (key string ~64 B on the heap, `Entry` ~48 B,
/// dictionary slot overhead). The largest session seen (2257 messages) tracks
/// ~905 parts ≈ 135 KB. `capacity` bounds it at ~600 KB per view model; past
/// it, the least recently used entries (by scan generation) are evicted down
/// to 3/4 of capacity. It is also emptied when the view model loads a session.
/// Losing entries only costs a re-judgement on the next scan — correctness
/// never depends on the cache.
///
/// Main-actor only (the scanner runs on the view model).
@MainActor
final class OffloadScanCache {
    enum Verdict: UInt8 { case readback, alreadyOffloaded, tooSmall, candidate }

    struct Entry {
        var fingerprint: Int
        var verdict: Verdict
        /// Candidates only (0 otherwise).
        var bytes: Int
        /// ContextSizeMeter estimate, uncalibrated. Candidates only.
        var tokens: Int
        /// Scan generation of the last use, for LRU eviction.
        var lastUsed: UInt32
    }

    static let capacity = 4096

    private var entries: [String: Entry] = [:]
    private var generation: UInt32 = 0
    private(set) var hits = 0
    private(set) var misses = 0

    var count: Int { entries.count }

    func beginScan() {
        generation &+= 1
        hits = 0
        misses = 0
    }

    func lookup(_ key: String, fingerprint: Int) -> Entry? {
        guard var entry = entries[key], entry.fingerprint == fingerprint else {
            misses += 1
            return nil
        }
        hits += 1
        entry.lastUsed = generation
        entries[key] = entry
        return entry
    }

    func store(_ key: String, fingerprint: Int, verdict: Verdict, bytes: Int = 0, tokens: Int = 0) {
        entries[key] = Entry(fingerprint: fingerprint, verdict: verdict, bytes: bytes,
                             tokens: tokens, lastUsed: generation)
    }

    /// Evicts least-recently-used entries once over capacity.
    func endScan() {
        guard entries.count > Self.capacity else { return }
        let keep = Self.capacity * 3 / 4
        let victims = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(entries.count - keep)
        for (key, _) in victims { entries.removeValue(forKey: key) }
    }

    func removeAll() { entries.removeAll() }

    /// Cheap: UTF-8 length (O(1) for native strings) plus the first and last
    /// 32 bytes — an offload rewrite changes all of them.
    nonisolated static func fingerprint(content: String, extraBytes: Int, flag: Bool) -> Int {
        var h = Hasher()
        let utf8 = content.utf8
        h.combine(utf8.count)
        h.combine(extraBytes)
        h.combine(flag)
        h.combine(utf8.prefix(32).reduce(0) { $0 &* 31 &+ Int($1) })
        h.combine(utf8.suffix(32).reduce(0) { $0 &* 31 &+ Int($1) })
        return h.finalize()
    }

    /// Size plus both ends: image headers (e.g. JPEG/JFIF) are often identical
    /// across files, so the tail carries most of the distinction.
    nonisolated static func fingerprint(data: Data) -> Int {
        var h = Hasher()
        h.combine(data.count)
        h.combine(data.prefix(32))
        h.combine(data.suffix(32))
        return h.finalize()
    }
}
