#!/usr/bin/env swift
// [T-limits-per-parent] Concurrency caps: 6 session slots, 3 sub agents PER
// PARENT (outside the session slots), 10 queued delegations per parent, and a
// view model cache that cannot thrash against them.
//
//   [1] The shipping code, compiled (Mac Catalyst, so UIKit links) and driven:
//       - ConcurrencyLimits + LoadTestLimits (BEGIN/END ConcurrencyLimits)
//       - SessionSlotLease + SessionConcurrencyManager (BEGIN/END SessionSlots)
//       - AgentJobRegistry's per-parent queue / admission / drain blocks
//         (BEGIN/END PerParentQueue, PerParentAdmission, PerParentDrain), in a
//         harness class with the registry's stored state
//       - ViewModelCache, the whole class, against a stub view model
//   [2] Source guards for what cannot run outside the app: every agent-loop
//       entry pairs `acquireSessionSlot` with `release`, helpers are exempt,
//       HelperRunner / ScheduledJobRunner admit per parent with a reservation,
//       model-facing text names the per-parent cap, the debug overrides still
//       reach the new limits.
//
// Run: swift SessionLimitsPerParentTests.swift   (needs swiftc)
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

let lifecycle = source("Agent/Chat/ChatLifecycleSupport.swift")
let registrySrc = source("Agent/Jobs/AgentJobRegistry.swift")
guard let limitsBlock = between(lifecycle, "// BEGIN ConcurrencyLimits", "// END ConcurrencyLimits"),
      let slotsBlock = between(lifecycle, "// BEGIN SessionSlots", "// END SessionSlots"),
      let queueBlock = between(registrySrc, "// BEGIN PerParentQueue", "// END PerParentQueue"),
      let admissionBlock = between(registrySrc, "// BEGIN PerParentAdmission", "// END PerParentAdmission"),
      let drainBlock = between(registrySrc, "// BEGIN PerParentDrain", "// END PerParentDrain"),
      let vmcBody = between(lifecycle, "final class ViewModelCache {", "\n}\n"),
      let targetEnum = between(registrySrc, "enum AgentJobTarget", "\n}\n"),
      let stateEnum = between(registrySrc, "enum AgentJobState: String {", "\n}\n") else {
    print("❌ a BEGIN/END block or a type was not found"); exit(1)
}

let prelude = #"""
import Foundation
import UIKit
import Combine
struct AppLogger {
    init(category: String) {}
    func info(_ s: @autoclosure () -> String) {}
    func warning(_ s: @autoclosure () -> String) {}
    func error(_ s: @autoclosure () -> String) {}
}
let logger = AppLogger(category: "test")

/// Stub of the chat view model: only what ViewModelCache and the drain touch.
@MainActor final class AIChatViewModel {
    nonisolated(unsafe) static var activeSessionId: String?
    static var started: [(parent: String, toolUseId: String)] = []
    /// When set, a queued start registers its job as running (as the real start does).
    static var startHook: ((String, String) -> Void)?
    var sessionId: String?
    var isProcessing = false
    // [OpenMinis#433] read by ViewModelCache's new-chat parking
    var remoteDeviceId: String?
    var hasUnsentDraft = false
    var streamingUIUpdatesSuspended = false
    let vmInstanceId = String(UUID().uuidString.prefix(6))
    var released = false
    func cancel() {}
    func releaseForEviction() { released = true }
    func setStreamingUIUpdatesSuspended(_ s: Bool) { streamingUIUpdatesSuspended = s }
    func setSuspendedForTransition(_ s: Bool) {}
    func executeDelegateTaskQueued(args: [String: Any], toolUseId: String) async -> Bool {
        AIChatViewModel.started.append((sessionId ?? "-", toolUseId))
        AIChatViewModel.startHook?(sessionId ?? "-", toolUseId)
        return true
    }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var activeSessions: Set<String> = []
}
enum SelectableMarkdownView { static func dropAllRenderers() -> Int { 0 } }
struct InputAttachment { var cacheURL = URL(fileURLWithPath: "/dev/null") }
struct ChatSession { var isChild = false }
extension Notification.Name { static let sessionDidUpdate = Notification.Name("sessionDidUpdate") }
actor ChatStore {
    static let shared = ChatStore()
    func sessionExists(id: String) -> Bool { true }
}
"""#

let registryHarness = """
enum AgentJobTarget\(targetEnum)
}
enum AgentJobState: String {\(stateEnum)
}
@MainActor final class AgentJob {
    let id: String
    let target: AgentJobTarget
    var state: AgentJobState
    var runSessionId: String?
    init(id: String, target: AgentJobTarget, state: AgentJobState, runSessionId: String?) {
        self.id = id; self.target = target; self.state = state; self.runSessionId = runSessionId
    }
}
@MainActor final class AgentJobRegistry {
    static let shared = AgentJobRegistry()
    /// Mirrors the one-line shipping definition (pinned by a source check).
    static var maxChildJobsPerParent: Int { ConcurrencyLimits.childJobsPerParent }
    var jobs: [String: AgentJob] = [:]
    func jobsDidChange() {}
    func hasActiveChildren(parent: String) -> Bool {
        jobs.values.contains { $0.target.parentSessionId == parent && $0.state == .running }
    }
    static func cancelAll(parent: String) {}
\(queueBlock)
\(admissionBlock)
\(drainBlock)
}
"""

let vmc = "@MainActor\nfinal class ViewModelCache {" + vmcBody + "\n}\n"

let harness = #"""
func out(_ k: String, _ v: Any) { print("R \(k)=\(v)") }

