//
//  ScheduledTaskDetailView.swift
//  MinisApp
//
//  [T-scheduled-task-detail] The page a scheduled-task card opens.
//
//  A scheduled fire lands in a chat as an orange card ("Scheduled task ·
//  <name> / Run 2 · 28 left · Next in 30 s · loop(60s×30)"). Tapping it used
//  to open the generic agent sheet: purple "Minis Computer" frame, the status
//  "Interrupted" (the envelope's `status="running"` read as a lost agent run),
//  and the raw envelope text as the "result". Nothing showed what the task
//  actually is or what it has done.
//
//  This page shows the task as structured information, in the card's amber:
//  what it is (name, trigger, delivery, preset command, id), where it stands
//  (a status derived from the task — never "Interrupted" — the run count, the
//  next run with a live countdown), its prompt without the machine prefixes,
//  and every run so far.
//
//  Run history has two sources, merged by run index:
//  - persisted: every envelope message of this job in any session
//    (`ChatStore.scheduledFireMessages`) — follow-up and new-session runs;
//  - in memory: the job's `fireLog` — rerun runs (no envelope) and failed
//    deliveries. Lost with the app process, like the job itself.
//
//  The design is shared by iOS and Android.
//

import SwiftUI
import UIKit

private let logger = AppLogger(category: "ScheduledBanner")

// [T-scheduled-task-detail] BEGIN scheduled-task-detail-model
// Foundation-only, so the standalone test can compile this section as is.

/// Where a scheduled task stands. Deliberately has no "interrupted": that
/// word belongs to agent runs, and a scheduled fire is not one.
enum ScheduledTaskStatus: Equatable {
    case waiting, running, disabled, cancelled, failed, timedOut, completed, stopped
}

/// The trigger, recovered from `AgentJobTrigger.logLabel` (the envelope's
/// `trigger` attribute) when the live job is gone.
enum ScheduledTriggerSpec: Equatable {
    case loop(interval: TimeInterval, count: Int?)
    case once(after: TimeInterval)
    case cron(hour: Int, minute: Int, days: [Int])
    case immediate
    case onCompletion(jobPrefix: String)
    case raw(String)

    /// Parses `loop(60s×30)`, `loop(60s×∞)`, `once(+300s)`,
    /// `cron(9:05 days=[2, 4])`, `immediate`, `onCompletion(ab12cd34)`.
    static func parse(label: String) -> ScheduledTriggerSpec {
        let s = label.trimmingCharacters(in: .whitespaces)
        func inner(_ prefix: String) -> String? {
            guard s.hasPrefix(prefix + "("), s.hasSuffix(")") else { return nil }
            return String(s.dropFirst(prefix.count + 1).dropLast())
        }
        if s == "immediate" { return .immediate }
        if let body = inner("loop") {
            let parts = body.components(separatedBy: "×")
            guard parts.count == 2, parts[0].hasSuffix("s"),
                  let interval = TimeInterval(parts[0].dropLast()) else { return .raw(s) }
            return .loop(interval: interval, count: Int(parts[1]))
        }
        if let body = inner("once") {
            guard body.hasPrefix("+"), body.hasSuffix("s"),
                  let after = TimeInterval(body.dropFirst().dropLast()) else { return .raw(s) }
            return .once(after: after)
        }
        if let body = inner("cron") {
            let halves = body.components(separatedBy: " days=")
            let hm = halves[0].components(separatedBy: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return .raw(s) }
            var days: [Int] = []
            if halves.count == 2 {
                days = halves[1].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            return .cron(hour: h, minute: m, days: days.sorted())
        }
        if let body = inner("onCompletion") { return .onCompletion(jobPrefix: body) }
        return .raw(s)
    }

    /// Fires more than once (loop / cron).
    var isRepeating: Bool {
        switch self {
        case .loop, .cron: return true
        case .raw(let s): return s.hasPrefix("loop") || s.hasPrefix("cron")
        default: return false
        }
    }

    /// Total planned runs, when bounded.
    var totalCount: Int? {
        if case .loop(_, let count) = self { return count }
        return nil
    }
}

/// One row of the run history.
struct ScheduledFireRow: Equatable {
    var index: Int?
    var at: Date
    var sessionId: String?
    /// true delivered, false delivery failed, nil unknown.
    var ok: Bool?
    /// Runs coalesced into this one while the chat was busy.
    var coalesced: Int
    /// The run whose card was tapped.
    var isCurrent: Bool
    /// Landed in another session than the one the page was opened from.
    var isOtherSession: Bool
    /// Being processed right now.
    var isRunning: Bool
}

enum ScheduledTaskDetailModel {
    /// The live job, reduced to what the status needs. nil when the job is no
    /// longer in memory (app relaunched).
    struct LiveJob: Equatable {
        /// `AgentJobState.rawValue`.
        var state: String
        var isEnabled: Bool
        /// A run of this job is being processed right now.
        var isProcessingNow: Bool
    }

    /// See the status table in the design (§4). Never produces "interrupted".
    static func status(live: LiveJob?, envelopeRemaining: Int?, trigger: ScheduledTriggerSpec) -> ScheduledTaskStatus {
        if let live {
            switch live.state {
            case "cancelled": return .cancelled
            case "failed": return .failed
            case "timeout": return .timedOut
            case "done": return .completed
            default: break
            }
            if !live.isEnabled { return .disabled }
            if live.isProcessingNow || live.state == "running" { return .running }
            return .waiting
        }
        if !trigger.isRepeating || envelopeRemaining == 0 { return .completed }
        return .stopped
    }

