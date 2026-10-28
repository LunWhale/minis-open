#!/usr/bin/env swift
// [T-image-real-seams] iOS-A: user-attachment images, through the REAL function.
//
// send() and the queued-prompt path (processAttachments) now share
// `AIChatViewModel.inlineAttachmentImage(_:ext:route:)` and
// `attachmentImageOverflowsMessage(cumulativeImageBytes:compressedB64:)`, defined
// between `// BEGIN InlineAttachmentImage` / `// END InlineAttachmentImage` in
// AIChatViewModel+Send.swift. This driver compiles that block VERBATIM
// (no anchor slicing of the logic under test) and runs it on generated
// images: S3 (camera), S4 (photo-library picks), S6 (queue vs send), P-i5 and
// the live half of P-i7.
//
// The function's own dependencies live in files outside iOS-A's scope
// (AIChatViewModel+Misc.swift, +RequestBudget.swift, AIChatViewModel.swift), so
// they are lifted from the current source by declaration and compiled next
// to it: resizedImageData, compressedImageDataUnderBudget, jpegEncode,
// downsampledCameraJPEG, estimatedBase64Length, rawBytesForBase64Budget,
// kPerImageMaxBytes, kMessageImageMaxBytes. A missing declaration fails as
// DRIFT. They are AIChatViewModel statics, so the harness supplies an empty
// `AIChatViewModel` class to hang them on.
//
// Characterization assertions pin today's behaviour (including the two route
// differences, which this round must not change); desired behaviour that is
// still missing is reported as KNOWN GAP and does not fail the run.
//
// Built for Mac Catalyst (UIKit / ImageIO as on iOS). Cached by content hash.
// Run: swift src/ios/MinisTests/Standalone/ImageRealIosATests.swift
// IOSA_JSON=<path> exports every measured value.
import Foundation
import CryptoKit

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

/// The text between BEGIN/END markers, markers included.
func block(_ src: String, _ name: String) -> String? {
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else { return nil }
    return String(src[b.lowerBound..<e.upperBound])
}

/// A declaration starting at the line containing `signature`: one line for a
/// `let`, through the matching brace for a func (strings and comments skipped).
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

// MARK: - Assemble the program from the current source

let attachments = source("Agent/Chat/AIChatViewModel+Attachments.swift")
let send = source("Agent/Chat/AIChatViewModel+Send.swift")
let misc = source("Agent/Chat/AIChatViewModel+Misc.swift")
let budget = source("Agent/Chat/AIChatViewModel+RequestBudget.swift")
let vm = source("Agent/Chat/AIChatViewModel.swift")

print("Real function and wiring")
guard let real = block(send, "InlineAttachmentImage") else {
    print("  ❌ DRIFT: BEGIN/END InlineAttachmentImage not found in AIChatViewModel+Send.swift"); exit(1)
}
check("send() inlines through the shared function, send route",
      send.contains("Self.inlineAttachmentImage(data, ext: ext, route: .send)"))
check("send() takes resized / final / MIME from it",
      send.contains("let resized = inline.resized") && send.contains("let compressed = inline.final")
      && send.contains("let mime = inline.mimeType"))
check("send() applies the message budget through the shared check",
      send.contains("Self.attachmentImageOverflowsMessage(cumulativeImageBytes: cumulativeImageBytes, compressedB64: compressedB64)"))
check("processAttachments inlines through the same function, queue route",
      attachments.contains("let inline = Self.inlineAttachmentImage(data, ext: ext, route: .queue)"))
check("no second copy of the resize call is left in either path",
      send.components(separatedBy: "resizedImageData(data, maxLongEdge: 2000)").count == 2
      && !attachments.contains("resizedImageData(data, maxLongEdge: 2000)"))

let deps: [(String, String, String)] = [
    ("misc", misc, "static func resizedImageData("),
    ("misc", misc, "static func compressedImageDataUnderBudget("),
    ("misc", misc, "static func downsampledCameraJPEG("),
    ("budget", budget, "static func jpegEncode("),
    ("vm", vm, "static func estimatedBase64Length("),
    ("vm", vm, "static func rawBytesForBase64Budget("),
    ("vm", vm, "static let kPerImageMaxBytes"),
    ("vm", vm, "static let kMessageImageMaxBytes"),
]
var lifted: [String] = []
for (file, src, sig) in deps {
    guard let d = declaration(src, sig) else { print("  ❌ DRIFT: \(sig) not found (\(file))"); exit(1) }
    lifted.append(d)
}

