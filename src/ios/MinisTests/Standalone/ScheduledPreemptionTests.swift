// Tests for [T-scheduled-preempt]: a scheduled fire that lands while its
// session is busy enters at the next tool gap as its own turn (one job per
// gap, piled-up fires of a job coalesced into the newest, with a reminder to
// finish the task in progress), instead of waiting for the whole turn and
// being merged with every other queued prompt.
//
//   [1] QueueDeliveryPlanner at a tool gap / at a turn end (verbatim port)
//   [2] reminder texts
//   [3] wiring in the agent loop, the drain, the bridge and the resume nudge
//
// Standalone: `swift ScheduledPreemptionTests.swift`.

import Foundation

/// The sources that used to be the single file Agent/Chat/ChatStore.swift -
/// the actor plus the files it was split into - read as one text.
func chatStoreSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["ChatStore", "ChatStore+Schema", "ChatStore+SessionCRUD", "ChatStore+SessionList",
                 "ChatStore+Search", "ChatStore+SessionQueries", "ChatStore+Folders",
                 "ChatStore+SessionDeletion", "ChatStore+StoredPreview", "ChatStore+Messages",
                 "ChatStore+Media", "ChatStore+CompactMarkers", "ChatStore+Tombstones",
                 "ChatStore+WebAppShortcuts", "ChatStore+Maintenance", "ChatStore+Helpers",
                 "ChatStore+UsageStats", "ChatStoreModels", "ContentPart+ProviderConversion",
                 "RawMessage+Conversion", "ChatStore+SyncDirty", "ChatStore+SyncRemoteSessions",
                 "ChatStore+SyncRemoteRecords", "ChatStore+BackupRestore"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

// MARK: - Port (verbatim from AIChatViewModel+ProgrammaticPrompt.swift)

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


// MARK: - Helpers

typealias Item = QueueDeliveryPlanner.Item
var ids: [String: UUID] = [:]
func id(_ k: String) -> UUID { if let v = ids[k] { return v }; let v = UUID(); ids[k] = v; return v }
func user(_ k: String) -> Item { Item(id: id(k), interruptsAtToolGap: true, scheduledJobId: nil) }
func helper(_ k: String) -> Item { Item(id: id(k), interruptsAtToolGap: false, scheduledJobId: nil) }
func fire(_ k: String, job: String) -> Item { Item(id: id(k), interruptsAtToolGap: false, scheduledJobId: job) }
func names(_ u: [UUID]) -> [String] { u.map { x in ids.first { $0.value == x }!.key } }

print("▶️  1a. at a tool gap")
check("empty queue: nothing", QueueDeliveryPlanner.take([], at: .toolGap) == nil)
check("only sub-agent callbacks: nothing (they wait for the turn to end)",
      QueueDeliveryPlanner.take([helper("h1"), helper("h2")], at: .toolGap) == nil)
do {
    let t = QueueDeliveryPlanner.take([fire("a1", job: "A"), user("u1"), helper("h1"), user("u2")], at: .toolGap)!
    check("the user's follow-ups go first, and only theirs", names(t.deliver) == ["u1", "u2"] && t.coalesced.isEmpty && t.scheduledJobId == nil)
}
do {
    let t = QueueDeliveryPlanner.take([helper("h1"), fire("a1", job: "A")], at: .toolGap)!
    check("a scheduled fire enters, skipping a sub-agent callback ahead of it", names(t.deliver) == ["a1"] && t.scheduledJobId == "A")
}
do {
    let q = [fire("a1", job: "A"), fire("b1", job: "B"), fire("a2", job: "A"), fire("a3", job: "A")]
    let t = QueueDeliveryPlanner.take(q, at: .toolGap)!
    check("one job per gap: the one that has waited longest", t.scheduledJobId == "A")
    check("its piled-up fires coalesce into the newest", names(t.deliver) == ["a3"] && names(t.coalesced) == ["a1", "a2"])
    check("the other job is left for the next gap", !t.deliver.contains(id("b1")) && !t.coalesced.contains(id("b1")))
}

print("\n▶️  1b. at a turn end / idle")
do {
    let t = QueueDeliveryPlanner.take([fire("a1", job: "A"), user("u1"), fire("a2", job: "A")], at: .turnEnd)!
    check("a scheduled fire at the head is its own turn (newest of its job)", names(t.deliver) == ["a2"] && names(t.coalesced) == ["a1"] && t.scheduledJobId == "A")
}
do {
    let t = QueueDeliveryPlanner.take([user("u1"), fire("a1", job: "A"), helper("h1"), user("u2")], at: .turnEnd)!
    check("otherwise every non-scheduled prompt arrives together, as before", names(t.deliver) == ["u1", "h1", "u2"] && t.scheduledJobId == nil)
    check("…and the scheduled fire is not merged into it", !t.deliver.contains(id("a1")))
}
check("three fires of one loop job arrive as ONE turn carrying the newest, not a merged message",
      { let t = QueueDeliveryPlanner.take([fire("x1", job: "X"), fire("x2", job: "X"), fire("x3", job: "X")], at: .turnEnd)!
        return names(t.deliver) == ["x3"] && t.coalesced.count == 2 }())

print("\n▶️  2. reminder texts")
let mid = ScheduledInsertText.midTaskReminder(title: "Check CI", hasPreset: false, coalescedCount: 0)
check("wrapped in <system-reminder> (the chat strips it from user rows)", mid.hasPrefix("<system-reminder>") && mid.hasSuffix("</system-reminder>"))
check("names the task and says it was inserted, not a tool result nor a user request",
      mid.contains("Scheduled task \"Check CI\" fired and was inserted here") && mid.contains("not your last tool result, not a user request."))
check("tells the model to resume its prior task (it is not finished)", mid.hasSuffix(" Handle briefly, then resume your unfinished prior task.</system-reminder>"))
check("short: one line, no metaphor or repeated explanation",
      !mid.contains("\n") && !mid.contains("does not replace") && !mid.contains("cancel your plan") && mid.count < 200)
check("no preset / coalesced sentence when not applicable", !mid.contains("preset") && !mid.contains("more time"))
let midP = ScheduledInsertText.midTaskReminder(title: "Check CI", hasPreset: true, coalescedCount: 2)
check("preset: already ran, read the result, do not re-run", midP.contains(" Preset command already ran; read the result below, don't re-run it."))
check("coalesced count, plural", midP.contains(" It also fired 2 more times while busy; only this latest is shown."))
check("coalesced count, singular", ScheduledInsertText.midTaskReminder(title: "t", hasPreset: false, coalescedCount: 1).contains("fired 1 more time while busy"))
check("order: identity, preset, coalesced, then resume",
      { let r = midP; let a = r.range(of: "not a user request.")!.lowerBound, b = r.range(of: "Preset command")!.lowerBound,
            c = r.range(of: "It also fired")!.lowerBound, d = r.range(of: "Handle briefly")!.lowerBound
        return a < b && b < c && c < d }())
check("turn-end note only when something was coalesced",
      ScheduledInsertText.coalescedNote(title: "t", coalescedCount: 0) == nil
      && ScheduledInsertText.coalescedNote(title: "t", coalescedCount: 3)!
         == "<system-reminder>Scheduled task \"t\" also fired 3 more times while busy; only the latest is shown above.</system-reminder>")

// MARK: - Sources

let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ rel: String) -> String { (try? String(contentsOf: ios.appendingPathComponent(rel), encoding: .utf8)) ?? "" }
let vm = chatViewModelSource()
let pp = read("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
let store = chatStoreSource()
let presetSrc = read("Agent/Jobs/ScheduledPresetToolCall.swift")
let me = (try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)) ?? ""
func between(_ s: String, _ a: String, _ b: String) -> String {
    guard let r = s.range(of: a), let e = s.range(of: b, range: r.upperBound..<s.endIndex) else { return "" }
    return String(s[r.lowerBound..<e.lowerBound])
}
let norm = { (s: String) in s.filter { !$0.isWhitespace } }

