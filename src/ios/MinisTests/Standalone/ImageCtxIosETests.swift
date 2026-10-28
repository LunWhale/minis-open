#!/usr/bin/env swift
// [T-ctx-builder] iOS-E: the whole "build the model request" chain, unit-tested
// with data built in code - no app host, no real data.
//
// The chain has one entry now: `RequestContextBuilder.build(_:)`
// (AIChatViewModel+RequestBudget.swift). Its `Input` names everything it reads
// (history, compaction marker, warm-up trim cache, the three history helpers,
// session id, spillover root, image budget); its `Output` is the message list
// the provider is handed plus the stage-1 history and the budget plan. The
// view model builds the Input from its own state (`requestContextInput()`).
// Its stages are the statics production already runs: effectiveAgentHistory()
// = effectiveHistoryFilters(effectiveHistory(...)), applyRequestImageBudget =
// budgetedRequestImages + log; the equivalence build proves builder == the
// AgentLoop path value for value.
// `AIChatViewModel.storedParts(for:...store:)` is buildRawMessage's
// AgentMessage -> stored parts step with the store injected.
//
// This driver compiles, VERBATIM from the current sources, the builder and
// both of its stages, the attachment intake, the tool-image seams, the
// persistence conversion and its reload, and the five provider serializers
// (iOS-D's extraction list), then runs the C01-C32 table (scenario
// numbering shared with Android) on the live
// turn and after a restart. It also builds the behaviour-unchanged evidence:
// ImageCtxIosE/Equiv.swift compiled against the three files at the pinned base
// commit and against the current files, at -Onone and -O, sha256 per message.
//
// Storage: every case runs in its own temp directory (ChatStore(baseURL:)); the
// driver refuses to build if a lifted declaration reaches for the real
// Library / Caches / app group.
//
// Built for Mac Catalyst. Cached by content hash.
// Run: swift src/ios/MinisTests/Standalone/ImageCtxIosETests.swift
//   IOSE_ONLY=C04,C26      run a subset
//   IOSE_UPDATE_GOLDEN=1   rewrite ImageCtxIosE/golden/ImageCtxIosE-Cxx.json
//   IOSE_JSON=<path>       copy of the full results
import Foundation
import CryptoKit

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0
var gaps = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iosRoot = here.deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
let helperDir = here.appendingPathComponent("ImageCtxIosE")
/// The three production files as they were before the extraction.
let equivBase = "f7d35419b786e49c4753ce939ec8800b70e763b7"
var drift: [String] = []

func source(_ rel: String) -> String {
    guard let s = try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8) else {
        drift.append("cannot read \(rel)"); return ""
    }
    return s
}
func sh(_ args: [String], cwd: URL? = nil, env: [String: String]? = nil) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    if let env { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
func gitShow(_ rel: String) -> String {
    let (s, o) = sh(["git", "show", "\(equivBase):src/ios/\(rel)"], cwd: repoRoot)
    if s != 0 { drift.append("git show \(equivBase):\(rel) failed") }
    return o
}
func blockText(_ src: String, _ name: String, _ label: String) -> String {
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else {
        drift.append("\(label): BEGIN/END \(name)"); return ""
    }
    return String(src[b.lowerBound..<e.upperBound])
}
/// One line for a `let` / `var`, through the matching brace otherwise.
func declText(_ src: String, _ signature: String, _ label: String) -> String {
    guard let hit = src.range(of: signature) else { drift.append("\(label): \(signature.trimmingCharacters(in: .whitespaces))"); return "" }
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
                if i + 2 < chars.count, chars[i + 1] == "(", chars[i + 2] == ")" { return String(chars[0...(i + 2)]) }
                return String(chars[0...i])
            }
        }
        else if c == "\n" && !opened && parens == 0 && i > 0 {
            let line = String(chars[0..<i])
            // A signature continued on the next line (`-> T {`, `where`, `{`) is not a body-less declaration.
            let next = String(chars[(i + 1)...].prefix(80)).trimmingCharacters(in: .whitespaces)
            let continues = ["->", "{", "where ", "throws", "async"].contains { next.hasPrefix($0) }
            if !continues && !line.trimmingCharacters(in: .whitespaces).hasSuffix("=") && !line.hasSuffix(",") { return line }
        }
        i += 1
    }
    drift.append("\(label): unterminated \(signature)")
    return ""
}
func decl(_ rel: String, _ sig: String) -> String { declText(source(rel), sig, rel) }
func block(_ rel: String, _ name: String) -> String { blockText(source(rel), name, rel) }

