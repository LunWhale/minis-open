#!/usr/bin/env swift
// [T-subagent-termination] Sub agent sessions that end without a final answer.
//
// Field report 2026-10-04 (72 sub agent sessions): 10 transcripts stop right
// after a tool result, and `minis-sessions-cli status` said is_running=false,
// last_message="" for them - and for 58 sessions that ended normally too.
// Nothing recorded WHY a run ended on the child session; an empty model reply
// was dropped by ChatStore's empty-assistant filter (its error with it); no
// closing request was ever sent.
//
//   [1] the shipping SubAgentTerminationCore block (SubAgentTermination.swift),
//       compiled standalone: classification of each ending, the final-answer
//       test on the last turn's shape, the no-answer note, the persisted store
//       (running -> interrupted when nothing is alive, delivery states,
//       restart survival, capacity)
//   [2] source guards: the in-loop closing request, where HelperRunner
//       records the ending in both modes, callback delivery states,
//       sessions-cli status fields, resolvedStatus no longer taking a
//       fallback text for an answer
//
// Run: swift SubAgentTerminationTests.swift   (needs swiftc)
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

let termSrc = source("Agent/Jobs/SubAgentTermination.swift")
guard let core = between(termSrc, "// BEGIN SubAgentTerminationCore", "// END SubAgentTerminationCore") else {
    print("❌ SubAgentTerminationCore block not found"); exit(1)
}

let harness = #"""
import Foundation
func out(_ k: String, _ v: Any) { print("R \(k)=\(v)") }

func cls(_ e: SubAgentRunEnd) -> String { SubAgentTerminationRules.classify(e).reason.rawValue }

