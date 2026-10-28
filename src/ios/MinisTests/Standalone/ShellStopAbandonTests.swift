#!/usr/bin/env swift
// [T-shell-stop-abandon] + [T-ish-bind-host-op-unlocked]
//
// Field report 2026-10-02 (iPhone 17 Pro, app backgrounded, phone locked): a
// shell tool running `rm` / `cp` on a bind mount of Surge's iCloud folder
// hung 20+ minutes. Stop did nothing, the 900 s timeout did nothing, and no
// other guest process could start.
//
//   - fakefs called the host unlink() for a bind-mounted path while holding
//     the global meta.db lock; the File Provider blocked it, so the whole
//     guest queued behind that lock (deps/ish fs/fake.c).
//   - Stop only signalled and kept waiting for an exit a task blocked in a
//     host syscall cannot produce; the timeout ran its blocking kill BEFORE
//     handing back a result, on the serial killQueue.
//   - The stop button gated on a single pid slot that the first tap clears.
//
// Run: swift ShellStopAbandonTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func flat(_ s: String) -> String {
    s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

let coord = source("Agent/ISH/ISHExecutionCoordinator.swift")
let vm = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
let fake = (try? String(contentsOf: iosRoot.appendingPathComponent("../../deps/ish/fs/fake.c"), encoding: .utf8)) ?? ""

print("▶️  1. Stop abandons a command that does not exit")
check("every running command registers an abandon handle; completion and timeout unregister it",
      coord.contains("Self.registerAbandon(myId, sessionId: sessionId, ownerId: ownerId, abandon)")
      && coord.contains("guard claimResume() else { return }\n                timeoutWork?.cancel()\n                Self.unregisterAbandon(myId)")
      && coord.components(separatedBy: "Self.unregisterAbandon(myId)").count - 1 == 3)
check("abandon resumes exactly once (claimResume), with the partial output and why it stopped",
      coord.contains("func abandon() {\n                guard claimResume() else { return }")
      && coord.contains("[Stopped by user. The command did not exit within")
      && coord.contains("let output = outputEndingWith(notice, emptyNotice: notice)"))
check("abandon releases the reader context instead of leaking it",
      coord.contains("Self.killQueue.async { ISHShellExecutor.finalizeTimedOutPid(pid) }"))
check("Stop arms the abandon after the grace period, off killQueue, scoped like the kill",
      coord.contains("static let stopAbandonGrace: TimeInterval = 3")
      && coord.contains("let pending = abandonEntries(sessionId: sessionId, ownerId: ownerId)")
      && coord.contains("DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + stopAbandonGrace) {\n                for entry in pending { entry.abandon() }"))
check("abandon scoping follows the kill's owner rule (an entry without an owner belongs to its key)",
      coord.contains("(ownerId == nil || (e.ownerId ?? e.sessionId) == ownerId)"))

print("\n▶️  2. The timeout cannot be held back by a blocked kill")
check("timeout is scheduled off killQueue",
      coord.contains("DispatchQueue.global(qos: .utility).asyncAfter(\n                deadline: .now() + effectiveTimeout,\n                execute: work")
      && !coord.contains("Self.killQueue.asyncAfter"))
let timeoutBody = coord.components(separatedBy: "// Timeout safety net").last ?? ""
if let resume = timeoutBody.range(of: "continuation.resume(returning: ISHCommandResult(output: timedOutput, exitCode: -1))"),
   let kill = timeoutBody.range(of: "ISHShellExecutor.killProcessGroup(pid)") {
    check("timeout hands back its result BEFORE the (possibly blocking) kill", resume.lowerBound < kill.lowerBound)
    check("…and the kill + finalize run on killQueue afterwards",
          flat(timeoutBody).contains("Self.killQueue.async { // [T-ish-thread-leak]"))
} else {
    check("timeout body found", false)
}

print("\n▶️  3. The stop button asks the coordinator, not just the pid slot")
check("a second tap still stops: guard includes the coordinator's running commands",
      vm.contains("ISHExecutionCoordinator.hasStoppableCommand(sessionId: $0, ownerId: sessionId)")
      && vm.contains("guard !runningCommandPids.isEmpty || shellRunning || toolDelayWaitActive || browserLoading else {")
      && vm.contains("if !runningCommandPids.isEmpty || shellRunning {"))
check("a tap with nothing to stop is logged, not silent",
      vm.contains("⏹️ stopCurrentCommand — nothing to stop"))

print("\n▶️  4. fakefs: bind-mount host calls run outside the meta.db lock")
if fake.isEmpty {
    print("  ⚠️  deps/ish/fs/fake.c not found — skipped")
} else {
    func body(_ name: String) -> String {
        guard let r = fake.range(of: "static int \(name)(") else { return "" }
        let rest = fake[r.lowerBound...]
        guard let end = rest.range(of: "\n}\n") else { return "" }
        return String(rest[..<end.upperBound])
    }
    for (fn, call) in [("fakefs_unlink", "if (via_bind && unlink(host_abs) < 0)"),
                       ("fakefs_rmdir", "if (via_bind && rmdir(host_abs) < 0)"),
                       ("fakefs_mkdir", "if (via_bind && mkdir(host_abs, 0777) < 0)"),
                       ("fakefs_rename", "if (src_bind && rename(host_src, host_dst) < 0)")] {
        let b = body(fn)
        if let host = b.range(of: call), let lock = b.range(of: "db_begin_write(fs);") {
            check("\(fn): host call before db_begin_write", host.lowerBound < lock.lowerBound)
        } else {
            check("\(fn): host call and lock found", false)
        }
    }
    let stat = body("fakefs_stat")
    if let commit = stat.range(of: "release fs->lock before touching the host (File Provider paths). */\n        db_commit(fs);"),
       let host = stat.range(of: "if (stat(host_stat_path, &real_stat) < 0)") {
        check("fakefs_stat: lock released before the host stat on a bind path", commit.lowerBound < host.lowerBound)
    } else {
        check("fakefs_stat: release + host stat found", false)
    }
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
