import Foundation

// [T-p0-agent-job-registry] Component B of the sub-agent / scheduled-task
// design (docs: subagent_design_v4 §8.1–8.2): the single in-process registry
// for every job that can inject a prompt into a session later — a
// `minis-scheduled` timer, a `delegate_task` helper run, a completion hook.
//
// Deliberately NOT persisted. The app being killed empties it; that is the
// documented "best effort within the session's lifetime" boundary. Anything
// that must survive a kill (Android's AlarmManager tasks, the P2 insurance
// notification) lives elsewhere and only mirrors into here at runtime.
//
// There is no `kind` field. Purpose is fully expressed by `trigger` (when it
// fires) and `target` (where it lands); "is this a helper job" is
// `target.isChildOfCurrent`, "who made it" is `origin`. A separate kind enum
// would have to be kept consistent with both and adds nothing.
//
// P0 ships the data model, lifecycle (register / start / finish / cancel),
// the loop-end observer that closes running jobs, and the `.followUpParent`
// hook wired to component A. Nothing registers a job yet — P1's
// `delegate_task` and P2's `minis-scheduled` are the producers.

/// Who created the job.
enum AgentJobOrigin: String {
    /// The model called a tool (`delegate_task`).
    case tool
    /// The sandbox CLI (`minis-scheduled`).
    case cli
    /// An App Intent.
    case shortcut
}

/// When the job fires.
enum AgentJobTrigger: Equatable {
    /// Run now (helper runs; `minis-scheduled run --id`).
    case immediate
    /// Once, after a delay from registration.
    case once(after: TimeInterval)
    /// Repeatedly, every `interval`; `count == nil` means until cancelled.
    case loop(interval: TimeInterval, count: Int?)
    /// Calendar time. iOS P2 keeps it in-process (best effort); the fields
    /// mirror Android's `ScheduledTask` so the CLI contract stays identical.
    case cron(hour: Int, minute: Int, days: Set<Int>, start: Date?, end: Date?)
    /// When another job finishes.
    case onCompletion(ofJobId: String)

    var logLabel: String {
        switch self {
        case .immediate: return "immediate"
        case .once(let after): return "once(+\(Int(after))s)"
        case .loop(let interval, let count): return "loop(\(Int(interval))s×\(count.map(String.init) ?? "∞"))"
        case .cron(let h, let m, let days, _, _): return "cron(\(h):\(String(format: "%02d", m)) days=\(days.sorted()))"
        case .onCompletion(let id): return "onCompletion(\(id.prefix(8)))"
        }
    }
}

/// Where the job's prompt lands.
enum AgentJobTarget: Equatable {
    /// A brand-new top-level session (visible in the home list).
    case new
    /// Appended as a new turn to an existing session.
    case followUp(sessionId: String)
    /// Re-run an existing session from a given user message.
    case rerun(sessionId: String, messageId: String)
    /// A hidden child session of `parentSessionId` (`parent_session_id` set).
    /// `parentToolUseId` is the `delegate_task` block that spawned it, or nil
    /// for a CLI `--target child-of-current`.
    case childOfCurrent(parentSessionId: String, parentToolUseId: String?)

    var isChildOfCurrent: Bool {
        if case .childOfCurrent = self { return true }
        return false
    }

    var parentSessionId: String? {
        if case .childOfCurrent(let parent, _) = self { return parent }
        return nil
    }

    var logLabel: String {
        switch self {
        case .new: return "new"
        case .followUp(let sid): return "followUp(\(sid.prefix(8)))"
        case .rerun(let sid, let mid): return "rerun(\(sid.prefix(8))/\(mid.prefix(8)))"
        case .childOfCurrent(let p, let t): return "childOfCurrent(\(p.prefix(8)) tool=\(t?.prefix(8) ?? "-"))"
        }
    }
}

/// What happens when the job's run finishes.
enum AgentJobThen: Equatable {
    /// Nothing — the producer is awaiting the run in-process (wait-mode
    /// `delegate_task`) or nobody cares.
    case none
    /// Inject a structured result message into the parent session through
    /// component A. `template` may contain `{{result}}`; when nil the
    /// registry builds the default header + result body.
    case followUpParent(template: String?)
}

enum AgentJobState: String {
    case pending, running, done, cancelled, failed
    /// The wall-clock budget elapsed and the run was cut short.
    case timeout
}

/// One registered job. A class so the registry can hand out a stable
/// reference while fields mutate; all access is main-actor.
@MainActor
final class AgentJob: Identifiable {
    let id: String
    let label: String?
    let origin: AgentJobOrigin
    let trigger: AgentJobTrigger
    let target: AgentJobTarget
    /// The prompt text for prompt-carrying targets (nil for `.rerun`).
    let prompt: String?
    /// Mutable: a wait-mode helper converts to `.followUpParent` when the
    /// user sends a follow-up while it is still running.
    var then: AgentJobThen
    /// User-facing title (helper `tool_title`, scheduled `--label`); shows on
    /// the capsule and in the completion header.
    let title: String

    private(set) var state: AgentJobState = .pending
    private(set) var firedCount = 0
    /// Remaining fires for `.loop(count:)`; nil = unbounded / not a loop.
    var remaining: Int?
    /// [T-sched-pill-count] Runs dropped with "Skip next run". They count
    /// against a loop's `remaining`, so the pill's "2/30" counts them too.
    var skippedCount = 0
    /// The Swift task driving the trigger (timer sleep) or awaiting the run.
    var task: Task<Void, Never>?
    /// Identifier of the insurance notification (P2), for cancellation.
    var notifId: String?
    /// The session the run executes in once known (the child session for
    /// `.childOfCurrent`, the target session otherwise).
    var runSessionId: String?
    /// Which model tier actually ran (helper jobs).
    /// [T-sub-agents-v1] "pinned" or "inherited" — where this job's model came
    /// from. Replaces the old primary/sub tier, which no longer exists.
    var modelOrigin: String?
    /// [T-sub-agents-v1] Display name of the sub agent definition this job runs
    /// under. Snapshotted at start; a later rename or delete does not rewrite it.
    var subAgentName: String?
    /// [T-sub-agents-steer] Course corrections that were queued but never read,
    /// because the run ended first. Reported back so the parent knows its steer
    /// did not shape this result.
    var missedSteers: [String] = []
    /// [T-sub-agents-resume] True when this job is a resumed run of a sub agent
    /// that was interrupted. Reported in the result so the parent model knows
    /// the run was not continuous — its tool context was lost midway, and the
    /// elapsed/turn counts below cover only the resumed part.
    var wasResumed = false
    /// [T-agent-model-identity] tier / resolved / effective model of a child
    /// job. Seeded by the producer at start, merged with the child's live
    /// `lastEffectiveModel` while it runs and once more at finish.
    var modelIdentity: HelperModelIdentity?
    // [T-p2-minis-scheduled] Scheduler state.
    /// `minis-scheduled disable`: an armed job that must not fire.
    var isEnabled = true
    /// Next planned fire for timer triggers; nil for event triggers.
    var nextFireAt: Date?
    /// [T-sched-run-now] A fire of this job has been claimed and has not
    /// returned yet. Set and cleared only by ScheduledJobRunner's claim
    /// (`claimFire` / the end of `fire`), which the armed timer and "Run now"
    /// both go through, so the two can never fire the same run twice.
    var fireInFlight = false
    /// [T-sched-run-now] The cron slot the current fire consumes. Equal to the
    /// fire time for a timer fire; earlier than its slot for "Run now", so the
    /// following run is searched from the slot, not from now.
    var firingSlot: Date?
    /// `--model <entry_id>` override for `.new` targets.
    var modelEntryId: String?
    /// [T-scheduled-preset-tool] `--command` / `--tool-args`: a tool call run as
    /// the first step of every fire, so the model only has to read its output.
    /// nil for every job without the flag — those fire exactly as before.
    var presetToolCall: ScheduledPresetToolCall?
    /// [T-scheduled-session-ownership] The conversation this job was CREATED
    /// from — distinct from `target.parentSessionId`, which only exists for
    /// `.childOfCurrent` and means "the parent of the child session".
    ///
    /// Without it a job is unreachable from the session that made it: a
    /// `--target follow-up --session X` loop created in X is not
    /// `isChildOfCurrent`, so `hasActiveChildren(parent:)` and
    /// `cancelAll(parent:)` both miss it entirely — X's Stop button could not
    /// stop a timer X had started, and no surface could report that X still
    /// had one planned.
    var creatorSessionId: String?
    /// [T-scheduled-thinking-level] `--thinking off|low|medium|high|xhigh`.
    ///
    /// nil = don't touch the session's level: a `.followUp` / `.rerun` job keeps
    /// whatever the conversation it lands in already uses, and a `.new` session
    /// keeps whatever its group default gives it. Only an explicit flag
    /// overrides, so every existing job behaves exactly as before.
    var thinkingLevel: ThinkingLevel?
    /// Producer hook run by `finish` before `then` (background helpers use
    /// it to write the final JSON into the parent's tool block).
    var completionHook: ((AgentJob) -> Void)?
    // [T-p2-progress-report] Mid-run progress reports to the parent model.
    /// "none" | "frequent" (every 15s when something changed) | "moderate" (every 60s).
    var progressLevel: String = "none"
    /// The reporter task; cancelled with the job.
    var progressTask: Task<Void, Never>?
    /// The queued (not yet consumed) progress prompt in the parent, so a
    /// newer report replaces it instead of stacking up while the parent is busy.
    var pendingProgressPromptId: UUID?
    /// Signature of the last report sent (frequent mode skips unchanged ones).
    var lastProgressSignature: String?
    /// "Tools · turns · tokens" line maintained by the producer; appended to
    /// progress reports and to the completion header.
    var summaryLine: String?
    /// Session the most recent fire landed in / last fire outcome.
    private(set) var lastFireOk: Bool?
    let createdAt = Date()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Final result text (last assistant message), filled by `finish`.
    private(set) var resultText: String?

