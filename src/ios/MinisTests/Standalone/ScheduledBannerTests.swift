#!/usr/bin/env swift
// [T-scheduled-banner] The chat's top banner: "next run of <task> in 00:48".
//
//   [1] the pure model (which job, which phase, countdown text, ring share),
//       compiled out of ScheduledTaskDetailView.swift between its markers
//   [2] data source: published from AgentJobRegistry.jobsDidChange (no poll)
//   [3] mounting, ticking, tap route, accessibility, styling
//   [4] localization
//
// Run: swift ScheduledBannerTests.swift
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

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String { (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
let page = src("Views/Chat/ScheduledTaskDetailView.swift")
let chat = chatViewSource()
let registry = src("Agent/Jobs/AgentJobRegistry.swift")
let runner = src("Agent/Jobs/ScheduledJobRunner.swift")
let catalog = src("Localizable.xcstrings")
check("sources readable", ![page, chat, registry, runner, catalog].contains(where: \.isEmpty))

// MARK: - [1] model

print("▶️  1. model (compiled from ScheduledTaskDetailView.swift)")
guard let a = page.range(of: "// [T-scheduled-banner] BEGIN scheduled-banner-model\n"),
      let b = page.range(of: "// [T-scheduled-banner] END scheduled-banner-model", range: a.upperBound..<page.endIndex) else {
    print("❌ model markers not found"); exit(1)
}
let model = String(page[a.upperBound..<b.lowerBound])
let harness = "import Foundation\n" + model + #"""
let t0 = Date(timeIntervalSince1970: 1_000_000)
func job(_ id: String, next: TimeInterval?, start: TimeInterval = -60, left: Int? = nil, firing: Bool = false, title: String = "t") -> ScheduledBannerJob {
    ScheduledBannerJob(id: id, title: title, nextFireAt: next.map { t0.addingTimeInterval($0) },
                       windowStart: t0.addingTimeInterval(start), remaining: left, isFiringNow: firing)
}
func show(_ s: ScheduledBannerModel.State?) -> String {
    guard let s else { return "nil" }
    let p: String = switch s.phase { case .countdown: "countdown"; case .running: "running"; case .waiting: "waiting" }
    return "\(s.job.id):\(p):+\(s.others)"
}
var out: [String] = []
out.append("empty=\(show(ScheduledBannerModel.state([])))")
out.append("one=\(show(ScheduledBannerModel.state([job("a", next: 48)])))")
out.append("soonest=\(show(ScheduledBannerModel.state([job("late", next: 600), job("soon", next: 30), job("mid", next: 90)])))")
out.append("firingWins=\(show(ScheduledBannerModel.state([job("soon", next: 5), job("run", next: 600, firing: true)])))")
out.append("waitOnly=\(show(ScheduledBannerModel.state([job("w", next: nil)])))")
out.append("timedBeatsWait=\(show(ScheduledBannerModel.state([job("w", next: nil), job("t", next: 3000)])))")
for (k, v) in [("c48", 48.0), ("c72", 72.0), ("c59_2", 59.2), ("c0_2", 0.2), ("c0", 0.0), ("cneg", -5.0), ("c3599", 3599.0), ("c3599_5", 3599.5), ("c3600", 3600.0), ("c86400", 86_400.0)] {
    out.append("\(k)=\(ScheduledBannerModel.countdown(v) ?? "nil")")
}
let half = job("h", next: 60, start: -60)
out.append("pHalf=\(ScheduledBannerModel.progress(half, now: t0))")
out.append("pStart=\(ScheduledBannerModel.progress(half, now: t0.addingTimeInterval(-60)))")
out.append("pPast=\(ScheduledBannerModel.progress(half, now: t0.addingTimeInterval(500)))")
out.append("pBefore=\(ScheduledBannerModel.progress(half, now: t0.addingTimeInterval(-500)))")
out.append("pNoNext=\(ScheduledBannerModel.progress(job("n", next: nil), now: t0))")
out.append("pZero=\(ScheduledBannerModel.progress(job("z", next: 0, start: 0), now: t0))")
// [T-sched-pill-count] run counter
func counted(done: Int, total: Int?, repeats: Bool = true) -> ScheduledBannerJob {
    var j = job("c", next: 60); j.runsDone = done; j.runTotal = total; j.repeats = repeats; return j
}
out.append("rFirst=\(ScheduledBannerModel.runCounter(counted(done: 0, total: 30), running: false) ?? "nil")")
out.append("rNext=\(ScheduledBannerModel.runCounter(counted(done: 1, total: 30), running: false) ?? "nil")")
out.append("rRunning=\(ScheduledBannerModel.runCounter(counted(done: 2, total: 30), running: true) ?? "nil")")
out.append("rAfterSkip=\(ScheduledBannerModel.runCounter(counted(done: 1 + 1, total: 30), running: false) ?? "nil")")
out.append("rCap=\(ScheduledBannerModel.runCounter(counted(done: 30, total: 30), running: false) ?? "nil")")
out.append("rUnbounded=\(ScheduledBannerModel.runCounter(counted(done: 6, total: nil), running: false) ?? "nil")")
out.append("rOnce=\(ScheduledBannerModel.runCounter(counted(done: 0, total: nil, repeats: false), running: false) ?? "nil")")
out.append("rRunningFirst=\(ScheduledBannerModel.runCounter(counted(done: 0, total: 5), running: true) ?? "nil")")
// [T-sched-pill-menu] hide / skip
func dis(_ live: Set<String>, _ hidden: Set<String>) -> Bool { ScheduledBannerModel.isDismissed(live: live, hidden: hidden) }
out.append("dHidden=\(dis(["a", "b"], ["a", "b"]))")
out.append("dNewJob=\(dis(["a", "b", "c"], ["a", "b"]))")
out.append("dOneLeft=\(dis(["b"], ["a", "b"]))")
out.append("dNone=\(dis([], ["a"]))")
out.append("dNever=\(dis(["a"], []))")
func plan(_ p: ScheduledBannerModel.SkipPlan) -> String {
    switch p {
    case .cancel: return "cancel"
    case .rearm(let at, let r): return "rearm+\(Int(at.timeIntervalSince(t0))):\(r.map(String.init) ?? "nil")"
    }
}
let every120: (Date) -> Date? = { $0.addingTimeInterval(120) }
out.append("sLoop=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: 30, following: every120)))")
out.append("sLoopUnbounded=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: nil, following: every120)))")
out.append("sLoopLast=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: 1, following: every120)))")
out.append("sLoopTwo=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: 2, following: every120)))")
out.append("sOnce=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: nil, following: { _ in nil })))")
out.append("sOnCompletion=\(plan(ScheduledBannerModel.skipPlan(next: nil, remaining: nil, following: every120)))")
out.append("sCronEnds=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: nil, following: { _ in nil })))")
out.append("sCron=\(plan(ScheduledBannerModel.skipPlan(next: t0.addingTimeInterval(60), remaining: nil, following: { $0.addingTimeInterval(86_400) })))")
// the pill then counts down to the run after the skipped one
let skipped = job("k", next: 60 + 120, start: 60)
out.append("sCountdown=\(ScheduledBannerModel.countdown(skipped.nextFireAt!.timeIntervalSince(t0)) ?? "nil")")
print(out.joined(separator: "\n"))
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sched-banner-\(UUID().uuidString)")
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
check("model compiles and runs", p.terminationStatus == 0)
if p.terminationStatus != 0 { print(output) }
let r = Set(output.split(separator: "\n").map(String.init))
func has(_ s: String) -> Bool { r.contains(s) }
check("no live job → no banner", has("empty=nil"))
check("one job → countdown, nothing else", has("one=a:countdown:+0"))
check("several → the soonest next fire, the rest counted (+2)", has("soonest=soon:countdown:+2"))
check("a job running right now wins over a sooner one", has("firingWins=run:running:+1"))
check("on-completion alone → waiting state", has("waitOnly=w:waiting:+0"))
check("a timed job beats an on-completion one", has("timedBeatsWait=t:countdown:+1"))
check("countdown mm:ss", has("c48=00:48") && has("c72=01:12"))
check("seconds round UP (never 00:00 while a fire is still ahead)", has("c59_2=01:00") && has("c0_2=00:01"))
check("due / overdue reads 00:00", has("c0=00:00") && has("cneg=00:00"))
check("mm:ss up to the last second of the hour", has("c3599=59:59"))
check("from an hour up no ticking clock (the short pill writes 1h 5m / 1d 3h)",
      has("c3599_5=nil") && has("c3600=nil") && has("c86400=nil"))
check("ring: half the wait elapsed → 0.5", has("pHalf=0.5"))
check("ring: start 0, past the fire 1, before the window 0", has("pStart=0.0") && has("pPast=1.0") && has("pBefore=0.0"))
check("ring: no next fire → 0; zero-length window → 1", has("pNoNext=0.0") && has("pZero=1.0"))
check("counter: the run counting down, of the total (0 done → 1/30, 1 done → 2/30)",
      has("rFirst=1/30") && has("rNext=2/30"))
check("counter: while a run is in progress it is that run (2 done, running → 2/30)", has("rRunning=2/30"))
check("counter: a skipped run counts (1 fired + 1 skipped → 3/30), never past the total",
      has("rAfterSkip=3/30") && has("rCap=30/30"))
check("counter: unbounded loop / cron → #N; one-shot → none", has("rUnbounded=#7") && has("rOnce=nil"))
check("counter: running before anything was recorded still reads 1", has("rRunningFirst=1/5"))
check("hide: hidden while every live job was hidden", has("dHidden=true") && has("dOneLeft=true"))
check("hide: a job not seen when hiding brings the pill back", has("dNewJob=false"))
check("hide: nothing live → not 'dismissed' (pill gone anyway); nothing hidden → shown",
      has("dNone=false") && has("dNever=false"))
check("skip: a loop re-arms one interval later, the skipped run counted (30 → 29)", has("sLoop=rearm+180:29"))
check("skip: an unbounded loop re-arms without a count", has("sLoopUnbounded=rearm+180:nil"))
check("skip: the last run of a loop ends it; the second-last leaves one", has("sLoopLast=cancel") && has("sLoopTwo=rearm+180:1"))
check("skip: once / on-completion / a cron past its window → the job is cancelled",
      has("sOnce=cancel") && has("sOnCompletion=cancel") && has("sCronEnds=cancel"))
check("skip: a cron re-arms at its next day", has("sCron=rearm+86460:nil"))
check("skip: the pill then counts down to the run after the skipped one", has("sCountdown=03:00"))

// MARK: - [2] data source

print("\n▶️  2. presence is pushed by jobsDidChange, not polled")
check("jobsDidChange publishes the jobs keeping each chat active, only on change",
      registry.contains("let byChat = activeScheduleJobIdsByChat\n        if byChat != activeScheduleJobIdsBySession { activeScheduleJobIdsBySession = byChat }"))
check("ONE rule: the banner's jobs and scheduledSessions both come from sessionKeptActive(by:)",
      registry.contains("if let sid = sessionKeptActive(by: job) { out[sid, default: []].insert(job.id) }")
      && registry.contains("Set(jobs.values.compactMap { sessionKeptActive(by: $0) })")
      && registry.contains("func sessionKeptActive(by job: AgentJob) -> String? {"))
check("…which is follow-up into its own creator only (no new-chat / child / rerun jobs)",
      registry.contains("case .followUp(let sid) = job.target, job.creatorSessionId == sid else { return nil }"))
check("the banner reads that published map", page.contains("registry.activeScheduleJobIdsBySession[sessionId] ?? []")
      && page.contains("(activeScheduleJobIdsBySession[sessionId] ?? []).compactMap"))
check("each tick re-checks a job with the same rule (no second copy of it)",
      page.contains("guard let job = self.job(id: id), sessionKeptActive(by: job) == sessionId")
      && page.contains("registry.scheduledBannerJobs(for: sessionId)")
      && !page.contains("guard let up = registry.job(id: upstreamId)"))
check("running state uses the task page's own rule", page.contains("isFiringNow: ScheduledTaskDetailStore.isProcessingNow(job),")
      && page.contains("static func isProcessingNow(_ job: AgentJob) -> Bool {"))

// MARK: - [3] view

print("\n▶️  3. mounting, ticking, tap, accessibility, style")
let list = messageListV3Source()
check("mounted in a top inset OUTSIDE NavBarStyleModifier (iOS 26 runs content behind the bar), first in topBanners",
      chat.contains(".modifier(NavBarStyleModifier(topSafeAreaInset: $topSafeAreaInset))\n        // [T-scheduled-banner]")
      && chat.contains(".safeAreaInset(edge: .top, spacing: 0) {\n            topBanners")
      && chat.contains("VStack(spacing: 0) {\n            if let sid = vm.sessionId {\n                ScheduledTaskBanner(sessionId: sid)"))
check("the top banners' measured height is passed to the list on iOS 26 only",
      chat.contains("extraTopInset: Self.listTopInset(forTopBanners: topBannersHeight)")
      && chat.contains("if #available(iOS 26, *) { return height }\n        return 0"))
check("the list adds it to its top content inset",
      list.contains("if #available(iOS 26, *) { return extraTopInset } else { return 8 + extraTopInset }")
      && list.contains("coord.extraTopInset = extraTopInset"))
check("ticks with a 1 s TimelineView only while shown", page.contains("TimelineView(.periodic(from: .now, by: 1))")
      && page.contains("if isShown {\n                TimelineView"))
check("Reduce Motion: fade instead of slide, no spring",
      page.contains("reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)")
      && page.contains("reduceMotion ? nil : .spring("))
check("tap opens the card's task page through the card's own route",
      page.contains("NotificationCenter.default.post(name: .openAgentCallback")
      && page.contains("\"callback\": ScheduledJobRunner.detailCallback(for: job)")
      && runner.contains("static func detailCallback(for job: AgentJob) -> AgentCallback {\n        AgentCallback(kind: .scheduled"))
check("VoiceOver: ONE button (label on the Button itself) with title, state and time left, plus a hint",
      page.contains(".contextMenu { menu(jobId: state.job.id, phase: state.phase, run: state.job.runsDone) }\n        // On the Button itself")
      && page.contains(".accessibilityLabel(accessibilityText(state, seconds: seconds))\n        .accessibilityHint(Text(AppLocalized(\"Opens the task details\")))")
      && page.contains("parts.append(AppLocalized(\"Next run in \\(spoken)\"))")
      && !page.contains(".accessibilityElement(children: .ignore)\n        .accessibilityLabel(accessibilityText"))
let pill: String = {
    guard let a = page.range(of: "    private func card(_ state: ScheduledBannerModel.State, now: Date) -> some View {"),
          let b = page.range(of: "    private func spokenSubtitle(", range: a.upperBound..<page.endIndex) else { return "" }
    return String(page[a.upperBound..<b.lowerBound])
}()
let face: String = {
    guard let a = page.range(of: "// [T-sched-pill-align] BEGIN scheduled-pill-face\n"),
          let b = page.range(of: "// [T-sched-pill-align] END scheduled-pill-face", range: a.upperBound..<page.endIndex) else { return "" }
    return String(page[a.upperBound..<b.lowerBound])
}()
check("the pill's look is ScheduledPillFace (plain values), the banner only feeds it",
      !face.isEmpty && pill.contains("ScheduledPillFace(ringFraction: ringFraction(state, now: now),")
      && pill.contains("glyph: state.phase == .waiting ? \"hourglass\" : ScheduledAccent.icon,"))
check("pill styling: capsule, material + amber wash, hairline, soft shadow",
      face.contains("Capsule().fill(.regularMaterial)")
      && face.contains("Capsule().fill(ScheduledAccent.color.opacity(0.06))")
      && face.contains(".overlay(Capsule().strokeBorder(ScheduledAccent.color.opacity(0.28), lineWidth: 0.75))")
      && face.contains(".shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)"))
check("compact: centered, hugging its content (no full-width card)",
      pill.contains(".padding(.bottom, 4)\n        .frame(maxWidth: .infinity)\n")
      && !pill.contains("Spacer(") && !pill.contains("chevron.right"))
// [T-sched-pill-adaptive] User feedback on device: a fixed 80 pt glyph
// segment left a wide gap between the ring and the clock. The pill hugs its
// content: [ring][+N][clock] with fixed gaps, no segments.
check("hugs its content: no fixed segment width, no segment tint",
      !face.contains("glyphSegmentWidth") && !face.contains(".frame(width: Self.") && !face.contains("maxHeight: .infinity")
      && !face.contains(".background(ScheduledAccent.color.opacity(0.12))"))
check("ring leading, inset like above and below (concentric in the capsule end); +N and clock follow at fixed gaps",
      face.contains("static let glyphInset: CGFloat = 4")
      && face.contains("ring\n                .padding(.leading, Self.glyphInset)\n                .padding(.vertical, Self.glyphInset)")
      && face.contains(".padding(.leading, Self.plusGap)")
      && face.contains("            .padding(.leading, Self.clockGap)\n            .padding(.vertical, 7)")
      && face.contains("        }\n        .padding(.trailing, Self.clockTrailing)"))
// [T-sched-pill-clock-big] Clock one size up; clock and counter on one text
// baseline; the counter trailing-aligned in its floor so it ends at the
// capsule's trailing inset (the floor's slack sits between the two).
check("clock keeps its format's widest width (no twitch while counting), one size up (headline)",
      face.contains("} else {\n                        Text(verbatim: Self.clockWidthTemplate(clock)).hidden()\n                        Text(clock)")
      && face.contains(".font(.system(.headline, design: .rounded).weight(.semibold).monospacedDigit())")
      && !face.contains(".subheadline"))
// [T-sched-pill-vcenter] Everything centred on the pill's middle line (a
// shared baseline put the smaller counter low); a status word is smaller
// than the clock but keeps its height.
check("clock, counter, +N and ring are centred on one middle line (no text-baseline alignment)",
      face.contains("HStack(alignment: .center, spacing: 0) {") && !face.contains(".firstTextBaseline")
      && face.contains("// Content-hugging: [ring][+N][clock], fixed gaps, no segments.\n        HStack(spacing: 0) {"))
check("a status word (Running / Waiting) is footnote, below the 17 pt clock, in the clock's height",
      face.contains("static let statusFont: Font = .system(.footnote, design: .rounded).weight(.semibold)")
      && face.contains("if clockIsStatus {\n                        // [T-sched-pill-vcenter]")
      && face.contains("Text(verbatim: \"0\").hidden()\n                        Text(clock).font(Self.statusFont)")
      && pill.contains("clockIsStatus: state.phase != .countdown,"))
check("run counter after the clock: smaller, lighter amber, monospaced, own width floor, right-aligned in it",
      face.contains("if let counter {\n                    ZStack(alignment: .trailing) {\n                        Text(verbatim: Self.clockWidthTemplate(counter)).hidden()")
      && face.contains(".font(.system(.caption, design: .rounded).weight(.medium).monospacedDigit())")
      && face.contains(".foregroundStyle(ScheduledAccent.color.opacity(0.7))")
      && pill.contains("counter: ScheduledBannerModel.runCounter(state.job, running: state.phase == .running),"))
check("counter data: fired + skipped runs, loop count as total, loop / cron repeat",
      page.contains("runsDone: job.firedCount + job.skippedCount,")
      && page.contains("case .loop(_, let count): (count, true)")
      && page.contains("case .cron: (nil, true)")
      && runner.contains("job.remaining = remaining\n            job.skippedCount += 1")
      && registry.contains("var skippedCount = 0"))
check("VoiceOver reads the counter as a sentence",
      page.contains("parts.append(state.job.runTotal.map { AppLocalized(\"Run \\(n) of \\($0)\") } ?? AppLocalized(\"Run \\(n)\"))"))
check("width changes (+N, clock format) are eased, not under Reduce Motion",
      face.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: others)")
      && face.contains(".animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: Self.clockWidthTemplate(clock))"))
// clockWidthTemplate is pure: compile the face block (SwiftUI on macOS) and run it.
let faceHarness = "import SwiftUI\nenum ScheduledAccent { static let color = Color.orange; static let icon = \"x\" }\n" + face + #"""
for c in ["00:48", "59:59", "1h 5m", "12h 30m", "1d 3h", "Running", "1 h 5 min", "1小时5分钟"] {
    print("T[\(c)]=\(ScheduledPillFace.clockWidthTemplate(c))")
}
"""#
let ftmp = FileManager.default.temporaryDirectory.appendingPathComponent("pill-face-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: ftmp, withIntermediateDirectories: true)
try? faceHarness.write(to: ftmp.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
let fp = Process()
fp.executableURL = URL(fileURLWithPath: "/usr/bin/env")
fp.arguments = ["swift", ftmp.appendingPathComponent("main.swift").path]
let fpipe = Pipe(); fp.standardOutput = fpipe; fp.standardError = fpipe
try? fp.run(); fp.waitUntilExit()
let fout = Set((String(data: fpipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n").map(String.init))
try? FileManager.default.removeItem(at: ftmp)
check("width template: mm:ss → 00:00 (the clock never twitches while counting)",
      fout.contains("T[00:48]=00:00") && fout.contains("T[59:59]=00:00"))
check("width template: every digit run at least 00, other characters kept",
      fout.contains("T[1h 5m]=00h 00m") && fout.contains("T[12h 30m]=00h 00m") && fout.contains("T[1d 3h]=00d 00h")
      && fout.contains("T[1 h 5 min]=00 h 00 min") && fout.contains("T[1小时5分钟]=00小时00分钟"))
check("width template: words are their own floor", fout.contains("T[Running]=Running"))
check("no visible title, \"N left\" or chevron — VoiceOver keeps the full sentence",
      !pill.contains("Text(state.job.title)") && !pill.contains("AppLocalized(\"Up next\")")
      && !pill.contains("left\") }")
      && page.contains("var parts = [AppLocalized(\"Upcoming scheduled task\"), state.job.title, spokenSubtitle(state)]"))
check("one line: the clock, or one word when running / waiting",
      pill.contains("case .running: return AppLocalized(\"Running\")")
      && pill.contains("case .waiting: return AppLocalized(\"Waiting\")")
      && pill.contains("case .countdown: return seconds.map(Self.visibleCountdown) ?? \"\""))
check("from an hour up the clock is a coarse, system-localized 1h 5m",
      page.contains("f.allowedUnits = [.hour, .minute]\n            return f.string(from: (s / 60).rounded(.up) * 60)"))
check("countdown in monospaced digits", face.contains(".monospacedDigit())"))
check("tap target reaches 44 pt around the ~34 pt pill", face.contains(".contentShape(Capsule().inset(by: -5))"))
check("Dynamic Type honoured, capped; the ring scales and stays leading",
      pill.contains(".dynamicTypeSize(...DynamicTypeSize.xxxLarge)")
      && page.contains("@ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 26")
      && pill.contains("ringSize: min(ringSize, ScheduledPillFace.maxRingSize))")
      && face.contains("static let maxRingSize: CGFloat = 36"))

// MARK: - [3b] long-press menu

print("\n▶️  3b. long-press menu [T-sched-pill-menu]")
let runnerSkip: String = {
    guard let a = runner.range(of: "    static func skipNext(_ job: AgentJob) {"),
          let b = runner.range(of: "\n    }\n", range: a.upperBound..<runner.endIndex) else { return "" }
    return String(runner[a.upperBound..<b.lowerBound])
}()
check("three items, SF Symbols, the third destructive",
      page.contains("Label(AppLocalized(\"Hide This Countdown\"), systemImage: \"eye.slash\")")
      && page.contains("Label(AppLocalized(\"Skip Next Run\"), systemImage: \"forward.end\")")
      && page.contains("Button(role: .destructive) { confirmCancelAll = true } label: {\n            Label(AppLocalized(\"Cancel All Scheduled Tasks\"), systemImage: \"xmark.circle\")"))
check("menu on the pill's Button; tap still opens the task page",
      pill.contains(".buttonStyle(.plain)\n        .contextMenu { menu(jobId: state.job.id, phase: state.phase, run: state.job.runsDone) }")
      && pill.contains("return Button { open(state.job.id) } label: {"))
check("haptic: one medium impact when the menu opens (project idiom: inline UIImpactFeedbackGenerator)",
      page.contains(".onAppear { menuDidOpen() }")
      && page.contains("UIImpactFeedbackGenerator(style: .medium).impactOccurred()"))
check("VoiceOver reaches all three as actions",
      pill.contains(".accessibilityAction(named: Text(AppLocalized(\"Hide This Countdown\"))) { hide() }")
      && pill.contains(".accessibilityAction(named: Text(AppLocalized(\"Skip Next Run\"))) { skipNext(state.job.id) }")
      && pill.contains(".accessibilityAction(named: Text(AppLocalized(\"Cancel All Scheduled Tasks\"))) { confirmCancelAll = true }"))
check("hide only hides the pill (in-memory per chat; jobs and keep-alive untouched)",
      page.contains("final class ScheduledBannerDismissals: ObservableObject {")
      && page.contains("!jobIds.isEmpty && !dismissals.isDismissed(jobIds, in: sessionId)")
      && page.contains("dismissals.hide(jobIds, in: sessionId)")
      && !page.contains("UserDefaults.standard.set(") )
check("hide prunes finished jobs so the next batch shows again",
      page.contains(".onChange(of: jobIds) { ids in dismissals.prune(live: ids, in: sessionId) }")
      && page.contains("let kept = h.intersection(live)"))
check("hidden pill leaves the stack, so the list's top inset shrinks with it",
      page.contains("if isShown {\n                TimelineView"))
check("cancel all: confirmed, then the Stop button's own call and scope",
      page.contains(".alert(AppLocalized(\"Cancel all scheduled tasks?\"), isPresented: $confirmCancelAll) {")
      && page.contains("Button(AppLocalized(\"Cancel All\"), role: .destructive) { cancelAll() }")
      && page.contains("registry.cancelScheduled(createdBy: sessionId, reason: \"user cancelled all from the timer pill\")"))
check("skip next: the job the pill shows, through ScheduledJobRunner.skipNext",
      page.contains("ScheduledJobRunner.skipNext(job)"))
check("runner: skip re-arms past the skipped run or cancels like Stop",
      runnerSkip.contains("switch ScheduledBannerModel.skipPlan(next: job.nextFireAt, remaining: job.remaining, following: following) {")
      && runnerSkip.contains("AgentJobRegistry.shared.cancel(jobId: job.id, reason: \"user skipped its last run\")")
      && runnerSkip.contains("job.remaining = remaining\n            job.skippedCount += 1\n            arm(job, firstFireAt: at)")
      && runnerSkip.contains("guard job.isEnabled, job.state == .pending else { return }"))
check("runner: arm takes the first fire for loop and cron",
      runner.contains("static func arm(_ job: AgentJob, firstFireAt: Date? = nil, runNowSlot: Date? = nil) {")
      && runner.contains("let first = preclaimed ? Date() : (firstFireAt ?? Date().addingTimeInterval(interval))")
      && runner.contains("guard let first = preclaimed ? Date() : (firstFireAt\n                    ?? nextCronDate("))
check("runner: a timer task re-armed while it was firing stops instead of overwriting the new schedule",
      runner.components(separatedBy: "await fire(job, claimed: claimed)\n                    claimed = false\n                    // Re-armed while firing (skipNext): the new task owns the schedule.\n                    if Task.isCancelled { return }").count == 2
      && runner.contains("await fire(job, claimed: claimed)\n                    claimed = false\n                    if Task.isCancelled { return }\n                    guard let n = nextCronDate("))

// MARK: - [4] localization

print("\n▶️  4. strings in all 18 locales")
let locales = ["de", "es", "fil", "fr", "hr", "id", "ja", "ko", "ms", "pl", "pt-BR", "ro", "ru", "th", "tr", "zh-Hans", "zh-Hant"]
for key in ["Upcoming run", "Upcoming run · %lld left", "Run in progress", "Waiting for another task to finish",
            "+%lld more", "Upcoming scheduled task", "Next run in %@", "Opens the task details",
            "Running", "Waiting",
            "Hide This Countdown", "Skip Next Run", "Cancel All Scheduled Tasks", "Cancel all scheduled tasks?",
            "Cancel All", "Every task still planned in this conversation will be cancelled.", "Not Now",
            "Run %lld of %lld", "Run %lld"] {
    guard let r = catalog.range(of: "\n    \"\(key)\" : {") else { check("\"\(key)\" in the catalog", false); continue }
    let next = catalog.range(of: "\n    \"", range: r.upperBound..<catalog.endIndex)?.lowerBound ?? catalog.endIndex
    let entry = catalog[r.upperBound..<next]
    let missing = locales.filter { !entry.contains("\"\($0)\" : {") }
    check("\"\(key)\"\(missing.isEmpty ? "" : " — missing \(missing)")", missing.isEmpty)
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
