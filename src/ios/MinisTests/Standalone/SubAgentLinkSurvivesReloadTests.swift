#!/usr/bin/env swift
// [T-subagent-link-survives-reload] The sub agent card keeps its link to the
// child session across a reload of the parent conversation.
//
// Field log (TestFlight 1.15, 2026-09-26): the transcript button worked at
// 03:12:38 and 03:12:54 (`child=133260BB`); an iCloud catch-up reloaded the
// parent from the DB at 03:13:02; three taps after that logged `child=nil`
// and did nothing ("子助理详情还经常点不开"). The link
// (`helperChildSessionId`) lives only on the in-memory block, and the
// progress mirror overwrites the reloaded block's content with a progress
// line, so the stored JSON's `child_session_id` could not be parsed either.
// Reproduced and verified on iPhone 11: reload → "re-attached child … after a
// parent reload" within 1 s → tap logs `linked=true`, transcript opens.
//
// Run: swift SubAgentLinkSurvivesReloadTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

/// Model of the block + the 1 s progress mirror.
struct Block { var childLink: String?; var content: String }
func tapResolves(_ b: Block) -> String? {
    if let l = b.childLink { return l }
    if b.content.hasPrefix("{"), let r = b.content.range(of: "\"child_session_id\":\"") {
        return String(b.content[r.upperBound...].prefix(8))
    }
    return nil
}
func run(reattach: Bool) -> String? {
    var b = Block(childLink: "133260BB", content: "{\"child_session_id\":\"133260BB\"}")
    b = Block(childLink: nil, content: "{\"child_session_id\":\"133260BB\"}")   // parent reloaded from DB
    b.content = "Agent · running · shell 12s"                                // mirror tick
    if reattach { b.childLink = "133260BB" }                                   // NEW: same tick re-attaches
    return tapResolves(b)
}
print("══ [1] reload while the child runs ══")
check("OLD: link gone after the reload + one mirror tick → tap does nothing", run(reattach: false) == nil)
check("NEW: the mirror tick re-attaches the link → tap opens the child", run(reattach: true) == "133260BB")

print("\n══ [2] source ══")
let runner = source("Agent/Jobs/HelperRunner.swift")
let reg = source("Agent/Jobs/AgentJobRegistry.swift")
let tls = source("Views/Chat/ToolLiveSheet.swift")
let sheet = source("Views/Chat/HelperSheet.swift")
check("re-attach helper exists and writes only on change",
      runner.contains("func reattachHelperBlock(toolUseId: String, childId: String, agentName: String?) {")
      && runner.contains("if block.helperChildSessionId != childId {"))
check("background mirror re-attaches every tick",
      runner.contains("self.reattachHelperBlock(toolUseId: toolUseId, childId: childId, agentName: job.subAgentName)"))
check("wait-mode progress loop re-attaches too",
      runner.contains("                reattachHelperBlock(toolUseId: toolUseId, childId: childId, agentName: job.subAgentName)"))
check("registry can find the live child by the parent's tool_use id",
      reg.contains("func childSessionId(forToolUseId toolUseId: String) -> String? {"))
check("transcript button: link → stored JSON → live job, and a non-nil miss is logged",
      tls.contains("?? block.toolUseId.flatMap { AgentJobRegistry.shared.childSessionId(forToolUseId: $0) }")
      && tls.contains("[agent] transcript button: no child session for tool="))
check("diagnostics: nested sheet set, transcript task start / loaded / disappear",
      tls.contains("[agent] nested sheet →") && sheet.contains("[agent] transcript task start child=")
      && sheet.contains("[agent] transcript loaded child=") && sheet.contains("[agent] transcript disappear child="))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
