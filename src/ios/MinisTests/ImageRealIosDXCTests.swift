import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import Minis

/// [T-image-real-seams] iOS-D, slow layer: tool images (browser_use,
/// read_image) through the app's own code from the stored row to every
/// provider's request: a RawMessage carrying a toolResult mediaRef (file
/// written by the real `ChatStore.saveMedia`) -> the real
/// `RawMessage.toAgentMessage` -> `applyRequestImageBudget` -> the real
/// serializers: Anthropic's `requestBody(messages:...)` (conversion + SDK
/// encoding + URLProtocol patches), Gemini and Antigravity `convertMessages`,
/// OpenAI Chat Completions `flattenChatCompletionsMessages`. Responses and the
/// attachment path are iOS-A's (`ImageRealIosAXCTests`).
///
/// Providers are only constructed (dummy credentials); nothing is sent.
/// Desired behaviour still missing is wrapped in XCTExpectFailure. The fast
/// layer is MinisTests/Standalone/ImageRealIosDTests.swift.
@MainActor
final class ImageRealIosDXCTests: XCTestCase {

    private let sessionId = "image-real-iosD-\(UUID().uuidString)"
    private let claude = LLMModel(id: "claude-sonnet-5", displayName: "image-real", provider: "anthropic", modalityOverride: .vision)
    private let gemini = LLMModel(id: "gemini-2.5-pro", displayName: "image-real", provider: "gemini", modalityOverride: .vision)
    private let gpt = LLMModel(id: "gpt-image-real", displayName: "image-real", provider: "openai", modalityOverride: .vision)

    /// [T-ios-unit-test-infra] Every test gets its own media store under a temp dir.
    /// `ChatStore.testOverride` points the app helpers that use `store`
    /// internally (snapshot / browser media) at the same store.
    private var storeRoot: URL!
    private var store: ChatStore!

    override func setUp() async throws {
        try await super.setUp()
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisTests-\(UUID().uuidString)", isDirectory: true)
        store = ChatStore(baseURL: storeRoot.appendingPathComponent("MinisChat", isDirectory: true))
        ChatStore.testOverride = store
    }

