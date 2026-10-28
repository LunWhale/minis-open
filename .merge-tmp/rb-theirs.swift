import CryptoKit
import Foundation
import ImageIO
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Request-level image budget + Minis paths + tool-output offload

extension AIChatViewModel {

    // MARK: - Request-level image budget

    // BEGIN RequestImageBudget
    /// One image part scoped for budget planning. Mirrors Android's
    /// ImageBudget.BudgetImage so the cross-platform algorithm is
    /// identical. linuxPath optional — missing means "no offload mirror
    /// yet; spill if dropped".
    private struct BudgetImage {
        let data: Data
        let linuxPath: String?
        let mimeType: String
    }

    /// Result of [planRequestBudget]. `droppedIds` are POSITIONS in the image
    /// list the planner was given (chronological: message index, then part
    /// index), so each image has its own id even when two are identical.
    /// [T-budget-position-ids] They used to be ObjectIdentifier(data as
    /// AnyObject) hashes: that boxes the Data in a fresh, short-lived bridge
    /// object on every call, the freed address is reused, and every image got
    /// the same id - the plan dropped "1" image, the rewrite then matched all
    /// of them, and every placeholder named the last path resolved.
    struct RequestBudgetPlan {
        let droppedIds: Set<Int>
        let droppedPaths: [Int: String?]
        /// [T-image-budget-base64] Both are BASE64 byte counts (wire size),
        /// matching the unit the budget is expressed in. Log/diagnostic only.
        let keptBytes: Int
        let elidedBytes: Int
        let droppedCount: Int
        let totalCount: Int
        /// [T-image-gate] What the gate stage did to this request's images.
        var gate = RequestGateReport()
        var mutated: Bool { droppedCount > 0 }
    }

    /// [T-image-gate] Counts from gating one request's images (log only).
    struct RequestGateReport {
        var total = 0
        /// Re-encoded to JPEG / PNG within the limits (size, format, orientation).
        var converted = 0
        /// Original bytes kept, MIME label corrected to what the bytes are.
        var relabelled = 0
        /// Not a usable image: replaced by a visible placeholder.
        var failed = 0
        var changed: Bool { converted + relabelled + failed > 0 }
    }

    /// [T-image-gate] Every image of a request through ModelImageGate, before
    /// the byte budget: Responses, Chat Completions, Gemini, Antigravity and
    /// Anthropic all get the same model image (Anthropic's own >2000 px
    /// downscale stays, and finds nothing left to do). Compliant images keep
    /// their original bytes (only a wrong MIME label is corrected); the rest
    /// are converted; an image that cannot be made valid becomes a visible
    /// placeholder instead of bytes the provider would reject or drop.
    ///
    /// This is also what heals history stored before #412 was fixed: a
    /// full-size original read back after a restart is converted here on the
    /// next request, the same way the live turn converts it.
    static func gatedRequestImages(_ messages: [AgentMessage], maxImageBytes: Int? = nil)
        -> (messages: [AgentMessage], report: RequestGateReport) {
        // Default: the raw equivalent of the per-image wire cap (kPerImageMaxBytes).
        let maxImageBytes = maxImageBytes ?? Self.rawBytesForBase64Budget(Self.kPerImageMaxBytes)
        var out = messages
        var report = RequestGateReport()
        for mi in out.indices {
            var parts = out[mi].parts
            var touched = false
            for pi in parts.indices {
                switch parts[pi] {
                case .imageData(let data, let mimeType, let linuxPath):
                    report.total += 1
                    let g = ModelImageGate.prepare(data, maxBytes: maxImageBytes)
                    switch g.kind {
                    case .original:
                        guard let mime = g.mimeType, mime != mimeType else { continue }
                        parts[pi] = .imageData(data: data, mimeType: mime, linuxPath: linuxPath)
                        report.relabelled += 1
                    case .converted:
                        parts[pi] = .imageData(data: g.data ?? data, mimeType: g.mimeType ?? "image/jpeg", linuxPath: linuxPath)
                        report.converted += 1
                    case .failed:
                        parts[pi] = .text(ModelImageGate.failurePlaceholder(reason: g.reason, linuxPath: linuxPath))
                        report.failed += 1
                    }
                    touched = true
                case .toolResult(let id, let name, let content, let isError, let imgData?, let imgMime, let pageURL, let imgLinuxPath, let isReadback):
                    report.total += 1
                    let g = ModelImageGate.prepare(imgData, maxBytes: maxImageBytes)
                    var newContent = content
                    var newData: Data? = imgData
                    var newMime = imgMime
                    switch g.kind {
                    case .original:
                        guard let mime = g.mimeType, mime != imgMime else { continue }
                        newMime = mime
                        report.relabelled += 1
                    case .converted:
                        newData = g.data ?? imgData
                        newMime = g.mimeType ?? "image/jpeg"
                        report.converted += 1
                    case .failed:
                        let placeholder = ModelImageGate.failurePlaceholder(reason: g.reason, linuxPath: imgLinuxPath)
                        newContent = content.isEmpty ? placeholder : "\(content)\n\(placeholder)"
                        newData = nil
                        newMime = nil
                        report.failed += 1
                    }
                    parts[pi] = .toolResult(
                        id: id, name: name, content: newContent, isError: isError,
                        imageData: newData, imageMimeType: newMime,
                        pageURL: pageURL, imageLinuxPath: imgLinuxPath, isOffloadReadback: isReadback
                    )
                    touched = true
                default: break
                }
            }
            if touched { out[mi].parts = parts }
        }
        return (out, report)
    }

