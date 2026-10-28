#!/usr/bin/env swift
// [T-invisible-user-row-merge] On reload, loadSession merges one agent run's
// assistant rows into a single ChatMessage and breaks the chain at a real user
// message. The app's own mid-loop persona reminder is persisted as a separate
// user row ("<system-reminder>[Minis runtime reminder] …") that renders
// nothing, yet it broke the chain: the run came back as two assistant messages
// with nothing visible between them, and per-message tool-call folding saw two
// halves (field session 20A89273, rows 69–76: tool, remark, tool, tool |
// reminder | remark, tool, reply — neither half reached two tools).
//
// Source guards on the merge loop, plus a port of the chain rule run over that
// session's row shape.
//
// Run: swift InvisibleUserRowMergeTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let src = (try? String(contentsOf: root.appendingPathComponent("Agent/Chat/AIChatViewModel+Persistence.swift"), encoding: .utf8)) ?? ""
check("source readable", !src.isEmpty)

print("▶️  merge loop order")
let skip = src.range(of: "// [T-invisible-user-row-merge]")
let breakLog = src.range(of: "// Real user message — finalize any pending assistant and start fresh")
let reset = src.range(of: "            currentAssistant = nil\n            msg.sourceSortOrder = raw.sortOrder")
check("the invisible-row skip exists", skip != nil)
check("it runs BEFORE the chain break (log + currentAssistant = nil)",
      skip != nil && breakLog != nil && reset != nil
      && skip!.lowerBound < breakLog!.lowerBound && breakLog!.lowerBound < reset!.lowerBound)
if let skip, let breakLog {
    let block = String(src[skip.lowerBound..<breakLog.lowerBound])
    check("same 'renders nothing' rule as before: no text, no attachments, no blocks",
          block.contains("msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,")
          && block.contains("msg.attachments.isEmpty,") && block.contains("msg.blocks.isEmpty {"))
    check("its tool results reach the open message's calls (tool result + hidden note rows)",
          block.contains("if let assistant = currentAssistant {\n                    Self.applyToolResults(from: raw, to: assistant, mediaResolver: resolver)\n                }\n                continue"))
}
if let breakLog, let end = src.range(of: "loadedUIMessages.append(msg)\n        }", range: breakLog.upperBound..<src.endIndex) {
    check("the message is built once: no second toChatMessage after the break",
          !src[breakLog.upperBound..<end.lowerBound].contains("raw.toChatMessage("))
} else { check("break-to-append span found", false) }

print("\n▶️  chain rule over the field session's shape")
// Row kinds: A = assistant, R = tool-result-only user row, I = invisible user
// row (renders nothing), U = visible user message. Returns the number of
// assistant UI messages, fixed vs old rule.
func assistantMessages(_ rows: String, skipInvisibleFirst: Bool) -> Int {
    var count = 0, open = false
    for r in rows {
        switch r {
        case "A": if !open { count += 1; open = true }
        case "R": continue
        case "I": if skipInvisibleFirst { continue }; open = false   // old: break, then skip
        default: open = false
        }
    }
    return count
}
let field = "UARARIARA"   // 68 user, 69 A, 70 R, 71 A, 72 R, 73 reminder, 74 A, 75 R, 76 A
check("old rule: the reminder split the run into 2 messages", assistantMessages(field, skipInvisibleFirst: false) == 2)
check("fixed: one run, one message", assistantMessages(field, skipInvisibleFirst: true) == 1)
check("a visible user message still starts a new turn", assistantMessages("UARAUARA", skipInvisibleFirst: true) == 2)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