    override func tearDown() async throws {
        ChatStore.testOverride = nil
        store = nil
        try? FileManager.default.removeItem(at: storeRoot)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func page(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(UIColor(white: 0.25, alpha: 1).cgColor)
        var y = 40, line = 0
        while y < h - 20 {
            ctx.fill(CGRect(x: 40, y: y, width: (w - 80) * (60 + (line * 37) % 40) / 100, height: max(2, w / 160)))
            y += max(10, w / 60); line += 1
        }
        return encode(ctx.makeImage()!, .jpeg)
    }

    private func encode(_ img: CGImage, _ type: UTType) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(_ data: Data) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    // MARK: - Request-body image parsing (same carriers as ImageRealIosD/WireImages.swift)

    private struct Wire { let mime: String; let data: Data }

    private func wireImages(_ body: Any) -> [Wire] {
        var found: [Wire] = []
        func walk(_ v: Any) {
            if let s = v as? String, s.hasPrefix("data:"), let comma = s.firstIndex(of: ","),
               let d = Data(base64Encoded: String(s[s.index(after: comma)...])) {
                found.append(Wire(mime: String(s[s.index(s.startIndex, offsetBy: 5)..<comma]).replacingOccurrences(of: ";base64", with: ""), data: d))
                return
            }
            if let a = v as? [Any] { a.forEach(walk); return }
            guard let dict = v as? [String: Any] else { return }
            for key in ["inlineData", "inline_data"] {
                if let i = dict[key] as? [String: Any], let b = i["data"] as? String, let d = Data(base64Encoded: b) {
                    found.append(Wire(mime: (i["mimeType"] as? String) ?? (i["mime_type"] as? String) ?? "?", data: d))
                }
            }
            if dict["type"] as? String == "image", let src = dict["source"] as? [String: Any],
               let b = src["data"] as? String, let d = Data(base64Encoded: b) {
                found.append(Wire(mime: src["media_type"] as? String ?? "?", data: d))
            }
            for key in dict.keys.sorted() where key != "inlineData" && key != "inline_data" && !(key == "source" && dict["type"] as? String == "image") {
                walk(dict[key]!)
            }
        }
        if let data = body as? Data, let json = try? JSONSerialization.jsonObject(with: data) { walk(json) } else { walk(body) }
        return found
    }

    // MARK: - Stored row -> rebuilt history

    /// A tool turn as persisted: toolUse, then a toolResult whose mediaRef
    /// points at `image` written through the real media store.
    private func reloadedToolTurn(tool: String, image: Data, subdir: String, linuxPath: String) async throws -> [AgentMessage] {
        let ref = await store.saveMedia(data: image, mimeType: "image/jpeg", sessionId: sessionId,
                                                   subdir: subdir, linuxPath: linuxPath)
        let rows: [(MessageRole, [ContentPart])] = [
            (.user, [.text("look at it")]),
            (.assistant, [.toolUse(ToolUse(toolUseId: "toolu_1", name: tool, input: "{\"action\":\"screenshot\"}",
                                           description: nil, thoughtSignature: nil))]),
            (.user, [.toolResult(ToolResult(toolUseId: "toolu_1", output: "done", success: true, mediaRef: ref,
                                            snapshot: ToolSnapshot(type: .image, text: nil, mediaRef: ref, duration: 1),
                                            pageURL: nil, status: "success"))]),
            (.user, [.text("what does it show?")]),
        ]
        let resolver = await store.mediaFileURLResolver()
        var history: [AgentMessage] = []
        for (i, row) in rows.enumerated() {
            let parts = try JSONDecoder().decode([ContentPart].self, from: JSONEncoder().encode(row.1))
            history.append(RawMessage(id: "m\(i)", sessionId: sessionId, role: row.0, parts: parts, createdAt: Date())
                .toAgentMessage(mediaResolver: resolver))
        }
        return history
    }

    private struct Bodies { let anthropic: [Wire]; let anthropicKeyAuth: [Wire]; let gemini: [Wire]; let antigravity: [Wire]; let chat: [Wire] }

    private func serialize(_ history: [AgentMessage]) throws -> Bodies {
        let budgeted = AIChatViewModel().applyRequestImageBudget(history)
        let oauth = AnthropicAgentProvider(provider: AnthropicProvider(oauthTokenProvider: { "no-network" }, model: claude))
        let anthropic = try XCTUnwrap(oauth.requestBody(messages: budgeted, systemPrompt: "test", tools: [],
                                                        maxTokens: 1024, route: .oauth))
        let key = AnthropicAgentProvider(provider: AnthropicProvider(apiKey: "no-network", model: claude))
        let keyBody = try XCTUnwrap(key.requestBody(messages: budgeted, systemPrompt: "test", tools: [],
                                                    maxTokens: 1024, route: .keyAuth))
        let geminiBody = GeminiAgentProvider(provider: GeminiProvider(apiKey: "no-network", model: gemini)).convertMessages(budgeted)
        let agBody = AntigravityAgentProvider(provider: AntigravityProvider(oauthTokenProvider: { "no-network" }, model: gemini))
            .convertMessages(budgeted)
        let chatBody = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "no-network", model: gpt)).flattenChatCompletionsMessages(budgeted)
        return Bodies(anthropic: wireImages(anthropic), anthropicKeyAuth: wireImages(keyBody), gemini: wireImages(geminiBody),
                      antigravity: wireImages(agBody), chat: wireImages(chatBody))
    }

    // MARK: - P-i2 (wire half): browser_use screenshot after a reload

    /// [T-image-gate] Was ..._GoesOutAsTheOriginalExceptOnAnthropic_today: the
    /// four non-Anthropic providers sent the 2760x21891 original after a
    /// reload. The request gate now sends every provider the same <= 2000 image.
    func testReloadedScreenshotGoesOutGatedOnEveryProvider() async throws {
        let original = page(2760, 21891)
        let history = try await reloadedToolTurn(tool: "browser_use", image: original, subdir: "browser",
                                                 linuxPath: "/var/minis/browser/screenshot_1.jpg")
        guard case .toolResult(_, _, _, _, let rebuilt?, let mime, _, _, _) = history[2].parts.first else {
            return XCTFail("tool image lost on reload")
        }
        XCTAssertEqual(rebuilt, original); XCTAssertEqual(mime, "image/jpeg")

        let b = try serialize(history)
        let gated = try XCTUnwrap(ModelImageGate.prepare(
            original, maxBytes: AIChatViewModel.rawBytesForBase64Budget(AIChatViewModel.kPerImageMaxBytes)).data)
        for (name, imgs) in [("gemini", b.gemini), ("antigravity", b.antigravity), ("chat", b.chat), ("anthropic", b.anthropic)] {
            XCTAssertEqual(imgs.count, 1, name)
            XCTAssertEqual(imgs.first?.data, gated, "\(name) sends the gate's 252x2000 image")
            XCTAssertEqual(imgs.first?.mime, "image/jpeg", name)
        }
        XCTAssertEqual(pixelSize(gated).1, 2000)

        // [T-image-gate #412] The live turn sends the gate's output too.
        XCTAssertEqual(b.gemini.first?.data, AIChatViewModel.browserUseInferenceImage(original).data,
                       "P-i2: after a reload every provider gets the image the live turn sent")
    }

    // MARK: - read_image tool image after a reload

    func testReloadedReadImageGoesOutOnEveryProvider() async throws {
        let shot = page(1200, 900)
        let history = try await reloadedToolTurn(tool: "read_image", image: shot, subdir: "images",
                                                 linuxPath: "/var/minis/images/photo.jpg")
        let b = try serialize(history)
        for (name, imgs) in [("anthropic", b.anthropic), ("gemini", b.gemini), ("antigravity", b.antigravity), ("chat", b.chat)] {
            XCTAssertEqual(imgs.count, 1, name)
            XCTAssertEqual(imgs.first?.data, shot, "\(name): a <= 2000 image goes out byte-identical")
            XCTAssertEqual(imgs.first?.mime, "image/jpeg", name)
        }
    }

    // MARK: - Anthropic API key / manual token route

    /// [T-anthropic-keyauth-toolimages] The key-auth chain claims the request
    /// token like the OAuth chain, so the tool image rides in the tool_result.
    func testKeyAuthRouteSendsTheToolImage() async throws {
        let history = try await reloadedToolTurn(tool: "browser_use", image: page(800, 600), subdir: "browser",
                                                 linuxPath: "/var/minis/browser/screenshot_2.jpg")
        let b = try serialize(history)
        XCTAssertEqual(b.anthropic.count, 1, "the OAuth route carries the tool image")
        XCTAssertEqual(b.anthropicKeyAuth.count, 1, "a tool-result image reaches Anthropic in API-key mode too")
        XCTAssertEqual(b.anthropicKeyAuth.first?.data, b.anthropic.first?.data, "same bytes on both routes")
        XCTAssertEqual(b.anthropicKeyAuth.first?.mime, "image/jpeg")
    }

    /// [T-anthropic-keyauth-toolimages] 20 rounds of: a request built but never
    /// sent (cancelled), a key-auth request, an OAuth request - each staged
    /// and patched through the real RequestBodyPatcher. Every OAuth request
    /// must get its own image back.
    ///
    /// The OAuth tokens are chosen to sort FIRST and the cancelled ones LAST:
    /// the old eviction dropped the lexicographically smallest tokens once the
    /// table passed 16 entries, so it would evict the OAuth request's own entry
    /// the moment it was written. Eviction by write order never drops the
    /// newest entry.
    func testInterleavedOAuthAndKeyAuthRequestsKeepEveryOAuthImage() throws {
        let image = page(320, 240)
        func body(_ toolUseId: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "model": "claude-sonnet-5", "max_tokens": 64,
                "messages": [["role": "user", "content": [["type": "tool_result", "tool_use_id": toolUseId, "content": "shot"]]]],
            ])
        }
        func sentImageCount(_ request: NSMutableURLRequest) -> Int { wireImages(request.httpBody ?? Data()).count }
        var oauthDelivered = 0, keyDelivered = 0
        for i in 0..<20 {
            RequestBodyPatcher.setToolResultImages(["toolu_cancel_\(i)": (image, "image/jpeg")],
                                                   requestToken: String(format: "ffff-cancelled-%02d", i))

            let keyToken = String(format: "8888-key-%02d", i)
            RequestBodyPatcher.setRequestToken(keyToken)
            RequestBodyPatcher.setToolResultImages(["toolu_key_\(i)": (image, "image/jpeg")], requestToken: keyToken)
            let keyRequest = NSMutableURLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            keyRequest.httpBody = body("toolu_key_\(i)")
            RequestBodyPatcher.applyKeyAuthBodyPatches(to: keyRequest)
            keyDelivered += sentImageCount(keyRequest)
            XCTAssertNil(keyRequest.value(forHTTPHeaderField: RequestBodyPatcher.requestTokenHeader), "token never leaves the device")

            let oauthToken = String(format: "0000-oauth-%02d", i)
            RequestBodyPatcher.setRequestToken(oauthToken)
            RequestBodyPatcher.setToolResultImages(["toolu_oauth_\(i)": (image, "image/jpeg")], requestToken: oauthToken)
            let oauthRequest = NSMutableURLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            oauthRequest.httpBody = body("toolu_oauth_\(i)")
            RequestBodyPatcher.applyOAuthBodyPatches(to: oauthRequest)
            oauthDelivered += sentImageCount(oauthRequest)
        }
        XCTAssertEqual(oauthDelivered, 20, "no OAuth request lost its image")
        XCTAssertEqual(keyDelivered, 20, "every key-auth request carried its image")
    }
}