print("\n▶️  3. wiring")
check("the planner/reminder port is verbatim",
      !between(pp, "enum QueueDeliveryPoint: Equatable {", "extension AIChatViewModel {").isEmpty
      && norm(between(pp, "enum QueueDeliveryPoint: Equatable {", "extension AIChatViewModel {"))
         == norm(between(me, "enum QueueDeliveryPoint: Equatable {", "// MARK: - Helpers")))
check("the planner reads a prompt's kind from the queue (non-deferred = interrupts, scheduled = envelope job id)",
      pp.contains("interruptsAtToolGap: !prompt.deferUntilIdle") && pp.contains("scheduledJobId: Self.scheduledCallback(inQueuedText: prompt.text)?.jobId")
      && pp.contains("callback.kind == .scheduled"))
let gap = between(vm, "let gapTake = planQueueTake(at: .toolGap)", "await waitIfBackgroundSuspended()")
check("tool gap: after this batch's tool_results are persisted",
      (vm.range(of: "await ChatStore.shared.appendMessages(batch)")?.lowerBound ?? vm.endIndex)
        < (vm.range(of: "let gapTake = planQueueTake(at: .toolGap)")?.lowerBound ?? vm.startIndex))
check("…and a scheduled fire only while the model continues (stop reason tool_use)",
      gap.contains("if let gapTake, gapTake.scheduledJobId == nil || stopReason == .toolUse {"))
