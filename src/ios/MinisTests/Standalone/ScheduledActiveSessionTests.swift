#!/usr/bin/env swift
// [T-scheduled-active-session] A conversation with a scheduled follow-up of
// its own still due is ACTIVE: `SessionActivityTracker.busySessions` (= own
// loop running ∪ scheduled follow-up due ∪ sub agents working) is the one read
// point for background keep-alive, the composer's Stop, the list spinner and
// the app badge. The narrow `activeSessions` (own loop running) is untouched,
// and so is everything that depends on exactly that.
//
//   [1] the counting rule, extracted from AgentJobRegistry.swift between its
//       BEGIN/END markers and run over a decision table
//   [2] every job change re-derives the sets (jobs are mutated in place, so
//       `$jobs` alone would never see a timer end)
//   [3] the tracker's union and the surfaces that read it
//   [4] keep-alive has no job special case left, and its Live Activity
//       content still follows running loops only
//   [5] loop-only consumers still read the narrow set
//   [6] Stop / deletion cancel the conversation's timers
//
// Run: swift ScheduledActiveSessionTests.swift
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

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

/// The home screen sources - Views/ContentView/ plus Views/Settings/SettingsSheet.swift
/// and AppearanceSettingsView.swift, formerly the single file ContentView.swift -
/// read as one text with the files in path order.
func contentViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/ContentView")
    var files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    files += ["Views/Settings/SettingsSheet.swift", "Views/Settings/AppearanceSettingsView.swift"]
        .map { ios.appendingPathComponent($0) }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
func count(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }

