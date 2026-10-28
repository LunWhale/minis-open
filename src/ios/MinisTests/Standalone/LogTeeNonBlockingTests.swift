#!/usr/bin/env swift
// [T-log-tee-nonblocking] Field 2026-10-02 19:10 (iPhone 17 Pro): the day's
// log file stopped growing while the app kept running. LoggingManager's
// writer tees every chunk back to the original stdout with a blocking
// write(); once that console stops being read (Xcode / devicectl over a Wi-Fi
// link that went away with the phone locked), the write never returns, the
// writer queue stalls and the reader drops every later chunk. A failed open
// of the log file also marked the day current, so it was never retried.
//
// Run: swift LogTeeNonBlockingTests.swift
import Foundation

signal(SIGPIPE, SIG_IGN)   // closing the read end below must not kill the test
var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let lm = (try? String(contentsOf: root.appendingPathComponent("Shared/LoggingManager.swift"), encoding: .utf8)) ?? ""

print("▶️  1. A full, unread pipe: non-blocking write returns, blocking write would hang")
var fds: [Int32] = [0, 0]
guard pipe(&fds) == 0 else { print("pipe failed"); exit(1) }
// Same helper as LoggingManager.setNonBlocking.
func setNonBlocking(_ fd: Int32, _ on: Bool) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
}
setNonBlocking(fds[1], true)
let chunk = [UInt8](repeating: 0x41, count: 4096)
var filled = 0
while true {
    let n = write(fds[1], chunk, chunk.count)
    if n < 0 { break }
    filled += n
    if filled > 16 * 1024 * 1024 { break }
}
let err = errno
check("filling the pipe stops with EAGAIN instead of blocking (filled \(filled) bytes)", err == EAGAIN)
let start = Date()
let n = write(fds[1], chunk, chunk.count)
check("one more tee write on the full pipe returns at once (dropped, not stuck)",
      n < 0 && errno == EAGAIN && Date().timeIntervalSince(start) < 0.5)
// The blocking case, bounded: a writer thread on a blocking fd must still be
// stuck after 1 s - the hang the fix removes.
setNonBlocking(fds[1], false)
let done = DispatchSemaphore(value: 0)
Thread.detachNewThread { _ = write(fds[1], chunk, chunk.count); done.signal() }
check("a BLOCKING write on the same full pipe is still stuck after 1 s", done.wait(timeout: .now() + 1) == .timedOut)
close(fds[0])   // unblocks the stuck writer (EPIPE)
_ = done.wait(timeout: .now() + 2)

print("\n▶️  2. LoggingManager wiring")
check("the saved stdout / stderr are switched to non-blocking when capture starts",
      lm.contains("origStderr = dup(STDERR_FILENO)\n        // [T-log-tee-nonblocking]")
      && lm.contains("Self.setNonBlocking(origStdout, true)\n        Self.setNonBlocking(origStderr, true)"))
check("…and back to blocking before they are restored",
      lm.contains("Self.setNonBlocking(origStdout, false)\n        Self.setNonBlocking(origStderr, false)\n        // Restore original fds"))
check("a missing handle re-opens (not only a new day), at most every 5 s",
      lm.contains("guard today != currentLogDate || logFileHandle == nil else { return }")
      && lm.contains("private static let reopenRetryInterval: TimeInterval = 5")
      && lm.contains("Date().timeIntervalSince(last) < Self.reopenRetryInterval { return }"))
check("the day is marked current only together with an open attempt, and a failure is reported on the console",
      lm.contains("logFileHandle?.seekToEndOfFile()\n        currentLogDate = today\n        if logFileHandle == nil {\n            lastOpenFailure = Date()"))
check("old logs are still pruned once per new day / launch, not on every re-open",
      lm.contains("lastOpenFailure = nil\n        guard dayChanged else { return }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
