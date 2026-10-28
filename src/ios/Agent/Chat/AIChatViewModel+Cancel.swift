//
//  AIChatViewModel+Cancel.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, stopping work: cancel() (the Stop button) and cancelling
//  everything still bound to the previous model after a mid-conversation model
//  switch; also the model prompt fragment helper that sits with it.
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
    /// [T-ios-switch-model-ghost-retry] Stop everything still aimed at the
    /// PREVIOUS model when the user switches model mid-conversation.
    ///
    /// The bug this exists for: a turn fails with a 5xx, the user picks a
    /// different model from the header menu, the new model answers normally —
    /// and the gateway log still shows the OLD model being retried twice more,
    /// with its errors popping up over the working conversation. Pressing Stop
    /// first made it go away, which is the tell: `cancel()` tears the in-flight
    /// work down and switching model did not. Switching only wrote the new
    /// binding (`SessionModelPicker.bindToEntry/bindToGroup`) and posted
    /// `.sessionModelBindingChanged`, which NOTHING observed.
    ///
    /// Two survivors kept the old model alive:
    ///   1. **The agent loop.** `currentTask` is still parked in
    ///      `streamWithAutoRetry`'s countdown (`Task.sleep`) or mid-ladder. Its
    ///      countdown does re-read the binding, but only between attempts —
    ///      the attempt already in flight, and every `streamWithAutoRetry` call
    ///      that was handed a captured `provider:`, still belong to the old
    ///      model.
    ///   2. **Title generation.** `generateSessionTitleIfNeeded` captures
    ///      `resolveSubEntry()` ONCE before its detached `Task`, and with no
    ///      per-session sub model that resolves to the PRIMARY entry. It then
    ///      retries 3× — so a first-turn failure keeps calling the old model
    ///      after the switch, on its own schedule.
    ///
    /// This is deliberately NOT `cancel()`. Stop means "stop this conversation":
    /// it drops queued delegations, cancels live sub agents and kills scheduled
    /// timers. Switching model means "use a different model from here on" — sub
    /// agents, timers and shell commands are not addressed to the old model and
    /// must survive. So this cancels the model-bound work only.
    ///
    /// Safe to call when nothing is running: every branch is guarded, and the
    /// common case (switching model on an idle conversation) does nothing.
    ///
    /// [T-ios-switch-model-next-request] The loop is only cancelled while its
    /// auto-retry ladder is live. Cancelling unconditionally (the first version
    /// of this seam) also killed HEALTHY turns: switching model while a reply
    /// was streaming or a tool was running threw away the output being read and
    /// left the message in the resumable "interrupted" state. Users expect the
    /// switch to apply to the next request instead, silently.
    ///
    /// Why the ladder is the right line: the provider is captured per attempt,
    /// so the only thing that keeps calling the abandoned model after a switch
    /// is the retry ladder, parked in its countdown and about to fire the next
    /// attempt at the old model — the ghost retry this seam was written for.
    /// That attempt is unwanted by definition, so cancelling it costs nothing.
    /// A turn that is merely streaming or running tools is left alone and
    /// flagged via `pendingModelSwitch`; the loop swaps to the new model before
    /// its next LLM request. Android does the same: ef4a06e4d stopped cancelling
    /// a healthy turn, and T-android-switch-model-next-request applies the new
    /// model at the next request too (before that it waited for the next turn).
    @MainActor
    func cancelWorkBoundToPreviousModel(reason: String) {
        let hasLoop = currentTask != nil
        let retryLadderLive = autoRetryAttempt > 0 || autoRetryCountdown > 0
        let hadLoop = hasLoop && retryLadderLive
        let hadTitleGen = isTitleGenerating

        if hasLoop && !retryLadderLive {
            pendingModelSwitch = true
            logger.info("🔀 model switch (\(reason)): turn in flight and healthy — letting it continue; the next request will use the new model")
        }
        guard hadLoop || hadTitleGen else {
            if !hasLoop {
                logger.info("🔀 model switch (\(reason)): nothing in flight, nothing to cancel")
            }
            return
        }
        logger.info("🔀 model switch (\(reason)): cancelling work bound to the previous model — retryLadder=\(hadLoop) titleGen=\(hadTitleGen)")

        if hadLoop {
            // The loop is ending, so there is no next request to apply a
            // pending switch to; the next turn resolves the new binding anyway.
            pendingModelSwitch = false
            // Mark as user-initiated so the loop's error handler treats the
            // CancellationError as an interruption (message marked resumable)
            // rather than surfacing the old model's error — the whole point is
            // that the user has already moved on from it.
            userDidCancel = true
            currentTask?.cancel()
            currentTask = nil
            dropPresetsOfStoppedTurn()  // [T-preset-cleared-on-stop]
            // Clear the retry UI immediately; a stale "retrying in 5s…" under
            // the new model is exactly the ghost the user reported seeing.
            autoRetryAttempt = 0
            autoRetryCountdown = 0
            isProcessing = false
        }

        if hadTitleGen {
            // The detached title Task re-checks this generation token before
            // each attempt and bails when it no longer matches, so the captured
            // old-model entry cannot be used again.
            titleGenEpoch &+= 1
            isTitleGenerating = false
        }
    }

    /// [T-ios-switch-model-next-request] The model-specific part of the system
    /// prompt, exactly as the agent loop appends it after `baseSystemPrompt`
    /// (capability fragment, then behaviour fragment, each preceded by a blank
    /// line). Used to swap those fragments in place on a mid-turn switch.
    static func modelPromptFragments(_ model: LLMModel) -> String {
        var s = ""
        if let cap = model.capabilityPromptFragment { s += "\n\n" + cap }
        if let behavior = model.agentBehaviorPromptFragment { s += "\n\n" + behavior }
        return s
    }

    func cancel() {
        let lastBlocks = (messages.last?.role == .assistant) ? messages.last!.blocks.count : -1
        let lastRole = messages.last.map { $0.role == .assistant ? "assistant" : "user" } ?? "nil"
        logger.info("⏹️ cancel() START session=\(self.sessionId ?? "nil") isProcessing=\(self.isProcessing) lastRole=\(lastRole) lastBlocks=\(lastBlocks) currentTask=\(self.currentTask != nil)")
        dumpCandidateState("cancel-START")
        // [T-ios-queued-candidate-not-onscreen] Snapshot the queue + on-screen
        // messages at Stop time, and again 500ms later, so we can see whether a
        // queued candidate that drains after Stop actually lands on screen.
        dumpQueueSnapshot("stop-BEFORE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dumpQueueSnapshot("stop-AFTER+500ms")
        }
        isSuspended = false
        if let sid = sessionId {
            SessionConcurrencyManager.shared.cancelWait(sessionId: sid)
            // [T-sub-agents-busy] Stop means stop everything this conversation
            // has in flight, including sub agents delegated in the background.
            // The composer now shows Stop while only they are running, so it
            // has to actually stop them; leaving them alive would tick the
            // button back to Stop and post a result the user just cancelled.
            // Each cancelled job still reports back through its own callback.
            if !isHelper {
                // [T-sub-agents-queue] Drop the backlog FIRST: cancelling a
                // running job drains the queue, which would start the very
                // delegations the user just stopped.
                AgentJobRegistry.shared.dropQueuedDelegations(parent: sid, reason: "user stopped the conversation")
                // silent: a cancelled job normally reports back so a waiting
                // model learns what happened — but here the callback IS what
                // the user is stopping. Delivered, it wakes the parent, which
                // reads "cancelled" as a sub-task that failed and delegates it
                // again: three agents go grey and a fresh one starts, with
                // nothing touched. Stop has to leave the conversation quiet.
                AgentJobRegistry.shared.cancelAll(parent: sid, reason: "user stopped the conversation", silent: true)
            }
            // [T-scheduled-session-ownership] Also stop the TIMERS this
            // conversation created. `cancelAll(parent:)` above only reaches
            // `.childOfCurrent` jobs, so a `--target follow-up`/`new` loop
            // started from here survived Stop and kept firing into the chat the
            // user had just silenced — the one thing Stop is supposed to
            // guarantee.
            //
            // NOT silent, unlike the sub agent sweep above: that one is quiet
            // because a cancelled delegation would otherwise wake the parent
            // and get re-delegated. A timer has no such loop — the user
            // deliberately cancelled it, and the model should see that its
            // schedule is gone rather than wait for a fire that never comes.
            AgentJobRegistry.shared.cancelScheduled(createdBy: sid,
                                                    reason: "user stopped the conversation")
        }
        stopCurrentCommand()
        // If the loop is suspended waiting for foreground, resume it so
        // Task cancellation can propagate through the continuation.
        backgroundSuspended = false
        if let c = foregroundContinuation {
            foregroundContinuation = nil
            c.resume()
        }
        // If the loop is suspended for browser takeover, resume it.
        browserTakeoverActive = false
        takeoverTimeoutTask?.cancel()
        takeoverTimeoutTask = nil
        if let c = takeoverContinuation {
            takeoverContinuation = nil
            c.resume()
        }
        if let c = midActionTakeoverContinuation {
            midActionTakeoverContinuation = nil
            c.resume()
        }
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        // [T-user-ask] A question waiting on the user ends with the run.
        cancelPendingUserAsk()
        userDidCancel = true
        currentTask?.cancel()
        currentTask = nil
        dropPresetsOfStoppedTurn()  // [T-preset-cleared-on-stop]
        autoRetryAttempt = 0
        autoRetryCountdown = 0
        if let sid = sessionId {
            logger.info("🔥 cache keep-alive: cancelling on user cancel — session=\(sid.prefix(8))")
            CacheKeepAliveManager.shared.cancelKeepAlive(sessionId: sid)
        }
        // Don't modify blocks here — the cancelled task may still be writing to them.
        // The task's error handler checks userDidCancel to mark as interrupted and
        // set canResume. We set isProcessing = false immediately for responsive UI.
        isProcessing = false
        // Cancel compact task if running — the task's CancellationError handler
        // will update the status message and clean up state.
        if isCompacting {
            let origin = compactOrigin
            compactTask?.cancel()
            compactTask = nil
            compactOrigin = nil
            // [T-ios-compact-task-binding] Roll the queue back ONLY for the
            // entry point that created it.
            //
            // This block undoes compact-and-send's setup: that path enqueues
            // the user's message and shows it as a queued bubble before
            // compacting, so cancelling must put the text back in the input
            // box. Every other entry point (long-press, /compact, debug RPC)
            // compacts an existing conversation and enqueues nothing.
            //
            // Before the entry points were unified, long-press compaction was
            // an unretained task that `compactTask?.cancel()` could not reach,
            // so this block never ran for it. Now that it can, running it
            // unconditionally would be a new bug: cancelling a long-press
            // compaction while a compact-and-send prompt happened to be queued
            // would delete that prompt's bubble, overwrite the input box with
            // its text, and drop the queue — destroying a message the user is
            // still waiting on.
            if origin == .beforeSend {
                // Restore all queued compact-and-send messages back to input
                // (use the last one for inputText since it's the most recent)
                for queued in promptQueue {
                    messages.removeAll { $0.queuedPromptId == queued.id }
                }
                if let last = promptQueue.last {
                    inputText = last.text
                    attachments = last.attachments
                }
                promptQueue.removeAll()
            }
        }
        endBackgroundProcessing()

        // If there are queued prompts remaining, spawn a new task to continue
        // processing them. The old task is cancelled (stops the current agent
        // loop) but the queue should keep draining.
        if !promptQueue.isEmpty && !isCompacting {
            logger.info("⏹️ cancel() — \(promptQueue.count) queued prompt(s) remain, restarting drain")
            resumeQueueAfterCancel()
        }
    }
}
