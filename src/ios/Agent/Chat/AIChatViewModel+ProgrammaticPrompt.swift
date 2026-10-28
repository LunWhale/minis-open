import Combine
import Foundation

private let logger = AppLogger(category: "ProgrammaticPrompt")

// [T-p0-programmatic-prompt] Component A of the sub-agent / scheduled-task
// design (docs: subagent_design_v4 §8.1): the ONE channel through which
// anything that is not the user's own tap — the sessions CLI, a Shortcut, a
// scheduled job firing, a helper reporting back — injects a prompt into a
// session.
//
// Why a dedicated entry point instead of `vm.inputText = …; vm.send()`:
//
//  1. `send()` silently returns while `isProcessing` is true, and
//     `enqueuePrompt()` silently returns while it is false. A caller that reads
//     `isProcessing` and then picks one of them races the loop's own
//     epilogue: the classic check-then-act window in which the prompt
//     evaporates. Doing the check and the hand-off in one synchronous
//     @MainActor step (no `await` in between) closes that window.
//  2. The queue's only consumers are loop epilogues. A prompt that lands in
//     the queue after the epilogue's drain already returned (there are DB
//     awaits between that drain and `isProcessing = false`) has no consumer.
//     `startDrainIfIdle` — called from the isProcessing didSet and defensively
//     here — is the rescue.
//  3. Callers get the truth back (`.sent` / `.queued` / `.rejected`) instead of
//     an unconditional "ok".
//  4. `silent` suppresses the tap + completion haptics for a turn nobody tapped.

/// Who is injecting the prompt. Recorded for logs; P2's job machinery will
/// key completion hooks and notification identifiers off it.
enum ProgrammaticPromptOrigin: Equatable {
    /// `minis-sessions-cli send` from inside the sandbox.
    case cli
    /// An App Intent (Shortcuts / Siri).
    case shortcut
    /// An `AgentJobRegistry` job (scheduled trigger, helper completion, …).
    case job(jobId: String)
    /// [T-user-ask-deferred] The user's answer to a deferred user_ask card,
    /// sent as their next message. The user is there: with the app in the
    /// foreground the run that answers it can ask again normally.
    case userAskAnswer

    var logLabel: String {
        switch self {
        case .cli: return "cli"
        case .shortcut: return "shortcut"
        case .job(let id): return "job:\(id.prefix(8))"
        case .userAskAnswer: return "user_ask_answer"
        }
    }
}

/// Truthful outcome of `submitProgrammaticPrompt`.
enum ProgrammaticSubmitOutcome: Equatable {
    /// No loop was running; a new turn started immediately.
    case sent
    /// A loop was running; the prompt is in `promptQueue` and will run as a
    /// fresh turn when that loop ends (or via the idle-drain rescue).
    case queued
    /// The vm declined it. `reason` is a stable snake_case token for callers
    /// that surface it to a script or a Shortcut result.
    case rejected(reason: String)
}

extension AIChatViewModel {

