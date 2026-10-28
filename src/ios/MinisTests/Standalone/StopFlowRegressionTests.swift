#!/usr/bin/env swift
// Regression guard for T-stop-queued-cancel-error (7b70aba71) and
// T-double-stop-empty-bubble (27e55237f): the flows those fixes did NOT mean
// to change must still work — a plain Stop, Stop that keeps generated text,
// Stop during a tool, Resume, an auto-retry that recovers, a single Stop with
// a queued prompt, the model-switch cancel, the concurrency-gate cancel, and a
// real failure in a turn nobody stopped.
//
// Behaviour sections mirror the production control flow with real Swift
// concurrency (the app target cannot be imported from a script); the source
// section pins the production lines those mirrors stand for.
//
// Run: swift StopFlowRegressionTests.swift
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

// MARK: - streamWithAutoRetry mirror (delays in ms instead of s)

struct Retryable: Error {}
struct Fatal: Error {}

@MainActor
final class RetryVM {
    var autoRetryAttempt = 0, autoRetryCountdown = 0
    var rowError: String?
    var attemptsMade = 0

    /// `outcomes[i]` = what attempt i does: true = stream opens, false = retryable failure.
    func streamWithAutoRetry(outcomes: [Bool], delays: [Int]) async throws -> Bool {
        var lastError: Error?
        for attempt in 0...delays.count {
            if attempt > 0 {
                try Task.checkCancellation()
                let delay = delays[attempt - 1]
                autoRetryAttempt = attempt
                if lastError != nil { rowError = "Network error" }
                do {
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        autoRetryCountdown = remaining
                        try await Task.sleep(nanoseconds: 10_000_000)
                        try Task.checkCancellation()
                    }
                } catch {
                    autoRetryAttempt = 0; autoRetryCountdown = 0; rowError = nil
                    throw error
                }
                autoRetryCountdown = 0
                rowError = nil
            }
            attemptsMade += 1
            if attempt < outcomes.count, outcomes[attempt] {
                autoRetryAttempt = 0
                return true
            }
            lastError = Retryable()
        }
        autoRetryAttempt = 0
        throw lastError!
    }
}

print("══ [1] auto-retry that recovers (nobody stops) ══")
do {
    let vm = await RetryVM()
    let ok = try? await vm.streamWithAutoRetry(outcomes: [false, false, true], delays: [2, 2, 2])
    check("third attempt opens the stream", ok == true)
    check("three attempts were made", await vm.attemptsMade == 3)
    check("retry pill gone (attempt=0, countdown=0)", await vm.autoRetryAttempt == 0 && vm.autoRetryCountdown == 0)
    check("countdown error cleared from the row", await vm.rowError == nil)
}

print("\n══ [2] auto-retry that exhausts (nobody stops) still reports the failure ══")
do {
    let vm = await RetryVM()
    var threw = false
    do { _ = try await vm.streamWithAutoRetry(outcomes: [false, false], delays: [1]) } catch is Retryable { threw = true } catch {}
    check("last retryable error propagates to fallback / the epilogue", threw)
    check("counters reset", await vm.autoRetryAttempt == 0)
}

print("\n══ [3] Stop during a countdown ══")
do {
    let vm = await RetryVM()
    let t = Task { try await vm.streamWithAutoRetry(outcomes: [false, true], delays: [50]) }
    try? await Task.sleep(nanoseconds: 60_000_000)
    check("countdown is showing before Stop", await vm.autoRetryAttempt == 1 && vm.rowError != nil)
    t.cancel()
    _ = try? await t.value
    check("after Stop: no pill, no row error", await vm.autoRetryAttempt == 0 && vm.autoRetryCountdown == 0 && vm.rowError == nil)
    check("the retry never fired", await vm.attemptsMade == 1)
}

// MARK: - resumeQueueAfterCancel mirror

@MainActor
final class DrainVM {
    var userDidCancel = true, canResume = true, isProcessing = false
    var drained = 0, cleanups = 0
    func resumeQueueAfterCancel(settleMs: UInt64) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: settleMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self.cleanups += 1
            self.userDidCancel = false
            self.canResume = false
            self.isProcessing = true
            self.drained += 1
        }
    }
}

print("\n══ [4] single Stop with a queued prompt ══")
do {
    let vm = await DrainVM()
    _ = await vm.resumeQueueAfterCancel(settleMs: 20).value
    check("queued prompt is drained once", await vm.drained == 1)
    check("cleanup ran once, flag reset, Resume banner cleared, turn running",
          await vm.cleanups == 1 && !vm.userDidCancel && !vm.canResume && vm.isProcessing)
}

print("\n══ [5] second Stop inside the settle wait ══")
do {
    let vm = await DrainVM()
    let d1 = await vm.resumeQueueAfterCancel(settleMs: 50)
    d1.cancel()                                             // Stop #2 cancels d1 …
    let d2 = await vm.resumeQueueAfterCancel(settleMs: 50)  // … and spawns its own drain
    _ = await d1.value; _ = await d2.value
    check("queued prompt drained exactly once", await vm.drained == 1)
    check("cleanup ran exactly once", await vm.cleanups == 1)
}

// MARK: - finishStoppedTurn decision per cancel source

