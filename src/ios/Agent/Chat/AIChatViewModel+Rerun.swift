//
//  AIChatViewModel+Rerun.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, re-running from an earlier point: retry from a user
//  message, delete from a message, retry from a tool block, and the shared
//  launcher (launchRerunAgentLoop) plus tool-snapshot rebuild they use.
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
    func retryFromMessage(_ messageId: UUID, replacementAttachments: [InputAttachment]? = nil) {
        settlePendingStop(before: "retryFromMessage")  // [T-stop-cleanup-before-new-turn]
        guard !isProcessing else { return }
        // [T-ios-retry-keyboard] Re-running from an existing user message is a
        // retry, not a new send.
        turnStartedByRetry = true
        // [T-ios-retry-usermsg-vanish] Guard the whole truncation window so a
        // deferred iCloud-sync reload can't rebuild `messages` from a
        // mid-truncation DB snapshot and drop the retried user message. Cleared
        // once the DB truncation Task below finishes; isProcessing=true (set in
        // launchRerunAgentLoop) keeps suppressing reloads afterward.
        isTruncatingForRetry = true
        canResume = false
        userDidCancel = false
        delegationResultsMuted = false
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].role == .user else {
            isTruncatingForRetry = false
            return
        }

        // [T-bubble-span] A bubble whose send() has not landed its entry yet
        // (Stop right after Send) has nothing in history to re-run from; its
        // entry lands in a moment, after which retry works normally.
        if messages[idx].awaitingHistoryEntry {
            logger.warning("[BubbleSpan] retryFromMessage: bubble idx=\(idx) still awaiting its history entry — retry ignored")
            isTruncatingForRetry = false
            return
        }
        // Keep the selected user message (through the last bubble of its
        // merged group) and its entry; remove everything after. Shared locator
        // with delete and edit — see locateUserBubble.
        let keepUpTo = cutAtUserBubble(idx, keepBubble: true, site: "retryFromMessage").keptEntry ?? (agentHistory.count - 1)
        // [T-ios-retry-ui-clear] symmetric with retryFromToolBlock's paths —
        // force a top-level publish so the UI clears synchronously on this
        // tick. The vm.$messages sink already fires off-tick (main-queue
        // receive), so without this the stale cells linger one runloop.
        if !transitionSuspended { objectWillChange.send() }
        AppLogger(category: "RetryDiag").info("[RetryDiag] retryFromMessage truncated userIdx=\(idx) messagesCount=\(self.messages.count)")

        // Replace attachments in the last user message of agentHistory if new ones are provided
        if let newAttachments = replacementAttachments, !newAttachments.isEmpty {
            let uploadsDir = Self.minisUploadsDir(for: sessionId ?? "draft")
            let fm = FileManager.default
            try? fm.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
            let nowStr = ISO8601DateFormatter().string(from: Date())
            let (newParts, newMetas) = processAttachments(newAttachments, uploadsDir: uploadsDir, nowStr: nowStr)
            Self.cleanupAttachmentFiles(newAttachments)

            // Replace parts in the last user agentHistory entry:
            // keep only .text parts that are NOT <user-attached-files>, then append new parts
            if !agentHistory.isEmpty {
                var lastEntry = agentHistory[keepUpTo]
                let filteredParts = lastEntry.parts.filter { part in
                    if case .text(let t) = part, t.contains("<user-attached-files>") { return false }
                    if case .imageData = part { return false }
                    return true
                }
                lastEntry.parts = filteredParts + newParts
                agentHistory[keepUpTo] = lastEntry
            }

            // Update the ChatMessage's attachments for display
            messages[idx].attachments = newMetas
            // [T-ios-user-attach-mount-invalidate] FOURTH mount site. Unlike the
            // send/drain sites this one has no two-phase race — it rewrites the
            // attachments of an EXISTING message — but that is precisely why it
            // needs the pair: the cell has certainly measured and cached a
            // height by now, and swapping the tile set is an in-place height
            // change on an item whose identity does not move, so the cached
            // value would be served until something else forced a relayout.
            if !newMetas.isEmpty {
                NotificationCenter.default.post(name: .minisUserAttachmentsMounted,
                                                object: messages[idx].id)
            }
        }

        // Trim persisted messages to match.
        // Phase B: agentHistory is no longer mutated by compact, so keepCount is valid.
        let persistedKeepCount = agentHistory.count
        let hasMarkerResend = cachedLatestMarker != nil
        logger.info("[DeleteAfter] resend path: sid=\(sessionId?.prefix(8) ?? "nil") keepCount=\(persistedKeepCount) hasMarker=\(hasMarkerResend)")
        if let sessionId {
            Task { @MainActor [weak self] in
                await ChatStore.shared.deleteMessagesAfter(sessionId: sessionId, keepCount: persistedKeepCount)
                // DB truncation done — the truncation window is closed. By now
                // launchRerunAgentLoop has set isProcessing=true, so reloads
                // stay suppressed through the rerun; this just releases the
                // retry-specific guard.
                self?.isTruncatingForRetry = false
            }
        } else {
            isTruncatingForRetry = false
        }

        rebuildToolSnapshotsFromMessages()
        launchRerunAgentLoop(label: "retryFromMessage")
    }

    /// [T-ios-delete-from-message] Delete a user message and everything after
    /// it, from the UI, the model-facing history, and the DB.
    ///
    /// Deliberately built as `retryFromMessage` minus the rerun, plus one row:
    /// deleting an arbitrary message would leave `tool_use` blocks without
    /// their `tool_result` (a hard 400 from every provider on the next turn),
    /// so the only safe cut is a SUFFIX cut. Reusing the retry rule gives that
    /// for free — it anchors on user BUBBLES in `agentHistory`
    /// (`isUserBubbleEntry` skips synthetic tool_result user-role entries), so
    /// the boundary always lands on a completed turn and can never split a
    /// tool_use/tool_result pair.
    ///
    /// The one difference from retry: the anchor user message is removed too
    /// (`keepUpTo - 1`), so the surviving history ends on the PREVIOUS
    /// assistant turn — still a valid, self-consistent context.
    func deleteFromMessage(_ messageId: UUID) {
        settlePendingStop(before: "deleteFromMessage")  // [T-stop-cleanup-before-new-turn]
        guard !isProcessing else { return }
        // Same truncation guard as retry: a deferred iCloud-sync reload landing
        // mid-truncation would rebuild `messages` from a stale DB snapshot and
        // resurrect the rows we are deleting. Unlike retry there is no
        // `isProcessing = true` afterwards to keep suppressing reloads, so this
        // flag must stay set until the DB delete has actually committed.
        isTruncatingForRetry = true
        canResume = false
        userDidCancel = false
        delegationResultsMuted = false
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              messages[idx].role == .user else {
            isTruncatingForRetry = false
            return
        }

        let messagesBefore = messages.count

        // Remove the selected user message AND everything after it — from the
        // first bubble of its merged group, with its entry. Shared locator
        // with retry and edit — see locateUserBubble. An unlinked bubble falls
        // back to the ordinal rule and, if even that finds nothing, fails OPEN
        // (keeps the full history) as before: the UI + DB still truncate, so
        // the worst case is an over-long context, not a corrupt one.
        cutAtUserBubble(idx, keepBubble: false, site: "deleteFromMessage")
        let deletedCount = messagesBefore - messages.count
        // [T-ios-retry-ui-clear] Force a top-level publish so the cells clear on
        // this tick; the $messages sink alone fires off-tick.
        if !transitionSuspended { objectWillChange.send() }

        logger.info("[DeleteDiag] deleteFromMessage idx=\(idx) deleted=\(deletedCount) messagesLeft=\(self.messages.count) historyLeft=\(self.agentHistory.count)")

        let persistedKeepCount = agentHistory.count
        if let sessionId {
            Task { @MainActor [weak self] in
                await ChatStore.shared.deleteMessagesAfter(sessionId: sessionId, keepCount: persistedKeepCount)
                self?.isTruncatingForRetry = false
            }
        } else {
            isTruncatingForRetry = false
        }

        rebuildToolSnapshotsFromMessages()
    }

    /// Rebuild `toolSnapshots` to only those still referenced by a tool_use
    /// block in the (post-truncation) messages list. Shared by the user-
    /// message retry path and the tool-block re-run path.
    func rebuildToolSnapshotsFromMessages() {
        toolSnapshots = messages
            .filter { $0.role == .assistant }
            .flatMap { msg in
                msg.blocks.compactMap { block -> ToolSnapshotItem? in
                    guard let tuId = block.toolUseId else { return nil }
                    return toolSnapshots.first(where: { $0.id == tuId })
                }
            }
    }

    /// Shared re-run tail used by retryFromMessage and retryFromToolBlock:
    /// reset transient UI state, flip isProcessing, boot the kernel, and
    /// launch the agent loop on `currentTask`. Caller must have already
    /// truncated messages / agentHistory / persisted rows to the desired
    /// re-entry point. [T-ios-rerun-from-tool-block-position]
    ///
    /// `resumeAt`/`resumeBlocks`: when the truncated tail still ends in an
    /// assistant message that the new generation should CONTINUE (the
    /// block-boundary re-run keeps the surviving earlier blocks of that
    /// turn), pass its index + surviving block count so runAgentLoop reuses
    /// it instead of appending a fresh assistant message — otherwise the UI
    /// shows two consecutive assistant headers (the trimmed turn + the new
    /// stream). The user-message retry path leaves `messages.last` as the
    /// user message and passes nil, so a fresh assistant is appended as
    /// before. [T-ios-retry-double-header]
    ///
    /// Immediate thinking UI [T-ios-retry-thinking-ui]: the agent loop's own
    /// assistant-message creation runs inside the async Task (after kernel
    /// boot + concurrency gate), so without preparing UI here the user sees
    /// no feedback for hundreds of ms after pressing "Retry" / "Re-run From
    /// Here". Synchronously prepare the message that the TypingIndicator
    /// keys off:
    ///   * resumeAt == nil → append a placeholder assistant ChatMessage and
    ///     set `isAwaitingModelResponse = true`. runAgentLoop is then
    ///     instructed to RESUME into that placeholder (resumingAt =
    ///     placeholderIdx, committedBlocks = 0) so it does NOT append a
    ///     second assistant message and we don't double-create.
    ///   * resumeAt != nil → caller already has a surviving assistant turn
    ///     they want to continue (sub-message cut); just flip its
    ///     `isAwaitingModelResponse = true` so the typing indicator shows on
    ///     it until the new content starts streaming.
    /// TypingIndicator's gate is
    /// `isLast && vm.isProcessing && (!hasVisibleContent || isAwaiting…)`
    /// — covered for both cases since `isProcessing = true` is set below and
    /// `messages.last` is the prepared assistant in each case.
    private func launchRerunAgentLoop(label: String, resumeAt: Int? = nil, resumeBlocks: Int? = nil) {
        AppLogger(category: "RetryDiag").info("[RetryDiag] launchRerunAgentLoop called label=\(label) resumeAt=\(resumeAt.map(String.init) ?? "nil") resumeBlocks=\(resumeBlocks.map(String.init) ?? "nil") messagesCount=\(self.messages.count)")
        errorMessage = nil
        // Clear interrupt badge on the last assistant message if present
        if let lastAssistant = messages.last(where: { $0.role == .assistant }) {
            lastAssistant.streamInterruptCount = 0
        }

        // Immediate thinking-state prep (see doc comment above).
        let effectiveResumeAt: Int?
        let effectiveResumeBlocks: Int?
        if let r = resumeAt {
            let inBounds = r < messages.count
            let isAsst = inBounds && messages[r].role == .assistant
            if inBounds, isAsst {
                messages[r].isAwaitingModelResponse = true
            } else {
                // [RetryDiag] resumeAt points outside the array or at a non-
                // assistant row — an off-by-one in the caller's index math. The
                // loop will still try to resume at r; surface it loudly.
                AppLogger(category: "RetryDiag").warning("[RetryDiag] launchRerunAgentLoop SUSPECT resumeAt=\(r) inBounds=\(inBounds) isAssistant=\(isAsst) messagesCount=\(self.messages.count) — index may be off-by-one")
            }
            effectiveResumeAt = r
            effectiveResumeBlocks = resumeBlocks
        } else {
            // Append placeholder assistant so the typing indicator can latch
            // on instantly; tell runAgentLoop to resume into it.
            let placeholder = ChatMessage(role: .assistant, content: "", blocks: [])
            placeholder.isAwaitingModelResponse = true
            messages.append(placeholder)
            effectiveResumeAt = messages.count - 1
            effectiveResumeBlocks = 0
        }

        isProcessing = true
        forceScrollToBottom.send()

        ensureKernelBooted()
        beginBackgroundProcessing()

        currentTask = Task { [weak self] in
            guard let self else { return }

            while self.kernelStatus == .booting {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if case .failed(let msg) = self.kernelStatus {
                self.errorMessage = "Kernel not available: \(msg)"
                self.isProcessing = false
                self.endBackgroundProcessing()
                return
            }

            // Concurrency gate: wait for a processing slot
            let retryFromSid = self.sessionId ?? "unknown"
            guard let slotLease = await self.acquireSessionSlot(retryFromSid) else { return }
            defer { SessionConcurrencyManager.shared.release(slotLease) }

            do {
                try await self.runAgentLoop(resumingAt: effectiveResumeAt, committedBlocks: effectiveResumeBlocks)
            } catch is CancellationError {
                logger.info("Agent loop cancelled (\(label))")
                self.finishStoppedTurn()
            } catch {
                let rawDesc = String(describing: error)
                logger.error("Agent loop error (\(label)): \(rawDesc)")
                if let llmErr = error as? LLMError {
                    logger.error("Agent loop LLMError detail: \(llmErr.errorDescription ?? "nil")")
                }
                if self.turnWasStopped {   // [T-stop-queued-cancel-error]
                    self.finishStoppedTurn()
                } else {
                    let displayDesc = Self.friendlyErrorMessage((error as? LocalizedError)?.errorDescription ?? rawDesc)
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
                        last.blocks.removeAll { $0.kind == .text && $0.content.isEmpty }
                        for block in last.blocks {
                            if case .streaming = block.toolStatus { block.toolStatus = .cancelled }
                            else if case .running = block.toolStatus { block.toolStatus = .cancelled }
                        }
                    } else {
                        self.reportTurnFailure(displayDesc)   // [T-ios-error-banner-lost]
                    }
                }
            }
            if self.userDidCancel { self.handleUserCancelledCleanup() }
            // [T-stop-with-queue-render-desync] See send(): Stop's cancel() owns
            // state teardown; a superseded task must not drain or flip isProcessing.
            guard !Task.isCancelled else {
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] \(label) epilogue skipped (task cancelled) session=\(self.sessionId ?? "nil")")
                return
            }
            await self.drainQueuedPrompts()
            logger.info("🔄SESSION [vm=\(self.vmInstanceId)] \(label) DONE session=\(self.sessionId ?? "nil")")
            self.playCompletionHaptic()
            self.isProcessing = false
            self.endBackgroundProcessing()
        }
    }

    /// [T-ios-rerun-from-tool-block-position] Re-run the agent loop from the
    /// point a specific tool_use was about to be issued. Block-boundary cut:
    /// keep the blocks BEFORE the target tool_use in its assistant turn, drop
    /// the target block + later blocks in that turn + all later messages, then
    /// re-run so the model re-decides from that point.
    ///
    /// Anchor is the block's `toolUseId` (stable, unique) — NOT positional
    /// counting — so streaming / multi-entry-per-UI-message alignment can't
    /// drift.
    ///
    /// Degenerate case: if the target is the FIRST block of its assistant
    /// message and nothing precedes it in that turn, this is equivalent to
    /// truncating at the preceding user message — delegate to
    /// retryFromMessage(precedingUser) and skip the sub-message rewrite.
    func retryFromToolBlock(blockId: UUID) {
        settlePendingStop(before: "retryFromToolBlock")  // [T-stop-cleanup-before-new-turn]
        guard !isProcessing else { return }

        // Locate the assistant UI message + the target block's index within it.
        guard let asstMsgIdx = messages.firstIndex(where: { m in
            m.role == .assistant && m.blocks.contains(where: { $0.id == blockId })
        }) else { return }
        let asstMsg = messages[asstMsgIdx]
        guard let blockIdx = asstMsg.blocks.firstIndex(where: { $0.id == blockId }) else { return }
        guard let targetToolUseId = asstMsg.blocks[blockIdx].toolUseId, !targetToolUseId.isEmpty else {
            // Not a tool block — nothing to anchor on.
            return
        }

        // Degenerate: target is the first block and no real content precedes it
        // in this turn → fall back to the preceding-user-message truncation.
        let hasPrecedingContent = asstMsg.blocks[..<blockIdx].contains { blk in
            switch blk.kind {
            case .text: return !blk.content.isEmpty
            default: return true  // any earlier tool/info block counts
            }
        }
        if !hasPrecedingContent {
            if let userIdx = messages[..<asstMsgIdx].lastIndex(where: { $0.role == .user }) {
                // Normal degenerate case: a user message precedes this turn —
                // truncate at it and re-run (existing whole-turn path).
                logger.info("[RerunToolBlock] degenerate → retryFromMessage(precedingUser) tuId=\(targetToolUseId.prefix(12))")
                retryFromMessage(messages[userIdx].id)
                return
            }
            // [T-ios-retry-double-header] No preceding user message (session
            // opens with an assistant turn — e.g. SOUL greeting / system-
            // triggered). Don't silently no-op: truncate from this assistant
            // message's START (drop the whole message + everything after, drop
            // its agentHistory entry + everything after) and re-run fresh.
            canResume = false
            userDidCancel = false
            delegationResultsMuted = false
            messages.removeSubrange(asstMsgIdx...)
            // [T-ios-retry-ui-clear] mirror the sub-message path: force a
            // top-level publish so the UI clears immediately on this tick
            // even when the snapshot binding's main-queue receive hasn't
            // fired yet.
            if !transitionSuspended { objectWillChange.send() }
            retrySnapshotReloadSignal.send()
            AppLogger(category: "RetryDiag").info("[RetryDiag] degenerate(noPrecedingUser) truncated asstMsgIdx=\(asstMsgIdx) messagesCount=\(self.messages.count)")
            // Find this assistant turn's agentHistory entry via the target's
            // toolUseId and drop it + all later entries.
            var dropFromEntry: Int? = nil
            outer0: for (ei, entry) in agentHistory.enumerated() where entry.role == .assistant {
                for part in entry.parts {
                    if case .toolUse(let id, _, _, _) = part, id == targetToolUseId {
                        dropFromEntry = ei
                        break outer0
                    }
                }
            }
            if let ei = dropFromEntry, ei < agentHistory.count {
                agentHistory.removeSubrange(ei...)
            }
            let keepCount = agentHistory.count
            logger.info("[RerunToolBlock] degenerate (no precedingUser) → truncate from assistant start tuId=\(targetToolUseId.prefix(12)) keepCount=\(keepCount)")
            if let sessionId {
                Task { await ChatStore.shared.deleteMessagesAfter(sessionId: sessionId, keepCount: keepCount) }
            }
            rebuildToolSnapshotsFromMessages()
            // No resume target — a fresh assistant message is appended by the
            // agent loop (messages.last is now whatever preceded this turn).
            launchRerunAgentLoop(label: "retryFromToolBlock")
            return
        }

        canResume = false
        userDidCancel = false
        delegationResultsMuted = false

        // --- Sub-message cut ---
        // 1. UI: trim this assistant message's blocks to before the target,
        //    and drop all later messages.
        // [T-ios-retry-ui-clear] Mutating `messages[asstMsgIdx].blocks` only
        // fires the *nested* ChatMessage.$blocks publisher; the collection
        // view's `lastMessageBlockCountSub` is wired to the CURRENT last
        // message (which at this moment is something AFTER asstMsgIdx, not
        // asstMsgIdx itself), so that publisher fires on an unrelated
        // message — no snapshot rebuild keys off the trim. The
        // removeSubrange below DOES publish on `vm.$messages` and triggers
        // applySnapshot, but the in-snapshot identifiers come from
        // `block.id` so the stale block items can linger one runloop tick
        // before the cells are dropped. Force a top-level publish so SwiftUI
        // / the collection-view bindings see the cut synchronously.
        messages[asstMsgIdx].blocks = Array(asstMsg.blocks[..<blockIdx])
        if asstMsgIdx + 1 < messages.count {
            messages.removeSubrange((asstMsgIdx + 1)...)
        }
        if !transitionSuspended { objectWillChange.send() }
        retrySnapshotReloadSignal.send()
        AppLogger(category: "RetryDiag").info("[RetryDiag] blocks truncated asstMsgIdx=\(asstMsgIdx) blockIdx=\(blockIdx) remainingBlocks=\(self.messages[asstMsgIdx].blocks.count) messagesCount=\(self.messages.count)")

        // 2. agentHistory: find the assistant entry carrying the target
        //    .toolUse(id==targetToolUseId), trim its parts to before that
        //    part, and drop every entry after it.
        var cutEntryIdx: Int? = nil
        var cutPartIdx: Int? = nil
        outer: for (ei, entry) in agentHistory.enumerated() where entry.role == .assistant {
            for (pi, part) in entry.parts.enumerated() {
                if case .toolUse(let id, _, _, _) = part, id == targetToolUseId {
                    cutEntryIdx = ei
                    cutPartIdx = pi
                    break outer
                }
            }
        }
        guard let entryIdx = cutEntryIdx, let partIdx = cutPartIdx else {
            // Anchor not found in agentHistory — abort without mutating further
            // to avoid a half-applied truncation. (Shouldn't happen: UI block
            // implies a persisted tool_use entry.)
            logger.warning("[RerunToolBlock] toolUseId \(targetToolUseId.prefix(12)) not found in agentHistory — aborting sub-message cut")
            return
        }

        // [RetryDiag] Index/parts alignment for the sub-message cut. asstMsgIdx
        // is the UI message; entryIdx/partIdx are the agentHistory cut point.
        // Under merged rendering one UI message maps to MANY agentHistory
        // entries, so blockIdx (UI) and partIdx (history) are NOT expected to
        // match — log both to confirm the anchor resolved to the right entry.
        AppLogger(category: "RetryDiag").info("[RetryDiag] sub-cut anchor tuId=\(targetToolUseId.prefix(12)) UI(asstMsgIdx=\(asstMsgIdx) blockIdx=\(blockIdx) blocks=\(self.messages[asstMsgIdx].blocks.count)) history(entryIdx=\(entryIdx) partIdx=\(partIdx) entryParts=\(self.agentHistory[entryIdx].parts.count) totalEntries=\(self.agentHistory.count))")

        dumpHistoryPairing("subcut-BEFORE entryIdx=\(entryIdx) partIdx=\(partIdx) targetTU=\(targetToolUseId.prefix(8))")
        let trimmedEntryDbId = agentHistory[entryIdx].dbMessageId
        let partsBefore = agentHistory[entryIdx].parts.count
        // Log exactly which parts the cut removes from this entry (partIdx...).
        // A tool_use here whose tool_result lives in a kept entry → orphan.
        let removedParts = agentHistory[entryIdx].parts[partIdx...].map { p -> String in
            switch p {
            case .text(let t): return "text(\(t.count)ch)"
            case .toolUse(let id, let name, _, _): return "TU(\(name),\(id.prefix(8)))"
            case .toolResult(let id, _, _, _, _, _, _, _, _): return "TR(\(id.prefix(8)))"
            case .imageData: return "image"
            }
        }
        AppLogger(category: "PairDiag").info("[PairDiag] subcut removes entry[\(entryIdx)].parts[\(partIdx)...]: [\(removedParts.joined(separator: ", "))]")
        agentHistory[entryIdx].parts = Array(agentHistory[entryIdx].parts[..<partIdx])
        let droppedEntries = (entryIdx + 1 < agentHistory.count) ? (agentHistory.count - (entryIdx + 1)) : 0
        if entryIdx + 1 < agentHistory.count {
            agentHistory.removeSubrange((entryIdx + 1)...)
        }
        AppLogger(category: "RetryDiag").info("[RetryDiag] sub-cut applied entry[\(entryIdx)] parts \(partsBefore)→\(self.agentHistory[entryIdx].parts.count), droppedTrailingEntries=\(droppedEntries), newHistoryCount=\(self.agentHistory.count), trimmedRowDbId=\(trimmedEntryDbId?.prefix(8) ?? "nil")")
        // If this fires ORPHANS, the sub-cut stranded a tool_result — i.e. the
        // (entryIdx, partIdx) cut point removed a tool_use whose tool_result
        // sits in an entry that was NOT dropped. That's the bug to chase.
        dumpHistoryPairing("subcut-AFTER")

        // 3. Persist: delete rows after the trimmed assistant entry, then
        //    rewrite the trimmed entry's row in place.
        let persistedKeepCount = agentHistory.count
        logger.info("[RerunToolBlock] sub-message cut tuId=\(targetToolUseId.prefix(12)) keepCount=\(persistedKeepCount) trimmedRow=\(trimmedEntryDbId?.prefix(8) ?? "nil")")
        if let sessionId {
            // [T-ios-retry-from-tool-block-oob] Snapshot the whole trimmed entry
            // (a value type) SYNCHRONOUSLY, before the Task suspends. The Task
            // below first awaits deleteMessagesAfter; during that suspension the
            // re-run agent loop (launchRerunAgentLoop, started further down) runs
            // runAgentLoop's "remove orphaned tool_result" pass, which can shrink
            // agentHistory (e.g. 19→18). If we then read `agentHistory[entryIdx]`
            // after the await, entryIdx is stale and the subscript traps with
            // "Index out of range" (ContiguousArrayBuffer.swift:692, crash
            // 2026-05-31). buildRawMessage takes an AgentMessage by value, so the
            // captured snapshot is all we need — never index the live array here.
            let trimmedEntry = agentHistory[entryIdx]
            let trimmedParts = trimmedEntry.parts
            let dbId = trimmedEntryDbId
            Task {
                await ChatStore.shared.deleteMessagesAfter(sessionId: sessionId, keepCount: persistedKeepCount)
                if let dbId {
                    let raw = await self.buildRawMessage(trimmedEntry)
                    await ChatStore.shared.updateMessageParts(messageId: dbId, parts: raw?.parts ?? Self.contentPartsFallback(trimmedParts))
                }
            }
        }

        // 4. toolSnapshots + re-run.
        // [T-ios-retry-double-header] The trimmed assistant message survives
        // at asstMsgIdx (now the last message) with `blockIdx` surviving
        // blocks. Resume INTO it so the new generation continues that turn
        // rather than appending a second assistant message (which rendered a
        // duplicate header). Mark its still-streaming/running tool blocks
        // cancelled first (none should remain before the cut point, but guard).
        for block in messages[asstMsgIdx].blocks {
            if case .streaming = block.toolStatus { block.toolStatus = .cancelled }
            else if case .running = block.toolStatus { block.toolStatus = .cancelled }
        }
        rebuildToolSnapshotsFromMessages()
        launchRerunAgentLoop(label: "retryFromToolBlock", resumeAt: asstMsgIdx, resumeBlocks: blockIdx)
    }

    /// Fallback ContentPart serialization if buildRawMessage returns nil
    /// (e.g. empty session id). Encodes only text/toolUse/toolResult parts —
    /// imageData parts are dropped (they're re-fetchable and not part of the
    /// truncation invariant). [T-ios-rerun-from-tool-block-position]
    private static func contentPartsFallback(_ parts: [AgentContentPart]) -> [ContentPart] {
        parts.compactMap { p in
            switch p {
            case .text(let t): return .text(t)
            default: return nil
            }
        }
    }
}
