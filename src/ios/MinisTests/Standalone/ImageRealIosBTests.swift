#!/usr/bin/env swift
// [T-image-seams iOS-B] Tool images (browser_use, read_image) through the
// functions production calls — fast layer.
//
// The tool-image steps used to be inline in executeSingleToolUse /
// BrowserUseManager.screenshot, so the previous suite (ImagePipelineReproTests)
// could only cut blocks out of those functions by anchor. They are now named
// functions that the tool path itself calls:
//   AIChatViewModel.browserUseInferenceImage / writeBrowserScreenshotCopy /
//   readImageInference / saveBrowserSnapshotMedia / saveReadImageSnapshotMedia
//   BrowserUseManager.screenshotJPEGData / screenshotImageLine
// This harness compiles exactly those declarations (by name — no inline
// blocks) with the rest of the reload / serializer chain, for Mac Catalyst, and
// runs propositions P-i1, P-i3, P-i9 and scenarios S1, S2, S5, S7. The linked
// layer is MinisTests/ImageRealIosBTests.swift (XCTest, @testable import Minis).
//
// Whole production files compiled as-is: AgentProvider, ChatStoreModels,
// LLMTypes, ProviderTypes, ThinkingLevelCatalog, GeminiWireFormat (+ the
// SwiftAnthropic Parameters/ResponseModels subset ChatStoreModels imports).
// Other functions are compiled from their named declarations. A missing name
// fails the suite as DRIFT.
//
// (A) characterization: today's behaviour, ✅ / ❌.
// (B) desired: "⚠️ KNOWN GAP" today, "✅ (gap closed)" once fixed.
// Every measured value is also compared with the previous round
// (ImagePipelineReproTests, 2026-10-04) and differences are printed.
//
// Run: swift src/ios/MinisTests/Standalone/ImageRealIosBTests.swift
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let suiteStart = Date()
var failures = 0, gaps = 0
func check(_ label: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    if !cond { failures += 1 }
}
func desired(_ label: String, _ cond: Bool) {
    if cond { print("  ✅ (gap closed) \(label)") } else { print("  ⚠️ KNOWN GAP \(label)"); gaps += 1 }
}