let registry = src("Agent/Jobs/AgentJobRegistry.swift")
let runner = src("Agent/Jobs/ScheduledJobRunner.swift")
let tracker = src("Agent/Chat/ChatLifecycleSupport.swift")
let bka = src("Agent/Background/BackgroundKeepAliveManager.swift")
let bgTask = src("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
let content = contentViewSource()
let chatView = chatViewSource()
let store = chatStoreSource()
let vm = chatViewModelSource()
check("sources readable", ![registry, runner, tracker, bka, bgTask, content, chatView, store, vm].contains(where: \.isEmpty))

// MARK: - [1] the rule, compiled from source

print("▶️  1. which jobs keep their conversation active")
guard let a = registry.range(of: "// BEGIN sessionsKeptActiveBySchedule\n"),
      let b = registry.range(of: "// END sessionsKeptActiveBySchedule", range: a.upperBound..<registry.endIndex) else {
    print("❌ rule markers not found"); exit(1)
}
let rule = String(registry[a.upperBound..<b.lowerBound])
// The stub enums must carry exactly the real cases, or the extracted switch
// would compile against a different shape than it ships with.
for c in ["case immediate", "case once(after: TimeInterval)", "case loop(interval: TimeInterval, count: Int?)",
          "case onCompletion(ofJobId: String)", "case new", "case followUp(sessionId: String)",
          "case rerun(sessionId: String, messageId: String)", "case childOfCurrent(parentSessionId: String, parentToolUseId: String?)",
          "case pending, running, done, cancelled, failed"] {
    check("stub mirrors `\(c)`", registry.contains(c))
}
let harness = """
import Foundation
enum AgentJobState: String { case pending, running, done, cancelled, failed, timeout }
enum AgentJobTrigger: Equatable {
    case immediate
    case once(after: TimeInterval)
    case loop(interval: TimeInterval, count: Int?)
    case cron(hour: Int, minute: Int, days: Set<Int>, start: Date?, end: Date?)
    case onCompletion(ofJobId: String)
}
enum AgentJobTarget: Equatable {
    case new
    case followUp(sessionId: String)
    case rerun(sessionId: String, messageId: String)
    case childOfCurrent(parentSessionId: String, parentToolUseId: String?)
}
final class AgentJob {
    let trigger: AgentJobTrigger; let target: AgentJobTarget
    var state: AgentJobState; var isEnabled: Bool; var creatorSessionId: String?
    init(_ t: AgentJobTrigger, _ g: AgentJobTarget, _ s: AgentJobState = .pending, enabled: Bool = true, creator: String?) {
        trigger = t; target = g; state = s; isEnabled = enabled; creatorSessionId = creator
    }
}
final class Registry {
    var jobs: [String: AgentJob] = [:]
\(rule)
}
func active(_ jobs: [String: AgentJob]) -> Set<String> { let r = Registry(); r.jobs = jobs; return r.sessionsKeptActiveBySchedule }
let loop = AgentJobTrigger.loop(interval: 60, count: 3)
var out: [String] = []
out.append("followUpOwn=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), creator: "A")]) == ["A"])")
out.append("followUpRunning=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), .running, creator: "A")]) == ["A"])")
out.append("cron=\\(active(["j": AgentJob(.cron(hour: 9, minute: 0, days: [], start: nil, end: nil), .followUp(sessionId: "A"), creator: "A")]) == ["A"])")
out.append("once=\\(active(["j": AgentJob(.once(after: 30), .followUp(sessionId: "A"), creator: "A")]) == ["A"])")
out.append("followUpOther=\\(active(["j": AgentJob(loop, .followUp(sessionId: "B"), creator: "A")]).isEmpty)")
out.append("noCreator=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), creator: nil)]).isEmpty)")
out.append("newChat=\\(active(["j": AgentJob(loop, .new, creator: "A")]).isEmpty)")
out.append("child=\\(active(["j": AgentJob(loop, .childOfCurrent(parentSessionId: "A", parentToolUseId: nil), creator: "A")]).isEmpty)")
out.append("rerun=\\(active(["j": AgentJob(loop, .rerun(sessionId: "A", messageId: "m"), creator: "A")]).isEmpty)")
out.append("disabled=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), enabled: false, creator: "A")]).isEmpty)")
out.append("done=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), .done, creator: "A")]).isEmpty)")
out.append("cancelled=\\(active(["j": AgentJob(loop, .followUp(sessionId: "A"), .cancelled, creator: "A")]).isEmpty)")
out.append("immediate=\\(active(["j": AgentJob(.immediate, .followUp(sessionId: "A"), creator: "A")]).isEmpty)")
out.append("onCompletionLive=\\(active(["up": AgentJob(loop, .new, creator: nil), "j": AgentJob(.onCompletion(ofJobId: "up"), .followUp(sessionId: "A"), creator: "A")]) == ["A"])")
out.append("onCompletionMissing=\\(active(["j": AgentJob(.onCompletion(ofJobId: "gone"), .followUp(sessionId: "A"), creator: "A")]).isEmpty)")
out.append("onCompletionFinished=\\(active(["up": AgentJob(loop, .new, .done, creator: nil), "j": AgentJob(.onCompletion(ofJobId: "up"), .followUp(sessionId: "A"), creator: "A")]).isEmpty)")
print(out.joined(separator: "\\n"))
"""
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-active-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let file = tmp.appendingPathComponent("main.swift")
try? harness.write(to: file, atomically: true, encoding: .utf8)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
p.arguments = ["swift", file.path]
let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
try? p.run(); p.waitUntilExit()
let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
try? FileManager.default.removeItem(at: tmp)
let results = Set(output.split(separator: "\n").map(String.init))
check("rule compiles and runs", p.terminationStatus == 0)
if p.terminationStatus != 0 { print(output) }
func ok(_ k: String) -> Bool { results.contains("\(k)=true") }
check("follow-up into its own conversation, waiting → active", ok("followUpOwn"))
check("…also while a fire is running", ok("followUpRunning"))
check("cron and once timers count the same way", ok("cron") && ok("once"))
check("follow-up into a DIFFERENT conversation → not active", ok("followUpOther"))
check("made outside any conversation → not active", ok("noCreator"))
check("new chat / child-of-current / rerun targets → not active", ok("newChat") && ok("child") && ok("rerun"))
check("disabled, done, cancelled → not active", ok("disabled") && ok("done") && ok("cancelled"))
check("an immediate run is not a timer", ok("immediate"))
check("on-completion with a live upstream → active", ok("onCompletionLive"))
check("on-completion whose upstream is missing or finished → not active", ok("onCompletionMissing") && ok("onCompletionFinished"))

// MARK: - [2] every change re-derives

print("\n▶️  2. every job change re-derives the active sets")
check("jobsDidChange pushes both sets to the tracker",
      registry.contains("SessionActivityTracker.shared.setJobSessions(scheduled: sessionsKeptActiveBySchedule,\n                                                     delegating: parentsWithActiveChildren)"))
func body(_ text: String, from start: String, to end: String) -> String {
    guard let s = text.range(of: start), let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return "" }
    return String(text[s.lowerBound..<e.upperBound])
}
check("register", body(registry, from: "func register(title: String,", to: "return job\n    }").contains("jobsDidChange()"))
check("enable / disable", body(registry, from: "func setEnabled(jobId: String, enabled: Bool) {", to: "\n    }\n").contains("jobsDidChange()"))
check("remove", body(registry, from: "func remove(jobId: String) {", to: "\n    }\n").contains("jobsDidChange()"))
check("running", body(registry, from: "func markRunning(_ jobId: String, sessionId: String?) {", to: "\n    }\n").contains("jobsDidChange()"))
check("finish (and so cancel)", body(registry, from: "func finish(_ jobId: String, state final: AgentJobState", to: "// with fires left is re-armed by its producer, not here.\n        jobsDidChange()").isEmpty == false)
check("prune", body(registry, from: "func pruneFinished(olderThan age: TimeInterval = 3600) {", to: "\n    }\n").contains("jobsDidChange()"))
check("the delegation queue", registry.contains("private(set) var queuedDelegations: [QueuedDelegation] = [] {\n        didSet { jobsDidChange() }"))
check("any session activity (the time-based `looksStuck` has no event)", registry.contains("self?.drainIfStalled()\n") && registry.contains("self?.jobsDidChange()"))
check("arming — after the creator session is set", runner.contains("AgentJobRegistry.shared.jobsDidChange()"))
check("the old keep-alive-only set is gone", !registry.contains("sessionsAwaitingScheduledFire"))

