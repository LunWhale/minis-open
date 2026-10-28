#!/usr/bin/env swift
// [T-queued-callback-reminder] A finished sub agent's callback waits in
// promptQueue (deferUntilIdle) until the parent's turn ends, so the parent
// model could not know a result was already waiting. The running loop now
// mentions it once, in the next request only.
//
//   [1] QueuedCallbackReminder (BEGIN/END block in
//       AIChatViewModel+ProgrammaticPrompt.swift), compiled as shipped:
//       which queued prompts count, exact text, only-once, only new jobs,
//       nothing → nil.
//   [2] Source guards: request-copy-only injection (never agentHistory /
//       messages), placement at the tail of the last tool_result / user
//       text, marking only after the stream opened and never for a preset
//       stream, delivery planner untouched, reminderSent in memory only.
//
// Run: swift QueuedCallbackReminderTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
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
func ordered(_ s: String, _ parts: [String]) -> Bool {
    var from = s.startIndex
    for p in parts {
        guard let r = s.range(of: p, range: from..<s.endIndex) else { return false }
        from = r.upperBound
    }
    return true
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let pp = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
let models = source("Agent/Chat/ChatModels.swift")
guard let block = between(pp, "// BEGIN QueuedCallbackReminder", "// END QueuedCallbackReminder") else {
    print("❌ QueuedCallbackReminder block not found"); exit(1)
}

print("[1] QueuedCallbackReminder, compiled as shipped")
let expectedOne = """
<system-reminder>
Background update: sub agent(s) you delegated have finished, and the result is queued for this conversation: Survey docs (job ab12cd34, done)

It has NOT been delivered to you yet. It arrives as a new message only after your current turn ends, i.e. when you reply without calling more tools. Your call:
- If the result could change what you do next, or your remaining work is short or non-essential, wrap up now and end the turn with a brief summary. The result will then arrive.
- If your current work is independent of it and must finish first, keep going. The result stays queued and won't be lost.

Don't poll for it, re-delegate, or mention this reminder to the user.
</system-reminder>
"""
let driver = #"""
import Foundation
\#(block)
typealias C = QueuedCallbackReminder.Candidate
func c(_ kind: String?, _ job: String, _ title: String, _ status: String = "done",
       deferIdle: Bool = true, sent: Bool = false) -> C {
    C(promptId: UUID(), callbackKind: kind, jobId: job, title: title, status: status,
      deferUntilIdle: deferIdle, reminderSent: sent)
}
func emit(_ k: String, _ v: String) { print("@@\(k)=" + v.replacingOccurrences(of: "\n", with: "\\n")) }

// One finished job.
let one = [c("finished", "ab12cd34", "Survey docs")]
emit("one", QueuedCallbackReminder.text(for: QueuedCallbackReminder.pending(one)) ?? "nil")

// Mixed queue: only finished + deferUntilIdle + not yet reminded count.
var queue = [
    c("finished", "aaa", "A"),                       // counts
    c("progress", "bbb", "B", "running"),            // progress: no
    c("scheduled", "ccc", "C"),                      // scheduled fire: no
    c(nil, "", "", "", deferIdle: false),            // user's typed follow-up: no
    c("finished", "ddd", "D", "failed"),             // counts
    c("finished", "eee", "E", deferIdle: false),     // not job-queued: no
    c("finished", "fff", "F", sent: true),           // already reminded: no
    c("finished", "", "G"),                          // no job id: no
]
let p1 = QueuedCallbackReminder.pending(queue)
emit("p1", p1.map(\.jobId).joined(separator: ","))
emit("list1", QueuedCallbackReminder.text(for: p1)!.components(separatedBy: "\n")[1])

// After the reminder went out: mark, then nothing more to say.
queue = queue.map { x in p1.contains(where: { $0.promptId == x.promptId })
    ? C(promptId: x.promptId, callbackKind: x.callbackKind, jobId: x.jobId, title: x.title, status: x.status,
        deferUntilIdle: x.deferUntilIdle, reminderSent: true) : x }
emit("p2", QueuedCallbackReminder.pending(queue).map(\.jobId).joined(separator: ","))
emit("t2", QueuedCallbackReminder.text(for: QueuedCallbackReminder.pending(queue)) ?? "nil")

// A new job arrives: only it is listed.
queue.append(c("finished", "hhh", "H", "timeout"))
let p3 = QueuedCallbackReminder.pending(queue)
emit("p3", p3.map(\.jobId).joined(separator: ","))
emit("list3", QueuedCallbackReminder.text(for: p3)!.components(separatedBy: "\n")[1])

// Empty title falls back; empty queue → nil.
emit("untitled", QueuedCallbackReminder.text(for: [c("finished", "zzz", "")])!.components(separatedBy: "\n")[1])
emit("empty", QueuedCallbackReminder.text(for: []) ?? "nil")
emit("emptyQueue", QueuedCallbackReminder.text(for: QueuedCallbackReminder.pending([])) ?? "nil")
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cb_reminder_\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let src = tmp.appendingPathComponent("main.swift"), exe = tmp.appendingPathComponent("t")
try! driver.write(to: src, atomically: true, encoding: .utf8)
let (cc, cout) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", exe.path])
check("block compiles standalone", cc == 0)
if cc != 0 { print(cout); exit(1) }
var got: [String: String] = [:]
for line in run(exe.path, []).1.split(separator: "\n") where line.hasPrefix("@@") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    if kv.count == 2 { got[kv[0]] = kv[1].replacingOccurrences(of: "\\n", with: "\n") }
}
check("single job: exact text, verbatim template", got["one"] == expectedOne)
check("only finished + job-queued + not-yet-reminded jobs count", got["p1"] == "aaa,ddd")
check("several jobs joined with '; '",
      got["list1"] == "Background update: sub agent(s) you delegated have finished, and the result is queued for this conversation: A (job aaa, done); D (job ddd, failed)")
