#!/usr/bin/env swift
// [T-shell-stop-owner] Stopping one agent must kill only the shell commands it
// issued. Parent and sub agents share a workspace key (`fsSessionId`), and the
// stop swept every pid under that key. Field-reproduced on iPhone 11
// (2026-09-26): stopping sub agent B1 signalled 2 pids — B1's and sibling B2's
// `sleep 90` (exit 15 after 19.7 s); B2 then reported "done" on a task it
// never finished, and the parent relayed it as completed.
//
// Run: swift ShellStopOwnerTests.swift
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

struct OwnedPid { let pid: Int32; let ownerId: String? }
/// Port of ISHExecutionCoordinator.stopAllNonisolated's target selection.
func targets(_ snap: [String: [OwnedPid]], sessionId: String?, ownerId: String?) -> [Int32] {
    var out: [Int32] = []
    for (sid, entries) in snap where sessionId == nil || sid == sessionId {
        for e in entries where e.pid > 0 {
            if let ownerId, (e.ownerId ?? sid) != ownerId { continue }
            out.append(e.pid)
        }
    }
    return out.sorted()
}
// Parent P runs one command; its sub agents B1 and B2 each run one; an MCP
// helper was filed with no owner under P's workspace.
let snap: [String: [OwnedPid]] = [
    "P": [OwnedPid(pid: 40, ownerId: "P"), OwnedPid(pid: 49, ownerId: "B1"),
          OwnedPid(pid: 52, ownerId: "B2"), OwnedPid(pid: 60, ownerId: nil)],
    "Q": [OwnedPid(pid: 70, ownerId: "Q")],
]
print("══ [1] who gets killed ══")
check("OLD (no owner filter): stopping B1 kills P, B1, B2 and the MCP helper", targets(snap, sessionId: "P", ownerId: nil) == [40, 49, 52, 60])
check("NEW: stopping B1 kills only B1's command", targets(snap, sessionId: "P", ownerId: "B1") == [49])
check("NEW: stopping B2 kills only B2's command", targets(snap, sessionId: "P", ownerId: "B2") == [52])
check("NEW: the parent's Stop kills its own command and the unowned one filed under it", targets(snap, sessionId: "P", ownerId: "P") == [40, 60])
check("another conversation is never touched", !targets(snap, sessionId: "P", ownerId: "P").contains(70))

print("\n══ [2] source ══")
let coord = source("Agent/ISH/ISHExecutionCoordinator.swift")
let cmd = source("Agent/Chat/AIChatViewModel+ISHCommand.swift")
let bg = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
check("in-flight entries carry the issuing session", coord.contains("let ownerId: String?") && coord.contains("InflightExec(id: myId, ownerId: ownerId, startTime: Date())"))
check("the lock-free snapshot keeps the owner", coord.contains("OwnedPid(pid: $0.pid, ownerId: $0.ownerId)"))
check("stop filters by owner (unowned = the workspace key)", coord.contains("if let ownerId, (entry.ownerId ?? sid) != ownerId { continue }"))
check("shell_execute files commands under the shared workspace but owned by this session",
      cmd.contains("ownerId: sessionId,"))
check("the user Stop passes its own session as owner",
      bg.contains("ISHExecutionCoordinator.stopAllNonisolated(sessionId: sid, ownerId: sessionId)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