check("a gap insertion of a scheduled fire owes one resume nudge; a user's follow-up does not",
      gap.contains("scheduledResumeNudgeOwed = gapInjection == .scheduledFire"))
let inject = between(vm, "func injectQueuedPromptsAsNewTurn(", "/// [T-ios-retry-orphan-toolresult] Compact dump")
check("injection takes one planned take, not the whole queue",
      inject.contains("guard let take = planQueueTake(at: point) else { return .none }")
      && inject.contains("let queued = removeQueueTake(take)") && !inject.contains("promptQueue.removeAll()"))
check("the reminder is its own text part AFTER the envelope",
      inject.contains("if let reminder { qCombinedParts.append(.text(reminder)) }")
      && (inject.range(of: "for prompt in queued {")?.lowerBound ?? inject.endIndex)
        < (inject.range(of: "if let reminder { qCombinedParts.append(.text(reminder)) }")?.lowerBound ?? inject.startIndex))
// [T-bridge-to-reminder] No assistant bridge row any more: the fire's own
// <system-reminder> (midTaskReminder) says to resume the unfinished task.
check("a scheduled insert writes no bridge row; its reminder carries the resume note",
      !inject.contains("RawMessage.scheduledInsertBridgeText") && !inject.contains("AgentMessage(role: .assistant, parts: [.text(bridgeText)])")
      && inject.contains("if agentHistory.last?.role == .user, take.scheduledJobId == nil {"))
check("…and old persisted scheduled bridges are still hidden like every bridge", store.contains("scheduledInsertBridgeText,\n    ]") || store.contains("        scheduledInsertBridgeText,\n"))
check("coalesced fires leave the queue and their queued bubbles", pp.contains("messages.removeAll { msg in msg.isQueued && msg.queuedPromptId.map { dropped.contains($0) } == true }"))
let finish = between(vm, "let endInjection = await injectQueuedPromptsAsNewTurn(", "[T-subagent-steer-continues-loop] A steer that arrived")
check("turn end: one take per turn", finish.contains("at: .turnEnd"))
check("the user's own message cancels the owed nudge", finish.contains("if endInjection == .prompts { scheduledResumeNudgeOwed = false }"))
check("resume nudge: only after a clean end_turn, not an error or a stop",
      finish.contains("if scheduledResumeNudgeOwed, stopReason == .endTurn, !canResume, !self.userDidCancel {"))
check("…at most once (cleared before it is sent)",
      (finish.range(of: "scheduledResumeNudgeOwed = false\n                    let nudge")?.lowerBound != nil))
check("…as the hidden user row, continuing in the same bubble (no new assistant message)",
      finish.contains("AgentMessage(role: .user, parts: [.text(RawMessage.scheduledResumeNudgeText)])")
      && finish.contains("committedBlockCount = messages[msgIdx].blocks.count")
      && !between(finish, "let nudge = AgentMessage", "continue\n").contains("messages.append("))
check("the nudge is recognized as internal (never rendered) and is itself a system-reminder",
      store.contains("case .user: return Self.isInternalUserNudgeText(s)")
      && store.contains("\"<system-reminder>The scheduled task above has been handled."))
check("the owed flag is local to one loop run", vm.contains("        var scheduledResumeNudgeOwed = false\n"))
let drain = between(vm, "private func drainQueuedPromptsInner() async {", "// Yield once to let any last-moment enqueuePrompt() calls execute")
check("idle / post-loop drain: one take per turn with the coalesced note",
      drain.contains("guard let take = self.planQueueTake(at: .turnEnd) else { break }")
      && drain.contains("if let drainReminder { combinedParts.append(.text(drainReminder)) }")
      && !drain.contains("self.promptQueue.removeAll()"))
check("preset reuse: the preset still runs from the envelope found in the trailing user texts, part by part",
      pp.contains("guard message.role == .user else { break }") && pp.contains("if case .text(let t) = part { trailing.append(t) }")
      && presetSrc.contains("trailingUserTexts"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
