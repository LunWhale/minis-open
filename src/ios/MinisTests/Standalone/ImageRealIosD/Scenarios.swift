// [T-image-real-seams] iOS-D scenarios: the request bodies all five
// serializers produce for a browser_use screenshot, on the live turn and after
// a reload, plus the gate idempotence of P-i6. Anthropic goes through the real
// `requestBody(...)` entry (conversion + SDK encoding + URLProtocol patches).
// Results go to the JSON file named by argv[1].
//
// Guarded like Fixtures.swift; the driver's main.swift calls runScenarios().
#if IMAGE_REAL_IOS_D
import Foundation
import UIKit

var results: [String: Any] = [:]
func R(_ key: String, _ value: Any) { results[key] = value }

let openAIModel = LLMModel(id: "gpt-image-real", displayName: "image-real", provider: "openai", modalityOverride: .vision)
let geminiModel = LLMModel(id: "gemini-2.5-pro", displayName: "image-real", provider: "gemini", modalityOverride: .vision)
let claudeModel = LLMModel(id: "claude-sonnet-5", displayName: "image-real", provider: "anthropic", modalityOverride: .vision)

/// A browser_use screenshot turn as agentHistory holds it.
func screenshotHistory(_ image: Data) -> [AgentMessage] {
    [AgentMessage(role: .user, parts: [.text("open the page")]),
     AgentMessage(role: .assistant, parts: [.toolUse(id: "toolu_1", name: "browser_use", input: ["action": "screenshot"])]),
     AgentMessage(role: .user, parts: [.toolResult(id: "toolu_1", name: "browser_use", content: "Screenshot taken", isError: false,
                                                   imageData: image, imageMimeType: "image/jpeg",
                                                   imageLinuxPath: "/var/minis/browser/screenshot_1.jpg")]),
     AgentMessage(role: .user, parts: [.text("what does it say?")])]
}

func recordWire(_ key: String, _ body: Any) {
    let imgs = wireImages(body)
    R("\(key).count", imgs.count)
    guard let first = imgs.first else { return }
    let p = probe(first.data)
    R("\(key).w", p.w); R("\(key).h", p.h); R("\(key).fmt", p.fmt)
    R("\(key).mime", first.mimeType); R("\(key).bytes", first.data.count); R("\(key).b64", first.base64Length)
    R("\(key).sha", String(sha256(first.data).prefix(16))); R("\(key).path", first.path); R("\(key).carrier", first.carrier)
}

func bodies(_ phase: String, _ history: [AgentMessage]) {
    recordWire("p2.\(phase).responses", OpenAIAgentProvider(model: openAIModel).convertMessagesResponsesAPI(history))
    recordWire("p2.\(phase).chat", OpenAIAgentProvider(model: openAIModel).flattenChatCompletionsMessages(history))
    recordWire("p2.\(phase).gemini", GeminiAgentProvider(model: geminiModel).convertMessages(history))
    recordWire("p2.\(phase).antigravity", AntigravityAgentProvider(model: geminiModel).convertMessages(history))
    let anthropic = AnthropicAgentProvider(provider: AnthropicProvider(model: claudeModel, isClaudeCode: true))
    let body = try! anthropic.requestBody(messages: history, systemPrompt: "harness", tools: [], maxTokens: 1024, route: .oauth)!
    recordWire("p2.\(phase).anthropic", body)
}

func runScenarios() {
    // P-i2: the browser_use original and its live-turn image (what browser_use
    // sends live: resizedImageData(original) ?? original).
    let original = encode(makeCGImage(w: 2760, h: 21891, pattern: .page), type: .jpeg, quality: 0.8)
    let live = AIChatViewModel.resizedImageData(original, maxLongEdge: 2000) ?? original
    R("p2.original.sha", String(sha256(original).prefix(16)))
    R("p2.live.src.sha", String(sha256(live).prefix(16)))
    bodies("live", screenshotHistory(live))
    bodies("rebuilt", screenshotHistory(original))

    // Anthropic, API key / manual token route.
    let keyAuth = AnthropicAgentProvider(provider: AnthropicProvider(model: claudeModel, isClaudeCode: false))
    let keyBody = try! keyAuth.requestBody(messages: screenshotHistory(original), systemPrompt: "harness", tools: [],
                                           maxTokens: 1024, route: .keyAuth)!
    recordWire("p2.keyAuth.anthropic", keyBody)
    var toolResultIsText = false
    if let json = try? JSONSerialization.jsonObject(with: keyBody) as? [String: Any],
       let messages = json["messages"] as? [[String: Any]] {
        for m in messages {
            for c in (m["content"] as? [[String: Any]]) ?? [] where c["type"] as? String == "tool_result" {
                toolResultIsText = c["content"] is String
            }
        }
    }
    R("p2.keyAuth.toolResultIsText", toolResultIsText)

    // [T-anthropic-keyauth-toolimages] 20 rounds of cancelled (staged, never
    // sent) + key-auth + OAuth requests through the real RequestBodyPatcher.
    // OAuth tokens sort FIRST, cancelled ones LAST: the old eviction dropped
    // the smallest tokens past 16 entries, i.e. the OAuth request's own entry.
    let small = encode(makeCGImage(w: 320, h: 240, pattern: .photo), type: .jpeg, quality: 0.8)
    func toolResultBody(_ id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "model": "claude-sonnet-5", "max_tokens": 64,
            "messages": [["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "shot"]]]],
        ])
    }
    var oauthDelivered = 0, keyDelivered = 0, tokenLeaked = false
    for i in 0..<20 {
        RequestBodyPatcher.setToolResultImages(["toolu_cancel_\(i)": (small, "image/jpeg")], requestToken: String(format: "ffff-cancelled-%02d", i))
        for (prefix, keyAuth) in [("8888-key", true), ("0000-oauth", false)] {
            let token = String(format: "\(prefix)-%02d", i)
            RequestBodyPatcher.setRequestToken(token)
            RequestBodyPatcher.setToolResultImages(["toolu_\(token)": (small, "image/jpeg")], requestToken: token)
            let request = NSMutableURLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpBody = toolResultBody("toolu_\(token)")
            if keyAuth { RequestBodyPatcher.applyKeyAuthBodyPatches(to: request) } else { RequestBodyPatcher.applyOAuthBodyPatches(to: request) }
            let n = wireImages(request.httpBody ?? Data()).count
            if keyAuth { keyDelivered += n } else { oauthDelivered += n }
            if request.value(forHTTPHeaderField: RequestBodyPatcher.requestTokenHeader) != nil { tokenLeaked = true }
        }
    }
    R("interleave.oauthDelivered", oauthDelivered); R("interleave.keyDelivered", keyDelivered); R("interleave.tokenLeaked", tokenLeaked)

    // P-i6: gate(gate(x)) vs gate(x).
    R("p6.resizeNilWithin", AIChatViewModel.resizedImageData(live, maxLongEdge: 2000) == nil)
    let once = AIChatViewModel.jpegEncode(original, maxLongEdge: 2000, quality: 0.85)!
    let twice = AIChatViewModel.jpegEncode(once, maxLongEdge: 2000, quality: 0.85)!
    R("p6.encode1.bytes", once.count); R("p6.encode2.bytes", twice.count)
    R("p6.encodeIdempotent", once == twice)
    R("p6.anthropicNilWithin", AnthropicAgentProvider.harnessDownscale(live) == nil)
    R("p6.anthropicStable", AnthropicAgentProvider.harnessDownscale(original) == live)

    let json = try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
    try! json.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
#endif