    /// Inject `text` (plus any attachments already staged on `attachments`)
    /// into this session as a user turn, atomically choosing between starting
    /// a loop and queueing behind the running one.
    ///
    /// Must be called on the main actor and must not be preceded by an
    /// `await` that read `isProcessing` — the whole point is that the check
    /// and the hand-off happen in the same synchronous step.
    ///
    /// - Parameters:
    ///   - text: the prompt. Trimmed; an empty prompt with no ready
    ///     attachment is rejected rather than silently dropped.
    ///   - origin: who is asking (logs only in P0).
    ///   - silent: suppress the send/enqueue haptic and, for a `.sent` turn,
    ///     the completion haptic. A `.queued` prompt drains inside the user's
    ///     own loop, whose completion haptic is theirs and is kept.
    ///   - presetToolCall: [T-scheduled-preset-tool] a scheduled fire's preset
    ///     first step. Kept on the vm until the request that answers this
    ///     fire's envelope, which it then replaces (see `takePresetToolStream`).
    ///   - bypassContextPrompt: [T-user-ask-deferred-delivery] start the turn
    ///     even when the context is near capacity, instead of parking the text
    ///     behind the "Context Near Capacity" alert. A parked programmatic
    ///     prompt is dropped when that alert is cancelled (or never seen and
    ///     cleared by the next loadSession). The agent loop's in-loop guard
    ///     compacts on its own, so nothing is lost by skipping the alert.
    @MainActor
    @discardableResult
    func submitProgrammaticPrompt(_ text: String,
                                  origin: ProgrammaticPromptOrigin,
                                  silent: Bool = true,
                                  presetToolCall: ScheduledPresetToolCallRequest? = nil,
                                  bypassContextPrompt: Bool = false) -> ProgrammaticSubmitOutcome {
        let tag = "📨[Programmatic] origin=\(origin.logLabel) vm=\(vmInstanceId) sid=\(sessionId?.prefix(8) ?? "nil")"

        guard remoteDeviceId == nil else {
            logger.warning("\(tag) REJECTED — read-only remote session")
            return .rejected(reason: "read_only_remote_session")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // send() prunes non-ready attachments before its own guard, so a
        // pure-attachment prompt whose files never loaded would pass a naive
        // check here and still vanish inside send(). Mirror that pruning.
        let readyAttachments = attachments.filter { $0.loadState == .ready }
        guard !trimmed.isEmpty || !readyAttachments.isEmpty else {
            logger.warning("\(tag) REJECTED — empty prompt and no ready attachment (staged=\(self.attachments.count))")
            return .rejected(reason: attachments.isEmpty ? "empty_prompt" : "attachments_not_ready")
        }
        if isCompacting {
            // compactAndSend has its own queue + post-compact drain; a foreign
            // prompt landing mid-compaction would be rolled back or double
            // drained. Refuse rather than guess.
            logger.warning("\(tag) REJECTED — session is compacting")
            return .rejected(reason: "session_compacting")
        }

        // [T-programmatic-prompt-no-composer] The prompt travels as an
        // argument, NOT through `inputText`.
        //
        // This used to be `inputText = text`, which made the composer — a
        // two-way binding to whatever the user is typing right now — the
        // transport for a prompt nobody typed. Any background turn landing
        // mid-sentence (a helper reporting back, a scheduled job firing, the
        // CLI) overwrote the draft and then send()/enqueuePrompt() cleared it
        // to "", destroying it with no way back. Android never had this: its
        // headless path carries the text in a local and leaves `_inputText`
        // to the composer.
        //
        // Restoring the draft afterwards would not do: `inputText` is
        // @Published with a didSet that drives the slash and mention menus and
        // resets `voiceUsedInComposition`, so a write/restore pair would
        // shut an open mention popup and disturb the caret mid-typing.
        //
        // `attachments` stays shared on purpose — the CLI and the Shortcut
        // intent both stage files onto it before calling (see
        // SessionsOffloadBridge.stageAttachments / SendPromptIntent), and the
        // doc comment above promises they are included.

        // Registered before the hand-off: once send()/enqueuePrompt() accept
        // the prompt, the turn that carries it may be requested at any later
        // main-actor hop. Matching is by the envelope's job id, so it does not
        // matter which path (send, drain, finish-branch injection) runs it.
        // A rejection below restores what was there before (an earlier fire of
        // the same job may still be queued with its own preset).
        let displacedPreset = presetToolCall.flatMap { pendingPresetToolCalls[$0.jobId] }
        func undoPresetRegistration() {
            guard let preset = presetToolCall else { return }
            pendingPresetToolCalls[preset.jobId] = displacedPreset
        }
        if let preset = presetToolCall {
            pendingPresetToolCalls[preset.jobId] = preset
            logger.info("\(tag) preset \(preset.call.toolName) armed for job \(preset.jobId.prefix(8))")
        }

        if isProcessing {
            // Busy: hand to the queue.
            let before = promptQueue.count
            // A job result is delivered gently: it never interrupts the
            // running plan, it waits for the loop to converge (fix: the
            // device run 15:53 showed a helper result abandoning the parent's
            // remaining plan at the next tool boundary).
            let gentle: Bool = { if case .job = origin { return true } else { return false } }()
            enqueuePrompt(silent: silent, deferUntilIdle: gentle, overrideText: text)
            guard promptQueue.count == before + 1 else {
                logger.warning("\(tag) REJECTED — enqueuePrompt did not accept the prompt (queue \(before) → \(self.promptQueue.count))")
                undoPresetRegistration()
                return .rejected(reason: "enqueue_declined")
            }
            if silent, let queuedId = promptQueue.last?.id {
                silentQueuedPromptIds.insert(queuedId)
            }
            logger.info("\(tag) QUEUED — position \(self.promptQueue.count), loop still running")
            // Defensive: if the loop flipped idle in the same runloop turn
            // (it cannot have, we hold the main actor, but the guard is free).
            startDrainIfIdle(reason: "programmatic-enqueue")
            return .queued
        }

        // Idle: start a loop. send() flips isProcessing synchronously before
        // it spawns its Task, so the flip is the acceptance signal — every
        // other exit from send() is a silent return.
        programmaticSilentTurn = silent
        programmaticTurnOrigin = origin  // [T-user-ask] no one to ask in this run
        // [T-loop-reminder-scheduled-exempt] A scheduled fire starting a turn
        // on an idle session: its poll is an expected repeat, not a loop. (A
        // queued fire is exempted where it is taken off the queue instead.)
        if Self.scheduledCallback(inQueuedText: text) != nil {
            toolLoopDetector.exemptNextCallForScheduledFire()
        }
        if bypassContextPrompt { skipCompactCheck = true }
        send(overrideText: text)
        // send() consumes the flag at its context check; an earlier return
        // must not leave it armed for the user's next message.
        if bypassContextPrompt { skipCompactCheck = false }
        guard isProcessing else {
            programmaticSilentTurn = false
            programmaticTurnOrigin = nil
            let reason = showContextExhaustedPrompt ? "context_exhausted" : "send_declined"
            logger.warning("\(tag) REJECTED — send() did not start a loop (\(reason))")
            undoPresetRegistration()
            return .rejected(reason: reason)
        }
        logger.info("\(tag) SENT — new loop started silent=\(silent)")
        return .sent
    }
}

// MARK: - Preset first step of a scheduled fire  [T-scheduled-preset-tool]

extension AIChatViewModel {