// MARK: - [3] tracker

print("\n▶️  3. the tracker's active set and who reads it")
check("busy = running ∪ scheduled ∪ delegating",
      tracker.contains("let busy = activeSessions.union(scheduledSessions).union(delegatingSessions)"))
check("any change to the running set re-derives it", tracker.contains("@Published var activeSessions: Set<String> = [] {\n        didSet { recomputeBusy() }"))
check("publishes only on a real change", tracker.contains("guard busy != busySessions else { return }"))
check("isBusy resolves draft aliases", tracker.contains("if let realId = draftAliases[sessionId], busySessions.contains(realId) { return true }"))
check("list spinner + folder aggregates read it", content.contains("let activeIds = sidebarActivityTracker.resolvedBusySessionIds"))
check("…and the sidebar no longer unions the registry itself", !content.contains("sidebarJobRegistry"))
check("composer Stop reads it", chatView.contains("vm.isProcessing || hasRunningSubAgent || (vm.sessionId.map(tracker.isBusy) ?? false)"))
check("Stop says what it stops when only timers are left", chatView.contains("Text(\"Stop scheduled tasks\""))

// MARK: - [4] keep-alive

print("\n▶️  4. keep-alive follows the active set, with no job special case")
check("subscribes to busySessions + the toggle only",
      bka.contains("Publishers.CombineLatest(\n            SessionActivityTracker.shared.$busySessions,\n            $enhancedBackgroundEnabled\n        )"))
check("no job registry anywhere in keep-alive", !bka.contains("AgentJobRegistry"))
check("audio reclaim, debounce, interruption read the active set",
      bka.contains("let sessionCount = SessionActivityTracker.shared.busySessions.count\n        let wantsKeepAlive")
      && bka.contains("let sessionCount = SessionActivityTracker.shared.busySessions.count\n        let shouldDebounce"))
check("app badge counts active conversations", bka.contains("refreshActiveTaskBadge(\n            sessions: SessionActivityTracker.shared.busySessions,")
      && bka.contains("SessionActivityTracker.shared.$busySessions,\n            $backgroundNotificationsEnabled"))
// [T-live-activity-scheduled] The cards: running loops, plus a waiting card
// per conversation its own schedule keeps active (pill data, one source).
// Sub agent parents get no card: their sub agents have their own.
let lam = src("Agent/Background/AgentLiveActivityManager.swift")
let pillPage = src("Views/Chat/ScheduledTaskDetailView.swift")
check("Live Activity cards: running loops + waiting cards for scheduled conversations",
      bka.contains("let running = tracker.activeSessions.sorted().map")
      && bka.contains("for: tracker.scheduledSessions.subtracting(tracker.activeSessions).sorted(),")
      && bka.contains("return running + waiting")
      && tracker.contains("var liveActivitySessions: Set<String> { activeSessions.union(scheduledSessions) }"))
check("the manager's live filter is the card set everywhere (6 reads, none of activeSessions)",
      count(lam, "SessionActivityTracker.shared.liveActivitySessions") == 6
      && !lam.contains("SessionActivityTracker.shared.activeSessions"))
check("a waiting card is the pill's state + counter (no second computation)",
      pillPage.contains("guard let state = state(AgentJobRegistry.shared.scheduledBannerJobs(for: sid)) else { return nil }")
      && pillPage.contains("let counter = runCounter(state.job, running: firing)")
      && pillPage.contains("nextRunAt: state.phase == .countdown ? state.job.nextFireAt : nil,"))