@MainActor func runSessionSlots() async {
    let m = SessionConcurrencyManager.shared
    out("s.max", m.maxConcurrent)
    var leases: [SessionSlotLease] = []
    for i in 0..<6 { leases.append(try! await m.acquire(sessionId: "S\(i)", exempt: false)) }
    out("s.sixRunning", m.runningSessions.count)
    // A sub agent run with every slot taken: no wait, no slot.
    let helper = try! await m.acquire(sessionId: "CHILD", exempt: true)
    out("s.helperHolds", helper.holdsSlot)
    out("s.helperNotCounted", m.runningSessions.count == 6 && !m.runningSessions.contains("CHILD"))
    // A 7th conversation waits.
    var seventh: SessionSlotLease?
    let waiter = Task { @MainActor in seventh = try? await m.acquire(sessionId: "S6", exempt: false) }
    for _ in 0..<20 { await Task.yield() }
    out("s.seventhSuspended", m.isSuspended("S6") && seventh == nil)
    // Releasing the helper's lease must NOT free a slot or wake the waiter.
    m.release(helper)
    for _ in 0..<20 { await Task.yield() }
    out("s.helperReleaseNoop", m.isSuspended("S6") && m.runningSessions.count == 6)
    // A real release wakes it.
    m.release(leases.removeFirst())
    _ = await waiter.value
    out("s.seventhRuns", seventh?.holdsSlot == true && m.runningSessions.contains("S6") && m.runningSessions.count == 6)
    // Cancelled while queued: no lease, nothing to release, count intact.
    let cancelled = Task { @MainActor () -> SessionSlotLease? in try? await m.acquire(sessionId: "S7", exempt: false) }
    for _ in 0..<20 { await Task.yield() }
    let wasSuspended = m.isSuspended("S7")
    cancelled.cancel()
    m.cancelWait(sessionId: "S7")
    let got = await cancelled.value
    out("s.cancelledWhileQueued", wasSuspended && got == nil && !m.runningSessions.contains("S7") && m.runningSessions.count == 6)
    for l in leases { m.release(l) }
    if let s = seventh { m.release(s) }
    out("s.allReleased", m.runningSessions.isEmpty)
    #if DEBUG
    LoadTestLimits.sessionSlots = 9
    out("s.override", m.maxConcurrent)
    LoadTestLimits.sessionSlots = nil
    #endif
}

@MainActor func job(_ parent: String, _ n: Int, state: AgentJobState = .running) {
    let r = AgentJobRegistry.shared
    for i in 0..<n {
        let id = "\(parent)-job\(r.jobs.count)-\(i)"
        r.jobs[id] = AgentJob(id: id, target: .childOfCurrent(parentSessionId: parent, parentToolUseId: "tu-\(id)"),
                              state: state, runSessionId: "child-\(id)")
    }
}

