import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Minis

/// [T-ctx-builder] iOS-E: the request-building chain through its single entry,
/// `RequestContextBuilder.build(_:)`, with every input given explicitly and the
/// storage injected - `ChatStore(baseURL: <temp dir>)`, spillover under the same
/// temp dir. Neither ChatStore.shared nor the app's Library is touched by these
/// tests, and no AIChatViewModel is created.
///
/// The history helpers the compaction slice uses (walk-back / n-th user text /
/// warm-up trim) are view-model methods that read its live state and model
/// settings; here they are fixed stand-ins (warm-up from the first message, no trim),
/// which pins where the summary lands without depending on model settings. The
/// Standalone layer (MinisTests/Standalone/ImageCtxIosETests.swift) runs the
/// real helpers and the full C01-C32 table.
///
/// Characterization tests pin TODAY's behaviour; desired behaviour is wrapped
/// in XCTExpectFailure (KNOWN GAP) and turns into a failure the day a fix makes
/// it pass - remove the wrapper then.
///
/// Do NOT run this on a Mac whose test host is the real Minis install: the
/// hosted runner starts the app (bundle com.openminis.app) and its launch path
/// reads and writes the real containers. Type-check only:
///   swiftc ... -typecheck src/ios/MinisTests/ImageCtxIosEXCTests.swift
@MainActor
final class ImageCtxIosEXCTests: XCTestCase {

    private let sid = "00000000-0000-4000-8000-00000000E0E0"
    private let gpt = LLMModel(id: "gpt-ctx", displayName: "ctx", provider: "openai", modalityOverride: .vision)
    private var root: URL!
    private var store: ChatStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-iosE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ChatStore(baseURL: root.appendingPathComponent("MinisChat", isDirectory: true))
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private var spilloverBase: URL { root.appendingPathComponent("MinisChat/minis", isDirectory: true) }