    /// The local response that replaces a model request when the turn about to
    /// be requested is a scheduled fire with a preset tool call: the preset's
    /// tool_use, then `stop_reason: tool_use`. nil otherwise — the caller then
    /// asks the provider as usual.
    ///
    /// Fed to `processStreamEvents` like a provider stream, so the tool card,
    /// the committed assistant tool_use, the real execution and the
    /// tool_result are exactly what a model-issued call produces.
    ///
    /// A preset runs only when its own envelope is in the trailing user
    /// messages (see `ScheduledPresetToolCall.jobIdsToRun`), and is consumed on
    /// use. A preset whose tool this turn does not offer is dropped, and the
    /// turn runs as a plain scheduled prompt: a tool_use for an undeclared tool
    /// is rejected by some providers.
    /// [T-preset-cleared-on-stop] Drop presets whose scheduled fire the user
    /// just stopped.
    ///
    /// A preset is consumed only when its turn is requested. A fire stopped
    /// before that (waiting for a concurrency slot, or before its first
    /// request) left the preset armed while its envelope stayed in history as
    /// a trailing user message — so the user's NEXT typed turn matched it and
    /// ran the stopped task's shell command instead of answering. Fires still
    /// waiting in `promptQueue` keep theirs: Stop drains the queue afterwards,
    /// and their envelope promises the model the step's output.
    @MainActor
    func dropPresetsOfStoppedTurn() {
        guard !pendingPresetToolCalls.isEmpty else { return }
        let stillQueued = Set(promptQueue.compactMap { item -> String? in
            guard let callback = AgentCallback.parse(item.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  callback.kind == .scheduled else { return nil }
            return callback.jobId
        })
        let stopped = pendingPresetToolCalls.keys.filter { !stillQueued.contains($0) }
        for jobId in stopped { pendingPresetToolCalls.removeValue(forKey: jobId) }
        if !stopped.isEmpty {
            logger.info("[PresetTool] Stop dropped \(stopped.count) armed preset(s) of the stopped turn (\(stillQueued.count) queued fire(s) keep theirs)")
        }
    }

    @MainActor
    func takePresetToolStream(tools: [AgentToolDefinition]) -> AsyncThrowingStream<AgentStreamEvent, Error>? {
        guard !pendingPresetToolCalls.isEmpty else { return nil }
        var trailing: [String] = []
        for message in agentHistory.reversed() {
            guard message.role == .user else { break }
            for part in message.parts.reversed() {
                if case .text(let t) = part { trailing.append(t) }
            }
        }
        let jobIds = ScheduledPresetToolCall.jobIdsToRun(
            trailingUserTexts: trailing.reversed(),
            pending: Set(pendingPresetToolCalls.keys)
        ) { text in
            guard let callback = AgentCallback.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  callback.kind == .scheduled else { return nil }
            return callback.jobId
        }
        guard !jobIds.isEmpty else { return nil }

        var calls: [(id: String, name: String, args: [String: Any])] = []
        for jobId in jobIds {
            guard let request = pendingPresetToolCalls.removeValue(forKey: jobId) else { continue }
            let name = request.call.toolName
            guard tools.contains(where: { $0.name == name }) else {
                logger.warning("[PresetTool] job \(jobId.prefix(8)): \(name) is not offered this turn — skipped, the model decides")
                continue
            }
            let id = ScheduledPresetToolCall.makeToolUseId()
            calls.append((id, name, request.call.toolArguments(title: request.title)))
            logger.info("[PresetTool] job \(jobId.prefix(8)): running \(name) id=\(id) in place of a model request sid=\(self.sessionId?.prefix(8) ?? "nil")")
        }
        guard !calls.isEmpty else { return nil }
        return AsyncThrowingStream { continuation in
            for call in calls {
                continuation.yield(.contentBlockStart(.toolUse(id: call.id, name: call.name)))
                continuation.yield(.toolCallComplete(id: call.id, name: call.name, args: call.args, metadata: nil))
            }
            continuation.yield(.done(stopReason: .toolUse))
            continuation.finish()
        }
    }
}

// MARK: - Waiting for a programmatic turn  [T-shortcut-wait-queued-turn]

extension AIChatViewModel {