check("after marking: nothing pending", got["p2"] == "")
check("after marking: no reminder text", got["t2"] == "nil")
check("a new job: only the new one is listed", got["p3"] == "hhh")
check("new-job reminder lists just it",
      got["list3"] == "Background update: sub agent(s) you delegated have finished, and the result is queued for this conversation: H (job hhh, timeout)")
check("empty title falls back to 'Sub agent'", got["untitled"]?.hasSuffix("Sub agent (job zzz, done)") == true)
check("no pending jobs → nil", got["empty"] == "nil" && got["emptyQueue"] == "nil")
try? FileManager.default.removeItem(at: tmp)

print("[2] Wiring")
check("QueuedPrompt carries reminderSent, default false",
      (between(models, "struct QueuedPrompt: Identifiable {", "\n}") ?? "").contains("var reminderSent: Bool = false"))
check("candidates parse the queued text with AgentCallback.parse and read deferUntilIdle / reminderSent",
      pp.contains("let callback = AgentCallback.parse(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))")
      && pp.contains("deferUntilIdle: prompt.deferUntilIdle,") && pp.contains("reminderSent: prompt.reminderSent)"))
let inject = between(loop, "[T-queued-callback-reminder] A finished sub agent's result is", "[T-request-imgsize-primary-path]") ?? ""
check("injection block found (after the persona reminder, before the request is measured)",
      !inject.isEmpty && ordered(loop, ["[PersonaReminder] appended", "QueuedCallbackReminder.pending(", "recordContextDispatch(history: contextHistory"]))
check("injection rewrites the request copy only",
      inject.contains("contextHistory = withReminder")
      && !inject.contains("agentHistory.append") && !inject.contains("agentHistory =")
      && !inject.contains("agentHistory[") && !inject.contains("messages["))
check("no history / message writes happen in the reminder helpers",
      !(between(pp, "func historyAppendingRequestReminder(", "/// The scheduled fire a queued prompt carries") ?? "x").contains("agentHistory"))
let helper = between(pp, "static func historyAppendingRequestReminder(", "/// The scheduled fire a queued prompt carries") ?? ""
check("placement: last message must be a user turn",
      helper.contains("history[lastIdx].role == .user else { return nil }"))
check("placement: tool_result content first, user text otherwise, nothing else",
      ordered(helper, ["case .toolResult = parts[$0]", "content: content + suffix", "case .text = parts[$0]", ".text(existing + suffix)", "return nil"]))
check("tool_result rebuilt with every field (no laundering of readback / image)",
      helper.contains("isOffloadReadback: isReadback") && helper.contains("imageData: imageData, imageMimeType: imageMimeType"))
let dispatch = between(loop, "if let preset = takePresetToolStream(tools: tools) {", "noteEffectiveEntry(activeEntryId)") ?? ""
check("marked only after the real request's stream opened, not for a preset stream",
      ordered(dispatch, ["stream = preset", "} else {", "stream = try await streamWithGroupFallback(", "markQueuedCallbacksReminded(queuedCallbackReminderIds)"]))
check("delivery planner unchanged: finished callbacks still wait for the turn end",
      pp.contains("let typed = items.filter(\\.interruptsAtToolGap)")
      && pp.contains("interruptsAtToolGap: !prompt.deferUntilIdle,"))
check("reminderSent not persisted anywhere",
      !source("Agent/Chat/AIChatViewModel+Persistence.swift").contains("reminderSent"))

print(failures == 0 ? "ALL PASSED" : "❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