check("a waiting card replaces an older completed card; finishing clears its countdown",
      count(lam, "for s in filteredInput where s.isScheduledWait {\n            completedSessionSnapshots.removeValue(forKey: s.sessionId)") == 2
      && lam.contains("c.scheduledWaiting = nil\n            c.nextRunAt = nil\n            c.runCounter = nil"))
check("scheduled set changes refresh the cards, except when nothing is busy (deactivation finishes instead)",
      tracker.contains("if scheduledChanged, !busySessions.isEmpty {\n            BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: \"scheduledSessions\")"))
check("Live Activity finish decision reads the active set", bgTask.contains("let otherActive = SessionActivityTracker.shared.busySessions"))
check("…and a run of a conversation its schedule keeps active neither finishes the activity nor marks it completed",
      bgTask.contains("let keptBySchedule = !sid.isEmpty && SessionActivityTracker.shared.scheduledSessions.contains(sid)")
      // [T-bgnotif-outcome] An interrupted turn's branch now sits between
      // them; the schedule check still comes first.
      && bgTask.contains("if keptBySchedule {\n                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: \"scheduledRunEnded\")\n                } else if outcome == .interrupted {"))
let widget = src("AgentWidget/AgentLiveActivityWidget.swift")
check("widget: a waiting card counts down with a system timer (no per-second pushes)",
      widget.contains("Text(timerInterval: Date()...max(next, Date()), countsDown: true)")
      && count(widget, "RunClock(session: session, startDate:") == 2
      && src("Shared/AgentActivityAttributes.swift").contains("var scheduledWaiting: Bool? = nil"))

// MARK: - [5] loop-only consumers

print("\n▶️  5. what means 'the loop is running' still reads exactly that")
let loopOnly: [(String, String)] = [
    ("keep screen awake", "Agent/Chat/ChatLifecycleSupport.swift"),
    ("AlwaysOn screen saver", "Agent/Chat/AlwaysOnController.swift"),
    ("Live Activity manager", "Agent/Background/AgentLiveActivityManager.swift"),
    ("Shortcuts completion", "Agent/Intents/ShortcutRunTracker.swift"),
    ("Shortcuts session status", "Agent/Intents/GetSessionStatusIntent.swift"),
    ("Resume banner", "Agent/MessageList/CollectionViewMessageListV3/"),
    ("load-time interrupted check", "Agent/Chat/AIChatViewModel+Persistence.swift"),
    ("iCloud send hold", "Agent/Chat/AIChatViewModel.swift"),
]
for (name, path) in loopOnly {
    let text = path == "Agent/Chat/AIChatViewModel.swift" ? chatViewModelSource()
        : path == "Agent/MessageList/CollectionViewMessageListV3/" ? messageListV3Source() : src(path)
    let usesBusy = path.hasSuffix("ChatLifecycleSupport.swift")
        ? text.components(separatedBy: "final class KeepScreenAwakeController")[safe: 1]?.contains("busySessions") ?? true
        : (text.contains("busySessions") || text.contains(".isBusy("))
    check("\(name) does not read the active set", !text.isEmpty && !usesBusy)
}

// MARK: - [6] Stop / deletion

print("\n▶️  6. Stop and deletion cancel the conversation's timers")
check("cancel() (every user-Stop path) still cancels the timers this chat created",
      vm.contains("AgentJobRegistry.shared.cancelScheduled(createdBy: sid,\n                                                    reason: \"user stopped the conversation\")"))
check("deleting a chat cancels its timers even without a cached VM (both funnels)",
      content.contains("AgentJobRegistry.shared.cancelScheduled(createdBy: sid, reason: \"sessionDeleted\", silent: true)")
      && store.contains("AgentJobRegistry.shared.cancelScheduled(createdBy: id, reason: \"sessionDeleted\", silent: true)"))
check("cancelScheduled can be silent", registry.contains("func cancelScheduled(createdBy sessionId: String, reason: String, silent: Bool = false) -> Int"))
let catalog = src("Localizable.xcstrings")
if let r = catalog.range(of: "\n    \"Stop scheduled tasks\" : {") {
    let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
    let entry = catalog[r.upperBound..<next]
    let missing = ["de", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
        .filter { !entry.contains("\"\($0)\" : {") }
    check("\"Stop scheduled tasks\" translated in all 18 locales\(missing.isEmpty ? "" : " — missing \(missing)")", missing.isEmpty)
} else { check("\"Stop scheduled tasks\" in the catalog", false) }

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
