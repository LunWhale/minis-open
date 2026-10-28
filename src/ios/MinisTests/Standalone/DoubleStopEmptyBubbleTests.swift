#!/usr/bin/env swift
// [T-double-stop-empty-bubble] Two Stops in a row must not leave an empty
// assistant bubble. Follow-up to T-stop-queued-cancel-error (7b70aba71): Stop
// turn A with a prompt queued, the queue drains into turn B, Stop again before
// B's first token → a bare assistant row (avatar, no content) stays on screen.
//
// Root cause: handleUserCancelledCleanup drops an empty placeholder only when
// the vm-wide `prevCommittedBlockCount` is 0. That mark is written when an
// iteration commits and was reset only by send(), so a turn started from the
// queue inherited turn A's value. With it > 0 the cleanup took the rollback
// branch instead: kept the empty row and removed A's committed reply from
// agentHistory.
//
// Run: swift DoubleStopEmptyBubbleTests.swift
import Foundation

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
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

/// The branch decision of handleUserCancelledCleanup for a candidate row
/// (tool-cancel Case 1 excluded: history does not end in a tool_result).
struct Row { var blocks: [String] }   // block contents
enum Outcome: Equatable { case removedPlaceholder, keptEmptyAndRolledBackHistory, keptContent }
func cleanup(_ row: Row, prevCommitted: Int, history: inout [String]) -> Outcome {
    let hasText = row.blocks.contains { !$0.isEmpty }
    if !hasText && prevCommitted == 0 { return .removedPlaceholder }          // Case 0
    if hasText { return .keptContent }                                        // Case 2 visible
    if prevCommitted > 0 {                                                    // Case 2 branch B
        if history.last?.hasPrefix("assistant") == true { history.removeLast() }
        return .keptEmptyAndRolledBackHistory
    }
    return .removedPlaceholder                                                // Case 2 branch C
}

/// Turn A: one tool round committed (prev→0, committed→2), then streaming text;
/// Stop #1 → Case 2 with visible content → prev = committed (2).
func afterStopOne() -> (prev: Int, history: [String]) {
    var prev = 0, committed = 0
    prev = committed; committed = 2          // iteration 1 commit (tool_use + result)
    // Stop #1, Case 2 visible content:
    prev = committed; committed = 3
    _ = committed
    return (prev, ["user A", "assistant A-tool", "user tool_result", "assistant A-partial", "user B"])
}

print("══ [1] Stop #2 before B's first token ══")
do {
    let (prevAfterA, hist) = afterStopOne()
    check("turn A leaves prevCommittedBlockCount > 0 (\(prevAfterA))", prevAfterA > 0)

    var oldHist = hist
    let old = cleanup(Row(blocks: []), prevCommitted: prevAfterA, history: &oldHist)   // OLD: inherited
    check("OLD: reproduces — empty bubble kept", old == .keptEmptyAndRolledBackHistory)

    var newHist = hist
    let new = cleanup(Row(blocks: []), prevCommitted: 0, history: &newHist)            // NEW: fresh bubble resets to 0
    check("NEW: empty placeholder removed", new == .removedPlaceholder)
    check("NEW: history untouched", newHist == hist)
}

print("\n══ [2] a stopped turn WITH text is unaffected ══")
do {
    var h = ["user B"]
    check("keeps its content", cleanup(Row(blocks: ["partial"]), prevCommitted: 0, history: &h) == .keptContent)
}

print("\n══ [3] superseded-turn epilogue ══")
do {
    // finishStoppedTurn: flag false + task cancelled → no cleanup at all.
    func decides(flag: Bool, cancelled: Bool) -> Bool { !( !flag && cancelled ) }
    check("user Stop (flag set) → cleanup runs", decides(flag: true, cancelled: true))
    check("superseded (flag already reset, task cancelled) → touches nothing", !decides(flag: false, cancelled: true))
    check("non-user cancellation (flag false, task live) → old cleanup kept", decides(flag: false, cancelled: false))
}

print("\n══ [4] source ══")
let vm = chatViewModelSource()
check("runAgentLoopCore resets the mark for a fresh bubble",
      vm.contains("if existingMsgIdx == nil {\n            self.prevCommittedBlockCount = 0\n        }"))
let freshSites = vm.components(separatedBy: "self.prevCommittedBlockCount = 0   // [T-double-stop-empty-bubble] fresh bubble").count - 1
check("the in-loop fresh-bubble sites reset it too (found \(freshSites), want 3)", freshSites == 3)
check("finishStoppedTurn skips superseded turns",
      vm.contains("func finishStoppedTurn() {\n        if !userDidCancel && Task.isCancelled {"))
let routed = vm.components(separatedBy: "self.finishStoppedTurn()").count - 1
check("all 12 stopped-turn epilogues route through it (found \(routed))", routed == 12)
check("resumeQueueAfterCancel hands over when a second Stop lands in its wait",
      vm.contains("try? await Task.sleep(nanoseconds: 200_000_000) // 200ms\n            // [T-double-stop-empty-bubble]")
      && vm.contains("guard !Task.isCancelled else {\n                logger.info(\"📨[DRAIN] queue-resume superseded by another Stop during the settle wait — handing over\")"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
