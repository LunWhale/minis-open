import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Background Task + Background Status Timer

extension AIChatViewModel {

    // MARK: - Current turn [T-bgnotif-current-turn]

    /// Index in `history` where the CURRENT user turn begins: just after the
    /// last user message that the user actually sent (any part that is not a
    /// tool result). Assistant turns at or after this index belong to the run
    /// answering that message; everything before is earlier turns. 0 when no
    /// such message exists.
    ///
    /// Structural rather than a count recorded at run start: `retry()` removes
    /// the failed reply AFTER some entry points begin the run, so a recorded
    /// count can point past the new reply. When a tool-result message carries
    /// extra parts (e.g. a screenshot) the boundary lands later, which only
    /// shrinks the window — it can never reach back into an earlier turn,
    /// which is the property the callers rely on.
    static func currentTurnStartIndex(in history: [AgentMessage]) -> Int {
        guard let userIdx = history.lastIndex(where: { msg in
            msg.role == .user && msg.parts.contains { part in
                if case .toolResult = part { return false }
                return true
            }
        }) else { return 0 }
        return userIdx + 1
    }

    /// [T-sched-notif-in-place] The scheduled task whose firing opened the
    /// current turn (see `currentTurnStartIndex`), or nil for a turn the user,
    /// a Shortcut or a sub agent started.
    static func scheduledJobIdOpeningCurrentTurn(in history: [AgentMessage]) -> String? {
        let start = currentTurnStartIndex(in: history)
        guard start > 0, start <= history.count else { return nil }
        let texts = history[start - 1].parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }
        return BackgroundTaskNotificationID.scheduledJobId(inTurnTexts: texts)
    }

    // MARK: - Background Task

    func beginBackgroundProcessing() {
        guard backgroundTaskID == .invalid else { return }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.1fs", remaining)
        let sessions = SessionActivityTracker.shared.activeSessions.count
        logger.info("[BKA][BGTask] Beginning 'AgentLoop' remaining=\(remainingStr) sessions=\(sessions)")
        backgroundSuspended = false
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AgentLoop") { [weak self] in
            guard let self else { return }
            let expRemaining = UIApplication.shared.backgroundTimeRemaining
            let expRemainingStr = expRemaining > 99999 ? "unlimited" : String(format: "%.1fs", expRemaining)
            logger.warning("[BKA][BGTask] Expiry handler fired — id=\(self.backgroundTaskID.rawValue) remaining=\(expRemainingStr) sessions=\(SessionActivityTracker.shared.activeSessions.count) silentAudio=\(BackgroundKeepAliveManager.shared.silentAudioIsPlaying) keepAliveEffective=\(BackgroundKeepAliveManager.shared.enhancedBackgroundEffective)")
            // The FINITE UIApplication background task is expiring. This is a
            // separate mechanism from the silent-audio (`audio` background mode)
            // keep-alive: when keep-alive is active the process stays alive
            // regardless of this task's clock, so expiring it must NOT kill the
            // running shell / delay countdown — doing so was severing long
            // `delay:` tool waits (and any in-flight command) even though the
            // app was in no danger of termination. Instead, just re-arm a fresh
            // finite task to reset the clock and let the agent loop continue.
            // [T-bka-continued-processing] An iOS 26 continued-processing task
            // holds the process while it runs, but backgroundTimeRemaining
            // still counts down and these finite tasks still expire. Re-arming
            // one with seconds left (the branch below, which assumes silent
            // audio makes the time unlimited) got the app killed by
            // RunningBoard for an assertion it could not end in time
            // (0x2182BAD2). End it promptly and keep the loop running.
            // [T-bka-audio-dead-expiry] One decision for the three exits below.
            // "Keep-alive is on in Settings" used to be enough to re-arm; on
            // 2026-10-09 the audio had been dead for 30 s (a phone call), the
            // handler fired with 4 s left, logged "silent-audio keep-alive is
            // active — re-arming, NOT cancelling", and the app was killed 4 s
            // later still holding the new task. Re-arm only while the audio
            // really plays; otherwise suspend, which the user can resume.
            let keepAlive = BackgroundKeepAliveManager.shared
            let expiryAction = BGTaskExpiryPolicy.decide(
                continuedTaskRunning: keepAlive.continuedTaskRunning,
                keepAliveConfigured: keepAlive.enhancedBackgroundEffective,
                silentAudioPlaying: keepAlive.silentAudioIsPlaying)
            if expiryAction == .endOnly {
                logger.info("[Background] Finite task expiring while a continued-processing task holds the app — ending it, loop keeps running")
                let expiringId = self.backgroundTaskID
                self.backgroundTaskID = .invalid
                if expiringId != .invalid {
                    UIApplication.shared.endBackgroundTask(expiringId)
                    AIChatViewModel.noteBackgroundTaskEnded()
                }
                // [T-bka-continued-fallback] If the continued task ends first
                // (expired, or Stop on its card), take a fresh finite task so
                // this handler runs again without the continued branch: it
                // then re-arms under silent audio, or suspends the loop to
                // resume in the foreground - rather than the app being frozen
                // mid-request with no task held.
                let sid = self.sessionId
                BackgroundKeepAliveManager.shared.onContinuedTaskEndedMidRun { [weak self] in
                    guard let self, let sid, SessionActivityTracker.shared.activeSessions.contains(sid) else { return }
                    logger.info("[Background] Continued task ended mid-run — taking a fresh finite task")
                    self.beginBackgroundProcessing()
                }
                return
            }
            if expiryAction == .rearm {
                logger.info("[Background] Finite task expiring but silent-audio keep-alive is active — re-arming, NOT cancelling")
                // End only the expiring task id (no completion notification),
                // then immediately request a new one. Order matters: capture the
                // old id, invalidate, re-begin.
                let expiringId = self.backgroundTaskID
                self.backgroundTaskID = .invalid
                if expiringId != .invalid {
                    UIApplication.shared.endBackgroundTask(expiringId)
                    AIChatViewModel.noteBackgroundTaskEnded()
                }
                self.beginBackgroundProcessing()
                return
            }
            // No keep-alive backing us — the system really will terminate the
            // app. Suspend instead of cancelling: kill the running shell command
            // so the OS doesn't terminate us, but keep the Task alive so we can
            // resume when foregrounded.
            // Keep-alive on in Settings but its audio is not playing: say so,
            // and give the audio one more start for whatever runs after this.
            let audioLost = keepAlive.enhancedBackgroundEffective
            if audioLost {
                logger.warning("[Background] Task expiring and keep-alive audio is NOT playing (interrupted and not restored) — suspending agent loop instead of re-arming")
                keepAlive.reviveSilentAudioIfDead(source: "bgTaskExpiry")
            } else {
                logger.warning("[Background] Task expiring (no keep-alive) — suspending agent loop")
            }
            self.backgroundSuspended = true
            if !keepAlive.enhancedBackgroundEffective || audioLost {
                BackgroundInterruptionTracker.shared.recordInterruption()
                // [T-session-paused-badge-active-false-positive] The PAUSED badge
                // is now driven solely by `canResume` (see AIChatViewModel's
                // canResume didSet) — the authoritative interrupted flag — so it
                // tracks genuine interruption + resolution uniformly. No explicit
                // push here: a background-suspended in-flight loop sets canResume
                // on the next session load / cleanup, which raises the badge.
                // [T-tool-bg-suspended-hint] Stamp the tool blocks that are
                // in-flight RIGHT NOW — these are the ones the OS is about to
                // suspend. They'll be force-finalized to .cancelled (here via
                // stopCurrentCommand / later via the safety net or session
                // reload); the flag lets the chat capsule show the yellow ⓘ
                // hint only for genuine background suspensions. Follows the same
                // gate as the BackgroundInterruptionTracker banner.
                for msg in self.messages where msg.role == .assistant {
                    for block in msg.blocks {
                        switch block.toolStatus {
                        case .streaming, .running:
                            // A real suspension outranks "ran slowly".
                            ContinuedRunHintStore.blockIds.remove(block.id)
                            block.wasBackgroundSuspended = true
                        default:
                            break
                        }
                    }
                }
            }
            self.stopCurrentCommand()
            // Must end the background task to avoid termination.
            // [T-bgnotif-outcome] The loop has NOT finished: it is suspended
            // (retrying, or waiting on a dead network) and resumes in the
            // foreground. Say so instead of "completed".
            self.endBackgroundProcessing(backgroundTimeExpired: true)
        }
        // [T-ios-bgkeepalive-diag] Only count a grant the OS actually gave
        // us: beginBackgroundTask returns .invalid when the request is refused,
        // and treating that as live is exactly the false "healthy" signal this
        // counter exists to remove.
        if backgroundTaskID != .invalid {
            AIChatViewModel.noteBackgroundTaskBegan()
        } else {
            logger.warning("[BKA][BGTask] beginBackgroundTask REFUSED (.invalid) — no OS grant held")
        }
        logger.info("[BKA][BGTask] started id=\(self.backgroundTaskID.rawValue) sessions=\(sessions) liveGrants=\(AIChatViewModel.liveBackgroundTaskCount)")
        startBackgroundStatusTimer()
    }

    /// [T-bgnotif-outcome] This turn's last assistant row in `messages`.
    ///
    /// A thrown loop error is attached to the last ASSISTANT row because a
    /// queued user row or a status row can follow it, so `messages.last` is
    /// not where the error lives. Rows before the last user message the user
    /// actually sent (queued rows excluded) belong to earlier turns and never
    /// count.
    func currentTurnAssistantMessage() -> ChatMessage? {
        let rows = messages
        let idx = BackgroundTurnOutcome.currentTurnAssistantIndex(
            count: rows.count,
            isSentUser: { rows[$0].role == .user && !rows[$0].isQueued },
            isAssistant: { rows[$0].role == .assistant })
        return idx.map { rows[$0] }
    }

    /// - Parameter backgroundTimeExpired: [T-bgnotif-outcome] true only from
    ///   the background-task expiration handler, which ends the grant while
    ///   the loop is still suspended mid-run.
    func endBackgroundProcessing(backgroundTimeExpired: Bool = false) {
        // [T-ios-session-unread-badge / T-ios-unread-dot-reappears] Mark unread
        // when this session finished off-screen and produced NEW content. The
        // red dot means "this session finished and you haven't opened it yet".
        //
        // This funnel is hit from ~15 sites (normal completions, kernel-failure
        // early-returns, cancel cleanup, the bgTask-expiration handler,
        // resumeQueueAfterCancel, …). Pushing unconditionally re-added the dot
        // on late/duplicate calls that carried no new content — e.g. the user
        // reads and leaves the session, then a background keep-alive bgTask
        // expires and its handler calls endBackgroundProcessing(), re-badging a
        // session the user already read. Gate on the assistant-turn count
        // actually having grown since we last badged, so only a run that truly
        // produced a new assistant completion re-marks unread.
        if let sid = sessionId, !sid.isEmpty {
            let assistantTurns = agentHistory.reduce(0) { $0 + ($1.role == .assistant ? 1 : 0) }
            let hasNewCompletion = assistantTurns > lastBadgedAssistantTurnCount
            if Self.activeSessionId == sid {
                // User is looking at this session right now — they see the
                // completion, so never badge, but DO advance the baseline so a
                // later off-screen call for this same turn can't re-badge it.
                lastBadgedAssistantTurnCount = max(lastBadgedAssistantTurnCount, assistantTurns)
            } else if hasNewCompletion,
                      !AgentJobRegistry.shared.hasActiveChildren(parent: sid) {
                lastBadgedAssistantTurnCount = assistantTurns
                SessionBadgeStore.shared.pushFront(.unread, for: sid)
            } else if hasNewCompletion {
                // [T-sidebar-subagent-running] A sub agent reporting back wakes
                // the parent for a turn, and that turn ending lands here — so a
                // five-agent fan-out raised the red "there is something new to
                // read" dot up to five times while the work was still going,
                // each one reading as if the whole thing had finished. The dot
                // is for a conversation that has come to rest; hold it until
                // the last sibling is in, and let the final turn raise it.
                //
                // The baseline is deliberately NOT advanced: this turn's
                // completion has not been announced yet, so the run that ends
                // the fan-out must still count as new.
                logger.info("[Badge] unread held — \(sid.prefix(8)) still has sub agents running")
            }
        }

        guard backgroundTaskID != .invalid else { return }
        stopBackgroundStatusTimer()
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.1fs", remaining)
        logger.info("[BKA][BGTask] Ending id=\(self.backgroundTaskID.rawValue) remaining=\(remainingStr) sessions=\(SessionActivityTracker.shared.activeSessions.count) silentAudio=\(BackgroundKeepAliveManager.shared.silentAudioIsPlaying)")

        // Post local notification if task completed in background.
        // Await Live Activity "completed" state update BEFORE posting the
        // notification so the lock-screen capsule shows the checkmark when
        // the notification arrives, not "Responding · streaming".
        do {
            let sid = sessionId ?? ""
            // [T-mac-dock-badge] "Away" includes a Mac where another app is in
            // front - UIKit still reports .active there.
            let wasBackground = BackgroundKeepAliveManager.shared.userIsAway
            // [T-bgnotif-outcome] What the turn really ended as. This used to be
            // `messages.last?.error != nil || errorMessage != nil` alone, so a
            // turn cut off by the background-time expiry, a context-full stop
            // (systemInfo row, no error) or an error sitting on an assistant row
            // with a queued/status row after it all notified "✅ completed".
            let turnError = currentTurnAssistantMessage()?.error
            let outcome = BackgroundTurnOutcome.decide(
                backgroundTimeExpired: backgroundTimeExpired,
                turnError: turnError,
                errorMessage: errorMessage,
                canResume: canResume,
                userStopped: userDidCancel)
            let hasError = outcome == .failed
            logger.info("[BackgroundNotification] outcome=\(outcome) expired=\(backgroundTimeExpired) turnError=\(turnError != nil) errorMessage=\(self.errorMessage != nil) canResume=\(self.canResume) userStopped=\(self.userDidCancel)")
            let responseSummary: String = {
                // [T-bgnotif-current-turn] GH#263. Only THIS turn's replies are
                // candidates. The search used to span the whole history, so a
                // turn that failed with no text fell back to the PREVIOUS
                // turn's reply — a lock-screen banner showing a complete answer
                // while the bubble said "Model returned an empty response".
                // [T-bgnotif-outcome] An interrupted turn says so; any partial
                // text would read as the answer.
                if outcome == .interrupted {
                    logger.info("[BackgroundNotification] source=interrupted")
                    return AppLocalized("Task paused. Open the session to continue.")
                }
                // A failed turn leads with why it failed.
                if hasError, let err = (turnError ?? errorMessage)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                    logger.info("[BackgroundNotification] source=turn-error")
                    return String(err.prefix(200))
                }
                let turnStart = Self.currentTurnStartIndex(in: agentHistory)
                let allAssistantTurns = agentHistory[min(turnStart, agentHistory.count)...].filter { $0.role == .assistant }
                logger.verbose("[BackgroundNotification] building responseSummary from agentHistory: totalMsgs=\(agentHistory.count) turnStart=\(turnStart) assistantTurns=\(allAssistantTurns.count) wasBackground=\(wasBackground) hasError=\(hasError)")

                func textFromTurn(_ msg: AgentMessage) -> String {
                    let raw = msg.parts.compactMap { part -> String? in
                        if case .text(let t) = part { return t }
                        return nil
                    }.joined(separator: "\n")
                    return MarkdownStripper.plainText(raw)
                }

                func hasToolUse(_ msg: AgentMessage) -> Bool {
                    msg.parts.contains { if case .toolUse = $0 { return true }; return false }
                }

                // [T-bgnotif-internal-text-leak] Never let a model-facing string
                // become the notification body.
                //
                // The internal "bridge" turn inserted when a queued user message
                // interrupts a tool loop is role=.assistant, a single .text part,
                // and has NO toolUse — i.e. it is precisely what the
                // "last pure-text turn" preference below looks for. It shipped to
                // a user's lock screen verbatim ("(Interrupted mid-task by a new
                // user message. Decide based on the new message…"), which is an
                // instruction addressed to the model, not a summary of anything.
                //
                // The chat UI already hides these rows (ChatModels.isInternalBridge,
                // CollectionViewMessageListV3, Persistence), but every one of those
                // filters is on RawMessage/ChatMessage. This path reads
                // `agentHistory` (AgentMessage), so it inherited none of them.
                // Filter here rather than at each `last(where:)` so any future
                // selection strategy added below is covered by construction.
                func isInternalOnly(_ msg: AgentMessage) -> Bool {
                    let raw = msg.parts.compactMap { part -> String? in
                        if case .text(let t) = part { return t }
                        return nil
                    }.joined(separator: "\n")
                    return RawMessage.isInternalBridgeText(raw)
                }

                let assistantTurns = allAssistantTurns.filter { !isInternalOnly($0) }
                if assistantTurns.count != allAssistantTurns.count {
                    logger.info("[BackgroundNotification] filtered \(allAssistantTurns.count - assistantTurns.count) internal-only turn(s) out of summary candidates")
                }

                for (idx, msg) in assistantTurns.enumerated() {
                    let hasTools = hasToolUse(msg)
                    let txt = textFromTurn(msg)
                    let preview = String(txt.prefix(20)).replacingOccurrences(of: "\n", with: "↵")
                    logger.info("[BackgroundNotification] agentTurns[\(idx)] hasToolUse=\(hasTools) textLen=\(txt.count) textPreview=\(preview.debugDescription)")
                }

                if let pure = assistantTurns.last(where: { !hasToolUse($0) }) {
                    let t = textFromTurn(pure)
                    if !t.isEmpty {
                        logger.info("[BackgroundNotification] source=pure-text-turn(agentHistory) first20=\(String(t.prefix(20)).debugDescription)")
                        return String(t.prefix(200))
                    }
                }
                if let any = assistantTurns.last(where: { !textFromTurn($0).isEmpty }) {
                    let t = textFromTurn(any)
                    logger.info("[BackgroundNotification] source=any-text-turn(agentHistory) first20=\(String(t.prefix(20)).debugDescription)")
                    return String(t.prefix(200))
                }
                // No usable assistant text. If the only thing this turn produced
                // was an internal bridge, the task did not finish — it was
                // interrupted by a queued user message — so say that in the
                // user's own terms instead of claiming completion.
                if allAssistantTurns.contains(where: { isInternalOnly($0) }) {
                    logger.info("[BackgroundNotification] source=fallback-interrupted")
                    return AppLocalized("Task interrupted by a new message. Open the session to continue.")
                }
                logger.info("[BackgroundNotification] source=fallback")
                return AppLocalized("Task completed.")
            }()
            logger.info("[BackgroundNotification] responseSummary ready length=\(responseSummary.count) first20=\(String(responseSummary.prefix(20)).debugDescription) wasBackground=\(wasBackground)")
            let fallbackTitle = messages.first(where: { $0.role == .user })?.content.prefix(60).description ?? "Agent task"
            let bgTaskID = backgroundTaskID
            backgroundTaskID = .invalid
            // [T-ios-bgkeepalive-diag] Decrement HERE, synchronously with the
            // `.invalid` reset — not inside the Task below. That Task first
            // awaits the Live Activity finish and a ChatStore lookup; if the
            // process is suspended or terminated before it lands, the decrement
            // never runs, while the `backgroundTaskID != .invalid` guard above
            // makes any retry a no-op. The count would then over-report live
            // grants forever — the same false-healthy signal this field was
            // added to eliminate. The OS-side endBackgroundTask stays in the
            // Task (it must outlive the notification work); only our own
            // bookkeeping moves up, so the two can disagree for a few hundred ms
            // in exchange for never leaking.
            if bgTaskID != .invalid {
                AIChatViewModel.noteBackgroundTaskEnded()
            }
            // [T-shortcut-duplicate-completion-notification] Read AND clear here,
            // synchronously, before the Task below: a Shortcuts intent already
            // posted its own completion notification for this run, so the generic
            // one would be a second, overlapping alert for one task. Consuming the
            // flag (rather than leaving it set) means only THIS completion is
            // suppressed — the cached VM stays usable, and a message the user
            // later sends by hand in the same session notifies normally.
            // Scope is deliberately narrow: only the notification is skipped.
            // Live Activity finish, badge counting, and endBackgroundTask all
            // still run below.
            let suppressGenericNotification = suppressGeneralCompletionNotification
            // [T-sched-notif-in-place] Read with the history now, before the Task:
            // a run opened by a scheduled firing updates that task's notification.
            let scheduledJobId = Self.scheduledJobIdOpeningCurrentTurn(in: agentHistory)
            suppressGeneralCompletionNotification = false
            if suppressGenericNotification {
                logger.info("[BackgroundNotification] suppressed — a Shortcuts intent owns this run's notification")
            }
            // [T-scheduled-active-session] Every ACTIVE conversation counts
            // here, including one only waiting on its scheduled follow-up or
            // its sub agents.
            //
            // `finishActivity` tears the Live Activity down entirely and is the
            // visible "everything is done" state. Doing that while another
            // conversation is still active says the work is over when it is
            // only waiting. `markSessionCompleted` is the right call in that
            // case: this run finished, the activity stays for what is still
            // outstanding.
            //
            // [T-live-activity-scheduled] This conversation itself may still be
            // waiting for its next scheduled run. Excluding it as "this run"
            // finished the whole activity after every fire of a single loop,
            // and the gap then showed an empty activity. Its card turns into
            // the waiting card instead (no "completed" mark: it is not done).
            let keptBySchedule = !sid.isEmpty && SessionActivityTracker.shared.scheduledSessions.contains(sid)
            let otherActive = SessionActivityTracker.shared.busySessions
                .filter { $0 != sid }
            logger.info("[BKA][BGTask] otherActive=\(otherActive.count) ids=[\(otherActive.map { $0.prefix(8) }.joined(separator: ","))] keptBySchedule=\(keptBySchedule) before Task")
            Task {
                if keptBySchedule {
                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "scheduledRunEnded")
                } else if outcome == .interrupted {
                    // [T-bgnotif-outcome] Not done, so never the green
                    // "completed" resting state: end the activity when nothing
                    // else runs, else re-sync it to what is still live.
                    if otherActive.isEmpty {
                        AgentLiveActivityManager.shared.endActivity()
                    } else {
                        BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "turnInterrupted")
                    }
                } else if otherActive.isEmpty {
                    await AgentLiveActivityManager.shared.finishActivity(
                        lastMessages: sid.isEmpty ? [:] : [sid: responseSummary]
                    )
                } else {
                    AgentLiveActivityManager.shared.markSessionCompleted(
                        sessionId: sid,
                        lastMessage: responseSummary
                    )
                }
                let sessionTitle: String
                if let session = await ChatStore.shared.getSession(sid),
                   let t = session.title, !t.isEmpty {
                    sessionTitle = t
                } else {
                    sessionTitle = fallbackTitle
                }
                if !suppressGenericNotification {
                    BackgroundKeepAliveManager.shared.postBackgroundTaskNotification(
                        sessionTitle: sessionTitle, responseSummary: responseSummary, sessionId: sid, outcome: outcome, wasBackground: wasBackground,
                        scheduledJobId: scheduledJobId
                    )
                }
                await MainActor.run {
                    // Bookkeeping was already decremented synchronously above.
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
        }
    }

    // MARK: - Background Status Timer

    /// Starts a periodic timer that logs tool execution status while backgrounded.
    /// Only emits logs when the app is actually in the background.
    func startBackgroundStatusTimer() {
        stopBackgroundStatusTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // Only log when actually in background
            guard UIApplication.shared.applicationState != .active else { return }
            let remaining = UIApplication.shared.backgroundTimeRemaining
            guard remaining < 99999 else {
                // Background task ended — stop timer
                timer.invalidate()
                self.backgroundStatusTimer = nil
                return
            }
            let remainingStr = String(format: "%.1fs", remaining)
            let status = self.backgroundToolStatusSummary()
            // Escalate to WARN once we're inside the last 15s — past this
            // point iOS is liable to suspend the process at any moment, so
            // any subsequent log noise is ranked accordingly. Below 60s
            // we keep the existing 5s cadence; we don't need finer
            // granularity until we're closer to expiry.
            if remaining < 15 {
                logger.warning("[Background] ⏱ remaining: \(remainingStr) (CRITICAL <15s) | \(status)")
            } else {
                logger.info("[Background] ⏱ remaining: \(remainingStr) | \(status)")
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        backgroundStatusTimer = timer
    }

    func stopBackgroundStatusTimer() {
        backgroundStatusTimer?.invalidate()
        backgroundStatusTimer = nil
    }

    /// Builds a one-line summary of current tool execution state for background logging.
    func backgroundToolStatusSummary() -> String {
        // Find the active assistant message (last one being processed)
        guard let assistantMsg = messages.last, assistantMsg.role == .assistant else {
            return "no active tool"
        }

        // Find the most recent tool block
        guard let toolBlock = assistantMsg.blocks.last(where: { $0.kind != .text }) else {
            return "streaming text (\(assistantMsg.blocks.last?.content.count ?? 0) chars)"
        }

        let toolName: String
        switch toolBlock.kind {
        case .text: toolName = "text"
        case .thinking: toolName = "thinking"
        case .shellTool: toolName = "shell"
        case .fileReadTool: toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool: toolName = "file_edit"
        case .browserTool: toolName = "browser"
        case .readImageTool: toolName = "read_image"
        case .memoryTool: toolName = "memory"
        case .delegateTool: toolName = SubAgentDefinition.toolName
        case .userAskTool: toolName = UserAskTool.name
        case .info: toolName = "info"
        }

        // [T-ios-tool-title-lost-in-status] Prefer the model-supplied
        // `tool_title` (persisted as `toolSummary`) over the derived
        // `toolDescription`, matching every other display site
        // (AssistantBlockView.displayText, SessionsOffloadBridge,
        // GetSessionStatusIntent, ToolLiveSheet). This site read
        // `toolDescription` alone, so a tool call WITH a title still surfaced
        // the generic derivation — e.g. a `read_image` whose title was
        // "查看页面截图" reported the bare filename / "Read image" instead.
        let desc = toolBlock.toolSummary ?? toolBlock.toolDescription
        let elapsed: String
        if let start = toolBlock.toolStartTime {
            elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
        } else {
            elapsed = "?"
        }

        let statusStr: String
        switch toolBlock.toolStatus {
        case .streaming(let bytes):
            statusStr = "streaming(\(bytes)B)"
        case .running:
            statusStr = "running"
        case .success:
            statusStr = "success"
        case .failed(let msg):
            statusStr = "failed(\(msg.prefix(50)))"
        case .cancelled:
            statusStr = "cancelled"
        case .none:
            statusStr = "pending"
        }

        let outputPreview: String
        if !toolBlock.content.isEmpty {
            let trimmed = toolBlock.content.suffix(80).replacingOccurrences(of: "\n", with: "↵")
            outputPreview = " output=\"...\(trimmed)\""
        } else {
            outputPreview = ""
        }

        // Browser-specific info
        var browserInfo = ""
        if case .browserTool = toolBlock.kind {
            if let bm = browserTabPool.activeManager {
                let url = bm.currentURL
                if !url.isEmpty {
                    browserInfo = " url=\(url.prefix(60))"
                }
                if bm.isLoading {
                    browserInfo += " loading=true"
                }
            }
        }

        // Running command PID info
        var pidInfo = ""
        if !runningCommandPids.isEmpty {
            let pidList = runningCommandPids.sorted().map(String.init).joined(separator: ",")
            pidInfo = " pids=[\(pidList)]"
        }

        let summary = "tool=\(toolName) status=\(statusStr) elapsed=\(elapsed)\(pidInfo) desc=\"\(desc.prefix(40))\"\(outputPreview)\(browserInfo)"
        SessionActivityTracker.shared.currentToolStatus = "\(toolName): \(statusStr)"
        if let sid = self.sessionId {
            // [T-ios-tool-title-lost-in-status] `toolStatus` is the USER-FACING
            // string (the SSE path at AIChatViewModel+SSEStream.swift ~830
            // passes `toolSummary ?? toolDescription` here, and the Live
            // Activity renders it as the tool's subtitle). This site passed the
            // internal lifecycle token instead — "running" / "streaming(512B)" —
            // so whenever the background path won the race the descriptive
            // title was replaced by machine state. Pass the same descriptive
            // text; the lifecycle token stays in `currentToolStatus` above,
            // which is what actually wants it.
            SessionActivityTracker.shared.updateToolInfo(sessionId: sid, toolName: toolName, toolStatus: desc)
        }
        return summary
    }

    /// Called from the agent loop after a tool result is collected.
    /// If the background task was expired, this suspends the loop until
    /// the app returns to the foreground, then re-registers a background task
    /// so the next iteration can proceed.
    func waitIfBackgroundSuspended() async {
        // If enhanced background keep-alive is active, skip suspension entirely
        if BackgroundKeepAliveManager.shared.enhancedBackgroundEffective { return }
        guard backgroundSuspended else { return }

        // If the app is already in the foreground (user returned before we got here),
        // just clear the flag, re-register background task, and continue.
        if UIApplication.shared.applicationState == .active {
            logger.info("[Background] App already active — resuming immediately")
            backgroundSuspended = false
            beginBackgroundProcessing()
            return
        }

        logger.info("[Background] Agent loop suspended — waiting for foreground")

        // [ContinuationDiag] (#181) Parks until willEnterForeground. A known
        // registration race here was already fixed once (see the comment further
        // down about T-ios-bgresume-registration-race), so an
        // entering-without-resumed here means the loop is waiting on a
        // foreground event that already passed — the loop then looks stalled
        // even though nothing is wrong with the network.
        let diagStart = Date()
        logger.info("[ContinuationDiag] entering wait for backgroundSuspended at \(Self.diagTimestamp(diagStart)) session=\(self.sessionId ?? "nil") appState=\(Self.diagAppStateName())")

        // Listen for foreground notification to resume
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.foregroundContinuation = continuation
            self.foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                logger.info("[Background] Foreground notification — resuming agent loop")
                self.backgroundSuspended = false
                // Re-register a background task for the continued work
                self.beginBackgroundProcessing()
                if let c = self.foregroundContinuation {
                    self.foregroundContinuation = nil
                    c.resume()
                }
                if let obs = self.foregroundObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.foregroundObserver = nil
                }
            }
            // [T-ios-bgresume-registration-race] The `.active` early-return
            // above and this observer leave a gap: if the loop reaches here
            // during the inactive window of a foreground transition
            // (willEnterForeground already delivered, didBecomeActive not
            // yet), the notification this observer waits for has ALREADY
            // fired and never repeats this cycle — the continuation would
            // park forever and the loop silently dies mid-run with no
            // error and no resume affordance. Re-check AFTER registration
            // (same main-thread turn, so no notification can interleave):
            // any state other than .background means we may have missed the
            // signal — resume through the same idempotent drain the
            // observer uses.
            if UIApplication.shared.applicationState != .background {
                logger.warning("[Background] App left .background before observer registration — resuming immediately (missed willEnterForeground)")
                self.backgroundSuspended = false
                self.beginBackgroundProcessing()
                if let c = self.foregroundContinuation {
                    self.foregroundContinuation = nil
                    c.resume()
                }
                if let obs = self.foregroundObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.foregroundObserver = nil
                }
            }
        }
        logger.info("[ContinuationDiag] resumed backgroundSuspended after \(Int(Date().timeIntervalSince(diagStart) * 1000))ms appState=\(Self.diagAppStateName())")
    }

    /// Pauses the agent loop when the user activates browser takeover.
    /// The loop suspends here until the user dismisses the browser sheet.
    func waitIfBrowserTakeover() async {
        guard browserTakeoverActive else { return }
        logger.info("[Takeover] Agent loop pausing for browser takeover")
        // [ContinuationDiag] (#181) This continuation has no timeout — if it is
        // never resumed the agent loop parks here forever and the user sees a
        // stalled session. An "entering" line with no matching "resumed" line is
        // the signature of candidate 1 (continuation deadlock).
        let diagStart = Date()
        logger.info("[ContinuationDiag] entering wait for browserTakeover at \(Self.diagTimestamp(diagStart)) session=\(self.sessionId ?? "nil")")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.takeoverContinuation = continuation
        }
        logger.info("[ContinuationDiag] resumed browserTakeover after \(Int(Date().timeIntervalSince(diagStart) * 1000))ms")
        logger.info("[Takeover] Agent loop resumed from browser takeover")

        // Take a screenshot so the agent sees what the user did during takeover
        let screenshotInput = BrowserActionInput(
            action: .screenshot, url: nil, selector: nil, text: nil,
            coordinateX: nil, coordinateY: nil, direction: nil, amount: nil,
            script: nil, userAgent: nil, maxDepth: nil, tabId: nil
        )
        if let result = try? await browserTabPool.execute(action: screenshotInput, owner: sessionId),
           let b64 = result.base64Image,
           let data = Data(base64Encoded: b64) {
            // [T-image-real-seams] File write + message: takeoverScreenshotMessage.
            let timestamp = Int(Date().timeIntervalSince1970)
            let msg = Self.takeoverScreenshotMessage(data, sessionId: sessionId, timestamp: timestamp)
            // [T-image-gate #412] Stored like the loop's other app-injected
            // rows, so after a restart the model still has the screenshot it
            // was shown (the stored image is the gate's output, so the bytes
            // match). It renders nothing on reload: the note is a
            // <system-reminder> and the image is not a picked attachment.
            let idx = agentHistory.count
            agentHistory.append(msg)
            if let pid = await persistAgentMessage(msg), idx < agentHistory.count {
                agentHistory[idx].dbMessageId = pid
            }
        }
    }

    /// Waits for the user to finish a mid-action browser takeover.
    /// Called after `browserTabPool.execute(action:)` when `browserTakeoverActive` is true.
    /// Returns a fresh screenshot result after the user finishes, or nil on timeout.
    func waitForMidActionTakeover() async -> BrowserActionResult? {
        logger.info("[Takeover] Mid-action: pausing browser action for user takeover")

        // Start 5-minute timeout
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                logger.info("[Takeover] Mid-action takeover timed out after 5 minutes")
                self.browserTakeoverActive = false
                if let c = self.midActionTakeoverContinuation {
                    self.midActionTakeoverContinuation = nil
                    c.resume()
                }
            }
        }
        self.takeoverTimeoutTask = timeoutTask

        // Suspend until the user finishes or timeout fires
        // [ContinuationDiag] (#181) This one DOES have a 5-minute timeout, so it
        // should always produce a matching "resumed" line. If a stall shows this
        // entering-without-resumed, the timeout task itself failed to fire —
        // which would point at Task.sleep being stretched (candidate 3) rather
        // than a plain deadlock.
        let diagStart = Date()
        logger.info("[ContinuationDiag] entering wait for midActionTakeover at \(Self.diagTimestamp(diagStart)) session=\(self.sessionId ?? "nil")")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.midActionTakeoverContinuation = continuation
        }
        logger.info("[ContinuationDiag] resumed midActionTakeover after \(Int(Date().timeIntervalSince(diagStart) * 1000))ms")

        // Clean up timeout — if cancel() is a no-op, the timeout already fired
        let timedOut = timeoutTask.isCancelled == false
        timeoutTask.cancel()
        self.takeoverTimeoutTask = nil

        logger.info("[Takeover] Mid-action: resumed (timedOut=\(timedOut))")

        // Take a fresh screenshot so the agent sees the user's changes
        let screenshotInput = BrowserActionInput(
            action: .screenshot, url: nil, selector: nil, text: nil,
            coordinateX: nil, coordinateY: nil, direction: nil, amount: nil,
            script: nil, userAgent: nil, maxDepth: nil, tabId: nil
        )
        if let result = try? await browserTabPool.execute(action: screenshotInput, owner: sessionId) {
            return result
        }
        return nil
    }

    /// Called when the user dismisses the browser takeover sheet.
    func resumeFromBrowserTakeover() {
        browserTakeoverActive = false
        // Cancel mid-action timeout
        takeoverTimeoutTask?.cancel()
        takeoverTimeoutTask = nil
        // Resume mid-action continuation if active
        if let c = midActionTakeoverContinuation {
            midActionTakeoverContinuation = nil
            c.resume()
        }
        // Resume between-turn continuation if active
        if let c = takeoverContinuation {
            takeoverContinuation = nil
            c.resume()
        }
    }

    func stopCurrentCommand() {
        // A tool can be in several cancellable states:
        //   - one or more live iSH processes (runningCommandPids non-empty),
        //   - a pre-execution delay countdown (toolDelayWaitActive),
        //   - an in-flight browser_use load (a tab is mid-navigation).
        // Any of these is a valid stop target. [T-ios-browser-tool-stop-button]
        // Browser tools don't go through iSH, so without the hasLoadingTab arm
        // the per-bubble stop button was a NOOP for a hung `navigate` — it bailed
        // here because runningCommandPids was empty. Bail only when NONE apply,
        // so random taps don't poison the flag for a future real invocation.
        let browserLoading = browserTabPool.hasLoadingTab
        // [T-shell-stop-abandon] Ask the coordinator too: `runningCommandPids`
        // is one slot that concurrent tools overwrite and the first Stop
        // clears, so a command still stuck after that first tap left every
        // further tap a silent no-op.
        let shellRunning = (fsSessionId ?? sessionId).map {
            ISHExecutionCoordinator.hasStoppableCommand(sessionId: $0, ownerId: sessionId)
        } ?? false
        guard !runningCommandPids.isEmpty || shellRunning || toolDelayWaitActive || browserLoading else {
            logger.info("⏹️ stopCurrentCommand — nothing to stop sid=\(self.sessionId?.prefix(8) ?? "nil")")
            return
        }
        commandCancelledByUser = true
        // Stop any in-flight browser page loads. stopLoading() resolves the
        // manager's navigationContinuation, so the awaited browserTabPool
        // .execute(action:) returns and the hung tool call completes.
        if browserLoading {
            let n = browserTabPool.stopAllLoading()
            logger.info("⏹️ stopCurrentCommand — stopped \(n) loading browser tab(s)")
        }
        // Stop ALL currently running shells — concurrent tool execution
        // can have many in flight at once and a stop tap should cancel
        // the entire batch. [T-concurrent-tools 2026-05-25]
        if !runningCommandPids.isEmpty || shellRunning {
            // [T-shell-stop-blocked-by-actor] SYNCHRONOUS and nonisolated —
            // deliberately not `Task { await …stopCurrentCommand() }`.
            //
            // That form has to queue on the coordinator actor, and the case
            // Stop exists for is exactly when the coordinator is stuck: a
            // guest process wedged on iSH's global `pids_lock` blocks the
            // actor, so the kill request sat in the queue behind the very
            // thing it was meant to kill. Field crash 2026-08-23 20:11 shows
            // no `Coordinator stopping command` line at all — the user
            // pressed Stop and the code never ran.
            //
            // Killing needs nothing from the actor but the pid, which is
            // mirrored under a lock, so this runs right here on the caller.
            // [T-p0-stop-scope] Only THIS session's pids. The coordinator has
            // always keyed in-flight pids by session and accepted the filter;
            // calling it unfiltered meant a Stop in one chat killed the shell
            // commands of every other concurrently running chat. A vm with no
            // session id yet cannot own a running command (commands run after
            // ensureSession), so nil here is logged rather than widened.
            let killed: Int
            // [T-agent-wrapup-turn] Shell commands run under fsSessionId (the
            // parent's id for an agent child, see the shared workspace) and the
            // coordinator files in-flight pids under THAT id — so a child that
            // scoped the kill to its own sessionId found 0 pids and its tool
            // never stopped.
            //
            // [T-shell-stop-owner] …and within that workspace, only the
            // commands THIS session issued. Parent and every sibling agent
            // share the workspace key, so the unfiltered kill took their
            // running commands down too — field-reproduced: stopping one agent
            // killed a sibling's `sleep 90` (exit 15), and that sibling then
            // reported "done" on a task it never finished.
            if let sid = fsSessionId ?? sessionId {
                killed = ISHExecutionCoordinator.stopAllNonisolated(sessionId: sid, ownerId: sessionId)
            } else {
                logger.warning("⏹️ stopCurrentCommand — no sessionId on vm=\(self.vmInstanceId); nothing to scope the kill to")
                killed = 0
            }
            // [T-shell-stop-abandon] …and a command that has not exited
            // `stopAbandonGrace` later gets its result anyway, so the tool
            // ends even when the process is stuck in host I/O.
            logger.info("⏹️ stopCurrentCommand — signalled \(killed) shell command(s) sid=\(self.sessionId?.prefix(8) ?? "nil"); abandon after \(ISHExecutionCoordinator.stopAbandonGrace)s if still running")
        }
        runningCommandPids.removeAll()
        commandStartTime = nil
    }

    func clearChat() {
        messages.removeAll()
        agentHistory.removeAll()
        toolSnapshots.removeAll()
        errorMessage = nil
        cachedLatestMarker = nil
        toolLoopDetector.reset()

        if let sessionId {
            Task { await ISHExecutionCoordinator.shared.sessionDidTerminate(sessionId: sessionId) }
            BrowserTabPool.deletePersistedData(for: sessionId)
            BrowserUseOffloadBridge.releasePool(forSession: sessionId)
            Task {
                await ChatStore.shared.deleteMessages(sessionId: sessionId)
                await ChatStore.shared.deleteCompactMarkers(sessionId: sessionId)
            }
        }
    }

}

