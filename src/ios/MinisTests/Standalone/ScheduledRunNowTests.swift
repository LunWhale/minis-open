#!/usr/bin/env swift
// [T-sched-run-now] "Run Now" in the scheduled-task pill's long-press menu.
//
// The item fires the run the pill counts down to, at once, through the armed
// timer's own loop. It must never execute a run twice: the timer and the tap
// both take ONE claim (pending -> firing), the tap re-decides from the live
// job, and the item exists only while the run has not started.
//
//   [1] ScheduledFireClaim, compiled from the shipping file
//   [2] a model of the runner's timer loop + runNow built on that claim:
//       (a) pending -> manual fire succeeds once
//       (b) firing / running / queued -> refused
//       (c) natural and manual fire racing, every interleaving -> one run
//       (d) double tap / rapid taps -> one run
//       (e) counted loop and cron consume each run once
//   [3] source guards: the runner and the pill really are wired that way
//   [4] the key covers every shipped locale
//
// Run: swift ScheduledRunNowTests.swift   (needs swiftc)
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

let runner = source("Agent/Jobs/ScheduledJobRunner.swift")
let pill = source("Views/Chat/ScheduledTaskDetailView.swift")
let registry = source("Agent/Jobs/AgentJobRegistry.swift")
guard let rules = between(runner, "// BEGIN ScheduledFireClaim", "// END ScheduledFireClaim") else {
    print("❌ ScheduledFireClaim not found"); exit(1)
}

let harness = #"""
import Foundation
typealias F = ScheduledFireClaim.Facts
func facts(_ mutate: (inout F) -> Void = { _ in }) -> F {
    var f = F(isEnabled: true, isPending: true, fireInFlight: false, isRunningOrQueued: false,
              hasTimedNextFire: true, kind: .loop)
    mutate(&f); return f
}
func out(_ k: String, _ v: Any) { print("R \(k)=\(v)") }

// ---- pure rules
out("offer.pending", ScheduledFireClaim.canRunNow(facts()))
out("offer.once", ScheduledFireClaim.canRunNow(facts { $0.kind = .once }))
out("offer.cron", ScheduledFireClaim.canRunNow(facts { $0.kind = .cron }))
out("offer.inflight", ScheduledFireClaim.canRunNow(facts { $0.fireInFlight = true }))
out("offer.running", ScheduledFireClaim.canRunNow(facts { $0.isRunningOrQueued = true }))
out("offer.disabled", ScheduledFireClaim.canRunNow(facts { $0.isEnabled = false }))
out("offer.finished", ScheduledFireClaim.canRunNow(facts { $0.isPending = false }))
out("offer.noTime", ScheduledFireClaim.canRunNow(facts { $0.hasTimedNextFire = false }))
out("offer.onCompletion", ScheduledFireClaim.canRunNow(facts { $0.kind = .onCompletion }))
out("offer.immediate", ScheduledFireClaim.canRunNow(facts { $0.kind = .immediate }))
var flag = false
let c1 = ScheduledFireClaim.claim(&flag), c2 = ScheduledFireClaim.claim(&flag)
flag = false
let c3 = ScheduledFireClaim.claim(&flag)
out("claim.seq", "\(c1),\(c2),\(c3)")
out("same", "\(ScheduledFireClaim.isSameRun(expected: 2, current: 2)),\(ScheduledFireClaim.isSameRun(expected: 2, current: 3)),\(ScheduledFireClaim.isSameRun(expected: nil, current: 9))")
let cal = Calendar(identifier: .gregorian)
let slot = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9))!
out("cron.natural", ScheduledFireClaim.cronSearchStart(now: slot.addingTimeInterval(0.5), consumedSlot: slot)
    .timeIntervalSince(slot))
out("cron.early", ScheduledFireClaim.cronSearchStart(now: slot.addingTimeInterval(-300), consumedSlot: slot)
    .timeIntervalSince(slot))