@MainActor func main() {
    // ── Classification, one row per ending ──
    out("c.final", cls(SubAgentRunEnd(loopStatus: "completed", hasFinalAnswer: true)))
    out("c.cancel", cls(SubAgentRunEnd(loopStatus: "cancelled", hasFinalAnswer: false)))
    out("c.userCancel", cls(SubAgentRunEnd(loopStatus: "completed", userCancelled: true, hasFinalAnswer: false)))
    out("c.timeoutCut", cls(SubAgentRunEnd(loopStatus: "timeout", hasFinalAnswer: false)))
    out("c.budgetEmptyWrapUp", cls(SubAgentRunEnd(loopStatus: "completed", budgetExpired: true, hasFinalAnswer: false)))
    out("c.budgetButAnswered", cls(SubAgentRunEnd(loopStatus: "completed", budgetExpired: true, hasFinalAnswer: true)))
    out("c.requestFailed", cls(SubAgentRunEnd(loopStatus: "completed", errorText: "HTTP 503 upstream unavailable", hasFinalAnswer: false)))
    // EEA94903: the last tool timed out, the model wrote nothing after it.
    out("c.afterFailedTool", cls(SubAgentRunEnd(loopStatus: "completed", hasFinalAnswer: false, lastToolStatus: "failed")))
    // D9976EE1 / the metadata batches: last tool fine, reply empty.
    out("c.emptyReply", cls(SubAgentRunEnd(loopStatus: "completed", hasFinalAnswer: false, lastToolStatus: "success")))
    out("c.errorBeatsTool", cls(SubAgentRunEnd(loopStatus: "completed", errorText: "boom", hasFinalAnswer: false, lastToolStatus: "failed")))
    out("c.cancelBeatsAnswer", cls(SubAgentRunEnd(loopStatus: "cancelled", hasFinalAnswer: true)))

    // ── [T-subagent-timeout-reason] Who stopped it: the runner's budget or a person ──
    // Wait mode, runner cut it: finalStatus "timeout", and the runner's own
    // cancel() left userDidCancel = true (field report 10-08, Ma Sam).
    out("t.runnerInline", cls(SubAgentRunEnd(loopStatus: "timeout", userCancelled: true, stoppedForTimeout: true,
                                              budgetExpired: true, hasFinalAnswer: false)))
    // Background mode, the registry's loop-end observer closed the job first
    // (state cancelled, from userDidCancel) - only the flag says timeout.
    out("t.runnerBgRace", cls(SubAgentRunEnd(loopStatus: "cancelled", userCancelled: true, stoppedForTimeout: true,
                                             budgetExpired: true, hasFinalAnswer: false)))
    // Background mode, the runner's finish(.timeout) won.
    out("t.runnerBg", cls(SubAgentRunEnd(loopStatus: "timeout", userCancelled: true, stoppedForTimeout: true,
                                         budgetExpired: true, hasFinalAnswer: false)))
    // User Stop well inside the budget.
    out("t.userInBudget", cls(SubAgentRunEnd(loopStatus: "completed", userCancelled: true, hasFinalAnswer: false)))
    // User Stop during the wrap-up grace: budget over, wrap-up asked, the
    // runner has NOT cut it yet - a real cancel.
    out("t.userInGrace", cls(SubAgentRunEnd(loopStatus: "completed", userCancelled: true,
                                            budgetExpired: true, hasFinalAnswer: false)))
    // Parent Stop cascade (Task.isCancelled): wait mode turns it into
    // finalStatus "cancelled" and cancels the child - inside the budget...
    out("t.parentCascade", cls(SubAgentRunEnd(loopStatus: "cancelled", userCancelled: true, hasFinalAnswer: false)))
    // ...and during the grace.
    out("t.parentCascadeInGrace", cls(SubAgentRunEnd(loopStatus: "cancelled", userCancelled: true,
                                                     budgetExpired: true, hasFinalAnswer: false)))
    // The parent model's note for the runner's timeout.
    let (tr, td) = SubAgentTerminationRules.classify(SubAgentRunEnd(loopStatus: "timeout", userCancelled: true,
                                                                    stoppedForTimeout: true, budgetExpired: true,
                                                                    hasFinalAnswer: false))
    var tt = SubAgentTermination(sessionId: "S9", jobId: "J9", parentSessionId: "P", reason: tr, startedAt: Date())
    tt.detail = td
    let tnote = SubAgentTerminationRules.noAnswerNote(tt)
    out("t.noteReason", tnote.contains("termination_reason=timeout"))
    out("t.noteNotCancelled", !tnote.contains("cancelled") && !tnote.contains("stopped before it finished"))
    out("t.noteDetail", tnote.contains("the time budget and the wrap-up grace ran out"))

    // ── Final answer = last row is an assistant text turn without tool calls ──
    typealias T = SubAgentTerminationRules.TurnShape
    let toolCall = T(isAssistant: true, hasText: true, hasToolUse: true)      // narration + tool call
    let results = T(isAssistant: false, hasText: false, hasToolUse: false)    // user row of tool results
    let answer = T(isAssistant: true, hasText: true, hasToolUse: false)
    let empty = T(isAssistant: true, hasText: false, hasToolUse: false)
    let nudge = T(isAssistant: false, hasText: true, hasToolUse: false)
    out("f.endsOnResults", SubAgentTerminationRules.endsWithFinalTurn([toolCall, results]))
    out("f.endsOnAnswer", SubAgentTerminationRules.endsWithFinalTurn([toolCall, results, answer]))
    out("f.endsOnEmpty", SubAgentTerminationRules.endsWithFinalTurn([toolCall, results, empty]))
    out("f.nudgeThenAnswer", SubAgentTerminationRules.endsWithFinalTurn([toolCall, results, empty, nudge, answer]))
    out("f.nudgeThenEmpty", SubAgentTerminationRules.endsWithFinalTurn([toolCall, results, empty, nudge, empty]))
    out("f.narrationLast", SubAgentTerminationRules.endsWithFinalTurn([results, toolCall]))
    out("f.none", SubAgentTerminationRules.endsWithFinalTurn([]))

    // ── Summary + note ──
    let s = SubAgentTerminationRules.summarize("a\n\n  b\tc", limit: 300)
    out("s.collapse", s)
    out("s.cap", SubAgentTerminationRules.summarize(String(repeating: "x", count: 500)).count)
    var t = SubAgentTermination(sessionId: "S1", jobId: "J1", parentSessionId: "P", reason: .toolError, startedAt: Date())
    t.detail = "the last tool call failed and the model wrote no answer after it"
    t.lastTool = "shell_execute \"Search source installation paths\""
    t.lastToolStatus = "failed"
    t.lastToolSummary = "[Command timed out after 30s with no output captured]"
    let note = SubAgentTerminationRules.noAnswerNote(t)
    out("n.prefix", note.hasPrefix(SubAgentTerminationRules.noAnswerNotePrefix))
    out("n.reason", note.contains("termination_reason=tool_error"))
    out("n.tool", note.contains("Last tool: shell_execute \"Search source installation paths\" → failed: [Command timed out after 30s"))
    out("n.partialHint", note.contains("partial notes"))
    t.partialOutputAvailable = true
    out("n.partialHint2", SubAgentTerminationRules.noAnswerNote(t).contains("partial notes"))

    // ── Payload ──
    t.delivery = .pending
    t.endedAt = Date()
    let p = t.payload()
    out("p.keys", ["termination_reason", "termination_detail", "last_tool_name", "last_tool_status",
                   "last_tool_result", "partial_output_available", "closing_attempted",
                   "delivery_state", "ended_at"].allSatisfy { p[$0] != nil })
    out("p.reason", p["termination_reason"] as? String ?? "-")
    out("p.delivery", p["delivery_state"] as? String ?? "-")
    let running = SubAgentTermination(sessionId: "S", jobId: "J", reason: .running, startedAt: Date()).payload()
    out("p.runningNoEnd", running["ended_at"] == nil && running["delivery_state"] == nil)

    // ── Store ──
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subagent_term_\(UUID().uuidString).json")
    let st = SubAgentTerminationStore(fileURL: url)
    let t0 = Date(timeIntervalSince1970: 1_000)
    st.begin(sessionId: "C1", jobId: "J1", parentSessionId: "P", now: t0)
    out("st.running", st.record(for: "C1")?.reason.rawValue ?? "-")
    out("st.liveStaysRunning", st.resolved(sessionId: "C1", isLive: true)?.reason.rawValue ?? "-")
    // Wait -> background conversion re-enters begin for the same job.
    st.begin(sessionId: "C1", jobId: "J1", parentSessionId: "P", now: Date(timeIntervalSince1970: 2_000))
    out("st.beginSameJobKeepsStart", st.record(for: "C1")?.startedAt == t0)
    // App killed: nothing alive, still running -> interrupted, persisted.
    out("st.deadIsInterrupted", st.resolved(sessionId: "C1", isLive: false)?.reason.rawValue ?? "-")
    out("st.interruptedPersisted", SubAgentTerminationStore(fileURL: url).record(for: "C1")?.reason.rawValue ?? "-")
    // A finished run is never rewritten as interrupted.
    st.begin(sessionId: "C2", jobId: "J2", parentSessionId: "P", now: t0)
    var done = SubAgentTermination(sessionId: "C2", jobId: "J2", parentSessionId: "P", reason: .modelError, startedAt: Date())
    done.delivery = .pending
    st.end(done)
    out("st.endKeepsStart", st.record(for: "C2")?.startedAt == t0)
    out("st.finishedNotInterrupted", st.resolved(sessionId: "C2", isLive: false)?.reason.rawValue ?? "-")
    st.setDelivery(sessionId: "C2", .delivered)
    out("st.delivered", st.record(for: "C2")?.delivery?.rawValue ?? "-")
    st.setDelivery(sessionId: "C2", .failed, detail: "parent was stopped by the user")
    out("st.failedDetail", st.record(for: "C2")?.deliveryDetail ?? "-")
    // An end() without delivery keeps what an earlier write recorded.
    var again = done; again.delivery = nil
    st.end(again)
    out("st.endKeepsDelivery", st.record(for: "C2")?.delivery?.rawValue ?? "-")
    st.setDelivery(sessionId: "nobody", .delivered)
    out("st.noRecordNoop", st.record(for: "nobody") == nil)
    out("st.reload", SubAgentTerminationStore(fileURL: url).record(for: "C2")?.delivery?.rawValue ?? "-")
    // A new job in the same child replaces the old record.
    st.begin(sessionId: "C2", jobId: "J3", parentSessionId: "P")
    out("st.newJobRunning", st.record(for: "C2")?.reason.rawValue ?? "-")
    // Capacity: the oldest go first.
    let capURL = FileManager.default.temporaryDirectory.appendingPathComponent("subagent_cap_\(UUID().uuidString).json")
    let cap = SubAgentTerminationStore(fileURL: capURL)
    for i in 0..<(SubAgentTerminationStore.capacity + 5) {
        cap.begin(sessionId: "s\(i)", jobId: "j\(i)", parentSessionId: nil, now: Date(timeIntervalSince1970: Double(i)))
    }
    out("cap.oldestDropped", cap.record(for: "s0") == nil && cap.record(for: "s4") == nil)
    out("cap.newestKept", cap.record(for: "s\(SubAgentTerminationStore.capacity + 4)") != nil && cap.record(for: "s5") != nil)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(at: capURL)
}
MainActor.assumeIsolated { main() }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("subagent_term_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? ("import Foundation\n" + core + "\n" + harness).write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. Each ending gets its own name")
check("final answer -> completed", r["c.final"] == "completed")
check("parent Stop / user Stop -> cancelled", r["c.cancel"] == "cancelled" && r["c.userCancel"] == "cancelled")
check("budget + grace ran out -> timeout", r["c.timeoutCut"] == "timeout")
check("budget over and the wrap-up turn wrote nothing -> timeout", r["c.budgetEmptyWrapUp"] == "timeout")
check("budget over but it did answer -> completed", r["c.budgetButAnswered"] == "completed")
check("request failed after retries -> model_error", r["c.requestFailed"] == "model_error")
check("EEA94903 shape: tool timed out, then nothing -> tool_error", r["c.afterFailedTool"] == "tool_error")
check("empty reply after a fine tool -> model_error", r["c.emptyReply"] == "model_error")
check("a request error outranks the failed tool", r["c.errorBeatsTool"] == "model_error")
check("an explicit cancel outranks the transcript", r["c.cancelBeatsAnswer"] == "cancelled")

