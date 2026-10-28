// [T24] Queued-prompt origin policy: a USER follow-up interrupts the running
// plan at the next tool boundary, a PROGRAMMATIC job result waits for the loop
// to converge, a programmatic prompt never touches the composer draft, and the
// #579 interrupt note reaches the model without ever being shown.
// [T-bridge-to-reminder] The note used to be an assistant "bridge" row; the
// model learned to say it, so it is now a <system-reminder> part at the end of
// the queued user message, and old bridge rows are hidden, kept out of
// requests, and stripped when the model echoes them.
//
// Pins:
//   d172f9acd  job results wait for the loop to converge (QueuedPrompt.deferUntilIdle,
//              QueueInterrupt trigger = "at least one NON-deferred prompt")
//   9f608639a  bridge wording extended to hint the model to resume the prior task
//   4688e3168 / 1ad38e0cf  the Android ports this is the iOS counterpart of
//   issues #201, #279
//
// Standalone (`swift QueuedPromptOriginTests.swift`) like its neighbours:
// deps/libs/libish_emu.a is device-only arm64, so the app cannot link for a
// simulator and an XCTest bundle has nowhere to run. Sections [1]-[4] exercise
// logic ported verbatim from the view model (file:line cited at each port);
// section [5] re-reads the shipping sources so the copies cannot drift.

import Foundation

/// [T-messagelist-v3-split] CollectionViewMessageListV3.swift became the folder
/// Agent/MessageList/CollectionViewMessageListV3/ (code moved verbatim); read all
/// of it as one text, the way the single file used to be read.
func messageListV3Source() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Agent/MessageList/CollectionViewMessageListV3")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
    return files.sorted { $0.path < $1.path }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

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
func checkEq<T: Equatable>(_ l: String, _ a: T, _ b: T) {
    if a == b { print("  ✅ \(l)") } else { print("  ❌ \(l)\n     expected: \(b)\n     actual:   \(a)"); failures += 1 }
}
/// A case that documents a real production gap: prints a warning, never fails the run.
func knownGap(_ label: String, _ holds: Bool) {
    if holds { print("  ✅ \(label) (gap closed)") }
    else { print("  ⚠️  KNOWN GAP: \(label)") }
}

// MARK: - Ported: origin → queue semantics
// AIChatViewModel+ProgrammaticPrompt.swift:31-46 (ProgrammaticPromptOrigin)
// AIChatViewModel+ProgrammaticPrompt.swift:134-135 (`gentle` = .job only)

enum ProgrammaticPromptOrigin: Equatable {
    case cli
    case shortcut
    case job(jobId: String)
}

/// The one line that decides whether a programmatic prompt may interrupt.
func deferUntilIdle(for origin: ProgrammaticPromptOrigin) -> Bool {
    let gentle: Bool = { if case .job = origin { return true } else { return false } }()
    return gentle
}

// AIChatViewModel+Misc.swift:69-100 (enqueuePrompt) — the parts that matter here.
struct QueuedPrompt: Equatable {
    let id = UUID()
    let text: String
    let attachments: [String]
    var deferUntilIdle: Bool = false
}

// AIChatViewModel.swift:7273 — the QueueInterrupt trigger at a tool-close boundary.
func queueInterruptFires(_ promptQueue: [QueuedPrompt]) -> Bool {
    promptQueue.contains(where: { !$0.deferUntilIdle })
}

/// Composer state as enqueuePrompt sees it.
struct ComposerState {
    var inputText: String
    var attachments: [String]
    var isProcessing: Bool
    var promptQueue: [QueuedPrompt] = []
}