    private func jpeg(_ w: Int, _ h: Int, seed: UInt64 = 1) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var x = seed &+ 88172645463325252
        for i in 0..<200 {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            ctx.setFillColor(red: CGFloat(x % 255) / 255, green: CGFloat((x >> 8) % 255) / 255, blue: CGFloat(i % 255) / 255, alpha: 1)
            ctx.fill(CGRect(x: Int(x % UInt64(w)), y: Int((x >> 16) % UInt64(h)), width: w / 8, height: h / 8))
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Fixed stand-ins for the view-model-bound helpers (see the type comment).
    private var helpers: AIChatViewModel.EffectiveHistoryHelpers {
        AIChatViewModel.EffectiveHistoryHelpers(
            // The warm-up starts at the first message - what the real walk-back
            // returns for these short histories. (An empty warm-up would drop
            // the anchor's tool_use and orphan the tool result after it.)
            walkBack: { anchorIdx, _, _ in AIChatViewModel.WalkBackResult(priorIdx: 0, userTextTurnsFound: 1, messageCount: anchorIdx + 1, stopReason: "reachedStart") },
            nthFromLastUserText: { _ in nil },
            trimWarmUp: { warmUp, _, _ in (warmUp, true) }
        )
    }

    private func input(_ history: [AgentMessage], marker: CompactMarker? = nil, maxBytes: Int = AIChatViewModel.kRequestImageMaxBytes) -> RequestContextBuilder.Input {
        RequestContextBuilder.Input(history: history, compaction: marker, warmUpDrop: [:], helpers: helpers, sessionId: sid,
                                    spilloverBase: spilloverBase, requestImageMaxBytes: maxBytes)
    }

    private func withIds(_ msgs: [AgentMessage]) -> [AgentMessage] {
        msgs.enumerated().map { i, m in var x = m; x.dbMessageId = String(format: "db%03d", i); return x }
    }

    private func marker(anchor: String) -> CompactMarker {
        var m = CompactMarker(id: "mk", sessionId: sid, summary: "S: earlier work", firstKeptSortOrder: 0, compactedCount: 0,
                              createdAt: Date(timeIntervalSince1970: 1_800_000_000), uiBoundarySortOrder: nil,
                              boundaryMessageId: anchor, firstKeptMessageId: nil, lastCompactedMessageId: anchor)
        m.version = 2
        return m
    }

    /// Persist with the real conversion into the injected store, then reload
    /// the way loadSession does.
    private func persistAndReload(_ history: [AgentMessage]) async throws -> [AgentMessage] {
        var rows: [RawMessage] = []
        for (i, m) in history.enumerated() {
            let parts = await AIChatViewModel.storedParts(for: m, sessionId: sid, store: store)
            let decoded = try JSONDecoder().decode([ContentPart].self, from: JSONEncoder().encode(parts))
            rows.append(RawMessage(id: m.dbMessageId ?? "r\(i)", sessionId: sid, role: m.role == .user ? .user : .assistant,
                                   parts: decoded, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i))))
        }
        let resolver = await store.mediaFileURLResolver()
        return rows.map { raw in
            var m = raw.toAgentMessage(mediaResolver: resolver)
            m.dbMessageId = raw.id
            return m
        }
    }

    private func images(_ msgs: [AgentMessage]) -> [Data] {
        msgs.flatMap { $0.parts.compactMap { p -> Data? in
            switch p {
            case .imageData(let d, _, _): return d
            case .toolResult(_, _, _, _, let d?, _, _, _, _): return d
            default: return nil
            }
        } }
    }

    private func texts(_ msgs: [AgentMessage]) -> [String] {
        msgs.flatMap { $0.parts.compactMap { if case .text(let t) = $0 { return t }; return nil } }
    }

    // MARK: - C01: no marker, no images = the history as is

    func testC01_plainTextPassesThroughUnchanged() {
        let history = withIds([AgentMessage(role: .user, parts: [.text("hi")]), AgentMessage(role: .assistant, parts: [.text("hello")]),
                               AgentMessage(role: .user, parts: [.text("again")])])
        let out = RequestContextBuilder.build(input(history))
        XCTAssertEqual(texts(out.messages), ["hi", "hello", "again"])
        XCTAssertNil(out.budgetPlan)
        XCTAssertEqual(out.messages.count, out.effectiveHistory.count)
    }

    // MARK: - C04: attached photo, live and after restart

    func testC04_cameraPhotoSameBytesLiveAndAfterRestart() async throws {
        let inline = AIChatViewModel.inlineAttachmentImage(jpeg(4032, 3024), ext: "jpg", route: .send)
        let history = withIds([AgentMessage(role: .user, parts: [.text("[attached image: /var/minis/attachments/uploads/IMG.jpg]"),
                                                                 .imageData(data: inline.final, mimeType: inline.mimeType,
                                                                            linuxPath: "/var/minis/attachments/uploads/IMG.jpg")])])
        let live = RequestContextBuilder.build(input(history)).messages
        let restarted = RequestContextBuilder.build(input(try await persistAndReload(history))).messages
        XCTAssertEqual(images(live).count, 1)
        XCTAssertEqual(images(live), images(restarted))
        let size = UIImage(data: images(live)[0]).map { $0.size }
        XCTAssertEqual(size, CGSize(width: 2000, height: 1500))
        let mediaDir = spilloverBase.appendingPathComponent(sid).appendingPathComponent("attachments")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mediaDir.path).count, 1, "media went to the injected store")
    }

    // MARK: - C25 / C26: where the compaction summary lands

    func testC25_summaryLeadsTheFirstPostAnchorUserMessage() {
        let history = withIds([AgentMessage(role: .user, parts: [.text("q1")]), AgentMessage(role: .assistant, parts: [.text("a1")]),
                               AgentMessage(role: .user, parts: [.text("q2")])])
        let out = RequestContextBuilder.build(input(history, marker: marker(anchor: "db001")))
        let last = try? XCTUnwrap(out.messages.last)
        guard case .text(let first)? = last?.parts.first else { return XCTFail("no text part") }
        XCTAssertTrue(first.hasPrefix("<context-summary>"))
        XCTAssertEqual(texts([last!]).last, "q2")
    }

    /// [T-404-summary-after-tool-results] Was a KNOWN GAP: the summary sat at
    /// parts[0] of the tool-result carrier, between function_call and
    /// function_call_output on Responses, and Chat Completions dropped it.
    func testC26_404_summaryFollowsTheToolResult() throws {
        let history = withIds([AgentMessage(role: .user, parts: [.text("list")]),
                               AgentMessage(role: .assistant, parts: [.toolUse(id: "call_1|fc_1", name: "shell", input: ["command": "ls"])]),
                               AgentMessage(role: .user, parts: [.toolResult(id: "call_1|fc_1", name: "shell", content: "a b", isError: false)]),
                               AgentMessage(role: .assistant, parts: [.text("done")])])
        let out = RequestContextBuilder.build(input(history, marker: marker(anchor: "db001")))
        let carrier = out.messages[out.messages.count - 2]
        guard case .toolResult? = carrier.parts.first, case .text(let s)? = carrier.parts.last else { return XCTFail("carrier shape") }
        XCTAssertTrue(s.hasPrefix("<context-summary>"), "summary follows the tool result")

        let provider = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "no-network", model: gpt))
        let items = provider.convertMessagesResponsesAPI(out.messages)
        let kinds = items.map { ($0["type"] as? String) ?? ($0["role"] as? String ?? "?") }
        let call = try XCTUnwrap(kinds.firstIndex(of: "function_call"))
        XCTAssertEqual(kinds[call + 1], "function_call_output", "function_call_output follows function_call directly")
        let summaryItem = String(decoding: try JSONSerialization.data(withJSONObject: items[call + 2]), as: UTF8.self)
        XCTAssertTrue(summaryItem.contains("context-summary"), "the summary comes right after the output: \(summaryItem.prefix(120))")

        let chat = provider.flattenChatCompletionsMessages(out.messages)
        let roles = chat.map { $0["role"] as? String ?? "?" }
        let tool = try XCTUnwrap(roles.firstIndex(of: "tool"))
        XCTAssertEqual(roles[tool - 1], "assistant", "role:tool directly under its tool_calls")
        XCTAssertEqual(roles[tool + 1], "user")
        XCTAssertTrue((chat[tool + 1]["content"] as? String)?.contains("<context-summary>") == true,
                      "Chat Completions sends the summary as a user message after the tool reply")
    }

    // MARK: - C24: request image budget (budget injected small)

    /// [T-budget-position-ids] Was testC24_budgetPlansOneDropButRewritesAll_today:
    /// ObjectIdentifier ids collided, every image was replaced and every
    /// placeholder named the same file. Ids are now positions.
    func testC24_budgetDropsOnlyThePlannedImage() throws {
        let imgs = (0..<6).map { jpeg(600 + $0, 600, seed: UInt64($0)) }
        let history = withIds(imgs.enumerated().map { i, d in
            AgentMessage(role: .user, parts: [.imageData(data: d, mimeType: "image/jpeg", linuxPath: "/var/minis/attachments/uploads/n\(i).jpg")])
        })
        let largest = imgs.map { AIChatViewModel.estimatedBase64Length($0.count) }.max()!
        let budget = imgs.map { AIChatViewModel.estimatedBase64Length($0.count) }.reduce(0, +) - largest / 2
        let out = RequestContextBuilder.build(input(history, maxBytes: budget))
        let plan = try XCTUnwrap(out.budgetPlan)
        XCTAssertEqual(plan.droppedCount, 1)
        XCTAssertEqual(images(out.messages).count, 5, "only the planned image is dropped")
        let placeholders = texts(out.messages).filter { $0.contains("Original at ") }
        XCTAssertEqual(placeholders.count, 1)
        XCTAssertTrue(placeholders.first?.contains("Original at /var/minis/attachments/uploads/n0.jpg ") == true,
                      "the placeholder names the dropped (oldest) image's own file")
    }

    // MARK: - C30: a missing media file after restart

    func testC30_missingMediaIsDroppedSilently_today() async throws {
        let history = withIds([AgentMessage(role: .user, parts: [.text("look"), .imageData(data: jpeg(800, 600), mimeType: "image/jpeg",
                                                                                         linuxPath: "/var/minis/attachments/uploads/p.jpg")])])
        var rows: [AgentMessage] = []
        let parts = await AIChatViewModel.storedParts(for: history[0], sessionId: sid, store: store)
        for case .mediaRef(let ref) in parts { try FileManager.default.removeItem(at: await store.mediaFileURL(for: ref)) }
        let resolver = await store.mediaFileURLResolver()
        rows.append(RawMessage(id: "db000", sessionId: sid, role: .user, parts: parts, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            .toAgentMessage(mediaResolver: resolver))
        let out = RequestContextBuilder.build(input(rows))
        XCTAssertEqual(images(out.messages).count, 0)
        XCTAssertEqual(texts(out.messages), ["look"], "today: no placeholder replaces the lost image")
        XCTExpectFailure("KNOWN GAP: a lost image should leave a visible placeholder") {
            XCTAssertTrue(texts(out.messages).contains { $0.contains("[image") })
        }
    }
}