    /// The prompt as written, without the machine prefixes the runner adds to
    /// every run: `[Scheduled task "…" · fire …]` and the preset-tool note
    /// `[This task's first step already ran for you: …]`.
    static func cleanPrompt(_ body: String) -> String {
        var s = body
        for prefix in ["[Scheduled task \"", "[This task's first step already ran for you:"] {
            let trimmed = s.drop(while: { $0 == "\n" || $0 == " " })
            guard trimmed.hasPrefix(prefix), let end = trimmed.firstIndex(of: "]") else { continue }
            s = String(trimmed[trimmed.index(after: end)...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "also fired 3 more times" → 3.
    static func coalescedCount(in text: String) -> Int {
        guard let r = text.range(of: #"also fired (\d+) more time"#, options: .regularExpression) else { return 0 }
        let digits = text[r].filter(\.isNumber)
        return Int(digits) ?? 0
    }

    struct PersistedFire: Equatable {
        var index: Int?
        var at: Date
        var sessionId: String
        var coalesced: Int
    }

    struct MemoryFire: Equatable {
        var index: Int
        var at: Date
        var sessionId: String?
        var ok: Bool?
    }

    /// Merge both sources into one row per run, newest first. Indexed runs are
    /// unique by index (persisted session/time win, memory supplies `ok`);
    /// un-indexed persisted runs (once / on-completion) are kept as they are.
    static func mergeHistory(persisted: [PersistedFire], memory: [MemoryFire],
                             currentIndex: Int?, hostSessionId: String?,
                             runningIndex: Int?) -> [ScheduledFireRow] {
        var byIndex: [Int: ScheduledFireRow] = [:]
        var unindexed: [ScheduledFireRow] = []
        func other(_ sid: String?) -> Bool {
            guard let sid, let host = hostSessionId else { return false }
            return sid != host
        }
        for p in persisted {
            let row = ScheduledFireRow(index: p.index, at: p.at, sessionId: p.sessionId, ok: nil,
                                       coalesced: p.coalesced, isCurrent: false,
                                       isOtherSession: other(p.sessionId), isRunning: false)
            if let i = p.index {
                if let existing = byIndex[i], existing.at >= p.at { continue }
                byIndex[i] = row
            } else {
                unindexed.append(row)
            }
        }
        for m in memory {
            if var row = byIndex[m.index] {
                row.ok = m.ok
                if row.sessionId == nil { row.sessionId = m.sessionId; row.isOtherSession = other(m.sessionId) }
                byIndex[m.index] = row
            } else {
                byIndex[m.index] = ScheduledFireRow(index: m.index, at: m.at, sessionId: m.sessionId, ok: m.ok,
                                                    coalesced: 0, isCurrent: false,
                                                    isOtherSession: other(m.sessionId), isRunning: false)
            }
        }
        var rows = Array(byIndex.values) + unindexed
        for i in rows.indices {
            if let idx = rows[i].index {
                rows[i].isCurrent = idx == currentIndex
                rows[i].isRunning = idx == runningIndex
            }
        }
        rows.sort { a, b in
            switch (a.index, b.index) {
            case let (x?, y?) where x != y: return x > y
            default: return a.at > b.at
            }
        }
        return rows
    }
}
// [T-scheduled-task-detail] END scheduled-task-detail-model

// MARK: - Presentation

/// Amber accent shared with the chat card (`AgentCallbackCellView` uses
/// `.orange` for `kind == .scheduled`).
enum ScheduledAccent {
    static let color = Color.orange
    static let icon = "calendar.badge.clock"
}

// [T-scheduled-banner] BEGIN scheduled-banner-model
/// One live scheduled job, as the chat's top banner sees it. Foundation-only:
/// MinisTests/Standalone/ScheduledBannerTests.swift compiles this block.
struct ScheduledBannerJob: Equatable {
    let id: String
    let title: String
    /// Next planned fire; nil for an on-completion job (it waits on another).
    let nextFireAt: Date?
    /// Where the wait the progress ring measures began: one interval before
    /// the next fire for a loop, else the last fire, else the job's creation.
    let windowStart: Date
    /// Fires left including the next one; nil when unbounded / not counted.
    let remaining: Int?
    /// A run of this job is being processed right now.
    let isFiringNow: Bool
    /// [T-sched-pill-count] Runs already fired or skipped.
    var runsDone: Int = 0
    /// Planned runs in all (a counted loop); nil when unbounded / unknown.
    var runTotal: Int? = nil
    /// Runs more than once (loop / cron): only those show a run counter.
    var repeats: Bool = false
}

enum ScheduledBannerModel {
    enum Phase: Equatable {
        /// Waiting for the next fire: countdown.
        case countdown
        /// A fire of this job is running in the chat right now.
        case running
        /// An on-completion job: no time to count down to.
        case waiting
    }

    struct State: Equatable {
        let job: ScheduledBannerJob
        let phase: Phase
        /// The conversation's other live scheduled jobs ("+N more").
        let others: Int
    }

    /// Which job the banner shows. A job running right now wins (the chat is
    /// visibly busy with it); otherwise the soonest next fire; an on-completion
    /// job only when nothing has a time. nil hides the banner.
    static func state(_ jobs: [ScheduledBannerJob]) -> State? {
        guard !jobs.isEmpty else { return nil }
        let others = jobs.count - 1
        if let firing = jobs.filter(\.isFiringNow).sorted(by: soonestFirst).first {
            return State(job: firing, phase: .running, others: others)
        }
        if let next = jobs.filter({ $0.nextFireAt != nil }).sorted(by: soonestFirst).first {
            return State(job: next, phase: .countdown, others: others)
        }
        let waiting = jobs.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        return State(job: waiting[0], phase: .waiting, others: others)
    }

    private static func soonestFirst(_ a: ScheduledBannerJob, _ b: ScheduledBannerJob) -> Bool {
        let ta = a.nextFireAt ?? .distantFuture, tb = b.nextFireAt ?? .distantFuture
        return ta != tb ? ta < tb : a.id < b.id
    }

    /// "00:48" / "12:05" / "59:59", seconds rounded up so it never shows
    /// 00:00 while a fire is still a moment away. nil from an hour up: the
    /// pill is a short clock, so the caller writes a coarse "1h 5m" / "1d 3h"
    /// instead of a wider h:mm:ss.
    static func countdown(_ seconds: TimeInterval) -> String? {
        let s = max(0, Int(seconds.rounded(.up)))
        guard s < 3600 else { return nil }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Share of the wait already elapsed, 0...1: the ring fills up toward the
    /// fire. 0 without a next fire.
    static func progress(_ job: ScheduledBannerJob, now: Date) -> Double {
        guard let end = job.nextFireAt else { return 0 }
        let total = end.timeIntervalSince(job.windowStart)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(job.windowStart) / total))
    }

    /// [T-sched-pill-count] The pill's run counter: "2/30" (this run of a
    /// counted loop), "#7" (unbounded loop / cron), nil for a one-shot.
    /// "This run" is the one counting down, or the one in progress.
    static func runNumber(_ job: ScheduledBannerJob, running: Bool) -> Int? {
        guard job.repeats else { return nil }
        let n = running ? max(1, job.runsDone) : job.runsDone + 1
        return job.runTotal.map { min(n, $0) } ?? n
    }

    static func runCounter(_ job: ScheduledBannerJob, running: Bool) -> String? {
        guard let n = runNumber(job, running: running) else { return nil }
        if let total = job.runTotal { return "\(n)/\(total)" }
        return "#\(n)"
    }

    // [T-sched-pill-menu] The pill's long-press menu.

    /// "Hide this countdown" covers the jobs live when it was chosen: the pill
    /// stays hidden while every live job is one of them, and comes back as
    /// soon as a job it has not seen appears.
    static func isDismissed(live: Set<String>, hidden: Set<String>) -> Bool {
        !live.isEmpty && live.isSubset(of: hidden)
    }

    enum SkipPlan: Equatable {
        /// Re-arm at `at`, with the loop's runs left after the skipped one.
        case rearm(at: Date, remaining: Int?)
        /// Nothing follows the skipped run: the job ends.
        case cancel
    }

    /// "Skip next run". `following` gives the run after a given one (a loop
    /// adds its interval, a cron finds its next day; nil for a one-shot).
    /// The skipped run counts against a loop's `remaining`.
    static func skipPlan(next: Date?, remaining: Int?, following: (Date) -> Date?) -> SkipPlan {
        guard let next else { return .cancel }
        if let remaining, remaining <= 1 { return .cancel }
        guard let after = following(next) else { return .cancel }
        return .rearm(at: after, remaining: remaining.map { $0 - 1 })
    }
}
// [T-scheduled-banner] END scheduled-banner-model

/// Everything the page shows, gathered once on appear and refreshed each
/// second for the countdown / status.
@MainActor
final class ScheduledTaskDetailStore: ObservableObject {
    let callback: AgentCallback
    let hostSessionId: String?

    @Published private(set) var history: [ScheduledFireRow] = []
    @Published private(set) var otherSessionTitles: [String: String] = [:]
    @Published private(set) var historyLoaded = false
    private var persisted: [ScheduledTaskDetailModel.PersistedFire] = []

    init(callback: AgentCallback, hostSessionId: String?) {
        self.callback = callback
        self.hostSessionId = hostSessionId
    }

    var job: AgentJob? { AgentJobRegistry.shared.job(id: callback.jobId) }

    var trigger: ScheduledTriggerSpec {
        if let job {
            switch job.trigger {
            case .loop(let i, let c): return .loop(interval: i, count: c)
            case .once(let a): return .once(after: a)
            case .cron(let h, let m, let d, _, _): return .cron(hour: h, minute: m, days: d.sorted())
            case .immediate: return .immediate
            case .onCompletion(let id): return .onCompletion(jobPrefix: String(id.prefix(8)))
            }
        }
        return .parse(label: callback.triggerLabel ?? "")
    }

    /// A run of this job is being processed now: a child run is running, or
    /// the session of the latest run is busy AND its last user turn is this
    /// job's envelope (so an unrelated reply in the same chat does not count).
    var isProcessingNow: Bool {
        guard let job else { return false }
        return Self.isProcessingNow(job)
    }

    /// `isProcessingNow` for any job — shared with the chat banner
    /// ([T-scheduled-banner]), which must agree with this page on it.
    static func isProcessingNow(_ job: AgentJob) -> Bool {
        if job.state == .running { return true }
        guard let sid = job.runSessionId,
              let vm = ViewModelCache.shared.get(for: sid), vm.isProcessing,
              let lastUser = vm.messages.last(where: { $0.role == .user }),
              let cb = lastUser.agentCallback else { return false }
        return cb.kind == .scheduled && cb.jobId == job.id
    }

    var status: ScheduledTaskStatus {
        let live = job.map {
            ScheduledTaskDetailModel.LiveJob(state: $0.state.rawValue, isEnabled: $0.isEnabled,
                                             isProcessingNow: isProcessingNow)
        }
        return ScheduledTaskDetailModel.status(live: live, envelopeRemaining: callback.remaining, trigger: trigger)
    }

    var name: String { job.map { $0.label ?? $0.title } ?? callback.title }

    var firedCount: Int? {
        if let job { return job.firedCount }
        return callback.fireIndex
    }

    var remaining: Int? { job?.remaining ?? callback.remaining }

    var nextFireAt: Date? {
        if let job {
            guard job.isEnabled, job.state == .pending || job.state == .running else { return nil }
            return job.nextFireAt.flatMap { $0 > Date() ? $0 : nil }
        }
        return nil
    }

    var prompt: String {
        if let p = job?.prompt, !p.isEmpty { return p }
        return ScheduledTaskDetailModel.cleanPrompt(callback.body)
    }

    func load() async {
        let rows = await ChatStore.shared.scheduledFireMessages(jobId: callback.jobId)
        persisted = rows.map { r in
            let cb = AgentCallback.parse(r.text)
            return .init(index: cb?.fireIndex, at: r.createdAt, sessionId: r.sessionId,
                         coalesced: ScheduledTaskDetailModel.coalescedCount(in: r.text))
        }
        rebuildHistory()
        historyLoaded = true
        var titles: [String: String] = [:]
        for sid in Set(history.compactMap { $0.isOtherSession ? $0.sessionId : nil }) {
            if let s = await ChatStore.shared.getSession(sid) {
                titles[sid] = s.title ?? ""
            }
        }
        otherSessionTitles = titles
    }

    /// Re-merge with the live fire log (called on appear and on each tick, so
    /// a run that lands while the page is open shows up).
    func rebuildHistory() {
        let memory = (job?.fireLog ?? []).map {
            ScheduledTaskDetailModel.MemoryFire(index: $0.index, at: $0.at, sessionId: $0.sessionId, ok: $0.ok)
        }
        let running = isProcessingNow ? job?.firedCount : nil
        let rows = ScheduledTaskDetailModel.mergeHistory(persisted: persisted, memory: memory,
                                                         currentIndex: callback.fireIndex,
                                                         hostSessionId: hostSessionId,
                                                         runningIndex: running)
        if rows != history { history = rows }
    }
}

struct ScheduledTaskDetailView: View {
    @StateObject private var store: ScheduledTaskDetailStore
    @Environment(\.dismiss) private var dismiss
    @State private var promptExpanded = false
    @State private var confirmCancel = false
    @State private var copiedToast: String?
    @State private var now = Date()

    init(callback: AgentCallback, hostSessionId: String?) {
        _store = StateObject(wrappedValue: ScheduledTaskDetailStore(callback: callback, hostSessionId: hostSessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            ScrollView {
                VStack(spacing: 14) {
                    headerCard
                    progressCard
                    parametersCard
                    promptCard
                    historyCard
                    actions
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let copiedToast {
                Text(copiedToast)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .task { await store.load() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { t in
            now = t
            store.rebuildHistory()
        }
        .alert(AppLocalized("Cancel this scheduled task?"), isPresented: $confirmCancel) {
            Button(AppLocalized("Cancel scheduled task"), role: .destructive) {
                AgentJobRegistry.shared.cancel(jobId: store.callback.jobId,
                                               reason: "user cancelled via detail page", silent: false)
            }
            Button(AppLocalized("Keep"), role: .cancel) {}
        } message: {
            Text("It won't run again.", comment: "Scheduled task detail: cancel confirmation message")
        }
    }

    // MARK: Sections

    private var navBar: some View {
        ZStack {
            Text("Scheduled task", comment: "Scheduled task detail page title")
                .font(.headline)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .accessibilityLabel(Text("Close", comment: "Close button"))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ScheduledAccent.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ScheduledAccent.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(ScheduledAccent.color.opacity(0.15)))
                .overlay(Circle().strokeBorder(ScheduledAccent.color.opacity(0.25), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(Self.triggerText(store.trigger))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            statusPill(store.status)
        }
        .padding(14)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ScheduledAccent.color.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var progressCard: some View {
        let fired = store.firedCount ?? 0
        let total: Int? = store.remaining.map { fired + $0 } ?? store.trigger.totalCount
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: AppLocalized("Run %d"), max(fired, store.callback.fireIndex ?? 0)))
                    .font(.title3.weight(.semibold))
                if let total {
                    Text(String(format: AppLocalized("of %d"), total))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let total, total > 0 {
                ProgressView(value: Double(min(fired, total)), total: Double(total))
                    .tint(ScheduledAccent.color)
            }
            Divider()
            row(AppLocalized("Next run"), value: nextRunText)
            row(AppLocalized("Remaining"), value: remainingText)
            if store.status == .stopped {
                Text("Scheduled tasks only run while the app is running and don't resume after a relaunch.",
                     comment: "Scheduled task detail: why a task shows as stopped")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var parametersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(AppLocalized("Parameters"), systemImage: "slider.horizontal.3")
            row(AppLocalized("Name"), value: store.name)
            row(AppLocalized("Trigger"), value: Self.triggerText(store.trigger))
            if let delivery = deliveryText { row(AppLocalized("Delivery"), value: delivery) }
            if case .shell(let command, _) = store.job?.presetToolCall?.kind {
                row(AppLocalized("Preset command"), value: command, monospaced: true, lineLimit: 3)
            }
            if let created = store.job?.createdAt {
                row(AppLocalized("Created"), value: Self.absoluteTime(created))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalized("Task ID"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Button {
                    UIPasteboard.general.string = store.callback.jobId
                    flash(AppLocalized("Copied"))
                } label: {
                    HStack(spacing: 4) {
                        Text(String(store.callback.jobId.prefix(8)))
                            .font(.subheadline.monospaced())
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(AppLocalized("Prompt"), systemImage: "text.alignleft")
                Spacer()
                Button {
                    UIPasteboard.general.string = store.prompt
                    flash(AppLocalized("Copied"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text(AppLocalized("Copy prompt")))
            }
            Text(store.prompt)
                .font(.subheadline)
                .lineLimit(promptExpanded ? nil : 6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if store.prompt.count > 220 || store.prompt.filter(\.isNewline).count >= 6 {
                Button(promptExpanded ? AppLocalized("Show less") : AppLocalized("Show more")) {
                    withAnimation(.easeInOut(duration: 0.2)) { promptExpanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ScheduledAccent.color)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(AppLocalized("Run history"), systemImage: "clock.arrow.circlepath")
                if !store.history.isEmpty {
                    Text("\(store.history.count)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(ScheduledAccent.color.opacity(0.15)))
                        .foregroundStyle(ScheduledAccent.color)
                }
                Spacer()
            }
            if !store.historyLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
            } else if store.history.isEmpty {
                Text("No runs yet", comment: "Scheduled task detail: empty run history")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.history.enumerated()), id: \.offset) { i, r in
                        historyRow(r)
                        if i < store.history.count - 1 { Divider().padding(.leading, 28) }
                    }
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func historyRow(_ r: ScheduledFireRow) -> some View {
        let content = HStack(spacing: 10) {
            statusGlyph(r)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.index.map { String(format: AppLocalized("Run %d"), $0) } ?? AppLocalized("Run"))
                        .font(.subheadline.weight(.medium))
                    if r.isCurrent {
                        tag(AppLocalized("Current"))
                    }
                    if r.coalesced > 0 {
                        tag(String(format: AppLocalized("+%d merged"), r.coalesced))
                    }
                }
                Text(historySubtitle(r))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if r.isOtherSession, r.sessionId != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        return Group {
            if r.isOtherSession, let sid = r.sessionId {
                Button { openSession(sid) } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if AgentJobRegistry.shared.isLiveScheduled(jobId: store.callback.jobId) {
                Button(role: .destructive) { confirmCancel = true } label: {
                    Label(AppLocalized("Cancel scheduled task"), systemImage: "calendar.badge.minus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(cardBackground)
                }
            }
            Button {
                UIPasteboard.general.string = store.prompt
                flash(AppLocalized("Copied"))
            } label: {
                Label(AppLocalized("Copy prompt"), systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(cardBackground)
            }
            .foregroundStyle(.primary)
        }
    }

    // MARK: Pieces

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
    }

    private func row(_ label: String, value: String, monospaced: Bool = false, lineLimit: Int = 2) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(ScheduledAccent.color.opacity(0.15)))
            .foregroundStyle(ScheduledAccent.color)
    }

    @ViewBuilder
    private func statusGlyph(_ r: ScheduledFireRow) -> some View {
        if r.isRunning {
            Circle().fill(ScheduledAccent.color).frame(width: 8, height: 8)
                .modifier(PulseModifier())
        } else if r.ok == false {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.subheadline)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.subheadline)
        }
    }

    private func statusPill(_ s: ScheduledTaskStatus) -> some View {
        let (text, color) = Self.statusLabel(s)
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
                .modifier(PulseModifier(active: s == .running))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }

    // MARK: Text

    static func statusLabel(_ s: ScheduledTaskStatus) -> (String, Color) {
        switch s {
        case .waiting: return (AppLocalized("Waiting for next run"), ScheduledAccent.color)
        case .running: return (AppLocalized("Running now"), ScheduledAccent.color)
        case .disabled: return (AppLocalized("Paused"), .secondary)
        case .cancelled: return (AppLocalized("Cancelled"), .secondary)
        case .failed: return (AppLocalized("Failed"), .red)
        case .timedOut: return (AppLocalized("Timed out"), .red)
        case .completed: return (AppLocalized("Completed"), .green)
        case .stopped: return (AppLocalized("Stopped"), .secondary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "\(Int(seconds))s"
    }

    static func triggerText(_ t: ScheduledTriggerSpec) -> String {
        switch t {
        case .loop(let interval, let count):
            if let count {
                return String(format: AppLocalized("Every %@ · %d runs"), duration(interval), count)
            }
            return String(format: AppLocalized("Every %@ · no limit"), duration(interval))
        case .once(let after):
            return String(format: AppLocalized("Once, %@ after it was set"), duration(after))
        case .cron(let h, let m, let days):
            let time = String(format: "%02d:%02d", h, m)
            if days.isEmpty || days.count == 7 {
                return String(format: AppLocalized("Every day at %@"), time)
            }
            let symbols = Calendar.current.shortWeekdaySymbols
            let names = days.compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            return String(format: AppLocalized("Every %@ at %@"), names.joined(separator: ", "), time)
        case .immediate:
            return AppLocalized("Run once, right away")
        case .onCompletion(let id):
            return String(format: AppLocalized("After task %@ finishes"), id)
        case .raw(let s):
            return s
        }
    }

    private var deliveryText: String? {
        guard let job = store.job else { return nil }
        switch job.target {
        case .new:
            return AppLocalized("A new chat for each run")
        case .followUp(let sid):
            if sid == store.hostSessionId { return AppLocalized("Added to this chat as a new message") }
            return String(format: AppLocalized("Added to the chat “%@”"),
                          store.otherSessionTitles[sid] ?? String(sid.prefix(8)))
        case .rerun:
            return AppLocalized("Regenerates a message in this chat")
        case .childOfCurrent:
            return AppLocalized("Runs as a sub-task; the result comes back to this chat")
        }
    }

    private var nextRunText: String {
        guard let next = store.nextFireAt else { return "—" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .short
        return "\(Self.absoluteTime(next)) · \(rel.localizedString(for: next, relativeTo: now))"
    }

    private var remainingText: String {
        if let r = store.remaining { return String(format: AppLocalized("%d left"), r) }
        if case .loop(_, nil) = store.trigger { return AppLocalized("Unlimited") }
        return "—"
    }

    private func historySubtitle(_ r: ScheduledFireRow) -> String {
        var parts = [Self.absoluteTime(r.at)]
        if r.isRunning {
            parts.append(AppLocalized("Running now"))
        } else if r.ok == false {
            parts.append(AppLocalized("Delivery failed"))
        }
        if r.isOtherSession, let sid = r.sessionId {
            let title = store.otherSessionTitles[sid] ?? ""
            parts.append(title.isEmpty ? String(sid.prefix(8)) : title)
        } else if r.sessionId != nil {
            parts.append(AppLocalized("This chat"))
        }
        return parts.joined(separator: " · ")
    }

    static func absoluteTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        if Calendar.current.isDateInToday(date) {
            f.setLocalizedDateFormatFromTemplate("HH:mm:ss")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        }
        return f.string(from: date)
    }

    // MARK: Actions

    private func flash(_ text: String) {
        withAnimation { copiedToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { copiedToast = nil }
        }
    }

    private func openSession(_ sessionId: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                            userInfo: ["sessionId": sessionId])
        }
    }
}

/// Soft opacity pulse for the "running now" dot.
private struct PulseModifier: ViewModifier {
    var active: Bool = true
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(active && on ? 0.35 : 1)
            .onAppear {
                guard active, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}


// MARK: - [T-scheduled-banner] Chat top banner

/// [T-sched-pill-menu] Pills hidden with "Hide this countdown", per chat: the
/// ids of the jobs live at the time. In memory only — the jobs themselves
/// live only as long as the process, so there is nothing to outlast.
@MainActor
final class ScheduledBannerDismissals: ObservableObject {
    static let shared = ScheduledBannerDismissals()
    @Published private(set) var hidden: [String: Set<String>] = [:]

    func hide(_ jobIds: Set<String>, in sessionId: String) {
        hidden[sessionId, default: []].formUnion(jobIds)
    }

    func isDismissed(_ live: Set<String>, in sessionId: String) -> Bool {
        ScheduledBannerModel.isDismissed(live: live, hidden: hidden[sessionId] ?? [])
    }

    /// Forget jobs that are no longer live, so the entry empties out once
    /// the hidden batch is over.
    func prune(live: Set<String>, in sessionId: String) {
        guard let h = hidden[sessionId] else { return }
        let kept = h.intersection(live)
        if kept != h { hidden[sessionId] = kept.isEmpty ? nil : kept }
    }
}

// [T-sched-pill-align] BEGIN scheduled-pill-face
/// The pill's look, given plain values: the banner below supplies them and
/// owns every action. Kept apart (SwiftUI only) so a standalone snapshot can
/// render it — MinisTests/Standalone/ScheduledPillSnapshot.swift.
struct ScheduledPillFace: View {
    /// Share of the wait elapsed, 0...1.
    let ringFraction: Double
    let glyph: String
    /// Further live tasks ("+N"); 0 shows nothing.
    let others: Int
    let clock: String
    /// [T-sched-pill-count] "2/30" / "#7" after the clock; nil shows nothing.
    var counter: String? = nil
    /// [T-sched-pill-vcenter] `clock` is a status word ("Running",
    /// "Waiting"), not a time: drawn smaller, in the clock's height.
    var clockIsStatus: Bool = false
    let ringSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Around the ring on its leading side and above and below, so at the
    /// default size (26 pt ring, 34 pt pill) it sits concentric in the
    /// capsule's rounded end.
    static let glyphInset: CGFloat = 4
    /// Ring → "+N", and ring or "+N" → clock.
    static let plusGap: CGFloat = 6
    static let clockGap: CGFloat = 8
    /// Clock → run counter, at least. [T-sched-pill-clock-big] The counter's
    /// width-floor slack is added here (it is trailing-aligned), so the
    /// counter always ends at the capsule's trailing inset.
    static let counterGap: CGFloat = 5
    /// Last element → the capsule's trailing end.
    static let clockTrailing: CGFloat = 13
    /// The ring's Dynamic Type cap.
    static let maxRingSize: CGFloat = 36
    /// [T-sched-pill-vcenter] "Running" / "Waiting": footnote (13 pt), well
    /// below the 17 pt clock, same rounded semibold amber.
    static let statusFont: Font = .system(.footnote, design: .rounded).weight(.semibold)

    /// The clock's width floor: every run of digits as "00" (at least as many
    /// zeros as it has digits). With monospaced digits that is the widest the
    /// current format gets, so "01:39" → "00:00" keeps the pill still while
    /// it ticks, and "1h 5m" holds the room of "00h 00m" until the format
    /// itself changes.
    static func clockWidthTemplate(_ clock: String) -> String {
        var out = ""
        var run = 0
        func flush() {
            if run > 0 { out += String(repeating: "0", count: max(2, run)) }
            run = 0
        }
        for ch in clock {
            if ch.isASCII && ch.isNumber { run += 1 } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    var body: some View {
        // Content-hugging: [ring][+N][clock], fixed gaps, no segments.
        HStack(spacing: 0) {
            ring
                .padding(.leading, Self.glyphInset)
                .padding(.vertical, Self.glyphInset)
            if others > 0 {
                Text(verbatim: "+\(others)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(ScheduledAccent.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Self.plusGap)
            }
            // [T-sched-pill-vcenter] Every element centred on the pill's middle
            // line. (A shared text baseline put the smaller counter low.)
            HStack(alignment: .center, spacing: 0) {
                // Leading: any slack of the floor (e.g. "1h 5m" in the room of
                // "00h 00m") goes after the clock, not between ring and clock.
                // [T-sched-pill-clock-big] One size up (headline, 17 pt).
                ZStack(alignment: .leading) {
                    if clockIsStatus {
                        // [T-sched-pill-vcenter] A status word is smaller than
                        // the clock; the hidden digit keeps the clock's height,
                        // so Running <-> 00:14 does not change the pill's height.
                        Text(verbatim: "0").hidden()
                        Text(clock).font(Self.statusFont)
                    } else {
                        Text(verbatim: Self.clockWidthTemplate(clock)).hidden()
                        Text(clock)
                    }
                }
                .font(.system(.headline, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(ScheduledAccent.color)
                .lineLimit(1)
                .fixedSize()
                // [T-sched-pill-count] Which run this is: secondary to the
                // clock (smaller, lighter, same amber), with the same width
                // floor so a fire or skip moving "9/30" to "10/30" does not
                // shift anything. [T-sched-pill-clock-big] Trailing: the
                // floor's slack sits between clock and counter, and the
                // counter ends at the capsule's trailing inset.
                if let counter {
                    ZStack(alignment: .trailing) {
                        Text(verbatim: Self.clockWidthTemplate(counter)).hidden()
                        Text(verbatim: counter)
                    }
                    .font(.system(.caption, design: .rounded).weight(.medium).monospacedDigit())
                    .foregroundStyle(ScheduledAccent.color.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Self.counterGap)
                }
            }
            .padding(.leading, Self.clockGap)
            .padding(.vertical, 7)
        }
        .padding(.trailing, Self.clockTrailing)
        .background {
            Capsule().fill(.regularMaterial)
            Capsule().fill(ScheduledAccent.color.opacity(0.06))
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(ScheduledAccent.color.opacity(0.28), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 3)
        // ~34 pt tall pill; the tap target reaches 44 pt.
        .contentShape(Capsule().inset(by: -5))
        // Width only moves when "+N" or the clock's format changes; ease it.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: others)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: Self.clockWidthTemplate(clock))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: counter.map(Self.clockWidthTemplate))
    }

    /// The glyph in its tinted circle, ringed by how much of the wait has
    /// passed. Moves once a second at most, and not at all for a running or
    /// waiting job, so there is nothing for Reduce Motion to tone down.
    private var ring: some View {
        ZStack {
            Circle().fill(ScheduledAccent.color.opacity(0.15))
            Circle().stroke(ScheduledAccent.color.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: ringFraction)
                .stroke(ScheduledAccent.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: glyph)
                .font(.system(size: ringSize * 0.46, weight: .semibold))
                .foregroundStyle(ScheduledAccent.color)
        }
        .frame(width: ringSize, height: ringSize)
    }
}
// [T-sched-pill-align] END scheduled-pill-face

/// A small centered pill under the chat's navigation bar — glyph ringed by the
/// elapsed wait, then a short clock ("00:48") — while the conversation has a
/// scheduled task still to run. Same amber, glyph, material and stroke as the
/// scheduled-task card; tapping it opens the card's task page.
///
/// - Compact on purpose (user feedback: the full-width card with the title
///   was too big). The title, the "N left" count and the run state in words
///   are read by VoiceOver and shown on the task page; the pill only keeps
///   what changes: the ring, the clock and a "+N" for further tasks.
/// - Hugs its content (a fixed 80 pt glyph segment left a gap users asked
///   about). The clock keeps the width of its format's widest value, so it
///   does not twitch while counting; the width changes only with "+N" or the
///   clock's format (mm:ss → "1h 5m", "Running"), eased.
///
/// - Appears and disappears with the jobs: `AgentJobRegistry
///   .liveScheduledJobIdsBySession` is published from `jobsDidChange()`, so a
///   cancel / finish / delete removes it at once — no polling for presence.
/// - Ticks only while shown: a 1 s `TimelineView`, which SwiftUI suspends
///   off screen and in the background. Each tick re-reads the jobs (a handful
///   of dictionary lookups), so a fire moving `nextFireAt` shows up within a
///   second without any extra notification.
/// - Kept visible while a fire runs (full ring, "Running" in place of the
///   clock), so its height does not toggle on every fire — the list's top
///   inset only changes when the task as a whole starts or ends.
/// - [T-sched-pill-menu] Long-press: hide this countdown / skip the next run /
///   cancel every scheduled task of the chat (confirmed first, same scope as
///   Stop). The same three are VoiceOver actions. [T-sched-run-now] "Run Now"
///   leads the menu while the run counted down to has not started.
struct ScheduledTaskBanner: View {
    let sessionId: String
    @ObservedObject private var registry = AgentJobRegistry.shared
    @ObservedObject private var dismissals = ScheduledBannerDismissals.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmCancelAll = false
    /// The ring grows with Dynamic Type; the cap keeps it (and "+N") inside
    /// the fixed glyph segment up to the xxxLarge limit below.
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 26

    private var jobIds: Set<String> { registry.activeScheduleJobIdsBySession[sessionId] ?? [] }

    /// Live jobs and not hidden from the long-press menu. Hiding only
    /// removes the pill: the jobs still fire and still keep the chat active.
    private var isShown: Bool {
        !jobIds.isEmpty && !dismissals.isDismissed(jobIds, in: sessionId)
    }

    var body: some View {
        Group {
            if isShown {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let state = ScheduledBannerModel.state(snapshot()) {
                        card(state, now: context.date)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: isShown)
        .onChange(of: jobIds) { ids in dismissals.prune(live: ids, in: sessionId) }
        .alert(AppLocalized("Cancel all scheduled tasks?"), isPresented: $confirmCancelAll) {
            Button(AppLocalized("Cancel All"), role: .destructive) { cancelAll() }
            Button(AppLocalized("Not Now"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Every task still planned in this conversation will be cancelled."))
        }
    }

    /// The live jobs, re-read on every tick.
    private func snapshot() -> [ScheduledBannerJob] {
        registry.scheduledBannerJobs(for: sessionId)
    }

    private func card(_ state: ScheduledBannerModel.State, now: Date) -> some View {
        let seconds = state.job.nextFireAt.map { $0.timeIntervalSince(now) }
        return Button { open(state.job.id) } label: {
            ScheduledPillFace(ringFraction: ringFraction(state, now: now),
                              glyph: state.phase == .waiting ? "hourglass" : ScheduledAccent.icon,
                              others: state.others,
                              clock: clockText(state, seconds: seconds),
                              counter: ScheduledBannerModel.runCounter(state.job, running: state.phase == .running),
                              clockIsStatus: state.phase != .countdown,
                              ringSize: min(ringSize, ScheduledPillFace.maxRingSize))
        }
        .buttonStyle(.plain)
        .contextMenu { menu(jobId: state.job.id, phase: state.phase, run: state.job.runsDone) }
        // On the Button itself, so VoiceOver meets ONE button: wrapping it in
        // a further element left the Button's own combined label as a second,
        // nested stop (seen in the device accessibility tree).
        .accessibilityLabel(accessibilityText(state, seconds: seconds))
        .accessibilityHint(Text(AppLocalized("Opens the task details")))
        .accessibilityAction(named: Text(AppLocalized("Hide This Countdown"))) { hide() }
        .accessibilityAction(named: Text(AppLocalized("Skip Next Run"))) { skipNext(state.job.id) }
        .accessibilityAction(named: Text(AppLocalized("Cancel All Scheduled Tasks"))) { confirmCancelAll = true }
        // [T-sched-run-now] Offered only while counting down; the action
        // re-checks at activation like the menu item.
        .accessibilityActions {
            if runNowOffered(jobId: state.job.id, phase: state.phase) {
                Button(AppLocalized("Run Now")) { runNow(state.job.id, run: state.job.runsDone) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }

    /// Share of the wait elapsed, for the ring: full while a run is in
    /// progress, empty while waiting on another task.
    private func ringFraction(_ state: ScheduledBannerModel.State, now: Date) -> Double {
        switch state.phase {
        case .countdown: ScheduledBannerModel.progress(state.job, now: now)
        case .running: 1
        case .waiting: 0
        }
    }

    /// The pill's one line: the clock, or a single word when there is nothing
    /// to count down to (running now / waiting on another task).
    private func clockText(_ state: ScheduledBannerModel.State, seconds: TimeInterval?) -> String {
        switch state.phase {
        case .running: return AppLocalized("Running")
        case .waiting: return AppLocalized("Waiting")
        case .countdown: return seconds.map(Self.visibleCountdown) ?? ""
        }
    }

    private func spokenSubtitle(_ state: ScheduledBannerModel.State) -> String {
        switch state.phase {
        case .running: return AppLocalized("Run in progress")
        case .waiting: return AppLocalized("Waiting for another task to finish")
        case .countdown:
            if let left = state.job.remaining { return AppLocalized("Upcoming run · \(left) left") }
            return AppLocalized("Upcoming run")
        }
    }

    private func accessibilityText(_ state: ScheduledBannerModel.State, seconds: TimeInterval?) -> String {
        var parts = [AppLocalized("Upcoming scheduled task"), state.job.title, spokenSubtitle(state)]
        // [T-sched-pill-count] The counter, as a sentence.
        if let n = ScheduledBannerModel.runNumber(state.job, running: state.phase == .running) {
            parts.append(state.job.runTotal.map { AppLocalized("Run \(n) of \($0)") } ?? AppLocalized("Run \(n)"))
        }
        if let seconds, let spoken = Self.spokenDuration(seconds) {
            parts.append(AppLocalized("Next run in \(spoken)"))
        }
        if state.others > 0 { parts.append(AppLocalized("+\(state.others) more")) }
        return parts.joined(separator: ", ")
    }

    // MARK: Long-press menu

    /// "Next run" is the job the pill is showing: the soonest, or the one
    /// running now (whose following run is then the one skipped).
    /// [T-sched-run-now] "Run Now" comes first, and only while the pill is
    /// counting down to a run that has not started (same state the pill
    /// draws from, read again as the menu opens).
    @ViewBuilder
    private func menu(jobId: String, phase: ScheduledBannerModel.Phase, run: Int) -> some View {
        if runNowOffered(jobId: jobId, phase: phase) {
            Button { runNow(jobId, run: run) } label: {
                Label(AppLocalized("Run Now"), systemImage: "play.fill")
            }
        }
        Button { hide() } label: {
            Label(AppLocalized("Hide This Countdown"), systemImage: "eye.slash")
        }
        // The menu's items are built as it opens, so this is the moment
        // it appears: one medium tap, like the composer's other press-and-
        // hold controls. UIKit feedback already honours the system haptics
        // switch; the app has no switch of its own.
        .onAppear { menuDidOpen() }
        Button { skipNext(jobId) } label: {
            Label(AppLocalized("Skip Next Run"), systemImage: "forward.end")
        }
        Button(role: .destructive) { confirmCancelAll = true } label: {
            Label(AppLocalized("Cancel All Scheduled Tasks"), systemImage: "xmark.circle")
        }
    }

    private func menuDidOpen() {
        logger.info("[SchedPill] menu opened session=\(sessionId.prefix(8))")
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func hide() {
        logger.info("[SchedPill] hide session=\(sessionId.prefix(8)) jobs=\(jobIds.count)")
        dismissals.hide(jobIds, in: sessionId)
    }

    private func runNowOffered(jobId: String, phase: ScheduledBannerModel.Phase) -> Bool {
        guard phase == .countdown, let job = registry.job(id: jobId) else { return false }
        return ScheduledJobRunner.canRunNow(job)
    }

    /// [T-sched-run-now] The tap re-decides from the live job and claims the
    /// fire atomically (`ScheduledJobRunner.runNow`); a run that started since
    /// the menu opened (`run` = the run the menu showed), or a second tap,
    /// does nothing.
    private func runNow(_ jobId: String, run: Int) {
        guard let job = registry.job(id: jobId) else { return }
        let started = ScheduledJobRunner.runNow(job, expectedRun: run)
        logger.info("[SchedPill] run now session=\(sessionId.prefix(8)) job=\(jobId.prefix(8)) started=\(started)")
    }

    private func skipNext(_ jobId: String) {
        guard let job = registry.job(id: jobId) else { return }
        ScheduledJobRunner.skipNext(job)
    }

    /// The Stop button's "Stop All" scope and call, without stopping a reply.
    private func cancelAll() {
        let n = registry.cancelScheduled(createdBy: sessionId, reason: "user cancelled all from the timer pill")
        logger.info("[SchedPill] cancel all session=\(sessionId.prefix(8)) cancelled=\(n)")
    }

    private func open(_ jobId: String) {
        guard let job = registry.job(id: jobId) else { return }
        // The card's own route: AIChatView turns this into the task page sheet.
        NotificationCenter.default.post(name: .openAgentCallback, object: nil, userInfo: [
            "callback": ScheduledJobRunner.detailCallback(for: job),
            "sessionId": sessionId,
        ])
    }

    /// "00:48" up to an hour, then "1h 5m" (minutes rounded up), then "1d 3h";
    /// the coarse forms are system-localized.
    static func visibleCountdown(_ seconds: TimeInterval) -> String {
        if let clock = ScheduledBannerModel.countdown(seconds) { return clock }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        let s = seconds.rounded(.up)
        if s < 86_400 {
            f.allowedUnits = [.hour, .minute]
            return f.string(from: (s / 60).rounded(.up) * 60) ?? ""
        }
        f.allowedUnits = [.day, .hour]
        return f.string(from: s) ?? ""
    }

    /// "48 seconds" / "1 minute, 12 seconds" for VoiceOver.
    static func spokenDuration(_ seconds: TimeInterval) -> String? {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour] : (seconds >= 3600 ? [.hour, .minute] : [.minute, .second])
        f.maximumUnitCount = 2
        return f.string(from: max(0, seconds.rounded(.up)))
    }
}

// [T-live-activity-scheduled] One source for the chat pill and the Live
// Activity's waiting card, so the two never show different times or counts.
extension AgentJobRegistry {
    /// The live scheduled jobs keeping `sessionId` active, as the pill sees them.
    func scheduledBannerJobs(for sessionId: String) -> [ScheduledBannerJob] {
        (activeScheduleJobIdsBySession[sessionId] ?? []).compactMap { id -> ScheduledBannerJob? in
            // The registry's one rule, re-checked per call for a job that
            // changed since the last push (e.g. its upstream just finished).
            guard let job = self.job(id: id), sessionKeptActive(by: job) == sessionId
            else { return nil }
            let start: Date = {
                if case .loop(let interval, _) = job.trigger, let next = job.nextFireAt {
                    return next.addingTimeInterval(-interval)
                }
                return job.fireLog.last?.at ?? job.createdAt
            }()
            let (total, repeats): (Int?, Bool) = switch job.trigger {
            case .loop(_, let count): (count, true)
            case .cron: (nil, true)
            case .once, .onCompletion, .immediate: (nil, false)
            }
            return ScheduledBannerJob(id: job.id, title: job.label ?? job.title,
                                      nextFireAt: job.nextFireAt, windowStart: start,
                                      remaining: job.remaining,
                                      isFiringNow: ScheduledTaskDetailStore.isProcessingNow(job),
                                      runsDone: job.firedCount + job.skippedCount,
                                      runTotal: total, repeats: repeats)
        }
    }
}

extension ScheduledBannerModel {
    /// [T-live-activity-scheduled] The Live Activity card of each conversation
    /// waiting for its next scheduled run: the pill's job, phase and run
    /// counter. The widget counts down to `nextRunAt` itself, so a card only
    /// changes when a run starts or ends - no per-second pushes.
    @MainActor
    static func liveActivityWaitCards(for sessionIds: [String], titles: [String: String]) -> [LiveSessionSnapshot] {
        sessionIds.compactMap { sid in
            guard let state = state(AgentJobRegistry.shared.scheduledBannerJobs(for: sid)) else { return nil }
            let firing = state.phase == .running
            let counter = runCounter(state.job, running: firing)
            let label = firing ? AppLocalized("Working...") : AppLocalized("Next run")
            let title = titles[sid].flatMap { $0.isEmpty ? nil : $0 } ?? state.job.title
            return LiveSessionSnapshot(
                sessionId: sid,
                title: title.isEmpty ? AppLocalized("Agent Task") : title,
                toolIcon: state.phase == .waiting ? "hourglass" : ScheduledAccent.icon,
                toolStatus: counter.map { "\(label) · \($0)" } ?? label,
                loopIteration: 0,
                scheduledWaiting: true,
                nextRunAt: state.phase == .countdown ? state.job.nextFireAt : nil,
                runCounter: counter
            )
        }
    }
}