let C = "Agent/Chat/"
let VM = C + "AIChatViewModel.swift", MISC = C + "AIChatViewModel+Misc.swift", RB = C + "AIChatViewModel+RequestBudget.swift"
let PERS = C + "AIChatViewModel+Persistence.swift", LOOP = C + "AIChatViewModel+AgentLoop.swift", SEND = C + "AIChatViewModel+Send.swift"
let ATT = C + "AIChatViewModel+Attachments.swift", OFF = C + "AIChatViewModel+Offloading.swift", COMP = C + "AIChatViewModel+Compaction.swift"
let TOOLS = C + "AIChatViewModel+ConcurrentTools.swift", BG = C + "AIChatViewModel+BackgroundTask.swift", AUDIO = C + "AIChatViewModel+AutoPlayAudio.swift"
let CONV = C + "RawMessage+Conversion.swift", MODELS = C + "ChatModels.swift", MEDIA = C + "ChatStore+Media.swift", HELP = C + "ChatStore+Helpers.swift"
let MSGS = C + "ChatStore+Messages.swift", DEL = C + "SessionDeletionSupport.swift", CPC = C + "ContentPart+ProviderConversion.swift"
let BUM = "Agent/BrowserUse/BrowserUseManager.swift"
let OAI = "Providers/OpenAI/OpenAIAgentProvider.swift", GEM = "Providers/Gemini/GeminiAgentProvider.swift", GEMP = "Providers/Gemini/GeminiProvider.swift"
let AG = "Providers/Antigravity/AntigravityAgentProvider.swift", ANT = "Providers/Anthropic/AnthropicAgentProvider.swift"
let ANTP = "Providers/Anthropic/AnthropicProvider.swift", OAUTH = "Providers/Anthropic/OAuthHTTPClient.swift", VGR = "Providers/VisionGroupResolver.swift"

// MARK: - Wiring: production goes through what the tests run

print("Wiring (production calls the code under test)")
let loopSrc = source(LOOP), persSrc = source(PERS), rbSrc = source(RB), sendSrc = source(SEND), attSrc = source(ATT)
let builderText = decl(RB, "enum RequestContextBuilder {")
check("AgentLoop: the three fallback sends are applyRequestImageBudget(effectiveAgentHistory()) (= builder stage 1 + 2)",
      loopSrc.components(separatedBy: "messages: applyRequestImageBudget(effectiveAgentHistory()),").count - 1 == 3)
check("AgentLoop: the main round builds effectiveAgentHistory() then applyRequestImageBudget (the builder's two stages)",
      loopSrc.contains("var contextHistory = effectiveAgentHistory()") && loopSrc.contains("contextHistory = applyRequestImageBudget(contextHistory)"))
check("effectiveAgentHistory() = effectiveHistoryFilters(effectiveAgentHistoryUncounted()), the two statics builder stage 1 runs",
      persSrc.contains("let sliced = effectiveAgentHistoryUncounted()\n        return Self.effectiveHistoryFilters(sliced, agentHistoryCount: agentHistory.count, markerId: cachedLatestMarker?.id)")
      && builderText.contains("let sliced = AIChatViewModel.effectiveHistory(input.history, marker: input.compaction,")
      && builderText.contains("return AIChatViewModel.effectiveHistoryFilters(sliced, agentHistoryCount: input.history.count,"))
check("effectiveAgentHistoryUncounted() is the static effectiveHistory with the view model's state",
      persSrc.contains("let result = Self.effectiveHistory(agentHistory, marker: cachedLatestMarker,"))
check("applyRequestImageBudget and builder stage 2 both call budgetedRequestImages (stage 2 passes the Input's root and budget)",
      rbSrc.contains("guard let budgeted = Self.budgetedRequestImages(messages, sessionId: sessionId) else { return messages }")
      && builderText.contains("guard let budgeted = AIChatViewModel.budgetedRequestImages(messages, sessionId: input.sessionId,"))
check("buildRawMessage converts parts through storedParts",
      persSrc.contains("let parts = await Self.storedParts(for: msg, sessionId: sessionId, snapshots: snapshots,"))
check("loadSession rebuilds history with toAgentMessage + dbMessageId (mirrored by Session.restart)",
      persSrc.contains("var agentMsg = raw.toAgentMessage(mediaResolver: resolver)") && persSrc.contains("agentMsg.dbMessageId = raw.id"))
check("ChatStore stores parts as JSONEncoder ContentPart JSON (Session.append round-trips the same)",
      source(MSGS).contains("let data = try JSONEncoder().encode(message.parts)") && source(MSGS).contains("JSONDecoder().decode([ContentPart].self, from: data)"))
let xmlLine = #"xml += "  <file path=\"\(meta.path)\" url=\"\(meta.minisURL)\" size=\"\(meta.size)\" modified=\"\(nowStr)\" />\n""#
check("send() mirror: its loop lines still exist verbatim in Send.swift",
      sendSrc.contains(xmlLine) && sendSrc.contains("let inline = await MainActor.run { Self.inlineAttachmentImage(data, ext: ext, route: .send) }")
      && sendSrc.contains("userParts.append(.text(\"[attached image: \\(linuxPath)]\"))")
      && sendSrc.contains("let wouldOverflowMessage = Self.attachmentImageOverflowsMessage(cumulativeImageBytes: cumulativeImageBytes, compressedB64: compressedB64)")
      && sendSrc.contains("let safeName = Self.uniqueFileName(for: attachment.fileName, in: uploadsDir)"))
