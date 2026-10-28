import CryptoKit
import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Request-level image budget + Minis paths + tool-output offload

extension AIChatViewModel {

    // MARK: - Request-level image budget

    /// One image part scoped for budget planning. Mirrors Android's
    /// ImageBudget.BudgetImage so the cross-platform algorithm is
    /// identical. linuxPath optional — missing means "no offload mirror
    /// yet; spill if dropped".
    private struct BudgetImage {
        let data: Data
        let linuxPath: String?
        let mimeType: String
        /// Stable identity for this image WITHIN one request: its position in
        /// the ref list `applyRequestImageBudget` builds.
        ///
        /// [T-image-budget-identity] This used to be derived as
        /// `ObjectIdentifier(data as AnyObject).hashValue`, which cannot serve
        /// as a key: bridging `Data` to `AnyObject` is not guaranteed to be
        /// stable across two conversions, nor distinct between two distinct
        /// `Data` values. Both failure modes were measured here — one run gave a
        /// fresh id per conversion, so `droppedIds` matched NOTHING and the
        /// 25 MB budget silently became a no-op (while the toast still claimed
        /// images had been elided), another gave one shared id for four distinct
        /// images, so the rewrite replaced images that fit the budget. A position
        /// is stable by construction and needs no bridging at all.
        let key: Int
    }

    /// Result of [planRequestBudget]. `droppedKeys` are `BudgetImage.key` values
    /// — positions in the request's image list, not object identities.
    private struct RequestBudgetPlan {
        let droppedKeys: Set<Int>
        let droppedPaths: [Int: String?]
        /// [T-image-budget-base64] Both are BASE64 byte counts (wire size),
        /// matching the unit the budget is expressed in. Log/diagnostic only.
        let keptBytes: Int
        let elidedBytes: Int
        let droppedCount: Int
        let totalCount: Int
        var mutated: Bool { droppedCount > 0 }
    }

    private static func planRequestBudget(
        _ images: [BudgetImage],
        maxBytes: Int = kRequestImageMaxBytes
    ) -> RequestBudgetPlan {
        guard !images.isEmpty else {
            return RequestBudgetPlan(droppedKeys: [], droppedPaths: [:], keptBytes: 0, elidedBytes: 0, droppedCount: 0, totalCount: 0)
        }
        var dropped = Set<Int>()
        var droppedPaths: [Int: String?] = [:]
        var kept = 0
        var elided = 0
        // Walk latest → eldest so most-recent images win the budget.
        for img in images.reversed() {
            let id = img.key
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
        return RequestBudgetPlan(droppedKeys: dropped, droppedPaths: droppedPaths, keptBytes: kept, elidedBytes: elided, droppedCount: dropped.count, totalCount: images.count)
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
    private static func ensureSpillover(_ data: Data, mimeType: String, sessionId: String) -> String? {
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
        let attachmentsRoot = minisPersistentBase
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
        // Collect every image part in chronological order so the planner
        // can reverse-walk and protect the most recent images.
        struct Ref { let msgIdx: Int; let partIdx: Int; let image: BudgetImage }
        var refs: [Ref] = []
        // Each collected image gets its position as its key — the plan and the
        // rewrite below must agree on identity, and position is the only thing
        // they can both recompute reliably (see BudgetImage.key).
        var nextKey = 0
        func collect(msgIdx: Int, partIdx: Int, data: Data, mimeType: String?, linuxPath: String?) {
            refs.append(Ref(
                msgIdx: msgIdx,
                partIdx: partIdx,
                image: BudgetImage(data: data, linuxPath: linuxPath, mimeType: mimeType ?? "image/jpeg", key: nextKey)
            ))
            nextKey += 1
        }
        for (mi, msg) in messages.enumerated() {
            for (pi, part) in msg.parts.enumerated() {
                switch part {
                case .imageData(let data, let mimeType, let lp):
                    collect(msgIdx: mi, partIdx: pi, data: data, mimeType: mimeType, linuxPath: lp)
                case .toolResult(_, _, _, _, let imgData, let imgMime, _, let lp, _):
                    if let d = imgData {
                        collect(msgIdx: mi, partIdx: pi, data: d, mimeType: imgMime, linuxPath: lp)
                    }
                default: break
                }
            }
        }
        guard !refs.isEmpty else { return messages }
        let plan = Self.planRequestBudget(refs.map { $0.image })
        guard plan.mutated else { return messages }

        // Resolve linuxPath for dropped images, spilling if needed.
        var resolved: [Int: String?] = [:]
        let sid = sessionId ?? "unknown"
        for ref in refs {
            let id = ref.image.key
            guard plan.droppedKeys.contains(id) else { continue }
            if let existing = ref.image.linuxPath {
                resolved[id] = existing
            } else {
                resolved[id] = Self.ensureSpillover(ref.image.data, mimeType: ref.image.mimeType, sessionId: sid)
            }
        }

        // Build new messages with dropped image parts replaced.
        var mutated = messages
        let grouped = Dictionary(grouping: refs, by: { $0.msgIdx })
        for (mi, group) in grouped {
            var newParts = mutated[mi].parts
            for ref in group {
                let id = ref.image.key
                guard plan.droppedKeys.contains(id) else { continue }
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

        logger.info("[ImageBudget] request-level: dropped=\(plan.droppedCount)/\(plan.totalCount) keptBytes=\(plan.keptBytes) elidedBytes=\(plan.elidedBytes) (base64 wire bytes, budget=\(Self.kRequestImageMaxBytes))")

        // Surface to the user via Toast (already-existing infrastructure).
        let droppedCount = plan.droppedCount
        Task { @MainActor in
            self.transientNotice = AppLocalized("Older \(droppedCount) image(s) elided from request to fit 25MB budget")
        }

        return mutated
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
        // resolvedContainerRoot falls back to a sandbox-local directory when
        // the App Group entitlement is not honored (re-signed / changed
        // bundle ID builds), so startup never crashes on a nil container.
        SharedContainerStore.resolvedContainerRoot
            .appendingPathComponent("MinisFileProvider", isDirectory: true)
    }

    /// App Group subdirectory for private metadata that must NOT be exposed
    /// to iOS Files (mounted-folders.json, FileProvider extension logs, etc).
    /// Sibling of `minisAppGroupRoot` inside the same App Group container.
    nonisolated static var minisConfigRoot: URL {
        let url = SharedContainerStore.resolvedContainerRoot
            .appendingPathComponent("MinisConfig", isDirectory: true)
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