let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
let helperDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ImageRealIosB")
var drift: [String] = []
func src(_ rel: String) -> String { (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? "" }

// MARK: - Named-declaration compiler input (Swift-aware brace matching)

func matchBrace(_ s: [Character], from open: Int) -> Int? {
    var i = open, depth = 0
    func skipString(_ start: Int) -> Int {
        var hashes = 0, j = start
        while j < s.count, s[j] == "#" { hashes += 1; j += 1 }
        let multi = j + 2 < s.count && s[j] == "\"" && s[j + 1] == "\"" && s[j + 2] == "\""
        j += multi ? 3 : 1
        while j < s.count {
            if s[j] == "\\" {
                var k = j + 1, h = 0
                while k < s.count, s[k] == "#", h < hashes { h += 1; k += 1 }
                if h == hashes, k < s.count, s[k] == "(" {
                    var p = 0, m = k
                    while m < s.count {
                        if s[m] == "\"" { m = skipString(m); continue }
                        if s[m] == "(" { p += 1 } else if s[m] == ")" { p -= 1; if p == 0 { break } }
                        m += 1
                    }
                    j = m + 1; continue
                }
                j = k + 1; continue
            }
            if s[j] == "\"" {
                if multi {
                    if j + 2 < s.count, s[j + 1] == "\"", s[j + 2] == "\"" { return j + 3 }
                } else {
                    var k = j + 1, h = 0
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
        if c == "/" && i + 1 < s.count && s[i + 1] == "/" { while i < s.count, s[i] != "\n" { i += 1 }; continue }
        if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
            while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
            i += 2; continue
        }
        if c == "\"" || (c == "#" && i + 1 < s.count && s[i + 1] == "\"") { i = skipString(i); continue }
        if c == "{" { depth += 1 }
        if c == "}" { depth -= 1; if depth == 0 { return i + 1 } }
        i += 1
    }
    return nil
}
/// The whole declaration that starts on the line holding `name`.
func decl(_ file: String, _ name: String) -> String {
    let text = src(file)
    guard let r = text.range(of: name) else { drift.append("\(file): `\(name)`"); return "" }
    let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
    let chars = Array(text[lineStart...])
    let firstLine = String(chars.prefix { $0 != "\n" })
    let words = firstLine.split(separator: " ").map(String.init)
    var code = "", inStr = false, esc = false
    for c in firstLine {
        if inStr { if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false } }
        else if c == "\"" { inStr = true } else { code.append(c) }
    }
    let isProperty = words.contains("let") || words.contains("var")
    if isProperty, !words.contains("func"), !code.contains("{") { return firstLine }
    guard let open = chars.firstIndex(of: "{"), var end = matchBrace(chars, from: open) else {
        drift.append("\(file): unbalanced `\(name)`"); return ""
    }
    if isProperty, end + 1 < chars.count, chars[end] == "(", chars[end + 1] == ")" { end += 2 }
    return String(chars[0..<end])
}

let CT = "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
let BUM = "Agent/BrowserUse/BrowserUseManager.swift"
let MISC = "Agent/Chat/AIChatViewModel+Misc.swift"
let RB = "Agent/Chat/AIChatViewModel+RequestBudget.swift"
let APA = "Agent/Chat/AIChatViewModel+AutoPlayAudio.swift"
let MEDIA = "Agent/Chat/ChatStore+Media.swift"
let HELP = "Agent/Chat/ChatStore+Helpers.swift"
let RMC = "Agent/Chat/RawMessage+Conversion.swift"
let CPC = "Agent/Chat/ContentPart+ProviderConversion.swift"
let ATT = "Agent/Chat/AIChatViewModel+Attachments.swift"
let VGR = "Providers/VisionGroupResolver.swift"
let OAI = "Providers/OpenAI/OpenAIAgentProvider.swift"
let GEM = "Providers/Gemini/GeminiAgentProvider.swift"
let GEMP = "Providers/Gemini/GeminiProvider.swift"
let AG = "Providers/Antigravity/AntigravityAgentProvider.swift"

var out = "// GENERATED by ImageRealIosBTests.swift from the current sources. Do not edit.\nimport Foundation\nimport UIKit\nimport ImageIO\nimport CryptoKit\nimport SwiftAnthropic\n\n"
func emit(_ s: String) { out += s + "\n" }

// The seams under test (production calls exactly these).
emit("@MainActor final class AIChatViewModel {")
emit("    nonisolated static var minisPersistentBase: URL { IosBEnv.root.appendingPathComponent(\"MinisChat/minis\") }")
for (f, n) in [(CT, "    static func browserUseInferenceImage("), (CT, "    static func writeBrowserScreenshotCopy("),
               (CT, "    struct ReadImageInference {"), (CT, "    static func readImageInference("),
               (CT, "    static func saveBrowserSnapshotMedia("), (CT, "    static func saveReadImageSnapshotMedia("),
               (MISC, "static func resizedImageData("), (MISC, "nonisolated static let minisBrowserLinuxDir"),
               (RB, "nonisolated static func minisBrowserPersistentDir(for sid: String) -> URL {"),
               (APA, "static func detectImageMime("),
               // [T-image-gate] the tool seams run ModelImageGate with the per-image cap
               ("Agent/Chat/AIChatViewModel.swift", "static func rawBytesForBase64Budget("),
               ("Agent/Chat/AIChatViewModel.swift", "static let kPerImageMaxBytes")] { emit(decl(f, n)) }
emit("}")
// [T-image-gate] The gate itself (BEGIN/END block in +RequestBudget).
do {
    let rb = src(RB)
    if let b = rb.range(of: "// BEGIN ModelImageGate"), let e = rb.range(of: "// END ModelImageGate") {
        emit(String(rb[b.lowerBound..<e.upperBound]))
    } else { drift.append("\(RB): BEGIN/END ModelImageGate not found") }
}
emit("enum BrowserUseManager {")
emit(decl(BUM, "    nonisolated static func screenshotJPEGData("))
emit(decl(BUM, "    nonisolated static func screenshotImageLine("))
emit("}")
// Disk + reload chain.
emit("actor ChatStore {\n    static let shared = ChatStore()\n    let minisBaseURL: URL = IosBEnv.root.appendingPathComponent(\"MinisChat/minis\")\n    func markDirty(recordType: String, recordId: String) {}")
emit(decl(MEDIA, "    func saveMedia(")); emit(decl(MEDIA, "    func mediaFileURLResolver() -> (MediaRef) -> URL {"))
emit(decl(HELP, "static func fileExtension(for mimeType: String) -> String {")); emit("}")
emit("extension RawMessage {"); emit(decl(RMC, "    func toAgentMessage(mediaResolver: (MediaRef) -> URL) -> AgentMessage {"))
emit(decl(RMC, "    private static func sniffImageMimeType(_ data: Data) -> String? {"))
// helpers toAgentMessage calls (extracted by iOS-C, 6fb57019e)
emit(decl(RMC, "    static func rebuiltImagePart(")); emit(decl(RMC, "    static func rebuiltToolResultImage(")); emit("}")
emit(decl(CPC, "func parseJSONToDict(_ json: String) -> [String: Any] {"))
emit(decl(ATT, "enum PastePlaceholder {"))
// Serializers (wire check).
emit("enum VisionGroupResolver {\n    nonisolated static var isConfiguredCached: Bool { false }")
emit(decl(VGR, "nonisolated static func visionImagePathNote(linuxPath: String?) -> String? {"))
emit(decl(VGR, "nonisolated static func attachmentPlaceholder(linuxPath: String?) -> String {")); emit("}")
emit("final class OpenAIAgentProvider {\n    struct ProviderShim { var isMistral = false; var isCerebras = false; var customBaseURL: String? = nil }\n    let model: LLMModel\n    let provider = ProviderShim()\n    init(model: LLMModel) { self.model = model }")
for n in ["static let encryptedReasoningMarker", "static let responsesAPIProviderKind", "var reasoningUpstreamIdentity: String {",
          "func convertMessagesResponsesAPI(_ messages: [AgentMessage]) -> [[String: Any]] {", "static func sanitizeResponsesToolPairing(",
          "func flattenChatCompletionsMessages(", "private func convertSingleMessageChatCompletions(",
          "private static func globallyDedupeToolCallIds(", "private static func sanitizeToolCallAdjacency(",
          "private static func splitResponsesAPIIds(", "private static func capChatId(", "private static func capResponsesId(",
          "private static let maxChatCompletionsIdLength", "private static let maxResponsesAPIIdLength"] { emit(decl(OAI, n)) }
emit("}")
emit("final class GeminiAgentProvider {\n    let model: LLMModel\n    var toolCallMetadataMap: [String: ToolCallMetadata] = [:]\n    init(model: LLMModel) { self.model = model }")
for n in ["    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {", "    static func narratedToolCall(",
          "    static func narratedToolResult(", "    static let narratedResultLimit"] { emit(decl(GEM, n)) }
emit("}"); emit(decl(GEMP, "enum GeminiConversation"))
emit("final class AntigravityAgentProvider {\n    let model: LLMModel\n    var toolCallMetadataMap: [String: ToolCallMetadata] = [:]\n    init(model: LLMModel) { self.model = model }")
emit(decl(AG, "    private var isClaude: Bool")); emit(decl(AG, "    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {")); emit("}")

// The tool path must call the seams (one definition, used by production and test).
let ct = src(CT), bum = src(BUM)
for (file, text, call) in [(CT, ct, "let inference = Self.browserUseInferenceImage(data)"),
                           (CT, ct, "let linuxPath = Self.writeBrowserScreenshotCopy(data, sessionId: sessionId)"),
                           (CT, ct, "let inference = Self.readImageInference(fileData: fileData, image: uiImage)"),
                           (CT, ct, "let ref = await Self.saveBrowserSnapshotMedia("),
                           (CT, ct, "let ref = await Self.saveReadImageSnapshotMedia("),
                           (BUM, bum, "guard let jpegData = Self.screenshotJPEGData(image) else {"),
                           (BUM, bum, "lines.append(Self.screenshotImageLine(imageSize: imageSize, fileSize: fileSize))")] where !text.contains(call) {
    drift.append("\(file): production no longer calls `\(call)`")
}
if !drift.isEmpty { print("❌ DRIFT:"); drift.forEach { print("   • \($0)") }; exit(1) }

// MARK: - Build (cached by content hash) and run

func sh(_ args: [String], timeout: TimeInterval = 600) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalyst = ["-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk, "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                "-L", "\(sdk)/System/iOSSupport/usr/lib"]
let whole = ["Providers/AgentProvider.swift", "Agent/Chat/ChatStoreModels.swift", "Providers/LLMTypes.swift", "Providers/ProviderTypes.swift",
             "Providers/ThinkingLevelCatalog.swift", "Providers/Gemini/GeminiWireFormat.swift"].map { iosRoot.appendingPathComponent($0).path }
let helpers = ((try? FileManager.default.contentsOfDirectory(atPath: helperDir.path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
    .map { helperDir.appendingPathComponent($0).path }
func fnv(_ s: String) -> String { var h: UInt64 = 0xcbf29ce484222325; for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }; return String(h, radix: 16) }
let key = fnv(out + sdk + (whole + helpers).map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? $0 }.joined())
let buildDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("imgreal-iosb-\(key)")
try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
let generated = buildDir.appendingPathComponent("Seams.swift")
try? out.write(to: generated, atomically: true, encoding: .utf8)
let exe = buildDir.appendingPathComponent("harness")
if !FileManager.default.fileExists(atPath: exe.path) {
    print("▶️  Building harness (Mac Catalyst) in \(buildDir.path)")
    let anthropic = repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic")
    let saFiles = (FileManager.default.enumerator(atPath: anthropic.path)?.allObjects as? [String] ?? [])
        .filter { ($0.hasPrefix("Public/Parameters") || $0.hasPrefix("Public/ResponseModels") || $0 == "Public/Model.swift") && $0.hasSuffix(".swift") }
        .map { anthropic.appendingPathComponent($0).path }
    guard !saFiles.isEmpty else { print("❌ SwiftAnthropic checkout missing — build the app once to resolve packages"); exit(1) }
    let sa = buildDir.appendingPathComponent("sa"); try? FileManager.default.createDirectory(at: sa, withIntermediateDirectories: true)
    let (s1, o1) = sh(["swiftc"] + catalyst + ["-parse-as-library", "-emit-library", "-static", "-emit-module", "-module-name", "SwiftAnthropic",
                      "-emit-module-path", sa.appendingPathComponent("SwiftAnthropic.swiftmodule").path, "-o", sa.appendingPathComponent("libSwiftAnthropic.a").path] + saFiles)
    guard s1 == 0 else { print("❌ SwiftAnthropic subset build failed:\n\(o1.suffix(2000))"); exit(1) }
    let (s2, o2) = sh(["swiftc"] + catalyst + ["-parse-as-library", "-I", sa.path, "-L", sa.path, "-lSwiftAnthropic", "-suppress-warnings",
                      "-o", exe.path, generated.path] + whole + helpers)
    guard s2 == 0 else {
        print("❌ harness build failed (\(generated.path)):"); print(o2.components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(30).joined(separator: "\n")); exit(1)
    }
}
print("▶️  Running harness")
let (rs, rout) = sh([exe.path, buildDir.appendingPathComponent("work").path], timeout: 180)
guard rs == 0 else { print("❌ harness exited \(rs):\n\(rout.suffix(3000))"); exit(1) }
var R: [String: Any] = [:]
for line in rout.components(separatedBy: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2); guard let eq = kv.firstIndex(of: "=") else { continue }
    R[String(kv[..<eq])] = (try? JSONSerialization.jsonObject(with: Data(kv[kv.index(after: eq)...].utf8), options: [.fragmentsAllowed])) ?? ""
}
func num(_ k: String) -> Int { (R[k] as? NSNumber)?.intValue ?? -1 }
func str(_ k: String) -> String { (R[k] as? String) ?? (R[k].map { "\($0)" } ?? "nil") }
func bool(_ k: String) -> Bool { (R[k] as? NSNumber)?.boolValue ?? false }
func long(_ k: String) -> Int { max(num(k + ".w"), num(k + ".h")) }
func dims(_ k: String) -> String { "\(num(k + ".w"))x\(num(k + ".h"))/\(num(k + ".bytes"))/\(str(k + ".fmt"))/\(R[k + ".mime"] == nil ? "-" : str(k + ".mime"))" }
let providers = ["responses", "chat", "gemini", "antigravity"]

// MARK: - Assertions

print("\n▶️  S1 full-page screenshot — P-i1, P-i9, S7")
check("screenshotJPEGData: 920x7297 pt @3 → \(dims("s1.src"))", dims("s1.src").hasPrefix("2760x21891/"))
check("P-i9 screenshotImageLine reports UIImage.size (points): \(str("s1.metaLine"))", str("s1.metaLine").hasPrefix("  Image: 920x7297 ("))
// [T-image-gate #412] The live tool image is ModelImageGate's output and the
// tool snapshot stores that same image (the original stays in browser/ via
// B2). Was: the snapshot persisted the ORIGINAL and a reload resent it
// (2760x21891 / 9000x6000 on every non-Anthropic serializer) - the five
// KNOWN GAPs below are now checks.
check("P-i1 browserUseInferenceImage: live \(dims("s1.live"))", dims("s1.live").hasPrefix("252x2000/") && str("s1.live.mime") == "image/jpeg")
check("B2 writeBrowserScreenshotCopy writes the ORIGINAL at \(str("s1.b2.linuxPath"))", bool("s1.b2.isOriginal") && str("s1.b2.linuxPath") == "/var/minis/browser/screenshot_<s>.jpg")
check("P-i1 saveBrowserSnapshotMedia persists the model image (\(dims("s1.persisted")), \(str("s1.persisted.subdir"))/, \(str("s1.persisted.name")))",
      dims("s1.persisted") == dims("s1.live") && str("s1.persisted.subdir") == "browser" && str("s1.persisted.name") == "browser_snapshot.jpg")
check("S7 reload keeps the tool image - the live bytes (\(dims("s1.rebuilt")))", dims("s1.rebuilt") == dims("s1.live"))
for p in providers {
    check("[\(p)] live \(dims("s1.wire.live.\(p)")) / after reload \(dims("s1.wire.rebuilt.\(p)"))",
          long("s1.wire.live.\(p)") == 2000 && dims("s1.wire.rebuilt.\(p)") == dims("s1.wire.live.\(p)"))
}
check("every serializer sends <= 2000 after a reload", providers.allSatisfy { long("s1.wire.rebuilt.\($0)") <= 2000 })
check("live and rebuilt bytes are identical", bool("s1.liveEqualsRebuilt"))

print("\n▶️  S2 viewport screenshots")
check("default 390x844 pt → \(dims("s2a.src")), live \(dims("s2a.live")), after reload \(dims("s2a.rebuilt"))",
      dims("s2a.src").hasPrefix("1170x2532/") && long("s2a.live") == 2000 && dims("s2a.rebuilt") == dims("s2a.live"))
check("big 3000x2000 pt → \(dims("s2b.src")), live \(dims("s2b.live")), after reload \(dims("s2b.rebuilt"))",
      dims("s2b.src").hasPrefix("9000x6000/") && long("s2b.live") == 2000 && dims("s2b.rebuilt") == dims("s2b.live"))
for p in providers { check("[\(p)] big viewport after reload carries the live 2000 px image", dims("s2b.wire.rebuilt.\(p)") == dims("s2b.live")) }
check("big viewport stays <= 8192 after a reload", providers.allSatisfy { long("s2b.wire.rebuilt.\($0)") <= 8192 })

print("\n▶️  S5 read_image — P-i3, S7")
check("P-i3 readImageInference: live \(dims("s5.big.live")) (sizes \(str("s5.big.sizes")))", long("s5.big.live") == 2000 && str("s5.big.sizes") == "2760x21891->252x2000")
check("P-i3 saveReadImageSnapshotMedia: R1 = the model image in \(str("s5.big.persisted.subdir"))/ (\(dims("s5.big.persisted")))",
      dims("s5.big.persisted") == dims("s5.big.live") && str("s5.big.persisted.subdir") == "images")
let s5Wire = providers.map { p in p + "=" + String(long("s5.big.wire.rebuilt." + p)) }.joined(separator: " ")
check("P-i3 after reload the live image goes out: " + s5Wire, providers.allSatisfy { dims("s5.big.wire.rebuilt." + $0) == dims("s5.big.live") })
check("P-i3 HEIC: live transcoded \(dims("s5.heic.live")); R1 \(dims("s5.heic.persisted")) .\(str("s5.heic.persisted.ext"))",
      str("s5.heic.live.fmt") == "jpeg" && str("s5.heic.persisted.fmt") == "jpeg" && str("s5.heic.persisted.mime") == "image/jpeg" && str("s5.heic.persisted.ext") == "jpg")
check("P-i3 HEIC after reload: labelled \(str("s5.heic.rebuilt.mime")) for \(str("s5.heic.rebuilt.fmt")) bytes", str("s5.heic.rebuilt.mime") == "image/jpeg" && str("s5.heic.rebuilt.fmt") == "jpeg")
// A compliant file now goes out as its own bytes (it used to be re-encoded).
check("same file read twice: \(num("s5.twice.r1Copies")) R1 copies, identical live bytes, the file's own bytes", num("s5.twice.r1Copies") == 2 && bool("s5.twice.liveSame") && !bool("s5.twice.reencodes"))
check("read_image after a reload resends the live bytes", bool("s5.big.liveEqualsRebuilt"))
check("HEIC never goes out labelled image/jpeg", str("s5.heic.rebuilt.fmt") != "heic")

// MARK: - Same values as the previous round?

// [T-image-gate] Round of task iOS-G: 47 values changed by the gate (#412 fix) -
// live tool images are the gate's output, snapshots / reloads carry them.
let previous: [String: String] = [
    "s1.src": "2760x21891/4295515/jpeg/image/jpeg",
    "s1.live": "252x2000/129932/jpeg/image/jpeg",
    "s1.persisted": "252x2000/129932/jpeg/image/jpeg",
    "s1.rebuilt": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.live.responses": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.rebuilt.responses": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.live.chat": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.rebuilt.chat": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.live.gemini": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.rebuilt.gemini": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.live.antigravity": "252x2000/129932/jpeg/image/jpeg",
    "s1.wire.rebuilt.antigravity": "252x2000/129932/jpeg/image/jpeg",
    "s2a.src": "1170x2532/412324/jpeg/image/jpeg",
    "s2a.live": "924x2000/329120/jpeg/image/jpeg",
    "s2a.persisted": "924x2000/329120/jpeg/image/jpeg",
    "s2a.rebuilt": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.live.responses": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.rebuilt.responses": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.live.chat": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.rebuilt.chat": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.live.gemini": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.rebuilt.gemini": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.live.antigravity": "924x2000/329120/jpeg/image/jpeg",
    "s2a.wire.rebuilt.antigravity": "924x2000/329120/jpeg/image/jpeg",
    "s2b.src": "9000x6000/1676181/jpeg/image/jpeg",
    "s2b.live": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.persisted": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.rebuilt": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.live.responses": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.rebuilt.responses": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.live.chat": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.rebuilt.chat": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.live.gemini": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.rebuilt.gemini": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.live.antigravity": "2000x1333/323781/jpeg/image/jpeg",
    "s2b.wire.rebuilt.antigravity": "2000x1333/323781/jpeg/image/jpeg",
    "s5.big.live": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.persisted": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.rebuilt": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.wire.rebuilt.responses": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.wire.rebuilt.chat": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.wire.rebuilt.gemini": "252x2000/129932/jpeg/image/jpeg",
    "s5.big.wire.rebuilt.antigravity": "252x2000/129932/jpeg/image/jpeg",
    "s5.heic.live": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.persisted": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.rebuilt": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.wire.rebuilt.responses": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.wire.rebuilt.chat": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.wire.rebuilt.gemini": "2000x1500/622833/jpeg/image/jpeg",
    "s5.heic.wire.rebuilt.antigravity": "2000x1500/622833/jpeg/image/jpeg",
]
print("\n▶️  Compared with the previous round (\(previous.count) measurements)")
var diffs = 0
for k in previous.keys.sorted() where dims(k) != previous[k]! {
    diffs += 1; print("  ⚠️ CHANGED \(k): previous \(previous[k]!) → now \(dims(k))")
}
check("all \(previous.count) image measurements equal the previous round", diffs == 0)

print("\nSuite time \(String(format: "%.1f", Date().timeIntervalSince(suiteStart)))s; known gaps: \(gaps)")
print(failures == 0 ? "✅ ALL PASSED (characterization)" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
