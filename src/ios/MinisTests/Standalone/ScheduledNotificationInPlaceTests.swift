#!/usr/bin/env swift
// [T-sched-notif-in-place] A scheduled task in a conversation posted a new
// "task finished" notification on every background run (identifier
// "bg-task-<session>-<timestamp>"), so a loop filled Notification Center with
// identical entries. A run opened by a scheduled firing now uses one identifier
// per (conversation, scheduled task), which iOS replaces in place.
//
// 1. compiles the shipping BackgroundTaskNotificationID block together with the
//    real AgentCallback.swift (HelperModelIdentity / AppLocalized stubbed) and
//    checks the identifier and the firing recognition;
// 2. pins the wiring: the VM reads the job id from the turn-opening message,
//    the notification uses it, and only a new entry bumps the badge.
//
// Run: swift ScheduledNotificationInPlaceTests.swift   (needs swiftc)
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
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

let bka = source("Agent/Background/BackgroundKeepAliveManager.swift")
let callback = source("Agent/Jobs/AgentCallback.swift")
guard let b = bka.range(of: "// [T-sched-notif-in-place] BEGIN bg-task-notification-id"),
      let e = bka.range(of: "// [T-sched-notif-in-place] END bg-task-notification-id"),
      !callback.isEmpty else {
    print("❌ sources not found"); exit(1)
}
let block = String(bka[b.lowerBound..<e.upperBound])

let stubs = """
import Foundation
func AppLocalized(_ s: String) -> String { s }
struct HelperModelIdentity: Equatable {
    init(payload: [String: Any]) {}
    func payload() -> [String: Any] { [:] }
}
"""

let tests = #"""
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }
let t0 = Date(timeIntervalSince1970: 1_790_000_000), t1 = t0.addingTimeInterval(600)

// Identifier
let a1 = BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: "J", now: t0)
let a2 = BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: "J", now: t1)
expect("two runs of one scheduled task share one identifier (updated in place)", a1 == a2)
expect("…which names the conversation and the task", a1 == "bg-task-S-job-J")
expect("another scheduled task in the same conversation keeps its own entry",
       a1 != BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: "K", now: t0))
expect("the same task id in another conversation keeps its own entry",
       a1 != BackgroundTaskNotificationID.make(sessionId: "T", scheduledJobId: "J", now: t0))
let n1 = BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: nil, now: t0)
let n2 = BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: nil, now: t1)
expect("an ordinary completion still gets a fresh identifier each time", n1 != n2)
expect("…in the same format as before", n1 == "bg-task-S-\(t0.timeIntervalSince1970)")
expect("an empty job id counts as no scheduled task",
       BackgroundTaskNotificationID.make(sessionId: "S", scheduledJobId: "", now: t0) == n1)

// Recognising the firing that opened the turn
let fire = """
<agent_callback kind="scheduled" job="JOB-1" title="Check the build" status="running" fire="3" remaining="27">
<prompt>
Check whether the build finished.
</prompt>
</agent_callback>
"""
let finished = """
<agent_callback kind="finished" job="HELPER-9" title="Research" status="done">
<result>
done
</result>
</agent_callback>
"""
expect("a scheduled firing is recognised", BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: [fire]) == "JOB-1")
expect("…with surrounding whitespace", BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: ["\n  " + fire + "\n"]) == "JOB-1")
expect("…next to a reminder part (queued injection)",
       BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: ["<system-reminder>queued</system-reminder>", fire]) == "JOB-1")
expect("a sub agent's report is not a scheduled firing",
       BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: [finished]) == nil)
expect("a typed message is not", BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: ["check the build please"]) == nil)
expect("an envelope quoted inside a typed message is not",
       BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: ["see this: " + fire]) == nil)
expect("no text parts: none", BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: []) == nil)
if fails > 0 { print("RESULT fail \(fails) check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-notif-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try stubs.write(to: tmp.appendingPathComponent("stubs.swift"), atomically: true, encoding: .utf8)
try callback.write(to: tmp.appendingPathComponent("AgentCallback.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + block).write(to: tmp.appendingPathComponent("block.swift"), atomically: true, encoding: .utf8)
try ("import Foundation\n" + tests).write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("1. Notification identity (shipping block + real AgentCallback)")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + ["stubs.swift", "AgentCallback.swift", "block.swift", "main.swift"]
                        .map { tmp.appendingPathComponent($0).path } + ["-o", bin.path])
check("block + AgentCallback + tests compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    let pass = line.hasPrefix("RESULT pass")
    check(String(line.dropFirst(12)), pass)
}

print("\n2. Wiring")
let bgTask = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
check("the VM reads the job id from the turn-opening user message",
      bgTask.contains("static func scheduledJobIdOpeningCurrentTurn(in history: [AgentMessage]) -> String? {")
      && bgTask.contains("let texts = history[start - 1].parts.compactMap")
      && bgTask.contains("return BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: texts)"))
check("…before the async notification work, and passes it on",
      bgTask.contains("let scheduledJobId = Self.scheduledJobIdOpeningCurrentTurn(in: agentHistory)")
      && bgTask.contains("scheduledJobId: scheduledJobId"))
check("the notification identifier comes from BackgroundTaskNotificationID",
      bka.contains("let identifier = BackgroundTaskNotificationID.make(sessionId: sessionId, scheduledJobId: scheduledJobId, now: Date())")
      && bka.contains("identifier: identifier,"))
check("no per-run timestamp identifier is built inline any more",
      !bka.contains("identifier: \"bg-task-\\(sessionId)-\\(Date().timeIntervalSince1970)\""))
check("a scheduled run checks what is already delivered",
      bka.contains("let delivered = await center.deliveredNotifications()")
      && bka.contains("let isNewEntry = !delivered.contains { $0.request.identifier == identifier }"))
check("…and only a new entry bumps the badge",
      bka.contains("if isNewEntry {\n            // [T-mac-dock-badge] Through the badge ledger, not \"icon + 1\".\n            content.badge = NSNumber(value: noteUnseenNotification())"))

print(failures == 0 ? "\n🎉 all checks passed" : "\n❌ \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
