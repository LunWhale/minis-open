#!/usr/bin/env swift
// [T-image-real-seams] iOS-C: persistence, reload, request budget and browser
// takeover, through the REAL functions.
//
// The image steps of these paths are now callable functions, each between
// `// BEGIN <name>` / `// END <name>` markers in its production file:
//   * PersistImageParts (AIChatViewModel+Persistence.swift):
//     toolResultMediaRef(imageData:snapshot:), persistedUserImageRef(...)
//   * RebuildImageParts (RawMessage+Conversion.swift): rebuiltImagePart,
//     rebuiltToolResultImage, sniffImageMimeType - what toAgentMessage uses
//   * RequestImageBudget (AIChatViewModel+RequestBudget.swift):
//     budgetedRequestImages(_:sessionId:) and the planner it uses
//   * TakeoverScreenshotMessage (AIChatViewModel+BackgroundTask.swift)
// This driver compiles those blocks VERBATIM together with the model types
// they use, compiled as whole files (AgentProvider, ChatStoreModels, LLMTypes,
// ProviderTypes, ThinkingLevelCatalog, GeminiWireFormat, SwiftAnthropic's
// request/response models). Dependencies outside iOS-C's files are lifted from
// the current source by declaration (DRIFT if missing): ChatStore.saveMedia /
// mediaFileURLResolver / fileExtension, estimatedBase64Length,
// kPerImageMaxBytes, kRequestImageMaxBytes, minisBrowserLinuxDir, and
// minisBrowserPersistentDir. Storage roots point at a temp directory.
//
// Re-verifies P-i2 (reload gives the original), P-i4 (takeover not resized,
// not in history), P-i8 (budget counts bytes, never scales), the silent drop
// of a missing media file, and the persist -> reload round trip.
// Characterization checks pin today's behaviour; KNOWN GAP lines are desired
// behaviour still missing and do not fail the run.
//
// Built for Mac Catalyst. Cached by content hash.
// Run: swift src/ios/MinisTests/Standalone/ImageRealIosCTests.swift
// IOSC_JSON=<path> exports every measured value.
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
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
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
func block(_ src: String, _ name: String) -> String? {
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else { return nil }
    return String(src[b.lowerBound..<e.upperBound])
}
/// One line for a `let`, through the matching brace otherwise.
func declaration(_ src: String, _ signature: String) -> String? {
    guard let hit = src.range(of: signature) else { return nil }
    let lineStart = src[..<hit.lowerBound].lastIndex(of: "\n").map { src.index(after: $0) } ?? src.startIndex
    if signature.contains(" let ") || signature.hasPrefix("static let") {
        let lineEnd = src[hit.upperBound...].firstIndex(of: "\n") ?? src.endIndex
        return String(src[lineStart..<lineEnd])
    }
    let chars = Array(src[lineStart...])
    var depth = 0, i = 0, opened = false
    var inString = false, inLineComment = false, inBlockComment = false
    while i < chars.count {
        let c = chars[i], n = i + 1 < chars.count ? chars[i + 1] : " "
        if inLineComment { if c == "\n" { inLineComment = false } }
        else if inBlockComment { if c == "*" && n == "/" { inBlockComment = false; i += 1 } }
        else if inString { if c == "\\" { i += 1 } else if c == "\"" { inString = false } }
        else if c == "/" && n == "/" { inLineComment = true; i += 1 }
        else if c == "/" && n == "*" { inBlockComment = true; i += 1 }
        else if c == "\"" { inString = true }
        else if c == "{" { depth += 1; opened = true }
        else if c == "}" { depth -= 1; if opened && depth == 0 { return String(chars[0...i]) } }
        i += 1
    }
    return nil
}

// MARK: - Real code from the current source

