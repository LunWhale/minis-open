//
//  AIChatViewModel+AgentLoop.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, the agent loop: runAgentLoop / runAgentLoopCore - build
//  the request, stream the reply, run tools, feed results back and repeat
//  until the model stops - plus clearing an uncommitted stream tail and the
//  tool-fold hooks around each request.
//
//  runAgentLoopCore is a single ~2,000-line function; splitting it further
//  needs real refactoring, not a move.
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
    // MARK: - Agent Loop

    /// Clear ONLY the uncommitted streaming tail of an assistant message after a
    /// mid-stream failure, preserving every block already committed+persisted in
    /// an earlier round of the same loop. [T-ios-stream-retry-text-disappear]
    ///
    /// Blocks at index `[0, committedBlockCount)` are the committed prefix (text
    /// and terminal tool results from prior rounds, already in the DB) and are
    /// kept verbatim. From `committedBlockCount` onward we drop the in-flight
    /// failed stream: text blocks (partial output that the retry will re-stream)
    /// and tool blocks stuck in `.streaming` / `.running` (which would otherwise
    /// stay orphaned in the UI, never reaching a terminal state). A completed
    /// tool block in the tail (rare) is left alone so its result still shows.
    @MainActor
    static func clearUncommittedStreamTail(_ message: ChatMessage, committedBlockCount: Int) {
        let lowerBound = max(0, min(committedBlockCount, message.blocks.count))
        guard lowerBound < message.blocks.count else { return }
        var kept = Array(message.blocks[0..<lowerBound])
        for block in message.blocks[lowerBound...] {
            if block.kind == .text { continue }
            // [T-dup-thinking-block] Drop uncommitted thinking blocks — not persisted, retry stream will regenerate them.
            if block.kind == .thinking { continue }
            if case .streaming = block.toolStatus { continue }
            if case .running = block.toolStatus { continue }
            kept.append(block)
        }
        message.blocks = kept
    }

    /// [T-fold-at-request-end] A request is about to start for `messageId`.
    /// The first one of this loop for that message makes it the running
    /// message, and whatever it already holds (a resumed or retried turn)
    /// counts as finished content: its last block becomes a separator, so
    /// runs folded before the loop do not open up again.
    private func noteToolFoldRequestStarting(messageId: UUID) {
        guard toolFoldRunningMessageId != messageId else { return }
        toolFoldRunningMessageId = messageId
        if let last = messages.first(where: { $0.id == messageId })?.blocks.last {
            toolFoldSeparators[messageId, default: []].insert(last.id)
        }
    }

    /// [T-fold-at-request-end] One request of the running task just finished
    /// streaming (its stop reason is known; its tool calls have not run yet).
    /// If the text it produced — all its text blocks, not only the last — has
    /// at least `ToolFoldPlanner.separatorMinimumLines` lines, its last block
    /// becomes a fold separator and the message list re-plans. This is the
    /// only mid-task fold trigger: nothing folds per token or per filled block.
    private func noteToolFoldRequestEnded(messageId: UUID, startBlockIds: Set<UUID>) {
        guard ToolFoldPlanner.isEnabled,
              let message = messages.first(where: { $0.id == messageId }),
              let lastBlock = message.blocks.last,
              !startBlockIds.contains(lastBlock.id) else { return }
        let text = message.blocks
            .filter { !startBlockIds.contains($0.id) && $0.kind == .text }
            .map(\.content)
            .joined(separator: "\n")
        guard ToolFoldPlanner.isFoldSeparator(requestText: text) else { return }
        toolFoldSeparators[messageId, default: []].insert(lastBlock.id)
        toolFoldSeparatorSignal.send(messageId)
    }

    func runAgentLoop(resumingAt existingMsgIdx: Int? = nil, committedBlocks: Int? = nil) async throws {
        do {
            try await runAgentLoopCore(resumingAt: existingMsgIdx, committedBlocks: committedBlocks)
        } catch {
            // [T-ctx-measure-outbound] A context-length rejection is the one
            // ground truth that our size estimate was too low (a borrowed ratio
            // after a model switch, a stale one on a legacy session, content the
            // estimator under-reads). Raise the ratio so the retry / next send
            // compacts instead of being rejected again, then surface the error
            // exactly as before.
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            noteContextOverflow(errorText: text, modelId: nil)
            throw error
        }
    }

    private func runAgentLoopCore(resumingAt existingMsgIdx: Int? = nil, committedBlocks: Int? = nil) async throws {
        // REPRO-DIAG(2026-05-16): bump global round counter and emit a clear
        // BEGIN/END marker so the user can grep `ROUND \d+` to slice the log
        // by attempt. A "round" = one runAgentLoop invocation, which is
        // triggered by a new user message send or a retry.
        let _diagRound = Self.bumpDiagRound()
        AppLogger(category: "RoundMarker").warning("══════════════ ROUND BEGIN \(_diagRound) ══════════════ vm=\(self.vmInstanceId) session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) resuming=\(existingMsgIdx != nil)")
        defer { AppLogger(category: "RoundMarker").warning("══════════════ ROUND END \(_diagRound) ════════════════ vm=\(self.vmInstanceId) session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) estimated ~\(self.estimateContextTokens()) tokens") }
        logger.info("🔄SESSION [vm=\(self.vmInstanceId)] runAgentLoop START session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) resuming=\(existingMsgIdx != nil)")
        defer { logger.info("🔄SESSION [vm=\(self.vmInstanceId)] runAgentLoop END session=\(self.sessionId ?? "nil") history=\(self.agentHistory.count) estimated ~\(self.estimateContextTokens()) tokens") }
        // [T-retry-log-sheet] A fresh run starts an empty retry log; a resume
        // continues the interrupted run's. The log is dropped when the run
        // ends (finished, failed or stopped), so the marker goes with it.
        let retryKey = retryLogKey
        if existingMsgIdx == nil { RetryLogStore.shared.beginRun(key: retryKey) }
        defer {
            RetryLogStore.shared.endRun(key: retryKey)
            // A draft that got its session id mid-run recorded under the new
            // key; drop that log too so no marker outlives the run.
            if retryLogKey != retryKey { RetryLogStore.shared.endRun(key: retryLogKey) }
        }

        let loopSetupStart = CFAbsoluteTimeGetCurrent()
        // [T-scheduled-preempt] Set when a scheduled fire was inserted at a tool
        // gap of THIS loop. If the model then answers it and stops while the
        // interrupted task is unfinished, one hidden resume nudge is sent.
        var scheduledResumeNudgeOwed = false

        // [T-ios-stale-error-banner] Every turn funnels through here — a send, a
        // retry, a Resume, a queued prompt draining, and the auto-fallback that
        // re-enters after a provider error. Sweeping here is what covers the
        // reported case, which none of the entry-point clears could: a rate
        // limit on one model appended a carrier row, the fallback recovered on
        // the next model, and the loop carried on with the red card frozen
        // mid-transcript above the successful output.
        //
        // Safe to run unconditionally at the TOP of the loop: any error this
        // turn produces is attached later, by the epilogues below.
        clearSupersededErrors(reason: "agent-loop-start",
                              keeping: existingMsgIdx.flatMap { messages.indices.contains($0) ? messages[$0] : nil })

        // [T-ios-empty-after-toolresult-reminder] Fresh turn → allow one reminder retry.
        didInjectEmptyToolReminderThisRun = false

        // [T-ios-switch-model-next-request] A switch flagged during an earlier
        // turn is reflected in the entry resolved just below; don't re-apply
        // it. This reset must come BEFORE that resolve: a switch landing
        // during the `await makeAgentProvider` below sets the flag again, and
        // clearing it after the await would run the whole turn on the old
        // model.
        pendingModelSwitch = false

        // Resolve provider from ProviderConfigStore
        guard let entry = resolveCurrentEntry() else {
            let errMsg = ChatMessage(role: .assistant, content: "", blocks: [])
            errMsg.error = AppLocalized("No model configured. Add a provider in Settings.")
            messages.append(errMsg)
            return
        }
        var provider = await makeAgentProvider(for: entry)

        // Set extended cache TTL globally for Anthropic request patching
        RequestBodyPatcher.setExtendedCacheTTL(self.enhancedCacheEnabled)

        // [T-gemini-signature-restore] Signatures are applied inside
        // `makeAgentProvider`, so every provider this loop builds (initial,
        // group fallback, mid-stream failover, model switch during a retry
        // countdown) gets them — not just this first one. The map is NOT
        // cleared here: it is the session's record and later providers need it.

        var activeGroupId: String?  // non-nil when using a group (enables fallback)
        var activeEntryId: String? = entry.id

        // Check if this entry came from a group binding
        if let sid = sessionId,
           let binding = ProviderConfigStore.shared.binding(for: sid),
           case .group(let gid, _) = binding.primarySource {
            activeGroupId = gid
        }

        // When resolved via cachedSessionModelId (no binding at all — e.g. an
        // iCloud-synced session whose binding row didn't sync), the entry may
        // still belong to the default group. Enable fallback by discovering
        // the group. Deliberately NOT applied when a .directEntry binding
        // exists: that is an explicit user pin, and enabling group fallback
        // would both switch models behind the user's back and overwrite the
        // pin with a group binding on fallback success.
        if activeGroupId == nil,
           sessionId.flatMap({ ProviderConfigStore.shared.binding(for: $0) }) == nil {
            let store = ProviderConfigStore.shared
            if let gid = store.defaultPrimaryGroupId,
               let group = store.group(for: gid),
               group.memberEntryIds.contains(entry.id) {
                activeGroupId = gid
            }
        }
        // [T-user-ask] Decide user_ask exposure once for the run (tool list
        // and system prompt read the same answer).
        let userAskDecision = computeUserAskExposure()
        userAskExposedThisRun = userAskDecision.exposed
        userAskDeferredThisRun = userAskDecision.deferred
        userAskAskedThisRun = false  // [T-user-ask-fallback]
        logger.info("[UserAsk] exposure=\(userAskDecision.exposed) deferred=\(userAskDecision.deferred) reason=\(userAskDecision.reason)")
        var tools = makeAgentTools()
        var helperWrapUpInjected = false
        // [T-user-ask-fallback] The text-ask nudge was sent in this run (once).
        var textAskNudgeSent = false
        // [T-subagent-turn-countdown] Fired once, a few rounds before the cliff.
        var helperTurnWarningInjected = false
        // [T-subagent-termination] The closing request was sent in this run (once).
        var helperClosingNudgeSent = false

        var userSystemPrompt = baseSystemPrompt
        // `var` for [T-ios-switch-model-next-request]: a mid-turn model switch
        // replaces it so the next request carries the new model's limits.
        var activeModel = ProviderConfigStore.shared.entry(for: entry.id)?.model ?? selectedModel
        if let capFragment = activeModel.capabilityPromptFragment {
            userSystemPrompt += "\n\n" + capFragment
        }
        if let behaviorFragment = activeModel.agentBehaviorPromptFragment {
            userSystemPrompt += "\n\n" + behaviorFragment
        }

        // Inject enabled skill metadata into system prompt
        // [T-p1-delegate-task] A helper inherits the PARENT session's skill
        // and MCP enablement (the user configured those for the conversation
        // that spawned it; the child session has no overrides of its own).
        if let sid = helperConfig?.parentSessionId ?? sessionId,
           let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
            userSystemPrompt += "\n\n" + skillFragment
        }

        // [T-mcp-integration-ios] Inject Top-20 enabled MCP server metadata.
        if let sid = helperConfig?.parentSessionId ?? sessionId,
           let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
            userSystemPrompt += "\n\n" + mcpFragment
        }

        // [T-memory-toggle-gates-injection-and-tools-ios] Memory injection
        // (GLOBAL.md + recent daily logs) is gated by the per-session
        // memoryEnabled toggle. SOUL.md (identity / persona) is rendered
        // by SystemPromptBuilder.identitySection() above and is NOT
        // affected by this toggle.
        // [T-memory-enabled-new-session-bug DIAG] vm.memoryEnabled is the
        // value the injection actually keys off. Trace it against the
        // session so a repro shows whether loadSession seeded it from the
        // global default.
        AppLogger(category: "MemDiag").info("[MemDiag] inject-decision sid=\(self.sessionId?.prefix(8) ?? "nil") vm.memoryEnabled=\(self.memoryEnabled)")
        if memoryEnabled {
            if let memoryFragment = Self.loadGlobalMemoryFragment() {
                userSystemPrompt += "\n\n" + memoryFragment
            }
            if let dailyFragment = Self.loadRecentDailyMemoryFragment() {
                userSystemPrompt += "\n\n" + dailyFragment
            }
        }
        // Authoritative memory-status footer (overrides any earlier
        // baseSystemPrompt mentions when memory is disabled).
        userSystemPrompt += memoryStatusFragment

        let promptBuildMs = (CFAbsoluteTimeGetCurrent() - loopSetupStart) * 1000
        logger.info("⏱️ [runAgentLoop] prompt build elapsed=\(String(format: "%.1f", promptBuildMs))ms history=\(self.agentHistory.count)")
        await Task.yield()

        // When resuming after error, reuse the existing assistant message; otherwise create new
        var msgIdx: Int
        if let existingMsgIdx {
            msgIdx = existingMsgIdx
            let okBounds = existingMsgIdx >= 0 && existingMsgIdx < messages.count
            let role = okBounds ? (messages[existingMsgIdx].role == .assistant ? "assistant" : "user") : "OOB"
            let blocks = okBounds ? messages[existingMsgIdx].blocks.count : -1
            AppLogger(category: "RetryDiag").info("[RetryDiag] runAgentLoop RESUME existingMsgIdx=\(existingMsgIdx) role=\(role) blocks=\(blocks) committedBlocks=\(committedBlocks ?? -1) messagesCount=\(self.messages.count)")
        } else {
            messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
            msgIdx = messages.count - 1
        }
        // Capture the assistant message's stable id so we can re-find it
        // when the `messages` array gets mutated mid-stream (user delete,
        // reloadMessagesFromDB rebuild, compactBefore removeAll, etc.). On
        // any retry / fallback catch path we resync `msgIdx` via this id
        // before touching `messages[msgIdx]`; if the message is gone we
        // bail out cleanly instead of crashing with Index out of range.
        var runMsgId: UUID = msgIdx < messages.count ? messages[msgIdx].id : UUID()
        // [T-fold-at-request-end] A new loop: no running message until its
        // first request, and none once it ends, however it ends.
        toolFoldRunningMessageId = nil
        toolFoldSeparators.removeAll()
        defer {
            toolFoldRunningMessageId = nil
            toolFoldSeparators.removeAll()
        }
        /// Track how many blocks were already committed to agentHistory
        /// so subsequent iterations only add new blocks.
        var committedBlockCount = committedBlocks ?? 0
        self.committedBlockCount = committedBlockCount
        // [T-double-stop-empty-bubble] A fresh bubble has no earlier iteration,
        // so the rollback mark must start at 0 too. It is only written when an
        // iteration commits, and only send() reset it, so a turn started from
        // the queue (drain after Stop, queued-drain) inherited the previous
        // turn's value. Stopped before its first token, that stale value > 0
        // kept handleUserCancelledCleanup out of its "drop the empty
        // placeholder" case: the empty bubble stayed on screen, and the
        // rollback branch it fell into removed the previous turn's committed
        // reply from agentHistory. A resumed row keeps its mark.
        if existingMsgIdx == nil {
            self.prevCommittedBlockCount = 0
        }
        var turnUsage = TokenUsage()

        // Log context baseline for offload diagnostics
        let estimatedTokens = estimateContextTokens()
        logger.info("📐 Context baseline: agentHistory=\(self.agentHistory.count) msgs, estimated ~\(estimatedTokens) tokens, turnUsage.latestContextTokens=\(turnUsage.latestContextTokens) (model window: \(ProviderConfigStore.shared.entry(for: entry.id)?.model.contextWindowTokens ?? 0))")

        // Safety: scan the entire agentHistory for assistant messages with tool_use
        // that lack corresponding tool_result messages. This can happen when:
        // - User cancelled mid-tool-execution and cleanup missed an entry
        // - Session was restored from persistence with incomplete state
        // - A race condition between cancel cleanup and retry left orphaned tool_uses
        //
        // IMPORTANT: skip injection when the assistant message was stream-interrupted.
        // A mid-stream network drop leaves tool_use blocks with empty/partial inputs
        // (partialJson never completed). Injecting a tool_result for such a tool_use
        // causes API 400 "unexpected tool_use_id" or "invalid input" errors.
        // Instead, the interrupted assistant message is dropped so the model retries
        // cleanly from the previous user/tool_result turn.
        //
        // First handle the last message specially (may need to be dropped entirely if interrupted).
        if let lastAssistant = agentHistory.last, lastAssistant.role == .assistant, lastAssistant.isInterrupted {
            agentHistory.removeLast()
            logger.warning("Dropped interrupted assistant message with partial tool_use(s) — will retry from previous turn")
        }

        // [T-ios-retry-orphan-toolresult] Snapshot the pairing as runAgentLoop
        // sees it on entry — BEFORE the orphan-removal below mutates anything.
        // If this shows ORPHANS, the entry came in already-broken (the cut /
        // a prior cancel / merged-render reorder stranded a tool_result); the
        // removal pass is only papering over it. Compare against subcut-AFTER.
        dumpHistoryPairing("runAgentLoop-entry (pre-orphan-scan)")
        await Task.yield()

        // Now scan ALL messages for orphaned tool_uses and orphaned tool_results.
        // Build sets of all tool_use IDs and tool_result IDs.
        var allToolUseIds = Set<String>()
        var allToolResultIds = Set<String>()
        // [T-responses-tool-id-normalize] Pair on the same key the wire uses —
        // the Responses path carries "<call_id>|<fc_id>" and matches on the
        // call_id half. Comparing raw ids here could both MISS a real orphan
        // and, worse, delete a correctly paired tool_result whose sibling
        // happens to carry the other id form.
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolUse(let id, _, _, _) = part {
                    allToolUseIds.insert(Self.pairingKey(id))
                }
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part {
                    allToolResultIds.insert(Self.pairingKey(id))
                }
            }
        }

        // 1. Remove orphaned tool_results (tool_result without matching tool_use).
        //    These cause API 400: "unexpected tool_use_id found in tool_result blocks".
        var removedOrphanedResults = 0
        for i in (0..<agentHistory.count).reversed() {
            let msg = agentHistory[i]
            guard msg.role == .user else { continue }
            let beforeCount = msg.parts.count
            let cleanedParts = msg.parts.filter { part in
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part {
                    if !allToolUseIds.contains(Self.pairingKey(id)) {
                        logger.warning("Removing orphaned tool_result id=\(id) at history[\(i)]")
                        removedOrphanedResults += 1
                        return false
                    }
                }
                return true
            }
            if cleanedParts.count < beforeCount {
                if cleanedParts.isEmpty {
                    // All parts were orphaned tool_results — remove entire message
                    agentHistory.remove(at: i)
                } else {
                    agentHistory[i].parts = cleanedParts  // [T-history-rebuild-keeps-ids] keep dbMessageId
                }
            }
        }
        if removedOrphanedResults > 0 {
            logger.warning("Removed \(removedOrphanedResults) orphaned tool_result(s) without matching tool_use")
        }

        // 2. Inject placeholder tool_results for orphaned tool_uses (tool_use without matching tool_result).
        // Rebuild allToolResultIds after removals above.
        allToolResultIds.removeAll()
        for msg in agentHistory {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part {
                    allToolResultIds.insert(Self.pairingKey(id))
                }
            }
        }

        var insertions: [(index: Int, message: AgentMessage)] = []
        for (i, msg) in agentHistory.enumerated() {
            guard msg.role == .assistant else { continue }
            let orphanedToolUses = msg.parts.compactMap { part -> (String, String)? in
                if case .toolUse(let id, let name, _, _) = part, !allToolResultIds.contains(Self.pairingKey(id)) {
                    return (id, name)
                }
                return nil
            }
            guard !orphanedToolUses.isEmpty else { continue }

            let insertIdx = i + 1
            let placeholderParts = orphanedToolUses.map { (id, name) in
                AgentContentPart.toolResult(
                    id: id, name: name,
                    content: "Tool execution was interrupted by an unexpected error.",
                    isError: true
                )
            }
            let placeholderMsg = AgentMessage(role: .user, parts: placeholderParts)
            insertions.append((index: insertIdx, message: placeholderMsg))
            logger.warning("Found \(orphanedToolUses.count) orphaned tool_use(s) in assistant message at index \(i)")
        }
        for insertion in insertions.reversed() {
            agentHistory.insert(insertion.message, at: insertion.index)
        }
        if !insertions.isEmpty {
            logger.warning("Injected placeholder tool results for \(insertions.count) assistant message(s) with orphaned tool_use(s)")
        }

        let orphanScanMs = (CFAbsoluteTimeGetCurrent() - loopSetupStart) * 1000
        logger.info("⏱️ [runAgentLoop] setup complete elapsed=\(String(format: "%.1f", orphanScanMs))ms (prompt+orphanScan)")
        await Task.yield()

        // Counted instead of `while true` so we have a hard backstop against
        // runaway tool loops that slip past ToolLoopDetector. The post-loop
        // tail uses `hitTurnLimit` (not `turnCount >= maxAgentTurns`) to
        // distinguish "exhausted the ceiling" from any internal `break`:
        // the defer below increments turnCount on *every* iteration end,
        // including breaks, so a value-based check would false-positive
        // when the happy-path break fires on the last allowed iteration.
        // hitTurnLimit stays true only when the while-condition itself
        // becomes false, never set false by any break path.
        var turnCount = 0
        var hitTurnLimit = true
        // [T-chat-auto-compact-inloop] Count in-loop auto-compactions so a loop
        // that keeps hitting the threshold can't compact forever; when the cap
        // is reached and we're still near capacity, the loop stops as exhausted.
        var compactionsThisLoop = 0
        // [T-ctx-measure-outbound] Set when an in-loop compaction left the
        // outbound request no smaller; cleared when a response arrives (new
        // content may make the next compaction worthwhile again).
        var lastInLoopCompactionMadeNoProgress = false
        // [T-ctx-valve-retry-keeps-spent] The valve is deliberately NOT reset
        // here. A provider rejection spends it (noteContextOverflow) but is
        // recorded after the loop has ended, so resetting at the next loop's
        // start — i.e. the user's Retry — threw that away and re-sent the
        // exact request just rejected. It is re-armed only by evidence: an
        // accepted response below, or a different session's calibration.
        // [T-p1-delegate-task] Helpers get a much tighter ceiling (design §4.3).
        let turnCap = helperConfig?.maxTurns ?? Self.maxAgentTurns
        loopLabel: while turnCount < turnCap {
            defer { turnCount += 1 }
            // [T-ios-switch-model-next-request] The user picked another model
            // while this turn was running. Apply it HERE, before the next
            // request — the stream / tool call that was in flight when they
            // switched finished on the old model, undisturbed.
            //
            // Keyed off the explicit flag, not "the binding changed": group
            // fallback also rewrites the binding on success, and must not be
            // mistaken for a user switch (that would yank the turn back off
            // the fallback entry it just moved to).
            if pendingModelSwitch {
                pendingModelSwitch = false
                if let newEntry = resolveCurrentEntry(), newEntry.id != activeEntryId {
                    let oldEntryId = activeEntryId
                    let promptModel = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")?.model ?? activeModel
                    provider = await makeAgentProvider(for: newEntry)
                    activeEntryId = newEntry.id
                    activeGroupId = nil
                    if let sid = sessionId,
                       let binding = ProviderConfigStore.shared.binding(for: sid),
                       case .group(let gid, _) = binding.primarySource {
                        activeGroupId = gid
                    }
                    activeModel = newEntry.model
                    // Swap only the model-specific fragments. They always sit
                    // right after the base prompt (both the setup code and the
                    // fallback rebuild add them first), so replacing that
                    // prefix leaves skills / MCP / memory untouched.
                    let oldPrefix = baseSystemPrompt + Self.modelPromptFragments(promptModel)
                    if userSystemPrompt.hasPrefix(oldPrefix) {
                        userSystemPrompt = baseSystemPrompt + Self.modelPromptFragments(newEntry.model)
                            + String(userSystemPrompt.dropFirst(oldPrefix.count))
                    } else {
                        logger.warning("🔀 model switch: system prompt prefix did not match — kept previous model fragments")
                    }
                    noteEffectiveEntry(activeEntryId)
                    logger.info("🔀 model switch applied at next request: \(oldEntryId ?? "nil") → \(newEntry.id) turn=\(turnCount + 1)")
                }
            }
            // [T-agent-wrapup-turn] A helper that reaches its last permitted
            // round (or whose budget the parent has called time on) must not
            // end on a tool call: the parent only ever receives the child's
            // final TEXT, and a run that stopped mid-tool returned "(no final
            // text)", pushing the parent to dig through the child transcript
            // itself. Take the tools away for this one turn and ask for the
            // deliverable, the way a person would say "time's up, write it up".
            if helperConfig != nil, !helperWrapUpInjected,
               helperWrapUpRequested || turnCount == turnCap - 1 {
                helperWrapUpInjected = true
                tools = []
                let note = Self.helperWrapUpPrompt(reason: helperWrapUpRequested ? .budget : .turns)
                if let lastIdx = agentHistory.indices.last, agentHistory[lastIdx].role == .user {
                    agentHistory[lastIdx].parts.append(.text(note))
                } else {
                    agentHistory.append(AgentMessage(role: .user, parts: [.text(note)]))
                }
                logger.info("[delegate_task] wrap-up turn injected reason=\(helperWrapUpRequested ? "budget" : "turns") turn=\(turnCount + 1)/\(turnCap)")
            }
            // [T-subagent-turn-countdown] Warn BEFORE the tools are gone.
            //
            // The wrap-up block above is a cliff: it fires on the last round
            // with tools already withdrawn, so a child that spent its budget
            // investigating learns it is out of rounds at the exact moment it
            // can no longer write anything. That is the reported failure — "it
            // could only reply with a message, it could not save the file".
            // The cap is intentional; being ambushed by it is not.
            //
            // So hand it the one fact it cannot work out for itself: how many
            // rounds remain. Tools still work on this turn, which is what makes
            // the warning actionable rather than an epitaph. Skipped once the
            // wrap-up has fired — the count is zero then and the wrap-up says
            // so more forcefully.
            if helperConfig != nil, !helperWrapUpInjected, !helperTurnWarningInjected {
                let remaining = turnCap - 1 - turnCount
                // `Self.`: on iOS these live on AIChatViewModel (HelperRunner.swift is
                // an extension of it, not a type, unlike the Android object).
                if remaining >= 1, remaining <= Self.turnWarningLead {
                    helperTurnWarningInjected = true
                    let note = Self.turnBudgetWarning(remaining: remaining)
                    if let lastIdx = agentHistory.indices.last, agentHistory[lastIdx].role == .user {
                        agentHistory[lastIdx].parts.append(.text(note))
                    } else {
                        agentHistory.append(AgentMessage(role: .user, parts: [.text(note)]))
                    }
                    logger.info("[subagent_task] turn budget warning injected remaining=\(remaining) turn=\(turnCount + 1)/\(turnCap)")
                }
            }
            // [T-sub-agents-steer] Deliver any course corrections the parent
            // queued while this turn's predecessor was running. Same shape as
            // the wrap-up injection above: appended to the pending user message
            // so it costs no extra turn, and read at a loop boundary so the
            // tool call that was in flight completed normally.
            //
            // After the wrap-up block on purpose: if both land on the same
            // turn, the child sees the steer first and the "write it up now"
            // instruction last, which is the order that keeps the deliverable.
            if helperConfig != nil, !pendingSteerMessages.isEmpty {
                let steers = pendingSteerMessages
                pendingSteerMessages.removeAll()
                let note = steers
                    .map { "[Course correction from the delegating agent] \($0)" }
                    .joined(separator: "\n")
                // [T-subagent-steer-visible] Persist it as a real user message
                // in the CHILD's own transcript, then let the normal history
                // path carry it — instead of only appending to `agentHistory`.
                //
                // A steer is the parent doing what a person does when they
                // interject mid-task, so it belongs in the conversation the
                // same way. Appended to `agentHistory` alone it reached the
                // model and nothing else: opening the sub agent's transcript
                // showed it changing direction with nothing to explain why,
                // and a relaunch (which rebuilds `agentHistory` from the DB)
                // lost the instruction outright.
                //
                // Written as its own message rather than folded into the
                // preceding one, so it keeps its own row, timestamp and cell.
                let steerMsg = AgentMessage(role: .user, parts: [.text(note)])
                let steerIdx = agentHistory.count
                agentHistory.append(steerMsg)
                let uiMsg = ChatMessage(role: .user, content: note)
                uiMsg.historyAnchorId = steerMsg.anchorId  // [T-edit-anchor-link]
                // Insert BEFORE the assistant message this turn is streaming
                // into, not at the end. `runAgentLoop` appends that assistant
                // bubble before the loop starts, so `messages` already ends
                // with it — appending put the correction visually AFTER the
                // reply it was meant to steer, at the very bottom of the
                // transcript, reading as though it arrived too late to matter.
                // It belongs where a person's interjection would go: above the
                // turn that answers it.
                let insertAt = (msgIdx >= 0 && msgIdx <= messages.count) ? msgIdx : messages.count
                messages.insert(uiMsg, at: insertAt)
                // The assistant message this loop writes into just shifted down
                // by one. Not adjusted by hand: the LOOP-RESYNC guard a few
                // lines below already re-finds it by `runMsgId` on exactly this
                // condition (`messages[msgIdx].id != runMsgId`) and runs in the
                // same iteration. Incrementing here too would move the index
                // past the message and leave the resync nothing wrong to fix.
                if let raw = await buildRawMessage(steerMsg) {
                    await ChatStore.shared.appendMessages([raw])
                    if steerIdx < agentHistory.count {
                        agentHistory[steerIdx].dbMessageId = raw.id
                    }
                }
                logger.info("[subagent_task] steer delivered count=\(steers.count) turn=\(turnCount + 1)/\(turnCap)")
            }
            // [LoopHeartbeat] (#181) One line per loop iteration. If the loop
            // wedges on an await, the last heartbeat pins which iteration it
            // died in, even when every other diagnostic is missing.
            logger.info("[LoopHeartbeat] turnCount=\(turnCount) session=\(self.sessionId ?? "nil") time=\(Self.diagTimestamp(Date()))")
            try Task.checkCancellation()
            if let sid = self.sessionId {
                SessionActivityTracker.shared.updateLoopIteration(sid, iteration: turnCount + 1)
            }

            // [T-ios-inloop-compact-freeze] Re-anchor msgIdx by stable id every
            // iteration. External mutations while the loop runs — in-loop
            // compaction's divider insert / status-row removeAll, a mid-loop
            // reloadMessagesFromDB wholesale rebuild, user delete — shift or
            // replace array members; a raw index (or a bail-out `break`) then
            // silently streams every later round into the wrong / a detached
            // ChatMessage: the UI freezes on the last rendered block while the
            // DB keeps advancing (field case 2026-07-31, sessions 35D4D2B2 /
            // 7FDC5B52: vm froze at sortOrder≈130 while DB reached 138).
            if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-RESYNC msgIdx \(msgIdx)→\(resynced) after external messages mutation (count=\(messages.count))")
                    msgIdx = resynced
                } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    // Array was rebuilt with fresh instances (reload) — adopt the
                    // trailing assistant message, which the rebuild reconstructed
                    // from the same rows this loop already persisted. Everything
                    // it now holds came from the DB, so it is all committed.
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-REBIND msgIdx \(msgIdx)→\(lastIdx) — streaming message instance gone, adopting trailing assistant (count=\(messages.count))")
                    msgIdx = lastIdx
                    runMsgId = messages[lastIdx].id
                    committedBlockCount = messages[lastIdx].blocks.count
                    self.committedBlockCount = committedBlockCount
                } else {
                    // No trailing assistant to adopt — append a fresh one so the
                    // rest of the turn stays visible instead of streaming into a
                    // detached object.
                    AppLogger(category: "BlocksLost").warning("[BlocksLost] LOOP-REAPPEND — streaming message gone and no trailing assistant (count=\(messages.count)); appending fresh assistant message")
                    messages.append(ChatMessage(role: .assistant, content: "", blocks: []))
                    msgIdx = messages.count - 1
                    runMsgId = messages[msgIdx].id
                    committedBlockCount = 0
                    self.committedBlockCount = 0
                    self.prevCommittedBlockCount = 0   // [T-double-stop-empty-bubble] fresh bubble
                }
            }

            // Trim old images: keep only the most recent `kImageContextKeepCount`
            // images in history; older ones become text placeholders so the model
            // can re-view them via read_image. Runs before token-based offload so
            // image bytes are removed first.
            trimOldImagesFromHistory()

            // [T-ctx-measure-outbound] The system prompt and tool schemas ride
            // on every request; measure them exactly for this iteration (they
            // can change mid-loop, e.g. the helper wrap-up path) so the guards
            // below and the calibration pair see the real fixed share.
            contextFixedTokens = ContextSizeMeter.estimateFixedTokens(systemPrompt: userSystemPrompt, tools: tools)
            // [T-ctx-count-reasoning] Ask the provider that will send this
            // request whether past reasoning rides along; refreshed every
            // iteration because a group fallback can swap the provider.
            contextEchoesReasoning = provider.echoesReasoningContent(thinkingLevel: currentThinkingLevel)
            contextProviderMaxOutput = provider.defaultMaxTokens

            // Context window management: offload old tool content if approaching limit
            let activeModelForOffload = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")?.model ?? selectedModel
            // [T-ctx-measure-outbound] Judged on the outbound measurement, not
            // `turnUsage.latestContextTokens`: after an in-loop compaction that
            // report still describes the pre-compaction request.
            offloadContextIfNeeded(model: activeModelForOffload, lastContextTokens: measureOutboundContextTokens())

            // [T-chat-auto-compact-inloop] In-loop context guard. checkContext-
            // BeforeSend only runs at the SEND entry point; a single turn that
            // fans out into many tool iterations can blow past the compact/
            // exhausted thresholds mid-loop, where offload alone (which only
            // moves tool payloads to files) can't recover if the bulk is the
            // model's own text. Re-evaluate the policy each iteration, AFTER
            // offload had its chance:
            //   • .needsCompact → compact in place (allowDuringProcessing) and
            //     continue; the next API call reads the freshly-compacted
            //     effectiveAgentHistory() automatically, so no resume handoff.
            //   • .exhausted (compaction couldn't get us under the ceiling) →
            //     stop the loop with a resumable, user-visible notice; the loop
            //     cannot present a modal and wait for a tap.
            // Turn-budget rule: a compaction iteration is a space-management
            // step, NOT a task iteration, so it must NOT consume a turnCount
            // slot (`continue` runs the defer, so we pre-decrement to cancel
            // it) — but the overall maxAgentTurns ceiling is NEVER reset by a
            // compaction, or a loop that keeps compacting could run forever and
            // defeat the runaway backstop.
            // [T-ctx-trim-ladder] Trim first - no model call: empty old
            // reasoning, offload, skeleton, each only as far as needed.
            // Collapsing whole iterations waits until a model summary had its
            // chance, unless none is available here. Only when the trimmed
            // request is still over the line does the switch below compact.
            let inLoopCompactAvailable = contextPolicyAllowsAutoCompact()
                && compactionsThisLoop < Self.maxInLoopCompactions && !lastInLoopCompactionMadeNoProgress
            replanTrim(site: "in-loop", allowCollapse: !inLoopCompactAvailable)
            var inLoopVerdict = checkContextBeforeSend(site: "in-loop")
            // [T-ctx-trim-escalate] The ladder without collapse has little left
            // to give: go to the next level now (collapse-first or a summary)
            // instead of re-planning every few requests just under the line.
            if inLoopVerdict == .ok, inLoopCompactAvailable, lastTrimPlanEscalates {
                logger.info("[ctx-trim] the re-plan recovered too little without collapse - escalating to the compaction branch")
                inLoopVerdict = .needsCompact
            }
            lastTrimPlanEscalates = false
            if !inLoopCompactAvailable, trimmedOverHard() {
                // Over the hard line by the calibrated size AND the raw
                // estimate: no ratio can be blamed, nothing is left to try.
                logger.warning("[ctx-trim] trimmed request still over the hard watermark - stopping (context full)")
                inLoopVerdict = .exhausted
            }
            switch inLoopVerdict {
            case .ok:
                break
            case .needsCompact:
                let compactAnchorId = messages.last(where: {
                    $0.role != .compactDivider && $0.role != .systemInfo && !$0.isCompactedHistory
                })?.id
                // [T-ctx-measure-outbound] A compaction that did not shrink the
                // outbound request is not retried: the loop used to spend its
                // whole budget re-compacting when the SIZE it judged by was the
                // thing that was wrong. Only real progress earns another pass.
                if compactionsThisLoop < Self.maxInLoopCompactions,
                   !lastInLoopCompactionMadeNoProgress,
                   let anchorId = compactAnchorId {
                    // [T-ctx-trim-collapse-first] Collapse first when a summary
                    // could not pay for its model call (one long user turn is
                    // itself the slice a compaction keeps); compact only if
                    // that is not enough.
                    if summaryWouldFreeLittle(measured: measureOutboundContextTokens()) {
                        trimReplanPending = true
                        replanTrim(site: "collapse-first", allowCollapse: true)
                        if checkContextBeforeSend(site: "collapse-first") == .ok {
                            logger.info("[Context] In-loop: collapse brought the request back under the compaction line - no summary needed")
                            break
                        }
                    }
                    compactionsThisLoop += 1
                    let sizeBefore = measureOutboundContextTokens()
                    logger.info("[Context] In-loop near capacity — auto-compacting (\(compactionsThisLoop)/\(Self.maxInLoopCompactions)) turnCount=\(turnCount) measured=\(sizeBefore)")
                    let markerBefore = cachedLatestMarker?.id
                    await compactBefore(anchorId, allowDuringProcessing: true)
                    // [T-ctx-trim-ladder] Bring what the summary kept down to
                    // the target; with no summary (the compaction failed)
                    // collapse is the only thing left, so it is allowed too.
                    trimReplanPending = true
                    replanTrim(site: cachedLatestMarker?.id == markerBefore ? "compact-failed" : "after-compact",
                               allowCollapse: true)
                    let sizeAfter = measureOutboundContextTokens()
                    lastInLoopCompactionMadeNoProgress = sizeAfter >= sizeBefore
                    logger.info("[Context] In-loop compact result: measured \(sizeBefore) → \(sizeAfter)\(lastInLoopCompactionMadeNoProgress ? " (no progress — will not retry)" : "")")

                    // [T-ios-inloop-compact-divider-order] GH#235. Seal the
                    // bubble this run has been writing into and continue in a
                    // FRESH one below the divider.
                    //
                    // `compactBefore` inserts the divider immediately AFTER the
                    // anchor row and greys everything up to it. In the in-loop
                    // case the anchor resolves to `messages.last(active)` —
                    // which is this run's own still-streaming assistant bubble.
                    // So without this, the loop `continue`s and keeps appending
                    // thinking / tool blocks into a bubble that now sits ABOVE
                    // the divider and is flagged `isCompactedHistory`: new
                    // output appears greyed out inside the "already compacted"
                    // region, in the wrong chronological place. That is exactly
                    // the reported symptom.
                    //
                    // Starting a new bubble (rather than moving the divider) is
                    // what matches the user's mental model: everything produced
                    // before the compaction really is pre-compaction history,
                    // and everything after it belongs below the line. It also
                    // keeps `compactBefore` untouched — the user-initiated
                    // "Compact Above" path anchors on a finished message and is
                    // already correct.
                    //
                    // The sealed bubble keeps whatever it had; if it never
                    // produced anything (compaction fired before the first
                    // block landed) it would render as an empty grey row, so
                    // drop it in that case.
                    if let sealedIdx = messages.firstIndex(where: { $0.id == runMsgId }) {
                        let sealed = messages[sealedIdx]
                        sealed.isAwaitingModelResponse = false
                        if sealed.blocks.isEmpty && sealed.content.isEmpty {
                            messages.remove(at: sealedIdx)
                            logger.info("[Context] In-loop compact: dropped empty sealed bubble at \(sealedIdx)")
                        }
                    }
                    let fresh = ChatMessage(role: .assistant, content: "", blocks: [])
                    fresh.isAwaitingModelResponse = true
                    messages.append(fresh)
                    msgIdx = messages.count - 1
                    runMsgId = fresh.id
                    // Blocks already committed belong to the sealed bubble; the
                    // fresh one starts from zero or the next round would skip
                    // its first N blocks when syncing to agentHistory.
                    committedBlockCount = 0
                    self.committedBlockCount = 0
                    self.prevCommittedBlockCount = 0   // [T-double-stop-empty-bubble] fresh bubble
                    logger.info("[Context] In-loop compact: continuing in fresh bubble idx=\(msgIdx) id=\(runMsgId.uuidString.prefix(8)) below the divider")

                    turnCount -= 1   // cancel this iteration's defer increment
                    continue
                }
                // [T-ctx-measure-outbound] Compaction has done all it can. Being
                // above the compact THRESHOLD is not a reason to abandon the
                // turn — that line leaves headroom by design — so send while the
                // request still fits the window, and only stop when it does not.
                let settle = settleWithoutCompacting()
                if settle.step == .sendWithinWindow {
                    logger.info("[Context] In-loop above compact threshold after \(compactionsThisLoop) compaction(s) but within the window — sending")
                    break
                }
                // [T-ctx-measure-outbound] "Over the window" here can be an
                // extrapolation: the calibrated size is estimate × a ratio
                // learned on OTHER content (or borrowed from another model).
                // Stopping on it alone could wedge the session for good — no
                // request goes out, so nothing ever corrects the ratio, and it is
                // re-seeded on reload. So if the uncalibrated estimate fits, send
                // once and let the provider decide: a success recalibrates, a
                // rejection raises the ratio (noteContextOverflow) and the next
                // stop is then backed by the provider's own count.
                if settle.step == .sendUncalibratedOnce {
                    sentPastExtrapolatedLimitThisLoop = true
                    logger.warning("[Context] In-loop: calibrated size is over the window but the raw estimate fits (\(settle.measurement.history + settle.measurement.fixed)) — sending once for the provider to decide (ratio=\(String(format: "%.2f", settle.measurement.ratio)))")
                    break
                }
                logger.info("[Context] In-loop still over the window after \(compactionsThisLoop) compaction(s) — stopping loop as exhausted")
                fallthrough
            case .exhausted:
                logger.info("[Context] In-loop exhausted — stopping loop with resumable notice (turnCount=\(turnCount))")
                let contextFull = AppLocalized("Context is full and could not be compacted further. Start a new session or clear the chat to continue.")
                appendSystemInfo(contextFull, icon: "exclamationmark.triangle")
                // [T-bgnotif-outcome] Record the reason on this turn's reply too,
                // so the bubble and the background notification agree that the
                // turn did not complete. The stop itself is unchanged.
                if let reply = currentTurnAssistantMessage(), reply.error == nil {
                    reply.error = contextFull
                    Task { await self.persistErrorInfo(contextFull) }
                }
                canResume = true
                hitTurnLimit = false
                break loopLabel
            }

            CrashReporter.shared.setLastAPI(provider: provider.name, model: activeModelForOffload.id)
            logger.info("Calling \(provider.name) API (streaming) with \(self.agentHistory.count) messages")
            // [StreamDiag] (#181) Monotonic request sequence, so a
            // [StreamDiag][STALL] line can be matched against the request it
            // belongs to — or shown to belong to none, which would mean the
            // request never went out (candidate 1).
            Self.diagRequestSeq &+= 1
            let diagReqSeq = Self.diagRequestSeq
            logger.info("[StreamDiag] req#\(diagReqSeq) DISPATCH turnCount=\(turnCount) session=\(self.sessionId ?? "nil") provider=\(provider.name) model=\(activeModelForOffload.id) messages=\(self.agentHistory.count) at=\(Self.diagTimestamp(Date()))")

            #if DEBUG
            // Begin a new agent request trace
            AgentRequestTrace.shared.begin()
            AgentRequestTrace.shared.step("agentLoop.start", detail: "provider=\(provider.name) messages=\(agentHistory.count)")

            // Log agent history summary for debugging tool result delivery.
            // [T-ios-log-noise-reduction] The full dump ran on every agent-loop
            // API call, re-printing the entire (growing) history each iteration
            // — the single biggest Debug-log noise source (~13.6k lines). The
            // structured AgentRequestTrace still records every entry (cheap,
            // in-memory, not NSLog), but the NSLog `📋 agentHistory[i]` line now
            // only fires for entries NEW since the last dump (delta), preceded
            // by a one-line summary. `lastDumpedAgentHistoryCount` resets to 0
            // whenever the history shrinks (retry truncation / new session) so
            // the next dump re-prints from the cut point.
            if agentHistory.count < lastDumpedAgentHistoryCount {
                lastDumpedAgentHistoryCount = 0
            }
            let deltaStart = lastDumpedAgentHistoryCount
            logger.debug("📋 agentHistory dump: total=\(agentHistory.count) newSince=\(deltaStart)")
            for (i, msg) in agentHistory.enumerated() {
                var partSummaries: [String] = []
                for part in msg.parts {
                    switch part {
                    case .text(let t):
                        let preview = String(t.prefix(200))
                        partSummaries.append("text(\(t.count)ch): \"\(preview)\(t.count > 200 ? "..." : "")\"")
                    case .toolUse(let id, let name, _, _):
                        // Anthropic ids start with the literal 8-char prefix
                        // `toolu_01`, so `prefix(8)` collapses every Anthropic
                        // tool_use to the same string in the trace and masks
                        // real id differences between parallel tool_uses
                        // (T-ios-concurrent-toolcall-dup-id). Use prefix(20)
                        // so concurrent calls are visibly distinct.
                        partSummaries.append("tool_use(\(name), id:\(id.prefix(20)))")
                    case .toolResult(let id, let name, let content, let isError, let imgData, _, _, _, _):
                        let head = String(content.prefix(200))
                        let tail = content.count > 400 ? String(content.suffix(200)) : ""
                        let errTag = isError ? " [ERROR]" : ""
                        let imgTag = imgData != nil ? " [IMG]" : ""
                        // Same prefix(20) as the .toolUse branch above — see note there.
                        partSummaries.append("tool_result(\(name), id:\(id.prefix(20)), \(content.count)ch\(errTag)\(imgTag)): head=\"\(head)\(content.count > 200 ? "..." : "")\"" + (tail.isEmpty ? "" : " tail=\"...\(tail)\""))
                    case .imageData(_, let mime, _):
                        partSummaries.append("image(\(mime))")
                    }
                }
                AgentRequestTrace.shared.step("agentHistory[\(i)]", detail: "\(msg.role.rawValue): \(partSummaries.joined(separator: " | "))")
                if i >= deltaStart {
                    logger.debug("📋 agentHistory[\(i)] \(msg.role.rawValue): \(partSummaries.joined(separator: " | "))")
                }
            }
            lastDumpedAgentHistoryCount = agentHistory.count
            #endif

            #if DEBUG
            let iterationStart = Date()
            var iterationUsage = TokenUsage()
            AgentRequestTrace.shared.step("streamAgentMessage.call", detail: "maxTokens=\(provider.defaultMaxTokens)")
            #endif
            let iterationStreamStart = Date()
            let prevEntryId = activeEntryId
            fallbackReasons.removeAll()
            // Phase B: route through effectiveAgentHistory() so compact summary is
            // synthesized at inference time instead of baked into agentHistory.
            var contextHistory = effectiveAgentHistory()
            // [T-longctx-persona-reminder-cachebreak] Past ~100k tokens,
            // remind the model that the user's SOUL.md / GLOBAL.md rules at
            // the head of the system prompt still apply (issue #37).
            //
            // This used to rewrite the outbound copy's LAST message on every
            // round, which broke the prompt cache (the "last message" differs
            // each round, so already-cached history kept changing) and fused
            // the reminder onto tool_result content (a file_read looked like
            // it carried an injected tag). Now it is APPENDED to agentHistory
            // as its own persisted message, at most once per
            // `kPersonaReminderRearmTokens` of context growth — earlier bytes
            // are never touched, so the cache prefix still hits.
            if personaReminderIsDue(contextTokens: turnUsage.latestContextTokens) {
                appendPersonaReminderToHistory(contextTokens: turnUsage.latestContextTokens)
                contextHistory = effectiveAgentHistory()
                logger.info("[PersonaReminder] appended at ~\(turnUsage.latestContextTokens) ctx tokens (agentHistory.count=\(self.agentHistory.count))")
            }
            // [T-queued-callback-reminder] A finished sub agent's result is
            // queued (deferUntilIdle) and will only arrive at the turn end;
            // tell the model on this request so it can choose to wrap up.
            // Request copy only — agentHistory / messages are untouched, so
            // it is never persisted or shown. The jobs are marked reminded
            // once the stream opens (below), so a request that fails before
            // that lists them again, with the same text, on its retry.
            var queuedCallbackReminderIds: [UUID] = []
            do {
                let pendingCallbacks = QueuedCallbackReminder.pending(queuedCallbackReminderCandidates())
                if let reminder = QueuedCallbackReminder.text(for: pendingCallbacks) {
                    let jobs = pendingCallbacks.map { $0.jobId.prefix(8) }.joined(separator: ",")
                    if let withReminder = Self.historyAppendingRequestReminder(reminder, to: contextHistory) {
                        contextHistory = withReminder
                        queuedCallbackReminderIds = pendingCallbacks.map(\.promptId)
                        logger.info("[CallbackReminder] injected jobs=[\(jobs)] queue=\(self.promptQueue.count)")
                    } else {
                        logger.warning("[CallbackReminder] SKIPPED jobs=[\(jobs)] — request tail is not a user/tool_result turn (role=\(contextHistory.last?.role.rawValue ?? "nil"))")
                    }
                }
            }
            // [T-request-imgsize-primary-path] Apply the request-level image
            // budget HERE, on the primary request.
            //
            // It was previously applied only on the empty-response retry and
            // the two group-fallback paths — every one of which runs AFTER a
            // request has already failed. The request that actually carries the
            // conversation was never budgeted, so a session that accumulated
            // enough screenshots / read_image results went out at full size and
            // the provider rejected it with request_too_large; the fallback
            // attempts then budgeted correctly but were pointed at the same
            // oversized history, so every model in the group failed in turn.
            // Present since the original port (74661a2eb), which wired up the
            // three fallback call sites and missed this one. Android's mirror
            // (ChatViewModel.kt) has always applied it at its single send site.
            // [T-ctx-measure-outbound] Record our estimate of THIS request so the
            // provider's count for it can calibrate the meter, and size
            // `max_tokens` from it. Taken before the image budget, like every
            // other measurement, so estimate and calibration stay comparable.
            let dispatchInputTokens = recordContextDispatch(history: contextHistory, model: activeModel)
            logger.info("[CtxMeter] dispatch model=\(activeModel.id) estimate=\(self.lastDispatchEstimate) ratio=\(String(format: "%.3f", self.lastDispatchRatio)) predicted=\(dispatchInputTokens) maxTokens=\(self.dynamicMaxTokens(provider: provider, model: activeModel, lastContextTokens: dispatchInputTokens))")
            contextHistory = applyRequestImageBudget(contextHistory)
            // [T-msgidx-oob] Re-resync before subscripting. The loop-top resync
            // (~line 4698) is not sufficient for this site: the in-loop
            // compaction guard above runs `await compactBefore(...)` in between,
            // and compaction deliberately mutates `messages` (removeAll of
            // status/divider rows, insert of the new divider) — so by the time
            // we build this request the index can be stale or point at a
            // different row. Cheap no-op on the overwhelmingly common path
            // (index valid + id matches).
            if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                    logger.error("🔀STREAM round-start: assistant message id=\(runMsgId) vanished (count=\(messages.count)) — aborting round")
                    throw LLMError.transientError(message: "The assistant message was removed while preparing the request.")
                }
                logger.warning("🔀STREAM round-start: msgIdx resynced → \(resynced) (count=\(messages.count))")
                msgIdx = resynced
            }
            // [T-fold-at-request-end] The blocks already there before this
            // request; whatever is new at its end is what it produced (each
            // request starts a fresh text block, so its text never lands in
            // an older one).
            let foldRequestStartBlockIds = Set(messages[msgIdx].blocks.map(\.id))
            noteToolFoldRequestStarting(messageId: runMsgId)
            // [T-scheduled-preset-tool] A scheduled fire with a preset first
            // step answers its own envelope with a local stream carrying that
            // tool call instead of a model request; everything downstream
            // (card, tool_use commit, execution, tool_result) is the normal
            // path, and the next iteration is the only model request.
            let stream: AsyncThrowingStream<AgentStreamEvent, Error>
            if let preset = takePresetToolStream(tools: tools) {
                stream = preset
            } else {
                stream = try await streamWithGroupFallback(
                    provider: provider,
                    messages: contextHistory,
                    baseSystemPrompt: baseSystemPrompt,
                    systemPrompt: userSystemPrompt,
                    tools: tools,
                    model: activeModel,
                    lastContextTokens: dispatchInputTokens,
                    chatMessage: messages[msgIdx],
                    activeGroupId: &activeGroupId,
                    activeEntryId: &activeEntryId
                )
                // [T-queued-callback-reminder] Dispatched: these jobs have
                // now been mentioned once and are not listed again.
                if !queuedCallbackReminderIds.isEmpty {
                    markQueuedCallbacksReminded(queuedCallbackReminderIds)
                    logger.info("[CallbackReminder] marked \(queuedCallbackReminderIds.count) queued callback(s) reminded")
                }
            }
            // [T-agent-model-identity] activeEntryId is now the entry this
            // turn is served on (group fallback inside the call above may
            // have moved it) — record it before any event is consumed.
            noteEffectiveEntry(activeEntryId)
            // [StreamDiag] (#181) The stream object now exists. Note this is
            // "request accepted / stream handle obtained", NOT first byte — the
            // first actual SSE event is logged by [StreamDiag] event #1 in
            // processStreamEvents. If a stall is logged with a DISPATCH and this
            // line but no event #1, the connection produced no first byte; if
            // event #1 appeared and it stalled later, the stream died mid-flight.
            logger.info("[StreamDiag] req#\(diagReqSeq) STREAM-OPEN elapsed=\(String(format: "%.2f", Date().timeIntervalSince(iterationStreamStart)))s at=\(Self.diagTimestamp(Date()))")

            // Helper: update provider & system prompt when fallback switched entries.
            // Returns true if a switch occurred.
            @discardableResult
            func applyFallbackSwitch() async -> Bool {
                noteEffectiveEntry(activeEntryId)
                guard activeEntryId != prevEntryId, let newEntryId = activeEntryId,
                      let newEntry = ProviderConfigStore.shared.entry(for: newEntryId) else {
                    return false
                }
                logger.info("🔀AGENT_LOOP provider updated after fallback: \(prevEntryId ?? "nil") → \(newEntryId)")
                provider = await makeAgentProvider(for: newEntry)
                // [T-provider-live-check] The limits follow the member now in
                // use. This stayed on the model the run started with, which
                // may since have been removed with its provider.
                activeModel = newEntry.model
                userSystemPrompt = baseSystemPrompt
                if let capFragment = newEntry.model.capabilityPromptFragment {
                    userSystemPrompt += "\n\n" + capFragment
                }
                if let behaviorFragment = newEntry.model.agentBehaviorPromptFragment {
                    userSystemPrompt += "\n\n" + behaviorFragment
                }
                // [T-ios-helper-fallback-parent-skills] Same key as the setup
                // path: a helper uses its PARENT's skill / MCP enablement.
                // Keying on the child id here made a sub-agent that fell back
                // lose the parent's skills and MCP servers mid-run.
                if let sid = helperConfig?.parentSessionId ?? sessionId,
                   let skillFragment = SkillStore.shared.skillPromptFragment(for: sid) {
                    userSystemPrompt += "\n\n" + skillFragment
                }
                // [T-mcp-integration-ios] Inject Top-20 enabled MCP metadata.
                if let sid = helperConfig?.parentSessionId ?? sessionId,
                   let mcpFragment = MCPStore.shared.systemPromptSnippet(for: sid) {
                    userSystemPrompt += "\n\n" + mcpFragment
                }
                // [T-memory-toggle-gates-injection-and-tools-ios] Mirror
                // the gate from the first injection site — fallback to a
                // new provider must respect the per-session memoryEnabled
                // toggle the same way the initial system prompt did.
                if memoryEnabled {
                    if let memoryFragment = Self.loadGlobalMemoryFragment() {
                        userSystemPrompt += "\n\n" + memoryFragment
                    }
                    if let dailyFragment = Self.loadRecentDailyMemoryFragment() {
                        userSystemPrompt += "\n\n" + dailyFragment
                    }
                }
                userSystemPrompt += memoryStatusFragment
                fallbackTrigger += 1
                if !fallbackReasons.isEmpty {
                    // Resync the assistant message index by its stable id before
                    // mutating `messages`. applyFallbackSwitch performs several
                    // awaits above (makeAgentProvider, fragment loads), during
                    // which a concurrent path (user delete, reloadMessagesFromDB,
                    // compactBefore, session switch) may have shrunk the array —
                    // the captured `msgIdx` then points past the end and the raw
                    // `messages[msgIdx]` subscript traps with "Index out of range"
                    // (crash on AsyncRenderer-adjacent path, AIChatViewModel.swift
                    // 2855). Every other messages[msgIdx] write in this loop already
                    // resyncs-or-guards; this site was the lone unguarded one
                    // (T-ios-fallback-switch-msgidx-oob). If the message is gone,
                    // skip the notice — it's a non-critical UI hint.
                    if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                        msgIdx = resynced
                        let trailLines = fallbackReasons.map { "⚠️ \($0.model) (\($0.instance)): \($0.reason)" }
                        let instanceLabel = ProviderConfigStore.shared.instance(for: newEntry.providerInstanceId)?.label ?? newEntry.model.provider
                        let noticeText = trailLines.joined(separator: "\n") + "\n" + AppLocalized("Switched to \(newEntry.model.displayName) (\(instanceLabel))")
                        let infoBlock = AssistantBlock(kind: .info, content: noticeText)
                        messages[msgIdx].blocks.insert(infoBlock, at: 0)
                        // [T-retry-log-sheet] The switch already has an open
                        // stream on the new model, so it is a success; earlier
                        // pending rows settle when that reply completes.
                        if let first = fallbackReasons.first {
                            RetryLogStore.shared.record(RetryLogEvent(
                                kind: .modelSwitch,
                                reason: fallbackReasons.map(\.reason).joined(separator: "; "),
                                model: "\(first.model) (\(first.instance))",
                                switchedTo: "\(newEntry.model.displayName) (\(instanceLabel))",
                                outcome: .succeeded
                            ), key: retryLogKey)
                        }
                        fallbackReasons.removeAll()
                    } else {
                        logger.error("🔀AGENT_LOOP applyFallbackSwitch: assistant message id=\(runMsgId) no longer in messages (count=\(self.messages.count)) — skipping fallback notice")
                        fallbackReasons.removeAll()
                    }
                }
                return true
            }

            await applyFallbackSwitch()
            scrollToBottomSignal.send()

            // Helper: check if a StreamResult is empty (no content produced).
            // Catches both the nil-stopReason path (Anthropic SSE error inside
            // HTTP 200) and the endTurn-with-zero-output path (OpenAI gpt-5.5
            // on long contexts: `finish_reason=stop` with no text/tool/reasoning).
            func isEmptyResponse(_ r: StreamResult) -> Bool {
                // [T-ios-reasoning-only-empty-turn] A turn that produced ONLY
                // reasoning — no text, no tool call — and then stopped is not a
                // legitimate turn, it is a stall the user sees as "the run just
                // ended".
                //
                // `!hasReasoning` was added by 5af31fe21 so "reasoning-only
                // legitimate turns still pass", and that case is real: with
                // interleaved thinking the model emits a reasoning block and
                // then CALLS A TOOL, so the turn continues. What distinguishes
                // it is the stop reason — `.toolUse` means the loop goes on and
                // the reasoning was a prelude to work. `.endTurn` (or a nil
                // stop) with nothing but reasoning means the model finished
                // while owing an answer, which is exactly the GPT-5.6 Terra /
                // Codex OAuth failure reported after a sub-agent callback: one
                // round of empty reasoning, stop, no text, no tool call.
                //
                // So the reasoning exemption now applies only to a turn that
                // actually continues. Keeping it any broader let the
                // pathological case skip the empty-response classifier
                // entirely: no reminder, no transient retry, no group
                // fallback — the turn was treated as a SUCCESS and the run
                // silently ended.
                //
                // [T-ios-tooluse-stop-no-entries] The `.toolUse` exemption is
                // gone too. Tool entries are appended while the stream runs
                // (at each tool block's end, see processStreamEvents), so by
                // the time this runs a turn that really called a tool already
                // has a non-empty `toolEntries` and is not empty anyway. The
                // exemption therefore only ever matched `.toolUse` with ZERO
                // entries — e.g. a proxy whose tool_call deltas lack `index`
                // are skipped but `finish_reason` still says tool_calls — and
                // that turn then fell into `guard !toolEntries.isEmpty` and
                // ended the run silently, while the same shape without
                // reasoning was retried.
                return r.assistantText.isEmpty && r.toolEntries.isEmpty
                    && !r.isStreamInterrupted
                    && r.stopReason != .maxTokens
                    // A refusal (Anthropic safety classifier decline) is deterministic:
                    // the content is empty but retrying the identical request just gets
                    // declined again and burns tokens. Don't route it through the
                    // transient-retry / group-fallback path; let the .refusal branch in
                    // the stop-reason handler surface it directly. [T-ios-fable5-empty-response]
                    && r.stopReason != .refusal
            }

            // Process SSE stream events on a background thread to keep
            // CFNetwork HTTP/2 HPACK decoding off the main RunLoop.
            // If a retryable error (transient 5xx / network) occurs mid-stream,
            // retry the entire request via streamWithAutoRetry before giving up.
            // If auto-retry is also exhausted, re-enter streamWithGroupFallback
            // to try the next model in the group.
            let streamResult: StreamResult
            do {
                let result = try await processStreamEvents(
                    stream: stream,
                    msgIdx: msgIdx,
                    provider: provider
                )
                // Detect empty responses — the stream completed without producing any
                // content blocks or a stop reason.  This happens when the Anthropic API
                // returns an SSE `event: error` (e.g. overloaded_error) inside an HTTP 200
                // response: the SDK silently terminates the stream instead of throwing.
                // Treat as a transient error so it enters the auto-retry path below.
                if isEmptyResponse(result) {
                    // [T-ios-empty-after-toolresult-reminder] Special case: the
                    // server returned nothing right after we handed it a tool
                    // result. The model owes a follow-up (next tool call or a
                    // final answer) but stalled — from the user's side the chat
                    // "stops" with no explanation. Inject a one-shot
                    // <system-reminder> into the last tool result and retry a
                    // SINGLE round. The per-run flag ensures this fires at most
                    // once, so it can never loop; if the reminder round is also
                    // empty we report an error (below) instead of a silent stall.
                    //
                    // [T-ios-callback-tail-empty-turn] The same "the model owes
                    // us a reply" situation arises with a second tail shape the
                    // tool-result predicate never matched: a bare
                    // `<agent_callback kind="finished">` user message, which
                    // `AgentJobRegistry.runThen` auto-delivers with no
                    // instruction after it. GPT-5.6 Terra over Codex OAuth
                    // answers that with one round of empty reasoning and a stop
                    // ~70% of the time, and Retry re-sends the identical
                    // history, so it usually stalls again. Both shapes now earn
                    // the one-shot reminder, each with its own wording.
                    let tailIsToolResult = lastEffectiveMessageIsToolResult()
                    let tailIsBareCallback = !tailIsToolResult && lastEffectiveMessageIsBareAgentCallback()
                    guard !didInjectEmptyToolReminderThisRun, tailIsToolResult || tailIsBareCallback else {
                        logger.error("🔁STREAM empty response (no content, no stop reason) — treating as transient error")
                        throw LLMError.transientError(message: "Server returned an empty response (overloaded or upstream error)")
                    }
                    didInjectEmptyToolReminderThisRun = true
                    RetryLogStore.shared.record(RetryLogEvent(
                        kind: .emptyResponse,
                        reason: AppLocalized("Empty response"),
                        model: retryLogModelLabel(entryId: activeEntryId)
                    ), key: retryLogKey)
                    logger.error("🔁STREAM empty after \(tailIsToolResult ? "tool result" : "agent callback") — injecting <system-reminder> and retrying one round")
                    // [T-msgidx-oob] Re-resync before subscripting: the stream
                    // we just consumed is a suspension point, so `messages` may
                    // have been mutated meanwhile (iCloud inbound rebuild,
                    // compaction sweep, user delete) and `msgIdx` gone stale.
                    // Reproduced deterministically on device (mock provider
                    // stalls, chat.debugRemoveMessages drops a row, provider
                    // then returns empty): this exact subscript trapped, and the
                    // reminder request below was never sent — matching the
                    // field crash 1.11(15) .ips 2026-08-15 14:02, symbolicated
                    // to this line. Same guard shape as the fallback paths below.
                    if msgIdx < 0 || msgIdx >= messages.count || messages[msgIdx].id != runMsgId {
                        guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                            logger.error("🔁STREAM empty-reminder: assistant message id=\(runMsgId) vanished (count=\(messages.count)) — aborting round")
                            throw LLMError.transientError(message: "Server returned an empty response (overloaded or upstream error)")
                        }
                        logger.warning("🔁STREAM empty-reminder: msgIdx resynced → \(resynced) (count=\(messages.count))")
                        msgIdx = resynced
                    }
                    let reminderHistory = applyRequestImageBudget(tailIsToolResult ? historyWithEmptyToolResultReminder() : historyWithEmptyCallbackReminder())
                    let reminderStream: AsyncThrowingStream<AgentStreamEvent, Error>
                    if providerProblem(forEntryId: activeEntryId) != nil {
                        // [T-provider-live-check] The provider went away since
                        // the request above: the reminder goes through the
                        // group path, which moves to the next member (or fails
                        // with the reason).
                        reminderStream = try await streamWithGroupFallback(
                            provider: provider,
                            messages: reminderHistory,
                            baseSystemPrompt: baseSystemPrompt,
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            model: activeModel,
                            lastContextTokens: dispatchInputTokens,
                            chatMessage: messages[msgIdx],
                            activeGroupId: &activeGroupId,
                            activeEntryId: &activeEntryId
                        )
                        await applyFallbackSwitch()
                    } else {
                        reminderStream = try await streamWithAutoRetry(
                            provider: provider,
                            messages: reminderHistory,
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            maxTokens: dynamicMaxTokens(provider: provider, model: activeModel, lastContextTokens: dispatchInputTokens),
                            chatMessage: messages[msgIdx],
                            entryId: activeEntryId
                        )
                    }
                    let reminderResult = try await processStreamEvents(
                        stream: reminderStream,
                        msgIdx: msgIdx,
                        provider: provider
                    )
                    if isEmptyResponse(reminderResult) {
                        // Still empty after the nudge — a genuine failure, not a
                        // transient blip. Surface it clearly instead of silently
                        // looping so the user knows why the chat stopped.
                        logger.error("🔁STREAM still empty after <system-reminder> retry — reporting error")
                        throw LLMError.providerError(message: "The model returned no response after a tool result, even after a reminder. It may be overloaded — please retry or switch models.")
                    }
                    // Recovered — proceed with the reminder round's content.
                    streamResult = reminderResult
                } else {
                    streamResult = result
                }
            } catch let streamError as LLMError where streamError.isRetryable || streamError.isFallbackable {
                // [T-fallback-midstream-fallbackable] `isRetryable` and
                // `isFallbackable` are DISJOINT sets (see LLMError's two
                // switches): retryable = networkError/transientError,
                // fallbackable = providerError/rateLimited/invalidAPIKey.
                // Matching only the first meant a 400/429/401 raised AFTER the
                // stream opened matched no catch at all and propagated straight
                // out of the loop — the group never got a chance to fall back,
                // even though the same error before the stream opened does fall
                // back immediately. The inner catch below already uses this
                // wider condition; this aligns the outer one with it.
                logger.error("🔁STREAM mid-stream error (retryable=\(streamError.isRetryable) fallbackable=\(streamError.isFallbackable)): \(streamError.localizedDescription)")
                // Resync msgIdx by stable id before touching messages — the
                // array may have been shrunk by a concurrent path (user
                // delete, reloadMessagesFromDB, compactBefore) during the
                // failed stream. If the assistant message is gone, bail.
                if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                    msgIdx = resynced
                } else {
                    logger.error("🔁STREAM mid-stream catch: assistant message id=\(runMsgId) no longer in messages (count=\(messages.count)) — aborting retry")
                    throw streamError
                }
                // Clear text blocks AND incomplete tool blocks from the interrupted stream
                // before retrying. Tool blocks stuck in .streaming or .running would otherwise
                // remain orphaned in the UI forever (never transition to a terminal state).
                //
                // [T-ios-stream-retry-text-disappear] ONLY clear the UNCOMMITTED tail
                // (blocks at index >= committedBlockCount). Earlier rounds of this same
                // resumed loop already committed+persisted their text/tool blocks to the
                // DB (committedBlockCount marks that boundary). The old unbounded
                // `removeAll { kind == .text }` wiped those committed text blocks from the
                // UI too, so a mid-stream retry made all prior post-tool text vanish on
                // screen even though it was still in the DB (reappearing only on reload).
                // Mirror resume()/Stop's `removeSubrange(committedBlockCount...)` boundary.
                await MainActor.run {
                    guard msgIdx < messages.count else { return }
                    Self.clearUncommittedStreamTail(messages[msgIdx], committedBlockCount: committedBlockCount)
                    messages[msgIdx].streamInterruptCount += 1
                    // [T-retry-log-sheet] Waiting on the model again: bring the
                    // typing row (and the retry marker in it) back, as Rerun does.
                    messages[msgIdx].isAwaitingModelResponse = true
                }
                RetryLogStore.shared.record(RetryLogEvent(
                    kind: .streamInterrupted,
                    reason: Self.retryLogReason(streamError),
                    model: retryLogModelLabel(entryId: activeEntryId)
                ), key: retryLogKey)
                // If group uses "always" fallback strategy, skip auto-retry and go straight
                // to group fallback for mid-stream errors too.
                let midStreamFbStrategy = activeGroupId
                    .flatMap { ProviderConfigStore.shared.group(for: $0) }?.fallbackStrategy ?? .limited
                // [T-fallback-midstream-fallbackable] A fallbackable error takes
                // the same direct-fallback path regardless of strategy, exactly
                // as it does before the stream opens (streamWithGroupFallback's
                // `catch ... where error.isFallbackable` advances immediately
                // rather than spending the retry ladder). Retrying the SAME
                // model on a 400/401 cannot succeed — the request is malformed
                // or the key is bad — and on a 429 it is actively harmful.
                if midStreamFbStrategy == .always || streamError.isFallbackable {
                    logger.error("🔀STREAM \(midStreamFbStrategy == .always ? "always-strategy" : "fallbackable error"), skipping autoRetry — direct group fallback: \(streamError.localizedDescription)")
                    if let eid = activeEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                        let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                        fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: streamError.fallbackReason))
                    }
                    // Re-resync after the await above — another task may have
                    // mutated `messages` during the MainActor.run suspension.
                    guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                        logger.error("🔀STREAM always-strategy: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting fallback")
                        throw streamError
                    }
                    msgIdx = resynced
                    streamResult = try await streamWithGroupFallbackUntilContent(
                        provider: provider,
                        messages: applyRequestImageBudget(effectiveAgentHistory()),
                        baseSystemPrompt: baseSystemPrompt,
                        systemPrompt: userSystemPrompt,
                        tools: tools,
                        model: activeModel,
                        lastContextTokens: dispatchInputTokens,
                        chatMessage: messages[msgIdx],
                        msgIdx: msgIdx,
                        activeGroupId: &activeGroupId,
                        activeEntryId: &activeEntryId
                    )
                    await applyFallbackSwitch()
                } else {
                    // Re-resync after the MainActor.run above before the next
                    // messages[msgIdx] read in the retry call.
                    guard let resynced = messages.firstIndex(where: { $0.id == runMsgId }) else {
                        logger.error("🔁STREAM autoRetry path: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting retry")
                        throw streamError
                    }
                    msgIdx = resynced
                    do {
                        let retryStream = try await streamWithAutoRetry(
                            provider: provider,
                            messages: applyRequestImageBudget(effectiveAgentHistory()),
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            maxTokens: dynamicMaxTokens(provider: provider, model: activeModel, lastContextTokens: dispatchInputTokens),
                            chatMessage: messages[msgIdx],
                            entryId: activeEntryId
                        )
                        let retryResult = try await processStreamEvents(
                            stream: retryStream,
                            msgIdx: msgIdx,
                            provider: provider
                        )
                        // If the retried stream is also empty, the provider is persistently
                        // failing (e.g. Anthropic overloaded).  Trigger group fallback.
                        if isEmptyResponse(retryResult) {
                            logger.error("🔁STREAM autoRetry also returned empty — triggering group fallback")
                            throw LLMError.providerError(message: "Server is overloaded")
                        }
                        streamResult = retryResult
                    } catch let retryError as LLMError where retryError.isFallbackable || retryError.isRetryable {
                        // Auto-retry exhausted or still empty — attempt group fallback.
                        logger.error("🔀STREAM retries exhausted, attempting group fallback: \(retryError.localizedDescription)")
                        if let eid = activeEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                            let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                            fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: retryError.fallbackReason))
                        }
                        // Resync before mutating — same rationale as outer catch.
                        if let resynced = messages.firstIndex(where: { $0.id == runMsgId }) {
                            msgIdx = resynced
                        } else {
                            logger.error("🔀STREAM retry-exhausted catch: assistant message id=\(runMsgId) gone (count=\(messages.count)) — aborting fallback")
                            throw retryError
                        }
                        await MainActor.run {
                            guard msgIdx < messages.count else { return }
                            // [T-ios-stream-retry-text-disappear] Same committed-tail
                            // guard as the outer catch — preserve persisted prior-round
                            // blocks, clear only the failed in-flight tail.
                            Self.clearUncommittedStreamTail(messages[msgIdx], committedBlockCount: committedBlockCount)
                            messages[msgIdx].streamInterruptCount += 1
                            messages[msgIdx].isAwaitingModelResponse = true
                        }
                        RetryLogStore.shared.record(RetryLogEvent(
                            kind: .streamInterrupted,
                            reason: Self.retryLogReason(retryError),
                            model: retryLogModelLabel(entryId: activeEntryId)
                        ), key: retryLogKey)
                        // Re-resync after MainActor.run before the messages[msgIdx]
                        // read below — see outer catch for rationale.
                        guard let resynced2 = messages.firstIndex(where: { $0.id == runMsgId }) else {
                            logger.error("🔀STREAM retry-exhausted fallback: assistant message id=\(runMsgId) vanished post-await (count=\(messages.count)) — aborting")
                            throw retryError
                        }
                        msgIdx = resynced2
                        // Use streamWithGroupFallbackUntilContent to keep cycling through
                        // group entries until one returns non-empty content.
                        streamResult = try await streamWithGroupFallbackUntilContent(
                            provider: provider,
                            messages: applyRequestImageBudget(effectiveAgentHistory()),
                            baseSystemPrompt: baseSystemPrompt,
                            systemPrompt: userSystemPrompt,
                            tools: tools,
                            model: activeModel,
                            lastContextTokens: dispatchInputTokens,
                            chatMessage: messages[msgIdx],
                            msgIdx: msgIdx,
                            activeGroupId: &activeGroupId,
                            activeEntryId: &activeEntryId
                        )
                        await applyFallbackSwitch()
                    }
                }
            }

            let streamEnd = Date()
            // [T-retry-log-sheet] A reply came back: every retry still pending
            // in this run (interruption, empty-response re-ask) recovered.
            RetryLogStore.shared.resolvePending(key: retryLogKey, outcome: .succeeded)
            // [T-bridge-echo-drop] A model that saw the old assistant bridge
            // rows in history may write one itself (sid AA40533E: a 262-char
            // copy closed a 12-block reply, rendered, and was persisted as one
            // more example). Drop the bridge sentence — keep any real text
            // after it — so it is neither shown nor saved.
            let bridgeEchoRemainder = RawMessage.strippingInternalBridgeEcho(streamResult.assistantText)
            let droppedBridgeEcho = bridgeEchoRemainder != nil
            let assistantText = bridgeEchoRemainder ?? streamResult.assistantText
            if droppedBridgeEcho {
                logger.warning("[Bridge] model echoed a bridge text (\(streamResult.assistantText.count) chars) — dropped, kept \(assistantText.count) chars after it")
            }
            let toolEntries = streamResult.toolEntries
            let stopReason = streamResult.stopReason
            turnUsage = streamResult.turnUsage
            noteToolFoldRequestEnded(messageId: runMsgId, startBlockIds: foldRequestStartBlockIds)
            logger.info("📐 Context after API: latestContextTokens=\(turnUsage.latestContextTokens) (in:\(turnUsage.inputTokens) cache_read:\(turnUsage.cacheReadTokens) cache_create:\(turnUsage.cacheCreationTokens))")
            // [T-ios-context-usage-realtime-crossing] Every API call in the
            // loop reports a fresh context size; feed it to the glow and the
            // first-crossing detector now instead of waiting for turn end.
            if turnUsage.latestContextTokens > 0 {
                noteContextUsageMidLoop(liveContextTokens: turnUsage.latestContextTokens)
                // [T-ctx-measure-outbound] Pair the report with our estimate of
                // the same request. The pair (not the raw report) is what the
                // capacity guard uses from here on, and what a reopened session
                // re-seeds from.
                // The model that actually served it: a group fallback may have
                // switched entries during this call.
                let servedModelId = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")?.model.id ?? activeModel.id
                if calibrateContextSize(reportedTokens: turnUsage.latestContextTokens, servedModelId: servedModelId) {
                    turnUsage.estimatedRequestTokens = lastDispatchEstimate
                    turnUsage.estimatedFixedTokens = contextFixedTokens
                    turnUsage.calibrationModelId = servedModelId
                    turnUsage.estimatorVersion = ContextSizeMeter.estimatorVersion
                }
                lastInLoopCompactionMadeNoProgress = false
                // [T-ctx-valve-rearm] An accepted request is fresh evidence, so
                // the once-per-evidence uncalibrated send is available again.
                // With a smoothed ratio one success no longer pulls a too-high
                // ratio all the way down; without this the NEXT iteration of the
                // same loop could stop as "over the window" right after the
                // provider accepted a same-size request. A rejection does not
                // re-arm it, so a real overflow still stops.
                sentPastExtrapolatedLimitThisLoop = false
            }

            // Track session-level token stats
            let iterationStreamDuration = streamEnd.timeIntervalSince(iterationStreamStart)
            let iterUsage = streamResult.turnUsage
            sessionInputTokens += iterUsage.inputTokens
            sessionOutputTokens += iterUsage.outputTokens
            sessionCacheReadTokens += iterUsage.cacheReadTokens
            sessionCacheWriteTokens += iterUsage.cacheCreationTokens
            if iterationStreamDuration > 0 && iterUsage.outputTokens > 0 {
                sessionStreamDuration += iterationStreamDuration
                sessionStreamOutputTokens += iterUsage.outputTokens
            }
            #if DEBUG
            iterationUsage = streamResult.iterationUsage
            #endif

            // Flush any throttled text delta that hasn't been pushed to the UI yet.
            // Find the last text block (processStreamEvents may have left un-flushed text).
            // Must also update cachedMarkdown — the render path uses it when present,
            // so stale cachedMarkdown causes the final tokens to not display.
            // Guard msgIdx again — messages may have been mutated during streaming.
            if !assistantText.isEmpty, msgIdx >= 0, msgIdx < messages.count,
               let textBlockIdx = messages[msgIdx].blocks.indices.last(where: { messages[msgIdx].blocks[$0].kind == .text }),
               messages[msgIdx].blocks[textBlockIdx].content != assistantText {
                // [DIAG-FINAL-1] Final text flush — this is the last chance to push
                // content to the UI before streaming ends. If this is skipped or
                // deferred (e.g. streamingUIUpdatesSuspended), the cell stays empty.
                logger.info("[StreamEnd] FINAL FLUSH text len=\(assistantText.count) blockContent len=\(messages[msgIdx].blocks[textBlockIdx].content.count) uiSuspended=\(streamingUIUpdatesSuspended) appState=\(UIApplication.shared.applicationState.rawValue)")
                setStreamingTextBlockContent(
                    msgIdx: msgIdx,
                    blockIdx: textBlockIdx,
                    text: assistantText,
                    parsedMarkdown: MarkdownContent(prepareMarkdownForRender(assistantText)),
                    cacheAttributedString: true,
                    requestScroll: true
                )
            } else if !assistantText.isEmpty, msgIdx >= 0, msgIdx < messages.count {
                // [DIAG-FINAL-2] Text already matches — no flush needed.
                // But if the cell is visually empty despite content being set,
                // it means SwiftUI/UIKit didn't re-render after the last @Published update.
                let textBlockIdx = messages[msgIdx].blocks.indices.last(where: { messages[msgIdx].blocks[$0].kind == .text })
                let blockContent = textBlockIdx.map { messages[msgIdx].blocks[$0].content } ?? "<no text block>"
                logger.info("[StreamEnd] SKIP FLUSH — content already matches. text len=\(assistantText.count) blockContent len=\(blockContent.count) hasCachedAttr=\(textBlockIdx.map { messages[msgIdx].blocks[$0].cachedAttributedString != nil } ?? false) hasCachedMD=\(textBlockIdx.map { messages[msgIdx].blocks[$0].cachedMarkdown != nil } ?? false)")
            } else if assistantText.isEmpty {
                // [DIAG-FINAL-3] No assistant text at all — tool-only response.
                logger.info("[StreamEnd] NO TEXT — tool-only response, nothing to flush")
            }

            // Auto-play: scan assistant text for audio URLs with ?auto_play=true
            // This works even when the app is in the background (e.g. Shortcuts intent)
            // because it triggers GlobalAudioPlayer directly, bypassing UI rendering.
            Self.triggerAutoPlayAudio(in: assistantText)

            #if DEBUG
            logger.debug("📊 Turn usage — in: \(turnUsage.inputTokens), out: \(turnUsage.outputTokens), cache_create: \(turnUsage.cacheCreationTokens), cache_read: \(turnUsage.cacheReadTokens)")
            let elapsed = Int(Date().timeIntervalSince(iterationStart) * 1000)
            LastAPIRequestBody.shared.updateLatest(
                usage: CapturedUsage(
                    inputTokens: iterationUsage.inputTokens,
                    outputTokens: iterationUsage.outputTokens,
                    cacheCreationTokens: iterationUsage.cacheCreationTokens,
                    cacheReadTokens: iterationUsage.cacheReadTokens
                ),
                durationMs: elapsed
            )
            #endif

            // Flush any deferred UI updates so block.content is up-to-date before
            // we read it — for the title below and for persistence. Without this,
            // content deferred due to streamingUIUpdatesSuspended would be lost
            // from the saved message.
            //
            // [T-shortcut-bg-title] Must run BEFORE title generation. While the UI
            // is suspended (app in background — every Shortcuts run — or a
            // session-switch transition, or a scroll) the final text lives only
            // in the deferred queue and the text block is still empty. Title
            // generation reads the blocks, saw "", and returned silently without
            // counting an attempt; a one-iteration text-only turn then ended with
            // no title until the user's NEXT message (field log: Shortcuts run
            // ended 17:13:10 with no [TitleGen], title only on userTurns=2).
            // Keyed on message/block ids, so it does not depend on msgIdx.
            flushDeferredStreamingTextUpdateIfNeeded()

            // [T-bridge-echo-drop] The live stream (and the deferred flush just
            // above) put the echoed text in this request's last text block;
            // replace it with what is left, or remove the block when nothing is.
            if droppedBridgeEcho, msgIdx >= 0, msgIdx < messages.count,
               let echoIdx = messages[msgIdx].blocks.indices.last(where: { $0 >= committedBlockCount && messages[msgIdx].blocks[$0].kind == .text }),
               RawMessage.strippingInternalBridgeEcho(messages[msgIdx].blocks[echoIdx].content) != nil {
                if assistantText.isEmpty {
                    messages[msgIdx].blocks.remove(at: echoIdx)
                } else {
                    setStreamingTextBlockContent(
                        msgIdx: msgIdx,
                        blockIdx: echoIdx,
                        text: assistantText,
                        parsedMarkdown: MarkdownContent(prepareMarkdownForRender(assistantText)),
                        cacheAttributedString: true,
                        requestScroll: false
                    )
                }
            }

            // Generate session title early — after first LLM response (text or tool call)
            generateSessionTitleIfNeeded(toolEntries: toolEntries.map { (name: $0.name, args: $0.args) })

            // Re-check bounds — messages may have been mutated during streaming.
            guard msgIdx >= 0, msgIdx < messages.count else {
                logger.error("⚠️ Agent loop: msgIdx \(msgIdx) out of bounds after streaming, breaking")
                hitTurnLimit = false
                break
            }

            // Build assistant content for agentHistory — only new blocks from this iteration
            var assistantParts: [AgentContentPart] = []
            let allBlocks = messages[msgIdx].blocks
            for i in min(committedBlockCount, allBlocks.count)..<allBlocks.count {
                let block = allBlocks[i]
                if case .text = block.kind {
                    // Prefer the fully-accumulated assistantText over block.content for the
                    // LAST text block — block.content may be stale due to throttled UI updates.
                    let isLastTextBlock = !allBlocks[(i+1)..<allBlocks.count].contains(where: { $0.kind == .text })
                    let content = (isLastTextBlock && assistantText.count > block.content.count)
                        ? assistantText : block.content
                    if !content.isEmpty {
                        assistantParts.append(.text(content))
                        // Also fix up the block so UI and persistence stay in sync
                        if content.count > block.content.count {
                            block.content = content
                        }
                    }
                }
            }
            for tu in toolEntries {
                assistantParts.append(.toolUse(id: tu.id, name: tu.name, input: tu.args))
            }
            self.prevCommittedBlockCount = self.committedBlockCount
            committedBlockCount = allBlocks.count
            self.committedBlockCount = committedBlockCount
            var assistantMessage = AgentMessage(role: .assistant, parts: assistantParts)
            assistantMessage.isInterrupted = streamResult.isStreamInterrupted
            assistantMessage.reasoningContent = streamResult.reasoningContent
            assistantMessage.reasoningEcho = streamResult.reasoningEcho
            let assistantAgentIdx = agentHistory.count
            agentHistory.append(assistantMessage)

            // Snapshot state for cache keep-alive warmup requests.
            // Phase B: must use effectiveAgentHistory so the keep-alive prefix matches
            // what we actually send to Anthropic (summary-prepended view).
            if provider is AnthropicAgentProvider, let sid = sessionId {
                keepAliveHistory = effectiveAgentHistory()
                keepAliveSystemPrompt = userSystemPrompt
                keepAliveTools = tools
                keepAliveEntry = ProviderConfigStore.shared.entry(for: activeEntryId ?? "")
                logger.info("🔥 cache keep-alive: snapshot updated — session=\(sid.prefix(8)) history=\(self.agentHistory.count) tools=\(tools.count) sysPromptLen=\(userSystemPrompt.count) enhancedCache=\(self.enhancedCacheEnabled) cacheRead=\(turnUsage.cacheReadTokens) cacheCreate=\(turnUsage.cacheCreationTokens)")
                CacheKeepAliveManager.shared.recordRequest(sessionId: sid, vm: self)
            }

            // Build thoughtSignature map from tool entries for persistence
            var sigMap: [String: String] = [:]
            for tu in toolEntries {
                if let sig = tu.metadata?.thoughtSignature { sigMap[tu.id] = sig }
            }
            // [T-gemini-signature-restore] Keep them on the session too, not
            // just on the row we are about to write. A provider built LATER in
            // this same run (group fallback, mid-stream failover) starts with an
            // empty metadata map and would otherwise treat the calls this turn
            // just made as unsigned — downgrading history the loop itself
            // produced seconds earlier.
            for (id, sig) in sigMap {
                pendingThoughtSignatures[id] = ToolCallMetadata(thoughtSignature: sig)
            }

            // If no tool uses, this turn is done — persist and break.
            guard !toolEntries.isEmpty else {
                logger.info("Agent loop ending — no tool calls. stopReason=\(String(describing: stopReason))")

                // [T-ios-stale-resume-banner] This turn produced a complete
                // assistant reply, so the conversation is no longer in an
                // interrupted/resumable state. canResume is only cleared at the
                // send/retry ENTRY points — if an earlier turn in this session
                // set it true (a prior interruption, a Stop, a transient empty
                // response) and was then continued, a normally-finished turn
                // never reset it, leaving the "Interrupted — tap Resume" banner
                // dangling under a fully-answered message (seen on the weibo
                // hot-search turn). Clear it here; the genuinely-incomplete
                // sub-cases below re-set it to true.
                canResume = false

                // Surface unexpected stops: nil stopReason or maxTokens with no text
                if stopReason == nil {
                    logger.warning("Agent loop ended with nil stopReason (stream closed unexpectedly)")
                    // [T-stream-drop-silent] A nil stopReason on the no-tool exit
                    // means the SSE ended WITHOUT the server sending a terminal
                    // finish_reason/message_stop — the stream returned instead of
                    // throwing (a mid-flight throw would go through the fallback/
                    // retry path, not here). This is an abnormal interruption, not a
                    // normal completion: a normally-finished turn always carries a
                    // concrete stopReason (endTurn/stop/…). Previously we only
                    // surfaced this when the text was empty, so a *partial* reply
                    // (bytes arrived, then the connection dropped on weak/handoff
                    // cellular — the "断流无提示" report) was persisted silently as if
                    // complete. Surface BOTH sub-cases now with a Resume entry, and
                    // distinguish the wording so a partial reply reads as truncated
                    // rather than empty.
                    if assistantText.isEmpty {
                        messages[msgIdx].error = AppLocalized("Response ended unexpectedly (no content received)")
                    } else {
                        messages[msgIdx].error = AppLocalized("The connection dropped — this reply may be incomplete. Tap Resume to continue.")
                    }
                    canResume = true
                } else if stopReason == .maxTokens {
                    logger.warning("Agent loop ended at max_tokens with no tool calls")
                    messages[msgIdx].error = AppLocalized("Response truncated (max tokens reached)")
                    canResume = true
                } else if stopReason == .refusal {
                    // [T-ios-fable5-empty-response] Anthropic safety classifier declined the
                    // request (HTTP 200, stop_reason="refusal", input tokens billed, empty
                    // content). On Fable 5 this fires as a false-positive on ordinary turns
                    // that carry the large agentic system prompt + tool set (OAuth path) — the
                    // exact reason the model detail page's Quick Test (no system prompt, no
                    // tools) succeeds while a real conversation returns empty. Retrying the
                    // identical request just gets declined again, so we surface it directly
                    // and steer the user to switch models rather than looping.
                    logger.warning("Agent loop ended with stop_reason=refusal — model declined the request")
                    messages[msgIdx].error = AppLocalized("The model declined to respond to this request. Try rephrasing, or switch to a different model.")
                    canResume = true
                } else if stopReason == .endTurn && assistantText.isEmpty
                            && (streamResult.reasoningContent ?? "").isEmpty
                            // [T-bridge-echo-drop] The model did answer — with a
                            // copied bridge line, now dropped. Not an empty reply.
                            && !droppedBridgeEcho
                            // [T-user-ask-fallback] After the text-ask nudge an
                            // empty end is its "nothing to ask" answer.
                            && !textAskNudgeSent
                            // [T-user-ask-deferred] A deferred card was shown and
                            // the model was told to end its turn: silence is right.
                            && !(userAskDeferred && userAskAskedThisRun) {
                    // Empty endTurn that survived all upstream retries — typically
                    // OpenAI gpt-5.5 on long contexts returning `finish_reason=stop`
                    // with no text/tool/reasoning. Surface it instead of silently
                    // dropping (ChatStore's empty-assistant filter would otherwise
                    // erase the row entirely).
                    logger.warning("Agent loop ended at endTurn with empty content")
                    // [T-error-persist-ios] If the context is nearly full, the empty
                    // response is most likely a context-overflow symptom — steer the
                    // user toward compacting rather than a blind retry.
                    // Re-fetch the entry from the store: `entry` was captured at
                    // loop start, so a context-window edit made during a long
                    // agent run would otherwise judge by the stale value here.
                    // [T-ios-switch-model-next-request] Judge against the entry
                    // that actually served this request (`activeEntryId` follows
                    // a mid-turn switch and group fallback), not the turn start.
                    let freshModel = ProviderConfigStore.shared.entry(for: activeEntryId ?? entry.id)?.model ?? activeModel
                    let maxCtx = effectiveContextWindow(for: freshModel)
                    let curCtx = estimateContextTokens()
                    if maxCtx > 0 && curCtx > Int(Double(maxCtx) * 0.7) {
                        messages[msgIdx].error = AppLocalized("The model returned an empty response. The conversation context may be too large — try compacting or starting a new session.")
                    } else {
                        messages[msgIdx].error = AppLocalized("Model returned an empty response. Please try again or switch models.")
                    }
                    canResume = true
                }

                // Flush any remaining unspoken text (streaming TTS already spoke most sentences)
                let remainingSpeak: String
                if streamResult.spokenTextOffset < streamResult.assistantText.count {
                    let startIdx = streamResult.assistantText.index(streamResult.assistantText.startIndex, offsetBy: streamResult.spokenTextOffset)
                    remainingSpeak = String(streamResult.assistantText[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    remainingSpeak = ""
                }
                if !remainingSpeak.isEmpty { speakQueued(remainingSpeak) }
                let interruptCount = await MainActor.run { messages[msgIdx].streamInterruptCount }
                let uiBlockCount = await MainActor.run { msgIdx < messages.count ? messages[msgIdx].blocks.count : -1 }
                logger.info("[BlocksLost] PERSIST final (no-tool) sid=\(sessionId?.prefix(8) ?? "nil") agentParts=\(assistantMessage.parts.count) uiBlocks=\(uiBlockCount)")
                if turnCount > 0 && streamResult.assistantText.count < 10 {
                    // [T-log-noise-privacy 2026-07-18] Content excerpt dropped —
                    // the char count + token counts carry the diagnostic signal.
                    logger.warning("[ModelDiag] SUSPICIOUS short final text after \(turnCount) tool turn(s): \(streamResult.assistantText.count) chars, sid=\(sessionId?.prefix(8) ?? "nil") outputTokens=\(turnUsage.outputTokens) contextTokens=\(turnUsage.latestContextTokens ?? 0)")
                }
                // [T-token-attribution-snapshot] activeEntryId is the entry that
                // actually served this turn — failover reassigns it in place, so
                // it names the backup model when one took over. Passing it here
                // (rather than letting the persist layer look up the session) is
                // what keeps attribution correct across a silent switch.
                if let persistedId = await persistAgentMessage(assistantMessage, tokenUsage: turnUsage, thoughtSignatures: sigMap, streamInterruptCount: interruptCount, modelEntryId: activeEntryId),
                   assistantAgentIdx < agentHistory.count {
                    agentHistory[assistantAgentIdx].dbMessageId = persistedId
                    // [T-error-persist-ios] Persist this turn's error state AFTER the
                    // row exists + dbMessageId is assigned, keyed by that id, so the
                    // indicator survives reload. Write UNCONDITIONALLY (incl. nil) so a
                    // successful (re)stream CLEARS a previously-persisted error rather
                    // than leaving the stale one in the DB (retry-then-succeed, edge #5).
                    if msgIdx < messages.count {
                        await ChatStore.shared.updateMessageErrorInfo(messageId: persistedId, errorInfo: messages[msgIdx].error)
                    }
                }
                hitTurnLimit = false

                // [T-ios-queued-message-continues-prev-turn] The current turn's
                // tool loop has fully converged (no tool calls this iteration) and
                // its final assistant reply is now persisted. If the user queued a
                // message mid-run, NOW inject it as a clean standalone user turn and
                // keep looping so the model produces a dedicated response — instead
                // of the old mid-loop drain that folded it into a tool_result and
                // made it read as in-loop context for this turn. Errors above
                // (canResume true) still inject: the user's new message takes
                // precedence over a stale interrupted-banner from this finished turn.
                let endInjection = await injectQueuedPromptsAsNewTurn(
                    msgIdx: &msgIdx,
                    committedBlockCount: &committedBlockCount,
                    turnUsage: turnUsage,
                    at: .turnEnd
                )
                if endInjection != .none {
                    // [T-scheduled-preempt] The user's own message decides what
                    // happens to the interrupted task — no resume nudge after it.
                    if endInjection == .prompts { scheduledResumeNudgeOwed = false }
                    // We're continuing with the user's new turn, so this session is
                    // no longer in an interrupted/resumable state. Reset per-turn
                    // usage for the fresh assistant message.
                    // [T-ios-inloop-compact-freeze] msgIdx now points at the fresh
                    // assistant message — retarget the stable anchor with it.
                    if msgIdx < messages.count { runMsgId = messages[msgIdx].id }
                    canResume = false
                    turnUsage = TokenUsage()
                    continue
                }
                // [T-scheduled-preempt] A scheduled fire was inserted at a tool gap
                // of this loop, the model has answered it and stopped cleanly —
                // possibly without resuming the task the fire interrupted. Send
                // ONE hidden nudge (never rendered: RawMessage.isInternalBridge)
                // and keep going in the same bubble; the model stops for real if
                // the task was in fact complete. Once per insertion.
                if scheduledResumeNudgeOwed, stopReason == .endTurn, !canResume, !self.userDidCancel {
                    scheduledResumeNudgeOwed = false
                    let nudge = AgentMessage(role: .user, parts: [.text(RawMessage.scheduledResumeNudgeText)])
                    let nudgeIdx = agentHistory.count
                    agentHistory.append(nudge)
                    if let pid = await persistAgentMessage(nudge), nudgeIdx < agentHistory.count {
                        agentHistory[nudgeIdx].dbMessageId = pid
                    }
                    self.prevCommittedBlockCount = self.committedBlockCount
                    committedBlockCount = messages[msgIdx].blocks.count
                    self.committedBlockCount = committedBlockCount
                    messages[msgIdx].isAwaitingModelResponse = true
                    logger.info("⏰[ScheduledPreempt] model stopped after an inserted scheduled fire — sent the one-shot resume nudge sid=\(self.sessionId?.prefix(8) ?? "nil")")
                    continue
                }
                // [T-user-ask-fallback] The reply ends by asking the user to
                // decide something in text (UserAskTextAsk), in a run that has
                // user_ask and has not used it: send ONE hidden reminder and let
                // the model ask with the card (or end without replying when it
                // was not really a decision). Once per run; never in a sub agent.
                if UserAskSettings.load().textAskNudge, userAskExposed, !textAskNudgeSent, !userAskAskedThisRun,
                   helperConfig == nil, stopReason == .endTurn, !canResume, !self.userDidCancel,
                   UserAskTextAsk.endsWithDecisionRequest(assistantText) {
                    textAskNudgeSent = true
                    let nudge = AgentMessage(role: .user, parts: [.text(RawMessage.userAskTextAskNudgeText)])
                    let nudgeIdx = agentHistory.count
                    agentHistory.append(nudge)
                    if let pid = await persistAgentMessage(nudge), nudgeIdx < agentHistory.count {
                        agentHistory[nudgeIdx].dbMessageId = pid
                    }
                    self.prevCommittedBlockCount = self.committedBlockCount
                    committedBlockCount = messages[msgIdx].blocks.count
                    self.committedBlockCount = committedBlockCount
                    messages[msgIdx].isAwaitingModelResponse = true
                    logger.info("[UserAsk] text-ask nudge sent sid=\(self.sessionId?.prefix(8) ?? "nil") textLen=\(assistantText.count)")
                    continue
                }
                // [T-subagent-steer-continues-loop] A steer that arrived while
                // this turn was converging keeps the loop alive, exactly as a
                // queued user message does above.
                //
                // The steer is consumed at the TOP of an iteration, so it is
                // only ever read if another iteration happens. When the child
                // answered without calling a tool — the common case for a
                // finishing agent — the loop broke here and the correction was
                // left in `pendingSteerMessages` for `finish()` to report as a
                // "missed steer": the parent was told the sub agent never saw
                // it, and from the user's side the instruction simply had no
                // effect. Continuing gives the next iteration something to
                // deliver, which is what makes a steer behave like the
                // mid-task interjection it is meant to be.
                if helperConfig != nil, !pendingSteerMessages.isEmpty {
                    logger.info("[subagent_task] steer arrived at loop end — continuing for another turn")
                    canResume = false
                    turnUsage = TokenUsage()
                    continue
                }
                // [T-subagent-termination] A sub agent whose turn ended with
                // neither tool calls nor text has handed the parent nothing:
                // an empty endTurn, a stream that closed without a stop
                // reason, a max_tokens cut inside reasoning. Field case
                // 2026-10-04: child transcripts that stop right after a tool
                // result, because the empty assistant row is dropped by
                // ChatStore's empty-assistant filter. Ask ONCE for the final
                // report with the tools withdrawn, the same mechanism as the
                // budget wrap-up. Not after a refusal (the same request is
                // declined again), not after a stop, not on the last round.
                if helperConfig != nil, !helperClosingNudgeSent, !self.userDidCancel,
                   stopReason != .refusal, turnCount + 1 < turnCap,
                   assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    helperClosingNudgeSent = true
                    helperClosingAttempted = true
                    tools = []
                    let nudge = AgentMessage(role: .user, parts: [.text(RawMessage.helperClosingNudgeText)])
                    let nudgeIdx = agentHistory.count
                    agentHistory.append(nudge)
                    if let pid = await persistAgentMessage(nudge), nudgeIdx < agentHistory.count {
                        agentHistory[nudgeIdx].dbMessageId = pid
                    }
                    if msgIdx < messages.count {
                        messages[msgIdx].error = nil
                        messages[msgIdx].isAwaitingModelResponse = true
                    }
                    canResume = false
                    self.prevCommittedBlockCount = self.committedBlockCount
                    committedBlockCount = messages[msgIdx].blocks.count
                    self.committedBlockCount = committedBlockCount
                    turnUsage = TokenUsage()
                    logger.warning("[subagent_term] empty turn end (stopReason=\(String(describing: stopReason))) — sent the one-shot closing request, tools withdrawn, turn=\(turnCount + 1)/\(turnCap)")
                    continue
                }
                // [T-user-ask-observe] One line per finished run: was user_ask in
                // it, was it used, and does the final reply still ask in text —
                // the before/after measure for the user_ask trigger changes.
                logger.info("[UserAsk] turn-end exposed=\(userAskExposed) asked=\(userAskAskedThisRun) textAsk=\(UserAskTextAsk.endsWithDecisionRequest(assistantText)) nudged=\(textAskNudgeSent) origin=\(programmaticTurnOrigin?.logLabel ?? "user") helper=\(helperConfig != nil)")
                break
            }

            // Build assistant RawMessage now but defer DB write until tool results
            // are ready, so both can be persisted in a single SQLite transaction.
            // [T-user-ask-observe] With the model that wrote it, like the final
            // reply row: a tool-call row used to get model_id NULL, so per-model
            // counts of tool use (user_ask included) were impossible.
            let deferredAssistantRaw = await buildRawMessage(assistantMessage, thoughtSignatures: sigMap,
                                                             modelEntryId: activeEntryId)
            // Phase B: write the DB id back into agentHistory immediately — even though
            // we defer the actual appendMessages to batch with the tool results below,
            // the id is deterministic and compact lookups rely on it.
            if let raw = deferredAssistantRaw, assistantAgentIdx < agentHistory.count {
                agentHistory[assistantAgentIdx].dbMessageId = raw.id
            }
            // Flush any remaining unspoken text (streaming TTS already spoke most sentences)
            do {
                let remainingSpeak: String
                if streamResult.spokenTextOffset < streamResult.assistantText.count {
                    let startIdx = streamResult.assistantText.index(streamResult.assistantText.startIndex, offsetBy: streamResult.spokenTextOffset)
                    remainingSpeak = String(streamResult.assistantText[startIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    remainingSpeak = ""
                }
                if !remainingSpeak.isEmpty { speakQueued(remainingSpeak) }
            }

            // Execute each tool use and collect results
            var toolResultParts: [AgentContentPart] = []
            var pendingSnapshots: [String: (toolName: String, snapshot: ToolSnapshot)] = [:]
            var cancelledDuringToolExecution = false

            // Image budget for this batch of tool results.
            //
            // Was: `kImageContextKeepCount - existingImages` (double-count with
            // trimOldImagesFromHistory). When trim left agentHistory near the
            // 20-image cap, a fan-out batch of 5+ read_image calls would race
            // for the few remaining slots and emit text placeholders for the
            // losers — even though the next turn's trim would have evicted
            // the old images anyway. Net effect: concurrent read_image
            // silently lost frames for the user.
            //
            // Now: budget the full `kImageContextKeepCount` per batch. The
            // single-turn cap is still 20 (worst case), and
            // trimOldImagesFromHistory() at the top of the next turn handles
            // historical pressure. [T-image-budget-double-count]
            let imageBudgetActor = BatchImageBudget(initial: Self.kImageContextKeepCount)

            #if DEBUG
            // [T-ios-concurrent-toolcall-dup-id] Per-batch dispatch trace —
            // logs each tool_use's full id + blockIdx so we can see whether
            // parallel calls share ids or have collisions on toolUseId
            // when the cancel-bubble bug reproduces.
            let _batchBlockCount = (msgIdx >= 0 && msgIdx < self.messages.count) ? self.messages[msgIdx].blocks.count : -1
            logger.info("[ConcurrentTools] BATCH START — entries=\(toolEntries.count) msgIdx=\(msgIdx) blocks=\(_batchBlockCount)")
            for (idx, tu) in toolEntries.enumerated() {
                logger.info("[ConcurrentTools]   DISPATCH [\(idx)] tu.id=\(tu.id) name=\(tu.name) blockIdx=\(tu.blockIdx)")
            }
            // toolUseId collision check across blocks in this assistant msg
            if msgIdx < self.messages.count {
                var seen: [String: Int] = [:]
                for blk in self.messages[msgIdx].blocks {
                    guard let tid = blk.toolUseId else { continue }
                    seen[tid, default: 0] += 1
                }
                let dupes = seen.filter { $0.value > 1 }
                if !dupes.isEmpty {
                    logger.error("[ToolUseId] COLLISION! Duplicate toolUseId across blocks: \(dupes)")
                }
            }
            #endif

            // Reset the global stop-signal once for the whole batch.
            // Concurrent tool tasks (below) only READ this flag; resetting
            // inside any single task would race-clear a stop initiated for
            // a sibling. [T-concurrent-tools 2026-05-25]
            commandCancelledByUser = false

            // Concurrent tool dispatch with maxConcurrentTools in-flight cap.
            // Anthropic requires tool_result blocks in the same order as
            // the originating tool_use blocks, so we tag each child task
            // with its source index and stitch results back in order after
            // every task completes.
            let toolsSnapshot = tools
            // [T-user-ask] Recovery snapshot for a user_ask in this batch.
            currentBatchAssistantRaw = deferredAssistantRaw
            currentBatchToolUseIds = toolEntries.map(\.id)
            var outcomesByIndex: [Int: ToolExecOutcome] = [:]
            await withTaskGroup(of: (Int, ToolExecOutcome).self) { group in
                var added = 0
                var harvested = 0
                for (idx, tu) in toolEntries.enumerated() {
                    // Rate-limit: hold here until we're below the in-flight cap.
                    while added - harvested >= Self.maxConcurrentTools {
                        if let pair = await group.next() {
                            outcomesByIndex[pair.0] = pair.1
                            harvested += 1
                        } else {
                            break
                        }
                    }
                    // [T-batch-read-after-write] A read that comes after a
                    // write in the same batch waits for that write. Every call
                    // of a batch used to start at once, so `shell_execute`
                    // (render q-1.png) + `read_image q-1.png` sent in one turn
                    // read the file ~15 ms in - before the shell had run -
                    // and failed with "Could not read image" (device log
                    // 2026-10-06 13:32:04), or read the PREVIOUS version of a
                    // file being regenerated, which models then explained as
                    // an image cache and worked around by renaming files.
                    // Only reader-after-writer pairs are ordered; everything
                    // else in the batch still runs concurrently.
                    let earlierWriters = BatchToolOrder.writersBefore(index: idx, in: toolEntries.map(\.name))
                    if !earlierWriters.isEmpty {
                        let waitStart = Date()
                        while earlierWriters.contains(where: { outcomesByIndex[$0] == nil }),
                              let pair = await group.next() {
                            outcomesByIndex[pair.0] = pair.1
                            harvested += 1
                        }
                        logger.info("[BatchOrder] \(tu.name) [\(idx)] waited \(String(format: "%.2f", Date().timeIntervalSince(waitStart)))s for writer(s) \(earlierWriters) in the same batch")
                    }
                    logger.info("[ToolLifecycle] DISPATCHED toolId=\(tu.id.prefix(20)) tool=\(tu.name) sid=\(self.sessionId?.prefix(8) ?? "nil") appState=\(UIApplication.shared.applicationState == .active ? "fg" : "bg") suspended=\(self.streamingUIUpdatesSuspended) isProcessing=\(self.isProcessing)")
                    group.addTask { [weak self] in
                        guard let self else {
                            // Self torn down mid-batch: synthesize a cancelled outcome
                            let cancelMsg = "<system-reminder>The session was torn down before this tool could execute.</system-reminder>"
                            return (idx, ToolExecOutcome(
                                toolId: tu.id, toolName: tu.name,
                                resultPart: .toolResult(id: tu.id, name: tu.name, content: cancelMsg, isError: true),
                                snapshotEntry: nil, snapshotItem: nil, cancelled: true
                            ))
                        }
                        let outcome = await self.executeSingleToolUse(
                            tu: tu, msgIdx: msgIdx, tools: toolsSnapshot, batchBudget: imageBudgetActor
                        )
                        return (idx, outcome)
                    }
                    added += 1
                }
                // Drain the remainder.
                for await pair in group {
                    outcomesByIndex[pair.0] = pair.1
                    harvested += 1
                }
            }

            // Stitch outcomes back in original tool_use order so the
            // tool_result blocks pair correctly with the assistant
            // message's tool_use blocks for the next API call.
            for idx in 0..<toolEntries.count {
                guard let outcome = outcomesByIndex[idx] else { continue }
                toolResultParts.append(outcome.resultPart)
                if let se = outcome.snapshotEntry {
                    pendingSnapshots[outcome.toolId] = se
                }
                if let si = outcome.snapshotItem {
                    toolSnapshots.append(si)
                }
                if outcome.cancelled {
                    cancelledDuringToolExecution = true
                }
            }

            // If any tool images were stripped due to budget, append a batch-reading tip
            let strippedImageCount = await imageBudgetActor.strippedSoFar
            if strippedImageCount > 0 {
                toolResultParts.append(.text(
                    "<system-reminder>\(strippedImageCount) image(s) from read_image were replaced with text placeholders"
                    + " because the context image limit (\(Self.kImageContextKeepCount)) was reached."
                    + " Summarize your findings so far, then use read_image again"
                    + " to view the remaining images in a new batch.</system-reminder>"
                ))
            }

            // Add tool results as a user message
            let toolResultMessage = AgentMessage(role: .user, parts: toolResultParts)
            logger.info("Appending tool result message with \(toolResultParts.count) part(s) to agentHistory (now \(self.agentHistory.count + 1) messages)")
            let toolResultAgentIdx = agentHistory.count
            agentHistory.append(toolResultMessage)

            // Collect terminal tool statuses from the assistant blocks so persistence can
            // distinguish failed vs cancelled (both have success == false).
            var toolStatusStrings: [String: String] = [:]
            if msgIdx < messages.count {
                for block in messages[msgIdx].blocks {
                    guard let id = block.toolUseId, let status = block.toolStatus else { continue }
                    switch status {
                    case .success: toolStatusStrings[id] = "success"
                    case .failed: toolStatusStrings[id] = "failed"
                    case .cancelled: toolStatusStrings[id] = "cancelled"
                    case .streaming, .running: break
                    }
                }
            }

            // Batch-persist the deferred assistant message + tool results in one transaction
            let uiBlockCountMid = await MainActor.run { msgIdx < messages.count ? messages[msgIdx].blocks.count : -1 }
            logger.info("[BlocksLost] PERSIST mid-loop (tool) sid=\(sessionId?.prefix(8) ?? "nil") agentParts=\(assistantMessage.parts.count) uiBlocks=\(uiBlockCountMid)")
            if let toolResultRaw = await buildRawMessage(toolResultMessage, snapshots: pendingSnapshots, toolStatuses: toolStatusStrings) {
                var batch: [RawMessage] = []
                if let assistantRaw = deferredAssistantRaw { batch.append(assistantRaw) }
                batch.append(toolResultRaw)
                await ChatStore.shared.appendMessages(batch)
                // [T-user-ask] The answers are in the transcript now: drop the
                // recovery records (delivery is exactly-once per toolCallId).
                let askIds = toolEntries.filter { $0.name == UserAskTool.name }.map(\.id)
                if !askIds.isEmpty { UserAskCenter.shared.markDelivered(toolUseIds: askIds) }
                // Phase B: write the DB id back into agentHistory entries so compact
                // can resolve boundaries by id.
                if toolResultAgentIdx < agentHistory.count {
                    agentHistory[toolResultAgentIdx].dbMessageId = toolResultRaw.id
                }
            } else if let assistantRaw = deferredAssistantRaw {
                await ChatStore.shared.appendMessage(assistantRaw)
                // (assistantAgentIdx was already populated above via deferredAssistantRaw path)
            }

            // Signal that tools are done and we're waiting for the model's next response.
            guard msgIdx < messages.count else { break }
            messages[msgIdx].isAwaitingModelResponse = true

            // If user cancelled during tool execution, commit everything and stop.
            // History is now properly paired: assistant(tool_use) + user(tool_result).
            // [T-agent-wrapup-turn] A helper whose running tool was stopped
            // by the parent's budget watcher (not by a person) must NOT end
            // here: the cancelled tool result is committed and the loop goes
            // round once more, where the wrap-up turn is injected.
            if cancelledDuringToolExecution, helperConfig != nil, helperWrapUpRequested, !self.userDidCancel {
                logger.info("[delegate_task] tool stopped for wrap-up — committed \(toolResultParts.count) tool result(s), continuing to the wrap-up turn")
                self.prevCommittedBlockCount = self.committedBlockCount
                committedBlockCount = messages[msgIdx].blocks.count
                self.committedBlockCount = committedBlockCount
                continue
            }
            // [T-stop-sibling-subagent] `delegationResultsMuted` lands here for
            // the sibling case: the user stopped a sub agent from its card, so
            // the parent was never cancelled and this break never fired. The
            // tool results ARE committed above (the transcript keeps what the
            // finished agents came back with) — what stops is sending them to
            // the model, which is what re-delegated a fresh agent seconds after
            // the user pressed Stop (real case 2026-09-07 19:59:08).
            if cancelledDuringToolExecution || self.userDidCancel || self.delegationResultsMuted {
                logger.info("⏹️ User cancelled during tool execution — committed \(toolResultParts.count) tool result(s), stopping agent loop (muted=\(self.delegationResultsMuted))")
                self.prevCommittedBlockCount = self.committedBlockCount
                committedBlockCount = messages[msgIdx].blocks.count
                self.committedBlockCount = committedBlockCount
                messages[msgIdx].usage = turnUsage
                publishContextUsage()
                // [T-usage-capsule-time] A stopped turn is finished too — the
                // capsule renders whenever usage exists, so the clock has to
                // be set on every path that sets usage or it would be blank.
                messages[msgIdx].completedAt = Date()
                hitTurnLimit = false
                break
            }

            // [T-ios-queued-message-interrupt-on-toolclose] If the user queued a
            // prompt while tools were running, interrupt as soon as the CURRENT
            // tool call closes (its tool_result is now built + persisted) — don't
            // keep grinding through the rest of the running plan. We break out of
            // the tool loop here; the post-loop drainQueuedPrompts() then lands the
            // queued prompt as a clean STANDALONE user turn and the model responds
            // to it next.
            //
            // Why break instead of appending inline: appending the queued user
            // message right after the tool_result lets mergeConsecutiveSameRole
            // fold it into that tool_result as a trailing text block (Anthropic
            // requires consecutive same-role messages merged), so the model read
            // it as in-loop context for the previous turn and never gave it its
            // own response (the #579 bug). Breaking → fresh turn avoids the merge
            // entirely while still inserting/un-queuing the message immediately.
            // [T-p2-gentle-job-injection] Only a USER follow-up earns the
            // interrupt. Job results (`deferUntilIdle`) stay queued and ride
            // the finish-branch injection once this turn's plan has converged
            // — the parent's own long tool chain runs to completion first.
            // [T-scheduled-preempt] …and a scheduled fire is let in here too, but
            // only while the model is continuing (stop reason tool_use): one
            // job per gap, its own turn behind a bridge, with a reminder to
            // finish the task in progress (QueueDeliveryPlanner).
            let gapTake = planQueueTake(at: .toolGap)
            if let gapTake, gapTake.scheduledJobId == nil || stopReason == .toolUse {
                logger.info("📨[QueueInterrupt] \(self.promptQueue.count) queued prompt(s) — interrupting after current tool call to start a standalone turn (scheduled=\(gapTake.scheduledJobId?.prefix(8) ?? "-"))")
                self.prevCommittedBlockCount = self.committedBlockCount
                committedBlockCount = messages[msgIdx].blocks.count
                self.committedBlockCount = committedBlockCount
                // injectQueuedPromptsAsNewTurn un-queues the on-screen message
                // (drops dashed border + X) so it appears inserted immediately,
                // persists it as a standalone user turn, caches the just-finished
                // assistant blocks, and starts a fresh assistant message. We then
                // `continue` so the next iteration produces a dedicated response to
                // the queued prompt — abandoning the rest of the running plan.
                let gapInjection = await injectQueuedPromptsAsNewTurn(
                    msgIdx: &msgIdx,
                    committedBlockCount: &committedBlockCount,
                    turnUsage: turnUsage,
                    at: .toolGap
                )
                if gapInjection != .none {
                    scheduledResumeNudgeOwed = gapInjection == .scheduledFire
                    // [T-ios-inloop-compact-freeze] Retarget the stable anchor
                    // alongside msgIdx (fresh assistant message for the new turn).
                    if msgIdx < messages.count { runMsgId = messages[msgIdx].id }
                    canResume = false
                    turnUsage = TokenUsage()
                    continue
                }
            }

            // If the background task expired while executing tools, pause here
            // until the app returns to the foreground before making the next API call.
            await waitIfBackgroundSuspended()

            // If the user activated browser takeover, pause until they're done.
            await waitIfBrowserTakeover()

            // If stop reason was end_turn (not tool_use), break
            if stopReason != .toolUse {
                // maxTokens: the model ran out of output tokens mid-response.
                // Show a warning and enable Resume so the user can continue.
                if stopReason == .maxTokens {
                    logger.warning("Agent loop stopped: max_tokens reached")
                    messages[msgIdx].error = AppLocalized("Response truncated (max tokens reached)")
                    canResume = true
                }
                // [T-stream-drop-silent] nil stopReason after tool turns means the
                // stream ended without a proper terminal event — same abnormal
                // interruption as the no-tool exit above. Surface with content-aware
                // wording + Resume instead of the old bare "ended unexpectedly".
                if stopReason == nil && toolEntries.isEmpty {
                    logger.warning("Agent loop stopped: stream ended without stop reason")
                    if assistantText.isEmpty {
                        messages[msgIdx].error = AppLocalized("Response ended unexpectedly (no content received)")
                    } else {
                        messages[msgIdx].error = AppLocalized("The connection dropped — this reply may be incomplete. Tap Resume to continue.")
                    }
                    canResume = true
                }
                hitTurnLimit = false
                break
            }
        }

        // hitTurnLimit stays true only when the while-condition itself failed
        // — meaning the model kept producing tool calls for maxAgentTurns
        // iterations straight. Surface why we stopped + arm canResume so the
        // user can continue from here. Mirrors Android ChatViewModel.
        // finalizeAtTurnLimit. (Earlier draft used `turnCount >= max` which
        // false-positived: the `defer { turnCount += 1 }` runs even on break,
        // so a happy-path break on the final allowed iteration would inflate
        // turnCount to max and slap a fake "200 turns hit" error on every
        // ordinary completion — exactly the v1.4.0-dev bug user hit.)
        if hitTurnLimit, msgIdx >= 0, msgIdx < messages.count {
            // [T-agent-wrapup-turn] Report the cap that actually applied: a
            // helper stops at helperConfig.maxTurns, not the 200 of a
            // normal chat, and it is not "runaway" — its wrap-up turn simply
            // did not produce a final answer.
            logger.warning("⚠️ runAgentLoop hit turnCap=\(turnCap) — finalizing as resumable")
            messages[msgIdx].error = helperConfig != nil
                ? "The agent used all \(turnCap) tool rounds without writing a final answer."
                : "Stopped after \(turnCap) agent turns to prevent runaway tool use. " +
                  "The model kept calling tools without finishing — tap Resume to continue from here, " +
                  "or send a new message to start over."
            canResume = true
        }

        // Store accumulated usage on the assistant message
        guard msgIdx < messages.count else { return }
        messages[msgIdx].isAwaitingModelResponse = false
        messages[msgIdx].usage = turnUsage
        publishContextUsage()
        // [T-usage-capsule-time] The ordinary end of a turn — see the field's
        // note for why this is not `timestamp`.
        messages[msgIdx].completedAt = Date()

        // Safety net: force-close any tool blocks still stuck in non-terminal status.
        // This can happen when stream interruptions, retries, or edge cases leave
        // tool blocks in .streaming or .running without transitioning to success/failed/cancelled.
        for block in messages[msgIdx].blocks {
            switch block.toolStatus {
            case .streaming:
                // [T-ios-concurrent-toolcall-dup-id] PRIMARY SUSPECT for the
                // concurrent cancel-bubble bug: if outcome stitching drops an
                // entry, that block stays .streaming and lands here.
                logger.warning("[SafetyNet] force-closing .streaming → .cancelled toolUseId=\(block.toolUseId ?? "nil") kind=\(block.kind) content_len=\(block.content.count)")
                block.toolStatus = .cancelled
            case .running:
                logger.warning("[SafetyNet] force-closing .running → .cancelled toolUseId=\(block.toolUseId ?? "nil") kind=\(block.kind) content_len=\(block.content.count)")
                block.toolStatus = .cancelled
            default:
                break
            }
        }

        // Cache parsed MarkdownContent and NSAttributedString on completed text blocks
        // to avoid re-parsing and re-rendering on cell recycling / SwiftUI refreshes.
        for i in messages[msgIdx].blocks.indices {
            if case .text = messages[msgIdx].blocks[i].kind, !messages[msgIdx].blocks[i].content.isEmpty {
                messages[msgIdx].blocks[i].cachedMarkdown = MarkdownContent(prepareMarkdownForRender(messages[msgIdx].blocks[i].content))
                cacheAttributedString(for: messages[msgIdx].blocks[i])
            }
        }

    }
}
