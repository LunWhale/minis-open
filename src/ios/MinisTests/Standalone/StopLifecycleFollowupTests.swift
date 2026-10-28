#!/usr/bin/env swift
// Deep-review follow-ups on the Stop / queue lifecycle (2026-09-27):
//  [T-queue-drain-handover]         M1: a drain skipped by the reentrancy guard is
//                                   re-offered when the guard is released.
//  [T-stop-cleanup-before-new-turn] M6: a new turn runs a pending Stop's cleanup
//                                   before it resets userDidCancel.
//  [T-mute-reset-on-drain]          M7: a drained queued prompt is a new turn —
//                                   a sub-agent stop's mute does not carry over.
//  [T-preset-cleared-on-stop]       M4: Stop drops the armed preset of the fire
//                                   it stopped; queued fires keep theirs.
//
// Run: swift StopLifecycleFollowupTests.swift
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
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

// MARK: - M1 model: reentrancy guard + handover

final class Q {
    var isDraining = false, requested = false, queue = ["P2"], isProcessing = false
    var drained: [String] = [], rescues = 0
    let handover: Bool
    init(handover: Bool) { self.handover = handover }
    func startDrainIfIdle() {
        guard !isProcessing, !isDraining, !queue.isEmpty else { return }
        rescues += 1; isDraining = true; drained += queue; queue.removeAll(); isDraining = false
    }
    /// Drain D (from Stop) arrives while the stopped task still holds the guard.
    func drainFromStopWhileHeld() {
        guard !isDraining else { if handover { requested = true }; return }
    }
    /// The stopped task finally unwinds and releases the guard.
    func stoppedTaskReleases() {
        isDraining = false
        if handover, requested { requested = false; if !queue.isEmpty { startDrainIfIdle() } }
    }
}
print("M1. queued prompt after Stop on a drained turn")
do {
    for handover in [false, true] {
        let q = Q(handover: handover)
        q.isDraining = true              // stopped drained turn still unwinding
        q.drainFromStopWhileHeld()       // D skipped by the guard
        q.isProcessing = false           // D sets isProcessing = false
        q.startDrainIfIdle()             // didSet rescue — also blocked by the guard
        q.stoppedTaskReleases()
        if handover { check("NEW: P2 drained after the guard is released", q.drained == ["P2"]) }
        else { check("OLD: reproduces — P2 stranded in the queue", q.queue == ["P2"] && q.drained.isEmpty) }
    }
}

// MARK: - M6 model

print("\nM6. Stop, then send before the stopped turn's late epilogue")
do {
    struct Rows { var rows = ["user A", "assistant(empty placeholder A)"] }
    // OLD: send() resets the flag; the late epilogue reads "superseded" and skips.
    var old = Rows(); var flag = true
    flag = false; old.rows += ["user B", "assistant(B)"]
    let lateEpilogueRunsCleanup = flag
    if lateEpilogueRunsCleanup { old.rows.remove(at: 1) }
    check("OLD: reproduces — A's empty placeholder stays", old.rows.contains("assistant(empty placeholder A)"))
    // NEW: settlePendingStop runs the cleanup first.
    var new = Rows(); var flag2 = true
    if flag2 { new.rows.removeAll { $0 == "assistant(empty placeholder A)" }; flag2 = false }
    new.rows += ["user B", "assistant(B)"]
    check("NEW: placeholder removed before the new turn appends", new.rows == ["user A", "user B", "assistant(B)"])
}

print("\nsource")
let vm = chatViewModelSource()
let pp = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
check("M1: guard records a skipped drain", vm.contains("self.drainRequestedWhileBusy = true\n            return"))
check("M1: releasing the guard re-offers it",
      vm.contains("if self.drainRequestedWhileBusy {\n                self.drainRequestedWhileBusy = false\n                if !self.promptQueue.isEmpty {\n                    self.startDrainIfIdle(reason: \"drain-handover\")"))
check("M6: settlePendingStop cleans only when a Stop is pending",
      vm.contains("func settlePendingStop(before site: String) {\n        guard userDidCancel else { return }"))
for fn in ["send", "retry", "resume", "resumeUnansweredUserTurn", "retryFromMessage", "deleteFromMessage", "retryFromToolBlock"] {
    check("M6: \(fn)() settles first", vm.contains("settlePendingStop(before: \"\(fn)\")  // [T-stop-cleanup-before-new-turn]"))
}
check("M6: startDrainIfIdle settles before resetting the flag",
      vm.contains("self.settlePendingStop(before: \"startDrainIfIdle\")\n            self.userDidCancel = false"))
check("M7: drain loop resets the mute per drained batch",
      vm.contains("logger.info(\"📨[DRAIN] Draining \\(queued.count) queued prompt(s) (scheduled=") && vm.contains("self.delegationResultsMuted = false\n"))
check("M7: in-loop injected prompt resets the mute",
      vm.contains("delegationResultsMuted = false\n        // Start a new assistant message so the next response appears below the queued user message"))
check("M4: cancel() drops the stopped fire's preset",
      vm.contains("currentTask = nil\n        dropPresetsOfStoppedTurn()  // [T-preset-cleared-on-stop]"))
check("M4: model-switch cancel drops it too",
      vm.contains("currentTask = nil\n            dropPresetsOfStoppedTurn()  // [T-preset-cleared-on-stop]"))
check("M4: queued fires keep their presets",
      pp.contains("let stopped = pendingPresetToolCalls.keys.filter { !stillQueued.contains($0) }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