func finishRunsCleanup(flag: Bool, taskCancelled: Bool) -> Bool { !( !flag && taskCancelled ) }

print("\n══ [6] who still gets the cleanup ══")
check("plain Stop (cancel(): flag=true, task cancelled)", finishRunsCleanup(flag: true, taskCancelled: true))
check("model-switch cancel (flag=true, task cancelled) → interrupted, resumable", finishRunsCleanup(flag: true, taskCancelled: true))
check("concurrency gate (flag=false, task live) → old non-user cleanup", finishRunsCleanup(flag: false, taskCancelled: false))
check("superseded turn after Stop handover (flag=false, task cancelled) → nothing", !finishRunsCleanup(flag: false, taskCancelled: true))

// MARK: - handleUserCancelledCleanup branch table (unchanged)

enum Branch: Equatable { case case1Tool, case0Remove, case2Keep, case2Rollback, case2Remove }
func branch(historyEndsInToolResult: Bool, hasText: Bool, hasTool: Bool, prev: Int, visible: Bool) -> Branch {
    if historyEndsInToolResult { return .case1Tool }
    if !hasText && !hasTool && prev == 0 { return .case0Remove }
    if visible { return .case2Keep }
    return prev > 0 ? .case2Rollback : .case2Remove
}

print("\n══ [7] single Stop, no queue ══")
check("before the first token → placeholder removed (Case 0)",
      branch(historyEndsInToolResult: false, hasText: false, hasTool: false, prev: 0, visible: false) == .case0Remove)
check("mid-text → content kept, Resume offered (Case 2)",
      branch(historyEndsInToolResult: false, hasText: true, hasTool: false, prev: 0, visible: true) == .case2Keep)
check("during a tool → blocks kept, Resume offered (Case 1)",
      branch(historyEndsInToolResult: true, hasText: true, hasTool: true, prev: 0, visible: true) == .case1Tool)
check("second iteration with no text yet → rolls back to the last commit (prev from THIS bubble)",
      branch(historyEndsInToolResult: false, hasText: false, hasTool: false, prev: 2, visible: false) == .case2Rollback)

// MARK: - source pins

print("\n══ [8] source: normal paths intact ══")
let vm = chatViewModelSource()
let fb = source("Agent/Chat/AIChatViewModel+Fallback.swift")

check("cancel() still sets the flag before cancelling the task",
      vm.contains("userDidCancel = true\n        currentTask?.cancel()\n        currentTask = nil\n        dropPresetsOfStoppedTurn()  // [T-preset-cleared-on-stop]\n        autoRetryAttempt = 0"))
check("cancel() still restarts the drain when prompts are queued",
      vm.contains("if !promptQueue.isEmpty && !isCompacting {") && vm.contains("resumeQueueAfterCancel()\n        }"))
check("drain still: cleanup → flag reset → canResume=false → isProcessing=true → drain",
      vm.contains("self.handleUserCancelledCleanup()\n            self.userDidCancel = false")
      && vm.contains("self.canResume = false\n            self.isProcessing = true\n            self.beginBackgroundProcessing()\n            logger.info(\"📨[DRAIN] Resuming queue in new task"))
check("model switch still marks the cancel as user-initiated",
      vm.contains("userDidCancel = true\n            currentTask?.cancel()"))
check("iteration commit still advances the rollback mark",
      vm.contains("self.prevCommittedBlockCount = self.committedBlockCount\n            committedBlockCount = allBlocks.count"))
check("Resume/Retry into an existing row keeps its mark (reset only when existingMsgIdx == nil)",
      vm.contains("if existingMsgIdx == nil {\n            self.prevCommittedBlockCount = 0\n        }"))
check("send() still resets both counters",
      vm.contains("committedBlockCount = 0\n        prevCommittedBlockCount = 0\n        userDidCancel = false"))
check("Case 1 still keeps blocks and offers Resume",
      vm.contains("canResume = true\n                logger.info(\"⏹️ Case 1 (tool cancel): preserved"))
check("Case 2 still keeps visible text and offers Resume",
      vm.contains("canResume = true\n                logger.info(\"⏹️ Case 2 (text cancel): preserved"))
check("non-user cancellation branch unchanged",
      vm.contains("// Non-user cancellation (e.g. concurrency gate) — just remove empty message"))
check("retry() and resume() still sweep superseded errors",
      vm.contains("clearSupersededErrors(reason: \"retry\", keeping: lastMsg)")
      && vm.contains("clearSupersededErrors(reason: \"resume\", keeping: lastMsg)"))
let failurePaths = vm.components(separatedBy: "self.reportTurnFailure(displayDesc)").count - 1
check("un-stopped failures still reach reportTurnFailure (\(failurePaths) paths)", failurePaths >= 6)
check("auto-retry success path still resets the attempt counter",
      fb.contains("self.autoRetryAttempt = 0\n                return stream"))
check("auto-retry still clears the countdown after a completed wait",
      fb.contains("self.autoRetryCountdown = 0\n                chatMessage?.error = nil\n\n                // Re-read current model binding"))
check("retryable errors still loop, others still throw",
      fb.contains("catch let error as LLMError where error.isRetryable {\n                lastError = error\n                continue"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