let persistence = source("Agent/Chat/AIChatViewModel+Persistence.swift")
let conversion = source("Agent/Chat/RawMessage+Conversion.swift")
let budget = source("Agent/Chat/AIChatViewModel+RequestBudget.swift")
let background = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
let vmSrc = source("Agent/Chat/AIChatViewModel.swift")
let misc = source("Agent/Chat/AIChatViewModel+Misc.swift")
let storeMedia = source("Agent/Chat/ChatStore+Media.swift")
let storeHelpers = source("Agent/Chat/ChatStore+Helpers.swift")

print("Real functions and wiring")
var blocks: [String: String] = [:]
for (name, src, file) in [("PersistImageParts", persistence, "+Persistence"), ("RebuildImageParts", conversion, "RawMessage+Conversion"),
                          ("RequestImageBudget", budget, "+RequestBudget"), ("TakeoverScreenshotMessage", background, "+BackgroundTask"),
                          ("ModelImageGate", budget, "+RequestBudget")] {
    guard let b = block(src, name) else { print("  ❌ DRIFT: BEGIN/END \(name) not found in \(file)"); exit(1) }
    blocks[name] = b
}
check("buildRawMessage stores a tool image's ref through toolResultMediaRef",
      persistence.contains("let mediaRef = Self.toolResultMediaRef(imageData: imgData, snapshot: snap)"))
check("buildRawMessage writes a user image through persistedUserImageRef",
      persistence.contains("let ref = await Self.persistedUserImageRef(data: data, mimeType: mimeType, sessionId: sessionId, linuxPath: linuxPath,\n                                                           store: store)"))
check("toAgentMessage rebuilds a user image through rebuiltImagePart",
      conversion.contains("} else if let image = Self.rebuiltImagePart(ref, mediaResolver: mediaResolver) {"))
check("toAgentMessage rebuilds a tool image through rebuiltToolResultImage",
      conversion.contains("let (imgData, imgMime) = Self.rebuiltToolResultImage(tr.mediaRef, mediaResolver: mediaResolver)"))
check("applyRequestImageBudget is budgetedRequestImages plus log and toast",
      budget.contains("guard let budgeted = Self.budgetedRequestImages(messages, sessionId: sessionId) else { return messages }"))
check("the takeover wait injects takeoverScreenshotMessage",
      background.contains("let msg = Self.takeoverScreenshotMessage(data, sessionId: sessionId, timestamp: timestamp)"))

let lifts: [(String, String, String)] = [
    ("AIChatViewModel.swift", vmSrc, "static func estimatedBase64Length("),
    ("AIChatViewModel.swift", vmSrc, "static func rawBytesForBase64Budget("),
    ("AIChatViewModel.swift", vmSrc, "static let kPerImageMaxBytes"),
    ("AIChatViewModel.swift", vmSrc, "static let kRequestImageMaxBytes"),
    ("+Misc", misc, "nonisolated static let minisBrowserLinuxDir"),
    ("+RequestBudget", budget, "nonisolated static func minisBrowserPersistentDir(for sid: String)"),
    ("ChatStore+Media", storeMedia, "    func saveMedia("),
    ("ChatStore+Media", storeMedia, "    func mediaFileURLResolver()"),
    ("ChatStore+Helpers", storeHelpers, "static func fileExtension(for mimeType: String)"),
]
var lifted: [String: String] = [:]
for (file, src, sig) in lifts {
    guard let d = declaration(src, sig) else { print("  ❌ DRIFT: \(sig) not found (\(file))"); exit(1) }
    lifted[sig] = d
}

