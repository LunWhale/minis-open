#!/usr/bin/env swift
// [T-bgnotif-outcome] A task that did not finish was notified "✅ completed"
// (user report: a task ended by a lost network showed "task completed").
// endBackgroundProcessing decided success from `messages.last?.error` alone,
// so three endings slipped through as completed:
//   - the background-task expiry (loop suspended mid-run, nothing sets an error)
//   - the context-full stop (a systemInfo row + canResume, no error)
//   - an error on the turn's assistant row with a queued / status row after it
//
//   [1] the shipping BackgroundTurnOutcome block, compiled standalone: the
//       decision table and the "this turn's last assistant row" search
//   [2] source guards: the expiry handler, the notification, the Live
//       Activity and the context-full stop all use it; strings localized
//
// Run: swift BackgroundTurnOutcomeTests.swift   (needs swiftc)
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

let bg = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
guard let block = between(bg, "// BEGIN BackgroundTurnOutcome", "// END BackgroundTurnOutcome") else {
    print("❌ BackgroundTurnOutcome block not found"); exit(1)
}

let harness = """
import Foundation
\(block)
var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \\(ok ? "✅" : "❌") \\(label)"); if !ok { fails += 1 } }

// A chat as the UI holds it: role, queued flag, error.
enum Role { case user, assistant, systemInfo }
struct Row { let role: Role; var queued = false; var error: String? = nil }
func turnError(_ rows: [Row]) -> String? {
    BackgroundTurnOutcome.currentTurnAssistantIndex(
        count: rows.count,
        isSentUser: { rows[$0].role == .user && !rows[$0].queued },
        isAssistant: { rows[$0].role == .assistant }).flatMap { rows[$0].error }
}
func outcome(_ rows: [Row], expired: Bool = false, errorMessage: String? = nil,
             canResume: Bool = false, stopped: Bool = false) -> BackgroundTurnOutcome {
    BackgroundTurnOutcome.decide(backgroundTimeExpired: expired, turnError: turnError(rows),
                                 errorMessage: errorMessage, canResume: canResume, userStopped: stopped)
}

print("[1] decision")
let done = [Row(role: .user), Row(role: .assistant)]
CHECK("normal end -> completed", outcome(done) == .completed)
CHECK("background time expired -> interrupted", outcome(done, expired: true) == .interrupted)
CHECK("expiry wins over an error seen mid-retry", outcome([Row(role: .user), Row(role: .assistant, error: "timeout")], expired: true) == .interrupted)
CHECK("canResume, no error -> interrupted", outcome(done, canResume: true) == .interrupted)
CHECK("user stop -> interrupted", outcome(done, stopped: true) == .interrupted)
CHECK("error on the reply -> failed", outcome([Row(role: .user), Row(role: .assistant, error: "HTTP 500")]) == .failed)
CHECK("error + canResume (max tokens, refusal, empty) -> failed, with its reason", outcome([Row(role: .user), Row(role: .assistant, error: "truncated")], canResume: true) == .failed)
CHECK("turn-level errorMessage -> failed", outcome([Row(role: .user)], errorMessage: "Kernel not available") == .failed)
CHECK("blank error text does not count", outcome([Row(role: .user), Row(role: .assistant, error: "  ")]) == .completed)

print("[2] the error behind a later row")
CHECK("error on the assistant, systemInfo row after it -> failed",
      outcome([Row(role: .user), Row(role: .assistant, error: "network lost"), Row(role: .systemInfo)]) == .failed)
CHECK("error on the assistant, queued user row after it -> failed",
      outcome([Row(role: .user), Row(role: .assistant, error: "network lost"), Row(role: .user, queued: true)]) == .failed)
CHECK("an EARLIER turn's error is not this turn's",
      outcome([Row(role: .user), Row(role: .assistant, error: "old"), Row(role: .user), Row(role: .assistant)]) == .completed)
CHECK("a new turn with no reply yet reads no error",
      turnError([Row(role: .user), Row(role: .assistant, error: "old"), Row(role: .user)]) == nil)
CHECK("no sent user row: the whole list is the turn",
      turnError([Row(role: .assistant, error: "x")]) == "x")
CHECK("empty chat", turnError([]) == nil)

print("[3] context-full stop")
// The stop sets canResume and now also records its reason on the reply.
CHECK("context full with a reply -> failed (not completed)",
      outcome([Row(role: .user), Row(role: .assistant, error: "Context is full"), Row(role: .systemInfo)], canResume: true) == .failed)
CHECK("context full before any reply -> interrupted (not completed)",
      outcome([Row(role: .user), Row(role: .systemInfo)], canResume: true) == .interrupted)
exit(fails == 0 ? 0 : 1)
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bg-outcome-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("outcome block compiles standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("decision checks all pass", status == 0 && !out.contains("❌"))
}

print("[4] source guards")
check("the expiry handler reports the turn as expired",
      bg.contains("self.stopCurrentCommand()\n            // Must end the background task to avoid termination.")
      && bg.contains("self.endBackgroundProcessing(backgroundTimeExpired: true)"))
let end = between(bg, "func endBackgroundProcessing(backgroundTimeExpired: Bool = false) {", "// MARK: - Background Status Timer") ?? ""
check("the state no longer comes from messages.last",
      !end.contains("let hasError = messages.last?.error") && !end.contains("(messages.last?.error ?? errorMessage)"))
check("the state comes from BackgroundTurnOutcome.decide with this turn's reply",
      end.contains("let turnError = currentTurnAssistantMessage()?.error")
      && end.contains("BackgroundTurnOutcome.decide(") && end.contains("canResume: canResume")
      && end.contains("userStopped: userDidCancel"))
check("an interrupted turn says paused, not the partial text",
      end.contains("if outcome == .interrupted {") && end.contains("AppLocalized(\"Task paused. Open the session to continue.\")"))
check("the notification gets the outcome", end.contains("outcome: outcome, wasBackground: wasBackground"))
let liveActivity = between(end, "} else if outcome == .interrupted {", "} else if otherActive.isEmpty {") ?? ""
check("an interrupted turn never flips the Live Activity to completed",
      liveActivity.contains("AgentLiveActivityManager.shared.endActivity()")
      && !liveActivity.contains("finishActivity") && !liveActivity.contains("markSessionCompleted"))
check("scheduled runs keep their in-place path first",
      end.contains("if keptBySchedule {\n                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: \"scheduledRunEnded\")\n                } else if outcome == .interrupted {"))

let manager = source("Agent/Background/BackgroundKeepAliveManager.swift")
check("titles: failed / paused / completed marks by outcome",
      manager.contains("case .interrupted: mark = \"⏸\"") && manager.contains("case .failed: mark = \"❌\"") && manager.contains("case .completed: mark = \"✅\""))
check("privacy mode has neutral paused variants",
      manager.contains("case .interrupted: content.title = AppLocalized(\"⏸ Task paused\")")
      && manager.contains("case .interrupted: base = AppLocalized(\"1 task paused\")"))
check("Shortcuts suppression still gates the post",
      end.contains("if !suppressGenericNotification {\n                    BackgroundKeepAliveManager.shared.postBackgroundTaskNotification("))

let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
check("context-full stop records its reason on this turn's reply, then stops as before",
      loop.contains("if let reply = currentTurnAssistantMessage(), reply.error == nil {\n                    reply.error = contextFull")
      && loop.contains("canResume = true\n                hitTurnLimit = false\n                break loopLabel"))

let catalog = source("Localizable.xcstrings")
for key in ["⏸ Task paused", "1 task paused", "Task paused. Open the session to continue."] {
    let entry = between(catalog, "\"\(key)\" : {", "\n    },") ?? ""
    check("localized zh-Hans + zh-Hant: \(key)", entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\""))
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
