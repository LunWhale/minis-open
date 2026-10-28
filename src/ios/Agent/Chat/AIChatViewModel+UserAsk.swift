//
//  AIChatViewModel+UserAsk.swift
//  Minis
//
//  [T-user-ask] The user_ask tool inside the agent loop: definition, when it
//  is exposed, its system-prompt fragments, execution (persist → card →
//  wait), and the hooks that end a wait early (Stop, a new user message).
//

import Foundation
import UIKit

enum UserAskTool {
    static let name = "user_ask"
}

extension Notification.Name {
    /// [T-user-ask-notsent-merge] A message's run of not-sent user_ask calls
    /// changed (object: the message id); the message list re-plans its rows.
    static let userAskNotSentRegrouped = Notification.Name("userAskNotSentRegrouped")
}

private let userAskLogger = AppLogger(category: "UserAsk")

extension AIChatViewModel {

    // MARK: - Exposure (§6.2 / §21: setting on, not a sub agent)

    /// Decided once per run, when the tool list is built, and read by the
    /// system prompt so both agree for the whole run: a run that goes to the
    /// background later keeps the tool (the notification carries the ask).
    ///
    /// [T-user-ask-deferred] A run no one can answer while it runs (started by
    /// a programmatic prompt, or in the background) has the tool in deferred
    /// mode: the card is shown and stays open, the call returns at once, and
    /// the answer arrives as the user's next message. Only sub agents (and the
    /// setting) remove the tool.
    func computeUserAskExposure() -> (exposed: Bool, deferred: Bool, reason: String) {
        guard UserAskSettings.load().enabled else { return (false, false, "setting off") }
        if isHelper { return (false, false, "sub agent") }
        let foreground = UIApplication.shared.applicationState != .background
        if programmaticTurnOrigin == .userAskAnswer, !programmaticSilentTurn, foreground {
            return (true, false, "answer to a deferred ask, app in foreground")
        }
        if programmaticSilentTurn { return (true, true, "silent programmatic turn") }
        if let origin = programmaticTurnOrigin { return (true, true, "programmatic turn (\(origin.logLabel))") }
        if !foreground { return (true, true, "run started in background") }
        return (true, false, "interactive foreground run")
    }

    var userAskExposed: Bool { userAskExposedThisRun ?? computeUserAskExposure().exposed }
    var userAskDeferred: Bool { userAskDeferredThisRun ?? computeUserAskExposure().deferred }

    // MARK: - Definition (§3)

    static var userAskToolDefinition: AgentToolDefinition {
        let option = AgentSchemaNode.object(description: nil, properties: [
            (name: "label", node: .string(description: "Max 12 chars.")),
            (name: "description", node: .string(description: "One line.")),
        ], required: ["label"])
        let question = AgentSchemaNode.object(description: nil, properties: [
            (name: "type", node: .string(description: "Required. options = a decision; confirm = approval for one action.", enumValues: ["options", "confirm"])),
            (name: "question", node: .string(description: "Required. options: the question only, one sentence. confirm: the exact action (real command or target).")),
            (name: "header", node: .string(description: "Short chip, max 12 chars.")),
            (name: "options", node: .array(description: "type=options only. 2-4 genuinely different choices, best first. Omit for an open-ended question.", items: option, minItems: 2, maxItems: 4)),
            (name: "multi_select", node: .boolean(description: "type=options only.")),
            (name: "impact", node: .string(description: "type=confirm only: what can be lost, and whether it can be undone.")),
            (name: "risk", node: .string(description: "type=confirm only. Card colour only (high = red).", enumValues: ["medium", "high"])),
            (name: "default", node: .string(description: "type=options only, optional: 0-based index (e.g. \"0\") of the option you would pick. Never applied; returned to you on timeout as a suggestion.")),
        ], required: ["type", "question"])
        return AgentToolDefinition(
            name: UserAskTool.name,
            description: UserAskPromptText.toolDescription,
            parameters: [
                "questions": AgentToolParam(type: .array, description: "Required. 1-4 question objects, each with `type` and `question`.",
                                            schema: .array(description: nil, items: question, minItems: 1, maxItems: 4)),
            ],
            required: ["questions"]
        )
    }

    // MARK: - Execution

