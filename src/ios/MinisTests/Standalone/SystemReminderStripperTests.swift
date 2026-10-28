#!/usr/bin/env swift
// [T-user-bubble-reminder-strip] A user's bubble showed the note meant for the
// model: the answer to a deferred user_ask arrives as a user message ending in
// <system-reminder>…</system-reminder>, and the live bubble printed it (the
// reload path already stripped it, case-sensitively and only when closed).
//
//   [1] the shipping SystemReminderStripper (BEGIN/END block in
//       RawMessage+Conversion.swift), compiled standalone: single, several,
//       multi-line, any case, unclosed, nested, stray close, no tag, answer
//       lines kept, the attached-files block, non-ASCII around tags
//   [2] source guards: one implementation, used by the bubble, its height
//       measurement, the reload conversion, the session preview and search;
//       the message sent to the model still carries the reminder
//
// Run: swift SystemReminderStripperTests.swift   (needs swiftc)
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

let conversion = source("Agent/Chat/RawMessage+Conversion.swift")
guard let block = between(conversion, "// BEGIN SystemReminderStripper", "// END SystemReminderStripper") else {
    print("❌ SystemReminderStripper block not found"); exit(1)
}

// Cases: name ⇒ (input, expected strip(), expected userBubbleText()).
let harness = #"""
import Foundation
let cases: [(String, String)] = [
  ("single", "1. 「重试」点击这一步怎么验证？ → 不用验证了吧，直接 archive 打包吧。\n<system-reminder>These are the user's answers to the user_ask card you showed earlier (its result above now holds them). Continue from here.</system-reminder>"),
  ("deferred", "1. Which env? → Staging\n2. Push? → Allowed once\n<system-reminder>The user's answers to your earlier question card.</system-reminder>"),
  ("several", "a<system-reminder>x</system-reminder>b<system-reminder>y</system-reminder>c"),
  ("multiline", "keep\n<system-reminder>\nline one\nline two\n</system-reminder>\nafter"),
  ("upper", "ans<SYSTEM-REMINDER>shout</SYSTEM-REMINDER>end"),
  ("mixed", "ans<System-Reminder >mixed</system-REMINDER>end"),
  ("unclosed", "answer line\n<system-reminder>note cut mid-stre"),
  ("nested", "a<system-reminder>o<system-reminder>i</system-reminder>o2</system-reminder>b"),
  ("stray_close", "text</system-reminder> more"),
  ("none", "plain <b>html</b> and a < b > c, 3 < 4"),
  ("lookalike", "<system-reminders>not ours</system-reminders> <system-remind>x</system-remind>"),
  ("empty_after", "<system-reminder>only a note</system-reminder>"),
  ("attached", "<user-attached-files>\n<file path=\"/a.png\"/>\n</user-attached-files>\nlook at this\n<system-reminder>n</system-reminder>"),
  ("cjk_around", "前<system-reminder>中</system-reminder>后🙂"),
]
for (k, s) in cases {
    let a = SystemReminderStripper.strip(s)
    let b = SystemReminderStripper.userBubbleText(s)
    let enc = { (x: String) in x.replacingOccurrences(of: "\n", with: "\\n") }
    print("R \(k).strip=\(enc(a))")
    print("R \(k).bubble=\(enc(b))")
    print("R \(k).same=\(a == s)")
}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-strip-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Stripper.swift", "import Foundation\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping SystemReminderStripper compiles standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    guard let eq = body.firstIndex(of: "=") else { continue }
    r[String(body[..<eq])] = String(body[body.index(after: eq)...])
}

print("\n1. What a bubble shows")
check("the reported answer: only the answer line remains",
      r["single.bubble"] == "1. 「重试」点击这一步怎么验证？ → 不用验证了吧，直接 archive 打包吧。")
check("the deferred-answer shape (UserAskDeferred.answerMessage): both answer lines, no note",
      r["deferred.bubble"] == "1. Which env? → Staging\\n2. Push? → Allowed once")
check("several tags", r["several.strip"] == "abc")
check("a tag spanning lines", r["multiline.bubble"] == "keep\\n\\nafter")
check("UPPER-case tags", r["upper.strip"] == "ansend")
check("mixed case, space before >", r["mixed.strip"] == "ansend")
check("unclosed (stream cut): from the tag to the end goes, the answer stays", r["unclosed.bubble"] == "answer line")
check("nested: the whole outer region goes", r["nested.strip"] == "ab")
check("a stray closing tag goes alone", r["stray_close.strip"] == "text more")
check("no tag: returned unchanged (same string)", r["none.same"] == "true")
check("look-alike tags (system-reminders, system-remind) are not touched", r["lookalike.same"] == "true")
check("a message that is only a note shows nothing", r["empty_after.bubble"] == "")
check("the attached-files block and the note both go", r["attached.bubble"] == "look at this")
check("non-ASCII around tags survives intact", r["cjk_around.strip"] == "前后🙂")

print("\n2. One implementation, every display path")
check("RawMessage.stripSystemReminders delegates to it (no second regex)",
      conversion.contains("static func stripSystemReminders(_ text: String) -> String {\n        SystemReminderStripper.strip(text)\n    }")
      && !conversion.contains("systemReminderRe"))
check("the user bubble uses userBubbleText",
      source("Views/Chat/ChatMessageViews.swift").contains("SystemReminderStripper.userBubbleText(message.content)"))
check("the bubble's height measurement uses the same text",
      messageListV3Source().contains("let text = SystemReminderStripper.userBubbleText(message.content)"))
check("reload conversion strips user rows through it", conversion.contains("displayStr = Self.stripSystemReminders(displayStr)"))
check("session preview and search go through it",
      source("Agent/Chat/ChatStore+SessionList.swift").contains("RawMessage.stripSystemReminders(t)")
      && source("Agent/Chat/ChatStore+Search.swift").contains("RawMessage.stripSystemReminders(t)"))
check("display only: the deferred answer sent to the model still carries its reminder",
      source("Agent/Chat/UserAskCore.swift").contains("<system-reminder>The user's answers to your earlier question card.</system-reminder>"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
