// [T-ctx-builder] iOS-E session DSL (catalog A6) and storage isolation (A7).
//
// A Session is one conversation in its own temp directory: `ChatStore(baseURL:
// <case dir>/MinisChat)` (the same initializer the app's tests use), and every
// /var/minis path resolves under `<case dir>/MinisChat/minis/<sid>/...`.
// Nothing outside the case directory is read or written.
//
// What runs for real (compiled from the current sources by the driver):
//   * attachment intake: addDataAttachment / addFileAttachment (kind
//     detection), processAttachments (queue route), inlineAttachmentImage /
//     attachmentImageOverflowsMessage (send route), consumePastedDraft
//   * tool images: browserUseInferenceImage, writeBrowserScreenshotCopy,
//     saveBrowserSnapshotMedia, readImageInference, saveReadImageSnapshotMedia,
//     takeoverScreenshotMessage
//   * persistence: AIChatViewModel.storedParts (buildRawMessage's conversion),
//     the ContentPart JSON ChatStore writes, RawMessage.toAgentMessage
//   * the request: RequestContextBuilder.build, then each provider's serializer
// Mirrored (the original is not a callable function; the driver checks the
// mirrored lines still exist verbatim in the source):
//   * send()'s attachment loop around the real per-image step
//   * the loadSession loop: toAgentMessage + dbMessageId per stored row
//   * edit: the attachment restore of editMessage + the history cut
//   * fork: SessionForkManager.duplicateSession's verbatim parts copy
//
// Guarded like Kit.swift.
#if IMAGE_CTX_IOS_E
import Foundation
import UIKit

enum AttachRoute { case send, queue }

struct Capture {
    let phase: String
    let output: RequestContextBuilder.Output
    var views: [Provider: [RVMessage]] = [:]
    var logs: [String] = []
}

final class Session {
    let sid: String
    let store: ChatStore
    let vm = AIChatViewModel()
    var history: [AgentMessage] = []
    var rows: [RawMessage] = []
    var marker: CompactMarker?
    var snapshots: [String: (toolName: String, snapshot: ToolSnapshot)] = [:]
    var userAttachmentMetas: [Int: [AttachmentMeta]] = [:]
    var seq = 0

    init(_ sid: String) {
        self.sid = sid
        store = ChatStore(baseURL: HarnessEnv.root.appendingPathComponent("MinisChat", isDirectory: true))
        ChatStore.shared = store   // the tool seams still call ChatStore.shared
        vm.sessionId = sid
    }

    var sessionDir: URL { AIChatViewModel.minisPersistentBase.appendingPathComponent(sid, isDirectory: true) }
    func hostPath(linux: String) -> URL {
        sessionDir.appendingPathComponent(String(linux.dropFirst("/var/minis/".count)))
    }

    // MARK: persistence