print("\n1b. [T-subagent-timeout-reason] The runner's budget stop is a timeout, a person's Stop is a cancel")
check("runner cut it in wait mode (userDidCancel set by its own cancel) -> timeout", r["t.runnerInline"] == "timeout")
check("background: registry closed it as cancelled first, flag still says timeout", r["t.runnerBgRace"] == "timeout")
check("background: runner's finish(.timeout) won -> timeout", r["t.runnerBg"] == "timeout")
check("user Stop inside the budget -> cancelled", r["t.userInBudget"] == "cancelled")
check("user Stop during the wrap-up grace -> cancelled", r["t.userInGrace"] == "cancelled")
check("parent Stop cascade -> cancelled", r["t.parentCascade"] == "cancelled")
check("parent Stop cascade during the grace -> cancelled", r["t.parentCascadeInGrace"] == "cancelled")
check("the parent's note names termination_reason=timeout", r["t.noteReason"] == "true")
check("…not cancelled / \"stopped before it finished\"", r["t.noteNotCancelled"] == "true")
check("…and says the budget and the grace ran out", r["t.noteDetail"] == "true")

print("\n2. Final answer = last row is a text turn with no tool call")
check("transcript ending on tool results has no answer", r["f.endsOnResults"] == "false")
check("…a text-only assistant turn is the answer", r["f.endsOnAnswer"] == "true")
check("…an empty last reply is not", r["f.endsOnEmpty"] == "false")
check("closing request answered -> answer", r["f.nudgeThenAnswer"] == "true")
check("closing request answered empty -> still none", r["f.nudgeThenEmpty"] == "false")
check("narration written with a tool call is not an answer", r["f.narrationLast"] == "false")
check("empty history has no answer", r["f.none"] == "false")