    /// The id of the prompt `submitProgrammaticPrompt` just queued, or nil when
    /// the outcome was not `.queued`. Read it IMMEDIATELY after the submit, on
    /// the main actor, before anything else can touch the queue.
    func lastQueuedProgrammaticPromptId(for outcome: ProgrammaticSubmitOutcome) -> UUID? {
        guard outcome == .queued else { return nil }
        return promptQueue.last?.id
    }

    /// Suspends until the turn carrying a programmatic prompt has finished.
    ///
    /// Callers used to do `for await p in $isProcessing.values { if !p { break } }`
    /// directly. That is right for `.sent` — send() flips isProcessing before it
    /// returns, so the first value the publisher replays is `true` — but wrong for
    /// `.queued`: the session was busy with an EARLIER turn, and the first `false`
    /// is that turn ending, before the queued prompt has even started. A "Wait for
    /// Result" Shortcut then returned the previous answer as if it were its own.
    ///
    /// Completion is therefore defined as: the queued prompt (if any) has left
    /// `promptQueue` (the drain took it) AND `isProcessing` is false. Both are
    /// watched together so a flip in either re-evaluates the pair, and the
    /// current values are replayed on subscription, so a turn that already
    /// finished resolves immediately rather than waiting for a change that will
    /// never come.
    ///
    /// Returns `false` if the task was cancelled before the turn finished
    /// (Shortcuts cancels perform() when its own time limit expires or the user
    /// stops the run); the caller decides what partial result to hand back.
    @discardableResult
    func awaitProgrammaticTurn(queuedPromptId: UUID?) async -> Bool {
        let states = Publishers.CombineLatest($isProcessing, $promptQueue)
            .map { processing, queue -> ProgrammaticTurnState in
                let stillQueued = queuedPromptId.map { id in queue.contains { $0.id == id } } ?? false
                return ProgrammaticTurnState(processing: processing, stillQueued: stillQueued)
            }
            .values
        return await Self.awaitTurnCompletion(in: states)
    }