    /// Runs inside executeSingleToolUse. Parse → persist (with the batch's
    /// assistant row) → card + notification → wait → result JSON.
    func executeUserAsk(args: [String: Any], toolUseId: String, msgIdx: Int, blockIdx: Int) async -> (output: String, success: Bool) {
        let request: UserAskRequest
        switch UserAskParser.parse(args) {
        case .success(let r): request = r
        case .failure(let e):
            let out = "Error: \(e.message)"
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            // Never asked: same as a preflight rejection for the card and the
            // not-sent run (the caller would mark it failed a moment later).
            if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
                messages[msgIdx].blocks[blockIdx].toolStatus = .failed(message: out)
            }
            regroupUserAskNotSent(msgIdx: msgIdx)
            return (out, false)
        }
        guard let sessionId else {
            let out = UserAskResolver.encode(UserAskResolver.unavailable(request.questions))
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            return (out, true)
        }
        let s = UserAskSettings.load()
        // [T-user-ask-deferred] No one waits in a deferred run: no countdown.
        let deferred = userAskDeferred
        var ask = PendingAsk(requestId: UUID().uuidString, sessionId: sessionId, toolCallId: toolUseId,
                             questions: request.questions, createdAt: Date(),
                             timeoutMinutes: deferred ? 0 : s.timeoutMinutes)
        if deferred { ask.deferred = true }
        ask.sessionTitle = await ChatStore.shared.getSession(sessionId)?.title
        // §12.3 step 1: the snapshot is written before the card or any
        // notification can reference the request.
        let assistantJSON = currentBatchAssistantRaw.flatMap { try? JSONEncoder().encode($0) }
        let record = UserAskRecord(ask: ask, assistantRawJSON: assistantJSON,
                                   siblingToolUseIds: currentBatchToolUseIds.filter { $0 != toolUseId })
        if msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count {
            messages[msgIdx].blocks[blockIdx].kind = .userAskTool
        }
        if deferred {
            // [T-user-ask-deferred] Card up (and a notification when the app is
            // not active), then return at once: the answer comes back later as
            // the user's next message (UserAskCenter.deliverDeferred).
            UserAskCenter.shared.beginDeferred(record)
            notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
            let out = UserAskDeferred.toolResult(questionCount: request.questions.count)
            userAskLogger.info("[UserAsk] DEFERRED sid=\(sessionId.prefix(8)) tool=\(toolUseId.prefix(16)) questions=\(request.questions.count) — card left open, run continues")
            setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, out)
            return (out, true)
        }
        userAskLogger.info("[UserAsk] waiting_user ENTER sid=\(sessionId.prefix(8)) tool=\(toolUseId.prefix(16))")
        UserAskCenter.shared.begin(record)
        notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
        let result = await UserAskCenter.shared.wait(requestId: ask.requestId)
        // Statuses and length only: the result carries the user's own words
        // (Other / note), which stay out of the log files (design §8).
        let statuses = (((try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any])?["results"] as? [[String: Any]])?
            .map { $0["status"] as? String ?? "?" } ?? []
        userAskLogger.info("[UserAsk] waiting_user EXIT sid=\(sessionId.prefix(8)) statuses=\(statuses) resultLen=\(result.count)")
        setBlockContent(msgIdx: msgIdx, blockIdx: blockIdx, result)
        notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: blockIdx)
        return (result, true)
    }

    /// [T-user-ask-notsent-merge] A user_ask call in message `msgIdx` just
    /// ended without being asked: recompute the message's not-sent runs. The
    /// run's lead re-renders on its own (it observes its block); its cell is
    /// re-measured, as the title and reason change its height; and the list
    /// re-plans so that members of the run leave it.
    func regroupUserAskNotSent(msgIdx: Int) {
        guard msgIdx < messages.count else { return }
        let message = messages[msgIdx]
        guard UserAskNotSentGrouping.annotate(message.blocks) else { return }
        for (i, b) in message.blocks.enumerated() {
            if case .lead = UserAskNotSentStore.shared.role(b.id) { notifyUserAskHeightChanged(msgIdx: msgIdx, blockIdx: i) }
        }
        NotificationCenter.default.post(name: .userAskNotSentRegrouped, object: message.id)
        trackUserAskRetry()
    }

    // MARK: - Retry a not-sent run ([T-user-ask-notsent-retry])

    /// Start following `isProcessing` for the Retry offer (idempotent, held
    /// by UserAskRetryStore), and refresh it now. Called once the session has
    /// a not-sent run.
    func trackUserAskRetry() {
        UserAskRetryStore.shared.track(self)
        refreshUserAskRetryable()
    }

    /// Which not-sent run of this session offers Retry now (UserAskRetryRule).
    func refreshUserAskRetryable() {
        guard let sid = sessionId else { return }
        var items: [UserAskRetryRule.Item] = []
        for m in messages where !m.isInternalBridge {
            switch m.role {
            case .user:
                items.append(.userTurn)
            case .assistant:
                for b in m.blocks {
                    guard case .userAskTool = b.kind else { continue }
                    switch UserAskNotSentStore.shared.role(b.id) {
                    case .lead: items.append(.notSentLead(b.toolUseId ?? ""))
                    case .member: break
                    case .none: items.append(.asked)
                    }
                }
            default:
                break
            }
        }
        let lead = UserAskRetryRule.retryableLead(items, isProcessing: isProcessing,
                                                  retried: Set(UserAskRetryStore.shared.claims.ids))
        UserAskRetryStore.shared.setRetryable(sessionId: sid, leadToolUseId: lead, owner: self)
    }

    /// The user tapped Retry on a not-sent run: ask the model to call
    /// user_ask again. A hidden user turn (RawMessage.userAskRetryNudgeText) is
    /// appended to the history and persisted first, then the reply starts
    /// through the same path that answers an unanswered user turn - a normal
    /// foreground run, so user_ask is offered interactively, on any provider.
    /// The not-sent rows, their tool results and the stored messages are not
    /// touched. Returns false when the retry could not start.
    func retryNotSentUserAsk(leadToolUseId: String) async -> Bool {
        let tag = "[UserAsk] RETRY lead=\(leadToolUseId.prefix(16)) sid=\(sessionId?.prefix(8) ?? "nil")"
        guard !isProcessing, sessionId != nil, remoteDeviceId == nil, !isCompacting else {
            userAskLogger.info("\(tag) refused: processing=\(isProcessing) compacting=\(isCompacting)")
            return false
        }
        let nudge = AgentMessage(role: .user, parts: [.text(RawMessage.userAskRetryNudgeText)])
        let pid = await persistAgentMessage(nudge)
        // A run may have started while the row was being written.
        guard !isProcessing else {
            userAskLogger.info("\(tag) refused after persist: a run started")
            return false
        }
        var stored = nudge
        stored.dbMessageId = pid
        agentHistory.append(stored)
        userAskLogger.info("\(tag) hidden retry turn appended (persisted=\(pid != nil))")
        resumeUnansweredUserTurn(afterHiddenNudge: true)
        return isProcessing
    }

    private func setBlockContent(msgIdx: Int, blockIdx: Int, _ text: String) {
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        messages[msgIdx].blocks[blockIdx].content = text
    }

    /// [T-user-ask-deferred-delivery] A deferred card answered while this vm
    /// is mid-run: the stored result was rewritten, but no reload runs, so the
    /// transcript in memory still says `deferred`. Write the real result there
    /// too, so every later request carries the user's choice - even before
    /// (or without) the answer message. In place: no index moves.
    @discardableResult
    func replaceUserAskResultInMemory(toolUseId: String, output: String) -> Bool {
        var replaced = false
        for i in agentHistory.indices {
            for j in agentHistory[i].parts.indices {
                guard case .toolResult(let id, let name, _, let isError, let imageData, let imageMimeType,
                                       let pageURL, let imageLinuxPath, let isOffloadReadback) = agentHistory[i].parts[j],
                      id == toolUseId else { continue }
                agentHistory[i].parts[j] = .toolResult(id: id, name: name, content: output, isError: isError,
                                                      imageData: imageData, imageMimeType: imageMimeType,
                                                      pageURL: pageURL, imageLinuxPath: imageLinuxPath,
                                                      isOffloadReadback: isOffloadReadback)
                replaced = true
            }
        }
        for msg in messages {
            for k in msg.blocks.indices where msg.blocks[k].toolUseId == toolUseId {
                msg.blocks[k].content = output
            }
        }
        return replaced
    }

    /// The card changes height (shown, answered, collapsed): same re-measure
    /// path as a thinking block toggle.
    func notifyUserAskHeightChanged(msgIdx: Int, blockIdx: Int) {
        guard msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        NotificationCenter.default.post(name: .thinkingBlockToggled, object: messages[msgIdx].blocks[blockIdx].id)
    }

    // MARK: - Ending a wait early

    /// A new message from the user while a question waits (§11.4): the
    /// question is dismissed and the message becomes the next turn.
    func supersedePendingUserAsk() {
        guard let sessionId, UserAskCenter.shared.hasPendingAsk(inSession: sessionId) else { return }
        UserAskCenter.shared.dismissPending(inSession: sessionId, reason: .supersededByUserMessage)
    }

    /// Stop: end every wait in this session now (a checked continuation
    /// does not observe task cancellation on its own schedule).
    func cancelPendingUserAsk() {
        guard let sessionId else { return }
        UserAskCenter.shared.dismissPending(inSession: sessionId, reason: .stopped)
    }

    /// After recovery appended the answer to the transcript: continue the run.
    func resumeAfterUserAsk() {
        guard !isProcessing else { return }
        if !canResume {
            userAskLogger.info("[UserAsk] RECOVER resume skipped — canResume=false (tail not resumable)")
            return
        }
        userAskLogger.info("[UserAsk] RECOVER resuming run")
        resume()
    }
}
