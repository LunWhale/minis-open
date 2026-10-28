#!/usr/bin/env swift
// [T-scroll-sync-defer] Dropped frames while flicking a chat.
//
// On device (2026-10-03, iPhone 17 Pro, 2602 sessions) every 50-90 ms dropped
// frame during a run of flicks lined up with an inbound iCloud batch: the batch
// posted cloudSyncDidFetchChanges, the home list (still mounted under the chat)
// re-fetched and re-diffed ~2000 rows, and the open chat ran its reload check -
// all on the main thread, mid-deceleration.
//
// 1. compiles the shipping ChatScrollActivity with an injected clock and checks
//    run-now / hold / coalesce / drain-after-quiet behaviour;
// 2. pins the wiring: the chat list reports user-driven movement, and the home
//    refresh, its cooldown timer and the chat's sync reload all go through it.
//
// Run: swift ChatScrollActivityTests.swift   (needs swiftc)
import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
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
func block(_ src: String, _ name: String) -> String? {
    guard let b = src.range(of: "// BEGIN \(name)"), let e = src.range(of: "// END \(name)") else { return nil }
    return String(src[b.lowerBound..<e.upperBound])
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

let layoutSrc = source("Agent/MessageList/MessageListLayout.swift")
let listSrc = messageListV3Source()
let refreshSrc = source("Views/ContentView/ContentView+SessionRefresh.swift")
let contentSrc = source("Views/ContentView/ContentView.swift")
let vmSrc = source("Agent/Chat/AIChatViewModel.swift")
let syncSrc = source("Agent/Sync/V2/SyncCore.swift")
guard let activityBlock = block(layoutSrc, "ChatScrollActivity") else {
    print("❌ ChatScrollActivity block not found"); exit(1)
}

let tests = #"""
import Foundation
import QuartzCore
var fails = 0
func expect(_ label: String, _ cond: Bool) { print(cond ? "RESULT pass \(label)" : "RESULT fail \(label)"); if !cond { fails += 1 } }

MainActor.assumeIsolated {
    var now: CFTimeInterval = 100
    ChatScrollActivity.clock = { now }
    var ran: [String] = []

    expect("still at launch", !ChatScrollActivity.isMoving)
    ChatScrollActivity.runWhenStill("a") { ran.append("a0") }
    expect("work runs at once while still", ran == ["a0"] && ChatScrollActivity.pending.isEmpty)

    ChatScrollActivity.noteMoving()
    expect("moving right after a scroll callback", ChatScrollActivity.isMoving)
    ChatScrollActivity.runWhenStill("a") { ran.append("a1") }
    ChatScrollActivity.runWhenStill("a") { ran.append("a2") }
    ChatScrollActivity.runWhenStill("b") { ran.append("b1") }
    expect("held while moving", ran == ["a0"])
    expect("same key coalesces", ChatScrollActivity.pending.count == 2)

    now += 0.1
    ChatScrollActivity.noteMoving()
    now += 0.2
    ChatScrollActivity.drain()
    expect("still held while the fling continues", ran == ["a0"] && ChatScrollActivity.pending.count == 2)

    now += 0.15
    expect("quiet after the interval", !ChatScrollActivity.isMoving)
    ChatScrollActivity.drain()
    expect("drain runs the latest closure per key once", ran == ["a0", "a2", "b1"])
    expect("nothing left pending", ChatScrollActivity.pending.isEmpty)
    ChatScrollActivity.drain()
    expect("a second drain is a no-op", ran == ["a0", "a2", "b1"])
}
if fails > 0 { print("RESULT fail \(fails) check(s)") }
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-activity-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try ("import Foundation\nimport QuartzCore\n" + activityBlock).write(to: tmp.appendingPathComponent("activity.swift"), atomically: true, encoding: .utf8)
try tests.write(to: tmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let bin = tmp.appendingPathComponent("t")

print("ChatScrollActivity behaviour")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-suppress-warnings"]
                        + ["activity.swift", "main.swift"].map { tmp.appendingPathComponent($0).path }
                        + ["-o", bin.path])
if cc != 0 { print(ccOut); exit(1) }
let (_, out) = run(bin.path, [])
for line in out.split(separator: "\n") where line.hasPrefix("RESULT") {
    check(String(line.dropFirst(12)), line.hasPrefix("RESULT pass"))
}

print("Wiring")
check("chat list reports user-driven movement only",
      listSrc.contains("if scrollView.isTracking || scrollView.isDecelerating {\n                ChatScrollActivity.noteMoving()"))
check("home refresh is held while the chat list moves",
      refreshSrc.contains("if ChatScrollActivity.isMoving {\n            ChatScrollActivity.runWhenStill(\"home.refreshSessionList\") { refreshSessionList() }"))
check("cooldown timer waits out a fling before touching state",
      contentSrc.contains("while ChatScrollActivity.isMoving, !Task.isCancelled {"))
check("chat sync reload goes through the gate",
      vmSrc.contains("ChatScrollActivity.runWhenStill(\"chat.syncReload.\\(sid)\")"))
check("deferred chat reload re-checks session and in-flight send",
      vmSrc.contains("guard let self, self.sessionId == sid, Self.activeSessionId == sid else { return }\n                if self.isProcessing {\n                    self.pendingSyncReloadOnIdle = true"))

// [T-scroll-sync-pause] The inbound apply itself (main thread, 25 records a
// chunk) waits for the chat list to stop moving, within a budget.
check("each inbound chunk waits while the chat list moves",
      syncSrc.contains("while i < allRecords.count {\n                scrollWaitBudget = await Self.waitWhileChatScrolls(budget: scrollWaitBudget)"))
check("deletions wait too",
      syncSrc.contains("if !allDeletes.isEmpty {\n                scrollWaitBudget = await Self.waitWhileChatScrolls(budget: scrollWaitBudget)\n            }\n            for deleteId in allDeletes {"))
check("the wait is bounded per batch",
      syncSrc.contains("static let scrollPauseBudget: TimeInterval = 20")
      && syncSrc.contains("while left > 0, ChatScrollActivity.isMoving {"))

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
