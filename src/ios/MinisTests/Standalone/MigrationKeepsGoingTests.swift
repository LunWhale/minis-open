#!/usr/bin/env swift
// [T-icloud-migration-keeps-going] The v1 -> v2 history migration keeps
// pushing until it is done instead of suspending after one 30-minute window.
//
// Field report 2026-09-30 (TestFlight 1.15): "this migration keeps pausing" -
// screenshot: in_progress, 483 / 59,570, "Paused - reopen Minis to continue",
// no way to continue. Phase 3 waited ONE 30-minute window and threw
// deferredUntilNextLaunch whenever the queue was not empty, however much that
// window pushed; nothing advanced the migration again until a cold launch.
// (Repro against the shipping loop: 2,400 pushed in the window, still
// suspended with 57,170 left.)
//
//   [1] The shipping drain (BEGIN/END MigrationDrainLoop in MigrationEngine.swift),
//       compiled and driven by a virtual clock through the user's scenario and
//       every stop condition: windows with progress continue; a window with none
//       suspends; throttling, the user's pause, no network and a suspended
//       process are waits, not stalls; the historical backlog must finish before
//       "drained"; cancellation stops; the auto-resume interval.
//   [2] Source guards for the wiring that needs the app: the phase uses the
//       drain, a stall still suspends without counting as a failure, runIfNeeded
//       clears the suspension when it drives, resume on foreground / sheet /
//       Continue, the UI says what it is doing, persisted state is unchanged.
//
// Run: swift MigrationKeepsGoingTests.swift   (needs swiftc)
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

let engine = source("Agent/Sync/V2/MigrationEngine.swift")
guard let drainBlock = between(engine, "// BEGIN MigrationDrainLoop", "// END MigrationDrainLoop") else {
    print("❌ MigrationDrainLoop block not found"); exit(1)
}

let harness = #"""
import Foundation
func out(_ k: String, _ v: Any) { print("R \(k)=\(v)") }

/// A simulated device: a virtual clock, a dirty queue that SyncCore drains at
/// `ratePer15s` records every 15 s while nothing blocks it, a pushed ledger,
/// and optional block / suspension / backlog schedules.
final class Sim {
    var t: Double = 0
    var dirty: Int
    var pushed = 0
    var ratePer15s: Int
    var lastPush: Double = 0
    var blockedUntil: Double = -1          // throttle window end
    var offlineUntil: Double = -1
    var userPausedUntil: Double = -1
    var stopPushingAt: Double = .infinity  // push chain dies here
    var backlogPendingUntil: Double = -1   // Phase B still staging until
    var backlogRestage: Int = 0            // records staged when Phase B's last pass lands
    var processSuspendAt: Double = -1      // one long suspension
    var processSuspendFor: Double = 0
    var cancelAt: Double = .infinity
    var sleeps = 0, blockedSleeps = 0, nudges = 0, windows: [MigrationDrain.WindowReport] = []
    init(dirty: Int, ratePer15s: Int) { self.dirty = dirty; self.ratePer15s = ratePer15s }
    func blocked() -> Bool { t < blockedUntil || t < offlineUntil || t < userPausedUntil }
    func advance(to target: Double) {
        // pushes happen only while unblocked and the chain is alive
        while lastPush + 15 <= target {
            lastPush += 15
            if lastPush < stopPushingAt, !(lastPush < blockedUntil || lastPush < offlineUntil || lastPush < userPausedUntil) {
                let n = min(ratePer15s, dirty); dirty -= n; pushed += n
            }
        }
        if backlogRestage > 0, target >= backlogPendingUntil, backlogPendingUntil > 0 {
            dirty += backlogRestage; backlogRestage = 0
        }
        t = target
    }
    func probe() -> MigrationDrain.Probe {
        MigrationDrain.Probe(
            dirtyTotal: { self.dirty },
            pushedCount: { self.pushed },
            historicalBacklogPending: { self.t < self.backlogPendingUntil || self.backlogRestage > 0 },
            externalBlock: {
                if self.t < self.userPausedUntil { return .userPaused(until: Date(timeIntervalSince1970: self.userPausedUntil)) }
                if self.t < self.blockedUntil { return .throttled(until: Date(timeIntervalSince1970: self.blockedUntil)) }
                if self.t < self.offlineUntil { return .offline }
                return nil
            },
            now: { Date(timeIntervalSince1970: self.t) },
            sleep: { s in
                self.sleeps += 1
                if self.blocked() { self.blockedSleeps += 1 }
                var target = self.t + s
                if self.processSuspendAt >= 0, self.t >= self.processSuspendAt {
                    target += self.processSuspendFor   // the app sat in the background
                    self.processSuspendAt = -1
                }
                self.advance(to: target)
            },
            isCancelled: { self.t >= self.cancelAt },
            nudgeSend: { self.nudges += 1 },
            onActivity: { _ in },
            onWindowEnd: { self.windows.append($0) }
        )
    }
}