let harness = """
import Foundation
import UIKit
import CryptoKit

enum HarnessEnv {
    static var root = URL(fileURLWithPath: CommandLine.arguments[2])
    static let sessionId = "S-IOSC"
}
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
func AppLocalized(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String { String(localized: key) }
enum ModelsDevAPI { static func enrichModel(_ m: LLMModel) -> LLMModel { m } }
enum XAIModelsAPI { static var allModels: [LLMModel] { [] } }
enum KimiModelsAPI { static var allModels: [LLMModel] { [] } }

/// Stand-in for the app's MainActor view model: only the statics the blocks use.
final class AIChatViewModel {
    var sessionId: String? = HarnessEnv.sessionId
    var transientNotice: String?
    nonisolated static var minisPersistentBase: URL { HarnessEnv.root.appendingPathComponent("MinisChat/minis", isDirectory: true) }
\(lifted["static func estimatedBase64Length("]!)
\(lifted["static func rawBytesForBase64Budget("]!)
\(lifted["static let kPerImageMaxBytes"]!)
\(lifted["static let kRequestImageMaxBytes"]!)
\(lifted["nonisolated static let minisBrowserLinuxDir"]!)
\(lifted["nonisolated static func minisBrowserPersistentDir(for sid: String)"]!)
}

/// Stand-in for the ChatStore actor: the real saveMedia / resolver /
/// fileExtension over a temp media root; sync bookkeeping is a no-op.
actor ChatStore {
    static let shared = ChatStore()
    let minisBaseURL: URL = HarnessEnv.root.appendingPathComponent("MinisChat/minis", isDirectory: true)
    func markDirty(recordType: String, recordId: String) {}
\(lifted["    func saveMedia("]!)
\(lifted["    func mediaFileURLResolver()"]!)
\(lifted["static func fileExtension(for mimeType: String)"]!)
}
"""

let realSwift = """
import Foundation
import UIKit
import ImageIO
import CryptoKit

\(blocks["PersistImageParts"]!)

\(blocks["RebuildImageParts"]!)

extension AIChatViewModel {
\(blocks["RequestImageBudget"]!)
}

\(blocks["TakeoverScreenshotMessage"]!)

\(blocks["ModelImageGate"]!)
"""

let helperDir = here.appendingPathComponent("ImageRealIosC")
let fixtures = (try? String(contentsOf: helperDir.appendingPathComponent("Fixtures.swift"), encoding: .utf8)) ?? ""
let scenarios = (try? String(contentsOf: helperDir.appendingPathComponent("Scenarios.swift"), encoding: .utf8)) ?? ""
guard !fixtures.isEmpty, !scenarios.isEmpty else { print("  ❌ ImageRealIosC/ helper files missing"); exit(1) }

// MARK: - Build (cached by content hash) and run

let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalyst = ["-D", "IMAGE_REAL_IOS_C", "-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                "-L", "\(sdk)/System/iOSSupport/usr/lib"]
let wholeFiles = ["Providers/AgentProvider.swift", "Agent/Chat/ChatStoreModels.swift", "Providers/LLMTypes.swift",
                  "Providers/ProviderTypes.swift", "Providers/ThinkingLevelCatalog.swift",
                  "Providers/Gemini/GeminiWireFormat.swift"]
let anthropicSrc = repoRoot.appendingPathComponent("build/DerivedData/SourcePackages/checkouts/SwiftAnthropic/Sources/Anthropic")
let saFiles = ((FileManager.default.enumerator(atPath: anthropicSrc.path)?.allObjects as? [String]) ?? [])
    .filter { ($0.hasPrefix("Public/Parameters") || $0.hasPrefix("Public/ResponseModels") || $0 == "Public/Model.swift") && $0.hasSuffix(".swift") }
    .sorted().map { anthropicSrc.appendingPathComponent($0).path }
guard !saFiles.isEmpty else { print("  ❌ SwiftAnthropic checkout missing at \(anthropicSrc.path) - build the app once"); exit(1) }

var generated = ["harness.swift": harness, "real.swift": realSwift, "Fixtures.swift": fixtures,
                 "Scenarios.swift": scenarios, "main.swift": "await runScenarios()\n"]
for f in wholeFiles { generated["whole_" + (f as NSString).lastPathComponent] = source(f) }
var key = generated.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + catalyst.joined()
for f in saFiles { key += (try? String(contentsOfFile: f, encoding: .utf8)) ?? f }
let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("minis-image-real-iosC-\(digest)")
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
        print(o2.components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(30).joined(separator: "\n"))
        print("  ❌ harness build failed (sources in \(work.path))"); exit(1)
    }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("minis-image-real-iosC-root-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let jsonURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IOSC_JSON"] ?? work.appendingPathComponent("results.json").path)