// ---- a model of ScheduledJobRunner on top of the real claim (same shape:
// a main-actor timer loop; fire = claim at the top, awaits, release at the end;
// runNow = canRunNow + claim, then re-arm with the first fire pre-claimed).
@MainActor final class Job {
    var fireInFlight = false
    var remaining: Int?
    var executions = 0
    var finished = false
    var runsDone: Int { executions }
    /// The chat is busy with the run a fire started (isProcessingNow).
    var running = false
    var nextFireAt: Date?
    var task: Task<Void, Never>?
    let interval: TimeInterval
    init(interval: TimeInterval, count: Int?) { self.interval = interval; remaining = count }
}
@MainActor enum Runner {
    static func facts(_ j: Job) -> F {
        F(isEnabled: true, isPending: !j.finished, fireInFlight: j.fireInFlight, isRunningOrQueued: j.running,
          hasTimedNextFire: j.nextFireAt != nil, kind: .loop)
    }
    static func fire(_ j: Job, claimed: Bool) async {
        if !claimed { guard ScheduledFireClaim.claim(&j.fireInFlight) else { return } }
        defer { j.fireInFlight = false }
        try? await Task.sleep(nanoseconds: 5_000_000)  // createSession / loadSession
        j.executions += 1                               // recordFire
        if let r = j.remaining { j.remaining = max(0, r - 1) }
        j.running = true                                // submitProgrammaticPrompt started the turn
        Task { @MainActor in try? await Task.sleep(nanoseconds: 2_000_000_000); j.running = false }
        await Task.yield()
    }
    static func arm(_ j: Job, first: TimeInterval, preclaimed: Bool = false) {
        j.task?.cancel()
        let start = preclaimed ? Date() : Date().addingTimeInterval(first)
        j.nextFireAt = start
        j.task = Task { @MainActor in
            var next = start
            var claimed = preclaimed
            while !Task.isCancelled {
                while next.timeIntervalSinceNow > 0 {
                    if Task.isCancelled { if claimed { j.fireInFlight = false }; return }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                if Task.isCancelled { if claimed { j.fireInFlight = false }; return }
                await fire(j, claimed: claimed)
                claimed = false
                if Task.isCancelled { return }
                if let r = j.remaining, r <= 0 { j.finished = true; j.nextFireAt = nil; return }
                next = Date().addingTimeInterval(j.interval)
                j.nextFireAt = next
            }
        }
    }
    @discardableResult
    static func runNow(_ j: Job, expectedRun: Int? = nil) -> Bool {
        guard ScheduledFireClaim.isSameRun(expected: expectedRun, current: j.runsDone),
              ScheduledFireClaim.canRunNow(facts(j)), j.nextFireAt != nil,
              ScheduledFireClaim.claim(&j.fireInFlight) else { return false }
        arm(j, first: 0, preclaimed: true)
        return true
    }
}
@MainActor func settle(_ ms: UInt64 = 40) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

@MainActor func scenarios() async {
    // (a) pending -> manual fire succeeds once.
    do {
        let j = Job(interval: 3600, count: nil); Runner.arm(j, first: 3600)
        let ok = Runner.runNow(j); await settle()
        out("a", "\(ok),\(j.executions),\(j.fireInFlight)")
        j.task?.cancel()
    }
    // (b) a fire in flight -> refused, and the in-flight fire runs once.
    do {
        let j = Job(interval: 3600, count: nil); Runner.arm(j, first: 0.005)
        var refusedWhileFiring = false
        for _ in 0..<400 {
            try? await Task.sleep(nanoseconds: 200_000)
            if j.fireInFlight { refusedWhileFiring = !Runner.runNow(j); break }
        }
        await settle()
        out("b", "\(refusedWhileFiring),\(j.executions)")
        j.task?.cancel()
    }
    // (c) natural and manual racing: tap at many offsets around the timer's
    // fire - before it, during its claim, during the run it started; every
    // case must execute exactly one run.
    var raceExecs: [Int] = []
    for k in 0..<12 {
        let j = Job(interval: 3600, count: nil)
        Runner.arm(j, first: 0.004)
        for _ in 0..<k { await Task.yield() }
        try? await Task.sleep(nanoseconds: UInt64(k) * 400_000)
        _ = Runner.runNow(j)
        await settle()
        raceExecs.append(j.executions)
        j.task?.cancel()
    }
    out("c", raceExecs.map(String.init).joined(separator: ","))
    // (d) double tap in the same turn, then a burst across turns.
    do {
        let j = Job(interval: 3600, count: nil); Runner.arm(j, first: 3600)
        let t1 = Runner.runNow(j), t2 = Runner.runNow(j)
        await Task.yield()
        let t3 = Runner.runNow(j)
        await settle()
        out("d", "\(t1),\(t2),\(t3),\(j.executions)")
        j.task?.cancel()
    }
    // (e) a counted loop: 3 runs; run the first one now, the rest by timer.
    do {
        let j = Job(interval: 0.01, count: 3); Runner.arm(j, first: 3600)
        Runner.runNow(j); Runner.runNow(j)
        try? await Task.sleep(nanoseconds: 200_000_000)
        out("e.loop", "\(j.executions),\(j.remaining ?? -1),\(j.finished)")
        j.task?.cancel()
    }
    // (c') the menu opened on run 1; the timer fires run 1 and its turn ends
    // before the tap lands. The tap names run 1, so it must not fire run 2.
    do {
        let j = Job(interval: 3600, count: nil); Runner.arm(j, first: 0.003)
        let shownRun = j.runsDone
        try? await Task.sleep(nanoseconds: 40_000_000)
        j.running = false                                // the run already ended
        let stale = Runner.runNow(j, expectedRun: shownRun)
        let fresh = Runner.runNow(j, expectedRun: j.runsDone)
        await settle()
        out("c2", "\(stale),\(fresh),\(j.executions)")
        j.task?.cancel()
    }
    // (e) one-shot (count 1): run now consumes it and the job ends.
    do {
        let j = Job(interval: 3600, count: 1); Runner.arm(j, first: 3600)
        Runner.runNow(j); await settle()
        out("e.once", "\(j.executions),\(j.finished),\(Runner.runNow(j))")
        j.task?.cancel()
    }
}
Task { @MainActor in await scenarios(); exit(0) }
RunLoop.main.run()
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-run-now-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Rules.swift": "import Foundation\n" + rules, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("[1] ScheduledFireClaim from the shipping file")
check("the rules block compiles on its own", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (status, out) = run(bin, [])
check("harness ran to the end", status == 0)
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = line.dropFirst(2)
    if let eq = body.firstIndex(of: "=") { r[String(body[..<eq])] = String(body[body.index(after: eq)...]) }
}
check("offered while counting down: loop / once / cron",
      r["offer.pending"] == "true" && r["offer.once"] == "true" && r["offer.cron"] == "true")
check("not offered: fire in flight / running or queued",
      r["offer.inflight"] == "false" && r["offer.running"] == "false")
check("not offered: disabled / finished / no timed run",
      r["offer.disabled"] == "false" && r["offer.finished"] == "false" && r["offer.noTime"] == "false")
check("not offered: on-completion / immediate", r["offer.onCompletion"] == "false" && r["offer.immediate"] == "false")
check("claim succeeds once until released", r["claim.seq"] == "true,false,true")
check("same run: matches only the run the menu showed; no expectation always matches",
      r["same"] == "true,false,true")
check("cron after a timer fire: searched from a minute after now (as before)", r["cron.natural"] == "60.5")
check("cron after Run now: searched from a minute after the consumed slot", r["cron.early"] == "60.0")

print("[2] Runner model on the real claim")
check("(a) pending → Run now starts one run and releases the claim", r["a"] == "true,1,false")
check("(b) while a fire is in flight Run now is refused; one run", r["b"] == "true,1")
let race = (r["c"] ?? "").split(separator: ",")
check("(c) natural vs manual, \(race.count) interleavings: exactly one run each (\(r["c"] ?? "-"))",
      race.count == 12 && race.allSatisfy { $0 == "1" })
check("(c') a tap for a run that already fired and ended does nothing (no early next run); a fresh tap works",
      r["c2"] == "false,true,2")
check("(d) double tap and a later tap: only the first starts; one run", r["d"] == "true,false,false,1")
check("(e) counted loop of 3: three runs in all, count consumed once each", r["e.loop"] == "3,0,true")
check("(e) one-shot: Run now consumes it, the job ends, a further tap is refused", r["e.once"] == "1,true,false")

print("[3] Source guards")
check("AgentJob carries the claim flag and the consumed cron slot",
      registry.contains("var fireInFlight = false") && registry.contains("var firingSlot: Date?"))
check("claimFire is the shared claim", runner.contains("static func claimFire(_ job: AgentJob) -> Bool {\n        ScheduledFireClaim.claim(&job.fireInFlight)"))
let fireHead = between(runner, "private static func fire(_ job: AgentJob, upstreamJobId: String? = nil, claimed: Bool = false) async -> String? {", "let registry = AgentJobRegistry.shared") ?? ""
check("every fire claims first (unless pre-claimed) and releases when it returns",
      fireHead.contains("if !claimed {\n            guard claimFire(job) else {") && fireHead.contains("defer { job.fireInFlight = false }")
      && fireHead.range(of: "guard claimFire(job)")!.lowerBound < fireHead.range(of: "defer { job.fireInFlight = false }")!.lowerBound)
let runNowFn = between(runner, "static func runNow(_ job: AgentJob, expectedRun: Int? = nil) -> Bool {", "\n    }\n") ?? ""
check("runNow: live re-check, then claim, then re-arm the timer loop with the slot",
      runNowFn.contains("guard ScheduledFireClaim.isSameRun(expected: expectedRun, current: runsDone(job)),\n              canRunNow(job), let slot = job.nextFireAt, claimFire(job) else {")
      && runNowFn.contains("arm(job, runNowSlot: slot)") && !runNowFn.contains("fire(job"))
check("runNow facts: running or queued counts as started",
      runner.contains("isRunningOrQueued: ScheduledTaskDetailStore.isProcessingNow(job) || isQueuedNow(job)"))
check("timer loops pass the pre-claim to the first fire only",
      runner.components(separatedBy: "await fire(job, claimed: claimed)\n                    claimed = false").count - 1 == 2
      && runner.contains("await fire(job, claimed: preclaimed)"))
check("a cancelled pre-claimed fire gives the claim back",
      runner.components(separatedBy: "if claimed { job.fireInFlight = false }").count - 1 == 2
      && runner.contains("if preclaimed { job.fireInFlight = false }"))
check("cron's following run is searched from the consumed slot, in the loop and in the card",
      runner.contains("from: ScheduledFireClaim.cronSearchStart(now: Date(), consumedSlot: slot)) else {")
      && runner.contains("consumedSlot: job.firingSlot ?? Date()))"))
check("menu: Run Now first, only while counting down and offered by the runner",
      pill.contains("if runNowOffered(jobId: jobId, phase: phase) {\n            Button { runNow(jobId, run: run) } label: {\n                Label(AppLocalized(\"Run Now\"), systemImage: \"play.fill\")")
      && pill.contains("guard phase == .countdown, let job = registry.job(id: jobId) else { return false }\n        return ScheduledJobRunner.canRunNow(job)"))
check("tap goes through the runner's claim, naming the run the menu showed",
      pill.contains("let started = ScheduledJobRunner.runNow(job, expectedRun: run)")
      && pill.contains(".contextMenu { menu(jobId: state.job.id, phase: state.phase, run: state.job.runsDone) }")
      && pill.contains("runNow(state.job.id, run: state.job.runsDone)"))
check("menu order: Run Now, Hide, Skip, Cancel all",
      { () -> Bool in
          let m = between(pill, "private func menu(jobId: String, phase: ScheduledBannerModel.Phase, run: Int) -> some View {", "private func menuDidOpen()") ?? ""
          let order = ["\"Run Now\"", "\"Hide This Countdown\"", "\"Skip Next Run\"", "\"Cancel All Scheduled Tasks\""].compactMap { m.range(of: $0)?.lowerBound }
          return order.count == 4 && order == order.sorted()
      }())
check("VoiceOver action only while offered", pill.contains(".accessibilityActions {\n            if runNowOffered(jobId: state.job.id, phase: state.phase) {"))

print("[4] Localization")
let catalogURL = iosRoot.appendingPathComponent("Localizable.xcstrings")
let catalog = (try? JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL))) as? [String: Any]
let strings = catalog?["strings"] as? [String: Any] ?? [:]
func locales(_ key: String) -> Set<String> {
    Set(((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
}
let shipped = locales("Skip Next Run")
let missing = shipped.subtracting(locales("Run Now"))
check("\"Run Now\" covers every locale \"Skip Next Run\" has (\(shipped.count))\(missing.isEmpty ? "" : " — missing \(missing.sorted())")",
      shipped.count >= 17 && missing.isEmpty)

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
