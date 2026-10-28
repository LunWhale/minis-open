import Foundation
import UserNotifications
import UIKit

private let logger = AppLogger(category: "ScheduledJobRunner")

// [T-p2-minis-scheduled] The execution half of component B: arms a job's
// trigger (once / loop / cron / on-completion / immediate) as an in-process
// Task and, when it fires, lands the job's prompt on its target through
// component A (`submitProgrammaticPrompt`).
//
// Everything here is best effort within the process lifetime (design v4
// §8.3 / §12): iOS has no AlarmManager, so a timer dies with the app. The
// insurance notification (§3 of the schedule design) is the only thing that
// survives a kill, and it is honest about that — it never claims a result.

@MainActor
enum ScheduledJobRunner {

    static let sourceTag = "scheduled"

    // MARK: - Arm

    /// Arm (or re-arm) the job's trigger. Cancels any previous timer task.
    /// `firstFireAt` replaces the first fire of a loop / cron job — only
    /// `skipNext` passes it, to re-arm past the run being skipped.
    /// `runNowSlot` ([T-sched-run-now]) is set only by `runNow`, which has
    /// already claimed the fire: the pending run planned for that slot fires
    /// at once through this same timer loop, and the schedule then continues
    /// exactly as after a timer fire.
    static func arm(_ job: AgentJob, firstFireAt: Date? = nil, runNowSlot: Date? = nil) {
        let preclaimed = runNowSlot != nil
        job.task?.cancel()
        job.task = nil
        guard job.isEnabled, job.state == .pending else {
            logger.info("[Sched] not arming \(job.logLabel) enabled=\(job.isEnabled)")
            if preclaimed { job.fireInFlight = false }
            return
        }
        switch job.trigger {
        case .immediate:
            job.nextFireAt = Date()
            job.task = Task { @MainActor in await fire(job) ; finishIfExhausted(job) }

        case .once(let after):
            let at = preclaimed ? Date() : Date().addingTimeInterval(after)
            job.nextFireAt = at
            scheduleInsurance(job, at: at)
            job.task = Task { @MainActor in
                guard await sleepUntil(at) else {
                    if preclaimed { job.fireInFlight = false }
                    return
                }
                await fire(job, claimed: preclaimed)
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
            }

        case .loop(let interval, _):
            let first = preclaimed ? Date() : (firstFireAt ?? Date().addingTimeInterval(interval))
            job.nextFireAt = first
            scheduleInsurance(job, at: first)
            job.task = Task { @MainActor in
                var next = first
                var claimed = preclaimed
                while !Task.isCancelled {
                    guard await sleepUntil(next) else {
                        if claimed { job.fireInFlight = false }
                        return
                    }
                    await fire(job, claimed: claimed)
                    claimed = false
                    // Re-armed while firing (skipNext): the new task owns the schedule.
                    if Task.isCancelled { return }
                    if let r = job.remaining, r <= 0 {
                        AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
                        return
                    }
                    next = Date().addingTimeInterval(interval)
                    job.nextFireAt = next
                    scheduleInsurance(job, at: next)
                }
            }

        case .cron(let hour, let minute, let days, let start, let end):
            guard let first = preclaimed ? Date() : (firstFireAt
                    ?? nextCronDate(hour: hour, minute: minute, days: days, start: start, end: end, from: Date())) else {
                logger.info("[Sched] cron has no future fire (window ended) — finishing \(job.id.prefix(8))")
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil)
                return
            }
            job.nextFireAt = first
            scheduleInsurance(job, at: first)
            job.task = Task { @MainActor in
                var next = first
                // The slot this fire consumes: the fire time itself, except
                // for "Run now", which fires a later slot early.
                var slot = runNowSlot ?? first
                var claimed = preclaimed
                while !Task.isCancelled {
                    guard await sleepUntil(next) else {
                        if claimed { job.fireInFlight = false }
                        return
                    }
                    job.firingSlot = slot
                    await fire(job, claimed: claimed)
                    claimed = false
                    if Task.isCancelled { return }
                    guard let n = nextCronDate(hour: hour, minute: minute, days: days, start: start, end: end,
                                               from: ScheduledFireClaim.cronSearchStart(now: Date(), consumedSlot: slot)) else {
                        AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
                        return
                    }
                    next = n
                    slot = n
                    job.nextFireAt = n
                    scheduleInsurance(job, at: n)
                }
            }

        case .onCompletion(let ofJobId):
            job.nextFireAt = nil
            job.task = Task { @MainActor in
                let seq = NotificationCenter.default.notifications(named: .agentJobDidFinish)
                for await note in seq {
                    if Task.isCancelled { return }
                    if (note.object as? String) == ofJobId { break }
                }
                await fire(job, upstreamJobId: ofJobId)
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
            }
        }
        logger.info("[Sched] ARMED \(job.logLabel) next=\(job.nextFireAt.map { Self.iso($0) } ?? "event")")
        // [T-scheduled-active-session] The creator session is set just before
        // arming, so this is the first point the job can count as keeping its
        // conversation active.
        AgentJobRegistry.shared.jobsDidChange()
    }

    /// [T-sched-pill-menu] "Skip next run" from the chat's timer pill: drop
    /// the job's next fire and re-arm at the one after it. A loop counts the
    /// skipped run against `--count` (the schedule still ends when planned);
    /// a job with no later run — once, on-completion, the last of a loop, a
    /// cron whose window closes — is cancelled, exactly as Stop cancels it.
    static func skipNext(_ job: AgentJob) {
        // `.pending` is where a follow-up loop / cron sits between fires (and
        // while one runs); `arm` refuses anything else.
        guard job.isEnabled, job.state == .pending else { return }
        let following: (Date) -> Date? = switch job.trigger {
        case .loop(let interval, _):
            { $0.addingTimeInterval(interval) }
        case .cron(let hour, let minute, let days, let start, let end):
            { nextCronDate(hour: hour, minute: minute, days: days, start: start, end: end,
                           from: $0.addingTimeInterval(60)) }
        case .once, .onCompletion, .immediate:
            { _ in nil }
        }
        switch ScheduledBannerModel.skipPlan(next: job.nextFireAt, remaining: job.remaining, following: following) {
        case .cancel:
            logger.info("[Sched] SKIP \(job.logLabel): no later run — cancelling")
            AgentJobRegistry.shared.cancel(jobId: job.id, reason: "user skipped its last run")
        case .rearm(let at, let remaining):
            logger.info("[Sched] SKIP \(job.logLabel): next run \(iso(at)) remaining=\(remaining.map(String.init) ?? "-")")
            job.remaining = remaining
            job.skippedCount += 1
            arm(job, firstFireAt: at)
        }
    }

    // MARK: - Run now  [T-sched-run-now]

    /// The single pending -> firing transition. The armed timer (at the top of
    /// `fire`) and "Run now" both take it; the whole runner is main-actor, so
    /// this check-and-set cannot interleave with another one.
    static func claimFire(_ job: AgentJob) -> Bool {
        ScheduledFireClaim.claim(&job.fireInFlight)
    }

    /// The facts "Run now" is decided on, read live from the job.
    static func runNowFacts(_ job: AgentJob) -> ScheduledFireClaim.Facts {
        let kind: ScheduledFireClaim.Kind = switch job.trigger {
        case .once: .once
        case .loop: .loop
        case .cron: .cron
        case .onCompletion: .onCompletion
        case .immediate: .immediate
        }
        return ScheduledFireClaim.Facts(
            isEnabled: job.isEnabled,
            isPending: job.state == .pending,
            fireInFlight: job.fireInFlight,
            isRunningOrQueued: ScheduledTaskDetailStore.isProcessingNow(job) || isQueuedNow(job),
            hasTimedNextFire: job.nextFireAt != nil,
            kind: kind)
    }

    /// Whether the pill may offer "Run now" for `job` at this moment.
    static func canRunNow(_ job: AgentJob) -> Bool {
        ScheduledFireClaim.canRunNow(runNowFacts(job))
    }

    /// "Run now" from the chat's timer pill: fire the run the pill is counting
    /// down to, immediately, through the armed timer's own loop (no separate
    /// execution path). The decision is re-made here from the live job, not
    /// from what the menu showed, and the claim is taken before anything else:
    /// a timer that fires in the meantime, a second tap, or a run that started
    /// while the menu was open all make this a silent no-op.
    /// `expectedRun` is the run the menu was showing (`runsDone` when it
    /// opened): if that run has since fired or been skipped, the tap is for a
    /// run that no longer waits, and it does nothing rather than firing the
    /// one after it.
    /// Returns whether the run was started.
    @discardableResult
    static func runNow(_ job: AgentJob, expectedRun: Int? = nil) -> Bool {
        guard ScheduledFireClaim.isSameRun(expected: expectedRun, current: runsDone(job)),
              canRunNow(job), let slot = job.nextFireAt, claimFire(job) else {
            logger.info("[Sched] RUN NOW \(job.logLabel) refused — run already started, queued, or nothing to run")
            return false
        }
        logger.info("[Sched] RUN NOW \(job.logLabel) slot=\(iso(slot))")
        arm(job, runNowSlot: slot)
        return true
    }

    /// Runs already fired or skipped - the pill's `runsDone`, which names the
    /// run it counts down to.
    static func runsDone(_ job: AgentJob) -> Int { job.firedCount + job.skippedCount }

    /// A fire of `job` waiting in its session's prompt queue (the session was
    /// busy when it fired): it has started as far as the user is concerned.
    static func isQueuedNow(_ job: AgentJob) -> Bool {
        var sessions: [String] = []
        if case .followUp(let sid) = job.target { sessions.append(sid) }
        if let sid = job.runSessionId { sessions.append(sid) }
        return sessions.contains { sid in
            ViewModelCache.shared.get(for: sid)?.promptQueue.contains { queued in
                AgentCallback.parse(queued.text).map { $0.kind == .scheduled && $0.jobId == job.id } ?? false
            } ?? false
        }
    }

    /// `run --id`: fire regardless of the trigger, off-schedule. The armed
    /// timer (if any) keeps its own cadence. [T-sched-run-now] It takes the
    /// same claim, so it reports `fired: false` while another fire of the job
    /// is still in progress instead of firing it twice at once.
    static func fireNow(_ job: AgentJob) async -> [String: Any] {
        // [T-limits-per-parent] A child-of-current job whose parent has no free
        // sub agent slot would hold the CLI call until one frees, possibly for
        // minutes. Fire it in the background instead; it starts as soon as the
        // parent has a slot (`waitForChildSlot`).
        if case .childOfCurrent(let parent, _) = job.target,
           !AgentJobRegistry.shared.canStartChildJob(parent: parent) {
            Task { @MainActor in await fire(job) }
            return ["fired": false, "deferred": true, "session_id": NSNull()]
        }
        let sid = await fire(job)
        return ["fired": sid != nil, "session_id": sid ?? NSNull()]
    }

    /// [T-limits-per-parent] Poll interval while a scheduled child waits for a
    /// sub agent slot of its parent.
    static let childSlotPollSeconds: UInt64 = 2

    /// [T-limits-per-parent] Wait until `parent` has a free sub agent slot.
    ///
    /// A scheduled child-of-current run is a sub agent of `parent` and counts
    /// against the same per-parent allowance as a delegation. It used to start
    /// without checking, so a timer could push a parent past its cap and make
    /// every delegation of that conversation queue behind it. Now it waits.
    /// False when the wait was abandoned: the job's task was cancelled, or the
    /// job was stopped / finished meanwhile.
    private static func waitForChildSlot(parent: String, job: AgentJob) async -> Bool {
        let registry = AgentJobRegistry.shared
        var waited = false
        while !registry.canStartChildJob(parent: parent) {
            if !waited {
                logger.info("[Sched] FIRE \(job.logLabel) deferred — parent \(parent.prefix(8)) has \(AgentJobRegistry.maxChildJobsPerParent) sub agents running")
                waited = true
            }
            do { try await Task.sleep(nanoseconds: childSlotPollSeconds * 1_000_000_000) } catch { return false }
            guard !Task.isCancelled, job.state == .pending || job.state == .running else { return false }
        }
        if waited { logger.info("[Sched] FIRE \(job.logLabel) — parent \(parent.prefix(8)) has a free sub agent slot, starting") }
        return true
    }

    // MARK: - Fire

    /// Land the prompt on the target. Returns the session the prompt went to.
    ///
    /// [T-sched-run-now] Starts with the claim (`claimFire`), unless the
    /// caller already holds it (`claimed`, "Run now"); a fire whose claim is
    /// refused does nothing - another fire of this job is in progress. The
    /// claim is released when this returns.
    @discardableResult
    private static func fire(_ job: AgentJob, upstreamJobId: String? = nil, claimed: Bool = false) async -> String? {
        if !claimed {
            guard claimFire(job) else {
                logger.info("[Sched] FIRE \(job.logLabel) skipped — another fire of this job is in progress")
                return nil
            }
        }
        defer { job.fireInFlight = false }
        let registry = AgentJobRegistry.shared
        var prompt = job.prompt ?? ""
        if let up = upstreamJobId, let upstream = registry.job(id: up) {
            prompt = prompt.replacingOccurrences(of: "{{result}}", with: upstream.resultText ?? "")
        }
        // [T-scheduled-task-card] Wrap the injected turn in the callback
        // envelope so the UI renders it as a card instead of a right-aligned
        // user bubble — it is the scheduler firing, not something the user
        // typed. `scheduledEnvelope` keeps `roundPrefix`'s line inside the
        // body verbatim, so what the MODEL reads is unchanged.
        let text = scheduledEnvelope(job, prompt: prompt)
        cancelInsurance(job)

        switch job.target {
        case .new:
            guard let entry = resolveModel(for: job) else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): no model to run on")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            let session = await ChatStore.shared.createSession(modelId: entry.model.id,
                                                               title: job.label.map { "Scheduled · \($0)" },
                                                               source: sourceTag)
            if let override = job.modelEntryId, ProviderConfigStore.shared.entry(for: override) != nil {
                ProviderConfigStore.shared.setBinding(
                    SessionModelBinding(sessionId: session.id, primarySource: .directEntry(modelEntryId: override)),
                    for: session.id)
            }
            applyThinkingLevel(job, sessionId: session.id, entry: entry)
            let (vm, _) = ViewModelCache.shared.getOrCreate(for: session.id)
            await vm.loadSession()
            vm.sessionSource = sourceTag
            let outcome = vm.submitProgrammaticPrompt(text, origin: .job(jobId: job.id), silent: true,
                                                     presetToolCall: presetFor(job))
            logger.info("[Sched] FIRE \(job.logLabel) → new session \(session.id.prefix(8)) outcome=\(String(describing: outcome))")
            if case .rejected = outcome { registry.recordFire(job.id, sessionId: session.id, ok: false) }
            else { registry.recordFire(job.id, sessionId: session.id, ok: true) }
            return session.id

        case .followUp(let sid):
            guard await ChatStore.shared.getSession(sid) != nil else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): follow-up session \(sid.prefix(8)) is gone — abort")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            let (vm, fresh) = ViewModelCache.shared.getOrCreate(for: sid)
            if fresh || vm.messages.isEmpty { await vm.loadSession() }
            applyThinkingLevel(job, sessionId: sid, entry: vm.resolveCurrentEntry())
            let outcome = vm.submitProgrammaticPrompt(text, origin: .job(jobId: job.id), silent: true,
                                                     presetToolCall: presetFor(job))
            logger.info("[Sched] FIRE \(job.logLabel) → follow-up \(sid.prefix(8)) outcome=\(String(describing: outcome))")
            if case .rejected = outcome { registry.recordFire(job.id, sessionId: sid, ok: false) }
            else { registry.recordFire(job.id, sessionId: sid, ok: true) }
            return sid

        case .rerun(let sid, let messageId):
            // The sessions bridge blocks its caller with a semaphore and
            // hops to the main actor inside — never call it from here directly.
            let ok: Bool = await Task.detached {
                let dict = SessionsOffloadBridge.retryMessage(sessionId: sid, messageId: messageId, attachmentPaths: [])
                return (dict["ok"] as? Bool) ?? false
            }.value
            logger.info("[Sched] FIRE \(job.logLabel) → rerun \(sid.prefix(8))/\(messageId.prefix(8)) ok=\(ok)")
            registry.recordFire(job.id, sessionId: sid, ok: ok)
            return ok ? sid : nil

        case .childOfCurrent(let parentSid, _):
            // [T-agents-debug-only] Defence in depth behind the CLI check:
            // a job armed while Agents was on must not spawn a helper after
            // the switch went off (or in a Release build, where it is
            // always off). Recorded as a failed fire; no child is created.
            guard AgentToolSwitch.agents.isEnabled else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): child-of-current refused — Sub Agents are off (Settings › Sub Agents)")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            // [T-limits-per-parent] Same per-parent cap as a delegation: wait for
            // a free slot, then hold it (reservation) across the awaits below
            // until the job is running.
            guard await waitForChildSlot(parent: parentSid, job: job) else {
                logger.info("[Sched] fire \(job.id.prefix(8)): abandoned while waiting for a sub agent slot")
                return nil
            }
            let slotReservation = "sched:\(job.id)"
            registry.reserveChildStart(key: slotReservation, parent: parentSid)
            defer { registry.releaseChildStart(key: slotReservation) }
            let (parentVM, parentFresh) = ViewModelCache.shared.getOrCreate(for: parentSid)
            if parentFresh { await parentVM.loadSession() }
            guard let resolution = SubAgentModelResolver.resolve(subAgent: nil, parent: parentVM) else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): parent has no model")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            let title = job.label ?? job.title
            let session = await ChatStore.shared.createSession(modelId: resolution.entry.model.id,
                                                               title: AgentJobRegistry.childSessionTitle(title),
                                                               source: sourceTag,
                                                               parentSessionId: parentSid,
                                                               parentToolUseId: nil)
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: session.id, primarySource: resolution.source), for: session.id)
            applyThinkingLevel(job, sessionId: session.id, entry: resolution.entry)
            // [T-limits-per-parent] Child pool, like a delegated sub agent: a
            // scheduled child used to land in the user's conversation pool.
            let (child, _) = ViewModelCache.shared.getOrCreate(for: session.id, kind: .child)
            await child.loadSession()
            child.sessionSource = sourceTag
            child.helperConfig = HelperConfig(parentSessionId: parentSid, parentToolUseId: "",
                                              jobId: job.id, maxTurns: AIChatViewModel.helperMaxTurns,
                                              title: title, modelOrigin: resolution.origin)
            child.memoryEnabled = false
            child.suppressGeneralCompletionNotification = true
            child.browserTabPool = parentVM.browserTabPool
            job.modelOrigin = resolution.origin.rawValue
            // [T-agent-model-identity] A scheduled child has no parent block;
            // the job carries its identity so the completion callback and
            // the transcript page still say what it ran on.
            job.modelIdentity = HelperModelIdentity.make(resolution: resolution)
            let outcome = child.submitProgrammaticPrompt(text, origin: .job(jobId: job.id), silent: true,
                                                     presetToolCall: presetFor(job))
            logger.info("[Sched] FIRE \(job.logLabel) → child \(session.id.prefix(8)) of \(parentSid.prefix(8)) outcome=\(String(describing: outcome))")
            guard outcome == .sent else {
                registry.recordFire(job.id, sessionId: session.id, ok: false)
                return nil
            }
            // The registry's loop-end observer closes the job and runs
            // `then: .followUpParent`; the insurance notification covers a
            // kill in between (design §8.6).
            registry.markRunning(job.id, sessionId: session.id)
            registry.releaseChildStart(key: slotReservation)   // counted as running now
            JobInsuranceNotification.schedule(
                jobId: job.id,
                at: Date().addingTimeInterval(TimeInterval(AIChatViewModel.helperMaxMinutes * 60)),
                title: AppLocalized("Minis agent"),
                body: String(format: AppLocalized("The agent \"%@\" may have finished or been interrupted. Open to check."), title),
                userInfo: ["sessionId": parentSid, "childSessionId": session.id, "helperJobId": job.id])
            return session.id
        }
    }

    /// [T-scheduled-preset-tool] The job's preset tool call, paired with the
    /// title its card shows. nil for jobs without `--command` / `--tool`.
    private static func presetFor(_ job: AgentJob) -> ScheduledPresetToolCallRequest? {
        guard let preset = job.presetToolCall else { return nil }
        return ScheduledPresetToolCallRequest(jobId: job.id, call: preset, title: job.label ?? job.title)
    }

    private static func finishIfExhausted(_ job: AgentJob) {
        if job.state == .pending {
            AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
        }
    }

    // MARK: - Pieces

    /// Structured prefix (schedule design §1.5): the model must know which
    /// fire this is, and how many remain, to decide when to wrap up.
    /// [T-scheduled-task-card] The scheduled firing wrapped as an
    /// `<agent_callback kind="scheduled">` envelope.
    ///
    /// The body is EXACTLY what used to be submitted — `roundPrefix(job) +
    /// prompt` — so the model's input is byte-identical to before this change.
    /// That is deliberate: the prompt instructs the model to decide from the
    /// remaining count whether to start wrapping up, and quietly relocating
    /// that fact into an XML attribute it may not attend to would be a
    /// behaviour change disguised as a display change. The attributes exist
    /// only so the card can show fire/remaining without re-parsing prose.
    /// [T-scheduled-banner] The job as a scheduled-task callback, so the chat
    /// banner opens the SAME task page a fired card opens
    /// (`ScheduledTaskDetailView`, via `.openAgentCallback`) — for a job that
    /// may not have fired yet and so has no card. The page reads the live job
    /// by id; these fields are only its fallback.
    static func detailCallback(for job: AgentJob) -> AgentCallback {
        AgentCallback(kind: .scheduled, jobId: job.id, childSessionId: nil,
                      title: job.label ?? job.title, status: "running",
                      tier: nil, elapsed: nil, tool: nil, activity: nil, turn: nil,
                      summary: nil, body: job.prompt ?? "",
                      fireIndex: job.firedCount, remaining: job.remaining,
                      triggerLabel: job.trigger.logLabel,
                      nextFireAt: job.nextFireAt.map { iso($0) })
    }

    static func scheduledEnvelope(_ job: AgentJob, prompt: String) -> String {
        var fireIndex: Int?
        var remaining: Int?
        switch job.trigger {
        case .loop, .cron:
            fireIndex = job.firedCount + 1
            remaining = job.remaining.map { max(0, $0 - 1) }
        default:
            break
        }
        // [T-scheduled-next-fire] When this job will fire AGAIN, so the card can
        // say the task is still planned rather than leaving the user to assume
        // the card's appearance meant it finished.
        //
        // Computed here, not read from `job.nextFireAt`: the envelope is built
        // BEFORE `fire()` runs, so that field still holds the fire happening
        // right now. `arm`'s own scheduling maths is mirrored rather than
        // shared because arm computes the next date only AFTER the fire
        // completes, which is too late to put in this envelope.
        //
        // nil means "no more" — the card then says the task is done instead of
        // promising a fire that will never come.
        let nextFire: Date? = {
            switch job.trigger {
            case .loop(let interval, _):
                // `remaining` is decremented by recordFire during this very
                // firing, so the value here is what will be left afterwards.
                if let r = job.remaining, r - 1 <= 0 { return nil }
                return Date().addingTimeInterval(interval)
            case .cron(let h, let m, let days, let start, let end):
                return nextCronDate(hour: h, minute: m, days: days, start: start, end: end,
                                    from: ScheduledFireClaim.cronSearchStart(now: Date(),
                                                                             consumedSlot: job.firingSlot ?? Date()))
            case .once, .immediate, .onCompletion:
                return nil
            }
        }()
        let callback = AgentCallback(
            kind: .scheduled,
            jobId: job.id,
            childSessionId: nil,
            title: job.label ?? job.title,
            // Not a lifecycle state — this envelope reports one firing that is
            // happening now, and `running` is what the card's neutral styling
            // and `localizedStatus` already key off.
            status: "running",
            tier: nil, elapsed: nil, tool: nil, activity: nil, turn: nil,
            summary: nil,
            // [T-scheduled-preset-tool] The note line exists only for a job
            // with a preset, so every other job's body stays byte-identical.
            body: roundPrefix(job) + (job.presetToolCall?.envelopeNote ?? "") + prompt,
            fireIndex: fireIndex,
            remaining: remaining,
            triggerLabel: job.trigger.logLabel,
            nextFireAt: nextFire.map { iso($0) }
        )
        return callback.xml
    }

    static func roundPrefix(_ job: AgentJob) -> String {
        let name = job.label ?? job.title
        switch job.trigger {
        case .loop, .cron:
            let fire = job.firedCount + 1
            let remaining = job.remaining.map { " · remaining \($0 - 1 < 0 ? 0 : $0 - 1)" } ?? ""
            return "[Scheduled task \"\(name)\" · fire \(fire)\(remaining) · \(job.trigger.logLabel)]\n"
        case .onCompletion(let of):
            return "[Scheduled task \"\(name)\" · triggered by completion of job \(of.prefix(8))]\n"
        case .once, .immediate:
            return "[Scheduled task \"\(name)\"]\n"
        }
    }

    /// [T-scheduled-thinking-level] Apply the job's `--thinking` override to
    /// the session it is about to fire into.
    ///
    /// nil means "leave it alone", which is what every pre-existing job has:
    /// a `.followUp` keeps the conversation's own level, and a `.new` session
    /// keeps whatever its group default gave it. Only an explicit flag writes.
    ///
    /// Clamped to the entry's `effectiveMaxThinkingLevel` for the same reason
    /// the send path clamps ([T-fallback-thinking-preclamp]): asking a model
    /// for a level above its ceiling is a 400, and a scheduled job would repeat
    /// that failure on every fire with nobody watching.
    static func applyThinkingLevel(_ job: AgentJob, sessionId: String, entry: ModelEntry?) {
        guard let requested = job.thinkingLevel else { return }
        let store = ProviderConfigStore.shared
        let level = entry.map { min(requested, $0.effectiveMaxThinkingLevel) } ?? requested
        var cfg = store.inferenceConfig(for: sessionId) ?? SessionInferenceConfig()
        guard cfg.thinkingLevel != level else { return }
        cfg.thinkingLevel = level
        store.setInferenceConfig(cfg, for: sessionId)
        logger.info("[Sched] \(job.id.prefix(8)) thinking=\(level.rawValue) on \(sessionId.prefix(8))")
    }

    private static func resolveModel(for job: AgentJob) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        if let override = job.modelEntryId, let e = store.entry(for: override) { return e }
        if let gid = store.defaultPrimaryGroupId, let group = store.group(for: gid),
           let id = ModelGroupRouter.resolve(group: group, sessionId: job.id, store: store),
           let e = store.entry(for: id) { return e }
        return store.resolvedAgentLoopEntries.first
    }

    /// Sleep until `date`. Returns false when cancelled.
    /// [T-scheduled-suspend-drift] Sleep in bounded steps, re-reading the
    /// WALL CLOCK each time, instead of one `Task.sleep` for the whole delta.
    ///
    /// A single sleep is measured in process-execution time: when iOS suspends
    /// the app the countdown stops with it, so a job due in 60s that spent 10
    /// minutes backgrounded fired 10 minutes LATE on resume rather than
    /// immediately. `Date()` keeps running across suspension, so re-deriving
    /// the remaining interval every step means a wake-up finds the deadline
    /// already passed and fires at once. Same wall-clock-over-sleep-relative
    /// reasoning as the compaction watchdog (T-ios-compact-no-timeout) and
    /// BrowserTabPool.
    ///
    /// This does NOT make firing reliable while suspended — nothing can; see
    /// the header note. It only removes the drift for the common case where
    /// the process survived and simply was not scheduled for a while.
    private static let sleepStep: TimeInterval = 30

    private static func sleepUntil(_ date: Date) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return !Task.isCancelled }
            let chunk = min(remaining, sleepStep)
            do { try await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000)) }
            catch { return false }
        }
    }

    /// Next occurrence of HH:MM on one of `days` (Calendar weekday numbers,
    /// 1 = Sunday), inside the optional [start, end] window.
    nonisolated static func nextCronDate(hour: Int, minute: Int, days: Set<Int>, start: Date?, end: Date?, from: Date) -> Date? {
        let cal = Calendar.current
        let allowed = days.isEmpty ? Set(1...7) : days
        let base = max(from, start ?? from)
        for offset in 0..<(7 * 53) {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base)) else { continue }
            guard allowed.contains(cal.component(.weekday, from: day)) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard let candidate = cal.date(from: comps) else { continue }
            if candidate <= base { continue }
            if let end, candidate > end { return nil }
            return candidate
        }
        return nil
    }

    /// "30m" / "2h" / "90s" / "1d" / bare seconds.
    nonisolated static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let unit = t.last!
        let numPart = "0123456789.".contains(unit) ? t : String(t.dropLast())
        // [T-scheduled-duration-finite] Double() also accepts "inf", "nan" and
        // "1e20": converting such a value to Int (a timeout) traps and kills
        // the app, and an infinite interval reaches Date / notification
        // triggers. Reject non-finite input and anything past ten years.
        guard let n = Double(numPart), n.isFinite, n >= 0 else { return nil }
        let seconds: Double
        switch unit {
        case "s": seconds = n
        case "m": seconds = n * 60
        case "h": seconds = n * 3600
        case "d": seconds = n * 86400
        default:
            guard "0123456789.".contains(unit) else { return nil }
            seconds = n
        }
        guard seconds.isFinite, seconds <= maxDurationSeconds else { return nil }
        return seconds
    }

    /// Longest duration `parseDuration` accepts (ten years).
    nonisolated static let maxDurationSeconds: TimeInterval = 10 * 365 * 86400

    nonisolated static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    // MARK: - Insurance

    private static func scheduleInsurance(_ job: AgentJob, at date: Date) {
        let name = job.label ?? job.title
        JobInsuranceNotification.schedule(
            jobId: job.id, at: date.addingTimeInterval(5),
            title: AppLocalized("Minis scheduled task"),
            body: String(format: AppLocalized("\"%@\" is due. Open Minis to see whether it ran."), name),
            userInfo: job.target.parentSessionId.map { ["sessionId": $0] }
                ?? job.target.sessionIdForNavigation.map { ["sessionId": $0] } ?? [:])
    }

    private static func cancelInsurance(_ job: AgentJob) {
        JobInsuranceNotification.cancel(jobId: job.id)
    }
}