check("the queue route (processAttachments) writes the same <file> line", attSrc.contains(xmlLine))
check("edit mirror: editMessage restores attachments from uploads; send() cuts at the bubble",
      source(C + "AIChatViewModel+EditMessage.swift").contains("let fileURL = uploadsDir.appendingPathComponent(fileName)")
      && sendSrc.contains("cutAtUserBubble(editIdx, keepBubble: false, site: \"edit\")"))
check("tool mirror: browser_use / read_image snapshots store the model image (Session.browserScreenshot / readImage)",
      source(TOOLS).components(separatedBy: "let imageData = toolImageData ?? (try? Data(contentsOf: URL(fileURLWithPath: imagePath))),").count - 1 == 2)
check("takeover mirror: the takeover message is stored (Session.takeover)",
      source(BG).contains("let msg = Self.takeoverScreenshotMessage(data, sessionId: sessionId, timestamp: timestamp)")
      && source(BG).contains("if let pid = await persistAgentMessage(msg), idx < agentHistory.count {"))
check("fork mirror: duplicateSession copies parts verbatim", source("Agent/Session/SessionForkManager.swift").contains("parts: msg.parts,"))
check("RequestContextBuilder reads no globals (ChatStore.shared, UserDefaults, Date(), UUID(), UIApplication)",
      !["ChatStore.shared", "UserDefaults", "Date()", "UUID()", "UIApplication"].contains { builderText.contains($0) })

// MARK: - Program assembly

let stubs = """
// GENERATED by ImageCtxIosETests.swift from the current sources. Do not edit.
import Foundation
import UIKit
import ImageIO
import CryptoKit
import SwiftAnthropic

enum HarnessEnv { nonisolated(unsafe) static var root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minis-ctx-iosE-unset") }
enum HarnessLog { nonisolated(unsafe) static var lines: [String] = [] }
struct AppLogger {
    init(category: String) {}
    func info(_ m: @autoclosure () -> String) { HarnessLog.lines.append("I " + m()) }
    func warning(_ m: @autoclosure () -> String) { HarnessLog.lines.append("W " + m()) }
    func error(_ m: @autoclosure () -> String) { HarnessLog.lines.append("E " + m()) }
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
struct HarnessEntry { let model: LLMModel; let providerInstanceId: String }
struct HarnessInstance { let providerType: ProviderType }
final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for id: String) -> HarnessEntry? { nil }
    func instance(for id: String) -> HarnessInstance? { nil }
}

"""

func chatStoreShim() -> String {
    """
    /// Stand-in for the ChatStore actor over a temp root: init(baseURL:) lays
    /// out `<base>/minis` like the real one; saveMedia / mediaFileURL /
    /// resolver / fileExtension are the real code; sync bookkeeping is a no-op.
    actor ChatStore {
        nonisolated(unsafe) static var shared = ChatStore(baseURL: HarnessEnv.root.appendingPathComponent("MinisChat", isDirectory: true))
        let minisBaseURL: URL
        init(baseURL: URL) {
            minisBaseURL = baseURL.appendingPathComponent("minis", isDirectory: true)
            try? FileManager.default.createDirectory(at: minisBaseURL, withIntermediateDirectories: true)
        }
        func markDirty(recordType: String, recordId: String) {}
    \(decl(MEDIA, "    func saveMedia("))
    \(decl(MEDIA, "    func mediaFileURL(for ref: MediaRef) -> URL {"))
    \(decl(MEDIA, "    func mediaFileURLResolver()"))
    \(decl(HELP, "static func fileExtension(for mimeType: String)"))
    }

    """
}