print("\n3. What the parent reads when there is no answer")
check("tool results are collapsed to one line", r["s.collapse"] == "a b c")
check("…and capped", r["s.cap"] == "301")
check("note starts with the recognised prefix", r["n.prefix"] == "true")
check("note names the reason", r["n.reason"] == "true")
check("note names the last tool, its status and its result", r["n.tool"] == "true")
check("partial-notes hint only when there is partial text", r["n.partialHint"] == "false" && r["n.partialHint2"] == "true")
check("payload carries every termination field", r["p.keys"] == "true")
check("payload values", r["p.reason"] == "tool_error" && r["p.delivery"] == "pending")
check("a running record has no end time or delivery yet", r["p.runningNoEnd"] == "true")

print("\n4. Persisted record")
check("begin -> running", r["st.running"] == "running")
check("running + alive stays running", r["st.liveStaysRunning"] == "running")
check("wait->background re-begin keeps the start time", r["st.beginSameJobKeepsStart"] == "true")
check("running + nothing alive -> interrupted (the app-killed case)", r["st.deadIsInterrupted"] == "interrupted")
check("…and that is written back", r["st.interruptedPersisted"] == "interrupted")
check("end keeps the start time", r["st.endKeepsStart"] == "true")
check("a finished run is never turned into interrupted", r["st.finishedNotInterrupted"] == "model_error")
check("delivery pending -> delivered", r["st.delivered"] == "delivered")
check("delivery failed carries why", r["st.failedDetail"] == "parent was stopped by the user")
check("end without delivery keeps the recorded delivery", r["st.endKeepsDelivery"] == "failed")
check("setDelivery on an unknown session is a no-op", r["st.noRecordNoop"] == "true")
check("survives a reload", r["st.reload"] == "failed")
check("a new job in the same child starts fresh", r["st.newJobRunning"] == "running")
check("capacity drops the oldest records", r["cap.oldestDropped"] == "true" && r["cap.newestKept"] == "true")