// MARK: - Insurance notification (schedule design §3)

/// A local notification registered when a job is armed and withdrawn the
/// moment the app itself handles the fire. If the process is killed first,
/// the notification is the only thing left standing — its text therefore
/// states only what is known (the task was due) and never a result.
enum JobInsuranceNotification {
    static func identifier(_ jobId: String) -> String { "job-\(jobId)" }

    static func schedule(jobId: String, at date: Date, title: String, body: String, userInfo: [String: String]) {
        guard UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "backgroundNotificationsEnabled") else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = ShortcutNotification.categoryId
        content.userInfo = userInfo
        let interval = max(1, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: identifier(jobId), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        // Replace any earlier registration for the same job (loop re-arms).
        center.removePendingNotificationRequests(withIdentifiers: [identifier(jobId)])
        center.add(request)
    }

    /// Both queues: a notification that already fired (app was backgrounded
    /// past the deadline) is only removable from the delivered list.
    static func cancel(jobId: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(jobId)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(jobId)])
    }
}

extension AgentJobTarget {
    /// The session a notification tap should open for this target.
    var sessionIdForNavigation: String? {
        switch self {
        case .new: return nil
        case .followUp(let sid): return sid
        case .rerun(let sid, _): return sid
        case .childOfCurrent(let parent, _): return parent
        }
    }
}

