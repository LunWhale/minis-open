// [T-scheduled-task-detail] A scheduled task's card opens its own page:
// parameters, a status derived from the task (never "Interrupted"), the run
// count and next run, the clean prompt, and every run so far.
//
// Before: the card opened the generic agent sheet, which read the fire's
// envelope `status="running"` as an interrupted agent run ("已中断") and showed
// the raw envelope text as the "result".
//
//   A. The page's pure model, compiled out of ScheduledTaskDetailView.swift:
//      status matrix, trigger parsing, prompt cleanup, coalesced count,
//      history merge.
//   B. Wiring: scheduled cards route to the page, other callbacks keep the
//      agent sheet; the job keeps an in-memory fire log; the chat store finds
//      a job's persisted fires; the page is in the Xcode target and localized.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift ScheduledTaskDetailTests.swift`

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

let page = src("Views/Chat/ScheduledTaskDetailView.swift")
let cell = src("Views/Chat/AgentCallbackCellView.swift")
let chat = chatViewSource()
let registry = src("Agent/Jobs/AgentJobRegistry.swift")
let store = chatStoreSource()
let pbx = src("Minis.xcodeproj/project.pbxproj")
let catalog = src("Localizable.xcstrings")
check("sources found", !page.isEmpty && !cell.isEmpty && !chat.isEmpty && !registry.isEmpty && !store.isEmpty)

// MARK: - A. compiled model

print("A. model (compiled from ScheduledTaskDetailView.swift)")
let model = between(page, "// [T-scheduled-task-detail] BEGIN scheduled-task-detail-model",
                    "// [T-scheduled-task-detail] END scheduled-task-detail-model")