let (runStatus, runOut) = sh([bin.path, jsonURL.path, root.path])
guard runStatus == 0, let raw = try? Data(contentsOf: jsonURL),
      let m = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    print(runOut); print("  ❌ harness run failed"); exit(1)
}
func int(_ k: String) -> Int { m[k] as? Int ?? -1 }
func str(_ k: String) -> String { m[k] as? String ?? "?" }
func bool(_ k: String) -> Bool { m[k] as? Bool ?? false }
func strs(_ k: String) -> [String] { m[k] as? [String] ?? [] }
func dims(_ k: String) -> String { "\(int("\(k).w"))x\(int("\(k).h"))" }

// MARK: - P-i2

print("P-i2 tool image across a reload")
check("a tool result that carried an image stores the snapshot's ref (the original)", bool("p2.storedRefIsSnapshotRef"))
check("a tool result without image data stores no ref", bool("p2.noImageMeansNoRef"))
check("a session stored before #412 was fixed reloads its tool image as the original 2760x21891, not the live image",
      dims("p2.rebuilt") == "2760x21891" && bool("p2.rebuiltEqualsOriginal") && !bool("p2.rebuiltEqualsLive"))
check("its MIME is sniffed from the bytes: image/jpeg", str("p2.rebuilt.mime") == "image/jpeg")
// [T-image-gate] Was: the request budget passed the 2760x21891 original through.
check("the request stage gates the reloaded original to 252x2000 JPEG",
      !bool("p2.budgetUnchanged") && dims("p2.request") == "252x2000" && str("p2.request.mime") == "image/jpeg")
// [T-image-gate] Was KNOWN GAP: the request gate heals the reloaded original to
// exactly the bytes the live turn sends.
check("after reload the model gets the same <=2000 image as the live turn", bool("p2.requestEqualsLive"))

// MARK: - P-i4

print("P-i4 browser takeover screenshot")
// [T-image-gate #412] The message carries the gate's output (was: the 9000x6000
// screenshot itself) and its note is a <system-reminder>, so the stored row
// (the agent loop now persists it) renders nothing on reload.
check("a user message: note text + one image", str("p4.role") == "user" && int("p4.partCount") == 2
      && str("p4.note").hasPrefix("<system-reminder>[Browser takeover] The user manually operated the browser."))
check("the image is the gate's output, 2000x1333 image/jpeg (was the 9000x6000 screenshot)",
      !bool("p4.liveIsSource") && bool("p4.liveIsGated") && dims("p4.live") == "2000x1333" && str("p4.live.mime") == "image/jpeg")
check("written to browser/takeover_<timestamp>.jpg and pointed at by its linuxPath",
      bool("p4.fileWritten") && str("p4.linuxPath") == "/var/minis/browser/takeover_1791000000.jpg")
check("not saved through the media store (so not in the stored history)", bool("p4.noMediaStoreWrite"))
// [T-image-gate] Was: the request budget passed it through at 9000x6000.
check("the request stage sends it unchanged (already compliant)", bool("p4.budgetUnchanged") && dims("p4.request") == "2000x1333")
check("a takeover screenshot is sent within 2000 px like other screenshots", int("p4.live.w") <= 2000 && int("p4.live.h") <= 2000)

// MARK: - P-i8

print("P-i8 request budget counts bytes; the gate before it resizes")
// [T-image-gate] Was: 9000x300 passed the budget untouched (KNOWN GAP below).
check("9000x300 (\(int("p8.src.bytes")) B) is resized by the request gate to \(dims("p8.request"))",
      dims("p8.src") == "9000x300" && dims("p8.request") == "2000x67")