    /// The pure part of `awaitProgrammaticTurn`, over any state sequence, so the
    /// completion rule is unit-testable without a view model.
    nonisolated static func awaitTurnCompletion<S: AsyncSequence>(in states: S) async -> Bool
    where S.Element == ProgrammaticTurnState {
        do {
            for try await state in states {
                if Task.isCancelled { return false }
                if state.isFinished { return true }
            }
        } catch {
            return false
        }
        // The sequence ended without a finished state: the publisher completed
        // (vm deallocated) or the task was cancelled mid-await.
        return false
    }
}

/// One observation of the pair `awaitTurnCompletion` decides on.
struct ProgrammaticTurnState: Equatable, Sendable {
    let processing: Bool
    /// Only meaningful for a `.queued` submit: true while the drain has not yet
    /// picked the prompt up. Always false for `.sent`.
    let stillQueued: Bool

    /// Finished = nothing left to run for this prompt AND the loop is idle.
    var isFinished: Bool { !processing && !stillQueued }
}

// MARK: - Which queued prompts a delivery point takes  [T-scheduled-preempt]
//
// A scheduled fire that lands while its session is busy used to wait for the
// whole running turn to converge, and every prompt queued meanwhile was then
// folded into ONE user message — three fires of a 1-minute loop arrived as a
// single turn after a 4-minute task (device run 2026-09-27). Now:
//
//  * a scheduled fire enters at the next TOOL GAP (this batch's tool_results
//    are committed and the model wants to continue), as its own user turn
//    behind a bridge, with a reminder that it was inserted and that the task
//    in progress must be finished afterwards;
//  * at most one job per gap; several fires of the same job that piled up are
//    coalesced into the newest one, and the reminder says how many;
//  * a user's own follow-up keeps its existing interrupt, but no longer drags
//    queued scheduled fires along;
//  * at the end of a turn (or when the session is idle) each scheduled job's
//    fire is still its own turn instead of being merged with the others.
//
// Sub-agent callbacks (finished / progress) are NOT scheduled fires: they keep
// waiting for the end of the turn ([T-p2-gentle-job-injection]).

/// Where the running loop is when it looks at `promptQueue`.
enum QueueDeliveryPoint: Equatable {
    /// Between two tool steps: the batch's tool_results are committed and the
    /// model asked to continue (stop reason tool_use).
    case toolGap
    /// The turn converged (a reply without tool calls), or the session is idle.
    case turnEnd
}

/// What one delivery takes out of `promptQueue`.
struct QueueTake: Equatable {
    /// Delivered, in queue order, together as ONE user turn.
    let deliver: [UUID]
    /// Taken out WITHOUT being delivered: older fires of the same scheduled
    /// job, superseded by the newest one in `deliver`.
    let coalesced: [UUID]
    /// Set when this take is one scheduled job's fire.
    let scheduledJobId: String?
}

/// The pure rule behind every delivery point, so it is unit-testable.
enum QueueDeliveryPlanner {
    struct Item: Equatable {
        let id: UUID
        /// The user's own follow-up (or a CLI / Shortcut prompt): interrupts
        /// the running plan at the next tool boundary.
        let interruptsAtToolGap: Bool
        /// The job id when the prompt is a scheduled fire's envelope.
        let scheduledJobId: String?
    }