print("\n5. Wiring")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let closing = between(loop, "// [T-subagent-termination] A sub agent whose turn ended with", "continue\n") ?? ""
check("closing request: helpers only, once, not after a stop or a refusal, not on the last round",
      closing.contains("if helperConfig != nil, !helperClosingNudgeSent, !self.userDidCancel,")
      && closing.contains("stopReason != .refusal, turnCount + 1 < turnCap,")
      && closing.contains("assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty"))
check("…withdraws the tools and sends the hidden nudge, persisted",
      closing.contains("tools = []") && closing.contains("RawMessage.helperClosingNudgeText")
      && closing.contains("await persistAgentMessage(nudge)") && closing.contains("helperClosingAttempted = true"))
check("…sits on the no-tool exit, before the run ends",
      (loop.range(of: "Agent loop ending — no tool calls.")?.lowerBound ?? loop.endIndex)
        < (loop.range(of: "// [T-subagent-termination] A sub agent whose turn ended with")?.lowerBound ?? loop.startIndex))
let models = source("Agent/Chat/ChatStoreModels.swift")
check("the nudge is a hidden user row",
      models.contains("static let internalUserNudgeTexts: [String] = [scheduledResumeNudgeText, userAskTextAskNudgeText, userAskRetryNudgeText, helperClosingNudgeText]"))

let runner = source("Agent/Jobs/HelperRunner.swift")
check("a run is recorded `running` when it starts, fresh and resumed",
      runner.components(separatedBy: "SubAgentTerminationStore.shared.begin(sessionId: childId, jobId: job.id, parentSessionId: parentSid)").count - 1 == 2)
check("wait mode records the ending (delivery inline) and reports it",
      runner.contains("resultText: resultText, delivery: .inline)")
      && runner.contains("\"result\": Self.helperResultText(resultText, termination: termination),"))
check("background mode records it before the callback (delivery pending)",
      runner.contains("resultText: result, delivery: .pending)")
      && runner.contains("\"result\": Self.helperResultText(result, termination: termination),"))
check("both payloads carry the termination fields",
      runner.components(separatedBy: "payload.merge(termination.payload()) { _, new in new }").count - 1 == 2)
check("a clean exit without an answer is not reported completed",
      runner.components(separatedBy: "if reportedStatus == \"completed\", termination.reason != .completed {").count - 1 == 2)
check("resolvedStatus does not take a fallback text for an answer",
      runner.contains("return isFinalAnswer(result) ? status : noDeliverableStatus"))
check("emptyResultNote still starts with the text isFinalAnswer rejects",
      runner.contains("\"(the agent ended with status \\(status) before writing a final answer;")
      && termSrc.contains("\"(the agent ended with status \"]"))
check("isFinalAnswer rejects the registry's labelled fallback and the termination note",
      termSrc.contains("let notes = [AgentJobRegistry.noFinalAnswerLabel, SubAgentTerminationRules.noAnswerNotePrefix,"))
check("the final-answer test reads the child's own history",
      termSrc.contains("let hasFinal = Self.isFinalAnswer(resultText) && SubAgentTerminationRules.endsWithFinalTurn(shapes)"))