    fileprivate init(id: String, label: String?, title: String, origin: AgentJobOrigin,
                     trigger: AgentJobTrigger, target: AgentJobTarget, prompt: String?, then: AgentJobThen) {
        self.id = id
        self.label = label
        self.title = title
        self.origin = origin
        self.trigger = trigger
        self.target = target
        self.prompt = prompt
        self.then = then
        if case .loop(_, let count) = trigger { self.remaining = count }
    }

    fileprivate func markRunning(sessionId: String?) {
        state = .running
        startedAt = startedAt ?? Date()
        firedCount += 1
        if let sessionId { runSessionId = sessionId }
        if let r = remaining { remaining = max(0, r - 1) }
        appendFireLog(sessionId: sessionId, ok: nil)
    }

    fileprivate func recordFire(sessionId: String?, ok: Bool) {
        firedCount += 1
        lastFireOk = ok
        if let sessionId { runSessionId = sessionId }
        if let r = remaining { remaining = max(0, r - 1) }
        startedAt = startedAt ?? Date()
        appendFireLog(sessionId: sessionId, ok: ok)
    }

    /// [T-scheduled-task-detail] One entry per fire, for the task's detail
    /// page. In memory only, like the job itself. It is the only record of a
    /// `rerun` fire (which writes no envelope message) and of a delivery that
    /// failed; fires that did write an envelope are also found in the chat
    /// store, and the page merges both. Bounded so an unbounded loop that runs
    /// for days cannot grow it without limit.
    struct FireLogEntry: Equatable {
        let index: Int
        let at: Date
        let sessionId: String?
        /// nil = handed to a child run whose outcome is not known yet.
        let ok: Bool?
    }
    private(set) var fireLog: [FireLogEntry] = []
    static let fireLogLimit = 500

    private func appendFireLog(sessionId: String?, ok: Bool?) {
        fireLog.append(FireLogEntry(index: firedCount, at: Date(), sessionId: sessionId, ok: ok))
        if fireLog.count > Self.fireLogLimit { fireLog.removeFirst(fireLog.count - Self.fireLogLimit) }
    }

    fileprivate func markFinished(_ final: AgentJobState, result: String?) {
        state = final
        finishedAt = Date()
        resultText = result
        task?.cancel()
        task = nil
        progressTask?.cancel()
        progressTask = nil
    }

    /// [T-sub-agents-busy] Running far past any budget it could have been
    /// given. Used only to stop a wedged job from pinning the composer to
    /// Stop; see `AgentJobRegistry.stuckAfter`.
    var looksStuck: Bool {
        guard state == .running || state == .pending else { return false }
        return Date().timeIntervalSince(startedAt ?? createdAt) > AgentJobRegistry.stuckAfter
    }

    var elapsed: TimeInterval? {
        guard let s = startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(s)
    }

    /// [T-log-noise-privacy] Identity and shape, never the title. A job's
    /// title is the user's own task text ("调研 2021 年苹果发布会及销售情况"),
    /// and it appeared on every REGISTER / RUNNING / FINISH / CANCEL line —
    /// which sub agents multiplied, since a fan-out registers one job per
    /// delegation. The id is what correlates lines; the prose was never what
    /// anyone read a log for.
    var logLabel: String {
        "job \(id.prefix(8)) origin=\(origin.rawValue) trigger=\(trigger.logLabel) target=\(target.logLabel) state=\(state.rawValue)"
    }
}

@MainActor
final class AgentJobRegistry: ObservableObject {
    static let shared = AgentJobRegistry()

    /// [T-limits-per-parent] Cap on child-session jobs (sub agents: delegate_task
    /// runs and scheduled child-of-current fires) running at once, PER PARENT
    /// conversation (design §4.3; the value lives in `ConcurrencyLimits`). Each
    /// parent has its own allowance, so one busy conversation can no longer
    /// make every other conversation's delegations queue.
    ///
    /// Child runs do not take `SessionConcurrencyManager` slots - the agent
    /// loop gate exempts any vm with a `helperConfig`
    /// (`AIChatViewModel.acquireSessionSlot`). A parent awaiting its helper
    /// already holds one, so routing helpers through the same pool could leave
    /// every parent waiting behind its own children. (Before this change the
    /// comment here said the same, but the child's `send()` took a slot anyway.)
    static var maxChildJobsPerParent: Int { ConcurrencyLimits.childJobsPerParent }

    /// [T-sub-agents-queue] Delegations that arrived while all slots were busy.
    ///
    /// They are NOT rejected and they do NOT block the calling tool: the tool
    /// returns `status: queued` immediately (a turn cannot finish until every
    /// tool call in it returns, so suspending one would freeze the whole
    /// conversation — and the results of the sub agents that DID start could
    /// not reach the model either). When a slot frees, `finish()` starts the
    /// next one and it reports back through the same callback as any other
    /// background run, so the model never has to remember to re-delegate.
    ///
    /// Stored as the original tool arguments rather than a half-built job: the
    /// wait can be long, and re-running the whole entry point re-resolves the
    /// sub agent definition, the model group and every limit against the state
    /// that is true when it actually starts.
    // BEGIN PerParentQueue
    struct QueuedDelegation {
        let parentSessionId: String
        let args: [String: Any]
        let toolUseId: String
        let queuedAt = Date()
    }