func runSim(_ name: String, _ sim: Sim) async -> MigrationDrain.Outcome {
    let o = await MigrationDrain.run(sim.probe())
    let kind: String
    switch o {
    case .drained(let w): kind = "drained:\(w)"
    case .stalled(let r, let w): kind = "stalled:\(r):\(w)"
    }
    out("\(name).outcome", kind)
    out("\(name).hours", String(format: "%.1f", sim.t / 3600))
    out("\(name).nudges", sim.nudges)
    out("\(name).sleeps", sim.sleeps)
    out("\(name).blockedSleeps", sim.blockedSleeps)
    out("\(name).allWindowsProgressed", sim.windows.dropLast().allSatisfy(\.progressed))
    out("\(name).lastWindowProgressed", sim.windows.last?.progressed ?? true)
    out("\(name).windowActiveOK", sim.windows.allSatisfy { $0.activeSeconds >= MigrationDrain.windowSeconds && $0.activeSeconds < MigrationDrain.windowSeconds + 5 })
    return o
}

@main struct Main { static func main() async {
    // The reporter: 59,570 queued, 20 records / 15 s.
    _ = await runSim("user", Sim(dirty: 59_570, ratePer15s: 20))
    // Nothing ever pushes (dead chain, unexplained): one window, then suspend.
    _ = await runSim("dead", Sim(dirty: 5_000, ratePer15s: 0))
    // Pushes for 40 minutes, then the chain dies.
    let died = Sim(dirty: 50_000, ratePer15s: 20); died.stopPushingAt = 40 * 60
    _ = await runSim("died", died)
    // Rate-limited for 3 h right away, then normal.
    let thr = Sim(dirty: 2_000, ratePer15s: 20); thr.blockedUntil = 3 * 3600
    _ = await runSim("throttled", thr)
    // Offline for 2 h, then normal.
    let off = Sim(dirty: 2_000, ratePer15s: 20); off.offlineUntil = 2 * 3600
    _ = await runSim("offline", off)
    // The user paused sync for 90 min.
    let up = Sim(dirty: 2_000, ratePer15s: 20); up.userPausedUntil = 90 * 60
    _ = await runSim("userPaused", up)
    // The app is backgrounded for 4 h after 10 minutes (process suspended).
    let bg = Sim(dirty: 30_000, ratePer15s: 20); bg.processSuspendAt = 10 * 60; bg.processSuspendFor = 4 * 3600
    _ = await runSim("background", bg)
    // Queue drains to 0 while Phase B is still between passes; it stages 600 more.
    let bl = Sim(dirty: 200, ratePer15s: 20); bl.backlogPendingUntil = 20 * 60; bl.backlogRestage = 600
    _ = await runSim("backlog", bl)
    // Cancelled mid-drain.
    let cx = Sim(dirty: 50_000, ratePer15s: 20); cx.cancelAt = 600
    _ = await runSim("cancel", cx)