// [T-subagent-timeout-reason] Only the runner's two budget cuts mark a stop
// as a timeout; every other cancel (card Stop, parent Stop, agent_status
// cancel) leaves the flag false and stays `cancelled`.
let flagSetter = "child.helperStoppedForTimeout = true\n"
check("the flag is set by exactly the two budget cuts",
      runner.components(separatedBy: flagSetter).count - 1 == 2
      && !source("Agent/Chat/AIChatViewModel+Cancel.swift").contains("helperStoppedForTimeout"))
let inlineCut = between(runner, "finalStatus = \"timeout\"", "break") ?? ""
check("wait mode: the flag goes up right before the runner's own cancel()",
      inlineCut.contains("child.helperStoppedForTimeout = true\n                        child.cancel()"))
let bgCut = between(runner, "cancelledForTimeout = true", "awaitChildIdle") ?? ""
check("background mode: same, before cancel()",
      bgCut.contains("child.helperStoppedForTimeout = true\n                    child.cancel()"))
check("the flag is reset when a run starts, fresh and resumed",
      runner.components(separatedBy: "child.helperStoppedForTimeout = false   // [T-subagent-timeout-reason] fresh run\n        let outcome = child.submitProgrammaticPrompt(").count - 1 == 2)
check("the termination record is told who stopped it",
      termSrc.contains("stoppedForTimeout: child.helperStoppedForTimeout, budgetExpired: budgetExpired,"))
check("classify checks the timeout stop before userCancelled",
      (termSrc.range(of: "if end.stoppedForTimeout || end.loopStatus == \"timeout\" {")?.lowerBound ?? termSrc.endIndex)
        < (termSrc.range(of: "if end.loopStatus == \"cancelled\" || end.userCancelled {")?.lowerBound ?? termSrc.startIndex))

let registry = source("Agent/Jobs/AgentJobRegistry.swift")
check("the registry's loop-end observer closes a budget-cut run as timeout, not cancelled",
      registry.contains("let state: AgentJobState = vm?.helperStoppedForTimeout == true ? .timeout\n                : (cancelled ? .cancelled : .done)")
      && registry.contains("self.finish(jobId, state: state, result: text)"))
let then = between(registry, "private func runThen(for job: AgentJob) {", "// MARK: -") ?? registry
check("callback text uses the same termination note", then.contains("return AIChatViewModel.helperResultText(r, termination: termination)"))
check("…only for this job's own record", then.contains(".flatMap { $0.jobId == job.id ? $0 : nil }"))
check("delivery: parent deleted / stopped -> failed",
      then.contains("setDelivery(sessionId: childSid, .failed, detail: \"parent session no longer exists\")")
      && then.contains("setDelivery(sessionId: childSid, .failed, detail: \"parent was stopped by the user\")"))
check("delivery: sent / queued / rejected",
      then.contains("case .sent: SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .delivered)")
      && then.contains("case .queued: SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .queued,")
      && then.contains("case .rejected(let reason): SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .failed, detail: reason)"))
let noneCase = between(registry, "case .none:", "case .followUpParent") ?? ""
check("a callback dropped by a silent cancel is not left pending forever",
      noneCase.contains("t.jobId == job.id, t.delivery == .pending")
      && noneCase.contains("sessionId: sid, .failed, detail: \"withheld: the user stopped the parent's agents\")"))
check("the registry's fallback label is the shared constant",
      registry.contains("return noFinalAnswerLabel + \"\\n\" + earlier"))

let bridge = source("NativeOffloads/SessionsOffloadBridge.swift")
check("status reads last message / tool from the stored transcript when the VM is evicted",
      bridge.contains("let fromDB = Self.lastActivity(in: await ChatStore.shared.loadMessages(sessionId: sessionId))"))
check("status resolves the record against everything that can be alive",
      bridge.contains("sessionId: sessionId, isLive: isRunning || jobAlive || vmBusy)"))
check("status returns last_tool_status / last_tool_result and the termination fields",
      bridge.contains("data[\"last_tool_status\"] = lastToolStatus")
      && bridge.contains("data[\"last_tool_result\"] = lastToolResult")
      && bridge.contains("data.merge(termination.payload()) { _, new in new }"))
check("the new file is in the app target",
      source("Minis.xcodeproj/project.pbxproj").contains("E5SAT0001 /* SubAgentTermination.swift in Sources */,"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
