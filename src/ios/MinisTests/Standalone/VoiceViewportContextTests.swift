#!/usr/bin/env swift
// [T-voice-viewport-context] Runs the ViewportContextBuilderTests XCTest cases from
// MinisTests/VoiceCorrectionTests.swift WITHOUT a simulator (the XCTest target needs the
// device-only libish_aot to link). It compiles the shipping
// Agent/Speech/CorrectionContextBuilder.swift together with that test class, a minimal
// XCTest shim and stubs for the builder's jieba / logging dependencies — so the code under
// test and the assertions are exactly the ones in the repo.
//
// Also pins the wiring the pure tests can't reach: the list capture, the context merge and
// the prompt blocks.
//
// Run: swift VoiceViewportContextTests.swift   (needs swiftc)
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

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

let builder = source("Agent/Speech/CorrectionContextBuilder.swift")
let tests = source("MinisTests/VoiceCorrectionTests.swift")
guard let start = tests.range(of: "final class ViewportContextBuilderTests: XCTestCase {") else {
    print("❌ ViewportContextBuilderTests not found"); exit(1)
}
let testClass = String(tests[start.lowerBound...])
let testNames: [String] = {
    let re = try! NSRegularExpression(pattern: #"func (test[A-Za-z0-9_]+)\(\)"#)
    let ns = testClass as NSString
    return re.matches(in: testClass, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}()

let shim = #"""
import Foundation
// Stubs for CorrectionContextBuilder.swift's dependencies (not exercised by these tests).
struct AppLogger {
    init(category: String) {}
    func info(_ s: @autoclosure () -> String) { print("    log:", s()) }
    func debug(_ s: @autoclosure () -> String) {}
    func warning(_ s: @autoclosure () -> String) {}
    func error(_ s: @autoclosure () -> String) {}
}
final class TextSegmenter: @unchecked Sendable {
    static let shared = TextSegmenter()
    func segment(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
}
enum SentenceSplitter { static func split(_ s: String) -> [String] { [s] } }
enum StopWords { static func contains(_ term: String) -> Bool { false } }
final class BackgroundWordFrequency: @unchecked Sendable {
    static let shared = BackgroundWordFrequency()
    func rank(of: String) -> Int? { nil }
}
// Minimal XCTest.
class XCTestCase { required init() {} }
var shimFailures = 0
private func fail(_ what: String, _ file: StaticString, _ line: UInt) {
    shimFailures += 1; print("    ✗ \(what) (line \(line))")
}
func XCTAssertTrue(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { if !e() { fail("XCTAssertTrue \(m())", file, line) } }
func XCTAssertFalse(_ e: @autoclosure () -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { if e() { fail("XCTAssertFalse \(m())", file, line) } }
func XCTAssertNil<T>(_ e: @autoclosure () -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { if let v = e() { fail("XCTAssertNil got \(v) \(m())", file, line) } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if x != y { fail("XCTAssertEqual \(x) != \(y) \(m())", file, line) } }
func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x < y) { fail("XCTAssertLessThan \(x) !< \(y) \(m())", file, line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x <= y) { fail("XCTAssertLessThanOrEqual \(x) !<= \(y) \(m())", file, line) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ m: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) { let x = a(), y = b(); if !(x > y) { fail("XCTAssertGreaterThan \(x) !> \(y) \(m())", file, line) } }
"""#

let main = "let t = ViewportContextBuilderTests()\n" + testNames.map { name in
    "do { let before = shimFailures; t.\(name)(); print(shimFailures == before ? \"RESULT pass \(name)\" : \"RESULT fail \(name)\") }"
}.joined(separator: "\n")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("viewport-ctx-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files: [(String, String)] = [("builder.swift", builder), ("shim.swift", shim), ("tests.swift", "import Foundation\n" + testClass), ("main.swift", main)]
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

print("1. ViewportContextBuilderTests (\(testNames.count) cases, shipping builder)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
check("shipping CorrectionContextBuilder.swift + test class compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
for line in out.split(separator: "\n") where line.contains("✗") { print(line) }
for name in testNames {
    check(name, out.contains("RESULT pass \(name)"))
}

print("\n2. Wiring")
let list = messageListV3Source()
let view = chatViewSource()
let strategy = source("Providers/Voice/CorrectionStrategy.swift")
let vmSrc = chatViewModelSource()
check("the list installs the capture hook on the view model",
      list.contains("vm.captureViewportSnapshot = { [weak self] in self?.captureViewportSnapshot() }")
      && vmSrc.contains("var captureViewportSnapshot: (() -> ViewportSnapshot?)?"))
check("capture reads layout attributes over two screens around the centre",
      list.contains("let window = CGRect(x: 0, y: center - height, width: max(cv.bounds.width, 1), height: height * 2)")
      && list.contains("cv.collectionViewLayout.layoutAttributesForElements(in: window)"))
check("the visible area excludes the bars and composer drawn over the list",
      list.contains("let visMin = cv.contentOffset.y + inset.top") && list.contains("let visMax = cv.contentOffset.y + cv.bounds.height - inset.bottom"))
check("tool rows use the capsule's title, thinking/info rows are skipped",
      list.contains("default: kind = .tool; text = b.toolSummary ?? b.toolDescription") && list.contains("case .thinking, .info: continue"))
check("the voice panel passes the snapshot when the correction runs",
      view.contains("viewport: vm.captureViewportSnapshot?())"))
check("the on-screen block is added next to the recent-turns block (both kept)",
      view.contains("var context = CorrectionContextBuilder.build(messages: source)")
      && view.contains("context.viewportLines = onScreen.lines") && view.contains("context.latestReply = onScreen.latestReply"))
check("the prompt carries both blocks and asks the model to reason from the screen",
      strategy.contains("以下是用户此刻在屏幕上看到的对话内容") && strategy.contains("尤其是用户此刻在屏幕上看到的对话内容")
      && strategy.contains("\"viewport\": viewportChars, \"latestReply\": latestReplyChars"))
check("a partly visible latest reply is labelled as the remainder",
      strategy.contains("未出现在上方屏幕内容里的部分"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
