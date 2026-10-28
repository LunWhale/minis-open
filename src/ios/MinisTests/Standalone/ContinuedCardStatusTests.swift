#!/usr/bin/env swift
// [T-bka-continued-card-status] The iOS 26 continued-processing card (the
// system banner shown while a run holds the app in the background) says what
// the run is doing, like the Live Activity: "Thinking deeply…", "Replying…",
// or the tool and its title, with the session count when several run. Task
// Status Privacy keeps the old content-free text.
//
//   [1] subtitle rules (ContinuedCardStatus compiled standalone)
//   [2] source guards: privacy branch, newest active session, thinking is
//       reported to the tracker, Always On names it, strings localized
//
// Run: swift ContinuedCardStatusTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let bka = source("Agent/Background/BackgroundKeepAliveManager.swift")
guard let block = between(bka, "// BEGIN ContinuedCardStatus", "// END ContinuedCardStatus") else {
    print("❌ ContinuedCardStatus block not found"); exit(1)
}

print("[1] subtitle rules")
let harness = """
import Foundation
\(block)
var fails = 0
func CHECK(_ l: String, _ c: Bool) { print(c ? "  ✅ \\(l)" : "  ❌ \\(l)"); if !c { fails += 1 } }
// Fake localization: mark every lookup so the test sees which key was used.
let L: (String) -> String = { "<\\($0)>" }
func T(_ n: String, _ s: String) -> String { ContinuedCardStatus.text(toolName: n, toolStatus: s, localize: L) }
CHECK("no tool yet: Working", T("", "") == "<Working…>")
CHECK("thinking", T("thinking", "") == "<Thinking deeply…>")
CHECK("reply: the 'streaming' token never shows", T("text", "streaming") == "<Replying…>")
CHECK("known tool + title", T("shell_execute", "Build the project") == "<Shell> · Build the project")
CHECK("known tool, no title", T("browser_use", "") == "<Browser>")
CHECK("unknown tool shows its title alone", T("web_search", "Apple Q4 results") == "Apple Q4 results")
CHECK("unknown tool, no title: Working", T("web_search", " ") == "<Working…>")
CHECK("multi-line title is one line", T("file_edit", "a\\nb") == "<Edit File> · a b")
let long = String(repeating: "x", count: 100)
CHECK("long title cut with an ellipsis", T("file_read", long) == "<Read File> · " + String(repeating: "x", count: 60) + "…")
CHECK("one session: status alone", ContinuedCardStatus.subtitle(status: "S", sessionCount: 1, localize: L) == "S")
CHECK("several sessions: count prefix", ContinuedCardStatus.subtitle(status: "S", sessionCount: 3, localize: { $0 }) == "3 sessions · S")
exit(fails == 0 ? 0 : 1)
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("card-status-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("status block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("status checks all pass", status == 0 && !out.contains("❌"))
}

print("[2] source guards")
let card = between(bka, "private func continuedCardText()", "var continuedTaskRunning") ?? ""
check("privacy keeps the content-free copy", card.contains("if liveActivityPrivacyMode {")
      && card.contains("AppLocalized(\"1 session running, please don't stop\")"))
check("status comes from the most recently active running session",
      card.contains(".filter { tracker.activeSessions.contains($0.key) }")
      && card.contains(".max { $0.value.lastActivity < $1.value.lastActivity }"))
check("submit and every tick use the same text",
      bka.components(separatedBy: "continuedCardText()").count - 1 >= 3)
let sse = source("Agent/Chat/AIChatViewModel+SSEStream.swift")
check("a new thinking block reports 'thinking' to the tracker",
      (between(sse, "AssistantBlock(kind: .thinking, content: \"\")", "currentThinkingBlockIdx = idx") ?? "")
        .contains("updateToolInfo(sessionId: sid, toolName: \"thinking\", toolStatus: \"\")"))
let overlay = source("Views/Chat/AlwaysOnOverlay.swift")
check("Always On names thinking too", overlay.contains("if s.toolName == \"thinking\" { return AppLocalized(\"Thinking deeply…\") }"))
let catalog = source("Localizable.xcstrings")
for key in ["Thinking deeply…", "Replying…", "Working…", "Shell", "Read File", "Write File", "Edit File", "Read Image",
            "Browser", "Memory", "Code", "%lld sessions · %@"] {
    guard let entry = between(catalog, "\"\(key)\" : {", "\n    },") else { check("localized: \(key)", false); continue }
    check("localized zh-Hans + zh-Hant: \(key)", entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\""))
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