    let now = Date(timeIntervalSince1970: 100_000)
    out("ar.notSuspended", MigrationDrain.mayAutoResume(suspended: false, suspendedAt: nil, now: now))
    out("ar.legacy", MigrationDrain.mayAutoResume(suspended: true, suspendedAt: nil, now: now))
    out("ar.recent", MigrationDrain.mayAutoResume(suspended: true, suspendedAt: now.addingTimeInterval(-60), now: now))
    out("ar.old", MigrationDrain.mayAutoResume(suspended: true, suspendedAt: now.addingTimeInterval(-6 * 60), now: now))
    out("progressed.pushed", MigrationDrain.progressed(pushedStart: 10, pushedNow: 11, dirtyStart: 5, dirtyNow: 9))
    out("progressed.shrunk", MigrationDrain.progressed(pushedStart: 10, pushedNow: 10, dirtyStart: 9, dirtyNow: 5))
    out("progressed.none", MigrationDrain.progressed(pushedStart: 10, pushedNow: 10, dirtyStart: 5, dirtyNow: 7))
}}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("migdrain_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? ("import Foundation\n" + drainBlock + "\n" + harness).write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-parse-as-library", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}
func windows(_ outcome: String?) -> Int { Int(outcome?.split(separator: ":").last ?? "") ?? -1 }

print("1. The reporter's migration (59,570 records, 20 per 15 s)")
check("drains to the end instead of suspending", r["user.outcome"]?.hasPrefix("drained:") == true)
check("…across many 30-minute windows (one would have suspended it)", windows(r["user.outcome"]) > 20)
check("every window before the last made progress and the next one started",
      r["user.allWindowsProgressed"] == "true" && Int(r["user.nudges"] ?? "") == windows(r["user.outcome"]) - 1)
check("each window is 30 minutes of active time", r["user.windowActiveOK"] == "true")
check("takes the time the push rate implies (~12.4 h), no extra waiting", r["user.hours"].flatMap(Double.init).map { $0 > 12 && $0 < 13 } == true)

print("\n2. Stop conditions")
check("nothing ever pushes: suspends after exactly one window", r["dead.outcome"] == "stalled:5000:1" && r["dead.hours"] == "0.5")
// Pushes stop at minute 40: windows 1 (0-30) and 2 (30-60) both pushed, window 3 is empty.
check("pushes then the chain dies: suspends after exactly one empty window (window 3, at 1.5 h)",
      r["died.outcome"].map { $0.hasPrefix("stalled:") && $0.hasSuffix(":3") } == true && r["died.hours"] == "1.5"
      && r["died.allWindowsProgressed"] == "true")
check("…the stalled window is reported as no progress", r["died.lastWindowProgressed"] == "false")
check("rate-limited 3 h: a wait, not a stall - drains", r["throttled.outcome"]?.hasPrefix("drained:") == true)
check("…and waits in long sleeps, not 2-second polls (≤ 60 s each)",
      Int(r["throttled.blockedSleeps"] ?? "") ?? 9999 <= 3 * 60 + 2)
check("offline 2 h: drains afterwards", r["offline.outcome"]?.hasPrefix("drained:") == true
      && Int(r["offline.blockedSleeps"] ?? "") ?? 9999 <= 2 * 60 + 2)
check("paused by the user 90 min: drains afterwards", r["userPaused.outcome"]?.hasPrefix("drained:") == true)
check("4 h in the background is not counted as a stalled window", r["background.outcome"]?.hasPrefix("drained:") == true)
check("an empty queue is not 'drained' while the history scan still has sessions to stage",
      r["backlog.outcome"]?.hasPrefix("drained:") == true && r["backlog.hours"].flatMap(Double.init).map { $0 >= 0.3 } == true)
check("cancellation stops the drain", r["cancel.outcome"]?.hasPrefix("stalled:") == true && r["cancel.hours"] == "0.2")
check("progress = records pushed OR the queue shrank",
      r["progressed.pushed"] == "true" && r["progressed.shrunk"] == "true" && r["progressed.none"] == "false")

print("\n3. Resuming a suspended migration")
check("not suspended: nothing to resume", r["ar.notSuspended"] == "false")
check("suspended by an older build (no time recorded): resumes at once", r["ar.legacy"] == "true")
check("suspended a minute ago: waits (throttled causes are not re-hit on every app switch)", r["ar.recent"] == "false")
check("suspended 6 minutes ago: resumes", r["ar.old"] == "true")

print("\n4. Wiring")
let phase = between(engine, "private func phaseV2InitialPush(_ s: inout MigrationState) async throws {", "\n    }\n") ?? ""
check("Phase 3 waits through MigrationDrain, not one 30-minute deadline",
      phase.contains("let outcome = await MigrationDrain.run(drainProbe())")
      && !phase.contains("let deadline = Date().addingTimeInterval(30 * 60)"))