    /// Appends to agentHistory and persists like persistAgentMessage: real
    /// storedParts, JSON round trip, dbMessageId set on the live entry.
    @discardableResult
    func append(_ msg: AgentMessage, pasted: [String: [ContentPart]] = [:]) async -> Int {
        seq += 1
        let id = String(format: "m%04d", seq)
        let parts = await AIChatViewModel.storedParts(for: msg, sessionId: sid, snapshots: snapshots, pastedParts: pasted, store: store)
        let json = try! JSONEncoder().encode(parts)
        let decoded = try! JSONDecoder().decode([ContentPart].self, from: json)
        var raw = RawMessage(id: id, sessionId: sid, role: msg.role == .user ? .user : .assistant, parts: decoded,
                             createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(seq)),
                             reasoningContent: msg.reasoningContent)
        raw.reasoningEchoJSON = msg.reasoningEcho?.persistableJSON
        rows.append(raw)
        var live = msg
        live.dbMessageId = id
        history.append(live)
        return history.count - 1
    }

    /// restart(): drop memory, rebuild agentHistory from the stored rows the
    /// way loadSession does.
    func restart() async {
        let resolver = await store.mediaFileURLResolver()
        history = rows.map { raw in
            var agentMsg = raw.toAgentMessage(mediaResolver: resolver)
            agentMsg.dbMessageId = raw.id
            return agentMsg
        }
    }

    // MARK: user input

    /// user(text, attachments): attachments go through the real intake
    /// (addDataAttachment kind detection, then the chosen route).
    @discardableResult
    func user(_ text: String, _ files: [Fixture] = [], route: AttachRoute = .send, pastes: [String] = []) async -> Int {
        vm.attachments = []
        for f in files { vm.addDataAttachment(data: f.data, fileName: f.fileName) }
        return await userWithStagedAttachments(text, route: route, pastes: pastes)
    }

    func userWithStagedAttachments(_ text: String, route: AttachRoute, pastes: [String] = []) async -> Int {
        let uploadsDir = AIChatViewModel.minisUploadsDir(for: sid)
        try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
        var parts: [AgentContentPart]
        var metas: [AttachmentMeta]
        switch route {
        case .queue:
            (parts, metas) = vm.processAttachments(vm.attachments, uploadsDir: uploadsDir, nowStr: "2027-01-15T08:00:00Z")
        case .send:
            (parts, metas) = sendRouteAttachments(vm.attachments, uploadsDir: uploadsDir, nowStr: "2027-01-15T08:00:00Z")
        }
        var pasted: [String: [ContentPart]] = [:]
        var body = text
        if !pastes.isEmpty {
            vm.pastedTexts = pastes.enumerated().map { PastedText(id: $0.offset + 1, text: $0.element) }
            body = text + pastes.indices.map { " [Pasted#\($0 + 1)]" }.joined()
        }
        if !body.isEmpty {
            if let consumed = await vm.consumePastedDraft(body, sessionId: sid) {
                parts.append(.text(consumed.modelText))
                pasted[consumed.modelText] = consumed.storedParts
            } else {
                parts.append(.text(body))
            }
        }
        vm.pastedTexts = []
        let idx = await append(AgentMessage(role: .user, parts: parts), pasted: pasted)
        userAttachmentMetas[idx] = metas
        return idx
    }

    /// send()'s attachment loop (AIChatViewModel+Send.swift), mirrored around
    /// the real per-image functions. Same order, texts and budgets.
    func sendRouteAttachments(_ attachments: [InputAttachment], uploadsDir: URL, nowStr: String) -> ([AgentContentPart], [AttachmentMeta]) {
        let fm = FileManager.default
        var metas: [AttachmentMeta] = []
        var userParts: [AgentContentPart] = []
        let inlineBudget = AIChatViewModel.kImageContextKeepCount
        var inlinedImages = 0
        var cumulativeImageBytes = 0
        for attachment in attachments {
            guard fm.fileExists(atPath: attachment.cacheURL.path) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: attachment.cacheURL.path)
            let fileDate: Date = (attrs?[.modificationDate] as? Date) ?? Date()
            let fileSize = (attrs?[.size] as? Int) ?? 0
            let safeName = AIChatViewModel.uniqueFileName(for: attachment.fileName, in: uploadsDir)
            let destURL = uploadsDir.appendingPathComponent(safeName)
            do { try fm.copyItem(at: attachment.cacheURL, to: destURL) } catch { continue }
            let linuxPath = "/var/minis/attachments/uploads/\(safeName)"
            metas.append(AttachmentMeta(path: linuxPath, size: fileSize, modified: fileDate))
            guard attachment.kind == .image else { continue }
            guard let data = try? Data(contentsOf: attachment.cacheURL) else { continue }
            if inlinedImages < inlineBudget {
                let ext = attachment.cacheURL.pathExtension.lowercased()
                let inline = AIChatViewModel.inlineAttachmentImage(data, ext: ext, route: .send)
                let compressed = inline.final
                let compressedB64 = AIChatViewModel.estimatedBase64Length(compressed.count)
                if AIChatViewModel.attachmentImageOverflowsMessage(cumulativeImageBytes: cumulativeImageBytes, compressedB64: compressedB64) {
                    userParts.append(.text(AIChatViewModel.imagePlaceholderText(data: data, originalPath: linuxPath, snapshotPath: nil)))
                } else {
                    userParts.append(.text("[attached image: \(linuxPath)]"))
                    userParts.append(.imageData(data: compressed, mimeType: inline.mimeType, linuxPath: linuxPath))
                    inlinedImages += 1
                    cumulativeImageBytes += compressedB64
                }
            } else {
                userParts.append(.text(AIChatViewModel.imagePlaceholderText(data: data, originalPath: linuxPath, snapshotPath: nil)))
            }
        }
        if !metas.isEmpty {
            var xml = "<user-attached-files>\n"
            for meta in metas {
                xml += "  <file path=\"\(meta.path)\" url=\"\(meta.minisURL)\" size=\"\(meta.size)\" modified=\"\(nowStr)\" />\n"
            }
            xml += "</user-attached-files>"
            userParts.append(.text(xml))
        }
        let totalImageAttachments = attachments.filter { $0.kind == .image }.count
        if totalImageAttachments > inlinedImages {
            let omitted = totalImageAttachments - inlinedImages
            userParts.append(.text(
                "<system-reminder>Only \(inlinedImages) of \(totalImageAttachments) images are inlined above."
                + " The remaining \(omitted) are saved to disk — use read_image to view them."
                + " To stay within the context image limit (\(AIChatViewModel.kImageContextKeepCount)),"
                + " process images in batches: read a batch, analyze, then summarize your findings"
                + " before reading the next batch.</system-reminder>"
            ))
        }
        return (userParts, metas)
    }

    // MARK: assistant / tools

    func assistant(_ text: String?, toolUses: [(id: String, name: String, input: [String: Any])] = []) async {
        var parts: [AgentContentPart] = []
        if let text { parts.append(.text(text)) }
        for t in toolUses { parts.append(.toolUse(id: t.id, name: t.name, input: t.input)) }
        await append(AgentMessage(role: .assistant, parts: parts))
    }

    func toolResult(_ id: String, _ name: String, _ text: String, image: Data? = nil, mime: String? = nil,
                    linuxPath: String? = nil, snapshot: ToolSnapshot? = nil) async {
        if let snapshot { snapshots[id] = (name, snapshot) }
        await append(AgentMessage(role: .user, parts: [.toolResult(id: id, name: name, content: text, isError: false,
                                                                   imageData: image, imageMimeType: mime, imageLinuxPath: linuxPath)]))
    }

    /// browser_use screenshot round, exactly the tool path's image steps.
    func browserScreenshot(_ id: String, pointW: Int, pointH: Int) async -> (live: Data, original: Data) {
        let shot = Kit.screenshot(pointW: pointW, pointH: pointH)
        await assistant(nil, toolUses: [(id, "browser_use", ["action": "screenshot"])])
        let inference = AIChatViewModel.browserUseInferenceImage(shot.data)
        let linuxPath = AIChatViewModel.writeBrowserScreenshotCopy(shot.data, sessionId: sid)
        // [T-image-gate #412] The snapshot stores the model image (ConcurrentTools:
        // `toolImageData ?? <file>`), not the original.
        let ref = await AIChatViewModel.saveBrowserSnapshotMedia(imageData: inference.data, sessionId: sid, linuxPath: linuxPath,
                                                                 mimeType: inference.mimeType)
        let snap = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: nil)
        let meta = BrowserUseManager.screenshotImageLine(imageSize: shot.size, fileSize: shot.data.count)
        await toolResult(id, "browser_use", "Screenshot captured\n\(meta)\n  minis_url: \(linuxPath)", image: inference.data,
                         mime: inference.mimeType, linuxPath: linuxPath, snapshot: snap)
        return (inference.data, shot.data)
    }

    /// read_image round: the file is written under uploads, then read.
    func readImage(_ id: String, _ f: Fixture) async -> Data? {
        let uploads = AIChatViewModel.minisUploadsDir(for: sid)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let url = uploads.appendingPathComponent(f.fileName)
        if !FileManager.default.fileExists(atPath: url.path) { try! f.data.write(to: url) }
        await assistant(nil, toolUses: [(id, "read_image", ["path": "/var/minis/attachments/uploads/\(f.fileName)"])])
        guard let ui = UIImage(data: f.data) else {
            await toolResult(id, "read_image", "Error: not an image")
            return nil
        }
        let inf = AIChatViewModel.readImageInference(fileData: f.data, image: ui)
        let ref = await AIChatViewModel.saveReadImageSnapshotMedia(imagePath: url.path, imageData: inf.data, sessionId: sid,
                                                                   linuxPath: "/var/minis/attachments/uploads/\(f.fileName)")
        let snap = ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: nil)
        await toolResult(id, "read_image", "Image \(inf.originalW)x\(inf.originalH) -> \(inf.resizedW)x\(inf.resizedH)",
                         image: inf.data, mime: inf.mimeType, linuxPath: "/var/minis/attachments/uploads/\(f.fileName)", snapshot: snap)
        return inf.data
    }

    /// takeover: the message the agent loop appends - [T-image-gate] and now
    /// stores like its other injected rows (was: agentHistory only, P-i4).
    func takeover(_ data: Data) async {
        _ = await append(AIChatViewModel.takeoverScreenshotMessage(data, sessionId: sid, timestamp: 1_800_000_123))
    }

    // MARK: compaction / edit / fork

    /// compaction(anchorAt, summary): a v2 marker whose anchor is the message
    /// at `index` (its dbMessageId), as the compactor writes it.
    func compaction(anchorAt index: Int, summary: String) {
        let anchor = history[index].dbMessageId
        let firstKept = index + 1 < history.count ? history[index + 1].dbMessageId : nil
        var m = CompactMarker(id: "marker-\(sid)", sessionId: sid, summary: summary, firstKeptSortOrder: index + 1,
                              compactedCount: index + 1, createdAt: Date(timeIntervalSince1970: 1_800_000_500),
                              uiBoundarySortOrder: nil, boundaryMessageId: anchor, firstKeptMessageId: firstKept,
                              lastCompactedMessageId: anchor)
        m.version = 2
        marker = m
    }

    /// edit(messageIndex, newText): editMessage restores the bubble's
    /// attachments from uploads into the composer, send() cuts history at the
    /// bubble and sends again.
    func edit(_ index: Int, _ newText: String) async {
        let metas = userAttachmentMetas[index] ?? []
        vm.attachments = []
        let cache = HarnessEnv.root.appendingPathComponent("Caches/InputAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for meta in metas {
            let fileName = (meta.path as NSString).lastPathComponent
            let src = AIChatViewModel.minisUploadsDir(for: sid).appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = cache.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
            let ext = (fileName as NSString).pathExtension.lowercased()
            let kind: InputAttachment.Kind = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) ? .image
                : (["mp4", "mov", "m4v"].contains(ext) ? .video : .document)
            vm.attachments.append(InputAttachment(fileName: fileName, cacheURL: dst, kind: kind))
        }
        history = Array(history.prefix(index))
        rows = Array(rows.prefix(index))
        await userWithStagedAttachments(newText, route: .send)
    }

    func fileCount(_ sub: String) -> Int {
        let dir = sessionDir.appendingPathComponent(sub)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    // MARK: the request

    func capture(_ phase: String) -> Capture {
        vm.agentHistory = history
        HarnessLog.lines.removeAll()
        let input = RequestContextBuilder.Input(
            history: history, compaction: marker, warmUpDrop: [:], helpers: vm.effectiveHistoryHelpers(),
            sessionId: sid, spilloverBase: AIChatViewModel.minisPersistentBase,
            requestImageMaxBytes: AIChatViewModel.kRequestImageMaxBytes)
        let output = RequestContextBuilder.build(input)
        var cap = Capture(phase: phase, output: output)
        cap.logs = HarnessLog.lines
        let messages = output.messages
        cap.views[.responses] = RequestView.parse(.responses, OpenAIAgentProvider(model: openAIModel).convertMessagesResponsesAPI(messages))
        cap.views[.chat] = RequestView.parse(.chat, OpenAIAgentProvider(model: openAIModel).flattenChatCompletionsMessages(messages))
        cap.views[.gemini] = RequestView.parse(.gemini, GeminiAgentProvider(model: geminiModel).convertMessages(messages))
        cap.views[.antigravity] = RequestView.parse(.antigravity, AntigravityAgentProvider(model: geminiModel).convertMessages(messages))
        let anthropic = AnthropicAgentProvider(provider: AnthropicProvider(model: claudeModel, isClaudeCode: true))
        let body = (try? anthropic.requestBody(messages: messages, systemPrompt: "harness", tools: [], maxTokens: 1024, route: .oauth)) ?? nil
        cap.views[.anthropic] = RequestView.parse(.anthropic, body ?? Data())
        return cap
    }
}

let openAIModel = LLMModel(id: "gpt-ctx", displayName: "ctx", provider: "openai", modalityOverride: .vision)
let geminiModel = LLMModel(id: "gemini-2.5-pro", displayName: "ctx", provider: "gemini", modalityOverride: .vision)
let claudeModel = LLMModel(id: "claude-sonnet-5", displayName: "ctx", provider: "anthropic", modalityOverride: .vision)

/// Images an AgentMessage list carries (user images and tool images).
func historyImages(_ h: [AgentMessage]) -> [Data] {
    h.flatMap { m in m.parts.compactMap { p -> Data? in
        switch p {
        case .imageData(let d, _, _): return d
        case .toolResult(_, _, _, _, let d?, _, _, _, _): return d
        default: return nil
        }
    } }
}
#endif