// MARK: - Browser takeover screenshot [T-image-real-seams]

// BEGIN TakeoverScreenshotMessage
extension AIChatViewModel {
    /// The user message injected after a browser takeover: the screenshot is
    /// written next to browser_use's own (`browser/takeover_<timestamp>.jpg`,
    /// the original, for viewing and read_image) and carried as `.imageData` -
    /// [T-image-gate] ModelImageGate's output, like browser_use's image (it
    /// used to go out at full size). The caller stores the message (P-i4), so
    /// the note is a <system-reminder>: the stored row renders nothing on
    /// reload, as `isUserBubbleEntry` already treats it.
    static func takeoverScreenshotMessage(_ data: Data, sessionId: String?, timestamp: Int) -> AgentMessage {
        // Persist the takeover screenshot the same way browser_use
        // does so request-level budget elision can point the model
        // back at it via read_image.
        let screenshotFilename = "takeover_\(timestamp).jpg"
        let sid = sessionId ?? "unknown"
        let persistDir = Self.minisBrowserPersistentDir(for: sid)
        try? FileManager.default.createDirectory(at: persistDir, withIntermediateDirectories: true)
        let persistPath = persistDir.appendingPathComponent(screenshotFilename)
        try? data.write(to: persistPath)
        let linuxPath = "\(Self.minisBrowserLinuxDir)/\(screenshotFilename)"

        // Inject a user message with the takeover screenshot so the model sees the current state
        let takeoverNote = "<system-reminder>[Browser takeover] The user manually operated the browser. Here is a screenshot of the current browser state after their interaction.</system-reminder>"
        let gated = ModelImageGate.prepare(data, maxBytes: Self.rawBytesForBase64Budget(Self.kPerImageMaxBytes))
        return AgentMessage(role: .user, parts: [
            .text(takeoverNote),
            .imageData(data: gated.data ?? data, mimeType: gated.mimeType ?? "image/jpeg", linuxPath: linuxPath)
        ])
    }
}
// END TakeoverScreenshotMessage

