#!/usr/bin/env swift
// [T-bka-session-single-invalidate] A CLBackgroundActivitySession must be
// invalidated exactly once.
//
// TestFlight 1.15 (12), iPhone17,1, iOS 18.2.1, crash point
// JDaljBN1_EA0tZdTm7tgj: EXC_BAD_ACCESS in objc_msgSend, called from
// _dispatch_call_block_and_release on a serial queue, no app frames. The block
// is the one -[CLDispatchSilo async:] enqueues; its silo had been freed.
//
// -[CLBackgroundActivitySession invalidate] reads the session's silo ivar
// without retaining it and enqueues a teardown block on that silo; the
// teardown releases the silo. A second invalidate that arrives while the first
// teardown is in flight can pick up the silo just as it is freed.
//
// The app caused the second invalidate itself: it iterated
// `session.diagnostics` in a task, and on stop cancelled that task and then
// called `session.invalidate()`. In the iOS 18 Swift overlay, the diagnostics
// stream's termination handler sends `invalidate` to the same session.
//
// Reproduced on macOS 26.5.1 with the same stack: invalidating one session
// twice, 0-150 us apart (MallocScribble on), crashed 3 of 5 runs of 4000
// pairs; 5 runs with a single invalidate each, 19000 in all, never crashed.
//
// Run: swift BKASessionSingleInvalidateTests.swift
import Foundation

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
/// Source with `//` comments removed, so a rule can be quoted in a comment.
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let r = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<r.lowerBound])
    }.joined(separator: "\n")
}
/// Body of the first function whose declaration contains `signature`.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature),
          let open = text.range(of: "{", range: start.upperBound..<text.endIndex) else { return "" }
    var depth = 0
    var i = open.lowerBound
    while i < text.endIndex {
        if text[i] == "{" { depth += 1 }
        if text[i] == "}" { depth -= 1; if depth == 0 { return String(text[open.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}
func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

let bka = code(source("Agent/Background/BackgroundKeepAliveManager.swift"))
let appDelegate = code(source("AppDelegate.swift"))

print("══ [1] the sources were found ══")
check("BackgroundKeepAliveManager.swift read", bka.contains("final class BackgroundKeepAliveManager"))
check("AppDelegate.swift read", appDelegate.contains("final class AppDelegate"))

print("\n══ [2] nothing ends a session behind the app's back ══")
check("no session diagnostics stream is read in the keep-alive manager", !bka.contains(".diagnostics"))
check("no session diagnostics stream is read in the app delegate", !appDelegate.contains(".diagnostics"))
check("the diagnostics watcher is gone", !bka.contains("watchSessionDiagnostics") && !bka.contains("locSessionDiagTask"))

print("\n══ [3] the owned session is invalidated once, then dropped ══")
let stop = body(of: "func stopBackgroundActivitySession()", in: bka)
check("stopBackgroundActivitySession found", !stop.isEmpty)
check("it invalidates exactly once", count(".invalidate()", in: stop) == 1)
if let inv = stop.range(of: ".invalidate()"), let drop = stop.range(of: "bgActivitySession = nil") {
    check("the handle is cleared after the invalidate, so a later stop cannot repeat it", inv.lowerBound < drop.lowerBound)
} else {
    check("the handle is cleared after the invalidate, so a later stop cannot repeat it", false)
}
let start = body(of: "func startBackgroundActivitySession()", in: bka)
check("startBackgroundActivitySession found", !start.isEmpty)
check("start never invalidates", !start.contains(".invalidate()"))
check("start is guarded against a second session while one is open", bka.contains("guard liveUpdatesTask == nil else { return }"))

print("\n══ [4] every probe session gets one invalidate ══")
let retract = body(of: "func retractOrphanedLocationSession(caller: String)", in: bka)
check("retractOrphanedLocationSession found", !retract.isEmpty)
check("the retract creates one probe and invalidates it once",
      count("CLBackgroundActivitySession()", in: retract) == 1 && count(".invalidate()", in: retract) == 1)
check("the retract never touches a session the app owns",
      retract.contains("guard liveUpdatesTask == nil, bgActivitySession == nil else { return }"))
check("probes in the manager: as many invalidates as creations",
      count("let probe = CLBackgroundActivitySession()", in: bka) == count("probe.invalidate()", in: bka))
check("the launch probe is created and invalidated in one expression",
      count("CLBackgroundActivitySession().invalidate()", in: appDelegate) == count("CLBackgroundActivitySession()", in: appDelegate))

print("\n══ [5] the helper used above ══")
check("comments are stripped before matching", !code("let a = 1 // session.diagnostics").contains(".diagnostics"))
check("a function body is cut at its closing brace",
      body(of: "func a()", in: "func a() { if x { y() } }\nfunc b() { z.invalidate() }") == "{ if x { y() } }")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
