#!/usr/bin/env swift
// [T-stream-watchdog-single-timer] Tests for StreamStallWatchdog, the per-stream
// stall watchdog in Agent/Chat/AIChatViewModel+SSEStream.swift.
//
// The SSE loop used to race every event against a fresh 120s Task.sleep; a
// TestFlight build on iOS 27.0.1 crashed inside that sleep's dispatch_after
// ("BUG IN CLIENT OF LIBDISPATCH: Setting interval to 0"). The watchdog replaces
// it with one tick task per stream and a timer-free racer. This compiles the
// SHIPPING class and checks:
//   [1] an event that wins releases the racer (no hang, no throw)
//   [2] a cancel that lands before the continuation is stored still resumes it
//   [3] fire() throws into the waiting racer, and into any later wait
//   [4] waitStart is only set while the loop waits (processing is not stall time)
//   [5] source guards: the loop no longer sleeps per event; one tick per stream
//
// Run: swift StreamStallWatchdogTests.swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let file = root.appendingPathComponent("Agent/Chat/AIChatViewModel+SSEStream.swift")
guard let src = try? String(contentsOf: file, encoding: .utf8) else { print("❌ cannot read \(file.path)"); exit(1) }

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

guard let start = src.range(of: "private final class StreamStallWatchdog"),
      let end = src.range(of: "// MARK: - Background SSE Stream Processing", range: start.upperBound..<src.endIndex) else {
    print("❌ could not extract StreamStallWatchdog"); exit(1)
}
let classSource = String(src[start.lowerBound..<end.lowerBound])

let harness = #"""
import Foundation
struct Stall: Error {}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async -> String {
    await withTaskGroup(of: String.self) { g in
        g.addTask { do { _ = try await op(); return "returned" } catch is Stall { return "threw" } catch { return "error:\(error)" } }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return "timeout" }
        let r = await g.next()!
        g.cancelAll()
        return r
    }
}

func valueWithTimeout(_ seconds: Double, _ op: @escaping @Sendable () async -> String) async -> String {
    await withTaskGroup(of: String.self) { g in
        g.addTask { await op() }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return "timeout" }
        let r = await g.next()!
        g.cancelAll()
        return r
    }
}

@main struct Main {
    static func main() async {
        // [1] event wins: racer released by cancelAll
        let w1 = StreamStallWatchdog()
        let r1 = await withTimeout(2) {
            try await withThrowingTaskGroup(of: Int?.self) { group in
                group.addTask { try await Task.sleep(nanoseconds: 20_000_000); return 7 }
                group.addTask { try await w1.wait(); return nil }
                let v = try await group.next()!
                group.cancelAll()
                return v ?? -1
            }
        }
        print("EVENT_WINS=\(r1)")

        // [1b] many rounds in a row (what a streaming reply does)
        let w1b = StreamStallWatchdog()
        let r1b = await withTimeout(5) {
            for i in 0..<500 {
                w1b.beginWait(at: Date())
                let v = try await withThrowingTaskGroup(of: Int?.self) { group in
                    group.addTask { await Task.yield(); return i }
                    group.addTask { try await w1b.wait(); return nil }
                    let v = try await group.next()!
                    group.cancelAll()
                    return v
                }
                w1b.endWait()
                if v != i { throw Stall() }
            }
            return 0
        }
        print("ROUNDS_500=\(r1b)")

        // [2] already-cancelled task: wait returns at once
        let w2 = StreamStallWatchdog()
        let t2 = Task { () -> String in
            while !Task.isCancelled { await Task.yield() }
            do { try await w2.wait(); return "returned" } catch { return "threw" }
        }
        t2.cancel()
        let r2 = await valueWithTimeout(2) { await t2.value }
        print("PRECANCEL=\(r2)")

        // [3] fire throws into the waiter, then into later waits
        let w3 = StreamStallWatchdog()
        let t3 = Task { () -> String in
            do { try await w3.wait(); return "returned" } catch is Stall { return "threw" } catch { return "other" }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        w3.fire(Stall())
        let r3 = await valueWithTimeout(2) { await t3.value }
        print("FIRE=\(r3)")
        let r3b = await withTimeout(2) { try await w3.wait(); return 0 }
        print("AFTER_FIRE=\(r3b)")

        // [4] waitStart only while waiting
        let w4 = StreamStallWatchdog()
        let before = w4.waitStart == nil
        w4.beginWait(at: Date(timeIntervalSince1970: 100))
        let during = w4.waitStart == Date(timeIntervalSince1970: 100)
        w4.endWait()
        let after = w4.waitStart == nil
        print("WAITSTART=\(before && during && after)")
    }
}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let classFile = tmp.appendingPathComponent("Watchdog.swift")
let mainFile = tmp.appendingPathComponent("main.swift")
try! ("import Foundation\n" + classSource.replacingOccurrences(of: "private final class StreamStallWatchdog", with: "final class StreamStallWatchdog")).write(to: classFile, atomically: true, encoding: .utf8)
try! harness.write(to: mainFile, atomically: true, encoding: .utf8)

func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("wd").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-o", bin, classFile.path, mainFile.path])
guard cs == 0 else { print("❌ compile failed:\n\(cout)"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") {
    guard let eq = line.firstIndex(of: "=") else { continue }
    r[String(line[..<eq])] = String(line[line.index(after: eq)...])
}

print("▶️  1. an event that wins releases the racer")
check("the event is returned, the racer does not hang or throw", r["EVENT_WINS"] == "returned")
check("500 consecutive rounds complete (a streaming reply)", r["ROUNDS_500"] == "returned")
print("▶️  2. cancellation before the continuation is stored")
check("wait() on an already-cancelled task returns at once", r["PRECANCEL"] == "returned")
print("▶️  3. firing")
check("fire() throws into the waiting racer", r["FIRE"] == "threw")
check("a wait after firing throws immediately", r["AFTER_FIRE"] == "threw")
print("▶️  4. stall time is waiting time only")
check("waitStart is set by beginWait and cleared by endWait", r["WAITSTART"] == "true")

print("▶️  5. source guards")
let loop = src.components(separatedBy: "let stallTick = Task {").last ?? ""
check("the racer waits on the watchdog, not on a per-event sleep",
      src.contains("try await stallWatchdog.wait()")
      && !src.contains("try await Task.sleep(nanoseconds: UInt64(stallTimeoutSeconds * 1_000_000_000))"))
check("one tick task per stream, cancelled when processing ends",
      src.contains("let stallTick = Task {") && src.contains("defer { stallTick.cancel() }"))
check("the loop marks waiting around each next()",
      loop.contains("stallWatchdog.beginWait(at: Date())") && loop.contains("stallWatchdog.endWait()"))
check("the stall still surfaces as the retryable LLMError",
      src.contains("stallWatchdog.fire(LLMError.transientError(message: \"No response from the server for"))

print("")
print(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")
if failures > 0 { print(out) }
exit(failures == 0 ? 0 : 1)