    static func take(_ items: [Item], at point: QueueDeliveryPoint) -> QueueTake? {
        guard !items.isEmpty else { return nil }
        func scheduledTake(_ jobId: String) -> QueueTake {
            let fires = items.filter { $0.scheduledJobId == jobId }
            return QueueTake(deliver: fires.suffix(1).map(\.id),
                             coalesced: fires.dropLast().map(\.id),
                             scheduledJobId: jobId)
        }
        switch point {
        case .toolGap:
            // The user's follow-up first, exactly as before — but only theirs.
            let typed = items.filter(\.interruptsAtToolGap)
            if !typed.isEmpty {
                return QueueTake(deliver: typed.map(\.id), coalesced: [], scheduledJobId: nil)
            }
            // Then the scheduled job that has waited longest. Other jobs wait
            // for the next gap; sub-agent callbacks wait for the turn to end.
            if let jobId = items.first(where: { $0.scheduledJobId != nil })?.scheduledJobId {
                return scheduledTake(jobId)
            }
            return nil
        case .turnEnd:
            if let jobId = items[0].scheduledJobId { return scheduledTake(jobId) }
            // Everything else still arrives together, as it always has; the
            // scheduled fires behind it get their own turns afterwards.
            let rest = items.filter { $0.scheduledJobId == nil }
            return QueueTake(deliver: rest.map(\.id), coalesced: [], scheduledJobId: nil)
        }
    }
}

/// The model-facing text added after an inserted scheduled fire's envelope.
/// Wrapped in <system-reminder>, so the chat (which strips reminders from user
/// rows) keeps showing just the fire's card.
enum ScheduledInsertText {
    /// For a fire inserted between two tool steps of a running task.
    static func midTaskReminder(title: String, hasPreset: Bool, coalescedCount: Int) -> String {
        var s = "<system-reminder>Scheduled task \"\(title)\" fired and was inserted here — not your last tool result, not a user request."
        if hasPreset {
            s += " Preset command already ran; read the result below, don't re-run it."
        }
        if coalescedCount > 0 {
            s += " It also fired \(coalescedCount) more time\(coalescedCount == 1 ? "" : "s") while busy; only this latest is shown."
        }
        // [T-bridge-to-reminder] Also carries what the old assistant bridge
        // row said, now that no bridge precedes the fire.
        s += " Handle briefly, then resume your unfinished prior task.</system-reminder>"
        return s
    }

    /// For a fire delivered at the end of a turn (or to an idle session) after
    /// earlier fires of the same job piled up. nil when nothing was coalesced.
    static func coalescedNote(title: String, coalescedCount: Int) -> String? {
        guard coalescedCount > 0 else { return nil }
        return "<system-reminder>Scheduled task \"\(title)\" also fired \(coalescedCount) more time\(coalescedCount == 1 ? "" : "s") while busy; only the latest is shown above.</system-reminder>"
    }
}

extension AIChatViewModel {

    /// [T-queued-callback-reminder] Candidates for `QueuedCallbackReminder`
    /// from the live queue.
    @MainActor
    func queuedCallbackReminderCandidates() -> [QueuedCallbackReminder.Candidate] {
        promptQueue.map { prompt in
            let callback = AgentCallback.parse(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines))
            return QueuedCallbackReminder.Candidate(
                promptId: prompt.id,
                callbackKind: callback?.kind.rawValue,
                jobId: callback?.jobId ?? "",
                title: callback?.title ?? "",
                status: callback?.status ?? "",
                deferUntilIdle: prompt.deferUntilIdle,
                reminderSent: prompt.reminderSent)
        }
    }