let depsSwift = """
import Foundation
import UIKit
final class AIChatViewModel {}
extension AIChatViewModel {
\(lifted.joined(separator: "\n\n"))
}
"""
let realSwift = "import Foundation\nimport UIKit\n\n" + real + "\n"
let fixtures = (try? String(contentsOf: here.appendingPathComponent("ImageRealIosA/Fixtures.swift"), encoding: .utf8)) ?? ""
let scenarios = (try? String(contentsOf: here.appendingPathComponent("ImageRealIosA/Scenarios.swift"), encoding: .utf8)) ?? ""
guard !fixtures.isEmpty, !scenarios.isEmpty else { print("  ❌ ImageRealIosA/ helper files missing"); exit(1) }

// MARK: - Build (cached by content hash) and run

let sdk = sh(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
let catalyst = ["-D", "IMAGE_REAL_IOS_A", "-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                "-Fsystem", "\(sdk)/System/iOSSupport/System/Library/Frameworks",
                "-L", "\(sdk)/System/iOSSupport/usr/lib"]
let files = ["deps.swift": depsSwift, "real.swift": realSwift, "Fixtures.swift": fixtures,
             "Scenarios.swift": scenarios, "main.swift": "runScenarios()\n"]
let digest = SHA256.hash(data: Data((files.sorted { $0.key < $1.key }.map { $0.key + $0.value } + catalyst).joined().utf8))
    .prefix(8).map { String(format: "%02x", $0) }.joined()
let work = FileManager.default.temporaryDirectory.appendingPathComponent("minis-image-real-iosA-\(digest)")
let bin = work.appendingPathComponent("run")
let started = Date()
if !FileManager.default.fileExists(atPath: bin.path) {
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    for (name, text) in files { try! text.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    let (status, out) = sh(["xcrun", "swiftc"] + catalyst + ["-O", "-suppress-warnings"]
                           + files.keys.sorted().map { work.appendingPathComponent($0).path } + ["-o", bin.path])
    if status != 0 { print(out); print("  ❌ compile failed"); exit(1) }
}
let jsonURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IOSA_JSON"] ?? work.appendingPathComponent("results.json").path)
let (runStatus, runOut) = sh([bin.path, jsonURL.path])
guard runStatus == 0, let raw = try? Data(contentsOf: jsonURL),
      let m = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    print(runOut); print("  ❌ harness run failed"); exit(1)
}
func int(_ k: String) -> Int { m[k] as? Int ?? -1 }
func str(_ k: String) -> String { m[k] as? String ?? "?" }
func bool(_ k: String) -> Bool { m[k] as? Bool ?? false }
func dims(_ k: String) -> String { "\(int("\(k).w"))x\(int("\(k).h"))" }

// MARK: - S3 camera (P-i7 live half)

print("S3 camera 4032x3024 -> downsampledCameraJPEG -> attachment")
check("capture downsampled to 2560x1920 JPEG", dims("s3.src") == "2560x1920" && str("s3.src.fmt") == "jpeg")
check("send route: 2000x1500 JPEG, image/jpeg", dims("s3.send") == "2000x1500" && str("s3.send.fmt") == "jpeg" && str("s3.send.mime") == "image/jpeg")
check("queue route: same bytes as send", str("s3.queue.sha256") == str("s3.send.sha256") && str("s3.queue.mime") == "image/jpeg")

// MARK: - S4 photo-library picks (send route)

print("S4 photo-library picks (send route)")
check("JPEG 4032x3024 -> 2000x1500 JPEG", dims("s4.jpeg.send") == "2000x1500" && str("s4.jpeg.send.mime") == "image/jpeg")
check("HEIC 4032x3024 -> re-encoded 2000x1500 JPEG, image/jpeg",
      dims("s4.heic.send") == "2000x1500" && str("s4.heic.send.fmt") == "jpeg" && str("s4.heic.send.mime") == "image/jpeg")
check("small HEIC 1200x900 passes through as HEIC bytes labelled image/jpeg (today)",
      bool("s4.heicSmall.send.finalIsSource") && str("s4.heicSmall.send.fmt") == "heic" && str("s4.heicSmall.send.mime") == "image/jpeg")
desired("small HEIC is labelled with the type its bytes are", str("s4.heicSmall.send.mime") == "image/heic" || str("s4.heicSmall.send.fmt") == "jpeg")
check("EXIF orientation 6 comes out upright 1500x2000", dims("s4.exif6.send") == "1500x2000")
check("transparent PNG 512 passes through as PNG, image/png, alpha kept",
      bool("s4.png.send.finalIsSource") && str("s4.png.send.mime") == "image/png" && bool("s4.png.send.alpha"))
check("transparent PNG 3000 -> 2000x2000 JPEG, alpha lost (today)",
      dims("s4.pngBig.send") == "2000x2000" && str("s4.pngBig.send.fmt") == "jpeg" && !bool("s4.pngBig.send.alpha")
      && str("s4.pngBig.send.mime") == "image/jpeg")
desired("a large transparent PNG keeps its transparency", bool("s4.pngBig.send.alpha"))

// MARK: - S6 queue vs send (P-i5)

print("S6 queue vs send")
check("same JPEG: both routes produce identical bytes", bool("s6.jpeg.identical"))
check("GIF 2400x1800: both routes output 2000x1500 JPEG bytes", dims("s6.gif.send") == "2000x1500"
      && str("s6.gif.send.fmt") == "jpeg" && str("s6.gif.queue.sha256") == str("s6.gif.send.sha256"))
check("GIF: send route labels it image/jpeg", str("s6.gif.send.mime") == "image/jpeg")
check("GIF: queue route still labels the JPEG bytes image/gif (P-i5, today)", str("s6.gif.queue.mime") == "image/gif")
desired("queue route labels resized GIF/WebP output with its real type", str("s6.gif.queue.mime") == "image/jpeg")
let ladder = int("ladderTargetRaw")
check("noisy 2000x2000 q1.0 JPEG source is over the ladder target", int("s6.noisy.src.bytes") > ladder)
check("noisy: send route runs the compressor ladder under the target",
      int("s6.noisy.send.bytes") <= ladder && str("s6.noisy.send.mime") == "image/jpeg")
check("noisy: queue route sends the source bytes unchanged (P-i5, no ladder today)",
      bool("s6.noisy.queue.finalIsSource") && int("s6.noisy.queue.bytes") == int("s6.noisy.src.bytes"))
desired("queue route also fits images under the per-image budget", int("s6.noisy.queue.bytes") <= ladder)

// MARK: - Message budget (send route)

print("Per-message budget (send route)")
check("exactly at the 25 MB message budget still inlines", !bool("budget.atCap"))
check("one byte over the message budget drops to a placeholder", bool("budget.overCap"))

// MARK: - Table

print("\nOutputs (real function)")
let rows = ["s3.send", "s3.queue", "s4.jpeg.send", "s4.heic.send", "s4.heicSmall.send", "s4.exif6.send",
            "s4.png.send", "s4.pngBig.send", "s6.jpeg.send", "s6.jpeg.queue", "s6.gif.send", "s6.gif.queue",
            "s6.noisy.send", "s6.noisy.queue"]
for k in rows {
    let pad = k.padding(toLength: 18, withPad: " ", startingAt: 0)
    print("  \(pad) \(dims(k).padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(int("\(k).bytes")).padding(toLength: 9, withPad: " ", startingAt: 0)) \(str("\(k).fmt").padding(toLength: 5, withPad: " ", startingAt: 0)) \(str("\(k).mime").padding(toLength: 11, withPad: " ", startingAt: 0)) \(str("\(k).sha256").prefix(16))")
}

print(String(format: "\nSuite time %.1fs; known gaps: %d", Date().timeIntervalSince(started), gaps))
print(failures == 0 ? "ALL PASSED (characterization)" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
