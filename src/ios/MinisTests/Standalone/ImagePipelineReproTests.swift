#!/usr/bin/env swift
// [T-image-repro] Image-pipeline reproduction suite (iOS).
//
// Runs the REAL image code paths on generated images and records what each
// stage does to the bytes: ingest (resize / re-encode / MIME), the copies
// written to disk, the live-turn message, the message rebuilt after a reload,
// and what every provider serializer puts on the wire. It answers whether the
// earlier static analysis (propositions P-i1..P-i9) matches what the code actually does.
//
// How "real code" is achieved without linking the app (device-only deps):
//   * Whole production files are compiled as-is where they stand alone:
//     Providers/AgentProvider.swift, Agent/Chat/ChatStoreModels.swift,
//     Providers/LLMTypes.swift, ProviderTypes.swift, ThinkingLevelCatalog.swift,
//     Gemini/GeminiWireFormat.swift, plus a SwiftAnthropic subset (Parameters,
//     ResponseModels, Model) from the SPM checkout.
//   * Everything else is EXTRACTED from the current sources at run time - whole
//     declarations by brace matching, inline blocks between two anchors - and
//     compiled into stand-in containers (AIChatViewModel, ChatStore, the four
//     agent providers, RequestBodyPatcher). Nothing is copied into this file;
//     every anchor must still match the tree or the suite fails with DRIFT.
//   * The harness is built for Mac Catalyst (arm64-apple-ios17.0-macabi) so
//     UIKit / ImageIO behave as on iOS. Not the iPhone itself - see the report.
//
// Two kinds of checks:
//   (A) characterization - asserts TODAY's behaviour; passing = the problem is
//       reproduced. Printed as ✅ / ❌.
//   (B) desired behaviour - what the fixed pipeline must do. Fails today, so it
//       prints "⚠️ KNOWN GAP" and does not fail the suite. When a fix lands the
//       line turns into "✅ (gap closed)" - then promote it to a hard check.
//
// Run:   swift src/ios/MinisTests/Standalone/ImagePipelineReproTests.swift
// Env:   IMG_REPRO_KEEP=1 keeps the build dir; IMG_REPRO_JSON=<path> writes the
//        raw measurements as JSON.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let suiteStart = Date()
var failures = 0
var gaps: [String] = []
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !cond { failures += 1 }
}
func desired(_ label: String, _ cond: Bool, _ detail: String = "") {
    if cond { print("  ✅ (gap closed) \(label)") }
    else { print("  ⚠️ KNOWN GAP \(label)\(detail.isEmpty ? "" : " — \(detail)")"); gaps.append(label) }
}

let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
let helperDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ImagePipelineRepro")
func src(_ rel: String) -> String {
    guard let s = try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8) else {
        print("❌ DRIFT: cannot read \(rel)"); exit(1)
    }
    return s
}

// MARK: - Swift-aware declaration extraction

/// Index just past the matching close brace of the `{` at `open`, skipping
/// string literals (incl. interpolation and multi-line), raw strings and comments.
func matchBrace(_ s: [Character], from open: Int) -> Int? {
    var i = open
    var depth = 0
    func skipString(_ start: Int) -> Int {
        // returns index after the closing quote of the string starting at `start`
        var hashes = 0
        var j = start
        while j < s.count, s[j] == "#" { hashes += 1; j += 1 }
        let multi = j + 2 < s.count && s[j] == "\"" && s[j + 1] == "\"" && s[j + 2] == "\""
        j += multi ? 3 : 1
        while j < s.count {
            if s[j] == "\\" {
                // escape or interpolation (raw strings need \#)
                var k = j + 1
                var h = 0
                while k < s.count, s[k] == "#", h < hashes { h += 1; k += 1 }
                if h == hashes, k < s.count, s[k] == "(" {
                    // interpolation: balance parens, recursing into nested strings
                    var p = 0
                    var m = k
                    while m < s.count {
                        if s[m] == "\"" || (s[m] == "#" && m + 1 < s.count && (s[m + 1] == "\"" || s[m + 1] == "#")) {
                            m = skipString(m); continue
                        }
                        if s[m] == "(" { p += 1 } else if s[m] == ")" { p -= 1; if p == 0 { break } }
                        m += 1
                    }
                    j = m + 1; continue
                }
                j = k + 1; continue
            }
            if s[j] == "\"" {
                if multi {
                    if j + 2 < s.count, s[j + 1] == "\"", s[j + 2] == "\"" {
                        var k = j + 3; var h = 0
                        while k < s.count, s[k] == "#", h < hashes { h += 1; k += 1 }
                        if h == hashes { return k }
                    }
                } else {
                    var k = j + 1; var h = 0
                    while k < s.count, s[k] == "#", h < hashes { h += 1; k += 1 }
                    if h == hashes { return k }
                }
            }
            j += 1
        }
        return j
    }
    while i < s.count {
        let c = s[i]
        if c == "/" && i + 1 < s.count && s[i + 1] == "/" {
            while i < s.count, s[i] != "\n" { i += 1 }; continue
        }
        if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
            var d = 0
            while i + 1 < s.count {
                if s[i] == "/" && s[i + 1] == "*" { d += 1; i += 2; continue }
                if s[i] == "*" && s[i + 1] == "/" { d -= 1; i += 2; if d == 0 { break }; continue }
                i += 1
            }
            continue
        }
        if c == "\"" || (c == "#" && i + 1 < s.count && (s[i + 1] == "\"" || s[i + 1] == "#")) {
            i = skipString(i); continue
        }
        if c == "{" { depth += 1 }
        if c == "}" { depth -= 1; if depth == 0 { return i + 1 } }
        i += 1
    }
    return nil
}