    private static func planRequestBudget(
        _ images: [BudgetImage],
        maxBytes: Int = kRequestImageMaxBytes
    ) -> RequestBudgetPlan {
        guard !images.isEmpty else {
            return RequestBudgetPlan(droppedIds: [], droppedPaths: [:], keptBytes: 0, elidedBytes: 0, droppedCount: 0, totalCount: 0)
        }
        var dropped = Set<Int>()
        var droppedPaths: [Int: String?] = [:]
        var kept = 0
        var elided = 0
        // Walk latest → eldest so most-recent images win the budget.
        var position = images.count
        for img in images.reversed() {
            position -= 1
            let id = position
            // [T-image-budget-base64] Measure what this image costs ON THE
            // WIRE: images are base64 inlined into the request body, so the
            // budget has to count encoded bytes or it under-counts every image
            // by a third — the gap that pushed real requests past a gateway's
            // 32 MB body limit while this planner believed it was at 25 MB.
            //
            // Cap-clamp to kPerImageMaxBytes (also base64 bytes) — matches
            // what compressedImageDataUnderBudget would produce, since its
            // caller targets the raw equivalent of that same ceiling.
            let effective = min(estimatedBase64Length(img.data.count), kPerImageMaxBytes)
            if kept + effective <= maxBytes {
                kept += effective
            } else {
                dropped.insert(id)
                droppedPaths[id] = img.linuxPath
                elided += effective
            }
        }
        return RequestBudgetPlan(droppedIds: dropped, droppedPaths: droppedPaths, keptBytes: kept, elidedBytes: elided, droppedCount: dropped.count, totalCount: images.count)
    }

    /// Construct the text placeholder a provider emits in place of an
    /// elided image. Same shape as Android's `ImageBudget.elidedImagePlaceholder`.
    static func elidedImagePlaceholder(linuxPath: String?) -> String {
        if let p = linuxPath {
            return "[image elided to fit 25MB request budget. Original at \(p) — re-fetch with `read_image \(p)` if you need to see it.]"
        }
        return "[image elided to fit 25MB request budget. Original bytes no longer addressable; ask the user to re-attach if needed.]"
    }

