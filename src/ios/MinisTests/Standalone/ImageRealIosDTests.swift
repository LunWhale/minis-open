#!/usr/bin/env swift
// [T-image-real-seams] iOS-D: every provider's request body, from the REAL
// serializers.
//
// Anthropic now has a callable "history -> final request body" entry:
// `AnthropicAgentProvider.requestBody(messages:systemPrompt:tools:maxTokens:route:)`
// (BEGIN/END AnthropicRequestBody, AnthropicAgentProvider.swift). It shares
// conversion, cache breakpoints, `messageParameter` and `stageToolResultImages`
// with streamAgentMessageClamped, and the body patch chains
// `RequestBodyPatcher.applyOAuthBodyPatches` / `applyKeyAuthBodyPatches`
// (BEGIN/END AnthropicBodyPatchChains, OAuthHTTPClient.swift) with the
// URLProtocols. Both blocks are compiled VERBATIM here; the rest of
// AnthropicAgentProvider's conversion (convertMessages and the helpers it
// calls, convertTools, messagesWithCacheBreakpoints, the downscale) and the
// whole RequestBodyPatcher enum are lifted by declaration into the same file.
// The previous round re-implemented the Anthropic body here (encode + stamp +
// one patch); that copy is gone.
//
// The other providers are not changed by iOS-D: OpenAI Responses / Chat
// Completions, Gemini and Antigravity serializers are lifted by declaration
// (their entries are internal) and called directly.
//
// Re-verifies the wire half of P-i2 (images in all five request bodies after a
// reload vs the live turn), P-i6 (the gates are not idempotent), and records
// what the Anthropic API-key / manual-token route sends.
// ImageRealIosD/WireImages.swift is the reusable request-body image parser.
//
// Built for Mac Catalyst. Cached by content hash.
// Run: swift src/ios/MinisTests/Standalone/ImageRealIosDTests.swift
// IOSD_JSON=<path> exports every measured value.
import Foundation
import CryptoKit

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
var gaps = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func desired(_ label: String, _ cond: Bool) {
    if cond { print("  ✅ (desired) \(label)") } else { print("  ⚠️ KNOWN GAP \(label)"); gaps += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iosRoot = here.deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
var drift: [String] = []
func source(_ rel: String) -> String {
    guard let s = try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8) else {
        drift.append("cannot read \(rel)"); return ""
    }
    return s
}
func sh(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
func block(_ rel: String, _ name: String) -> String {
    let src = source(rel)
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else {
        drift.append("\(rel): BEGIN/END \(name)"); return ""
    }
    return String(src[b.lowerBound..<e.upperBound])
}
/// One line for a `let` / `var`, through the matching brace otherwise.
func decl(_ rel: String, _ signature: String) -> String {
    let src = source(rel)
    guard let hit = src.range(of: signature) else { drift.append("\(rel): \(signature.trimmingCharacters(in: .whitespaces))"); return "" }
    let lineStart = src[..<hit.lowerBound].lastIndex(of: "\n").map { src.index(after: $0) } ?? src.startIndex
    let chars = Array(src[lineStart...])
    var depth = 0, i = 0, opened = false, parens = 0
    var inString = false, inLineComment = false, inBlockComment = false, multiline = false
    while i < chars.count {
        let c = chars[i], n = i + 1 < chars.count ? chars[i + 1] : " "
        if inLineComment { if c == "\n" { inLineComment = false } }
        else if inBlockComment { if c == "*" && n == "/" { inBlockComment = false; i += 1 } }
        else if multiline {
            if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { multiline = false; i += 2 }
        }
        else if inString { if c == "\\" { i += 1 } else if c == "\"" { inString = false } }
        else if c == "/" && n == "/" { inLineComment = true; i += 1 }
        else if c == "/" && n == "*" { inBlockComment = true; i += 1 }
        else if c == "\"", i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { multiline = true; i += 2 }
        else if c == "\"" { inString = true }
        else if c == "(" { parens += 1 }
        else if c == ")" { parens -= 1 }
        else if c == "{" { depth += 1; opened = true }
        else if c == "}" {
            depth -= 1
            if opened && depth == 0 {
                // a closure initializer `= { ... }()` keeps its call
                if i + 2 < chars.count, chars[i + 1] == "(", chars[i + 2] == ")" { return String(chars[0...(i + 2)]) }
                return String(chars[0...i])
            }
        }
        else if c == "\n" && !opened && parens == 0 && i > 0 {
            // a declaration without a body (let / var / one-line) ends at the newline
            let line = String(chars[0..<i])
            if !line.trimmingCharacters(in: .whitespaces).hasSuffix("=") && !line.hasSuffix(",") { return line }
        }
        i += 1
    }
    drift.append("\(rel): unterminated \(signature)")
    return ""
}

let OAI = "Providers/OpenAI/OpenAIAgentProvider.swift"
let GEM = "Providers/Gemini/GeminiAgentProvider.swift"
let GEMP = "Providers/Gemini/GeminiProvider.swift"
let AG = "Providers/Antigravity/AntigravityAgentProvider.swift"
let ANT = "Providers/Anthropic/AnthropicAgentProvider.swift"
let ANTP = "Providers/Anthropic/AnthropicProvider.swift"
let OAUTH = "Providers/Anthropic/OAuthHTTPClient.swift"
let VGR = "Providers/VisionGroupResolver.swift"
let CPC = "Agent/Chat/ContentPart+ProviderConversion.swift"
let MISC = "Agent/Chat/AIChatViewModel+Misc.swift"
let RB = "Agent/Chat/AIChatViewModel+RequestBudget.swift"

// MARK: - Wiring (the production paths call what the tests call)

print("Real entry points and wiring")
let antSrc = source(ANT), oauthSrc = source(OAUTH)
check("streamAgentMessageClamped stages tool images through stageToolResultImages",
      antSrc.contains("let requestToken = stageToolResultImages()"))
check("streamAgentMessageClamped builds its parameter through messageParameter",
      antSrc.contains("let parameter = messageParameter(messages: cachedMessages, tools: anthropicTools,"))
check("OAuthURLProtocol applies applyOAuthBodyPatches",
      oauthSrc.contains("RequestBodyPatcher.applyOAuthBodyPatches(to: mutable)"))
check("EagerStreaming and DualAuth URLProtocols apply applyKeyAuthBodyPatches",
      oauthSrc.components(separatedBy: "RequestBodyPatcher.applyKeyAuthBodyPatches(to: mutable)").count - 1 == 2)
check("no protocol runs its own patch list any more",
      oauthSrc.components(separatedBy: "RequestBodyPatcher.patchToolResultsWithImages(into: mutable)").count - 1 == 2)
let sdkEndpoint = (try? String(contentsOf: repoRoot.appendingPathComponent(
    "build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Private/Network/Endpoint.swift"), encoding: .utf8)) ?? ""
let sdkService = (try? String(contentsOf: repoRoot.appendingPathComponent(
    "build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Service/DefaultAnthropicService.swift"), encoding: .utf8)) ?? ""
check("requestBody encodes like the SDK: Endpoint uses a snake_case JSONEncoder, streamMessage sets stream = true",
      sdkEndpoint.contains("encoder.keyEncodingStrategy = .convertToSnakeCase") && sdkService.contains("localParameter.stream = true")
      && antSrc.contains("encoder.keyEncodingStrategy = .convertToSnakeCase") && antSrc.contains("parameter.stream = true"))

// MARK: - Assemble the program

var out = """
// GENERATED by ImageRealIosDTests.swift from the current sources. Do not edit.
import Foundation
import UIKit
import ImageIO
import CryptoKit
import SwiftAnthropic

struct AppLogger {
    init(category: String) {}
    func info(_ m: @autoclosure () -> String) {}
    func warning(_ m: @autoclosure () -> String) {}
    func error(_ m: @autoclosure () -> String) {}
    func debug(_ m: @autoclosure () -> String) {}
    func verbose(_ m: @autoclosure () -> String) {}
    func notice(_ m: @autoclosure () -> String) {}
}
let logger = AppLogger(category: "harness")
let thinkingLogger = AppLogger(category: "harness")
func AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String { String(localized: key) }
enum ModelsDevAPI { static func enrichModel(_ m: LLMModel) -> LLMModel { m } }
enum XAIModelsAPI { static var allModels: [LLMModel] { [] } }
enum KimiModelsAPI { static var allModels: [LLMModel] { [] } }

"""
func emit(_ s: String) { out += s + "\n" }

emit("final class AIChatViewModel {")
emit(decl(MISC, "    static func resizedImageData("))
emit(decl(RB, "    static func jpegEncode("))
emit("}")

emit(decl(CPC, "func parseJSONToDict(_ json: String) -> [String: Any] {"))
emit("enum VisionGroupResolver {")
emit("    nonisolated static var isConfiguredCached: Bool { false }")
emit(decl(VGR, "nonisolated static func visionImagePathNote(linuxPath: String?) -> String? {"))
emit(decl(VGR, "nonisolated static func attachmentPlaceholder(linuxPath: String?) -> String {"))
emit("}")

emit("""
final class OpenAIAgentProvider {
    struct ProviderShim { var isMistral = false; var isCerebras = false; var customBaseURL: String? = nil }
    let model: LLMModel
    let provider = ProviderShim()
    init(model: LLMModel) { self.model = model }
""")
for a in ["static let encryptedReasoningMarker", "static let responsesAPIProviderKind",
          "var reasoningUpstreamIdentity: String {",
          "func convertMessagesResponsesAPI(_ messages: [AgentMessage]) -> [[String: Any]] {",
          "static func sanitizeResponsesToolPairing(",
          "func flattenChatCompletionsMessages(",
          "private func convertSingleMessageChatCompletions(",
          "private static func globallyDedupeToolCallIds(",
          "private static func sanitizeToolCallAdjacency(",
          "private static func splitResponsesAPIIds(",
          "private static func capChatId(",
          "private static func capResponsesId(",
          "private static let maxChatCompletionsIdLength", "private static let maxResponsesAPIIdLength"] { emit(decl(OAI, a)) }
emit("}")

emit("""
final class GeminiAgentProvider {
    let model: LLMModel
    var toolCallMetadataMap: [String: ToolCallMetadata] = [:]
    init(model: LLMModel) { self.model = model }
""")
emit(decl(GEM, "    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {"))
emit(decl(GEM, "    static func narratedToolCall("))
emit(decl(GEM, "    static func narratedToolResult("))
emit(decl(GEM, "    static let narratedResultLimit"))
emit("}")
emit(decl(GEMP, "enum GeminiConversation"))
emit("""
final class AntigravityAgentProvider {
    let model: LLMModel
    var toolCallMetadataMap: [String: ToolCallMetadata] = [:]
    init(model: LLMModel) { self.model = model }
""")
emit(decl(AG, "    private var isClaude: Bool"))
emit(decl(AG, "    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {"))
emit("}")

// Anthropic: provider shim with the two methods the parameter uses (real code).
emit("""
final class AnthropicProvider {
    let model: LLMModel
    let isClaudeCode: Bool
    var isOfficialAnthropicEndpoint: Bool { true }
    init(model: LLMModel, isClaudeCode: Bool) { self.model = model; self.isClaudeCode = isClaudeCode }
    /// Stand-in: the real text is generated (ProviderCustomizationGenerated)
    /// and has nothing to do with images.
    static let claudeCodeSystemPrompt = "<harness: Claude Code system prompt>"
""")
for a in ["    func resolveSystemPrompt(_ userPrompt: String?) -> MessageParameter.System? {",
          "    func effectiveTemperature(_ temperature: Double?) -> Double? {", "    static func modelRejectsTemperature(",
          "    static func parseClaudeVersion(", "    static func modelUsesAdaptiveThinking(",
          "    enum OffThinking: Equatable {", "    static func offThinking(for modelId: String) -> OffThinking {"] { emit(decl(ANTP, a)) }
emit("}")
emit("""
final class AnthropicAgentProvider {
    let provider: AnthropicProvider
    var model: LLMModel { provider.model }
    init(provider: AnthropicProvider) { self.provider = provider }
""")
emit(decl(ANT, "    private var pendingToolResultImages"))
for a in ["    private func convertMessages(_ messages: [AgentMessage]) -> [MessageParameter.Message] {",
          "    private static func injectMissingToolResults(",
          "    private static func stripOrphanToolResults(",
          "    private static func mergeConsecutiveSameRole(",
          "    private static func reorderUserContent(",
          "    private static func reorderAssistantContent(",
          "    private static func concatContent(",
          "    private func convertToInput(",
          "    private func convertTools(_ tools: [AgentToolDefinition]) -> [MessageParameter.Tool] {",
          "    static func anthropicProperty(",
          "    static func anthropicItems(",
          "    private func messagesWithCacheBreakpoints(",
          "    private func tryInjectCacheControl(",
          "    private static let downscaleCache",
          "    private static func downscaleForAnthropic(",
          "    private static func computeDownscaleForAnthropic("] { emit(decl(ANT, a)) }
emit("""
    /// Harness-only: the same downscale convertMessages applies, for P-i6.
    static func harnessDownscale(_ d: Data) -> Data? { downscaleForAnthropic(d) }
}
""")
emit(block(ANT, "AnthropicToolInputConverter"))
emit(block(ANT, "AnthropicRequestBody"))
emit(decl(OAUTH, "enum RequestBodyPatcher {"))
emit(block(OAUTH, "AnthropicBodyPatchChains"))

if !drift.isEmpty {
    print("  ❌ DRIFT — the production code these tests compile has moved:")
    drift.forEach { print("     • \($0)") }
    exit(1)
}

let helperDir = here.appendingPathComponent("ImageRealIosD")
var generated: [String: String] = ["Extracted.swift": out, "main.swift": "runScenarios()\n"]
for f in ["Fixtures.swift", "WireImages.swift", "Scenarios.swift"] {
    guard let t = try? String(contentsOf: helperDir.appendingPathComponent(f), encoding: .utf8) else {
        print("  ❌ ImageRealIosD/\(f) missing"); exit(1)
    }
    generated[f] = t
}
let wholeFiles = ["Providers/AgentProvider.swift", "Agent/Chat/ChatStoreModels.swift", "Providers/LLMTypes.swift",
                  "Providers/ProviderTypes.swift", "Providers/ThinkingLevelCatalog.swift",
                  "Providers/Gemini/GeminiWireFormat.swift"]
for f in wholeFiles { generated["whole_" + (f as NSString).lastPathComponent] = source(f) }

// MARK: - Build (cached by content hash) and run

let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalyst = ["-D", "IMAGE_REAL_IOS_D", "-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                "-L", "\(sdk)/System/iOSSupport/usr/lib"]
let anthropicSrc = repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic")
let saFiles = ((FileManager.default.enumerator(atPath: anthropicSrc.path)?.allObjects as? [String]) ?? [])
    .filter { ($0.hasPrefix("Public/Parameters") || $0.hasPrefix("Public/ResponseModels") || $0 == "Public/Model.swift") && $0.hasSuffix(".swift") }
    .sorted().map { anthropicSrc.appendingPathComponent($0).path }
guard !saFiles.isEmpty else { print("  ❌ SwiftAnthropic checkout missing at \(anthropicSrc.path) - build the app once"); exit(1) }
var key = generated.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + catalyst.joined()
for f in saFiles { key += (try? String(contentsOfFile: f, encoding: .utf8)) ?? f }
let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("minis-image-real-iosD-\(digest)")
let bin = work.appendingPathComponent("run")
let started = Date()
if !FileManager.default.fileExists(atPath: bin.path) {
    print("▶️  building harness (Mac Catalyst) in \(work.path)")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    for (name, text) in generated { try! text.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let sa = work.appendingPathComponent("sa")
    try? FileManager.default.createDirectory(at: sa, withIntermediateDirectories: true)
    let (s1, o1) = sh(["xcrun", "swiftc"] + catalyst + ["-parse-as-library", "-emit-library", "-static", "-emit-module",
                      "-module-name", "SwiftAnthropic", "-emit-module-path", sa.appendingPathComponent("SwiftAnthropic.swiftmodule").path,
                      "-suppress-warnings", "-o", sa.appendingPathComponent("libSwiftAnthropic.a").path] + saFiles)
    guard s1 == 0 else { print(String(o1.suffix(3000))); print("  ❌ SwiftAnthropic subset build failed"); exit(1) }
    let (s2, o2) = sh(["xcrun", "swiftc"] + catalyst + ["-I", sa.path, "-L", sa.path, "-lSwiftAnthropic", "-suppress-warnings",
                      "-o", bin.path] + generated.keys.sorted().map { work.appendingPathComponent($0).path })
    guard s2 == 0 else {
        print(o2.components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(40).joined(separator: "\n"))
        print("  ❌ harness build failed (sources in \(work.path))"); exit(1)
    }
}
let jsonURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IOSD_JSON"] ?? work.appendingPathComponent("results.json").path)
let (runStatus, runOut) = sh([bin.path, jsonURL.path])
guard runStatus == 0, let raw = try? Data(contentsOf: jsonURL),
      let m = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    print(runOut); print("  ❌ harness run failed"); exit(1)
}
func int(_ k: String) -> Int { m[k] as? Int ?? -1 }
func str(_ k: String) -> String { m[k] as? String ?? "?" }
func bool(_ k: String) -> Bool { m[k] as? Bool ?? false }
func dims(_ k: String) -> String { "\(int("\(k).w"))x\(int("\(k).h"))" }

// MARK: - P-i2 wire half

let providers = ["responses", "chat", "gemini", "antigravity", "anthropic"]
for phase in ["live", "rebuilt"] {
    print("P-i2 request bodies, \(phase == "live" ? "live turn (253x2000 tool image)" : "after reload (2760x21891 original)")")
    for p in providers {
        let k = "p2.\(phase).\(p)"
        let expect = (phase == "rebuilt" && p != "anthropic") ? "2760x21891" : "253x2000"
        check("\(p): one image, \(expect), image/jpeg", int("\(k).count") == 1 && dims(k) == expect && str("\(k).mime") == "image/jpeg")
    }
}
check("after reload Responses/Chat/Gemini/Antigravity send the original's bytes, base64 \(int("p2.rebuilt.responses.b64")) chars",
      ["responses", "chat", "gemini", "antigravity"].allSatisfy { str("p2.rebuilt.\($0).sha") == str("p2.original.sha") })
check("after reload Anthropic still sends exactly the live-turn bytes (prompt cache stable)",
      str("p2.rebuilt.anthropic.sha") == str("p2.live.anthropic.sha"))
check("the Anthropic image rides in the tool_result block (image, then text)",
      str("p2.rebuilt.anthropic.path").hasPrefix("messages[") && str("p2.rebuilt.anthropic.path").contains(".content[0].content[0]"))
desired("after reload no provider is sent more than 2000 px", providers.allSatisfy { max(int("p2.rebuilt.\($0).w"), int("p2.rebuilt.\($0).h")) <= 2000 })

print("Anthropic route: API key / manual token (EagerStreaming / DualAuth URLProtocol)")
check("the OAuth route carries the tool image", int("p2.rebuilt.anthropic.count") == 1)
// [T-anthropic-keyauth-toolimages] was KNOWN GAP: the key-auth chain now stamps the request token.
check("a tool-result image reaches Anthropic in API-key mode too",
      int("p2.keyAuth.anthropic.count") == 1 && !bool("p2.keyAuth.toolResultIsText"))
check("…the same bytes the OAuth route sends", str("p2.keyAuth.anthropic.sha") == str("p2.rebuilt.anthropic.sha"))
check("20 interleaved cancelled / key-auth / OAuth requests: every OAuth request keeps its image (\(int("interleave.oauthDelivered"))/20)",
      int("interleave.oauthDelivered") == 20)
check("…every key-auth request carries its image (\(int("interleave.keyDelivered"))/20)", int("interleave.keyDelivered") == 20)
check("…the correlation token never leaves the device", !bool("interleave.tokenLeaked"))

// MARK: - P-i6

print("P-i6 the image gates are not idempotent")
check("resizedImageData leaves an image <= 2000 alone (returns nil)", bool("p6.resizeNilWithin"))
check("jpegEncode twice gives different bytes from once (\(int("p6.encode1.bytes")) B vs \(int("p6.encode2.bytes")) B)",
      !bool("p6.encodeIdempotent"))
check("Anthropic's downscale leaves a <= 2000 image alone (nil -> original bytes are sent)", bool("p6.anthropicNilWithin"))
check("Anthropic's downscale of its own output is a no-op, so the live and rebuilt bodies agree", bool("p6.anthropicStable"))
desired("jpegEncode(jpegEncode(x)) == jpegEncode(x)", bool("p6.encodeIdempotent"))

print("\nRequest-body images (real serializers)")
for phase in ["live", "rebuilt"] {
    for p in providers {
        let k = "p2.\(phase).\(p)"
        print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(dims(k).padding(toLength: 11, withPad: " ", startingAt: 0)) \(str("\(k).mime").padding(toLength: 11, withPad: " ", startingAt: 0)) b64=\(int("\(k).b64")) \(str("\(k).sha"))")
    }
}

print(String(format: "\nSuite time %.1fs; known gaps: %d", Date().timeIntervalSince(started), gaps))
print(failures == 0 ? "ALL PASSED (characterization)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