@MainActor func runRegistry() async {
    let r = AgentJobRegistry.shared
    out("r.cap", AgentJobRegistry.maxChildJobsPerParent)
    out("r.queueCap", AgentJobRegistry.maxQueuedDelegationsPerParent)
    job("A", 3)
    out("r.aFull", !r.canStartChildJob(parent: "A"))
    out("r.bFree", r.canStartChildJob(parent: "B") && r.freeChildSlots(parent: "B") == 3)
    out("r.countA", r.runningChildJobCount(parent: "A"))
    // Per-parent queue cap: A fills 10, the 11th is refused; B unaffected.
    var accepted = 0
    for i in 0..<11 where r.enqueueDelegation(.init(parentSessionId: "A", args: [:], toolUseId: "qa\(i)")) { accepted += 1 }
    out("r.aQueued", accepted)
    out("r.bStillQueues", r.enqueueDelegation(.init(parentSessionId: "B", args: [:], toolUseId: "qb0")))
    // Head-of-line: A's ten come first and A is full; B's one must still start.
    let vmc = ViewModelCache.shared
    for p in ["A", "B", "C"] { _ = vmc.getOrCreate(for: p) }
    AIChatViewModel.started = []
    AIChatViewModel.startHook = { parent, tu in
        // The real start registers the job and only then drops the reservation.
        job(parent, 1)
        AgentJobRegistry.shared.releaseChildStart(key: tu)
    }
    r.drainQueuedDelegations()
    for _ in 0..<50 { await Task.yield() }
    out("r.hol.bStarted", AIChatViewModel.started.map(\.toolUseId) == ["qb0"])
    out("r.hol.aKeptInOrder", r.queuedDelegations.map(\.toolUseId) == (0..<10).map { "qa\($0)" })
    // A frees ONE slot: exactly one of A's starts, the oldest.
    if let done = r.jobs.values.first(where: { $0.target.parentSessionId == "A" && $0.state == .running }) { done.state = .done }
    AIChatViewModel.started = []
    r.drainQueuedDelegations()
    for _ in 0..<50 { await Task.yield() }
    out("r.oneFreeOneStart", AIChatViewModel.started.map(\.toolUseId) == ["qa0"])
    out("r.aFullAgain", !r.canStartChildJob(parent: "A") && r.queuedCount(parent: "A") == 9)
    // Reservations: C has 3 free; queue 5 with a start that does NOT register
    // (still between admission and markRunning) - only 3 may start.
    AIChatViewModel.startHook = nil
    AIChatViewModel.started = []
    for i in 0..<5 { _ = r.enqueueDelegation(.init(parentSessionId: "C", args: [:], toolUseId: "qc\(i)")) }
    r.drainQueuedDelegations()
    r.drainQueuedDelegations()   // a second pass in the same gap must not over-admit
    out("r.reservedNoOverAdmit", 5 - r.queuedCount(parent: "C"))
    for _ in 0..<50 { await Task.yield() }
    // ...but the drain Task releases each reservation when its start returns, so
    // with nothing registered as running C is free again and the rest start.
    r.drainQueuedDelegations()
    for _ in 0..<50 { await Task.yield() }
    out("r.reservationsReleased", r.childStartReservations.isEmpty || r.childStartReservations.values.allSatisfy { $0 != "C" } || r.queuedCount(parent: "C") == 0)
    // Own reservation is not counted against itself.
    r.reserveChildStart(key: "self", parent: "D")
    r.reserveChildStart(key: "d2", parent: "D")
    r.reserveChildStart(key: "d3", parent: "D")
    out("r.selfExcluded", !r.canStartChildJob(parent: "D") && r.canStartChildJob(parent: "D", excludingReservation: "self"))
    r.releaseChildStart(key: "self"); r.releaseChildStart(key: "d2"); r.releaseChildStart(key: "d3")
    out("r.releaseIdempotent", { r.releaseChildStart(key: "self"); return r.freeChildSlots(parent: "D") == 3 }())
    #if DEBUG
    LoadTestLimits.childJobs = 5
    out("r.override", AgentJobRegistry.maxChildJobsPerParent == 5 && r.canStartChildJob(parent: "A"))
    LoadTestLimits.childJobs = nil
    LoadTestLimits.queuedDelegations = 12
    out("r.queueOverride", AgentJobRegistry.maxQueuedDelegationsPerParent)
    LoadTestLimits.queuedDelegations = nil
    #endif
}