check("a stalled drain still suspends without counting as a failure",
      phase.contains("case .stalled(let remaining, let windows):")
      && phase.contains("throw MigrationError.deferredUntilNextLaunch(remaining: remaining)"))
check("the drain sees the user's pause, the iCloud throttle gate and the network",
      engine.contains("if let until = core.pausedUntil { return .userPaused(until: until) }")
      && engine.contains("if let gate = core.nextEarliestSendAt, gate > Date() { return .throttled(until: gate) }")
      && engine.contains("if !core.isNetworkSatisfied { return .offline }")
      && source("Agent/Sync/V2/SyncCore.swift").contains("let satisfied = path.status == .satisfied"))
check("…and waits for the historical backlog scan to finish staging",
      engine.contains("UserDefaults.standard.double(forKey: \"cloudSync.v2.backlogScanCursorAt\") > 0"))
check("windows log their pushes and rate; suspension logs its reason",
      engine.contains("window=\\(r.window) end: pushed=\\(r.pushedDelta)") && engine.contains("NO progress in")
      && engine.contains("UserDefaults.standard.set(\"phase=\\(state.phase.rawValue) remaining=\\(n)\", forKey: Self.suspendedReasonKey)"))
check("runIfNeeded clears the suspension (incl. one left by an older build) when it drives",
      engine.contains("resuming a suspended migration at phase=") && engine.contains("        Self.clearSuspended()\n"))
let resume = between(engine, "func resumeIfSuspended(trigger: String, force: Bool = false) async {", "\n    }\n") ?? ""
check("resume: only a requested, unfinished, suspended, idle migration; interval unless forced",
      resume.contains("guard SyncV2Bootstrap.isMigrationRequested, !isRunning else { return }")
      && resume.contains("guard status == .inProgress || status == .pending else { return }")
      && resume.contains("guard force ? suspended : MigrationDrain.mayAutoResume(") && resume.contains("await runIfNeeded()"))
check("resumes on foreground, on opening the sync page, and from Continue",
      source("Views/ContentView/ContentView.swift").contains("Task { await MigrationEngine.shared.resumeIfSuspended(trigger: \"foreground\") }")
      && source("Views/Sync/SyncMigrationDetailView.swift").contains("Task { await MigrationEngine.shared.resumeIfSuspended(trigger: \"syncSheet\") }")
      && source("Views/Sync/SyncMigrationDetailView.swift").contains("resumeIfSuspended(trigger: \"continueButton\", force: true)"))
let view = source("Views/Sync/SyncMigrationDetailView.swift")
check("the sheet no longer tells the user to reopen the app; it offers Continue and says what is happening",
      !view.contains("Text(\"Paused — reopen Minis to continue\")") && view.contains("Text(\"Continue Migration\")")
      && view.contains("AppLocalized(\"Waiting — iCloud rate limit until %@\")") && view.contains("AppLocalized(\"Waiting for network\")"))
check("'paused' is only shown while nothing is driving it",
      engine.contains("isSuspended: UserDefaults.standard.bool(forKey: Self.suspendedKey) && !isRunning,"))
check("the deferral text still says 'Deferred' (the legacy auto-recovery matches it)",
      engine.contains("return \"Deferred — \\(n) records still in queue, will resume automatically\""))
let stateStruct = between(engine, "struct MigrationState: Codable {", "\n}\n") ?? ""
check("persisted MigrationState is unchanged (older builds keep decoding it)",
      stateStruct.components(separatedBy: "    var ").count - 1 == 7
      && !stateStruct.contains("window") && !stateStruct.contains("suspend"))
let catalog = source("Localizable.xcstrings")
check("new strings are in the catalog with Chinese",
      ["\"Continue Migration\"", "\"Pushing (window %lld)\"", "\"Waiting — iCloud rate limit until %@\"",
       "\"Paused by you until %@\"", "\"Waiting for network\"", "\"Activity\"",
       "\"Paused — no progress for 30 minutes. Minis continues automatically when you come back to the app.\""]
        .allSatisfy { catalog.contains($0) } && catalog.contains("继续迁移"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