// BEGIN ScheduledFireClaim
/// [T-sched-run-now] Pure rules behind the pill's "Run now" and the one claim
/// every fire of a scheduled job takes. Foundation-only:
/// MinisTests/Standalone/ScheduledRunNowTests.swift compiles this block.
enum ScheduledFireClaim {
    enum Kind: Equatable { case once, loop, cron, onCompletion, immediate }

    /// What "Run now" is decided on, read live from the job.
    struct Facts: Equatable {
        var isEnabled: Bool
        /// Still scheduled (not finished / cancelled).
        var isPending: Bool
        /// A fire has been claimed and has not returned.
        var fireInFlight: Bool
        /// A run of this job is in progress in its chat, or waiting in the
        /// chat's prompt queue.
        var isRunningOrQueued: Bool
        /// The job is counting down to a known time.
        var hasTimedNextFire: Bool
        var kind: Kind
    }

    /// The pending -> firing claim: true exactly once until it is released
    /// (the flag is cleared when the fire returns).
    static func claim(_ inFlight: inout Bool) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    /// "Run now" exists only while the pill counts down to a timed run that
    /// has not started: a one-shot, a loop or a cron. Not for an
    /// on-completion job (it waits on another job's result) or an immediate
    /// one (it is already firing).
    static func canRunNow(_ f: Facts) -> Bool {
        guard f.isEnabled, f.isPending, !f.fireInFlight, !f.isRunningOrQueued, f.hasTimedNextFire else {
            return false
        }
        switch f.kind {
        case .once, .loop, .cron: return true
        case .onCompletion, .immediate: return false
        }
    }

    /// The tap is for the run the menu showed: none fired or skipped since.
    /// nil (no expectation, e.g. a caller without a menu) always matches.
    static func isSameRun(expected: Int?, current: Int) -> Bool {
        expected.map { $0 == current } ?? true
    }

    /// Where to search for a cron job's next run after a fire. A timer fire
    /// happens at its slot, so this is a minute after now, as it always was;
    /// "Run now" fires a slot early, and searching from now would plan that
    /// same slot again.
    static func cronSearchStart(now: Date, consumedSlot: Date) -> Date {
        max(now, consumedSlot).addingTimeInterval(60)
    }
}
// END ScheduledFireClaim