// BEGIN BackgroundTurnOutcome
/// [T-bgnotif-outcome] How a turn ended, for its background notification and
/// Live Activity.
enum BackgroundTurnOutcome: Equatable, CustomStringConvertible {
    /// Reached its normal end.
    case completed
    /// Ended with an error on this turn's reply, or a turn-level error.
    case failed
    /// Did not finish and can be continued: background time ran out, it is
    /// resumable (`canResume`), or the user stopped it.
    case interrupted

    var description: String {
        switch self {
        case .completed: return "completed"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    /// Expiry wins over everything: the loop is still mid-run, so any error
    /// seen now may yet be retried away. Then a stated error, so a reply that
    /// failed (and is resumable too) is reported with its reason. Then the
    /// resumable / stopped states.
    static func decide(backgroundTimeExpired: Bool, turnError: String?, errorMessage: String?,
                       canResume: Bool, userStopped: Bool) -> BackgroundTurnOutcome {
        if backgroundTimeExpired { return .interrupted }
        if hasText(turnError) || hasText(errorMessage) { return .failed }
        if canResume || userStopped { return .interrupted }
        return .completed
    }

    /// Index of the current turn's last assistant row: the last assistant
    /// after the last row the user actually sent. Rows after it that are not
    /// assistants (queued user rows, status rows) are skipped, not treated as
    /// the end of the turn. With no sent row, the whole list is the turn.
    static func currentTurnAssistantIndex(count: Int, isSentUser: (Int) -> Bool,
                                          isAssistant: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        let start = (0..<count).last(where: isSentUser).map { $0 + 1 } ?? 0
        guard start < count else { return nil }
        return (start..<count).last(where: isAssistant)
    }

    private static func hasText(_ s: String?) -> Bool {
        !(s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
// END BackgroundTurnOutcome