    /// [T-queued-callback-reminder] Marks the listed queued callbacks as
    /// reminded. Called only once the request carrying the reminder has been
    /// dispatched, so a request that fails before that re-lists the same jobs
    /// (same text) on its retry. A prompt already taken out of the queue
    /// meanwhile is simply not found. In memory only.
    @MainActor
    func markQueuedCallbacksReminded(_ promptIds: [UUID]) {
        guard !promptIds.isEmpty else { return }
        let ids = Set(promptIds)
        for i in promptQueue.indices where ids.contains(promptQueue[i].id) {
            promptQueue[i].reminderSent = true
        }
    }

    /// [T-queued-callback-reminder] `history` (an outbound request copy) with
    /// `reminder` appended to the tail of its last message, or nil when that
    /// message cannot carry it.
    ///
    /// Same placement as the empty-response nudges
    /// (`historyWithEmptyToolResultReminder` /
    /// `historyWithEmptyCallbackReminder`): inside the last tool result's
    /// content when the tail is a tool_result turn — so the tool_result block
    /// structure, and what `mergeConsecutiveSameRole` later merges, stay
    /// exactly as they were — otherwise onto the last text part of a user
    /// message. Never written to `agentHistory` or `messages`.
    static func historyAppendingRequestReminder(_ reminder: String,
                                                to history: [AgentMessage]) -> [AgentMessage]? {
        guard let lastIdx = history.indices.last, history[lastIdx].role == .user else { return nil }
        var parts = history[lastIdx].parts
        let suffix = "\n\n" + reminder
        if let partIdx = parts.indices.last(where: {
            if case .toolResult = parts[$0] { return true }; return false
        }), case let .toolResult(id, name, content, isError, imageData, imageMimeType, pageURL, imageLinuxPath, isReadback) = parts[partIdx] {
            parts[partIdx] = .toolResult(
                id: id, name: name, content: content + suffix, isError: isError,
                imageData: imageData, imageMimeType: imageMimeType,
                pageURL: pageURL, imageLinuxPath: imageLinuxPath,
                isOffloadReadback: isReadback)
        } else if let partIdx = parts.indices.last(where: {
            if case .text = parts[$0] { return true }; return false
        }), case let .text(existing) = parts[partIdx] {
            parts[partIdx] = .text(existing + suffix)
        } else {
            return nil
        }
        var out = history
        out[lastIdx] = AgentMessage(
            role: history[lastIdx].role,
            parts: parts,
            isInterrupted: history[lastIdx].isInterrupted,
            reasoningContent: history[lastIdx].reasoningContent,
            reasoningEcho: history[lastIdx].reasoningEcho,
            dbMessageId: history[lastIdx].dbMessageId)
        return out
    }

    /// The scheduled fire a queued prompt carries, if it is one.
    static func scheduledCallback(inQueuedText text: String) -> AgentCallback? {
        guard let callback = AgentCallback.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              callback.kind == .scheduled else { return nil }
        return callback
    }

    /// `QueueDeliveryPlanner.take` over the live queue.
    @MainActor
    func planQueueTake(at point: QueueDeliveryPoint) -> QueueTake? {
        let items = promptQueue.map { prompt in
            QueueDeliveryPlanner.Item(id: prompt.id,
                                      interruptsAtToolGap: !prompt.deferUntilIdle,
                                      scheduledJobId: Self.scheduledCallback(inQueuedText: prompt.text)?.jobId)
        }
        return QueueDeliveryPlanner.take(items, at: point)
    }

