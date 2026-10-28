//
//  AIChatViewModel+PromptQueue.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, queued prompts: resuming the queue after a stop, starting
//  a drain when idle, draining after a loop ends, and injecting queued prompts
//  as a new turn (QueueInjection).
//
//  Map of the AIChatViewModel files: AIChatViewModel.swift.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {
    /// Resume queue processing after the user stopped the current task.
    /// Spawns a fresh Task (not cancelled) so the drain loop can call runAgentLoop().
    func resumeQueueAfterCancel() {
        // Small delay to let the cancelled task's error handler finish cleanup.
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait briefly for the previous task to complete cleanup
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            // [T-double-stop-empty-bubble] A second Stop inside this wait
            // cancelled us. `try?` swallowed that, so we used to carry on:
            // consume the second Stop's flag against the previous turn's row
            // (cleaning it twice) and drain the queue inside a cancelled task,
            // racing the drain the second Stop spawns. That Stop's cancel()
            // owns the handover now — leave everything to it.
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] queue-resume superseded by another Stop during the settle wait — handing over")
                return
            }
            self.handleUserCancelledCleanup()
            self.userDidCancel = false
            // [T-stop-with-queue-render-desync] handleUserCancelledCleanup (run
            // here or by the cancelled task's own catch) set canResume=true —
            // correct for a plain Stop, but this drain immediately continues the
            // conversation with the queued prompt, so the "Interrupted — tap
            // Resume" banner / ⏸ badge must not stay up over a live run. Clearing
            // it also lets the didSet replay any sync reload it deferred.
            self.canResume = false
            self.isProcessing = true
            self.beginBackgroundProcessing()
            logger.info("📨[DRAIN] Resuming queue in new task — \(self.promptQueue.count) prompt(s)")
            await self.drainQueuedPrompts()

            // [T-stop-with-queue-render-desync] A second Stop during this drained
            // run cancels THIS task and may spawn yet another drain task — same
            // handover as send()'s epilogue, so don't clobber its state either.
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] queue-resume epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }

            if let sid = self.sessionId {
                let dbMessages = await ChatStore.shared.loadMessages(sessionId: sid)
                self.lastKnownDbSortOrder = dbMessages.last?.sortOrder ?? self.lastKnownDbSortOrder
                self.lastKnownDbCount = dbMessages.count
                // T-baseline-hash-drift: see send DONE path for why hash
                // must be refreshed alongside count/sortOrder.
                self.lastKnownDbOrderHash = Self.computeOrderHash(of: dbMessages)
            }
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// [T-p0-programmatic-prompt] Start a drain when NO loop is running.
    ///
    /// The seven existing drain sites are all loop epilogues (send/retry/
    /// resume/orphan-tail/retryFromMessage/resumeQueueAfterCancel/post-compact)
    /// — there is no idle-time consumer. `submitProgrammaticPrompt` checks
    /// isProcessing and enqueues in one synchronous @MainActor step, which
    /// closes the classic check-then-act window, but a prompt can still be
    /// enqueued while `isProcessing` is true AFTER the epilogue's drain already
    /// returned (the epilogues await DB reads between the drain and the flip).
    /// The isProcessing didSet calls this on the flip; callers may also call it
    /// directly. Mirrors resumeQueueAfterCancel minus the cancel bookkeeping.
    func startDrainIfIdle(reason: String) {
        guard remoteDeviceId == nil else { return }
        guard !isProcessing, !isDrainingQueue, !isCompacting, !postCompactDrainPending else {
            logger.info("📨[DRAIN] startDrainIfIdle(\(reason)) skipped — isProcessing=\(self.isProcessing) draining=\(self.isDrainingQueue) compacting=\(self.isCompacting) postCompactPending=\(self.postCompactDrainPending)")
            return
        }
        guard !promptQueue.isEmpty else { return }
        logger.info("📨[DRAIN] startDrainIfIdle(\(reason)) — \(self.promptQueue.count) prompt(s), no loop running")
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.settlePendingStop(before: "startDrainIfIdle")
            self.userDidCancel = false
            self.canResume = false
            // Silent iff nothing a user typed is in this batch.
            let batch = self.promptQueue
            self.programmaticSilentTurn = !batch.isEmpty && batch.allSatisfy { self.silentQueuedPromptIds.contains($0.id) }
            self.silentQueuedPromptIds.subtract(batch.map(\.id))
            self.isProcessing = true
            self.beginBackgroundProcessing()
            await self.drainQueuedPrompts()
            // Same stop-handover rule as every other epilogue: a Stop during
            // the drained run hands state ownership to cancel().
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] idle-drain epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }
            if let sid = self.sessionId {
                let dbMessages = await ChatStore.shared.loadMessages(sessionId: sid)
                self.lastKnownDbSortOrder = dbMessages.last?.sortOrder ?? self.lastKnownDbSortOrder
                self.lastKnownDbCount = dbMessages.count
                self.lastKnownDbOrderHash = Self.computeOrderHash(of: dbMessages)
            }
            logger.info("📨[DRAIN] idle-drain DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// Drain any queued prompts after an agent loop finishes.
    /// Called from send(), retry(), resume(), and retryFromMessage() before setting isProcessing=false.
    /// Uses a while loop + final yield to catch prompts queued during the last streaming response.
    /// Reentrancy-guarded entry point. Only ONE drain may be active at a time:
    /// a Stop with queued prompts spawns a fresh resume Task whose drain races
    /// the superseded original Task's post-loop drain, and without this guard
    /// both would run the queued turn and double-fire the next request (every
    /// tool call + reply twice). The guard is set/cleared only on @MainActor so
    /// check-and-set is atomic and held across the inner `await runAgentLoop()`.
    /// [T-ios-concurrent-stop-double-request]
    /// `internal` (not `private`) so `compactAndSend` in the +Compaction
    /// extension file can drain through this same path after a compact.
    func drainQueuedPrompts() async {
        guard !self.isDrainingQueue else {
            logger.info("📨[DRAIN] Already draining in another task — skipping duplicate drain")
            // [T-queue-drain-handover] Remember the request. The task holding
            // the guard may be a stopped turn that is only unwinding (a drained
            // turn cancelled before its first token keeps waiting on HTTP); it
            // will not drain again, and the rescue on isProcessing → false was
            // blocked by the same guard — so the queued prompt sat until the
            // user's next send.
            self.drainRequestedWhileBusy = true
            return
        }
        self.isDrainingQueue = true
        defer {
            self.isDrainingQueue = false
            // [T-queue-drain-handover] Hand the skipped request on now that the
            // guard is free. startDrainIfIdle is a no-op while a loop still
            // runs (that loop's own epilogue / isProcessing rescue drains).
            if self.drainRequestedWhileBusy {
                self.drainRequestedWhileBusy = false
                if !self.promptQueue.isEmpty {
                    self.startDrainIfIdle(reason: "drain-handover")
                }
            }
        }
        await drainQueuedPromptsInner()
    }

    /// The actual drain loop. Unguarded so its own tail-recursion for late
    /// arrivals (below) doesn't trip the reentrancy guard — that guard only
    /// gates cross-Task duplicate entry, which all goes through the wrapper.
    private func drainQueuedPromptsInner() async {
        while !self.userDidCancel && !self.promptQueue.isEmpty {
            // If the Task itself is cancelled (e.g. user tapped stop), don't
            // consume queue items — resumeQueueAfterCancel() handles them
            // in a fresh Task.
            guard !Task.isCancelled else {
                logger.info("📨[DRAIN] Task cancelled — leaving \(self.promptQueue.count) prompt(s) in queue")
                break
            }
            // [T-scheduled-preempt] One take per turn: each scheduled job's fire
            // is its own turn (older piled-up fires of that job coalesced into
            // it); everything else still drains together as before.
            guard let take = self.planQueueTake(at: .turnEnd) else { break }
            let queued = self.removeQueueTake(take)
            guard !queued.isEmpty else { continue }
            let drainReminder = self.scheduledReminder(for: take, delivered: queued, at: .turnEnd)
            // [T-loop-reminder-scheduled-exempt] A scheduled fire's poll is an
            // expected repeat: don't let it count toward a loop warning.
            if take.scheduledJobId != nil { self.toolLoopDetector.exemptNextCallForScheduledFire() }
            logger.info("📨[DRAIN] Draining \(queued.count) queued prompt(s) (scheduled=\(take.scheduledJobId?.prefix(8) ?? "-") coalesced=\(take.coalesced.count))")
            // [T-mute-reset-on-drain] A queued prompt is a new turn. Stopping a
            // sub agent mutes the PARENT'S current turn (results delivered from
            // now on must not restart it); that mute used to be reset only by
            // send/retry/resume, so a prompt drained after the muted turn ended
            // broke out after its first tool round and was never answered.
            self.delegationResultsMuted = false

            let queuedIds = Set(queued.map(\.id))
            for msg in self.messages where msg.isQueued {
                if let pid = msg.queuedPromptId, queuedIds.contains(pid) {
                    // Queue drain: isQueued true -> false. The withdraw button
                    // disappears here, so the bubble's wrap width widens by
                    // ~28pt and any measurement taken while queued is
                    // superseded from this point on.
                    msg.isQueued = false
                    // [T-queued-bubble-height-after-drain] …and the row must be
                    // told: the flip re-renders it in place, so nothing else
                    // re-measures it and the queued (taller) frame is kept.
                    // Same targeted invalidate + reconfigure as an attachment
                    // mount; harmless when the row is not in the list.
                    NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: msg.id)
                }
            }
            self.scrollToBottomSignal.send()

            let sid = self.sessionId ?? "unknown"
            let uploadsDir = Self.minisUploadsDir(for: sid)
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime]
            let nowStr = isoFmt.string(from: Date())
            try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)

            var combinedParts: [AgentContentPart] = []
            var drainPastedParts: [String: [ContentPart]] = [:]
            for prompt in queued {
                if !prompt.attachments.isEmpty {
                    let (attParts, attMetas) = self.processAttachments(prompt.attachments, uploadsDir: uploadsDir, nowStr: nowStr)
                    combinedParts.append(contentsOf: attParts)
                    Self.cleanupAttachmentFiles(prompt.attachments)
                    if let chatMsg = self.messages.first(where: { $0.queuedPromptId == prompt.id }) {
                        chatMsg.attachments = attMetas
                        chatMsg.inputAttachments = []
                        // [T-ios-user-attach-mount-invalidate #182-followup] The
                        // mount above is an in-place +70pt/row content change on
                        // a cell whose item identity does not move; without this
                        // the tile-less height measured moments earlier stays
                        // cached and the bubble truncates (see the Name's doc).
                        NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: chatMsg.id)
                    }
                }
                if !prompt.text.isEmpty {
                    // [T-paste-single-split] Queued drafts consume their pasted
                    // literals at the same boundary send() does; files land on
                    // the ids planned at enqueue so the born-with cards stay
                    // valid ([T-paste-live-bubble-card]).
                    if let consumed = await self.consumePastedDraft(prompt.text, sessionId: sid,
                                                                   plannedFileIds: prompt.pastePlan) {
                        combinedParts.append(.text(consumed.modelText))
                        drainPastedParts[consumed.modelText] = consumed.storedParts
                        if let chatMsg = self.messages.first(where: { $0.queuedPromptId == prompt.id }) {
                            let extra = consumed.liveCardMetas.filter { meta in
                                !chatMsg.attachments.contains(where: { $0.path == meta.path })
                            }
                            if !extra.isEmpty {
                                chatMsg.attachments.append(contentsOf: extra)
                                NotificationCenter.default.post(name: .minisUserAttachmentsMounted,
                                                                object: chatMsg.id)
                            }
                        }
                    } else {
                        combinedParts.append(.text(prompt.text))
                    }
                }
            }

            if let drainReminder { combinedParts.append(.text(drainReminder)) }
            let queueAgentMsg = AgentMessage(role: .user, parts: combinedParts)
            let qIdx = self.agentHistory.count
            self.agentHistory.append(queueAgentMsg)
            // [T-edit-anchor-link] Every drained bubble links to the one entry.
            for msg in self.messages where msg.queuedPromptId.map(queuedIds.contains) == true {
                msg.historyAnchorId = queueAgentMsg.anchorId
            }
            if let pid = await self.persistAgentMessage(queueAgentMsg, pastedParts: drainPastedParts), qIdx < self.agentHistory.count {
                self.agentHistory[qIdx].dbMessageId = pid
            }

            do {
                try await self.runAgentLoop()
            } catch is CancellationError {
                logger.info("Agent loop (queued-drain) cancelled")
                self.finishStoppedTurn()
                // Don't consume remaining queue items — resumeQueueAfterCancel()
                // will pick them up in a fresh Task.
                break
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop (queued-drain) error: \(rawDesc)")
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
                    // [T-stream-empty-banner-trace] Diagnostic: log the
                    // messages-tail state when an agent-loop error
                    // surfaces so we can tell whether the placeholder
                    // assistant message survived the failure (bubble
                    // path) or got pruned beforehand (banner path).
                    // Catalyst users have reported the loading
                    // indicator flashing once and the error red banner
                    // appearing at the top of the chat with no
                    // placeholder bubble — that's the "else" branch
                    // below and it shouldn't happen if runAgentLoop's
                    // line 5124 placeholder is still in `messages`.
                    let lastRoleStr = self.messages.last.map { "\($0.role)" } ?? "nil"
                    let lastBlocks = self.messages.last?.blocks.count ?? -1
                    let lastErr = self.messages.last?.error ?? "nil"
                    let tail3 = self.messages.suffix(3).map { "\($0.role)(\($0.blocks.count)blk err=\($0.error ?? "nil"))" }.joined(separator: " > ")
                    AppLogger(category: "StreamError").error("[StreamError] catch displayDesc=\"\(displayDesc.prefix(120))\" msgCount=\(self.messages.count) lastRole=\(lastRoleStr) lastBlocks=\(lastBlocks) lastErr=\(lastErr) tail=\(tail3)")
                    // [T-ios-retry-tool-blocks-invisible / T-stream-empty-banner-trace]
                    // Resolve the streaming assistant by the last ASSISTANT row,
                    // not messages.last. A queued .user message (enqueuePrompt
                    // appends one mid-tool) sits AFTER the candidate, so
                    // messages.last would be that user row — the error then fell
                    // through to the top red banner (vm.errorMessage) instead of
                    // attaching to the assistant bubble. Same root cause as the
                    // Stop-loses-content fix.
                    if let last = self.messages.last(where: { $0.role == .assistant }) {
                        last.error = displayDesc
                        Task { await self.persistErrorInfo(displayDesc) }  // [T-error-persist-ios]
                        AppLogger(category: "StreamError").error("[StreamError] → bubble path (set last.error)")
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                        AppLogger(category: "StreamError").error("[StreamError] → banner path (carrier row + vm.errorMessage set)")
                    }
                }
                break
            }
        }

        // Yield once to let any last-moment enqueuePrompt() calls execute
        await Task.yield()
        if !Task.isCancelled && !self.userDidCancel && !self.promptQueue.isEmpty {
            logger.info("📨[DRAIN] Late arrivals after yield: \(self.promptQueue.count)")
            // Recurse on the INNER worker (we already hold the reentrancy guard)
            // so late-arrival handling isn't skipped by our own guard.
            await drainQueuedPromptsInner()
        }
    }

    /// [T-ios-queued-message-continues-prev-turn] Drain any prompts the user
    /// queued mid-run and append them as ONE standalone user turn, then start a
    /// fresh assistant message so the next loop iteration produces a dedicated
    /// response. Called ONLY from the agent loop's finish branch (after the
    /// current turn's tool loop has fully converged to a no-tool-use assistant
    /// reply), so the queued prompt never gets folded into a mid-loop tool_result
    /// (which made the model treat it as in-loop context for the previous turn).
    ///
    /// Returns true if a prompt was injected (caller should `continue` the loop
    /// instead of breaking). `msgIdx` / `committedBlockCount` are advanced to the
    /// new assistant message. The caller must have already persisted the just-
    /// finished assistant reply before calling this.
    /// [T-scheduled-preempt] What `injectQueuedPromptsAsNewTurn` delivered.
    enum QueueInjection: Equatable {
        case none
        /// The user's follow-up(s) (or anything else that is not a scheduled fire).
        case prompts
        /// One scheduled job's fire (plus any coalesced older fires).
        case scheduledFire
    }

    func injectQueuedPromptsAsNewTurn(
        msgIdx: inout Int,
        committedBlockCount: inout Int,
        turnUsage: TokenUsage,
        at point: QueueDeliveryPoint
    ) async -> QueueInjection {
        // [T-scheduled-preempt] One delivery = one take (QueueDeliveryPlanner):
        // a scheduled fire is its own turn, never merged with other prompts.
        guard let take = planQueueTake(at: point) else { return .none }
        let queued = removeQueueTake(take)
        guard !queued.isEmpty else { return .none }
        let reminder = scheduledReminder(for: take, delivered: queued, at: point)
        // Mark corresponding chat messages as no longer queued (remove dashed border + X)
        let queuedIds = Set(queued.map(\.id))
        for msg in messages where msg.isQueued {
            if let pid = msg.queuedPromptId, queuedIds.contains(pid) {
                msg.isQueued = false
                // [T-queued-bubble-height-after-drain] Re-measure the row at
                // its sent width (see the idle drain above).
                NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: msg.id)
            }
        }

        // Build combined parts from all queued prompts (text + attachments)
        let qSid = sessionId ?? "unknown"
        let qUploadsDir = Self.minisUploadsDir(for: qSid)
        let qIsoFormatter = ISO8601DateFormatter()
        qIsoFormatter.formatOptions = [.withInternetDateTime]
        let qNowStr = qIsoFormatter.string(from: Date())
        try? FileManager.default.createDirectory(at: qUploadsDir, withIntermediateDirectories: true)

        var qCombinedParts: [AgentContentPart] = []
        var qPastedParts: [String: [ContentPart]] = [:]
        for prompt in queued {
            if !prompt.attachments.isEmpty {
                let (attParts, attMetas) = processAttachments(prompt.attachments, uploadsDir: qUploadsDir, nowStr: qNowStr)
                qCombinedParts.append(contentsOf: attParts)
                Self.cleanupAttachmentFiles(prompt.attachments)
                // Update the corresponding ChatMessage so attachment thumbnails appear in the UI
                if let chatMsg = messages.first(where: { $0.queuedPromptId == prompt.id }) {
                    chatMsg.attachments = attMetas
                    chatMsg.inputAttachments = []
                    // [T-ios-user-attach-mount-invalidate] See the sibling drain site.
                    NotificationCenter.default.post(name: .minisUserAttachmentsMounted, object: chatMsg.id)
                }
            }
            if !prompt.text.isEmpty {
                // [T-paste-single-split] Same boundary consumption as send();
                // files land on the enqueue-planned ids ([T-paste-live-bubble-card]).
                if let consumed = await consumePastedDraft(prompt.text, sessionId: qSid,
                                                           plannedFileIds: prompt.pastePlan) {
                    qCombinedParts.append(.text(consumed.modelText))
                    qPastedParts[consumed.modelText] = consumed.storedParts
                    if let chatMsg = messages.first(where: { $0.queuedPromptId == prompt.id }) {
                        let extra = consumed.liveCardMetas.filter { meta in
                            !chatMsg.attachments.contains(where: { $0.path == meta.path })
                        }
                        if !extra.isEmpty {
                            chatMsg.attachments.append(contentsOf: extra)
                            NotificationCenter.default.post(name: .minisUserAttachmentsMounted,
                                                            object: chatMsg.id)
                        }
                    }
                } else {
                    qCombinedParts.append(.text(prompt.text))
                }
            }
        }

        // Guard: if every queued prompt was empty (no text, no attachments) the
        // combined parts are empty — an empty user message is a 400. Skip.
        guard !qCombinedParts.isEmpty else {
            logger.warning("injectQueuedPromptsAsNewTurn: \(queued.count) queued prompt(s) produced no content, skipping")
            return .none
        }
        // [T-scheduled-preempt] The reminder rides AFTER the envelope as its own
        // text part: the preset matcher keys off the envelope part, and the chat
        // strips <system-reminder> from user rows, so the card is unchanged.
        if let reminder { qCombinedParts.append(.text(reminder)) }

        // [T-ios-queued-message-interrupt-on-toolclose] Interrupting mid-tool-
        // loop (right after a tool call closed) leaves the agentHistory tail at
        // user(tool_result). The queued message used to be preceded by an
        // assistant "bridge" row so the two user turns would not be merged
        // (#579). [T-bridge-to-reminder] That row taught the model to write the
        // bridge sentence itself at the end of a turn, where it rendered and
        // was persisted as one more example. Now the note rides at the end of
        // the queued message as a <system-reminder> the model reads but does
        // not imitate, and the chat strips from user rows. The tool_result row
        // is untouched; Anthropic merges the two user rows (tool_result first),
        // OpenAI-style APIs send tool → user. A scheduled fire already carries
        // its own reminder (`scheduledReminder`, which says to resume).
        // Only for this interrupt: at a turn end the tail is an assistant reply.
        if agentHistory.last?.role == .user, take.scheduledJobId == nil {
            qCombinedParts.append(.text(RawMessage.queuedInterruptReminderText))
        }

        let queueMsg = AgentMessage(role: .user, parts: qCombinedParts)
        let queueIdx = agentHistory.count
        agentHistory.append(queueMsg)
        // [T-edit-anchor-link] Every injected bubble links to the one entry.
        for msg in messages where msg.queuedPromptId.map(queuedIds.contains) == true {
            msg.historyAnchorId = queueMsg.anchorId
        }
        if let pid = await persistAgentMessage(queueMsg, snapshots: [:], pastedParts: qPastedParts), queueIdx < agentHistory.count {
            agentHistory[queueIdx].dbMessageId = pid
        }
        // Cache markdown on the completed assistant message before starting a new one
        if msgIdx < messages.count {
            for i in messages[msgIdx].blocks.indices {
                if case .text = messages[msgIdx].blocks[i].kind, !messages[msgIdx].blocks[i].content.isEmpty {
                    messages[msgIdx].blocks[i].cachedMarkdown = MarkdownContent(prepareMarkdownForRender(messages[msgIdx].blocks[i].content))
                    cacheAttributedString(for: messages[msgIdx].blocks[i])
                }
            }
            // Clear "thinking" indicator + store usage on the just-finished assistant message
            messages[msgIdx].isAwaitingModelResponse = false
            messages[msgIdx].usage = turnUsage
            publishContextUsage()
            // [T-usage-capsule-time] Stamped with the usage, not before: this
            // is the moment the turn is declared finished, and the capsule
            // that shows the usage shows this clock beside it.
            messages[msgIdx].completedAt = Date()
        }
        // [T-mute-reset-on-drain] The queued prompt injected here starts a new
        // turn inside this loop: a sub-agent stop's mute was for the turn that
        // just ended, not for the user's queued message.
        delegationResultsMuted = false
        // Start a new assistant message so the next response appears below the queued user message
        messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
        msgIdx = messages.count - 1
        committedBlockCount = 0
        self.committedBlockCount = 0
        self.prevCommittedBlockCount = 0   // [T-double-stop-empty-bubble] fresh bubble
        scrollToBottomSignal.send()
        logger.info("Injected \(queued.count) queued prompt(s) as new turn after tool loop, new msgIdx=\(msgIdx) point=\(point) scheduled=\(take.scheduledJobId?.prefix(8) ?? "-")")
        // [T-loop-reminder-scheduled-exempt] Same as the idle drain.
        if take.scheduledJobId != nil { toolLoopDetector.exemptNextCallForScheduledFire() }
        return take.scheduledJobId != nil ? .scheduledFire : .prompts
    }
}
