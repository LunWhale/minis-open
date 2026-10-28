#!/usr/bin/env swift
// [T-voice-mixed-term-restore] Runs the voice-correction cases touched by this change
// WITHOUT a simulator (the XCTest target needs the device-only libish_aot to link):
// the whole CorrectionContextBuilderTests class and the testCharChangeRatio_* cases from
// MinisTests/VoiceCorrectionTests.swift, compiled against the shipping
// CorrectionContextBuilder.swift, VoiceCorrectionDiff.swift, VocabularyFilter.swift,
// SentenceSplitter.swift and the real VoiceCorrectionConfig, plus a minimal XCTest shim and
// stubs for jieba / logging.
//
// Also pins the prompt wording the pure tests can't reach.
//
// Run: swift VoiceMixedTermRestoreTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
/// The brace-balanced block starting at `header` (header line included).
func block(_ text: String, from header: String) -> String? {
    guard let r = text.range(of: header) else { return nil }
    var depth = 0
    var seenOpen = false
    var i = r.lowerBound
    while i < text.endIndex {
        let c = text[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" { depth -= 1 }
        i = text.index(after: i)
        if seenOpen && depth == 0 { return String(text[r.lowerBound..<i]) }
    }
    return nil
}

let tests = source("MinisTests/VoiceCorrectionTests.swift")
guard let builderTests = block(tests, from: "final class CorrectionContextBuilderTests: XCTestCase {") else {
    print("❌ CorrectionContextBuilderTests not found"); exit(1)
}
let ratioNames: [String] = {
    let re = try! NSRegularExpression(pattern: "func (testCharChangeRatio_\\w+)\\(\\)")
    let ns = tests as NSString
    return re.matches(in: tests, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}()
let ratioBodies = ratioNames.compactMap { block(tests, from: "    func \($0)()") }
let ratioClass = "final class CharChangeRatioTests: XCTestCase {\n" + ratioBodies.joined(separator: "\n") + "\n}\n"
let builderNames: [String] = {
    let re = try! NSRegularExpression(pattern: "func (test\\w+)\\(\\)")
    let ns = builderTests as NSString
    return re.matches(in: builderTests, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}()
guard let profileTests = block(tests, from: "final class CorrectionLanguageProfileTests: XCTestCase {"),
      let profileEnum = block(source("Providers/Voice/CorrectionStrategy.swift"), from: "enum CorrectionLanguageProfile:") else {
    print("❌ CorrectionLanguageProfile / its tests not found"); exit(1)
}
let profileNames: [String] = {
    let re = try! NSRegularExpression(pattern: "func (test\\w+)\\(\\)")
    let ns = profileTests as NSString
    return re.matches(in: profileTests, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}()
guard let config = block(source("Providers/Voice/CorrectionSignalSource.swift"), from: "enum VoiceCorrectionConfig {") else {
    print("❌ VoiceCorrectionConfig not found"); exit(1)
}

let shim = #"""
import Foundation
struct AppLogger {
    init(category: String) {}
    func info(_ s: @autoclosure () -> String) {}
    func debug(_ s: @autoclosure () -> String) {}
    func warning(_ s: @autoclosure () -> String) {}
    func error(_ s: @autoclosure () -> String) {}
}
// jieba stand-in: whitespace-separated tokens (the test texts are pre-spaced).
final class TextSegmenter: @unchecked Sendable {
    static let shared = TextSegmenter()
    func segment(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    func posTag(_ s: String) -> [(token: String, tag: String)] { [] }
}
class XCTestCase { required init() {} }
var shimFailures = 0
private func fail(_ what: String, _ line: UInt) { shimFailures += 1; print("    ✗ \(what) (line \(line))") }
func XCTFail(_ m: String = "", file: StaticString = #file, line: UInt = #line) { fail("XCTFail \(m)", line) }
func XCTAssertTrue(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { if !e() { fail("XCTAssertTrue \(m())", line) } }
func XCTAssertFalse(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { if e() { fail("XCTAssertFalse \(m())", line) } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if x != y { fail("XCTAssertEqual \(x) != \(y) \(m())", line) } }
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x < y) { fail("XCTAssertLessThan \(x) !< \(y) \(m())", line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x <= y) { fail("XCTAssertLessThanOrEqual \(x) !<= \(y) \(m())", line) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x > y) { fail("XCTAssertGreaterThan \(x) !> \(y) \(m())", line) } }
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x >= y) { fail("XCTAssertGreaterThanOrEqual \(x) !>= \(y) \(m())", line) } }
"""#

func runner(_ cls: String, _ names: [String]) -> String {
    "do { let t = \(cls)()\n" + names.map { name in
        "do { let before = shimFailures; t.\(name)(); print(shimFailures == before ? \"RESULT pass \(name)\" : \"RESULT fail \(name)\") }"
    }.joined(separator: "\n") + "\n}\n"
}
let main = runner("CorrectionContextBuilderTests", builderNames) + runner("CharChangeRatioTests", ratioNames)
    + runner("CorrectionLanguageProfileTests", profileNames)

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-term-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files: [(String, String)] = [
    ("builder.swift", source("Agent/Speech/CorrectionContextBuilder.swift")),
    ("diff.swift", source("Agent/Speech/VoiceCorrectionDiff.swift")),
    ("vocab.swift", source("Agent/Speech/VocabularyFilter.swift")),
    ("splitter.swift", source("Shared/SentenceSplitter.swift")),
    ("config.swift", "import Foundation\n" + config),
    ("profile.swift", "import Foundation\n" + profileEnum + """

        enum PhoneticNormalizerRegistry {
            static func normalizedLocaleKey(_ locale: String) -> String {
                String(locale.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            }
        }
        """),
    ("shim.swift", shim),
    ("tests.swift", "import Foundation\n" + builderTests + "\n" + ratioClass + "\n" + profileTests),
    ("main.swift", main),
]
for (name, text) in files { try text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

print("1. CorrectionContextBuilderTests (\(builderNames.count)) + charChangeRatio (\(ratioNames.count)) + CorrectionLanguageProfileTests (\(profileNames.count)), shipping sources")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("shipping sources + test classes compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
for line in out.split(separator: "\n") where line.contains("✗") { print(line) }
for name in builderNames + ratioNames + profileNames {
    check(name, out.contains("RESULT pass \(name)"))
}

print("\n2. Prompt")
let strategy = source("Providers/Voice/CorrectionStrategy.swift")
check("system prompt states the setting: a voice message to the agent, answering what it offered",
      strategy.contains("the user is talking to an AI agent in a chat app by voice")
      && strategy.contains("picking one of the options it offered"))
check("system prompt = shared contract + setting + method, failure modes per language",
      strategy.contains("static func systemPrompt(for profile: CorrectionLanguageProfile) -> String")
      && strategy.contains("\\(profile.failureModes)")
      && strategy.contains("Restore the term itself; never translate it"))
check("the live call and the prompt use the same resolved profile",
      strategy.contains("let profile = CorrectionLanguageProfile.resolve(locale: locale, transcript: transcript)")
      && strategy.contains("systemPrompt: Self.systemPrompt(for: profile)")
      && strategy.contains("context: context, profile: profile, diagnostics: diagnostics)"))
check("the user-prompt lead names proper nouns (Chinese or English), not just homophones",
      strategy.contains("被识别成普通词或音译汉字的专有名词（中文或英文")
      && !strategy.contains("同音字/识别错误"))
check("the lead frames the transcript as a message to the AI",
      strategy.components(separatedBy: "推断用户这句要发给 AI 的话的整体意图").count == 3)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