/// The view model stand-in: its state as plain vars, the statics and instance
/// methods the chain and the intake use, lifted verbatim. `chain` carries the
/// request-building code (old or new).
func viewModel(chain: String, persistImageParts: String, budget: String) -> String {
    var s = """
    final class AIChatViewModel {
        var sessionId: String?
        var agentHistory: [AgentMessage] = []
        var cachedLatestMarker: CompactMarker?
        var warmUpDropByMarker: [String: Int] = [:]
        var contextFixedTokens = 0
        var attachments: [InputAttachment] = []
        var pastedTexts: [PastedText] = []
        var attachmentCacheDir: URL { HarnessEnv.root.appendingPathComponent("Caches/attachments", isDirectory: true) }
        func ensureSession() async {}
        func resolveCurrentEntry() -> HarnessEntry? { nil }
        func resolvedContextWindow(for model: LLMModel) -> (window: Int, isUserCap: Bool) { (0, false) }
        func contextCalibrationRatio(for modelId: String? = nil) -> Double { 1 }
        nonisolated static var minisPersistentBase: URL { HarnessEnv.root.appendingPathComponent("MinisChat/minis", isDirectory: true) }

    """
    let lifts: [(String, String)] = [
        (VM, "static let kImageContextKeepCount"), (VM, "static let kPerImageMaxBytes"), (VM, "static let kRequestImageMaxBytes"),
        (VM, "static let kMessageImageMaxBytes"), (VM, "static func estimatedBase64Length("), (VM, "static func rawBytesForBase64Budget("),
        (MISC, "nonisolated static let minisBrowserLinuxDir"), (MISC, "    static func resizedImageData("),
        (MISC, "    static func compressedImageDataUnderBudget("), (MISC, "nonisolated static func minisAttachmentsPersistentDir(for sid: String)"),
        (MISC, "static func minisUploadsDir(for sid: String)"),
        (RB, "nonisolated static func minisBrowserPersistentDir(for sid: String)"), (RB, "    static func jpegEncode("),
        (AUDIO, "    static func detectImageMime(_ data: Data) -> String {"),
        (OFF, "    private static func imagePixelSize("), (OFF, "    private static let byteFormatter"), (OFF, "    static func imagePlaceholderText("),
        (ATT, "    static func uniqueFileName("), (ATT, "    static func detectImageType(from data: Data)"),
        (ATT, "    static func detectImageType(atFileURL url: URL)"), (ATT, "    func addFileAttachment(from sourceURL: URL"),
        (ATT, "    func addDataAttachment(data: Data, fileName: String)"), (ATT, "    func processAttachments("), (ATT, "    func consumePastedDraft("),
        (PERS, "    static func droppingLegacyBridgeRows("), (PERS, "    static func pairingKey("), (PERS, "    static func dropOrphanedToolParts("),
        (COMP, "    static let compactKeepRecentUserTurns"), (COMP, "    static func compactSummaryWrappedText("),
        (COMP, "    static func summaryAsAgentMessage("), (COMP, "    struct WalkBackResult {"), (COMP, "    func walkBackUserTurnsBounded("),
        (COMP, "    func indexOfNthFromLastUserText(_ n: Int) -> Int? {"), (COMP, "    func indexOfNthFromLastUserText(_ n: Int, upToIncluding"),
        (COMP, "    func trimWarmUpToFit("),
    ]
    for (rel, sig) in lifts { s += decl(rel, sig) + "\n" }
    s += chain + "\n}\n\n"
    s += persistImageParts + "\n\nextension AIChatViewModel {\n" + budget + "\n}\n"
    return s
}

func newChain() -> String {
    [decl(PERS, "    func effectiveAgentHistory() -> [AgentMessage] {"), decl(PERS, "    func effectiveAgentHistoryUncounted() -> [AgentMessage] {"),
     decl(PERS, "    func effectiveHistoryHelpers() -> EffectiveHistoryHelpers {"), decl(PERS, "    struct EffectiveHistoryHelpers {"),
     decl(PERS, "    static func effectiveHistory(_ history: [AgentMessage]"), decl(PERS, "    static func effectiveHistoryFilters("), decl(PERS, "    static func storedParts(for msg: AgentMessage"),
     decl(PERS, "    func buildRawMessage("), decl(RB, "    func requestContextInput() -> RequestContextBuilder.Input {"),
     decl(RB, "    func buildRequestContext() -> RequestContextBuilder.Output {")].joined(separator: "\n")
}
func oldChain() -> String {
    let p = gitShow(PERS)
    return [declText(p, "    func effectiveAgentHistory() -> [AgentMessage] {", "base Persistence"),
            declText(p, "    func effectiveAgentHistoryUncounted() -> [AgentMessage] {", "base Persistence"),
            declText(p, "    func buildRawMessage(", "base Persistence")].joined(separator: "\n")
}