check("model section found", model != nil)
if let model {
    let harness = #"""
    import Foundation
    \#(model)
    var out: [String] = []
    typealias M = ScheduledTaskDetailModel
    func live(_ state: String, enabled: Bool = true, busy: Bool = false) -> M.LiveJob {
        M.LiveJob(state: state, isEnabled: enabled, isProcessingNow: busy)
    }
    let loop = ScheduledTriggerSpec.loop(interval: 60, count: 30)
    // status matrix
    out.append("st:" + [
        M.status(live: live("pending"), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("pending", busy: true), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("running"), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("pending", enabled: false), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("cancelled"), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("failed"), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("timeout"), envelopeRemaining: 28, trigger: loop),
        M.status(live: live("done"), envelopeRemaining: 0, trigger: loop),
        M.status(live: nil, envelopeRemaining: 28, trigger: loop),
        M.status(live: nil, envelopeRemaining: 0, trigger: loop),
        M.status(live: nil, envelopeRemaining: nil, trigger: .once(after: 300)),
    ].map { "\($0)" }.joined(separator: ","))
    // trigger parsing
    let labels = ["loop(60s×30)", "loop(90s×∞)", "once(+300s)", "cron(9:05 days=[4, 2])", "cron(18:00 days=[])",
                  "immediate", "onCompletion(ab12cd34)", "weird(1)"]
    for l in labels { out.append("tr:\(l)=\(ScheduledTriggerSpec.parse(label: l))") }
    out.append("rep:\(ScheduledTriggerSpec.parse(label: "loop(60s×30)").isRepeating),\(ScheduledTriggerSpec.parse(label: "once(+300s)").isRepeating),\(ScheduledTriggerSpec.parse(label: "cron(9:05 days=[])").isRepeating)")
    out.append("total:\(String(describing: loop.totalCount)),\(String(describing: ScheduledTriggerSpec.loop(interval: 60, count: nil).totalCount))")
    // prompt cleanup
    let body = "[Scheduled task \"tsproxy-alive-watch\" · fire 2 · remaining 28 · loop(60s×30)]\n[This task's first step already ran for you: shell_execute — its call and output follow. Work from that output; re-run only if it failed.]\n检测 tsproxy daemon 是否存活 [PID 423]。"
    out.append("clean:\(M.cleanPrompt(body))")
    out.append("clean2:\(M.cleanPrompt("[Scheduled task \"x\" · fire 1 · loop(60s×2)]\nhello"))")
    out.append("clean3:\(M.cleanPrompt("plain prompt [not a prefix]"))")
    out.append("co:\(M.coalescedCount(in: "x<system-reminder>Scheduled task \"t\" also fired 3 more times while busy</system-reminder>")),\(M.coalescedCount(in: "nothing"))")
    // history merge
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let persisted: [M.PersistedFire] = [
        .init(index: 1, at: t0, sessionId: "HOST", coalesced: 0),
        .init(index: 2, at: t0.addingTimeInterval(60), sessionId: "HOST", coalesced: 2),
        .init(index: 3, at: t0.addingTimeInterval(120), sessionId: "OTHER", coalesced: 0),
    ]
    let memory: [M.MemoryFire] = [
        .init(index: 2, at: t0.addingTimeInterval(61), sessionId: "HOST", ok: true),
        .init(index: 4, at: t0.addingTimeInterval(180), sessionId: nil, ok: false),
    ]
    let rows = M.mergeHistory(persisted: persisted, memory: memory, currentIndex: 2, hostSessionId: "HOST", runningIndex: 4)
    out.append("hist:" + rows.map { "\($0.index.map(String.init) ?? "-")/ok=\($0.ok.map { "\($0)" } ?? "?")/cur=\($0.isCurrent)/other=\($0.isOtherSession)/run=\($0.isRunning)/co=\($0.coalesced)" }.joined(separator: "|"))
    let once = M.mergeHistory(persisted: [.init(index: nil, at: t0, sessionId: "S1", coalesced: 0),
                                          .init(index: nil, at: t0.addingTimeInterval(5), sessionId: "S2", coalesced: 0)],
                              memory: [], currentIndex: nil, hostSessionId: "S1", runningIndex: nil)
    out.append("once:" + once.map { $0.sessionId ?? "-" }.joined(separator: ","))
    print(out.joined(separator: "\n"))
    """#
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sched-detail-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? harness.write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    func line(_ prefix: String) -> String { output.split(separator: "\n").first { $0.hasPrefix(prefix) }.map(String.init) ?? "<missing \(prefix)>" }
    check("model compiles and runs", p.terminationStatus == 0)
    if p.terminationStatus != 0 { print(output) }

    check("status matrix: waiting, running(busy), running(state), disabled, cancelled, failed, timeout, done, stopped, done(0 left), done(once)",
          line("st:") == "st:waiting,running,running,disabled,cancelled,failed,timedOut,completed,stopped,completed,completed")
    check("status never says interrupted", !page.contains("case interrupted") && !line("st:").contains("interrupt"))
    check("loop with count", line("tr:loop(60s×30)") == "tr:loop(60s×30)=loop(interval: 60.0, count: Optional(30))")
    check("unbounded loop", line("tr:loop(90s×∞)") == "tr:loop(90s×∞)=loop(interval: 90.0, count: nil)")
    check("once", line("tr:once(+300s)") == "tr:once(+300s)=once(after: 300.0)")
    check("cron with days (sorted)", line("tr:cron(9:05") == "tr:cron(9:05 days=[4, 2])=cron(hour: 9, minute: 5, days: [2, 4])")
    check("cron every day", line("tr:cron(18:00") == "tr:cron(18:00 days=[])=cron(hour: 18, minute: 0, days: [])")
    check("immediate / onCompletion / unknown", line("tr:immediate") == "tr:immediate=immediate"
          && line("tr:onCompletion") == "tr:onCompletion(ab12cd34)=onCompletion(jobPrefix: \"ab12cd34\")"
          && line("tr:weird") == "tr:weird(1)=raw(\"weird(1)\")")
    check("repeating: loop yes, once no, cron yes", line("rep:") == "rep:true,false,true")
    check("total count only for a bounded loop", line("total:") == "total:Optional(30),nil")
    check("prompt: both machine prefixes stripped", line("clean:") == "clean:检测 tsproxy daemon 是否存活 [PID 423]。")
    check("prompt: round prefix alone stripped", line("clean2:") == "clean2:hello")
    check("prompt: a plain prompt is left alone", line("clean3:") == "clean3:plain prompt [not a prefix]")
    check("coalesced count parsed", line("co:") == "co:3,0")
    check("history: newest first, merged by index, memory ok + rerun-only run, flags",
          line("hist:") == "hist:4/ok=false/cur=false/other=false/run=true/co=0|3/ok=?/cur=false/other=true/run=false/co=0|2/ok=true/cur=true/other=false/run=false/co=2|1/ok=?/cur=false/other=false/run=false/co=0")
    check("un-indexed runs (once) kept, newest first", line("once:") == "once:S2,S1")
}

// MARK: - B. wiring

print("B. wiring")
check("scheduled cards open the task page, other callbacks keep the agent sheet",
      chat.contains("if target.opensScheduledTaskPage {\n                                // [T-scheduled-task-detail]")
      && chat.contains("ScheduledTaskDetailView(callback: target.callback,")
      && chat.contains("ToolLiveSheet(toolBlocks: [target.block], initialIdx: 0, browserPool: nil)")
      && cell.contains("var opensScheduledTaskPage: Bool { callback.kind == .scheduled }"))
check("the sheet closure reads the host session from the target, not the chat view",
      chat.contains("hostSessionId: target.hostSessionId)")
      && chat.contains("AgentCallbackDetailTarget(callback: cb, hostSessionId: vm.sessionId)"))
check("jobs keep an in-memory fire log on both fire paths (bounded)",
      registry.contains("appendFireLog(sessionId: sessionId, ok: nil)") && registry.contains("appendFireLog(sessionId: sessionId, ok: ok)")
      && registry.contains("static let fireLogLimit = 500"))
check("chat store finds a job's persisted fires and verifies the job id",
      store.contains("func scheduledFireMessages(jobId: String, limit: Int = 500)")
      && store.contains("guard let cb = AgentCallback.parse(text), cb.kind == .scheduled, cb.jobId == jobId else { continue }"))
check("page status is derived from the task via the model", page.contains("ScheduledTaskDetailModel.status(live: live, envelopeRemaining: callback.remaining, trigger: trigger)"))
check("running-now requires the session's last user turn to be this job's fire",
      page.contains("return cb.kind == .scheduled && cb.jobId == job.id"))
check("page is in the Minis target (build file + file ref + group + sources)",
      pbx.split(separator: "\n").filter { $0.contains("ScheduledTaskDetailView.swift") }.count == 4)
for key in ["Waiting for next run", "Running now", "Run history", "Next run", "Every %@ · %d runs", "A new chat for each run", "No runs yet"] {
    check("localized: \(key)", catalog.contains("\"\(key)\" : {"))
}

// Card subtitle: "Task complete" only on the last fire. Device run showed
// "Run 1 · 4 left · Task complete" on an old card whose next-fire time had
// passed while the task kept firing.
func isLastFire(next: String?, remaining: Int?) -> Bool { next?.isEmpty ?? true || remaining == 0 }
check("card: past next-fire with runs left is NOT 'Task complete'", !isLastFire(next: "2026-09-27T15:12:14Z", remaining: 4))
check("card: no next fire = last fire", isLastFire(next: nil, remaining: nil))
check("card: nothing left = last fire", isLastFire(next: "2026-09-27T15:12:14Z", remaining: 0))
check("source: card uses isLastFire", cell.contains("} else if Self.isLastFire(callback) {")
      && cell.contains("cb.nextFireAt?.isEmpty ?? true || cb.remaining == 0"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