    /// Takes `take` out of the queue: returns the prompts to deliver (queue
    /// order) and drops the coalesced fires together with their queued bubbles.
    @MainActor
    func removeQueueTake(_ take: QueueTake) -> [QueuedPrompt] {
        let delivered = promptQueue.filter { take.deliver.contains($0.id) }
        let taken = Set(take.deliver + take.coalesced)
        promptQueue.removeAll { taken.contains($0.id) }
        if !take.coalesced.isEmpty {
            let dropped = Set(take.coalesced)
            messages.removeAll { msg in msg.isQueued && msg.queuedPromptId.map { dropped.contains($0) } == true }
            silentQueuedPromptIds.subtract(dropped)
        }
        logger.info("📨[QueueTake] deliver=\(take.deliver.count) coalesced=\(take.coalesced.count) scheduled=\(take.scheduledJobId?.prefix(8) ?? "-") left=\(self.promptQueue.count)")
        return delivered
    }

    /// The reminder text that goes after a delivered scheduled fire's envelope,
    /// or nil (not a scheduled take, or nothing to say at a turn end).
    @MainActor
    func scheduledReminder(for take: QueueTake, delivered: [QueuedPrompt],
                           at point: QueueDeliveryPoint) -> String? {
        guard let jobId = take.scheduledJobId,
              let callback = delivered.last.flatMap({ Self.scheduledCallback(inQueuedText: $0.text) }) else { return nil }
        switch point {
        case .toolGap:
            return ScheduledInsertText.midTaskReminder(title: callback.title,
                                                       hasPreset: pendingPresetToolCalls[jobId] != nil,
                                                       coalescedCount: take.coalesced.count)
        case .turnEnd:
            return ScheduledInsertText.coalescedNote(title: callback.title, coalescedCount: take.coalesced.count)
        }
    }
}

// BEGIN QueuedCallbackReminder
/// [T-queued-callback-reminder] Tells the parent model, on the NEXT request of
/// its running loop, that a sub agent it delegated has finished and the
/// result is sitting in `promptQueue`.
///
/// Delivery itself is unchanged: a finished callback is queued with
/// `deferUntilIdle`, the tool gap never takes it, and it only becomes a real
/// message at the turn end. Until then the parent cannot see it at all and
/// keeps working blind on a long plan. This adds awareness only — the model
/// decides whether to wrap up or carry on.
///
/// Rules (pure, so they are unit-tested as written):
/// - only `kind="finished"` callbacks that a background job queued
///   (`deferUntilIdle`) count — not progress reports, not scheduled fires,
///   not the user's own queued follow-ups;
/// - each queued callback is listed once (`reminderSent`); a later request
///   carries a reminder only when NEW finished callbacks have arrived, and
///   lists only those;
/// - nothing pending → no reminder.
enum QueuedCallbackReminder {
    struct Candidate: Equatable {
        let promptId: UUID
        /// `AgentCallback.Kind.rawValue` of the queued text, nil when it is
        /// not a callback envelope.
        let callbackKind: String?
        let jobId: String
        let title: String
        let status: String
        let deferUntilIdle: Bool
        let reminderSent: Bool
    }

    /// The callbacks a reminder should list now, in queue order.
    static func pending(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter {
            $0.callbackKind == "finished" && $0.deferUntilIdle && !$0.reminderSent && !$0.jobId.isEmpty
        }
    }

    /// The reminder text for `pending`, or nil when there is nothing to say.
    static func text(for pending: [Candidate]) -> String? {
        guard !pending.isEmpty else { return nil }
        let list = pending.map { c -> String in
            let title = c.title.isEmpty ? "Sub agent" : c.title
            return "\(title) (job \(c.jobId), \(c.status))"
        }.joined(separator: "; ")
        return """
        <system-reminder>
        Background update: sub agent(s) you delegated have finished, and the result is queued for this conversation: \(list)

        It has NOT been delivered to you yet. It arrives as a new message only after your current turn ends, i.e. when you reply without calling more tools. Your call:
        - If the result could change what you do next, or your remaining work is short or non-essential, wrap up now and end the turn with a brief summary. The result will then arrive.
        - If your current work is independent of it and must finish first, keep going. The result stays queued and won't be lost.

        Don't poll for it, re-delegate, or mention this reminder to the user.
        </system-reminder>
        """
    }
}
// END QueuedCallbackReminder