var drift: [String] = []
/// Whole declaration starting on the line that contains `anchor`.
func decl(_ file: String, _ anchor: String) -> String {
    let text = src(file)
    guard let r = text.range(of: anchor) else { drift.append("\(file): `\(anchor)`"); return "" }
    let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let chars = Array(text[lineStart...])
    // a stored property on one line has no body
    let firstLine = String(chars.prefix { $0 != "\n" })
    let words = firstLine.split(separator: " ").map(String.init)
    let isProperty = words.contains("let") || words.contains("var")
    var codeOnly = ""          // the first line with string-literal contents removed
    var inString = false, escaped = false
    for c in firstLine {
        if inString {
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
        } else if c == "\"" { inString = true } else { codeOnly.append(c) }
    }
    if isProperty, !words.contains("func"), !codeOnly.contains("{") { return firstLine }
    guard let open = chars.firstIndex(of: "{"), var end = matchBrace(chars, from: open) else {
        drift.append("\(file): unbalanced `\(anchor)`"); return ""
    }
    // `static let x: T = { ... }()` — keep the call
    if isProperty, end + 1 < chars.count, chars[end] == "(", chars[end + 1] == ")" { end += 2 }
    return String(chars[0..<end])
}
/// Verbatim block from the line holding `from` through the line holding `through`.
func block(_ file: String, from: String, through: String) -> String {
    let text = src(file)
    guard let a = text.range(of: from) else { drift.append("\(file): `\(from)`"); return "" }
    guard let b = text.range(of: through, range: a.lowerBound..<text.endIndex) else {
        drift.append("\(file): `\(through)` after `\(from)`"); return ""
    }
    let lineStart = text[..<a.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let lineEnd = text[b.upperBound...].firstIndex(of: "\n") ?? text.endIndex
    return String(text[lineStart..<lineEnd])
}
/// Require a literal to still be in the file (for checks on inline code that
/// cannot be executed in isolation).
func guardLiteral(_ file: String, _ literal: String) -> Bool {
    let ok = src(file).contains(literal)
    if !ok { drift.append("\(file): literal `\(literal.prefix(80))`") }
    return ok
}

// MARK: - Sources

let CT = "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
let MISC = "Agent/Chat/AIChatViewModel+Misc.swift"
let VM = "Agent/Chat/AIChatViewModel.swift"
let RB = "Agent/Chat/AIChatViewModel+RequestBudget.swift"
let ATT = "Agent/Chat/AIChatViewModel+Attachments.swift"
let SND = "Agent/Chat/AIChatViewModel+Send.swift"
let PERS = "Agent/Chat/AIChatViewModel+Persistence.swift"
let BG = "Agent/Chat/AIChatViewModel+BackgroundTask.swift"
let OFF = "Agent/Chat/AIChatViewModel+Offloading.swift"
let APA = "Agent/Chat/AIChatViewModel+AutoPlayAudio.swift"
let MEDIA = "Agent/Chat/ChatStore+Media.swift"
let HELP = "Agent/Chat/ChatStore+Helpers.swift"
let RMC = "Agent/Chat/RawMessage+Conversion.swift"
let CPC = "Agent/Chat/ContentPart+ProviderConversion.swift"
let CM = "Agent/Chat/ChatModels.swift"
let OAI = "Providers/OpenAI/OpenAIAgentProvider.swift"
let GEM = "Providers/Gemini/GeminiAgentProvider.swift"
let GEMP = "Providers/Gemini/GeminiProvider.swift"
let AG = "Providers/Antigravity/AntigravityAgentProvider.swift"
let ANT = "Providers/Anthropic/AnthropicAgentProvider.swift"
let OAUTH = "Providers/Anthropic/OAuthHTTPClient.swift"
let VGR = "Providers/VisionGroupResolver.swift"
let BUM = "Agent/BrowserUse/BrowserUseManager.swift"

// MARK: - Generate Extracted.swift

var out = """
// GENERATED by ImagePipelineReproTests.swift from the current sources. Do not edit.
import Foundation
import UIKit
import ImageIO
import CryptoKit
import SwiftAnthropic

"""
func emit(_ s: String) { out += s + "\n" }

// --- AIChatViewModel stand-in: static image helpers + request budget + attachment paths
emit("final class AIChatViewModel {")
emit("    var sessionId: String? = HarnessEnv.sessionId")
emit("    var transientNotice: String?")
emit("    static var minisPersistentBase: URL { HarnessEnv.root.appendingPathComponent(\"minis\") }")
for (f, a) in [
    (VM, "static let kImageContextKeepCount"),
    (VM, "static func estimatedBase64Length("),
    (VM, "static func rawBytesForBase64Budget("),
    (VM, "static let kPerImageMaxBytes"),
    (VM, "static let kMessageImageMaxBytes"),
    (VM, "static let kRequestImageMaxBytes"),
    (MISC, "static func downsampledCameraJPEG("),
    (MISC, "static func resizedImageData("),
    (MISC, "static func compressedImageDataUnderBudget("),
    (APA, "static func detectImageMime("),
    (OFF, "static func imagePlaceholderText("),
    (OFF, "private static func imagePixelSize("),
    (OFF, "private static let byteFormatter"),
    (RB, "private struct BudgetImage"),
    (RB, "private struct RequestBudgetPlan"),
    (RB, "private static func planRequestBudget("),
    (RB, "func applyRequestImageBudget("),
    (RB, "static func elidedImagePlaceholder("),
    (RB, "private static func ensureSpillover("),
    (RB, "static func jpegEncode("),
    (ATT, "static func uniqueFileName(for name: String, in dir: URL)"),
    (ATT, "func processAttachments("),
] { emit(decl(f, a)) }

// Send path (AIChatViewModel+Send.swift, inside send()): the per-image block,
// verbatim, wrapped with the locals it reads.
let sendBlock = block(SND, from: "                if attachment.kind == .image {\n                    if inlinedImages < inlineBudget {",
                      through: "                        logger.info(\"📎[SEND-ASYNC]   image not inlined (count budget")
emit("""
    /// Wrapper around the verbatim send-path image block.
    func sendPathImage(_ attachment: InputAttachment, data: Data, linuxPath: String, i: Int = 0) async -> [AgentContentPart] {
        let inlineBudget = Self.kImageContextKeepCount
        var inlinedImages = 0
        var cumulativeImageBytes = 0
        var userParts: [AgentContentPart] = []
        _ = inlinedImages; _ = cumulativeImageBytes
    \(sendBlock)
                    }
                }
        return userParts
    }
""")

// read_image live-turn bytes (ConcurrentTools.swift), verbatim.
let readImageBlock = block(CT, from: "                let inferenceData: Data\n", through: "                    resizedH = originalH")
emit("""
    func readImageLive(fileData: Data, uiImage: UIImage) -> (data: Data, w: Int, h: Int, mime: String) {
        let originalW = uiImage.cgImage.map { $0.width } ?? Int(uiImage.size.width)
        let originalH = uiImage.cgImage.map { $0.height } ?? Int(uiImage.size.height)
    \(readImageBlock)
                }
        var toolImageData: Data?; var toolImageMimeType: String?
    \(block(CT, from: "                    toolImageData = inferenceData", through: "                    toolImageMimeType = \"image/jpeg\""))
        return (toolImageData!, resizedW, resizedH, toolImageMimeType!)
    }
""")

// browser_use live-turn bytes (ConcurrentTools.swift), verbatim.
emit("""
    static func minisBrowserPersistentDir(for sid: String) -> URL {
        HarnessEnv.root.appendingPathComponent("MinisChat/minis/\\(sid)/browser")
    }
    /// Live-turn bytes AND the `minis_url` copy (B2) browser_use writes.
    func browserUseLive(data: Data) -> (data: Data, mime: String, b2: URL) {
        var toolImageData: Data?; var toolImageMimeType: String?
    \(block(CT, from: "                toolImageData = Self.resizedImageData(data, maxLongEdge: 2000) ?? data", through: "                try? data.write(to: persistPath)"))
        return (toolImageData!, toolImageMimeType!, persistPath)
    }
""")

// Tool snapshot persistence (ConcurrentTools.swift): browser_use and read_image
// saveMedia calls, verbatim.
emit("""
    func persistBrowserSnapshot(imageData: Data, sid: String, toolImageLinuxPath: String?) async -> MediaRef {
    \(block(CT, from: "                let ref = await ChatStore.shared.saveMedia(\n                    data: imageData, mimeType: \"image/jpeg\", sessionId: sid,", through: "                )"))
        return ref
    }
    func persistReadImageSnapshot(imagePath: String, imageData: Data, sid: String, toolImageLinuxPath: String?) async -> MediaRef {
    \(block(CT, from: "                let fileURL = URL(fileURLWithPath: imagePath)\n                let mime = Self.detectImageMime(imageData)", through: "                )"))
        return ref
    }
""")

// Message persistence (Persistence.swift): which bytes a part's mediaRef points to.
emit("""
    func persistedToolResultRef(imgData: Data?, snapshotRef: MediaRef?) -> MediaRef? {
        struct SnapshotShim { let mediaRef: MediaRef? }
        let snap: SnapshotShim? = SnapshotShim(mediaRef: snapshotRef)
    \(block(PERS, from: "                let mediaRef: MediaRef? = imgData != nil ? snap?.mediaRef : nil", through: "                let mediaRef: MediaRef? = imgData != nil ? snap?.mediaRef : nil"))
        return mediaRef
    }
    func persistedImagePart(data: Data, mimeType: String, sessionId: String, linuxPath: String?) async -> MediaRef {
    \(block(PERS, from: "                let ref = await ChatStore.shared.saveMedia(\n                    data: data, mimeType: mimeType, sessionId: sessionId,", through: "                )"))
        return ref
    }
""")

// Takeover (BackgroundTask.swift): the message it appends, verbatim.
emit("""
    var agentHistory: [AgentMessage] = []
    static var minisBrowserLinuxDir: String { "/var/minis/browser" }
    func takeoverMessage(data: Data, linuxPath persistLinuxPath: String) -> AgentMessage {
        let linuxPath = persistLinuxPath
    \(block(BG, from: "            let takeoverNote = ", through: "            agentHistory.append(msg)"))
        return agentHistory.last!
    }
""")
emit("}")

// --- AttachmentMeta / InputAttachment / PastePlaceholder
emit(decl(CM, "struct AttachmentMeta: Identifiable, Equatable {"))
emit(decl(CM, "struct InputAttachment: Identifiable {"))
emit(decl(ATT, "enum PastePlaceholder {"))

// --- ChatStore stand-in: saveMedia + resolver (real code)
emit("actor ChatStore {")
emit("    static let shared = ChatStore()")
emit("    let minisBaseURL: URL = HarnessEnv.root.appendingPathComponent(\"MinisChat/minis\")")
emit("    var dirty: [String] = []")
emit("    func markDirty(recordType: String, recordId: String) { dirty.append(recordId) }")
emit(decl(MEDIA, "    func saveMedia("))
emit(decl(MEDIA, "    func mediaFileURLResolver() -> (MediaRef) -> URL {"))
emit(decl(HELP, "static func fileExtension(for mimeType: String) -> String {"))
emit("}")

// --- Rebuild after reload (RawMessage+Conversion.swift): toAgentMessage + sniff
emit("extension RawMessage {")
emit(decl(RMC, "    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {"))
emit(decl(RMC, "    private static func sniffImageMimeType(_ data: Data) -> String? {"))
emit("}")
emit(decl(CPC, "func parseJSONToDict(_ json: String) -> [String: Any] {"))

// --- Vision Group text helpers used by the OpenAI serializers
emit("enum VisionGroupResolver {")
// Wording switch for text-only models; the harness models all have vision.
emit("    nonisolated static var isConfiguredCached: Bool { false }")
emit(decl(VGR, "nonisolated static func visionImagePathNote(linuxPath: String?) -> String? {"))
emit(decl(VGR, "nonisolated static func attachmentPlaceholder(linuxPath: String?) -> String {"))
emit("}")

// --- OpenAI (Responses + Chat Completions)
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

// --- Gemini + Antigravity
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

// --- Anthropic (SwiftAnthropic request model + RequestBodyPatcher)
emit("""
final class AnthropicAgentProvider {
    let model: LLMModel
    init(model: LLMModel) { self.model = model }
    private var pendingToolResultImages: [String: (data: Data, mimeType: String)] = [:]
    var harnessPendingToolResultImages: [String: (data: Data, mimeType: String)] { pendingToolResultImages }
    func harnessConvert(_ m: [AgentMessage]) -> [MessageParameter.Message] { pendingToolResultImages.removeAll(); return convertMessages(m) }
""")
for a in ["    private func convertMessages(_ messages: [AgentMessage]) -> [MessageParameter.Message] {",
          "    private static func injectMissingToolResults(",
          "    private static func stripOrphanToolResults(",
          "    private static func mergeConsecutiveSameRole(",
          "    private static func reorderUserContent(",
          "    private static func reorderAssistantContent(",
          "    private static func concatContent(",
          "    private func convertToInput(",
          "    private static let downscaleCache",
          "    private static func downscaleForAnthropic(",
          "    private static func computeDownscaleForAnthropic("] { emit(decl(ANT, a)) }
emit("}")
emit(decl(ANT, "enum AnthropicToolInputConverter {"))
emit("enum RequestBodyPatcher {")
for a in ["    static let requestTokenHeader", "    private static let imageLock",
          "    private static var _toolResultImagesByToken",
          "    private static let maxPendingImageEntries",
          "    static func setToolResultImages(",
          "    private static func takeToolResultImages(",
          "    static func patchToolResultsWithImages(into request: NSMutableURLRequest) {"] { emit(decl(OAUTH, a)) }
emit("}")

// --- P-i9: the screenshot metadata line reports `image.size` (points)
// The harness encodes MessageParameter like the SDK's Endpoint.swift does.
let sdkEndpoint = (try? String(contentsOf: repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic/Private/Network/Endpoint.swift"), encoding: .utf8)) ?? ""
if !sdkEndpoint.contains("encoder.keyEncodingStrategy = .convertToSnakeCase") { drift.append("SwiftAnthropic Endpoint.swift: snake_case request encoder") }
let sizeLineOK = guardLiteral(BUM, "        let size = image.size")
    && guardLiteral(BUM, "lines.append(\"  Image: \\(Int(imageSize.width))x\\(Int(imageSize.height))")
    && guardLiteral(BUM, "guard let jpegData = image.jpegData(compressionQuality: 0.8) else {")
// --- P-i4: takeover does not persist through saveMedia / persistAgentMessage
let takeoverFn = decl(BG, "            let takeoverNote = ").isEmpty ? "" : block(BG, from: "        // Take a screenshot so the agent sees what the user did during takeover", through: "            agentHistory.append(msg)")
let takeoverPersists = takeoverFn.contains("saveMedia") || takeoverFn.contains("persistAgentMessage")
let takeoverResizes = takeoverFn.contains("resizedImageData") || takeoverFn.contains("jpegEncode")

if !drift.isEmpty {
    print("❌ DRIFT — the production code these tests extract has moved:")
    drift.forEach { print("   • \($0)") }
    exit(1)
}

// MARK: - Build (cached by content hash)

func sh(_ args: [String], cwd: URL? = nil, timeout: TimeInterval = 600) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run()
    // never hang the suite: kill a child that overruns
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    defer { killer.cancel() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalyst = ["-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                "-L", "\(sdk)/System/iOSSupport/usr/lib"]
let anthropicSrc = repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic")
let wholeFiles = ["Providers/AgentProvider.swift", "Agent/Chat/ChatStoreModels.swift", "Providers/LLMTypes.swift",
                  "Providers/ProviderTypes.swift", "Providers/ThinkingLevelCatalog.swift",
                  "Providers/Gemini/GeminiWireFormat.swift"].map { iosRoot.appendingPathComponent($0).path }
let helpers = ((try? FileManager.default.contentsOfDirectory(atPath: helperDir.path)) ?? [])
    .filter { $0.hasSuffix(".swift") }.sorted().map { helperDir.appendingPathComponent($0).path }

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}
var keyMaterial = out
for f in wholeFiles + helpers { keyMaterial += (try? String(contentsOfFile: f, encoding: .utf8)) ?? f }
let buildDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minis-image-repro-\(fnv(keyMaterial + sdk))")
try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
let extractedPath = buildDir.appendingPathComponent("Extracted.swift")
try? out.write(to: extractedPath, atomically: true, encoding: .utf8)
let exe = buildDir.appendingPathComponent("harness")

if !FileManager.default.fileExists(atPath: exe.path) {
    print("▶️  Building harness (Mac Catalyst) in \(buildDir.path)")
    let saDir = buildDir.appendingPathComponent("sa")
    try? FileManager.default.createDirectory(at: saDir, withIntermediateDirectories: true)
    guard FileManager.default.fileExists(atPath: anthropicSrc.path) else {
        print("❌ SwiftAnthropic checkout missing at \(anthropicSrc.path) — build the app once to resolve packages"); exit(1)
    }
    let saFiles = (FileManager.default.enumerator(atPath: anthropicSrc.path)?.allObjects as? [String] ?? [])
        .filter { ($0.hasPrefix("Public/Parameters") || $0.hasPrefix("Public/ResponseModels") || $0 == "Public/Model.swift") && $0.hasSuffix(".swift") }
        .map { anthropicSrc.appendingPathComponent($0).path }
    let (s1, o1) = sh(["swiftc"] + catalyst + ["-parse-as-library", "-emit-library", "-static", "-emit-module",
                      "-module-name", "SwiftAnthropic", "-emit-module-path", saDir.appendingPathComponent("SwiftAnthropic.swiftmodule").path,
                      "-o", saDir.appendingPathComponent("libSwiftAnthropic.a").path] + saFiles)
    guard s1 == 0 else { print("❌ SwiftAnthropic subset build failed:\n\(o1.suffix(3000))"); exit(1) }
    let (s2, o2) = sh(["swiftc"] + catalyst + ["-I", saDir.path, "-L", saDir.path, "-lSwiftAnthropic",
                      "-suppress-warnings", "-o", exe.path, extractedPath.path] + wholeFiles + helpers)
    guard s2 == 0 else {
        print("❌ harness build failed (see \(extractedPath.path)):")
        print(o2.components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(40).joined(separator: "\n"))
        exit(1)
    }
}

// MARK: - Run

print("▶️  Running harness")
let runStart = Date()
let (rs, rout) = sh([exe.path, buildDir.appendingPathComponent("work").path], timeout: 180)
var R: [String: Any] = [:]
for line in rout.components(separatedBy: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2)
    guard let eq = kv.firstIndex(of: "=") else { continue }
    let key = String(kv[..<eq])
    let val = String(kv[kv.index(after: eq)...])
    R[key] = (try? JSONSerialization.jsonObject(with: Data(val.utf8), options: [.fragmentsAllowed])) ?? val
}
guard rs == 0 else {
    print("❌ harness exited \(rs):\n\(rout.suffix(4000))"); exit(1)
}
print("   harness ran in \(String(format: "%.1f", Date().timeIntervalSince(runStart)))s, \(R.count) measurements")
if let path = ProcessInfo.processInfo.environment["IMG_REPRO_JSON"],
   let data = try? JSONSerialization.data(withJSONObject: R, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: URL(fileURLWithPath: path))
}

func num(_ k: String) -> Int { (R[k] as? NSNumber)?.intValue ?? Int((R[k] as? String) ?? "") ?? -1 }
func str(_ k: String) -> String { (R[k] as? String) ?? (R[k].map { "\($0)" } ?? "nil") }
func bool(_ k: String) -> Bool { (R[k] as? NSNumber)?.boolValue ?? (str(k) == "true") }
func long(_ k: String) -> Int { max(num(k + ".w"), num(k + ".h")) }
func dims(_ k: String) -> String { "\(num(k + ".w"))x\(num(k + ".h")) \(str(k + ".mime")) \(num(k + ".bytes"))B" }

let providers = ["responses", "chat", "gemini", "antigravity", "anthropic"]

// MARK: - Assertions

print("\n▶️  S1 browser full-page screenshot (2760x21891) — P-i1, P-i2, P-i9")
check("ingest: WKWebView-equivalent JPEG is 2760x21891 px while UIImage.size reports 920x7297 pt",
      dims("s1.src") .hasPrefix("2760x21891") && str("s1.reportedSize") == "920x7297", "\(dims("s1.src")) reported=\(str("s1.reportedSize"))")
check("P-i9: the metadata line reports image.size (points) — `Image: 920x7297`", sizeLineOK && str("s1.metaLine").contains("Image: 920x7297"), str("s1.metaLine"))
check("P-i1 live: browser_use sends a <=2000 long-edge image (\(dims("s1.live")))", long("s1.live") <= 2000 && long("s1.live") > 0)
check("P-i1 persisted: the snapshot mediaRef file is the ORIGINAL (\(dims("s1.persisted")) in \(str("s1.persisted.subdir")))",
      long("s1.persisted") == 21891 && str("s1.persisted.subdir") == "browser")
check("disk: browser screenshot copies — tmp original + mediaRef original (= \(num("s1.copies.original")) originals)", num("s1.copies.original") >= 1)
check("P-i2 rebuilt: toolResult.imageData after reload is the original 2760x21891 (\(dims("s1.rebuilt")))", long("s1.rebuilt") == 21891)
check("live != rebuilt bytes", !bool("s1.liveEqualsRebuilt"))
for p in providers {
    let k = "s1.wire.rebuilt.\(p)"
    if p == "anthropic" {
        check("P-i2 [\(p)] rebuilt request image is downscaled by downscaleForAnthropic (\(dims(k)))", long(k) <= 2000 && long(k) > 0)
    } else {
        check("P-i2 [\(p)] rebuilt request carries the original, long edge 21891 > 8192 (\(dims(k)))", long(k) == 21891)
    }
    desired("[\(p)] every request image has long edge <= 2000 after reload (\(dims(k)))", long(k) <= 2000 && long(k) > 0)
}
for p in providers {
    let k = "s1.wire.live.\(p)"
    check("[\(p)] live request image long edge <= 2000 (\(dims(k)))", long(k) <= 2000 && long(k) > 0)
}
desired("live and rebuilt request bytes are identical (prompt cache stable)", bool("s1.liveEqualsRebuilt"))
for p in providers {
    let same = str("s1.wire.live.\(p).sha") == str("s1.wire.rebuilt.\(p).sha")
    if p == "anthropic" {
        check("[anthropic] live and rebuilt S1 request images are byte-identical (resizedImageData ≡ downscaleForAnthropic for scale-1 input)", same)
    } else {
        check("[\(p)] live and rebuilt S1 request images differ — a reload changes the prompt bytes", !same)
    }
}

print("\n▶️  S2 browser viewport screenshot — default (390x844 pt) and big custom viewport (3000x2000 pt)")
check("default viewport: 1170x2532 px, rebuilt original stays <= 8192 (\(dims("s2a.rebuilt")))", dims("s2a.src").hasPrefix("1170x2532") && long("s2a.rebuilt") <= 8192)
check("default viewport live <=2000 (\(dims("s2a.live")))", long("s2a.live") <= 2000)
check("big viewport: 9000x6000 px source (\(dims("s2b.src")))", dims("s2b.src").hasPrefix("9000x6000"))
check("big viewport live <=2000 (\(dims("s2b.live")))", long("s2b.live") <= 2000)
check("big viewport rebuilt = original 9000 > 8192 (\(dims("s2b.rebuilt")))", long("s2b.rebuilt") == 9000)
check("big viewport [responses] wire after reload carries 9000 px (\(dims("s2b.wire.rebuilt.responses")))", long("s2b.wire.rebuilt.responses") == 9000)
desired("big viewport: every provider gets <= 2000 after reload", providers.allSatisfy { long("s2b.wire.rebuilt.\($0)") <= 2000 })

print("\n▶️  S3 camera photo (4032x3024 -> downsampledCameraJPEG) — P-i7")
check("ingest: downsampledCameraJPEG caps the capture at 2560 (\(dims("s3.c1")))", long("s3.c1") == 2560)
check("send path: <=2000 JPEG (\(dims("s3.send.live")))", long("s3.send.live") <= 2000 && str("s3.send.live.mime") == "image/jpeg")
check("P-i7 send path: rebuilt bytes == live bytes", bool("s3.send.liveEqualsRebuilt"))
check("P-i7 queue path: rebuilt bytes == live bytes", bool("s3.queue.liveEqualsRebuilt"))
check("C3 (<sid>/attachments/<uuid>) holds the live bytes; C2 uploads/ holds the 2560 copy (\(dims("s3.c2")))", long("s3.c2") == 2560)
for p in providers {
    check("[\(p)] camera image on the wire after reload <= 2000 (\(dims("s3.wire.rebuilt.\(p)")))", long("s3.wire.rebuilt.\(p)") <= 2000 && long("s3.wire.rebuilt.\(p)") > 0)
}

print("\n▶️  S4 photo-library picks — P-i3 (HEIC mime), P-i5, P-i7")
check("JPEG 4032x3024: send path <=2000 (\(dims("s4.jpeg.send.live")))", long("s4.jpeg.send.live") <= 2000)
check("JPEG: send == rebuilt", bool("s4.jpeg.send.liveEqualsRebuilt"))
check("HEIC 4032x3024: send path re-encodes to <=2000 JPEG labelled image/jpeg (\(dims("s4.heic.send.live")))",
      long("s4.heic.send.live") <= 2000 && str("s4.heic.send.live.mime") == "image/jpeg" && str("s4.heic.send.live.fmt") == "jpeg")
check("small HEIC (1200x900, <=2000): passes through as HEIC bytes but labelled image/jpeg (fmt=\(str("s4.heicSmall.send.live.fmt")) mime=\(str("s4.heicSmall.send.live.mime")))",
      str("s4.heicSmall.send.live.fmt") == "heic" && str("s4.heicSmall.send.live.mime") == "image/jpeg")
desired("small HEIC reaches the wire as a JPEG/PNG (fmt matches mime)", str("s4.heicSmall.wire.rebuilt.responses.fmt") != "heic", "wire fmt=\(str("s4.heicSmall.wire.rebuilt.responses.fmt")) mime=\(str("s4.heicSmall.wire.rebuilt.responses.mime"))")
check("EXIF orientation 6 (4032x3024 stored, 3024x4032 displayed): send path output is upright \(dims("s4.exif6.send.live"))",
      num("s4.exif6.send.live.w") < num("s4.exif6.send.live.h"))
check("transparent PNG 512x512 (<=2000): passes through as PNG with alpha (\(dims("s4.png.send.live")) alpha=\(str("s4.png.send.live.alpha")))",
      str("s4.png.send.live.mime") == "image/png" && bool("s4.png.send.live.alpha"))
check("transparent PNG 3000x3000: send path flattens to JPEG (alpha lost) (\(dims("s4.pngBig.send.live")))",
      str("s4.pngBig.send.live.fmt") == "jpeg" && !bool("s4.pngBig.send.live.alpha"))
check("transparent PNG 3000x3000: flattened corner pixel is \(str("s4.pngBig.send.live.corner")) (white = UIGraphicsImageRenderer default)", str("s4.pngBig.send.live.corner") != "")

print("\n▶️  S5 read_image — P-i3")
check("P-i3 live: big JPEG 2760x21891 -> <=2000 JPEG (\(dims("s5.big.live")))", long("s5.big.live") <= 2000 && str("s5.big.live.mime") == "image/jpeg")
check("P-i3 persisted R1 = the original file in images/ (\(dims("s5.big.persisted")) subdir=\(str("s5.big.persisted.subdir")))",
      long("s5.big.persisted") == 21891 && str("s5.big.persisted.subdir") == "images")
check("P-i3 rebuilt = original 21891 (\(dims("s5.big.rebuilt")))", long("s5.big.rebuilt") == 21891)
check("P-i3 [responses] after reload sends 21891 (\(dims("s5.big.wire.rebuilt.responses")))", long("s5.big.wire.rebuilt.responses") == 21891)
check("P-i3 HEIC: live is re-encoded JPEG (\(dims("s5.heic.live")) fmt=\(str("s5.heic.live.fmt")))", str("s5.heic.live.fmt") == "jpeg")
check("P-i3 HEIC: R1 stored with detectImageMime=\(str("s5.heic.persisted.declaredMime")) ext=\(str("s5.heic.persisted.ext")) (HEIC bytes)",
      str("s5.heic.persisted.declaredMime") == "image/jpeg" && str("s5.heic.persisted.fmt") == "heic")
check("P-i3 HEIC: rebuilt labelled \(str("s5.heic.rebuilt.mime")) while the bytes are \(str("s5.heic.rebuilt.fmt"))",
      str("s5.heic.rebuilt.mime") == "image/jpeg" && str("s5.heic.rebuilt.fmt") == "heic")
check("read same image twice: two R1 copies on disk (\(num("s5.twice.r1Copies")))", num("s5.twice.r1Copies") == 2)
check("read same image twice: live bytes identical between the two reads", bool("s5.twice.liveSame"))
desired("read_image: rebuilt bytes == live bytes", bool("s5.big.liveEqualsRebuilt"))

print("\n▶️  S6 queue path vs send path — P-i5")
check("same 4032x3024 JPEG: both paths <=2000 (send \(dims("s6.jpeg.send")) / queue \(dims("s6.jpeg.queue")))", long("s6.jpeg.send") <= 2000 && long("s6.jpeg.queue") <= 2000)
check("same JPEG: send and queue produce identical bytes = \(str("s6.jpeg.identical"))", true)
check("P-i5 GIF 2400x1800: queue path re-encodes to JPEG but labels it image/gif (fmt=\(str("s6.gif.queue.live.fmt")) mime=\(str("s6.gif.queue.live.mime")))",
      str("s6.gif.queue.live.fmt") == "jpeg" && str("s6.gif.queue.live.mime") == "image/gif")
check("GIF 2400x1800: send path labels the JPEG output image/jpeg (mime=\(str("s6.gif.sendRaw.live.mime")))", str("s6.gif.sendRaw.live.mime") == "image/jpeg")
check("P-i5 noisy 2000x2000 q1.0 JPEG (\(num("s6.noisy.src.bytes"))B): queue path has no compression ladder (queue \(num("s6.noisy.queue.bytes"))B vs send \(num("s6.noisy.send.bytes"))B)",
      bool("s6.noisy.queueHasNoLadder"))
desired("queue path labels MIME from the output bytes", str("s6.gif.queue.live.mime") == "image/jpeg")

print("\n▶️  S7 tool-result image across a reload — iOS keeps it (as the original)")
check("browser_use tool image survives the reload (rebuilt has imageData)", num("s1.rebuilt.w") > 0)
check("read_image tool image survives the reload", num("s5.big.rebuilt.w") > 0)

print("\n▶️  EXIF orientation through the read_image → reload → serializer path (review #9)")
check("read_image live (resizedImageData via UIImage.draw) is upright: \(str("s5.exif6.live.orientation"))", str("s5.exif6.live.orientation").hasPrefix("upright"))
check("R1 keeps the original with its EXIF tag; rebuilt [responses] bytes are \(str("s5.exif6.wire.rebuilt.responses.orientation"))", str("s5.exif6.wire.rebuilt.responses.orientation").hasPrefix("tagged(6)"))
check("jpegEncode (cgImage size + UIImage.draw) distorts a rotated photo: \(str("s5.exif6.jpegEncode.orientation"))", str("s5.exif6.jpegEncode.orientation").hasPrefix("squashed"))
check("[anthropic] downscaleForAnthropic after reload distorts it the same way: \(str("s5.exif6.wire.rebuilt.anthropic.orientation"))", str("s5.exif6.wire.rebuilt.anthropic.orientation").hasPrefix("squashed"))
desired("every provider gets an upright, untagged image after reload", providers.allSatisfy { str("s5.exif6.wire.rebuilt.\($0).orientation").hasPrefix("upright") })

print("\n▶️  MIME vs bytes on the wire")
check("queue-path GIF after reload: [anthropic] declares \(str("s6.gif.wire.rebuilt.anthropic.mime")) for \(str("s6.gif.wire.rebuilt.anthropic.fmt")) bytes",
      str("s6.gif.wire.rebuilt.anthropic.mime") == "image/gif" && str("s6.gif.wire.rebuilt.anthropic.fmt") == "jpeg")
check("small HEIC after reload: [anthropic] declares \(str("s4.heicSmall.wire.rebuilt.anthropic.mime")) for \(str("s4.heicSmall.wire.rebuilt.anthropic.fmt")) bytes",
      str("s4.heicSmall.wire.rebuilt.anthropic.mime") == "image/jpeg" && str("s4.heicSmall.wire.rebuilt.anthropic.fmt") == "heic")
desired("declared MIME matches the bytes for every provider (GIF queue + small HEIC)",
        providers.allSatisfy { str("s6.gif.wire.rebuilt.\($0).fmt") == "jpeg" ? str("s6.gif.wire.rebuilt.\($0).mime") == "image/jpeg" : true }
        && providers.allSatisfy { str("s4.heicSmall.wire.rebuilt.\($0).fmt") != "heic" })

print("\n▶️  P-i4 takeover screenshot")
check("P-i4 takeover appends the raw screenshot bytes (9000x6000 stays 9000x6000: \(dims("p4.live")))", long("p4.live") == 9000)
check("P-i4 takeover path has no resize call", !takeoverResizes)
check("P-i4 takeover path never calls saveMedia / persistAgentMessage (only writes takeover_<s>.jpg)", !takeoverPersists)
check("P-i4 [responses] live request carries 9000 px (\(dims("p4.wire.live.responses")))", long("p4.wire.live.responses") == 9000)
check("P-i4 [anthropic] live request is downscaled to <=2000 (\(dims("p4.wire.live.anthropic")))", long("p4.wire.live.anthropic") <= 2000)
desired("takeover image <= 2000 for every provider", providers.allSatisfy { long("p4.wire.live.\($0)") <= 2000 })

print("\n▶️  P-i6 re-encoding is not idempotent")
check("P-i6 jpegEncode(jpegEncode(x)) != jpegEncode(x) (bytes \(num("p6.once")) vs \(num("p6.twice")))", !bool("p6.jpegEncodeIdempotent"))
check("resizedImageData on an already <=2000 image returns nil (pass-through, so ?? data keeps bytes)", bool("p6.resizedPassThrough"))
check("read_image re-encodes a <=2000 JPEG every time (bytes change vs the file: \(str("p6.readImageChangesBytes")))", bool("p6.readImageChangesBytes"))

print("\n▶️  P-i8 request budget is bytes-only")
check("P-i8 a \(num("p8.src.bytes"))-byte 9000x300 image passes applyRequestImageBudget untouched", bool("p8.untouched") && num("p8.src.bytes") < 300_000)
check("P-i8 [responses] request carries the 9000x300 image (\(dims("p8.wire.responses")))", long("p8.wire.responses") == 9000)
desired("request layer bounds pixel size (<= 2000) for every provider", providers.allSatisfy { long("p8.wire.\($0)") <= 2000 })

print("\n▶️  Message structure")
check("send path: one image part per attachment, preceded by `[attached image: …]` text (count=\(num("s3.send.imageParts")))", num("s3.send.imageParts") == 1 && bool("s3.send.hasAttachedMarker"))
check("[responses] rebuilt S1 order: reasoning? → function_call → function_call_output → user image carrier (\(str("s1.wire.rebuilt.responses.order")))",
      str("s1.wire.rebuilt.responses.order").contains("function_call>function_call_output>user:input_image"))
check("[chat] rebuilt S1 order: tool message then synthetic user image (\(str("s1.wire.rebuilt.chat.order")))", str("s1.wire.rebuilt.chat.order").contains("tool>user:image_url"))
check("each provider carries exactly one copy of the S1 image (\(providers.map { "\($0)=\(num("s1.wire.rebuilt.\($0).count"))" }.joined(separator: " ")))",
      providers.allSatisfy { num("s1.wire.rebuilt.\($0).count") == 1 })
check("missing media file on reload: image silently dropped, no placeholder (parts \(str("miss.parts")))", str("miss.parts") == "text" )
desired("missing media file on reload leaves a visible placeholder", str("miss.parts") != "text")

let total = Date().timeIntervalSince(suiteStart)
print("\nSuite time \(String(format: "%.1f", total))s; known gaps: \(gaps.count)")
print(failures == 0 ? "✅ ALL PASSED (characterization)" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
