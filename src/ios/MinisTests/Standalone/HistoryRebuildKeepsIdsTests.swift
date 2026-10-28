#!/usr/bin/env swift
// [T-history-rebuild-keeps-ids] Editing a message in `agentHistory` must keep
// its identity fields. Three sites rebuilt the message with
// `AgentMessage(role:parts:…)`, whose defaults reset `dbMessageId` (and
// `reasoningEcho`) to nil:
//   - trimOldImagesFromHistory (image eviction, > 20 images in context)
//   - retry()'s orphan tool_result cleanup
//   - the in-loop orphan tool_result sweep
// When the edited message was the v2 compaction anchor, the anchor lookup by
// dbMessageId failed and effectiveAgentHistory fell back to the full history —
// the compaction silently undone — and the offload scan restarted at index 0.
//
// Run: swift HistoryRebuildKeepsIdsTests.swift
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

// Model of the bug: a memberwise rebuild vs an in-place parts edit.
struct Msg { var parts: [String]; var reasoningEcho: String? = nil; var dbMessageId: String? = nil }
var anchor = Msg(parts: ["text", "image"], reasoningEcho: "enc", dbMessageId: "ANCHOR")
let rebuilt = Msg(parts: ["text", "[image placeholder]"])
check("OLD: rebuilding drops the anchor id (lookup would fail)", rebuilt.dbMessageId == nil)
anchor.parts = ["text", "[image placeholder]"]
check("NEW: in-place edit keeps dbMessageId", anchor.dbMessageId == "ANCHOR")
check("NEW: in-place edit keeps reasoningEcho", anchor.reasoningEcho == "enc")

print("\nsource")
let off = source("Agent/Chat/AIChatViewModel+Offloading.swift")
let vm = source("Agent/Chat/AIChatViewModel.swift")
check("image eviction edits parts in place", off.contains("agentHistory[mi].parts = newParts"))
check("retry cleanup edits parts in place", vm.contains("agentHistory[i].parts = cleaned  // [T-history-rebuild-keeps-ids]"))
check("in-loop orphan sweep edits parts in place", vm.contains("agentHistory[i].parts = cleanedParts  // [T-history-rebuild-keeps-ids]"))
let rebuildPattern = try! NSRegularExpression(pattern: #"agentHistory\[[A-Za-z_]+\]\s*=\s*AgentMessage\("#)
for (name, text) in [("Offloading", off), ("AIChatViewModel", vm)] {
    let n = rebuildPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    check("no `agentHistory[i] = AgentMessage(` rebuild left in \(name) (found \(n))", n == 0)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
