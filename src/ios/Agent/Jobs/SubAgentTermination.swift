import Foundation

private let logger = AppLogger(category: "SubAgentTermination")

// [T-subagent-termination] How a sub agent run ended, recorded on the CHILD
// session so it can be read back after the fact.
//
// Before this, the reason a run ended lived in two places only: the
// in-memory AgentJobRegistry (gone after a restart) and the JSON of the
// parent's tool_result. The child session itself carried nothing, and every
// abnormal ending - an empty model reply (dropped by ChatStore's
// empty-assistant filter, its error with it), a request that failed after
// its retries, a cancel from the parent, the budget cut, the app being
// killed - left the same transcript: the last message is a tool result.
// `minis-sessions-cli status` could not tell them apart (field report
// 2026-10-04: 10 of 72 sub agent sessions "ended on a tool result").
//
// One record per child session, device-local (not synced: it describes a run
// on this device). Written `running` when the run starts and finalised when
// it ends; a record still `running` whose run is no longer alive is reported
// as `interrupted` - that is the app-killed case, which has no ending path to
// write from.

// BEGIN SubAgentTerminationCore
struct SubAgentTermination: Codable, Equatable {
    enum Reason: String, Codable {
        case running
        /// Ended with a final answer.
        case completed
        /// The time budget ran out without a final answer.
        case timeout
        /// Ended with no answer right after a failed tool call.
        case toolError = "tool_error"
        /// Stopped by the user, the parent, or the parent's Stop.
        case cancelled
        /// Still recorded as running, but the run is gone (app killed).
        case interrupted
        /// The model request failed, or the model returned no text.
        case modelError = "model_error"
    }

    /// How the result reached the parent.
    enum Delivery: String, Codable {
        /// Wait mode: the result was the delegate_task call's own return value.
        case inline
        /// Background mode: finished, the callback has not reached the parent yet.
        case pending
        /// Background mode: the callback started a turn in the parent.
        case delivered
        /// Background mode: accepted into the parent's prompt queue.
        case queued
        /// Background mode: the callback could not be delivered.
        case failed
    }

    var sessionId: String
    var jobId: String
    var parentSessionId: String?
    var reason: Reason
    var detail: String?
    var lastTool: String?
    /// success | failed | cancelled | running
    var lastToolStatus: String?
    var lastToolSummary: String?
    /// No final answer, but the agent did write something before it ended.
    var partialOutputAvailable: Bool = false
    /// The one-shot closing request was sent (see the agent loop).
    var closingAttempted: Bool = false
    var delivery: Delivery?
    var deliveryDetail: String?
    var startedAt: Date
    var endedAt: Date?

    var isTerminal: Bool { reason != .running }

    /// The snake_case fields shared by `sessions-cli status` and the parent's
    /// delegate_task payload.
    func payload() -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "termination_reason": reason.rawValue,
            "partial_output_available": partialOutputAvailable,
            "closing_attempted": closingAttempted,
        ]
        if let detail { out["termination_detail"] = detail }
        if let lastTool { out["last_tool_name"] = lastTool }
        if let lastToolStatus { out["last_tool_status"] = lastToolStatus }
        if let lastToolSummary { out["last_tool_result"] = lastToolSummary }
        if let delivery { out["delivery_state"] = delivery.rawValue }
        if let deliveryDetail { out["delivery_detail"] = deliveryDetail }
        if let endedAt { out["ended_at"] = iso.string(from: endedAt) }
        return out
    }
}

/// What the runner knows when a run ends - the inputs to `classify`.
struct SubAgentRunEnd {
    /// The loop state the runner observed: completed | cancelled | timeout.
    var loopStatus: String
    /// The child's `userDidCancel`. Also true when the RUNNER stopped it for
    /// the budget, since that stop goes through the same `cancel()` - see
    /// `stoppedForTimeout`.
    var userCancelled: Bool = false
    /// [T-subagent-timeout-reason] The runner itself cancelled the child
    /// because the budget and the wrap-up grace ran out
    /// (`helperStoppedForTimeout`). Lets `classify` tell that stop from a
    /// real user / parent Stop, which also sets `userCancelled`.
    var stoppedForTimeout: Bool = false
    /// The time budget ran out (wrap-up requested) at some point in the run.
    var budgetExpired: Bool = false
    /// The child's request error, if its last request failed.
    var errorText: String?
    /// The last assistant row carries text - the deliverable.
    var hasFinalAnswer: Bool
    var lastToolStatus: String?
}

enum SubAgentTerminationRules {
    /// How `noAnswerNote` starts - recognised so a note is never taken for
    /// an answer by a later reader (the callback cell, `resolvedStatus`).
    static let noAnswerNotePrefix = "(the agent ended without a final answer"

    /// One transcript row, reduced to what decides "did it end on an answer".
    struct TurnShape {
        var isAssistant: Bool
        var hasText: Bool
        var hasToolUse: Bool
    }