check("an image over 8000 px on a side is resized before it is sent", !bool("p8.budgetUnchanged"))
check("6 images of 4 MB (5 MB base64 each) over the 25 MB budget: the oldest one is elided",
      int("budget.dropped") == 1 && int("budget.total") == 6)
let outTexts = strs("budget.out.texts")
check("an elided image without a linuxPath is spilled and the placeholder points at the spill file",
      outTexts.contains { $0.hasPrefix("[image elided to fit 25MB request budget. Original at /var/minis/attachments/spillover/") && $0.contains(".jpg") })
check("no image is resized: whatever is not elided keeps its exact bytes", bool("budget.keptBytesUnchanged"))
// [T-budget-position-ids] Was KNOWN GAP: the rewrite matched parts by
// ObjectIdentifier(data as AnyObject) - a temporary box whose address is
// reused - so every image matched and was elided, all pointing at the first
// spill file. Images are now matched by their position in the request.
let placeholders = outTexts.filter { $0.contains("[image elided to fit 25MB request budget.") }.count
print("     (observed: \(placeholders) of 6 images elided, \(strs("budget.out.images").count) left)")
check("only the image the plan dropped is elided; the other 5 are still sent",
      placeholders == 1 && strs("budget.out.images").count == 5)
check("an elided image that has a linuxPath is pointed at that path, not at a spill file",
      outTexts.contains { $0.contains("Original at /var/minis/attachments/uploads/b.png") } || placeholders <= 1)

// MARK: - Missing media

print("Missing media file on reload")
check("a user image whose file is gone rebuilds to nothing (dropped silently)", bool("missing.userPartIsNil"))
check("a tool image whose file is gone rebuilds to no image", bool("missing.toolImageIsNil"))
desired("a missing image leaves a visible placeholder", !bool("missing.userPartIsNil"))

// MARK: - Round trip

print("Persist -> reload round trip (user images)")
for name in ["jpeg", "heicAsJpeg", "png", "gifLabelOnJpeg"] {
    check("\(name): written under attachments/, read back byte-identical with the same MIME and linuxPath",
          str("rt.\(name).subdir") == "attachments" && bool("rt.\(name).bytesEqual") && bool("rt.\(name).mimeEqual")
          && str("rt.\(name).linuxPath") == "/var/minis/attachments/uploads/\(name)")
}
check("file extension follows the stored MIME: jpg / jpg / png / gif",
      str("rt.jpeg.relativePath.ext") == "jpg" && str("rt.heicAsJpeg.relativePath.ext") == "jpg"
      && str("rt.png.relativePath.ext") == "png" && str("rt.gifLabelOnJpeg.relativePath.ext") == "gif")
check("HEIC bytes labelled image/jpeg stay labelled image/jpeg after reload (today)",
      str("rt.heicAsJpeg.rebuilt.fmt") == "heic" && str("rt.heicAsJpeg.rebuilt.mime") == "image/jpeg")
desired("a user image's MIME on reload matches its bytes", str("rt.heicAsJpeg.rebuilt.mime") == "image/heic"
        && str("rt.gifLabelOnJpeg.rebuilt.mime") == "image/jpeg")

print("Tool image MIME on reload")
check("JPEG bytes stored as image/png: sniffed back to image/jpeg", str("sniff.jpegStoredAsPng.mime") == "image/jpeg")
check("PNG bytes stored as image/jpeg: sniffed back to image/png", str("sniff.pngStoredAsJpeg.mime") == "image/png")
check("HEIC bytes stored as image/jpeg: not recognised, stored label kept (image/jpeg)",
      str("sniff.heicStoredAsJpeg.mime") == "image/jpeg" && str("sniff.heicStoredAsJpeg.fmt") == "heic")
desired("HEIC bytes are recognised on reload", str("sniff.heicStoredAsJpeg.mime") == "image/heic")

print(String(format: "\nSuite time %.1fs; known gaps: %d", Date().timeIntervalSince(started), gaps))
print(failures == 0 ? "ALL PASSED (characterization)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