/// Everything else the scenarios call: intake / tool seams / reload / providers.
func sharedReal() -> String {
    var s = ""
    s += block(SEND, "InlineAttachmentImage") + "\n"
    s += "extension AIChatViewModel {\n"
    for sig in ["    static func browserUseInferenceImage(", "    static func writeBrowserScreenshotCopy(", "    struct ReadImageInference {",
                "    static func readImageInference(", "    static func saveBrowserSnapshotMedia(", "    static func saveReadImageSnapshotMedia("] {
        s += decl(TOOLS, sig) + "\n"
    }
    s += "}\n"
    s += block(BG, "TakeoverScreenshotMessage") + "\n"
    s += "extension RawMessage {\n" + decl(CONV, "    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {") + "\n}\n"
    s += block(CONV, "RebuildImageParts") + "\n"
    s += "final class BrowserUseManager {\n" + decl(BUM, "    nonisolated static func screenshotJPEGData(") + "\n"
        + decl(BUM, "    nonisolated static func screenshotImageLine(") + "\n}\n"
    for (rel, sig) in [(ATT, "struct PastedText: Identifiable {"), (ATT, "enum PastePlaceholder {"), (MODELS, "struct AttachmentMeta: Identifiable, Equatable {"),
                       (MODELS, "struct InputAttachment: Identifiable {"), (MODELS, "struct TokenUsage {"), (CPC, "func parseJSONToDict(_ json: String) -> [String: Any] {"),
                       (DEL, "enum SessionStorageCleanup {")] {
        s += decl(rel, sig) + "\n"
    }
    return s
}
func baseReal() -> String {
    // What the equivalence builds need besides the chain.
    var s = "extension RawMessage {\n" + decl(CONV, "    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {") + "\n}\n"
    s += block(CONV, "RebuildImageParts") + "\n"
    for (rel, sig) in [(ATT, "struct PastedText: Identifiable {"), (ATT, "enum PastePlaceholder {"), (MODELS, "struct AttachmentMeta: Identifiable, Equatable {"),
                       (MODELS, "struct InputAttachment: Identifiable {"), (MODELS, "struct TokenUsage {"), (CPC, "func parseJSONToDict(_ json: String) -> [String: Any] {")] {
        s += decl(rel, sig) + "\n"
    }
    s += block(SEND, "InlineAttachmentImage") + "\n"
    return s
}