    /// A run has a final answer only when its LAST row is an assistant turn
    /// with text and no tool call. Text written alongside a tool call is
    /// narration ("let me check X"); a run that stops after it - cancelled,
    /// failed, an empty reply - ended mid-task, not on an answer, even though
    /// `lastAssistantText` returns that narration.
    static func endsWithFinalTurn(_ turns: [TurnShape]) -> Bool {
        guard let last = turns.last else { return false }
        return last.isAssistant && last.hasText && !last.hasToolUse
    }
    /// The one place a finished run is named. Order matters: an explicit stop
    /// or cut-off outranks what the transcript looks like, and a final answer
    /// outranks everything that happened before it.
    ///
    /// [T-subagent-timeout-reason] The runner's own budget stop comes first.
    /// It cancels the child through the same `cancel()` as a user Stop, so
    /// `userCancelled` is true for it too, and with cancel checked first a
    /// timed-out run was recorded `cancelled` ("stopped before it finished")
    /// while its card said "Timed out". In the background path the registry
    /// can even close the job as `cancelled` before the runner does, hence
    /// `stoppedForTimeout` and not only `loopStatus`. A Stop by the user or
    /// the parent - also during the wrap-up grace - never sets either, so it
    /// still lands on `.cancelled` below.
    static func classify(_ end: SubAgentRunEnd) -> (reason: SubAgentTermination.Reason, detail: String?) {
        if end.stoppedForTimeout || end.loopStatus == "timeout" {
            return (.timeout, "the time budget and the wrap-up grace ran out")
        }
        if end.loopStatus == "cancelled" || end.userCancelled {
            return (.cancelled, "stopped before it finished")
        }
        if end.hasFinalAnswer { return (.completed, nil) }
        if end.budgetExpired {
            return (.timeout, "the time budget ran out and the wrap-up turn produced no answer")
        }
        if let err = end.errorText?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
            return (.modelError, String(err.prefix(300)))
        }
        if end.lastToolStatus == "failed" {
            return (.toolError, "the last tool call failed and the model wrote no answer after it")
        }
        return (.modelError, "the model returned no text")
    }

    /// One line for a tool result: whitespace collapsed, capped.
    static func summarize(_ text: String, limit: Int = 300) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// What the parent reads in `result` when the run left no final answer.
    /// Names the reason and the last tool, so the parent can act on it
    /// (re-delegate narrower, fix the command) without opening the transcript.
    static func noAnswerNote(_ t: SubAgentTermination) -> String {
        var s = noAnswerNotePrefix + " - termination_reason=\(t.reason.rawValue)"
        if let d = t.detail, !d.isEmpty { s += ": \(d)" }
        s += "."
        if let tool = t.lastTool {
            s += " Last tool: \(tool) → \(t.lastToolStatus ?? "unknown")"
            if let r = t.lastToolSummary, !r.isEmpty { s += ": \(r)" }
            s += "."
        }
        if t.partialOutputAvailable { s += " It wrote partial notes before ending; they follow below." }
        s += " Re-delegate with a narrower task or a larger budget rather than reading its transcript.)"
        return s
    }
}

