#!/usr/bin/env swift
// [T-stop-queued-cancel-error] Stop pressed before the first token, with a
// prompt queued behind the turn, must not leave a permanent error + Retry on
// screen. User report (iOS): "sent a candidate message before the first
// character came back, tapped Stop so the candidate went in, it entered the
// queue — but a persistent retry error appeared".
//
// Root cause: the stopped turn's error epilogue tested only the vm-wide
// `userDidCancel`, which `resumeQueueAfterCancel` resets after 200 ms so the
// queued turn can run. A turn stopped before its first token is still waiting
// on HTTP, so its LLMError.cancelled usually lands after that reset and was
// reported as a failure on the last assistant row — the drained turn's bubble.
//
// Run: swift StopQueuedCancelErrorTests.swift
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

struct CancelledRequest: Error {}   // stands in for LLMError.cancelled

/// Model of the vm: one shared flag, one stopped turn whose request error
/// arrives `errorDelayMs` after Stop, and the queue drain that resets the flag
/// after 200 ms.
@MainActor
final class VM {
    var userDidCancel = false
    var shownError: String?
    let useTaskCancellation: Bool
    init(useTaskCancellation: Bool) { self.useTaskCancellation = useTaskCancellation }

    var turnWasStopped: Bool {
        useTaskCancellation ? (userDidCancel || Task.isCancelled) : userDidCancel
    }

    func run(errorDelayMs: UInt64, queued: Bool) async {
        let turn = Task { @MainActor in
            do {
                // The HTTP wait ignores cancellation until the transport
                // reports it, like URLSession does before the first byte.
                try? await Task.sleep(nanoseconds: 0)
                let deadline = Date().addingTimeInterval(Double(errorDelayMs) / 1000)
                while Date() < deadline { await Task.yield() }
                throw CancelledRequest()
            } catch {
                if self.turnWasStopped {
                    // handleUserCancelledCleanup: nothing shown
                } else {
                    self.shownError = "Request was cancelled"
                }
            }
        }
        // User taps Stop right away.
        userDidCancel = true
        turn.cancel()
        if queued {
            // resumeQueueAfterCancel: 200 ms later the drained turn takes over.
            try? await Task.sleep(nanoseconds: 200_000_000)
            userDidCancel = false
        }
        _ = await turn.value
    }
}

print("══ [1] error arrives BEFORE the 200 ms drain reset ══")
do {
    let old = await VM(useTaskCancellation: false); await old.run(errorDelayMs: 50, queued: true)
    let new = await VM(useTaskCancellation: true); await new.run(errorDelayMs: 50, queued: true)
    check("OLD: no error (flag still set)", await old.shownError == nil)
    check("NEW: no error", await new.shownError == nil)
}

print("\n══ [2] error arrives AFTER the drain reset (the reported case) ══")
do {
    let old = await VM(useTaskCancellation: false); await old.run(errorDelayMs: 450, queued: true)
    let new = await VM(useTaskCancellation: true); await new.run(errorDelayMs: 450, queued: true)
    check("OLD: reproduces — the Stop surfaces as \"Request was cancelled\"", await old.shownError != nil)
    check("NEW: the stopped task knows it was cancelled → nothing shown", await new.shownError == nil)
}

print("\n══ [3] plain Stop, nothing queued ══")
do {
    let new = await VM(useTaskCancellation: true); await new.run(errorDelayMs: 450, queued: false)
    check("NEW: no error", await new.shownError == nil)
}

print("\n══ [4] a real failure in a turn nobody stopped still shows ══")
do {
    let vm = await VM(useTaskCancellation: true)
    let t = Task { @MainActor in
        do { throw CancelledRequest() } catch {
            if vm.turnWasStopped {} else { vm.shownError = "Provider error: 400" }
        }
    }
    _ = await t.value
    check("NEW: error surfaced", await vm.shownError != nil)
}

print("\n══ [5] source ══")
let vmSrc = chatViewModelSource()
let fb = source("Agent/Chat/AIChatViewModel+Fallback.swift")
check("turnWasStopped = userDidCancel || Task.isCancelled",
      vmSrc.contains("var turnWasStopped: Bool { userDidCancel || Task.isCancelled }"))
let sites = vmSrc.components(separatedBy: "if self.turnWasStopped {   // [T-stop-queued-cancel-error]").count - 1
check("all 6 turn error epilogues use turnWasStopped (found \(sites))", sites == 6)
check("no epilogue still decides on userDidCancel alone",
      !vmSrc.contains("if self.userDidCancel {\n                    self.handleUserCancelledCleanup()\n                } else {"))
check("auto-retry checks cancellation before starting a countdown",
      fb.contains("if attempt > 0 {\n                // [T-stop-queued-cancel-error]") && fb.contains("try Task.checkCancellation()\n                let delay = retryDelays[attempt - 1]"))
check("a countdown cut short by Stop clears its error and pill",
      fb.contains("self.autoRetryAttempt = 0\n                    self.autoRetryCountdown = 0\n                    chatMessage?.error = nil\n                    throw error"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
