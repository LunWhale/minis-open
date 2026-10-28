#!/usr/bin/env swift
// [T-retry-log-sheet] The run's retry log behind the yellow retry marker.
//
//   [1] the shipping RetryLogEvent / RetryLogStore (BEGIN/END block in
//       AIChatViewModel+Fallback.swift), compiled standalone and driven
//       through the run shapes the agent loop produces: marker visibility
//       (isRetrying), auto-retry settling only its own rows, a reply
//       recovering everything, a model switch, stop / run end dropping the
//       log, a fresh run starting empty, keys kept apart
//   [2] source guards: where the agent loop records, settles and drops
//
// Run: swift RetryLogStoreTests.swift   (needs swiftc)
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

let fallback = source("Agent/Chat/AIChatViewModel+Fallback.swift")
let loop = source("Agent/Chat/AIChatViewModel+AgentLoop.swift")
guard let block = between(fallback, "// BEGIN RetryLogTypes", "// END RetryLogTypes") else {
    print("❌ RetryLogTypes block not found"); exit(1)
}

let prelude = """
import Foundation
import Combine
struct _Log { func info(_ s: @autoclosure () -> String) {} }
let logger = _Log()
"""

let harness = #"""
import Foundation
@MainActor func main() {
    let s = RetryLogStore.shared
    let k = "session-A", other = "session-B"
    func ev(_ kind: RetryLogEvent.Kind, outcome: RetryLogEvent.Outcome = .pending) -> RetryLogEvent {
        RetryLogEvent(kind: kind, reason: "r", model: "M (I)", outcome: outcome)
    }
    print("R idle.retrying=\(s.isRetrying(key: k))")

    // Countdown retries, then the stream opens.
    s.beginRun(key: k)
    s.record(ev(.autoRetry), key: k)
    print("R autoRetry.retrying=\(s.isRetrying(key: k))")
    s.record(ev(.autoRetry), key: k)
    s.resolvePending(key: k, outcome: .succeeded, kind: .autoRetry)
    print("R autoRetry.opened.retrying=\(s.isRetrying(key: k)) autoRetry.outcomes=\(s.events(for: k).map { "\($0.outcome)" }.joined(separator: ","))")

    // Mid-stream interruption -> retry ladder exhausted -> model switch -> reply.
    s.record(ev(.streamInterrupted), key: k)
    s.record(ev(.autoRetry), key: k)
    s.resolvePending(key: k, outcome: .failed, kind: .autoRetry)
    print("R exhausted.interruptStillPending=\(s.events(for: k).first { $0.kind == .streamInterrupted }!.outcome == .pending) exhausted.retrying=\(s.isRetrying(key: k))")
    s.record(ev(.modelSwitch, outcome: .succeeded), key: k)
    s.resolvePending(key: k, outcome: .succeeded)
    let afterReply = s.events(for: k)
    print("R reply.retrying=\(s.isRetrying(key: k)) reply.interrupt=\(afterReply.first { $0.kind == .streamInterrupted }!.outcome) reply.lastAuto=\(afterReply.last { $0.kind == .autoRetry }!.outcome) reply.count=\(afterReply.count)")

    // Other conversation untouched.
    s.record(ev(.emptyResponse), key: other)
    print("R keys.apart=\(s.isRetrying(key: other) && !s.isRetrying(key: k))")

    // Stopped mid-retry: the run ends, the log (and marker) go.
    s.record(ev(.streamInterrupted), key: k)
    print("R stopMid.retrying=\(s.isRetrying(key: k))")
    s.endRun(key: k)
    print("R ended.retrying=\(s.isRetrying(key: k)) ended.count=\(s.events(for: k).count) ended.otherKept=\(s.events(for: other).count)")

    // A fresh run starts empty even if the last one left something.
    s.record(ev(.autoRetry), key: other)
    s.beginRun(key: other)
    print("R fresh.count=\(s.events(for: other).count) fresh.retrying=\(s.isRetrying(key: other))")
    // Settling with nothing pending is a no-op.
    s.resolvePending(key: other, outcome: .succeeded)
    s.endRun(key: other)
    print("R noop.count=\(s.events(for: other).count)")
}
MainActor.assumeIsolated { main() }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("retry-log-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Types.swift", prelude + "\n" + block), ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping RetryLogEvent / RetryLogStore compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    for part in line.dropFirst(2).split(separator: " ") {
        guard let eq = part.firstIndex(of: "=") else { continue }
        r[String(part[..<eq])] = String(part[part.index(after: eq)...])
    }
}

print("\n1. Behaviour")
check("no run, no marker", r["idle.retrying"] == "false")
check("a countdown retry shows the marker", r["autoRetry.retrying"] == "true")
check("the stream opening clears it and marks both countdowns recovered",
      r["autoRetry.opened.retrying"] == "false" && r["autoRetry.outcomes"] == "succeeded,succeeded")
check("an exhausted ladder settles only its own rows: the interruption stays pending, marker stays",
      r["exhausted.interruptStillPending"] == "true" && r["exhausted.retrying"] == "true")
check("a reply after the switch recovers the interruption and ends the marker",
      r["reply.retrying"] == "false" && r["reply.interrupt"] == "succeeded")
check("…while the given-up countdown stays failed, and every event is kept for the sheet",
      r["reply.lastAuto"] == "failed" && r["reply.count"] == "5")
check("conversations are kept apart", r["keys.apart"] == "true")
check("a mid-run interruption shows the marker until the run ends", r["stopMid.retrying"] == "true")
check("the run ending drops its log (marker gone, nothing left behind)",
      r["ended.retrying"] == "false" && r["ended.count"] == "0" && r["ended.otherKept"] == "1")
check("a fresh run starts with an empty log", r["fresh.count"] == "0")
check("settling or ending an empty log is a harmless no-op", r["noop.count"] == "0")

print("\n2. Wired into the agent loop")
check("a fresh run starts the log; every run end drops it",
      loop.contains("if existingMsgIdx == nil { RetryLogStore.shared.beginRun(key: retryKey) }")
      && loop.contains("RetryLogStore.shared.endRun(key: retryKey)")
      && loop.contains("if retryLogKey != retryKey { RetryLogStore.shared.endRun(key: retryLogKey) }"))
check("both mid-stream interruption sites record and bring the typing row back",
      loop.components(separatedBy: "kind: .streamInterrupted,").count - 1 == 2
      && loop.components(separatedBy: "messages[msgIdx].isAwaitingModelResponse = true\n").count - 1 >= 2)
check("a model switch is recorded with where it switched to",
      loop.contains("kind: .modelSwitch,") && loop.contains("switchedTo: \"\\(newEntry.model.displayName) (\\(instanceLabel))\""))
check("the empty-reply re-ask is recorded", loop.contains("kind: .emptyResponse,"))
check("a completed reply settles everything pending as recovered",
      loop.contains("RetryLogStore.shared.resolvePending(key: retryLogKey, outcome: .succeeded)\n"))
check("the countdown records each attempt with its real ladder length",
      fallback.contains("attempt: attempt, maxAttempts: retryDelays.count, delaySeconds: delay,"))
check("the countdown settles only its own rows",
      fallback.contains("outcome: .succeeded, kind: .autoRetry)") && fallback.contains("outcome: .failed, kind: .autoRetry)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