    private(set) var queuedDelegations: [QueuedDelegation] = [] {
        didSet { jobsDidChange() }   // [T-scheduled-active-session] parents with queued work are busy
    }

    /// [T-sub-agents-queue-orphan] Is this tool call still in the queue?
    ///
    /// The queue lives only in memory, so after a restart a block persisted as
    /// `status: queued` has nothing behind it — the delegation it represents
    /// can never start. The UI asks this to tell a live wait from that
    /// orphaned state, the same way a `running` block is checked against the
    /// job list.
    /// [T-subagent-link-survives-reload] The child session of the live job
    /// that a parent's delegate block (by tool_use id) started, if any.
    func childSessionId(forToolUseId toolUseId: String) -> String? {
        jobs.values
            .filter { if case .childOfCurrent(_, let t) = $0.target { return t == toolUseId }; return false }
            .filter { $0.state == .running || $0.state == .pending }
            .compactMap(\.runSessionId).first
    }

    func isQueued(toolUseId: String) -> Bool {
        queuedDelegations.contains { $0.toolUseId == toolUseId }
    }

    /// How many are waiting for a slot in `parent`.
    func queuedCount(parent parentSessionId: String) -> Int {
        queuedDelegations.filter { $0.parentSessionId == parentSessionId }.count
    }

    /// Cap on the backlog, so a model that fires off a dozen delegations in one
    /// turn cannot leave a queue that outlives the user's interest in it.
    ///
    /// [T-limits-per-parent] Per parent, like the running cap: one
    /// conversation's backlog cannot fill the queue for the others. With 3
    /// running and 10 queued, a parent can have at most 13 delegations pending
    /// at one instant. Past that a delegation is REFUSED rather than queued,
    /// and the refusal says so explicitly so the model re-delegates later
    /// instead of assuming it was accepted.
    static var maxQueuedDelegationsPerParent: Int { ConcurrencyLimits.queuedDelegationsPerParent }

    func enqueueDelegation(_ item: QueuedDelegation) -> Bool {
        let waiting = queuedCount(parent: item.parentSessionId)
        guard waiting < Self.maxQueuedDelegationsPerParent else {
            logger.warning("[Jobs] delegation queue full for parent \(item.parentSessionId.prefix(8)) (\(Self.maxQueuedDelegationsPerParent)) — refusing \(item.toolUseId.prefix(12))")
            return false
        }
        queuedDelegations.append(item)
        logger.info("[Jobs] QUEUED delegation tool=\(item.toolUseId.prefix(12)) parent=\(item.parentSessionId.prefix(8)) depth=\(waiting + 1) total=\(self.queuedDelegations.count)")
        return true
    }
    // END PerParentQueue

    /// Drop anything queued for `parentSessionId` (session deleted, user stop).
    func dropQueuedDelegations(parent parentSessionId: String, reason: String) {
        let before = queuedDelegations.count
        queuedDelegations.removeAll { $0.parentSessionId == parentSessionId }
        if before != queuedDelegations.count {
            logger.info("[Jobs] dropped \(before - self.queuedDelegations.count) queued delegation(s) for \(parentSessionId.prefix(8)) — \(reason)")
        }
    }

    @Published private(set) var jobs: [String: AgentJob] = [:]
    /// runSessionId → jobId, for closing jobs from the loop-end notification.
    private var jobBySession: [String: String] = [:]
    private var loopEndObserver: Any?
    private var activityObserver: Any?