@MainActor func runVMCache() {
    let c = ViewModelCache()
    out("v.softCap", ViewModelCache.softCap)
    out("v.childCap", ViewModelCache.childSoftCap)
    // Six running conversations, then the user browses four others.
    for i in 0..<6 { let (vm, _) = c.getOrCreate(for: "run\(i)"); vm.isProcessing = true }
    for i in 0..<4 {
        AIChatViewModel.activeSessionId = "view\(i)"
        _ = c.getOrCreate(for: "view\(i)")
    }
    // poolCounts does not touch the LRU order; `get` would.
    out("v.browseNoEvict", c.poolCounts.normal == 10)
    out("v.runningKept", (0..<6).allSatisfy { c.get(for: "run\($0)") != nil })
    // An 11th: the least recently used IDLE one goes, never a running one.
    AIChatViewModel.activeSessionId = "view4"
    _ = c.getOrCreate(for: "view4")
    out("v.11thEvictsIdleLRU", c.get(for: "view0") == nil && (0..<6).allSatisfy { c.get(for: "run\($0)") != nil }
        && c.get(for: "view4") != nil)
    // Eighteen running children do not touch the normal pool.
    let before = c.poolCounts.normal
    var kids: [AIChatViewModel] = []
    for i in 0..<18 { let (vm, _) = c.getOrCreate(for: "kid\(i)", kind: .child); vm.isProcessing = true; kids.append(vm) }
    out("v.childrenSeparate", c.poolCounts.child == 18 && c.poolCounts.normal == before)
    out("v.runningChildrenKept", (0..<18).allSatisfy { c.get(for: "kid\($0)") != nil })
    // The 19th child, created while all 18 others run, is NOT evicted at birth.
    let (fresh, _) = c.getOrCreate(for: "kid18", kind: .child)
    out("v.newEntryKept", c.get(for: "kid18") === fresh)
    fresh.isProcessing = true; kids.append(fresh)
    // A child created by a caller that did not say `.child` still lands in the child pool.
    let r = AgentJobRegistry.shared
    r.jobs["sched"] = AgentJob(id: "sched", target: .childOfCurrent(parentSessionId: "P", parentToolUseId: ""),
                               state: .running, runSessionId: "schedKid")
    _ = c.getOrCreate(for: "schedKid")
    out("v.inferredChild", c.poolCounts.child == 20 && c.poolCounts.normal == before)
    // Children finish; the user is reading kid3's transcript.
    for k in kids { k.isProcessing = false }
    c.setOnScreen("kid3", true)
    _ = c.getOrCreate(for: "kidNew", kind: .child)
    out("v.finishedChildrenSwept", c.poolCounts.child <= ViewModelCache.childSoftCap + 1)
    out("v.viewedChildKept", c.get(for: "kid3") != nil)
    out("v.normalUntouchedBySweep", c.poolCounts.normal == before)
    c.setOnScreen("kid3", false)
    out("v.claimReleased", !c.isOnScreen("kid3"))
    #if DEBUG
    LoadTestLimits.sessionSlots = 12
    out("v.capFollowsSlots", ViewModelCache.softCap)
    LoadTestLimits.sessionSlots = nil
    #endif
}