/// Persisted records, keyed by child session id. Main-actor: every writer
/// (HelperRunner, the job registry) and reader (sessions-cli) is.
@MainActor
final class SubAgentTerminationStore {
    static let shared = SubAgentTerminationStore(fileURL: SubAgentTerminationStore.defaultURL)
    /// Oldest records are dropped past this; a record is ~0.5 KB.
    static let capacity = 500
    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("subagent_terminations.json")
    }

    private let fileURL: URL?
    private var records: [String: SubAgentTermination] = [:]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: SubAgentTermination].self, from: data) {
            records = decoded
        }
    }

    func record(for sessionId: String) -> SubAgentTermination? { records[sessionId] }

    /// A run started (or a resumed run restarted) in `sessionId`.
    func begin(sessionId: String, jobId: String, parentSessionId: String?, now: Date = Date()) {
        if let old = records[sessionId], old.jobId == jobId, old.reason == .running { return }
        records[sessionId] = SubAgentTermination(sessionId: sessionId, jobId: jobId,
                                                 parentSessionId: parentSessionId,
                                                 reason: .running, startedAt: now)
        save()
    }

    /// Store a finished run. Keeps the start time and any delivery state an
    /// earlier write already recorded for the same job.
    func end(_ t: SubAgentTermination) {
        var t = t
        if let old = records[t.sessionId], old.jobId == t.jobId {
            t.startedAt = old.startedAt
            if t.delivery == nil { t.delivery = old.delivery; t.deliveryDetail = old.deliveryDetail }
        }
        records[t.sessionId] = t
        save()
    }

    /// Background callback progress. No-op for sessions without a record (a
    /// scheduled child-of-current job is not a delegate_task run).
    func setDelivery(sessionId: String, _ delivery: SubAgentTermination.Delivery, detail: String? = nil) {
        guard var t = records[sessionId] else { return }
        t.delivery = delivery
        t.deliveryDetail = detail
        records[sessionId] = t
        save()
    }

    /// The record as it should be reported now. A record still `running`
    /// whose run is not alive was cut off without an ending path - the app
    /// was killed or suspended mid-run - and is rewritten as `interrupted`.
    func resolved(sessionId: String, isLive: Bool, now: Date = Date()) -> SubAgentTermination? {
        guard var t = records[sessionId] else { return nil }
        if t.reason == .running, !isLive {
            t.reason = .interrupted
            t.detail = "the run stopped without reaching an ending (app killed or suspended)"
            t.endedAt = now
            records[sessionId] = t
            save()
        }
        return t
    }

    private func save() {
        if records.count > Self.capacity {
            let drop = records.values.sorted { $0.startedAt < $1.startedAt }.prefix(records.count - Self.capacity)
            for t in drop { records[t.sessionId] = nil }
        }
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
// END SubAgentTerminationCore

extension AIChatViewModel {
    /// The wire name of a tool block, as the model calls the tool.
    static func toolWireName(_ kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: "shell_execute"
        case .fileReadTool: "file_read"
        case .fileWriteTool: "file_write"
        case .fileEditTool: "file_edit"
        case .browserTool: "browser_use"
        case .readImageTool: "read_image"
        case .memoryTool(let a): a
        case .delegateTool: SubAgentDefinition.toolName
        case .userAskTool: UserAskTool.name
        default: "other"
        }
    }

    /// The child's last tool call: "name \"title\"", its status word and a
    /// one-line summary of its result.
    static func lastToolSnapshot(of child: AIChatViewModel) -> (name: String, status: String, summary: String)? {
        for msg in child.messages.reversed() where msg.role == .assistant {
            guard let block = msg.blocks.last(where: { $0.toolStatus != nil }), let status = block.toolStatus else { continue }
            let word: String
            var text = block.content
            switch status {
            case .success: word = "success"
            case .failed(let message):
                word = "failed"
                if !message.isEmpty, !text.contains(message) { text = message + " " + text }
            case .cancelled: word = "cancelled"
            case .running, .streaming: word = "running"
            }
            var name = toolWireName(block.kind)
            let title = block.toolSummary ?? block.toolDescription
            if !title.isEmpty { name += " \"\(SubAgentTerminationRules.summarize(title, limit: 80))\"" }
            return (name, word, SubAgentTerminationRules.summarize(text))
        }
        return nil
    }

    /// Classify a finished helper run, store it on the child session and
    /// return it for the parent payload.
    @discardableResult
    static func recordHelperTermination(child: AIChatViewModel, childId: String, jobId: String,
                                        parentSessionId: String?, loopStatus: String,
                                        budgetExpired: Bool, resultText: String,
                                        delivery: SubAgentTermination.Delivery) -> SubAgentTermination {
        let shapes = child.agentHistory.map { m in
            SubAgentTerminationRules.TurnShape(
                isAssistant: m.role == .assistant,
                hasText: m.parts.contains { if case .text(let s) = $0 { return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return false },
                hasToolUse: m.parts.contains { if case .toolUse = $0 { return true }; return false })
        }
        let hasFinal = Self.isFinalAnswer(resultText) && SubAgentTerminationRules.endsWithFinalTurn(shapes)
        let tool = lastToolSnapshot(of: child)
        let (reason, detail) = SubAgentTerminationRules.classify(SubAgentRunEnd(
            loopStatus: loopStatus, userCancelled: child.userDidCancel,
            stoppedForTimeout: child.helperStoppedForTimeout, budgetExpired: budgetExpired,
            errorText: child.errorMessage, hasFinalAnswer: hasFinal, lastToolStatus: tool?.status))
        var t = SubAgentTermination(sessionId: childId, jobId: jobId, parentSessionId: parentSessionId,
                                    reason: reason, startedAt: Date())
        t.detail = detail
        t.lastTool = tool?.name
        t.lastToolStatus = tool?.status
        t.lastToolSummary = tool?.summary
        t.partialOutputAvailable = reason != .completed && !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        t.closingAttempted = child.helperClosingAttempted
        t.delivery = delivery
        t.endedAt = Date()
        SubAgentTerminationStore.shared.end(t)
        logger.info("[subagent_term] child=\(childId.prefix(8)) job=\(jobId.prefix(8)) reason=\(reason.rawValue) lastTool=\(tool?.name ?? "-")/\(tool?.status ?? "-") partial=\(t.partialOutputAvailable) closing=\(t.closingAttempted)")
        return t
    }

    /// True when `text` can be the agent's own final answer: not empty, and
    /// not one of the app's "there is no answer" texts - the labelled earlier
    /// line `lastAssistantText` falls back to, `noAnswerNote`, or
    /// `emptyResultNote`.
    nonisolated static func isFinalAnswer(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let notes = [AgentJobRegistry.noFinalAnswerLabel, SubAgentTerminationRules.noAnswerNotePrefix,
                     "(the agent ended with status "]
        return !notes.contains { t.hasPrefix($0) }
    }

    /// The parent's `result` for a finished run: the answer itself, or the
    /// termination note followed by whatever partial text exists.
    static func helperResultText(_ resultText: String, termination t: SubAgentTermination) -> String {
        if t.reason == .completed { return resultText }
        let note = SubAgentTerminationRules.noAnswerNote(t)
        let partial = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        return partial.isEmpty ? note : note + "\n" + partial
    }
}