    private init() {
        // Every AIChatViewModel posts this when a loop finishes on a vm that
        // is not the one on screen — which is exactly every headless run.
        loopEndObserver = NotificationCenter.default.addObserver(
            forName: .sessionAgentLoopDidEnd, object: nil, queue: .main
        ) { [weak self] note in
            guard let sid = note.object as? String else { return }
            Task { @MainActor [weak self] in self?.sessionLoopDidEnd(sid) }
        }
        // [T-sub-agents-queue] Safety net on a signal that is NOT part of the
        // ending path. `sessionDidUpdate` fires whenever any session's rows
        // change — including each running sub agent's own writes — so if a
        // slot was freed without `finish()` running, the next thing any
        // sibling does recovers the queue. Deliberately not the loop-end
        // notification above: that is the same path as `finish()`, so it
        // could not cover a job that never reached it. `drainIfStalled`
        // returns immediately unless a slot is free AND work is waiting.
        activityObserver = NotificationCenter.default.addObserver(
            forName: .sessionDidUpdate, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainIfStalled()
                // [T-scheduled-active-session] `parentsWithActiveChildren` drops
                // a job once it `looksStuck`, which is time-based and has no
                // event of its own; any session activity re-derives it.
                self?.jobsDidChange()
            }
        }
    }

    // MARK: - Register / query

    @discardableResult
    func register(title: String,
                  label: String? = nil,
                  origin: AgentJobOrigin,
                  trigger: AgentJobTrigger,
                  target: AgentJobTarget,
                  prompt: String?,
                  then: AgentJobThen? = nil) -> AgentJob {
        // childOfCurrent defaults to reporting back to the parent — a hidden
        // child whose result goes nowhere has no entry point (design §8.1).
        let resolvedThen: AgentJobThen = then ?? (target.isChildOfCurrent ? .followUpParent(template: nil) : .none)
        let job = AgentJob(id: UUID().uuidString, label: label, title: title, origin: origin,
                           trigger: trigger, target: target, prompt: prompt, then: resolvedThen)
        jobs[job.id] = job
        logger.info("[Jobs] REGISTER \(job.logLabel) then=\(String(describing: resolvedThen))")
        jobsDidChange()
        return job
    }

    func job(id: String) -> AgentJob? { jobs[id] }

    func job(label: String) -> AgentJob? {
        jobs.values
            .filter { $0.label == label && ($0.state == .pending || $0.state == .running) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    /// A timer fired (schedule jobs): bump counters without changing state.
    func recordFire(_ jobId: String, sessionId: String?, ok: Bool) {
        guard let job = jobs[jobId] else { return }
        job.recordFire(sessionId: sessionId, ok: ok)
        logger.info("[Jobs] FIRED \(job.logLabel) session=\(sessionId?.prefix(8) ?? "nil") ok=\(ok) fired=\(job.firedCount) remaining=\(job.remaining.map(String.init) ?? "∞")")
    }

    /// `minis-scheduled enable|disable` — re-arms or disarms the trigger.
    func setEnabled(jobId: String, enabled: Bool) {
        guard let job = jobs[jobId] else { return }
        job.isEnabled = enabled
        if enabled {
            ScheduledJobRunner.arm(job)
        } else {
            job.task?.cancel()
            job.task = nil
            job.nextFireAt = nil
            JobInsuranceNotification.cancel(jobId: jobId)
        }
        logger.info("[Jobs] \(enabled ? "ENABLE" : "DISABLE") \(job.logLabel)")
        jobsDidChange()
    }

    /// Drop a job entirely (after cancel).
    func remove(jobId: String) {
        jobs[jobId]?.task?.cancel()
        jobs[jobId] = nil
        JobInsuranceNotification.cancel(jobId: jobId)
        jobsDidChange()
    }

    /// CLI / RPC projection of a job — field names match Android's
    /// `taskJson` where the concept exists there.
    func jobDict(_ job: AgentJob) -> [String: Any] {
        var d: [String: Any] = [
            "id": job.id,
            "label": job.label ?? NSNull(),
            "title": job.title,
            "origin": job.origin.rawValue,
            "trigger": job.trigger.logLabel,
            "target": job.target.logLabel,
            "state": job.state.rawValue,
            "enabled": job.isEnabled,
            "firedCount": job.firedCount,
            "remaining": job.remaining ?? NSNull(),
            "createdAt": ScheduledJobRunner.iso(job.createdAt),
        ]
        if let n = job.nextFireAt { d["nextFireAt"] = ScheduledJobRunner.iso(n) }
        if let s = job.runSessionId { d["sessionId"] = s }
        if let p = job.target.parentSessionId { d["parentSessionId"] = p }
        if let t = job.modelOrigin { d["modelOrigin"] = t }
        // [T-scheduled-thinking-level] Only when set, so `list` output for an
        // existing job is unchanged.
        if let lvl = job.thinkingLevel { d["thinking"] = lvl.rawValue }
        // [T-scheduled-session-ownership] So `list` shows which conversation
        // owns a timer, and the model can tell its own from another chat's.
        if let c = job.creatorSessionId { d["creatorSessionId"] = c }
        if let id = job.modelIdentity { d["modelIdentity"] = id.payload() }
        if let ok = job.lastFireOk { d["lastFireOk"] = ok }
        if let p = job.prompt { d["prompt"] = String(p.prefix(200)) }
        // [T-scheduled-preset-tool] Only when set, like `thinking` above. Key
        // shared with Android's `list` output.
        if let preset = job.presetToolCall { d["prefillTool"] = preset.summary }
        return d
    }

    /// Every job, newest first.
    func list() -> [AgentJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Running/pending child-session jobs of `parent` — the capsule's data.
    func activeChildren(parent parentSessionId: String) -> [AgentJob] {
        jobs.values.filter {
            $0.target.parentSessionId == parentSessionId && ($0.state == .running || $0.state == .pending)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// [T-sub-agents-busy] True while `parent` still has a sub agent working.
    ///
    /// The conversation is not finished just because its own loop stopped: a
    /// background delegation keeps running and will post its result back as a
    /// new turn. The composer uses this so the button stays "stop", and the
    /// user is not shown an idle chat that is about to speak again.
    /// [T-sidebar-subagent-running] Every parent with work still in flight, in
    /// one pass — for the sidebar's folder aggregation, which asks about a
    /// whole list rather than one session at a time.
    var parentsWithActiveChildren: Set<String> {
        var out = Set(queuedDelegations.map(\.parentSessionId))
        for job in jobs.values where job.state == .running || job.state == .pending {
            guard !job.looksStuck, let parent = job.target.parentSessionId else { continue }
            out.insert(parent)
        }
        return out
    }

    func hasActiveChildren(parent parentSessionId: String) -> Bool {
        // [T-sub-agents-queue] A queued delegation counts: it will start on its
        // own, so the conversation is not finished.
        if queuedCount(parent: parentSessionId) > 0 { return true }
        return jobs.values.contains {
            $0.target.parentSessionId == parentSessionId
                && ($0.state == .running || $0.state == .pending)
                && !$0.looksStuck
        }
    }

    /// Belt and braces for the composer: a job that has outlived the largest
    /// budget any delegation can ask for, plus the wrap-up grace and a wide
    /// margin, is treated as no longer active for UI purposes.
    ///
    /// Every path that ends a run calls `finish()` — the background watcher on
    /// its own Task, the loop-end observer, cancel, session delete — and the
    /// registry is in-memory so a kill empties it. This exists only so that a
    /// bug in one of those can never leave the user with a composer stuck on
    /// Stop and no way to send a message. It does not change the job's state,
    /// so `status` still reports the truth.
    static let stuckAfter: TimeInterval =
        TimeInterval(AIChatViewModel.helperMaxMinutes * 60) + AIChatViewModel.helperWrapUpGraceSeconds + 300

    // BEGIN PerParentAdmission
    /// Child jobs running across every parent - diagnostics only; admission
    /// is per parent.
    var runningChildJobCount: Int {
        jobs.values.filter { $0.target.isChildOfCurrent && $0.state == .running }.count
    }

    /// [T-limits-per-parent] Child jobs running for one parent.
    func runningChildJobCount(parent parentSessionId: String) -> Int {
        jobs.values.filter { $0.target.parentSessionId == parentSessionId && $0.state == .running }.count
    }

    /// [T-limits-per-parent] Starts that have been admitted but are not
    /// `.running` yet, keyed by a caller token (the delegation's tool_use id,
    /// or `sched:<jobId>` for a scheduled fire) -> parent session id.
    ///
    /// Admission and `markRunning` are separated by awaits (creating the child
    /// session, loading it), so counting only `.running` jobs let a second
    /// start slip into a slot the first had already taken. A reservation holds
    /// the slot across that gap; it is released once the job is running (it is
    /// then counted twice for a moment, which only ever under-admits) or the
    /// start failed.
    private(set) var childStartReservations: [String: String] = [:]

    func reserveChildStart(key: String, parent parentSessionId: String) {
        childStartReservations[key] = parentSessionId
    }

    /// Release a reservation; a freed reservation may let a queued delegation
    /// start, so the queue is drained after it.
    func releaseChildStart(key: String) {
        guard childStartReservations.removeValue(forKey: key) != nil else { return }
        drainQueuedDelegations()
    }

    /// Free child slots of `parent`, not counting the reservation `key` holds
    /// (the caller's own, when it is the start that reservation was made for).
    func freeChildSlots(parent parentSessionId: String, excludingReservation key: String? = nil) -> Int {
        let reserved = childStartReservations.filter { $0.value == parentSessionId && $0.key != key }.count
        return Self.maxChildJobsPerParent - runningChildJobCount(parent: parentSessionId) - reserved
    }

    func canStartChildJob(parent parentSessionId: String, excludingReservation key: String? = nil) -> Bool {
        freeChildSlots(parent: parentSessionId, excludingReservation: key) > 0
    }
    // END PerParentAdmission

    // MARK: - Lifecycle

    /// The producer has started the run (loop launched in `sessionId`).
    func markRunning(_ jobId: String, sessionId: String?) {
        guard let job = jobs[jobId] else { return }
        job.markRunning(sessionId: sessionId)
        if let sid = sessionId { jobBySession[sid] = jobId }
        logger.info("[Jobs] RUNNING \(job.logLabel) session=\(sessionId?.prefix(8) ?? "nil") fired=\(job.firedCount)")
        jobsDidChange()
    }

    /// Close a job with its final state. Runs `then` for successful
    /// completions, fires any `.onCompletion(ofJobId:)` dependents, and drops
    /// the session mapping. Idempotent.
    func finish(_ jobId: String, state final: AgentJobState, result: String?,
                keepIfChildRunning: Bool = false) {
        guard let job = jobs[jobId], job.state == .running || job.state == .pending else { return }
        // A timer whose last fire spawned a child that is still running must
        // stay open: the child's loop end closes it (and runs `then`).
        if keepIfChildRunning, job.state == .running, let sid = job.runSessionId,
           ViewModelCache.shared.get(for: sid)?.isProcessing == true {
            logger.info("[Jobs] finish deferred — child \(sid.prefix(8)) still running for \(job.id.prefix(8))")
            return
        }
        // [T-sub-agents-steer] A steer the child never reached (it finished
        // first) has to be reported, not dropped: the parent was told "queued"
        // and would otherwise assume its correction was applied to this result.
        if let sid = job.runSessionId, let child = ViewModelCache.shared.get(for: sid),
           !child.pendingSteerMessages.isEmpty {
            let missed = child.pendingSteerMessages
            child.pendingSteerMessages.removeAll()
            job.missedSteers = missed
            logger.info("[Jobs] \(job.id.prefix(8)) finished with \(missed.count) unconsumed steer(s)")
        }
        // [T-perf-cpu-probe] One sample per run, at the single point every
        // outcome passes through (completed / failed / cancelled). Folded into
        // an in-memory bucket; PerfProbe emits one summary line per agent per
        // minute rather than a line per run.
        PerfProbe.subAgentEnd(job: job.id, agent: job.subAgentName,
                              outcome: final.rawValue, started: job.startedAt)
        job.markFinished(final, result: result)
        // [T-agent-model-identity] Last chance to read what the child really
        // ran on before the callback / completion hook serialise it.
        if let sid = job.runSessionId, let vm = ViewModelCache.shared.get(for: sid) {
            job.modelIdentity?.merge(vm.lastEffectiveModel)
        }
        if let sid = job.runSessionId { jobBySession[sid] = nil }
        JobInsuranceNotification.cancel(jobId: jobId)
        logger.info("[Jobs] FINISH \(job.logLabel) elapsed=\(Int(job.elapsed ?? 0))s result=\(result?.count ?? 0)ch")
        // [T-browser-agent-isolation] Give the agent's browser tabs back to
        // the shared pool the moment its job ends, whatever produced it
        // (delegate_task wait/background, minis-scheduled child-of-current).
        if job.target.isChildOfCurrent, let sid = job.runSessionId,
           let vm = ViewModelCache.shared.get(for: sid) {
            vm.browserTabPool.releaseTabs(owner: sid)
        }
        job.completionHook?(job)
        job.completionHook = nil
        // Every terminal state reports back — a parent that delegated in the
        // background must learn about a cancel / timeout / failure just as it
        // learns about success (the header carries `status`).
        runThen(for: job)
        // ONE notification per finish (the Android review caught the old
        // double post): `state` always, plus the ids of any `.onCompletion`
        // jobs this one arms, so an observer keyed on `object == jobId`
        // sees exactly one event.
        let dependents = jobs.values.filter { dep in
            guard dep.state == .pending, case .onCompletion(let of) = dep.trigger else { return false }
            return of == jobId
        }.map(\.id)
        if !dependents.isEmpty {
            logger.info("[Jobs] onCompletion dependents \(dependents.map { $0.prefix(8) }) armed by \(jobId.prefix(8)) — producer runs them")
        }
        NotificationCenter.default.post(name: .agentJobDidFinish, object: jobId,
                                        userInfo: ["state": final.rawValue, "dependentJobIds": dependents])
        // [T-sub-agents-queue] A slot just freed — start whatever was waiting.
        drainQueuedDelegations()
        // Terminal jobs stay listable until the parent is gone; a loop job
        // with fires left is re-armed by its producer, not here.
        jobsDidChange()
    }

    /// [T-sub-agents-queue] Start queued delegations while slots are free.
    ///
    /// Re-enters `executeDelegateTask` on the PARENT's view model with the
    /// original arguments, so a queued run is identical to one the model just
    /// made: same limits, same sub agent resolution, same block, and the same
    /// completion callback. `wait` is forced off — the tool call that queued it
    /// has long since returned, so there is nobody left to block.
    /// [T-sub-agents-queue] Periodic safety net for the drain.
    ///
    /// The queue normally moves on `finish()`, which every ending path calls.
    /// This exists for the case where one of them does not: a job killed
    /// off-path, a watcher that threw, anything that leaves a slot free with
    /// work still waiting. Without it the queue starves silently and forever,
    /// because nothing else ever re-checks. Cheap enough to call often — it
    /// returns immediately unless there is both a free slot and something
    /// queued.
    // BEGIN PerParentDrain
    func drainIfStalled() {
        guard queuedDelegations.contains(where: { canStartChildJob(parent: $0.parentSessionId) }) else { return }
        logger.warning("[Jobs] queue stalled with a free slot (\(self.queuedDelegations.count) waiting) — draining")
        drainQueuedDelegations()
    }

    /// [T-limits-per-parent] Start every queued delegation whose parent has a
    /// free slot, oldest first.
    ///
    /// The queue holds several parents' work, each with its own allowance, so
    /// this does not stop at the first item that cannot start: a parent that
    /// is full keeps only its OWN items waiting, while later items of other
    /// parents start (no head-of-line blocking). Each started item reserves its
    /// slot until it is running, so the same pass cannot over-admit one parent.
    func drainQueuedDelegations() {
        var remaining: [QueuedDelegation] = []
        var started: [(QueuedDelegation, AIChatViewModel)] = []
        for item in queuedDelegations {
            guard canStartChildJob(parent: item.parentSessionId) else {
                remaining.append(item)
                continue
            }
            // The parent's VM may be gone (session deleted while this waited);
            // whether the session row still exists is checked inside the Task,
            // since that lookup is actor-isolated.
            guard let parent = ViewModelCache.shared.get(for: item.parentSessionId) else {
                logger.warning("[Jobs] queued delegation dropped — parent \(item.parentSessionId.prefix(8)) is gone")
                continue
            }
            reserveChildStart(key: item.toolUseId, parent: item.parentSessionId)
            started.append((item, parent))
        }
        guard !started.isEmpty || remaining.count != queuedDelegations.count else { return }
        queuedDelegations = remaining
        for (item, parent) in started {
            var args = item.args
            args["wait"] = false
            logger.info("[Jobs] STARTING queued delegation tool=\(item.toolUseId.prefix(12)) parent=\(item.parentSessionId.prefix(8)) waited=\(Int(Date().timeIntervalSince(item.queuedAt)))s")
            Task { @MainActor in
                // The reservation is held until the start has either registered
                // its job as running or failed; then it is released (and the
                // queue drained again for whatever that frees).
                defer { self.releaseChildStart(key: item.toolUseId) }
                guard await ChatStore.shared.sessionExists(id: item.parentSessionId) else {
                    logger.warning("[Jobs] queued delegation dropped — session \(item.parentSessionId.prefix(8)) no longer exists")
                    return
                }
                _ = await parent.executeDelegateTaskQueued(args: args, toolUseId: item.toolUseId)
            }
        }
    }
    // END PerParentDrain

    /// Cancel one job (by id) — cancels its task and, for a running child
    /// session, the child's loop.
    /// - `silent`: skip the parent callback. Cancelling normally still reports
    ///   back, because a background delegation the model is waiting on must
    ///   learn it was cancelled. But when the USER pressed Stop, that callback
    ///   is the thing being stopped: it wakes the parent, which reads
    ///   "cancelled" as a failed sub-task and delegates it again — the user
    ///   watched three agents go grey and a fresh one start on its own, having
    ///   touched nothing. Stop means the conversation goes quiet.
    func cancel(jobId: String, reason: String, silent: Bool = false) {
        guard let job = jobs[jobId], job.state == .running || job.state == .pending else { return }
        logger.info("[Jobs] CANCEL \(job.logLabel) reason=\(reason)\(silent ? " (silent)" : "")")
        if job.state == .running, let sid = job.runSessionId,
           let vm = ViewModelCache.shared.get(for: sid), vm.isProcessing {
            vm.cancel()
        }
        // Drop the follow-up before finishing: `finish` runs `then`, so the
        // callback has to be gone by the time it does.
        if silent { job.then = AgentJobThen.none }
        finish(jobId, state: .cancelled, result: nil)
    }

    // MARK: - Scheduled jobs owned by a session

    /// [T-scheduled-session-ownership] Scheduled jobs created from `sessionId`
    /// that will still fire again.
    ///
    /// "Still live" is `state == .pending || .running`. A loop / cron job sits
    /// at `.pending` BETWEEN fires: the scheduled path reports each firing
    /// through `recordFire`, which bumps counters and never touches `state`
    /// (only `markRunning`, used by helper runs, moves it to `.running`).
    /// `finish` — the terminal transition — is called only when the count is
    /// exhausted, the cron window closes, or someone cancels. So a job that is
    /// merely waiting for its next fire is correctly still listed here.
    ///
    /// `.immediate` is excluded: it is a one-shot `run --id` that is either
    /// happening now or already over, and offering to "cancel a planned task"
    /// for it would be misleading.
    func liveScheduledJobs(createdBy sessionId: String) -> [AgentJob] {
        jobs.values.filter {
            $0.creatorSessionId == sessionId
                && $0.trigger != .immediate
                && ($0.state == .pending || $0.state == .running)
                && $0.isEnabled
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func hasLiveScheduledJobs(createdBy sessionId: String) -> Bool {
        !liveScheduledJobs(createdBy: sessionId).isEmpty
    }

    /// [T-scheduled-active-session] Conversations a scheduled job keeps ACTIVE
    /// between its fires: they are not finished, they are waiting to be woken.
    ///
    /// Only a job that comes back into the conversation it was created in
    /// counts — `--target follow-up` aimed at its own creator — because only
    /// then is "this chat is still working" true from the user's side. A job
    /// made outside any conversation, or one that lands in a new chat or a
    /// different one, makes no chat active. An `.onCompletion` job counts only
    /// while its upstream job still exists and is unfinished; otherwise it is
    /// waiting for something that will never happen.
    ///
    /// Fed to `SessionActivityTracker` by `jobsDidChange()`; everything that
    /// treats a conversation as active — background keep-alive, the composer's
    /// Stop button, the list spinner, the app badge — reads it from there.
    // BEGIN sessionsKeptActiveBySchedule
    /// The conversation `job` keeps active, or nil — THE rule, used for both
    /// the tracker's `scheduledSessions` and the chat banner's jobs
    /// ([T-scheduled-banner]), so the two can never disagree.
    func sessionKeptActive(by job: AgentJob) -> String? {
        guard job.isEnabled, job.state == .pending || job.state == .running,
              case .followUp(let sid) = job.target, job.creatorSessionId == sid else { return nil }
        switch job.trigger {
        case .immediate:
            return nil
        case .onCompletion(let upstreamId):
            guard let up = jobs[upstreamId], up.state == .pending || up.state == .running else { return nil }
        case .once, .loop, .cron:
            break
        }
        return sid
    }

    var sessionsKeptActiveBySchedule: Set<String> {
        Set(jobs.values.compactMap { sessionKeptActive(by: $0) })
    }
    // END sessionsKeptActiveBySchedule

    /// [T-scheduled-active-session] Push the job-derived active sessions to the
    /// tracker. Called after EVERY change that can move a job in or out of
    /// them — registration, arming (which runs after the creator is set),
    /// running, finishing / cancelling, enable / disable, removal, pruning,
    /// and the delegation queue — because a job is a class mutated in place:
    /// `$jobs` only publishes on insert / remove, so nothing downstream would
    /// otherwise see a timer end. Cheap (a pass over a small map); the tracker
    /// publishes only when a set actually changes.
    func jobsDidChange() {
        SessionActivityTracker.shared.setJobSessions(scheduled: sessionsKeptActiveBySchedule,
                                                     delegating: parentsWithActiveChildren)
        // [T-scheduled-banner] The chat's top banner shows the next of these.
        let byChat = activeScheduleJobIdsByChat
        if byChat != activeScheduleJobIdsBySession { activeScheduleJobIdsBySession = byChat }
    }

    /// [T-scheduled-banner] The jobs keeping each conversation active
    /// (`sessionKeptActive(by:)` — the very jobs behind `scheduledSessions`),
    /// grouped by that conversation. Published from `jobsDidChange()` only
    /// when the grouping changes, so the chat banner appears and disappears
    /// with them without polling; the banner reads each job's next fire time
    /// itself, once a second.
    @Published private(set) var activeScheduleJobIdsBySession: [String: Set<String>] = [:]

    private var activeScheduleJobIdsByChat: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for job in jobs.values {
            if let sid = sessionKeptActive(by: job) { out[sid, default: []].insert(job.id) }
        }
        return out
    }

    /// [T-scheduled-cancel-from-card] Is this specific job a timer that will
    /// still fire? Used by the callback card to decide whether to offer Cancel.
    func isLiveScheduled(jobId: String) -> Bool {
        guard let job = jobs[jobId] else { return false }
        return job.trigger != .immediate
            && (job.state == .pending || job.state == .running)
            && job.isEnabled
    }

    /// Cancel every still-live scheduled job this session created.
    ///
    /// Deliberately NOT silent: the user pressed Stop, so the model should see
    /// that its timer was cancelled rather than silently stop hearing from it
    /// (`silent` exists for the opposite case — tearing a job down without
    /// disturbing a conversation).
    /// `silent: true` is for tearing down a DELETED conversation: there is
    /// nobody left to tell, so no cancellation callback is delivered.
    @discardableResult
    func cancelScheduled(createdBy sessionId: String, reason: String, silent: Bool = false) -> Int {
        let live = liveScheduledJobs(createdBy: sessionId)
        for job in live { cancel(jobId: job.id, reason: reason, silent: silent) }
        if !live.isEmpty {
            logger.info("[Jobs] cancelled \(live.count) scheduled job(s) created by \(sessionId.prefix(8)): \(reason)")
        }
        return live.count
    }

    func cancel(label: String, reason: String) {
        for job in jobs.values where job.label == label { cancel(jobId: job.id, reason: reason) }
    }

    /// Cascade: the parent session stopped or was deleted.
    func cancelAll(parent parentSessionId: String, reason: String, silent: Bool = false) {
        for job in activeChildren(parent: parentSessionId) {
            cancel(jobId: job.id, reason: reason, silent: silent)
        }
    }

    /// [T-stop-sibling-subagent] Which sessions a card's Stop must reach.
    ///
    /// Pure and static so the fan-out rule is pinned without a registry, view
    /// models or a running loop. `children` is (childSessionId, parentSessionId)
    /// for every job currently running or pending.
    ///
    /// Returns every child of the same parent as `stopped` — including
    /// `stopped` itself — or just `stopped` when no job claims it (a run left
    /// over from a previous process: the registry is in-memory).
    static func siblingSessions(ofChild stopped: String,
                                children: [(child: String, parent: String)]) -> [String] {
        guard let parent = children.first(where: { $0.child == stopped })?.parent else {
            return [stopped]
        }
        return children.filter { $0.parent == parent }.map(\.child)
    }

    /// [T-stop-sibling-subagent] The parent session that `childSessionId` was
    /// delegated from, if a live job still knows about it.
    ///
    /// The card UI only holds the CHILD id, so without this it can cancel one
    /// agent but has no way to name the turn that agent belongs to.
    func parentSession(ofChild childSessionId: String) -> String? {
        for job in jobs.values where job.runSessionId == childSessionId {
            if let parent = job.target.parentSessionId { return parent }
        }
        return nil
    }

    /// [T-subagent-stop-from-own-page] The user's Stop on a sub agent, from
    /// its card in the parent OR its own page. Mute the parent turn first (a
    /// sibling already finishing delivers through the loop or the job
    /// callback, and both check the flag), then cancel the whole sibling set
    /// silently — see `cancelSiblings`. Returns how many jobs it stopped; 0
    /// means no live job backs this child (e.g. a run from an earlier process).
    ///
    /// The child's own page used to call the child's `cancel()` directly,
    /// which leaves the job's callback armed: the backstop observer finished
    /// the job as "cancelled" and woke the parent with it, and the parent
    /// could re-delegate the task the user had just stopped (field-reproduced
    /// on iPhone 11, 2026-09-26).
    @discardableResult
    func stopSubAgentByUser(childSessionId: String, reason: String) -> Int {
        if let parent = parentSession(ofChild: childSessionId),
           let parentVM = ViewModelCache.shared.get(for: parent) {
            parentVM.muteDelegationResults(reason: reason)
        }
        return cancelSiblings(ofChild: childSessionId, reason: reason)
    }

    /// [T-stop-sibling-subagent] Stop every sub agent of the turn that
    /// `childSessionId` belongs to, not just that one child.
    ///
    /// Pressing Stop on a card means "stop this", but when a turn fanned out
    /// into several agents, stopping one of them and leaving the siblings
    /// running is never what the user is asking for: the siblings keep
    /// reporting in and the parent keeps going, so the run the user just
    /// stopped visibly continues. Cancels the whole sibling set silently and
    /// drops anything still queued behind it.
    ///
    /// Returns the number of jobs cancelled — 0 means nothing in the registry
    /// owned that session (a run from a previous process), and the caller
    /// should fall back to stopping the child's loop directly.
    @discardableResult
    func cancelSiblings(ofChild childSessionId: String, reason: String) -> Int {
        // Build the (child, parent) view the rule works on, from the jobs that
        // are still live — a finished sibling has nothing left to cancel.
        let live: [(child: String, parent: String)] = jobs.values.compactMap { job in
            guard job.state == .running || job.state == .pending,
                  let child = job.runSessionId,
                  let parent = job.target.parentSessionId else { return nil }
            return (child: child, parent: parent)
        }
        let targets = Set(Self.siblingSessions(ofChild: childSessionId, children: live))
        guard let parent = parentSession(ofChild: childSessionId) else {
            // Not a delegation this registry owns (a run from a previous
            // process): stop the one session we were given, if a job has it.
            return cancelAll(session: childSessionId, reason: reason, silent: true) ? 1 : 0
        }
        logger.info("[Jobs] STOP SIBLINGS parent=\(parent.prefix(8)) via child=\(childSessionId.prefix(8)) targets=\(targets.count) — \(reason)")
        // Drop the backlog FIRST: cancelling a running job drains the queue,
        // which would start the very delegations the user just stopped.
        dropQueuedDelegations(parent: parent, reason: reason)
        var cancelled = 0
        // Snapshot before mutating: `cancel` calls `finish`, which mutates
        // `jobs` (and can drain the queue into it).
        for job in activeChildren(parent: parent) where targets.contains(job.runSessionId ?? "") {
            cancel(jobId: job.id, reason: reason, silent: true)
            cancelled += 1
        }
        return cancelled
    }

    /// The job whose child session IS `sessionId` (the session being
    /// deleted directly, e.g. a child row removed by an iCloud tombstone).
    /// Returns true if it found a job to cancel — the caller can then tell a
    /// registry-tracked run apart from a bare session with no job behind it.
    @discardableResult
    func cancelAll(session sessionId: String, reason: String, silent: Bool = false) -> Bool {
        var found = false
        for job in jobs.values where job.runSessionId == sessionId && (job.state == .running || job.state == .pending) {
            cancel(jobId: job.id, reason: reason, silent: silent)
            found = true
        }
        return found
    }

    /// Drop terminal jobs so the map does not grow without bound.
    func pruneFinished(olderThan age: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        for (id, job) in jobs where job.state != .running && job.state != .pending {
            if (job.finishedAt ?? job.createdAt) < cutoff { jobs[id] = nil }
        }
        jobsDidChange()
    }

    // MARK: - Loop end → job end

    private func sessionLoopDidEnd(_ sessionId: String) {
        guard let jobId = jobBySession[sessionId], let job = jobs[jobId], job.state == .running else { return }
        // The producer that awaits the run in-process (wait-mode helper)
        // finishes the job itself with the real status; this observer is the
        // backstop for background runs so a job never stays "running" after
        // its loop is gone.
        Task { @MainActor [weak self] in
            let text = await Self.lastAssistantText(sessionId: sessionId)
            guard let self, let job = self.jobs[jobId], job.state == .running else { return }
            let vm = ViewModelCache.shared.get(for: sessionId)
            let cancelled = vm?.userDidCancel ?? false
            // [T-subagent-timeout-reason] A helper the runner stopped for its
            // budget also has userDidCancel set (same cancel()). This observer
            // can run before the runner's own finish(.timeout), so it has to
            // name that ending itself or the job closes as `cancelled`.
            let state: AgentJobState = vm?.helperStoppedForTimeout == true ? .timeout
                : (cancelled ? .cancelled : .done)
            self.finish(jobId, state: state, result: text)
        }
    }

    /// Last assistant text from the DB — the flushed truth, not the vm's
    /// in-memory list (same reasoning as Android's HeadlessChatRunner).
    static func lastAssistantText(sessionId: String) async -> String? {
        let raws = await ChatStore.shared.loadMessages(sessionId: sessionId)
        func text(of raw: RawMessage) -> String {
            raw.parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let assistants = raws.filter { $0.role == .assistant }
        guard let last = assistants.last else { return nil }
        let final = text(of: last)
        if !final.isEmpty { return final }
        // [T-agent-wrapup-turn] The run ended on a tool call (cancelled,
        // crashed, cut off). Fall back to the last thing the agent actually
        // said, clearly labelled, rather than returning nothing.
        guard let earlier = assistants.dropLast().reversed().map(text(of:)).first(where: { !$0.isEmpty }) else { return nil }
        return noFinalAnswerLabel + "\n" + earlier
    }

    /// The label `lastAssistantText` puts in front of an earlier line when the
    /// run left no final answer. [T-subagent-termination] Recognised by
    /// `AIChatViewModel.isFinalAnswer`, so such a run is not reported as
    /// `completed` just because the fallback text is non-empty.
    nonisolated static let noFinalAnswerLabel =
        "(The agent did not write a final answer; this is its last message before the run ended.)"

    // MARK: - then

    private func runThen(for job: AgentJob) {
        switch job.then {
        case .none:
            // Wait mode: this job returns through its own tool result, so
            // there is nothing to deliver here.
            // [T-subagent-termination] A background run whose callback was
            // dropped by a silent cancel (the user stopped the parent's agents)
            // was recorded `pending` by its completion hook - it never will be
            // delivered, so say so instead of leaving it pending forever.
            if let sid = job.runSessionId,
               let t = SubAgentTerminationStore.shared.record(for: sid),
               t.jobId == job.id, t.delivery == .pending {
                SubAgentTerminationStore.shared.setDelivery(
                    sessionId: sid, .failed, detail: "withheld: the user stopped the parent's agents")
            }
            return
        case .followUpParent(let template):
            guard let parent = job.target.parentSessionId else { return }
            // [T-agent-wrapup-turn] Never hand the parent an empty result:
            // say what happened so it re-delegates instead of digging.
            // [T-subagent-termination] A delegate run's termination record (if
            // it has one) names WHY there is no answer and what the last tool
            // did; other jobs keep the generic note.
            let termination = job.runSessionId
                .flatMap { SubAgentTerminationStore.shared.record(for: $0) }
                .flatMap { $0.jobId == job.id ? $0 : nil }
            let childSid = termination?.sessionId
            let result: String = {
                let r = job.resultText ?? ""
                if let termination, termination.isTerminal {
                    return AIChatViewModel.helperResultText(r, termination: termination)
                }
                return r.isEmpty ? AIChatViewModel.emptyResultNote(status: job.state.rawValue) : r
            }()
            let text: String
            if let template, !template.isEmpty {
                text = template.replacingOccurrences(of: "{{result}}", with: result)
            } else {
                // [T-p3-agent-callback-cell] Fixed XML so the parent UI can
                // draw this as a callback cell rather than a user bubble.
                text = Self.completionCallback(for: job, result: result).xml
            }
            // [T-sub-agents-batch-callback] A completion is NEVER held back.
            //
            // An earlier cut parked results here until the last sibling of a
            // fan-out finished, to spend one parent turn on the batch instead
            // of one per agent. That throttle was on the wrong callback: with
            // three agents running and two queued, the first result to land
            // was withheld for the entire run, so the parent could not report
            // progress from it, could not adjust the remaining tasks, and
            // could not decide to let a queued delegation start early. The
            // whole fan-out became a black box until every last agent was in.
            //
            // Coalescing belongs to the STARTUP acknowledgements — several
            // delegations reporting "running"/"queued" in the same turn say
            // nothing individually — and those already arrive together,
            // because the concurrent tool dispatcher waits for every tool call
            // in a turn before returning (tool_result order must mirror
            // tool_use order). A result, a progress report and a completion
            // each carry something the parent needs now, so each one wakes it.
            let payload = text
            Task { @MainActor in
                // [T-child-delete-storage] A parent deleted while its agent
                // ran must not be resurrected by the callback: getOrCreate
                // would mint a fresh VM and the prompt would persist rows
                // under an id that no longer exists.
                guard await ChatStore.shared.sessionExists(id: parent) else {
                    logger.warning("[Jobs] then.followUpParent \(job.id.prefix(8)) dropped — parent \(parent.prefix(8)) no longer exists")
                    if let childSid {
                        SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .failed, detail: "parent session no longer exists")
                    }
                    return
                }
                let (vm, fresh) = ViewModelCache.shared.getOrCreate(for: parent)
                if fresh { await vm.loadSession() }
                // [T-stop-sibling-subagent] The stop may have landed while this
                // sibling was already finishing. `cancel(silent:)` drops the
                // callback of the job it cancels, but a job that closes on its
                // own a moment later still holds a live `then`, and delivering
                // it here restarts the very conversation the user stopped.
                // Checked at delivery time, not at finish time: this hop is
                // asynchronous, so the stop can arrive in between.
                guard !vm.delegationResultsAreMuted else {
                    logger.info("[Jobs] then.followUpParent \(job.id.prefix(8)) dropped — parent \(parent.prefix(8)) was stopped by the user")
                    if let childSid {
                        SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .failed, detail: "parent was stopped by the user")
                    }
                    return
                }
                let outcome = vm.submitProgrammaticPrompt(payload, origin: .job(jobId: job.id), silent: true)
                if let childSid {
                    switch outcome {
                    case .sent: SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .delivered)
                    case .queued: SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .queued,
                                                                             detail: "waiting behind the parent's running turn")
                    case .rejected(let reason): SubAgentTerminationStore.shared.setDelivery(sessionId: childSid, .failed, detail: reason)
                    }
                }
                logger.info("[Jobs] then.followUpParent \(job.id.prefix(8)) → parent \(parent.prefix(8)) outcome=\(String(describing: outcome))")
            }
        }
    }

    /// [T-sub-agents-sibling-status] One sentence about the OTHER sub agents of
    /// `parentSessionId`, or nil when this one is alone.
    ///
    /// Interrupted runs are counted from the parent's TRANSCRIPT, not from this
    /// registry: the registry is in-memory, so a kill leaves no job behind —
    /// which is exactly the case the parent model most needs told about, since
    /// nothing else will ever mention those runs again.
    static func siblingSummary(parentSessionId: String, excluding jobId: String) -> String? {
        var running = 0, queued = 0
        for j in AgentJobRegistry.shared.jobs.values
        where j.id != jobId && j.target.parentSessionId == parentSessionId {
            switch j.state {
            case .running: running += 1
            case .pending: queued += 1
            default: break
            }
        }
        queued += AgentJobRegistry.shared.queuedCount(parent: parentSessionId)

        var interrupted = 0
        if let vm = ViewModelCache.shared.get(for: parentSessionId) {
            for msg in vm.messages {
                for b in msg.blocks {
                    guard case .delegateTool = b.kind else { continue }
                    // A block still holding a "running" payload while no job
                    // backs it is one the app lost.
                    guard let obj = AIChatViewModel.parseDelegateResult(b.content),
                          (obj["status"] as? String) == "running",
                          let child = obj["child_session_id"] as? String else { continue }
                    let alive = AgentJobRegistry.shared.jobs.values.contains {
                        $0.runSessionId == child && ($0.state == .running || $0.state == .pending)
                    }
                    if !alive { interrupted += 1 }
                }
            }
        }

        var parts: [String] = []
        if running > 0 { parts.append("\(running) still running") }
        if queued > 0 { parts.append("\(queued) queued") }
        if interrupted > 0 {
            parts.append("\(interrupted) interrupted (the app was restarted; resume with action=resume, or leave them)")
        }
        guard !parts.isEmpty else { return nil }
        return "Other sub agents in this conversation: " + parts.joined(separator: ", ") + "."
    }

    static func completionCallback(for job: AgentJob, result: String) -> AgentCallback {
        AgentCallback(kind: .finished,
                      jobId: job.id,
                      childSessionId: job.runSessionId,
                      title: job.title,
                      status: job.state.rawValue,
                      tier: job.modelOrigin,
                      elapsed: Self.elapsedClock(job.elapsed),
                      tool: nil, activity: nil, turn: nil,
                      summary: job.summaryLine.flatMap { $0.hasPrefix("Summary: ") ? String($0.dropFirst(9)) : $0 },
                      body: result,
                      siblings: job.target.parentSessionId.flatMap {
                          siblingSummary(parentSessionId: $0, excluding: job.id)
                      },
                      modelIdentity: job.modelIdentity,
                      agent: job.subAgentName)
    }

    static func elapsedClock(_ e: TimeInterval?) -> String? {
        guard let e else { return nil }
        let s = Int(e)
        return s >= 60 ? "\(s / 60)m\(String(format: "%02d", s % 60))s" : "\(s)s"
    }

}

extension AgentJobRegistry {
    /// [T-agent-terminology] The one place that spells the child-session
    /// title prefix. delegate_task and `minis-scheduled --target
    /// child-of-current` both go through here so the session list never
    /// shows two different words for the same thing, and the prefix is the
    /// localized "Agent" noun (代理任务 / エージェント …), not a bare English
    /// literal.
    /// [T-sub-agents-v1] `subAgentName` is omitted for the built-in definition,
    /// so an ordinary delegation keeps exactly the title format it had.
    nonisolated static func childSessionTitle(_ title: String, subAgentName: String? = nil) -> String {
        if let name = subAgentName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(AppLocalized("Agent")) · \(name) · \(title)"
        }
        return "\(AppLocalized("Agent")) · \(title)"
    }

    /// Strip the (current-locale or legacy) prefix back off a stored title.
    nonisolated static func stripChildSessionTitlePrefix(_ title: String) -> String {
        var t = title
        for prefix in ["\(AppLocalized("Agent")) · ", "Agent · ", "Helper · "] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        return t
    }
}

extension Notification.Name {
    /// Posted ONCE by `AgentJobRegistry.finish`. `object` is the job id;
    /// `userInfo["state"]` the final state and `userInfo["dependentJobIds"]`
    /// the `[String]` of `.onCompletion` jobs it armed (empty when none).
    static let agentJobDidFinish = Notification.Name("agentJobDidFinish")
}

private let logger = AppLogger(category: "AgentJobRegistry")