@main struct Main {
    static func main() async {
        await runSessionSlots()
        await runRegistry()
        await MainActor.run { runVMCache() }
        out("ship", "\(ConcurrencyLimits.shippingSessionSlots)/\(ConcurrencyLimits.shippingChildJobsPerParent)/\(ConcurrencyLimits.shippingQueuedDelegationsPerParent)/\(ConcurrencyLimits.shippingToolsPerTurn)")
    }
}
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("limits_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? (prelude + "\n" + limitsBlock + "\n" + slotsBlock + "\n" + registryHarness + "\n" + vmc + "\n" + harness)
    .write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (_, sdkOut) = run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
let sdk = sdkOut.trimmingCharacters(in: .whitespacesAndNewlines)
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", "-parse-as-library", "-D", "DEBUG",
                                        "-target", "arm64-apple-ios17.0-macabi", "-sdk", sdk,
                                        "-Fsystem", sdk + "/System/iOSSupport/System/Library/Frameworks",
                                        "-I", sdk + "/System/iOSSupport/usr/include",
                                        mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. Session slots: 6, sub agent runs exempt, every lease paired")
check("shipping caps 6 sessions / 3 per parent / 10 queued per parent / 10 tools", r["ship"] == "6/3/10/10")
check("SessionConcurrencyManager allows 6", r["s.max"] == "6" && r["s.sixRunning"] == "6")
check("a sub agent run gets a lease that holds no slot, even with all 6 taken", r["s.helperHolds"] == "false" && r["s.helperNotCounted"] == "true")
check("a 7th conversation waits", r["s.seventhSuspended"] == "true")
check("releasing an exempt lease frees nothing and wakes nobody", r["s.helperReleaseNoop"] == "true")
check("a real release lets the waiter in", r["s.seventhRuns"] == "true")
check("cancelled while queued: no lease, no slot leaked or double-freed", r["s.cancelledWhileQueued"] == "true")
check("every lease returned leaves no slot held", r["s.allReleased"] == "true")
check("DEBUG override still reaches the session cap", r["s.override"] == "9")

print("\n2. Sub agents: 3 per parent, queue 10 per parent, no head-of-line blocking")
check("per-parent cap 3, queue cap 10", r["r.cap"] == "3" && r["r.queueCap"] == "10")
check("a parent with 3 running is full; another parent has all 3 free", r["r.aFull"] == "true" && r["r.bFree"] == "true" && r["r.countA"] == "3")
check("a parent queues 10, the 11th is refused", r["r.aQueued"] == "10")
check("another parent still queues when the first is at its queue cap", r["r.bStillQueues"] == "true")
check("drain starts B's item behind ten of full parent A (no head-of-line block)", r["r.hol.bStarted"] == "true")
check("…and keeps A's items waiting in order", r["r.hol.aKeptInOrder"] == "true")
check("one slot freed starts exactly one item - the parent's oldest", r["r.oneFreeOneStart"] == "true" && r["r.aFullAgain"] == "true")
check("reservations stop two drains in the same gap from over-admitting a parent", r["r.reservedNoOverAdmit"] == "3")
check("reservations are released when the start returns", r["r.reservationsReleased"] == "true")
check("a start is not counted against its own reservation", r["r.selfExcluded"] == "true")
check("releasing a reservation twice is harmless", r["r.releaseIdempotent"] == "true")
check("DEBUG overrides reach the per-parent caps", r["r.override"] == "true" && r["r.queueOverride"] == "12")

print("\n3. View model cache")
check("main pool cap 10 (> 6 slots), child pool 10", r["v.softCap"] == "10" && r["v.childCap"] == "10")
check("6 running conversations + browsing 4 others evicts nothing", r["v.browseNoEvict"] == "true" && r["v.runningKept"] == "true")
check("an 11th evicts the least recently used IDLE conversation, never a running one", r["v.11thEvictsIdleLRU"] == "true")
check("18 running sub agents live in the child pool and leave the main pool alone", r["v.childrenSeparate"] == "true" && r["v.runningChildrenKept"] == "true")
check("a vm created while its whole pool is busy is not evicted at birth", r["v.newEntryKept"] == "true")
check("a child job's session goes to the child pool even from a caller that did not say so", r["v.inferredChild"] == "true")
check("finished children are swept down to the child cap", r["v.finishedChildrenSwept"] == "true")
check("…except the one the user is reading", r["v.viewedChildKept"] == "true" && r["v.claimReleased"] == "true")
check("…and the sweep never touches the main pool", r["v.normalUntouchedBySweep"] == "true")
check("main cap follows the DEBUG session-slot override (stays above it)", r["v.capFollowsSlots"] == "16")

print("\n4. Wiring")
let send = source("Agent/Chat/AIChatViewModel+Send.swift")
let rerun = source("Agent/Chat/AIChatViewModel+Rerun.swift")
let gates = send.components(separatedBy: "guard let slotLease = await self.acquireSessionSlot(").count - 1
    + rerun.components(separatedBy: "guard let slotLease = await self.acquireSessionSlot(").count - 1
let releases = send.components(separatedBy: "defer { SessionConcurrencyManager.shared.release(slotLease) }").count - 1
    + rerun.components(separatedBy: "defer { SessionConcurrencyManager.shared.release(slotLease) }").count - 1
check("all 5 loop entries (send/retry/resume/resumeUnanswered/retryFromMessage) take a lease and defer its release",
      gates == 5 && releases == 5)
let allSwift = ["Agent", "Views", "NativeOffloads", "Debug", "Shared"].flatMap { dir -> [String] in
    let base = iosRoot.appendingPathComponent(dir)
    let files = (FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    return files.filter { $0.pathExtension == "swift" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
}.joined(separator: "\n")
check("nothing outside the manager acquires or releases a slot directly",
      !allSwift.contains("concurrency.acquireSlot(") && !allSwift.contains("concurrency.releaseSlot(")
      && lifecycle.contains("    private func acquireSlot(sessionId: String) async throws {")
      && lifecycle.contains("    private func releaseSlot(sessionId: String) {"))
check("the exemption is exactly 'this vm runs a sub agent'",
      send.contains("let exempt = helperConfig != nil") && send.contains("self.isSuspended = !exempt &&"))
check("no shipping code still names the old global caps",
      !allSwift.contains("maxConcurrentChildJobs") && !allSwift.contains("maxQueuedDelegations ")
      && !allSwift.contains("LoadTestLimits.sessionSlots ?? 5") && !allSwift.contains("Only 3 run at once"))
check("the registry's per-parent cap is the one-liner the harness mirrors",
      registrySrc.contains("static var maxChildJobsPerParent: Int { ConcurrencyLimits.childJobsPerParent }"))
let runner = source("Agent/Jobs/HelperRunner.swift")
check("delegation admission is per parent and not counted against its own reservation",
      runner.contains("registry.canStartChildJob(parent: parentSid, excludingReservation: toolUseId)")
      && runner.components(separatedBy: "registry.reserveChildStart(key: toolUseId, parent: parentSid)").count - 1 == 2
      && runner.components(separatedBy: "registry.releaseChildStart(key: toolUseId)   // [T-limits-per-parent] counted as running now").count - 1 == 2)
check("a full per-parent queue refuses with 'NOT queued' (delegation and resume)",
      runner.contains("more queued. Wait for some to finish, then delegate this task again — it was NOT queued.")
      && runner.contains("queued; it was NOT queued - resume it again once some finish"))
let sched = source("Agent/Jobs/ScheduledJobRunner.swift")
check("scheduled child-of-current waits for a per-parent slot, reserves it, uses the child pool",
      sched.contains("guard await waitForChildSlot(parent: parentSid, job: job) else {")
      && sched.contains("registry.reserveChildStart(key: slotReservation, parent: parentSid)")
      && sched.contains("registry.releaseChildStart(key: slotReservation)   // counted as running now")
      && sched.contains("getOrCreate(for: session.id, kind: .child)"))
check("run --id on a full parent returns deferred instead of blocking the CLI",
      sched.contains("return [\"fired\": false, \"deferred\": true, \"session_id\": NSNull()]")
      && source("NativeOffloads/ScheduledOffloadBridge.swift").contains("out[\"deferred\"] = true"))
check("the delegate tool tells the model the cap is per conversation",
      source("Agent/Chat/AIChatViewModel+ToolDefinitions.swift").contains("Only \\(AgentJobRegistry.maxChildJobsPerParent) of this conversation's sub agents run at once"))
let rpc = source("Debug/DebugJSONRPC.swift")
check("debug.loadtest.setLimits keeps its keys and accepts the per-parent aliases",
      rpc.contains("if let v = pick(\"childJobs\") ?? pick(\"childJobsPerParent\") { LoadTestLimits.childJobs = v }")
      && rpc.contains("if let v = pick(\"queuedDelegations\") ?? pick(\"queuedDelegationsPerParent\") { LoadTestLimits.queuedDelegations = v }"))
let sheet = source("Views/Chat/HelperSheet.swift")
check("the transcript sheet pins the child while shown and releases it on disappear",
      sheet.contains("ViewModelCache.shared.setOnScreen(target.id, true)") && sheet.contains("ViewModelCache.shared.setOnScreen(target.id, false)"))
check("an unwatched sub agent skips the attributed-string pre-render",
      source("Agent/Chat/AIChatViewModel+StreamingUI.swift").contains("if helperConfig != nil, let sid = sessionId, !ViewModelCache.shared.isOnScreen(sid) { return }"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