/// iOS-D's provider extraction list (OpenAI Responses / Chat, Gemini,
/// Antigravity, Anthropic requestBody + body patch chains).
func providers() -> String {
    var out = ""
    func emit(_ s: String) { out += s + "\n" }
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
    for a in ["static let encryptedReasoningMarker", "static let responsesAPIProviderKind", "var reasoningUpstreamIdentity: String {",
              "func convertMessagesResponsesAPI(_ messages: [AgentMessage]) -> [[String: Any]] {", "static func sanitizeResponsesToolPairing(",
              "func flattenChatCompletionsMessages(", "private func convertSingleMessageChatCompletions(", "private static func globallyDedupeToolCallIds(",
              "private static func sanitizeToolCallAdjacency(", "private static func splitResponsesAPIIds(", "private static func capChatId(",
              "private static func capResponsesId(", "private static let maxChatCompletionsIdLength", "private static let maxResponsesAPIIdLength"] {
        emit(decl(OAI, a))
    }
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
    emit("""
    final class AnthropicProvider {
        let model: LLMModel
        let isClaudeCode: Bool
        var isOfficialAnthropicEndpoint: Bool { true }
        init(model: LLMModel, isClaudeCode: Bool) { self.model = model; self.isClaudeCode = isClaudeCode }
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
              "    private static func injectMissingToolResults(", "    private static func stripOrphanToolResults(",
              "    private static func mergeConsecutiveSameRole(", "    private static func reorderUserContent(",
              "    private static func reorderAssistantContent(", "    private static func concatContent(", "    private func convertToInput(",
              "    private func convertTools(_ tools: [AgentToolDefinition]) -> [MessageParameter.Tool] {", "    static func anthropicProperty(",
              "    static func anthropicItems(", "    private func messagesWithCacheBreakpoints(", "    private func tryInjectCacheControl(",
              "    private static let downscaleCache", "    private static func downscaleForAnthropic(", "    private static func computeDownscaleForAnthropic("] {
        emit(decl(ANT, a))
    }
    emit("}")
    emit(block(ANT, "AnthropicToolInputConverter"))
    emit(block(ANT, "AnthropicRequestBody"))
    emit(decl(OAUTH, "enum RequestBodyPatcher {"))
    emit(block(OAUTH, "AnthropicBodyPatchChains"))
    return out
}

let newPersistParts = block(PERS, "PersistImageParts")
let newBudget = block(RB, "RequestImageBudget")
// [T-image-gate] The request image stage runs every image through the gate first.
let newGate = block(RB, "ModelImageGate")
let scenarioReal = stubs + chatStoreShim()
    + viewModel(chain: newChain(), persistImageParts: newPersistParts, budget: newBudget)
    + "\n" + decl(RB, "enum RequestContextBuilder {") + "\n" + sharedReal() + "\n" + providers() + "\n" + newGate
let basePers = gitShow(PERS), baseRB = gitShow(RB)
let equivOld = stubs + chatStoreShim()
    + viewModel(chain: oldChain(), persistImageParts: blockText(basePers, "PersistImageParts", "base Persistence"),
                budget: blockText(baseRB, "RequestImageBudget", "base RequestBudget"))
    + "\n" + baseReal()
let equivNew = stubs + chatStoreShim()
    + viewModel(chain: newChain(), persistImageParts: newPersistParts, budget: newBudget)
    + "\n" + decl(RB, "enum RequestContextBuilder {") + "\n" + baseReal() + "\n" + newGate

if !drift.isEmpty {
    print("  ❌ DRIFT — the production code these tests compile has moved:")
    drift.forEach { print("     • \($0)") }
    exit(1)
}
// A7: nothing lifted may reach the real app containers.
for (name, text) in [("scenario", scenarioReal), ("equivOld", equivOld), ("equivNew", equivNew)] {
    let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    let hits = ["libraryDirectory", "cachesDirectory", "applicationSupportDirectory", "group.com.openminis", "containerURL(forSecurityApplicationGroupIdentifier"]
        .filter { code.contains($0) }
    check("A7 storage isolation: \(name) program touches no real container path \(hits.isEmpty ? "" : "(found \(hits))")", hits.isEmpty)
}

// MARK: - Build (cached by content hash)

func helper(_ dir: String, _ f: String) -> String {
    guard let t = try? String(contentsOf: here.appendingPathComponent(dir).appendingPathComponent(f), encoding: .utf8) else {
        print("  ❌ \(dir)/\(f) missing"); exit(1)
    }
    return t
}
let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalystBase = ["-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk, "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                    "-L", "\(sdk)/System/iOSSupport/usr/lib", "-D", "IMAGE_REAL_IOS_D"]
let anthropicSrc = repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic")
let saFiles = ((FileManager.default.enumerator(atPath: anthropicSrc.path)?.allObjects as? [String]) ?? [])
    .filter { ($0.hasPrefix("Public/Parameters") || $0.hasPrefix("Public/ResponseModels") || $0 == "Public/Model.swift") && $0.hasSuffix(".swift") }
    .sorted().map { anthropicSrc.appendingPathComponent($0).path }
guard !saFiles.isEmpty else { print("  ❌ SwiftAnthropic checkout missing at \(anthropicSrc.path) - build the app once"); exit(1) }
let wholeFiles = ["Providers/AgentProvider.swift", "Agent/Chat/ChatStoreModels.swift", "Providers/LLMTypes.swift", "Providers/ProviderTypes.swift",
                  "Providers/ThinkingLevelCatalog.swift", "Providers/Gemini/GeminiWireFormat.swift", "Agent/Chat/ContextPolicy.swift",
                  "Shared/BPETokenizer.swift"]
let started = Date()

/// Builds (or reuses) one program; returns the binary.
func build(_ name: String, _ files: [String: String], flags: [String]) -> URL? {
    var generated = files
    for f in wholeFiles { generated["whole_" + (f as NSString).lastPathComponent] = source(f) }
    let catalyst = catalystBase + flags
    var key = generated.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + catalyst.joined()
    for f in saFiles { key += (try? String(contentsOfFile: f, encoding: .utf8)) ?? f }
    let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("minis-ctx-iosE-\(name)-\(digest)")
    let bin = work.appendingPathComponent("run")
    if FileManager.default.fileExists(atPath: bin.path) { return bin }
    print("▶️  building \(name) (Mac Catalyst \(flags.filter { $0.hasPrefix("-O") }.joined())) in \(work.path)")
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    for (n, text) in generated { try! text.write(to: work.appendingPathComponent(n), atomically: true, encoding: .utf8) }
    let sa = work.appendingPathComponent("sa")
    try? FileManager.default.createDirectory(at: sa, withIntermediateDirectories: true)
    let (s1, o1) = sh(["xcrun", "swiftc"] + catalyst + ["-parse-as-library", "-emit-library", "-static", "-emit-module",
                      "-module-name", "SwiftAnthropic", "-emit-module-path", sa.appendingPathComponent("SwiftAnthropic.swiftmodule").path,
                      "-suppress-warnings", "-o", sa.appendingPathComponent("libSwiftAnthropic.a").path] + saFiles)
    guard s1 == 0 else { print(String(o1.suffix(3000))); print("  ❌ SwiftAnthropic subset build failed"); return nil }
    let (s2, o2) = sh(["xcrun", "swiftc"] + catalyst + ["-I", sa.path, "-L", sa.path, "-lSwiftAnthropic", "-suppress-warnings",
                      "-o", bin.path] + generated.keys.sorted().map { work.appendingPathComponent($0).path })
    guard s2 == 0 else {
        print(o2.components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(40).joined(separator: "\n"))
        print("  ❌ \(name) build failed (sources in \(work.path))"); return nil
    }
    return bin
}

let fixturesD = helper("ImageRealIosD", "Fixtures.swift")
var scenarioFiles = ["real.swift": scenarioReal, "Fixtures.swift": fixturesD,
                     "main.swift": "import Foundation\nawait runAll(workRoot: URL(fileURLWithPath: CommandLine.arguments[1]), resultsURL: URL(fileURLWithPath: CommandLine.arguments[2]))\n"]
for f in ["Kit.swift", "RequestView.swift", "Session.swift", "Scenarios.swift", "Runner.swift"] { scenarioFiles[f] = helper("ImageCtxIosE", f) }
let equivMain = "import Foundation\nawait runEquiv(root: URL(fileURLWithPath: CommandLine.arguments[1]))\n"
let equivHelper = helper("ImageCtxIosE", "Equiv.swift")

guard let scenarioBin = build("scenarios", scenarioFiles, flags: ["-D", "IMAGE_CTX_IOS_E", "-Onone"]) else { exit(1) }
var equivBins: [String: URL] = [:]
for (variant, real, extra) in [("old", equivOld, [String]()), ("new", equivNew, ["-D", "NEW_BUILDER"])] {
    for opt in ["-Onone", "-O"] {
        guard let b = build("equiv-\(variant)\(opt)", ["real.swift": real, "Fixtures.swift": fixturesD, "Equiv.swift": equivHelper, "main.swift": equivMain],
                            flags: ["-D", "IMAGE_CTX_IOS_E_EQUIV", opt] + extra) else { exit(1) }
        equivBins["\(variant)\(opt)"] = b
    }
}
let buildSeconds = Date().timeIntervalSince(started)

// MARK: - Behaviour unchanged (old vs new, -Onone and -O)

print("\nBehaviour-unchanged evidence (base \(equivBase.prefix(9)) vs working tree)")
var equivOut: [String: [String: String]] = [:]
for (key, bin) in equivBins.sorted(by: { $0.key < $1.key }) {
    var lines: [String: String] = [:]
    for run in 0..<3 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minis-ctx-iosE-equiv-\(key)-\(run)")
        let (st, o) = sh([bin.path, root.path])
        guard st == 0 else { print(o); check("equiv \(key) ran", false); continue }
        for l in o.split(separator: "\n") where l.hasPrefix("E ") {
            let f = l.split(separator: " ").map(String.init)
            let k = f[1...3].joined(separator: " ")
            if run == 0 { lines[k] = f.count > 4 ? f[4] : "" }
            else if lines[k] != (f.count > 4 ? f[4] : "") { lines[k] = "UNSTABLE" }
        }
    }
    equivOut[key] = lines
}
var equivRows: [[String: Any]] = []
for opt in ["-Onone", "-O"] {
    let old = equivOut["old\(opt)"] ?? [:], new = equivOut["new\(opt)"] ?? [:]
    let shared = old.keys.filter { new[$0] != nil }.sorted()
    // Behaviour changed on purpose since the base, value by value. Each must
    // DIFFER from the base (so a revert is caught); everything else must match.
    //   [T-404-summary-after-tool-results] the #404 carrier now holds the
    //   summary after its tool result instead of before it.
    let deliberate: Set<String> = ["compactToolCarrier404 request 4"]
    let same = shared.filter { old[$0] == new[$0] }
    let unstable = shared.filter { old[$0] == "UNSTABLE" || new[$0] == "UNSTABLE" }
    let unchanged = shared.filter { !deliberate.contains($0) }
    check("\(opt): \(unchanged.filter { old[$0] == new[$0] }.count)/\(unchanged.count) old/new hashes identical (request, stored parts, counts)",
          unchanged.allSatisfy { old[$0] == new[$0] } && !unchanged.isEmpty)
    check("\(opt): deliberate changes differ from the base: \(deliberate.sorted())",
          deliberate.allSatisfy { old[$0] != nil && old[$0] != new[$0] })
    _ = same
    if !unstable.isEmpty { print("     note: \(unstable.count) value(s) vary between runs of the SAME build: \(unstable.prefix(4))") }
    for k in new.keys.sorted() where k.contains("builder") || k.contains("ViaBuildRequestContext") {
        let base = k.replacingOccurrences(of: " builder ", with: " request ").replacingOccurrences(of: " requestViaBuildRequestContext ", with: " request ")
        if new[base] != new[k] { check("\(opt): \(k) == request", false) }
    }
    let builderKeys = new.keys.filter { $0.contains(" builder ") }
    check("\(opt): RequestContextBuilder.build with explicit inputs == the production path (\(builderKeys.count) values)",
          builderKeys.allSatisfy { new[$0] == new[$0.replacingOccurrences(of: " builder ", with: " request ")] } && !builderKeys.isEmpty)
    for k in shared { equivRows.append(["opt": opt, "key": k, "old": old[k]!, "new": new[k]!]) }
}
let crossOpt = (equivOut["new-Onone"] ?? [:]).filter { equivOut["new-O"]?[$0.key] != $0.value }.map(\.key).sorted()
print("  ℹ️ -Onone vs -O differ on \(crossOpt.count) value(s)\(crossOpt.isEmpty ? "" : ": \(crossOpt.prefix(6))")")

// MARK: - Scenarios

print("\nScenarios C01-C32 (live turn and after restart; five providers)")
let workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("minis-ctx-iosE-run")
let resultsURL = workRoot.appendingPathComponent("results.json")
try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
let runStart = Date()
let (runStatus, runOut) = sh([scenarioBin.path, workRoot.path, resultsURL.path])
let runSeconds = Date().timeIntervalSince(runStart)
guard runStatus == 0, let raw = try? Data(contentsOf: resultsURL),
      let results = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    print(runOut); print("  ❌ scenario run failed"); exit(1)
}
if let p = ProcessInfo.processInfo.environment["IOSE_JSON"] { try? raw.write(to: URL(fileURLWithPath: p)) }
let scen = results["scenarios"] as? [[String: Any]] ?? []
var currentCount = 0, desiredCount = 0
for s in scen {
    print("\(s["id"]!) \(s["title"]!)")
    for c in s["checks"] as? [[String: Any]] ?? [] {
        let ok = c["ok"] as? Bool ?? false, label = c["label"] as? String ?? ""
        if c["desired"] as? Bool == true {
            desiredCount += 1
            if ok { print("  ✅ (desired) \(label)") } else { print("  ⚠️ KNOWN GAP \(label)"); gaps += 1 }
        } else { currentCount += 1; check(label, ok) }
    }
    if let m = s["metrics"] as? [String: Any], !m.isEmpty {
        for k in m.keys.sorted() {
            let v = (try? JSONSerialization.data(withJSONObject: m[k]!, options: [.sortedKeys, .fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            print("     · \(k) = \(v.prefix(220))")
        }
    }
    for n in s["notes"] as? [String] ?? [] { print("     ℹ️ \(n)") }
}
check("all 32 scenarios ran", ProcessInfo.processInfo.environment["IOSE_ONLY"] != nil || scen.count == 32)

// MARK: - Golden snapshots (structure, not bytes)

func shape(_ v: Any) -> Any {
    if let d = v as? [String: Any] {
        var o: [String: Any] = [:]
        for (k, x) in d where !["bytes", "base64Len", "sha256", "sha8", "tail"].contains(k) { o[k] = shape(x) }
        return o
    }
    if let a = v as? [Any] { return a.map(shape) }
    return v
}
let goldenDir = helperDir.appendingPathComponent("golden")
let update = ProcessInfo.processInfo.environment["IOSE_UPDATE_GOLDEN"] == "1"
try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
var goldenDiffs: [String] = []
for (id, v) in (results["views"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
    let url = goldenDir.appendingPathComponent("ImageCtxIosE-\(id).json")
    let data = try! JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .prettyPrinted])
    if update || !FileManager.default.fileExists(atPath: url.path) { try! data.write(to: url); continue }
    let old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) ?? [:]
    if !(NSDictionary(dictionary: ["v": shape(old)]).isEqual(to: ["v": shape(v)])) { goldenDiffs.append(id) }
}
check("golden RequestView snapshots match (role / order / kinds / text / image size+MIME)\(goldenDiffs.isEmpty ? "" : ": \(goldenDiffs)")", goldenDiffs.isEmpty)

// MARK: - Summary table

print("\nSummary: scenario x provider x phase  (images / max edge / MIME / total bytes / compliant / adjacency)")
print("  id   provider     phase    img  maxEdge  mime                       bytes      ok  adj  lost dup flags")
for r in results["summary"] as? [[String: Any]] ?? [] {
    func f(_ k: String, _ w: Int) -> String { "\(r[k] ?? "-")".padding(toLength: w, withPad: " ", startingAt: 0) }
    let mimes = (r["mimes"] as? [String] ?? []).joined(separator: ",")
    print("  \(f("scenario", 4)) \(f("provider", 12)) \(f("phase", 8)) \(f("images", 4)) \(f("maxEdge", 8)) \(mimes.padding(toLength: 26, withPad: " ", startingAt: 0)) \(f("totalBytes", 10)) \((r["compliant"] as? Bool ?? false) ? "Y " : "N ")  \((r["adjacency"] as? Bool ?? false) ? "Y  " : "N  ")  \(f("silentlyLost", 4)) \(f("duplicates", 3)) \((r["flags"] as? [String] ?? []).joined(separator: ","))")
}
print("  header-only fixtures: \(results["headerOnlyFormats"] ?? [])")

print(String(format: "\nBuild %.1fs, scenarios %.1fs, total %.1fs; current checks %d, desired %d, known gaps %d",
             buildSeconds, runSeconds, Date().timeIntervalSince(started), currentCount, desiredCount, gaps))
print(failures == 0 ? "ALL PASSED (characterization)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
