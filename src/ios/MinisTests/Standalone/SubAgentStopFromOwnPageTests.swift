#!/usr/bin/env swift
// [T-subagent-stop-from-own-page] Stopping a sub agent from its own page must
// behave like stopping it from its card: no "cancelled" callback wakes the
// parent. Field-reproduced on iPhone 11 (2026-09-26): cancelling sub agent B1
// on its own session woke the parent with `status="cancelled"` and started a
// new parent turn — the path a model uses to re-delegate what the user stopped.
//
// Run: swift SubAgentStopFromOwnPageTests.swift
import Foundation

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

/// Model: a job's callback wakes the parent unless it was cancelled silently
/// (then = none) or the parent is muted.
struct World {
    var thenArmed = true, parentMuted = false, parentWoken = false
    mutating func childLoopEnds() { if thenArmed && !parentMuted { parentWoken = true } }
}
print("══ [1] Stop from the child's own page ══")
do {
    var w = World()                    // OLD: child.cancel() only
    w.childLoopEnds()
    check("OLD: raw cancel() leaves the callback armed → parent woken with 'cancelled'", w.parentWoken)
    var n = World()                    // NEW: registry path — mute + silent cancel
    n.parentMuted = true; n.thenArmed = false; n.childLoopEnds()
    check("NEW: parent muted and callback dropped → parent stays quiet", !n.parentWoken)
}

print("\n══ [2] source ══")
let reg = source("Agent/Jobs/AgentJobRegistry.swift")
let runner = source("Agent/Jobs/HelperRunner.swift")
let card = source("Views/Chat/HelperBlockView.swift")
let chat = chatViewSource()
let rpc = source("Debug/DebugRPCProviderChat.swift")
check("one shared user-stop in the registry: mute parent, then cancel the sibling set",
      reg.contains("func stopSubAgentByUser(childSessionId: String, reason: String) -> Int {")
      && reg.contains("parentVM.muteDelegationResults(reason: reason)\n        }\n        return cancelSiblings(ofChild: childSessionId, reason: reason)"))
check("the card uses it", card.contains("AgentJobRegistry.shared.stopSubAgentByUser(\n                        childSessionId: childId"))
check("the vm routes a sub agent's own Stop through it, else plain cancel()",
      runner.contains("func stopByUser() {") && runner.contains("if isHelper, let sid = sessionId,")
      && runner.contains("AgentJobRegistry.shared.stopSubAgentByUser(\n               childSessionId: sid"))
// [T-stop-confirm] 4: the composer Stop (setting off), its "Stop this task?"
// dialog's Stop, Stop All and Stop & New Chat.
check("composer Stop, its confirmation, Stop All and Stop & New Chat call stopByUser",
      chat.components(separatedBy: "vm.stopByUser()").count - 1 == 4)
check("…and none of them calls a raw vm.cancel() any more",
      !chat.contains("vm.cancel()\n                NotificationCenter.default.post(name: .newChatRequested")
      && !chat.contains("{ vm.cancel() }"))
check("the debug RPC mirrors the tap", rpc.contains("cachedVM?.stopByUser()"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