    /// Lazily persist `data` under a session's `attachments/spillover/<sha1>.<ext>`
    /// directory and return the iSH-visible `/var/minis/attachments/spillover/...`
    /// path. Idempotent — same bytes hash to the same path. Returns nil
    /// if the write fails; the caller falls back to the no-path
    /// placeholder variant.
    private static func ensureSpillover(_ data: Data, mimeType: String, sessionId: String,
                                        base: URL = minisPersistentBase) -> String? {
        guard !data.isEmpty else { return nil }
        let ext: String
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/png":  ext = "png"
        case "image/gif":  ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic", "image/heif": ext = "heic"
        default: ext = "bin"
        }
        // SHA-1 hex digest via CryptoKit.Insecure (SHA-1 is fine here —
        // we're keying a cache by content, not signing anything).
        let digest = Insecure.SHA1.hash(data: data)
        let sha = digest.map { String(format: "%02x", $0) }.joined()
        let attachmentsRoot = base
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("spillover", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let file = attachmentsRoot.appendingPathComponent("\(sha).\(ext)")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try data.write(to: file)
            } catch {
                return nil
            }
        }
        return "/var/minis/attachments/spillover/\(sha).\(ext)"
    }

    /// Apply the request-level image budget to a fully-resolved agent
    /// history before passing it to a provider. Images that don't fit
    /// under `kRequestImageMaxBytes` (oldest first) are replaced with
    /// text placeholders that point the model back to the linuxPath
    /// where the bytes are still readable via `read_image`. Returns the
    /// budgeted history; same instance when nothing was elided.
    func applyRequestImageBudget(_ messages: [AgentMessage]) -> [AgentMessage] {
        // [T-image-real-seams] Planning and the rewrite live in
        // `budgetedRequestImages(_:sessionId:)`; this adds the log.
        guard let budgeted = Self.budgetedRequestImages(messages, sessionId: sessionId) else { return messages }
        let plan = budgeted.plan
        let mutated = budgeted.messages

        if plan.gate.changed {
            let s = ModelImageGate.stats
            logger.info("[ImageGate] request: converted=\(plan.gate.converted) relabelled=\(plan.gate.relabelled) failed=\(plan.gate.failed) of \(plan.gate.total) (cache hits=\(s.hits) misses=\(s.misses))")
        }
        guard plan.mutated else { return mutated }

        // [T-silence-auto-notices] Log only. This used to raise the
        // "Older N image(s) elided from request to fit 25MB budget" top strip;
        // once a conversation's history images pass 25MB it fired on EVERY
        // request (each tool round, retry and model switch) for the rest of the
        // conversation, with nothing for the user to decide. The model still
        // gets the "[image elided…]" placeholder (with the read_image path), so
        // nothing is lost - the user just isn't told each time.
        logger.info("[ImageBudget] request-level (silent): dropped=\(plan.droppedCount)/\(plan.totalCount) keptBytes=\(plan.keptBytes) elidedBytes=\(plan.elidedBytes) (base64 wire bytes, budget=\(Self.kRequestImageMaxBytes))")

        return mutated
    }

    /// The request image stage as a pure rewrite: every image through the
    /// gate (`gatedRequestImages`), then the byte budget. nil when the gate
    /// changed nothing and every image fits (the history is then sent as is),
    /// else the rewritten history and the plan (its `gate` says what the gate
    /// did). Images without a linuxPath are spilled under `sessionId`
    /// ("unknown" when nil).
    static func budgetedRequestImages(_ messages: [AgentMessage], sessionId: String?,
                                      spilloverBase: URL = minisPersistentBase,
                                      maxBytes: Int = kRequestImageMaxBytes) -> (messages: [AgentMessage], plan: RequestBudgetPlan)? {
        let gated = Self.gatedRequestImages(messages)
        let messages = gated.messages
        // Collect every image part in chronological order so the planner
        // can reverse-walk and protect the most recent images.
        // `position` is the image's index in `refs`, the id the planner uses.
        struct Ref { let position: Int; let msgIdx: Int; let partIdx: Int; let image: BudgetImage }
        var refs: [Ref] = []
        for (mi, msg) in messages.enumerated() {
            for (pi, part) in msg.parts.enumerated() {
                switch part {
                case .imageData(let data, let mimeType, let lp):
                    refs.append(Ref(position: refs.count, msgIdx: mi, partIdx: pi, image: BudgetImage(data: data, linuxPath: lp, mimeType: mimeType)))
                case .toolResult(_, _, _, _, let imgData, let imgMime, _, let lp, _):
                    if let d = imgData {
                        refs.append(Ref(position: refs.count, msgIdx: mi, partIdx: pi, image: BudgetImage(data: d, linuxPath: lp, mimeType: imgMime ?? "image/jpeg")))
                    }
                default: break
                }
            }
        }
        var plan = Self.planRequestBudget(refs.map { $0.image }, maxBytes: maxBytes)
        plan.gate = gated.report
        guard plan.mutated else { return gated.report.changed ? (messages, plan) : nil }

        // Resolve linuxPath for dropped images, spilling if needed.
        var resolved: [Int: String?] = [:]
        let sid = sessionId ?? "unknown"
        for ref in refs {
            let id = ref.position
            guard plan.droppedIds.contains(id) else { continue }
            if let existing = ref.image.linuxPath {
                resolved[id] = existing
            } else {
                resolved[id] = Self.ensureSpillover(ref.image.data, mimeType: ref.image.mimeType, sessionId: sid,
                                                    base: spilloverBase)
            }
        }

        // Build new messages with dropped image parts replaced.
        var mutated = messages
        let grouped = Dictionary(grouping: refs, by: { $0.msgIdx })
        for (mi, group) in grouped {
            var newParts = mutated[mi].parts
            for ref in group {
                let id = ref.position
                guard plan.droppedIds.contains(id) else { continue }
                let path: String? = resolved[id] ?? nil
                let placeholder = Self.elidedImagePlaceholder(linuxPath: path)
                let original = newParts[ref.partIdx]
                switch original {
                case .imageData:
                    newParts[ref.partIdx] = .text(placeholder)
                case .toolResult(let id, let name, let content, let isError, _, _, let pageURL, let imgLinuxPath, let isReadback):
                    let newContent = content.isEmpty ? placeholder : "\(content)\n\(placeholder)"
                    newParts[ref.partIdx] = .toolResult(
                        id: id, name: name, content: newContent,
                        isError: isError, imageData: nil, imageMimeType: nil,
                        // [T-offload-readback-loop] Carry the flag across the rebuild.
                        pageURL: pageURL, imageLinuxPath: imgLinuxPath,
                        isOffloadReadback: isReadback
                    )
                default: break
                }
            }
            mutated[mi].parts = newParts
        }
        return (mutated, plan)
    }
    // END RequestImageBudget

    // MARK: - [T-ctx-builder] The view model's inputs to RequestContextBuilder

    /// Everything RequestContextBuilder reads, taken from this view model.
    func requestContextInput() -> RequestContextBuilder.Input {
        RequestContextBuilder.Input(
            history: agentHistory,
            compaction: cachedLatestMarker,
            warmUpDrop: warmUpDropByMarker,
            helpers: effectiveHistoryHelpers(),
            sessionId: sessionId,
            spilloverBase: Self.minisPersistentBase,
            requestImageMaxBytes: Self.kRequestImageMaxBytes
        )
    }

    /// `applyRequestImageBudget(effectiveAgentHistory())` - what AgentLoop
    /// sends - through the builder, with this view model's state.
    func buildRequestContext() -> RequestContextBuilder.Output {
        let output = RequestContextBuilder.build(requestContextInput())
        if output.warmUpDrop != warmUpDropByMarker { warmUpDropByMarker = output.warmUpDrop }
        return output
    }

    /// Single-shot resize + JPEG encode at the given edge/quality. Always
    /// re-encodes (does NOT short-circuit when the input is already small)
    /// so the caller's ladder can compare candidates at consistent settings.
    static func jpegEncode(_ data: Data, maxLongEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let longest = max(pixelW, pixelH)
        let targetW: CGFloat
        let targetH: CGFloat
        if longest > maxLongEdge {
            let scale = maxLongEdge / longest
            targetW = pixelW * scale
            targetH = pixelH * scale
        } else {
            targetW = pixelW
            targetH = pixelH
        }
        let newSize = CGSize(width: targetW, height: targetH)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Rewrite known provider error messages into friendlier guidance. The
    /// raw Anthropic 413 text is `"Downloaded image content cannot exceed
    /// 30MB"` — we keep the agent-visible record (`raw`) for diagnosis but
    /// surface a localized hint to the user. T-imgsize-13b7d81c.
    static func friendlyErrorMessage(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("image content cannot exceed")
            || lower.contains("image_too_large")
            || (lower.contains("413") && lower.contains("image")) {
            return AppLocalized("Image too large for the provider. The pre-send compressor already shrank it as far as it could; try removing one or more attachments and resending.") + "\n\n" + raw
        }
        // [T-file-write-large-content-timeout] GH#223. A request that dies with
        // a timeout / TLS drop while the model is emitting a big file_write
        // argument surfaces only as "Network error: request timed out", which
        // reads as a connectivity fault and sends users off checking their
        // proxy. The real cause is usually the sheer length of the generated
        // argument, so point at that too — without claiming it as the only
        // cause, since a genuinely bad network produces the same string.
        if lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("request timed out") || lower.contains("secure connection")
            || lower.contains("ssl") || lower.contains("tls") {
            return raw + "\n\n" + AppLocalized("If this happened while writing a large file, the request likely died mid-generation rather than the network being down: the whole file is generated as tool arguments before the write starts. Ask for the file in smaller appended chunks, or have it generated by a short script instead.")
        }
        return raw
    }

    /// Persistent storage directory for a specific session's workspace.
    nonisolated static func minisWorkspacePersistentDir(for sid: String) -> URL {
        minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// Persistent storage directory for a specific session's browser snapshots.
    nonisolated static func minisBrowserPersistentDir(for sid: String) -> URL {
        minisPersistentBase.appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent("browser", isDirectory: true)
    }

    /// App Group container root for FileProvider-visible directories.
    /// Everything under this path is exposed to iOS Files via the replicated
    /// FileProvider extension. Keep ONLY user-facing subdirs (shared, skills,
    /// memory) here — anything else leaks into "On My iPhone → Minis".
    nonisolated static var minisAppGroupRoot: URL {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
        )!.appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    /// App Group subdirectory for private metadata that must NOT be exposed
    /// to iOS Files (mounted-folders.json, FileProvider extension logs, etc).
    /// Sibling of `minisAppGroupRoot` inside the same App Group container.
    nonisolated static var minisConfigRoot: URL {
        let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
        )!.appendingPathComponent("MinisConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Persistent storage directory for memory (shared across all sessions).
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisMemoryPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("memory", isDirectory: true)
    }

    /// Persistent storage directory for skills (shared across all sessions).
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisSkillsPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("skills", isDirectory: true)
    }

    /// Persistent storage directory for shared files (shared across all sessions).
    /// Stored in the App Group container so the FileProvider extension can access it.
    nonisolated static var minisSharedPersistentDir: URL {
        minisAppGroupRoot.appendingPathComponent("shared", isDirectory: true)
    }

    /// Persistent storage directory for MCP server configs (servers.json,
    /// daemon log). Deliberately under MinisConfig, NOT minisAppGroupRoot:
    /// servers.json carries credentials (Authorization headers, API keys) and
    /// must never surface in iOS Files via the FileProvider extension.
    nonisolated static var minisMcpServersPersistentDir: URL {
        minisConfigRoot.appendingPathComponent("mcp-servers", isDirectory: true)
    }

    /// Resolve a `minis://` URL to a host filesystem URL.
    /// Shared resolution logic used by Markdown link handlers and the browser's WKURLSchemeHandler.
    ///
    /// [T-minisurl-wrong-active-session] `sessionId` scopes the per-session
    /// hosts (attachments/workspace/…) to the session that OWNS the reference.
    /// Callers running inside an agent loop MUST pass their own session id —
    /// the `activeSessionId` fallback tracks the session whose UI is
    /// frontmost, which is the wrong scope whenever another session is
    /// processing concurrently in the background.
    nonisolated static func resolveMinisURL(_ url: URL, sessionId: String? = nil) -> URL? {
        guard url.scheme == "minis", let host = url.host else { return nil }
        // Tolerate double-encoded links (%25E6…) alongside the correct
        // single-encoded form. [T-fix-double-encoding]
        let subPaths = MinisURLPathDecoding.subPathCandidates(for: url)
        let fm = FileManager.default

        // Primary: resolve via the owning session (explicit), else frontmost
        if let sid = sessionId ?? activeSessionId {
            for subPath in subPaths {
                let candidate = minisPersistentBase
                    .appendingPathComponent(sid, isDirectory: true)
                    .appendingPathComponent(host, isDirectory: true)
                    .appendingPathComponent(subPath)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // Global directories (skills, memory, shared)
        let globalDirs: [(String, URL)] = [
            ("skills", minisSkillsPersistentDir),
            ("memory", minisMemoryPersistentDir),
            ("shared", minisSharedPersistentDir),
        ]
        for (subdir, dir) in globalDirs where host == subdir {
            for subPath in subPaths {
                let candidate = dir.appendingPathComponent(subPath)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // Scan all sessions
        if let sessions = try? fm.contentsOfDirectory(atPath: minisPersistentBase.path) {
            for sid in sessions {
                for subPath in subPaths {
                    let candidate = minisPersistentBase
                        .appendingPathComponent(sid, isDirectory: true)
                        .appendingPathComponent(host, isDirectory: true)
                        .appendingPathComponent(subPath)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }
        return nil
    }

    struct OffloadResult {
        let linuxPath: String
    }

    /// Save large tool output to persistent storage.
    /// With bind mounts, writing to persistent storage is automatically visible to iSH.
    func offloadToolOutput(_ output: String, toolName: String, toolId: String) -> OffloadResult {
        let fm = FileManager.default
        let sid = sessionId ?? "unknown"

        // Write to persistent storage (bind-mounted, so iSH sees it automatically)
        let persistDir = Self.minisOffloadsPersistentDir(for: sid)
        try? fm.createDirectory(at: persistDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let sanitizedName = toolName.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(sanitizedName)_\(timestamp)_\(toolId.prefix(8)).txt"
        let persistPath = persistDir.appendingPathComponent(fileName)
        try? output.write(to: persistPath, atomically: true, encoding: .utf8)

        let linuxPath = "\(Self.minisOffloadsLinuxDir)/\(fileName)"
        return OffloadResult(linuxPath: linuxPath)
    }

}

// MARK: - [T-ctx-builder] Request context: history -> what the provider is sent

/// The single entry for building a model request's message list: compaction
/// slice + summary injection, legacy bridge rows dropped, orphan tool parts
/// repaired (stage 1, what `effectiveAgentHistory()` returns), then the 25 MB
/// request image budget (stage 2, what `applyRequestImageBudget` returns).
/// The provider serializer is the next step and is not part of it.
///
/// Every input is explicit: no ChatStore.shared, UserDefaults, clock or view
/// model state is read here. The view model builds an `Input` from its own
/// state (`requestContextInput()`). Stage 1 runs the same two statics as
/// effectiveAgentHistory() (`effectiveHistory` + `effectiveHistoryFilters`),
/// stage 2 the same `budgetedRequestImages` as applyRequestImageBudget, with
/// the spillover root and budget taken from the Input instead of their
/// defaults. Logs are unchanged. No behaviour change.
@MainActor
enum RequestContextBuilder {
    struct Input {
        /// The view model's `agentHistory`.
        var history: [AgentMessage]
        /// The latest compaction marker (`cachedLatestMarker`), nil if none.
        var compaction: CompactMarker?
        /// The warm-up trim cache (`warmUpDropByMarker`); updated in `Output`.
        var warmUpDrop: [String: Int]
        /// walk-back / n-th user text / warm-up trim, bound to the history.
        var helpers: AIChatViewModel.EffectiveHistoryHelpers
        /// Session id for spillover file names ("unknown" when nil).
        var sessionId: String?
        /// Root that spillover copies of elided images are written under
        /// (`<root>/<sid>/attachments/spillover/`); production: minisPersistentBase.
        var spilloverBase: URL
        /// Request image budget in base64 wire bytes; production: 25 MB.
        var requestImageMaxBytes: Int
    }

    struct Output {
        /// The message list handed to the provider (`streamMessage(messages:)`).
        let messages: [AgentMessage]
        /// Stage 1 result, before the image budget.
        let effectiveHistory: [AgentMessage]
        /// The image-stage plan, nil when the images went out unchanged (no
        /// gate change, nothing elided).
        let budgetPlan: AIChatViewModel.RequestBudgetPlan?
        /// The warm-up trim cache after this build.
        let warmUpDrop: [String: Int]
    }

    /// Stage 1 — what effectiveAgentHistory() returns.
    static func effectiveHistory(_ input: Input, warmUpDrop: inout [String: Int]) -> [AgentMessage] {
        let sliced = AIChatViewModel.effectiveHistory(input.history, marker: input.compaction,
                                                      warmUpDrop: &warmUpDrop, helpers: input.helpers)
        return AIChatViewModel.effectiveHistoryFilters(sliced, agentHistoryCount: input.history.count,
                                                       markerId: input.compaction?.id)
    }

    /// Stage 2 — applyRequestImageBudget(_:) with the Input's spillover root
    /// and budget. Returns the same array when nothing is elided.
    static func budgeted(_ messages: [AgentMessage], _ input: Input) -> (messages: [AgentMessage], plan: AIChatViewModel.RequestBudgetPlan?) {
        guard let budgeted = AIChatViewModel.budgetedRequestImages(messages, sessionId: input.sessionId,
                                                                   spilloverBase: input.spilloverBase,
                                                                   maxBytes: input.requestImageMaxBytes) else { return (messages, nil) }
        let plan = budgeted.plan
        let mutated = budgeted.messages
        guard plan.mutated else { return (mutated, plan) }

        // [T-silence-auto-notices] Log only. This used to raise the
        // "Older N image(s) elided from request to fit 25MB budget" top strip;
        // once a conversation's history images pass 25MB it fired on EVERY
        // request (each tool round, retry and model switch) for the rest of the
        // conversation, with nothing for the user to decide. The model still
        // gets the "[image elided…]" placeholder (with the read_image path), so
        // nothing is lost - the user just isn't told each time.
        logger.info("[ImageBudget] request-level (silent): dropped=\(plan.droppedCount)/\(plan.totalCount) keptBytes=\(plan.keptBytes) elidedBytes=\(plan.elidedBytes) (base64 wire bytes, budget=\(AIChatViewModel.kRequestImageMaxBytes))")

        return (mutated, plan)
    }

    /// Stage 1 then stage 2.
    static func build(_ input: Input) -> Output {
        var drop = input.warmUpDrop
        let history = effectiveHistory(input, warmUpDrop: &drop)
        let (messages, plan) = budgeted(history, input)
        return Output(messages: messages, effectiveHistory: history, budgetPlan: plan, warmUpDrop: drop)
    }
}

// MARK: - [T-image-gate] One image rule for every model request

// BEGIN ModelImageGate
/// [T-image-gate] The one rule every image follows before a model sees it:
/// JPEG or PNG only, long edge <= 2000 px, within the per-image byte cap,
/// pixels upright, MIME taken from the bytes. Used by the request stage
/// (AIChatViewModel.budgetedRequestImages - every provider, every request,
/// including history rebuilt after a restart), by the tool paths
/// (browser_use / read_image / takeover) and therefore by what they store.
///
/// An image that already follows the rule is passed through as its ORIGINAL
/// bytes, never re-encoded: history images are part of every request, and
/// re-encoding them would change bytes the provider has cached (JPEG
/// re-encoding is not idempotent - jpegEncode(jpegEncode(x)) != jpegEncode(x)).
/// Converted output always follows the rule itself, so gate(gate(x)) ==
/// gate(x).
///
/// Decoding is sampled (CGImageSourceCreateThumbnailAtIndex with a max pixel
/// size), never a full-size UIImage decode, so a 60-megapixel PNG does not
/// need a 240 MB bitmap. Results are cached by content (sha256 + gate version),
/// so one image is processed once however many requests carry it.
enum ModelImageGate {
    /// Bump when the output for a given input changes (cache key).
    static let version = 1
    static let maxLongEdge = 2000
    static let jpegQuality: CGFloat = 0.85

    /// Image container, from the magic bytes.
    enum Format: String {
        case jpeg, png, gif, webp, heic, bmp, tiff, unknown
    }

    struct Result {
        enum Kind: String { case original, converted, failed }
        let kind: Kind
        /// Bytes for the model; nil when `kind == .failed`.
        let data: Data?
        /// "image/jpeg" or "image/png"; nil when failed.
        let mimeType: String?
        /// Why the image was converted or could not be sent; "" for original.
        let reason: String
        let width: Int
        let height: Int
    }

    struct Stats: Equatable {
        var hits = 0, misses = 0, original = 0, converted = 0, failed = 0
    }

    // MARK: - Entry point

    /// The model-ready form of `data`. `maxBytes` is the raw byte cap for one
    /// image (callers pass the raw equivalent of kPerImageMaxBytes).
    static func prepare(_ data: Data, maxBytes: Int) -> Result {
        let key = "v\(version)|\(maxBytes)|\(sha256Hex(data))" as NSString
        if let hit = cache.object(forKey: key) {
            count { $0.hits += 1 }
            return hit.result(input: data)
        }
        let result = compute(data, maxBytes: maxBytes)
        cache.setObject(ResultBox(result), forKey: key, cost: result.kind == .converted ? result.data?.count ?? 0 : 0)
        count {
            $0.misses += 1
            switch result.kind {
            case .original: $0.original += 1
            case .converted: $0.converted += 1
            case .failed: $0.failed += 1
            }
        }
        return result
    }

    /// Text sent instead of an image the gate could not turn into a valid
    /// one, so the model knows an image was there and where to find it.
    static func failurePlaceholder(reason: String, linuxPath: String?) -> String {
        if let p = linuxPath {
            return "[image not sent: \(reason). Original at \(p) — re-fetch with `read_image \(p)` if you need to see it.]"
        }
        return "[image not sent: \(reason).]"
    }

    static func sniffFormat(_ data: Data) -> Format {
        let b = [UInt8](data.prefix(12))
        guard b.count >= 4 else { return .unknown }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return .gif }
        if b[0] == 0x42, b[1] == 0x4D { return .bmp }
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return .tiff }
        if b.count >= 12 {
            let tag4 = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, tag4 == "WEBP" { return .webp }
            let box = String(bytes: b[4..<8], encoding: .ascii) ?? ""
            if box == "ftyp", ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis"].contains(tag4) { return .heic }
        }
        return .unknown
    }

    // MARK: - Stats (tests and diagnostics)

    static var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    /// Clears the cache and the counters (tests only).
    static func resetForTesting() {
        cache.removeAllObjects()
        lock.lock(); _stats = Stats(); lock.unlock()
    }

    // MARK: - Implementation

    /// A cached verdict. For an original the bytes are NOT kept (the caller
    /// holds them, and the cache must not keep history images alive); only
    /// converted output is stored, and costed by its size.
    private final class ResultBox: NSObject {
        let stored: Result
        init(_ r: Result) {
            stored = r.kind == .original
                ? Result(kind: .original, data: nil, mimeType: r.mimeType, reason: r.reason, width: r.width, height: r.height)
                : r
        }
        func result(input: Data) -> Result {
            stored.kind == .original
                ? Result(kind: .original, data: input, mimeType: stored.mimeType, reason: "", width: stored.width, height: stored.height)
                : stored
        }
    }

    private static let cache: NSCache<NSString, ResultBox> = {
        let c = NSCache<NSString, ResultBox>()
        c.countLimit = 1024
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stats = Stats()

    private static func count(_ f: (inout Stats) -> Void) {
        lock.lock(); f(&_stats); lock.unlock()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failed(_ reason: String, _ w: Int = 0, _ h: Int = 0) -> Result {
        Result(kind: .failed, data: nil, mimeType: nil, reason: reason, width: w, height: h)
    }

    private static func compute(_ data: Data, maxBytes: Int) -> Result {
        guard !data.isEmpty else { return failed("the image file is empty (0 bytes)") }
        let format = sniffFormat(data)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(src) > 0 else {
            return failed("the bytes are not a readable image")
        }
        // HEIC may keep its main picture at another index; GIF: the first frame.
        let index = format == .gif ? 0 : CGImageSourceGetPrimaryImageIndex(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else {
            return failed("the image has no readable size")
        }
        guard CGImageSourceGetStatusAtIndex(src, index) == .statusComplete else {
            return failed("the image data is truncated or corrupt", w, h)
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false

        var reasons: [String] = []
        if format != .jpeg && format != .png { reasons.append("format \(format.rawValue)") }
        if max(w, h) > maxLongEdge { reasons.append("\(w)x\(h) over \(maxLongEdge) px") }
        if data.count > maxBytes { reasons.append("\(data.count) bytes over \(maxBytes)") }
        if orientation != 1 { reasons.append("EXIF orientation \(orientation)") }
        // ImageIO reads the header of a cut-off file and reports it complete,
        // so check the container's end marker before trusting the bytes as is.
        if (format == .jpeg || format == .png) && !hasEndMarker(data, format) { reasons.append("no \(format.rawValue) end marker") }
        if reasons.isEmpty {
            return Result(kind: .original, data: data, mimeType: format == .png ? "image/png" : "image/jpeg",
                          reason: "", width: w, height: h)
        }

        // Keep transparency as PNG when the source can carry it; else JPEG.
        let keepAlpha = hasAlpha && format != .jpeg
        let full = min(maxLongEdge, max(w, h))
        let ladder: [(edge: Int, quality: CGFloat)] = [
            (full, jpegQuality), (min(full, 1600), 0.8), (min(full, 1280), 0.75),
            (min(full, 1024), 0.7), (min(full, 800), 0.6), (min(full, 640), 0.5),
        ]
        var thumbs: [Int: CGImage] = [:]
        for step in ladder {
            guard let thumb = thumbs[step.edge]
                    ?? decode(src, index: index, format: format, width: w, height: h, orientation: orientation, maxPixelSize: step.edge) else {
                return failed("the image could not be decoded", w, h)
            }
            thumbs[step.edge] = thumb
            if keepAlpha, step.quality == jpegQuality, let png = encode(thumb, type: "public.png", quality: nil),
               png.count <= maxBytes {
                return Result(kind: .converted, data: png, mimeType: "image/png", reason: reasons.joined(separator: ", "),
                              width: thumb.width, height: thumb.height)
            }
            let opaque = keepAlpha || thumb.alphaInfo.hasAlpha ? flattenedOnWhite(thumb) ?? thumb : thumb
            if let jpeg = encode(opaque, type: "public.jpeg", quality: step.quality), jpeg.count <= maxBytes {
                return Result(kind: .converted, data: jpeg, mimeType: "image/jpeg", reason: reasons.joined(separator: ", "),
                              width: thumb.width, height: thumb.height)
            }
        }
        return failed("the image could not be compressed under \(maxBytes) bytes", w, h)
    }

    /// Sampled decode to at most `maxPixelSize` on the long edge, upright.
    ///
    /// JPEG / HEIC: ImageIO's thumbnail path subsamples while decoding.
    /// PNG / TIFF: the thumbnail path still decodes the full bitmap first
    /// (~113 MB peak for a 60 MP PNG), so an un-rotated one is decoded with
    /// kCGImageSourceSubsampleFactor (the largest power of two that keeps at
    /// least 90% of the target edge; ~29 MB for the same PNG) and scaled down
    /// only if it is still over the target.
    private static func decode(_ src: CGImageSource, index: Int, format: Format, width w: Int, height h: Int,
                               orientation: Int, maxPixelSize edge: Int) -> CGImage? {
        if orientation == 1, format == .png || format == .tiff {
            var factor = 1
            while factor < 8, Double(max(w, h)) / Double(factor * 2) >= 0.9 * Double(edge) { factor *= 2 }
            if factor > 1, let sub = CGImageSourceCreateImageAtIndex(
                src, index, [kCGImageSourceSubsampleFactor: factor, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return max(sub.width, sub.height) <= edge ? sub : scaled(sub, toLongEdge: edge)
            }
        }
        return thumbnail(src, index: index, maxPixelSize: edge)
    }

    private static func scaled(_ image: CGImage, toLongEdge edge: Int) -> CGImage? {
        let scale = Double(edge) / Double(max(image.width, image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// JPEG: an EOI marker (FF D9) in the last 4 KB (trailers after it are
    /// legal); PNG: the IEND chunk in the last 12 bytes.
    private static func hasEndMarker(_ data: Data, _ format: Format) -> Bool {
        switch format {
        case .jpeg:
            let tail = [UInt8](data.suffix(4096))
            return zip(tail, tail.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
        case .png:
            return data.suffix(12).range(of: Data("IEND".utf8)) != nil
        default:
            return true
        }
    }

    /// ImageIO's thumbnail path: decodes straight to at most `maxPixelSize`
    /// on the long edge, applying the EXIF orientation.
    private static func thumbnail(_ src: CGImageSource, index: Int, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, options as CFDictionary)
    }

    /// `type`: a UTI ("public.jpeg" / "public.png").
    private static func encode(_ image: CGImage, type: String, quality: CGFloat?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// JPEG has no alpha: composite transparent pixels onto white (what a
    /// viewer shows) instead of letting the encoder turn them black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

private extension CGImageAlphaInfo {
    var hasAlpha: Bool {
        switch self {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }
}
// END ModelImageGate