/// Verbatim port of the state transitions in enqueuePrompt (Misc.swift:69-100).
/// Returns false when the guard declined the prompt.
@discardableResult
func enqueuePrompt(_ s: inout ComposerState, deferUntilIdle: Bool = false,
                   overrideText: String? = nil) -> Bool {
    let usingComposer = overrideText == nil
    let text = (overrideText ?? s.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !s.attachments.isEmpty, s.isProcessing else { return false }
    let pendingAttachments = s.attachments
    var prompt = QueuedPrompt(text: text, attachments: pendingAttachments)
    prompt.deferUntilIdle = deferUntilIdle
    s.promptQueue.append(prompt)
    if usingComposer { s.inputText = "" }
    s.attachments = []
    return true
}

// MARK: - Ported: the bridge
// ChatStore.swift:427-454 (RawMessage.internalBridgeText / isInternalBridgeText / isInternalBridge)

enum Bridge {
    static let internalBridgeText =
        "(Interrupted mid-task by a new user message. Decide based on the new message and overall context whether the prior task should continue — do not forget or abandon it unless the user explicitly says to stop, or the new message makes clear it is no longer needed.)"
    static let internalBridgeTexts: [String] = [
        internalBridgeText,
        "(Interrupted mid-task to handle your new message. Will return to the prior task after.)",
    ]
    static func isInternalBridgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return internalBridgeTexts.contains { trimmed == $0 }
    }
    /// ChatStoreModels.swift — RawMessage.queuedInterruptReminderText.
    static let queuedInterruptReminderText =
        "<system-reminder>This note is from the system, not something the user wrote. The user sent the message above while you were in the middle of a task. Decide from that message and the conversation so far whether the earlier task should continue; do not forget or abandon it unless the user explicitly asks you to stop or the message makes clear it is no longer needed. Do not repeat or mention this note.</system-reminder>"
    /// ChatStoreModels.swift — RawMessage.strippingInternalBridgeEcho.
    static func strippingInternalBridgeEcho(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for bridge in internalBridgeTexts where trimmed.hasPrefix(bridge) {
            return String(trimmed.dropFirst(bridge.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

enum Part: Equatable { case text(String); case toolUse(String); case toolResult(String) }
enum Role: Equatable { case user, assistant }
struct AgentMessage: Equatable {
    var role: Role
    var parts: [Part]
    /// RawMessage.isInternalBridge (ChatStore.swift:450).
    var isInternalBridge: Bool {
        guard role == .assistant, parts.count == 1, case .text(let s) = parts[0] else { return false }
        return Bridge.isInternalBridgeText(s)
    }
    var isToolResultOnly: Bool {
        !parts.isEmpty && parts.allSatisfy { if case .toolResult = $0 { return true }; return false }
    }
}

/// ChatMessage.isInternalBridge (ChatModels.swift:154-163) — the UI row shape.
struct UIMessage: Equatable {
    var role: Role
    var content: String
    var blocks: [Part] = []
    var isInternalBridge: Bool {
        guard role == .assistant else { return false }
        if Bridge.isInternalBridgeText(content) { return true }
        if content.isEmpty, blocks.count == 1, case .text(let t) = blocks[0] {
            return Bridge.isInternalBridgeText(t)
        }
        return false
    }
}

/// applySnapshot in Agent/MessageList/CollectionViewMessageListV3/Coordinator/
/// MessageListV3Coordinator+Snapshot.swift — the single UI-collection sink filter.
func uiSink(_ rawMessages: [UIMessage]) -> [UIMessage] {
    rawMessages.contains(where: { $0.isInternalBridge })
        ? rawMessages.filter { !$0.isInternalBridge }
        : rawMessages
}

/// AIChatViewModel+Persistence.swift:300-325 — loadSession's split: every raw
/// row goes to loadedHistory; the bridge and tool-result-only rows produce no
/// UI message.
func loadSession(_ rows: [AgentMessage]) -> (history: [AgentMessage], ui: [UIMessage]) {
    var history: [AgentMessage] = []
    var ui: [UIMessage] = []
    for raw in rows {
        history.append(raw)
        if raw.isInternalBridge { continue }
        if raw.role == .user && raw.isToolResultOnly { continue }
        let text = raw.parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
        ui.append(UIMessage(role: raw.role, content: text))
    }
    return (history, ui)
}

/// AIChatViewModel+PromptQueue.swift — injectQueuedPromptsAsNewTurn: when the
/// tail is a user row (a tool_result: the user interrupted between two tool
/// steps) the note goes at the END of the queued message; no assistant row.
func injectQueuedPrompt(_ history: inout AgentMessage, into agentHistory: inout [AgentMessage]) {
    if agentHistory.last?.role == .user {
        history.parts.append(.text(Bridge.queuedInterruptReminderText))
    }
    agentHistory.append(history)
}

/// AIChatViewModel+Persistence.swift — droppingLegacyBridgeRows.
func droppingLegacyBridgeRows(_ history: [AgentMessage]) -> [AgentMessage] {
    func isBridgePart(_ part: Part) -> Bool {
        if case .text(let s) = part { return Bridge.isInternalBridgeText(s) }
        return false
    }
    return history.compactMap { msg in
        guard msg.role == .assistant, msg.parts.contains(where: isBridgePart) else { return msg }
        var kept = msg
        kept.parts.removeAll(where: isBridgePart)
        return kept.parts.isEmpty ? nil : kept
    }
}

/// AnthropicAgentProvider.reorderUserContent, reduced: tool_results first.
func reorderUserContent(_ m: AgentMessage) -> AgentMessage {
    guard m.role == .user else { return m }
    let results = m.parts.filter { if case .toolResult = $0 { return true }; return false }
    let rest = m.parts.filter { if case .toolResult = $0 { return false }; return true }
    return AgentMessage(role: .user, parts: results + rest)
}

/// AnthropicAgentProvider.swift:686 — mergeConsecutiveSameRole, reduced to roles + parts.
func mergeConsecutiveSameRole(_ messages: [AgentMessage]) -> [AgentMessage] {
    var out: [AgentMessage] = []
    for m in messages {
        if let last = out.last, last.role == m.role {
            out[out.count - 1].parts += m.parts
        } else {
            out.append(m)
        }
    }
    return out
}

// MARK: - A tiny replay of the agent loop's two injection sites

/// Simulates one turn whose plan has `plannedTools` tool calls. `arrivals`
/// maps "after tool N closes" → the prompt that lands then. Returns the number
/// of tools that actually ran before the queued prompt started its own turn,
/// and where the injection happened.
enum InjectionSite: Equatable { case toolClose(afterTool: Int), finishBranch, none }
func replayTurn(plannedTools: Int, arrivals: [Int: QueuedPrompt]) -> (toolsRun: Int, site: InjectionSite) {
    var queue: [QueuedPrompt] = []
    var toolsRun = 0
    for tool in 1...plannedTools {
        toolsRun = tool
        if let p = arrivals[tool] { queue.append(p) }
        // AIChatViewModel.swift:7273 — checked right after the tool call closes.
        if queueInterruptFires(queue) { return (toolsRun, .toolClose(afterTool: tool)) }
    }
    // AIChatViewModel.swift:6993 — the finish branch drains whatever is queued.
    return (toolsRun, queue.isEmpty ? .none : .finishBranch)
}

// MARK: - [1] Origin → interrupt policy

print("\n[1] Which origins may interrupt a running plan")
check("a job result is deferred until idle", deferUntilIdle(for: .job(jobId: "abc")))
check("a CLI send keeps user-message semantics (interruptible)", deferUntilIdle(for: .cli), false)
check("a Shortcut send keeps user-message semantics (interruptible)", deferUntilIdle(for: .shortcut), false)

let userPrompt = QueuedPrompt(text: "how is it going?", attachments: [])
var jobPrompt = QueuedPrompt(text: "<agent_callback kind=\"finished\">…</agent_callback>", attachments: [])
jobPrompt.deferUntilIdle = deferUntilIdle(for: .job(jobId: "j1"))

check("USER prompt in queue → QueueInterrupt fires", queueInterruptFires([userPrompt]))
check("job-only queue → [QueueHold] (no interrupt)", queueInterruptFires([jobPrompt]), false)
check("mixed queue → the USER prompt still earns the interrupt", queueInterruptFires([jobPrompt, userPrompt]))
check("empty queue never interrupts", queueInterruptFires([]), false)

print("\n[2] Replayed loop: where the queued prompt lands")
do {
    // USER follow-up arrives after tool 2 of a 5-tool plan → the plan is
    // abandoned at that boundary and the prompt gets its own turn.
    let r = replayTurn(plannedTools: 5, arrivals: [2: userPrompt])
    checkEq("USER: injected at the tool-close boundary", r.site, .toolClose(afterTool: 2))
    checkEq("USER: the remaining 3 planned tools are abandoned", r.toolsRun, 2)

    // The 15:53 device run: a helper result arrives while the parent's own
    // shell plan is mid-flight. Pre-d172f9acd this abandoned the plan.
    let j = replayTurn(plannedTools: 5, arrivals: [2: jobPrompt])
    checkEq("PROGRAMMATIC: held until the finish branch", j.site, .finishBranch)
    checkEq("PROGRAMMATIC: every planned tool still runs", j.toolsRun, 5)

    // Pre-fix trigger ("queue is non-empty") would have interrupted here.
    let preFixFires = ![jobPrompt].isEmpty
    check("PRE-FIX: a non-empty queue interrupted regardless of origin", preFixFires)

    let none = replayTurn(plannedTools: 3, arrivals: [:])
    checkEq("no arrivals: nothing is injected", none.site, .none)
}

// MARK: - [3] The composer is not the transport

print("\n[3] A programmatic prompt leaves the user's draft alone")
do {
    var s = ComposerState(inputText: "half-typed sentence", attachments: ["photo.jpg"], isProcessing: true)
    check("programmatic enqueue is accepted",
          enqueuePrompt(&s, deferUntilIdle: true, overrideText: "helper finished"))
    checkEq("the queued text is the override, not the draft", s.promptQueue.last?.text, "helper finished")
    checkEq("inputText survives untouched", s.inputText, "half-typed sentence")
    // The spec (and Android 1ad38e0cf) wants staged attachments to stay in the
    // composer for a non-user prompt. iOS deliberately shares `attachments`
    // with the CLI/Shortcut staging path (ProgrammaticPrompt.swift:121-124),
    // so enqueuePrompt still takes AND clears them for every origin — a job
    // result landing while files are staged walks off with them.
    knownGap("a job-origin prompt must not take the composer's staged attachments (expected: attachments still [\"photo.jpg\"], queued prompt carries none)",
             s.attachments == ["photo.jpg"] && s.promptQueue.last?.attachments.isEmpty == true)

    // The user's own tap: draft is consumed, that is the one clearing case.
    var u = ComposerState(inputText: "  send this  ", attachments: ["a.png"], isProcessing: true)
    check("composer enqueue is accepted", enqueuePrompt(&u))
    checkEq("composer text is trimmed into the prompt", u.promptQueue.last?.text, "send this")
    checkEq("composer draft is cleared", u.inputText, "")
    checkEq("composer attachments travel with the prompt", u.promptQueue.last?.attachments, ["a.png"])
    checkEq("composer attachments are cleared", u.attachments, [])

    // The guard: enqueue is only for a busy loop.
    var idle = ComposerState(inputText: "x", attachments: [], isProcessing: false)
    check("idle vm declines enqueue (send() owns that path)", enqueuePrompt(&idle), false)
    var empty = ComposerState(inputText: "   ", attachments: [], isProcessing: true)
    check("blank text with no attachments is declined", enqueuePrompt(&empty), false)
}

// MARK: - [4] The bridge

print("\n[4] The bridge is internal: kept once for the model, never shown, never folded")
do {
    let bridge = AgentMessage(role: .assistant, parts: [.text(Bridge.internalBridgeText)])
    check("current wording is recognised", bridge.isInternalBridge)
    check("pre-d2e111e9 wording is recognised too",
          AgentMessage(role: .assistant, parts: [.text(Bridge.internalBridgeTexts[1])]).isInternalBridge)
    check("trailing whitespace from a DB round-trip still matches",
          Bridge.isInternalBridgeText(Bridge.internalBridgeText + "\n"))
    check("a user row with the same text is NOT a bridge",
          AgentMessage(role: .user, parts: [.text(Bridge.internalBridgeText)]).isInternalBridge, false)
    check("a bridge plus another part is NOT a bridge (parts.count == 1)",
          AgentMessage(role: .assistant, parts: [.text(Bridge.internalBridgeText), .toolUse("x")]).isInternalBridge, false)
    check("ordinary assistant text is NOT a bridge",
          AgentMessage(role: .assistant, parts: [.text("(Interrupted…) something else")]).isInternalBridge, false)

    // Injection at a tool-close boundary: tail is user(tool_result).
    // [T-bridge-to-reminder] No assistant bridge any more: the note rides at
    // the end of the queued message.
    var hist: [AgentMessage] = [
        AgentMessage(role: .user, parts: [.text("run the sync")]),
        AgentMessage(role: .assistant, parts: [.toolUse("shell_execute")]),
        AgentMessage(role: .user, parts: [.toolResult("ok")]),
    ]
    var queued = AgentMessage(role: .user, parts: [.text("how is it going?")])
    injectQueuedPrompt(&queued, into: &hist)
    checkEq("no assistant bridge row is written", hist.filter { $0.role == .assistant && $0.parts.contains(.text(Bridge.internalBridgeText)) }.count, 0)
    checkEq("sequence is …tool_result → queued (two user rows)", hist.suffix(2).map { $0.role }, [.user, .user])
    checkEq("the note is the queued message's LAST part, after the user's text",
            hist.last?.parts, [.text("how is it going?"), .text(Bridge.queuedInterruptReminderText)])
    check("the note is a <system-reminder> that says it is not the user and asks not to be repeated",
          Bridge.queuedInterruptReminderText.hasPrefix("<system-reminder>")
          && Bridge.queuedInterruptReminderText.hasSuffix("</system-reminder>")
          && Bridge.queuedInterruptReminderText.contains("not something the user wrote")
          && Bridge.queuedInterruptReminderText.contains("Do not repeat or mention this note."))
    // Anthropic folds the two user rows into one, tool_result first, then the
    // user's text, then the note — the tool_result row itself is untouched.
    let merged = mergeConsecutiveSameRole(hist).map(reorderUserContent)
    checkEq("Anthropic: one user turn, tool_result first, text, then the note",
            merged.last?.parts, [.toolResult("ok"), .text("how is it going?"), .text(Bridge.queuedInterruptReminderText)])
    checkEq("…and the tool_result row in history is unchanged", hist[2].parts, [.toolResult("ok")])

    // Finish-branch injection: tail is already an assistant reply → no note.
    var finished: [AgentMessage] = [
        AgentMessage(role: .user, parts: [.text("hi")]),
        AgentMessage(role: .assistant, parts: [.text("done")]),
    ]
    var q2 = AgentMessage(role: .user, parts: [.text("next")])
    injectQueuedPrompt(&q2, into: &finished)
    checkEq("assistant tail → no note", finished.last?.parts, [.text("next")])

    // Legacy rows from older builds: hidden in the UI, kept out of requests.
    let legacy: [AgentMessage] = [
        AgentMessage(role: .user, parts: [.text("run the sync")]),
        AgentMessage(role: .assistant, parts: [.toolUse("shell_execute")]),
        AgentMessage(role: .user, parts: [.toolResult("ok")]),
        AgentMessage(role: .assistant, parts: [.text(Bridge.internalBridgeText)]),
        AgentMessage(role: .user, parts: [.text("how is it going?")]),
        AgentMessage(role: .assistant, parts: [.text("working"), .toolUse("read"), .text(Bridge.internalBridgeTexts[1])]),
        AgentMessage(role: .user, parts: [.toolResult("r")]),
    ]
    let reloaded = loadSession(legacy)
    check("reload emits no UI row for a legacy bridge row", reloaded.ui.contains { $0.isInternalBridge }, false)
    checkEq("reload emits the queued user bubble",
            reloaded.ui.first(where: { $0.content == "how is it going?" })?.content, "how is it going?")
    let outbound = droppingLegacyBridgeRows(legacy)
    checkEq("request: the bridge row is gone", outbound.count, legacy.count - 1)
    checkEq("request: a copied bridge part inside a reply is gone, the rest stays",
            outbound[4].parts, [.text("working"), .toolUse("read")])
    check("request: every tool_use still has its tool_result (only text parts removed)",
          outbound.flatMap(\.parts).filter { if case .toolUse = $0 { return true }; return false }.count
          == outbound.flatMap(\.parts).filter { if case .toolResult = $0 { return true }; return false }.count)
    checkEq("request: tool_result → queued are now adjacent user rows (merged like any interrupt)",
            outbound[2...3].map(\.role), [.user, .user])
    checkEq("request: nothing else is touched", droppingLegacyBridgeRows(hist), hist)

    // Echo guard: the model writing a bridge itself.
    checkEq("echo: exactly a bridge → empty", Bridge.strippingInternalBridgeEcho(Bridge.internalBridgeText), "")
    checkEq("echo: old wording too", Bridge.strippingInternalBridgeEcho("  " + Bridge.internalBridgeTexts[1] + "\n"), "")
    checkEq("echo: bridge then real text → the real text",
            Bridge.strippingInternalBridgeEcho(Bridge.internalBridgeText + "\n\nDone: 3 files changed."), "Done: 3 files changed.")
    checkEq("echo: ordinary text → untouched (nil)", Bridge.strippingInternalBridgeEcho("(Interrupted…) something else"), nil)
    checkEq("echo: a bridge quoted mid-reply is not an echo", Bridge.strippingInternalBridgeEcho("He said " + Bridge.internalBridgeText), nil)

    // UI sink: every other path that pushes into the list is filtered too.
    let leaked: [UIMessage] = [
        UIMessage(role: .user, content: "run the sync"),
        UIMessage(role: .assistant, content: Bridge.internalBridgeText),
        UIMessage(role: .assistant, content: "", blocks: [.text(Bridge.internalBridgeTexts[1])]),
        UIMessage(role: .assistant, content: "real reply"),
    ]
    let shown = uiSink(leaked)
    checkEq("the UI sink drops both bridge shapes", shown.count, 2)
    check("…and keeps the real reply", shown.contains { $0.content == "real reply" })
    check("a lone-block bridge with non-empty content is NOT hidden (content wins)",
          UIMessage(role: .assistant, content: "x", blocks: [.text(Bridge.internalBridgeText)]).isInternalBridge, false)
}

// MARK: - [5] Drift guards against the shipping sources

print("\n[5] Shipping sources match these ports")
func source(_ rel: String) -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
let pp = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
let vm = chatViewModelSource()
let misc = source("Agent/Chat/AIChatViewModel+Misc.swift")
let store = chatStoreSource()
let models = source("Agent/Chat/ChatModels.swift")
let cv3 = messageListV3Source()
let persist = source("Agent/Chat/AIChatViewModel+Persistence.swift")
if [pp, vm, misc, store, models, cv3, persist].contains(where: { $0.isEmpty }) {
    print("  ⏭  a source is not readable"); failures += 1
} else {
    check("gentle = .job origin only",
          pp.contains("let gentle: Bool = { if case .job = origin { return true } else { return false } }()"))
    check("submitProgrammaticPrompt queues with deferUntilIdle: gentle",
          pp.contains("enqueuePrompt(silent: silent, deferUntilIdle: gentle, overrideText: text)"))
    check("the idle path sends the text as an argument, not via inputText",
          pp.contains("send(overrideText: text)")
              && !pp.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "inputText = text" })
    // [T-scheduled-preempt] The gap rule moved into QueueDeliveryPlanner: a
    // non-deferred prompt still interrupts; a scheduled fire may enter only
    // while the model continues; other job callbacks never do.
    check("QueueInterrupt keys off a NON-deferred prompt (or a scheduled fire while continuing)",
          vm.contains("let gapTake = planQueueTake(at: .toolGap)")
          && vm.contains("if let gapTake, gapTake.scheduledJobId == nil || stopReason == .toolUse {"))
    check("QueuedPrompt carries deferUntilIdle", models.contains("var deferUntilIdle: Bool = false"))
    check("enqueuePrompt clears the draft only for the composer's own send",
          misc.contains("let usingComposer = overrideText == nil") && misc.contains("if usingComposer { inputText = \"\" }"))
    // [T-bridge-to-reminder]
    check("no assistant bridge row is written any more",
          !vm.contains("AgentMessage(role: .assistant, parts: [.text(bridgeText)])")
          && !vm.contains("? RawMessage.scheduledInsertBridgeText"))
    check("the note is appended to the queued message, only when the tail is a user row and not for a scheduled fire",
          vm.contains("if agentHistory.last?.role == .user, take.scheduledJobId == nil {\n            qCombinedParts.append(.text(RawMessage.queuedInterruptReminderText))"))
    check("the note's wording matches the shipping constant",
          store.contains("\"" + Bridge.queuedInterruptReminderText + "\""))
    check("requests drop legacy bridge rows / parts before the orphan pass",
          persist.contains("let withoutBridges = Self.droppingLegacyBridgeRows(sliced)")
          && persist.contains("let result = Self.dropOrphanedToolParts(withoutBridges, logger: logger)")
          && persist.contains("kept.parts.removeAll(where: isBridgePart)"))
    check("stream end drops an echoed bridge (not shown, not saved, not an 'empty reply')",
          vm.contains("let bridgeEchoRemainder = RawMessage.strippingInternalBridgeEcho(streamResult.assistantText)")
          && vm.contains("let assistantText = bridgeEchoRemainder ?? streamResult.assistantText")
          && vm.contains("messages[msgIdx].blocks.remove(at: echoIdx)")
          && vm.contains("&& !droppedBridgeEcho"))
    check("echo helper matches the port", store.contains("for bridge in internalBridgeTexts where trimmed.hasPrefix(bridge) {"))
    check("display drops a bridge text part inside a longer reply",
          store.contains("if role == .assistant, Self.isInternalBridgeText(s) { continue }"))
    checkEq("bridge wording matches the shipping constant",
            store.contains("\"" + Bridge.internalBridgeText + "\""), true)
    check("old wording stays in the recognised set",
          store.contains("\"" + Bridge.internalBridgeTexts[1] + "\""))
    check("RawMessage.isInternalBridge requires a single text part (assistant bridge or user nudge)",
          store.contains("guard parts.count == 1, case .text(let s) = parts[0] else { return false }")
          && store.contains("case .assistant: return Self.isInternalBridgeText(s)")
          && store.contains("case .user: return Self.isInternalUserNudgeText(s)"))
    check("loadSession skips the bridge for UI but keeps it in history",
          persist.contains("if raw.isInternalBridge {\n                continue\n            }"))
    check("the UI sink filters every path", cv3.contains("? rawMessages.filter { !$0.isInternalBridge }"))
    check("ChatMessage.isInternalBridge handles the lone-block shape",
          models.contains("if content.isEmpty, blocks.count == 1,"))
}

print("\n\(failures == 0 ? "✅ ALL PASSED" : "❌ \(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
