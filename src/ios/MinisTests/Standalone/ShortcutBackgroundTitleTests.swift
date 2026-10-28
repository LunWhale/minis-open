#!/usr/bin/env swift
// [T-shortcut-bg-title] A session run from Shortcuts got no title.
//
// Field log (Telegram report, 2026-09-25): the Shortcuts run's only turn ended
// at 17:13:10 with
//   [StreamEnd] FINAL FLUSH text len=668 blockContent len=0 uiSuspended=true appState=2
//   [StreamText] DEFERRED — uiSuspended=true …
// and no [TitleGen] line at all. The title appeared only after the user's
// second message, in the foreground ("[TitleGen] Summary … userTurns=2").
//
// Root cause: in the agent loop, title generation ran BEFORE the deferred
// streaming text was flushed into the message blocks. While the UI is
// suspended — app in background (every Shortcuts run), a session-switch
// transition, a scroll — the final text lives only in the deferred queue, so
// generateSessionTitleIfNeeded read an empty text block, found no tool calls to
// fall back on, and returned silently without counting an attempt. A text-only
// turn has one iteration, so nothing retried.
//
// Run: swift ShortcutBackgroundTitleTests.swift
import Foundation

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
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label) — expected true, got false")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

// MARK: - [1] Model of the stream-end sequence

print("══ [1] a turn that ends while the UI is suspended ══")
/// Minimal model: the text block, the deferred queue, and the title gate
/// (generateSessionTitleIfNeeded: assistant block text, else tool-call args).
final class Turn {
    var blockText = ""
    var deferred: String? = nil
    let suspended: Bool
    init(suspended: Bool) { self.suspended = suspended }
    func finalFlush(_ text: String) { if suspended { deferred = text } else { blockText = text } }
    func flushDeferred() { if let d = deferred { blockText = d; deferred = nil } }
    func titleGate(toolCalls: Int) -> Bool { !blockText.isEmpty || toolCalls > 0 }
}
func run(suspended: Bool, flushFirst: Bool, toolCalls: Int = 0) -> Bool {
    let t = Turn(suspended: suspended)
    t.finalFlush("这张图片是哔哩哔哩（Bilibili）移动端App的一个官方…")
    if flushFirst { t.flushDeferred() }
    let titled = t.titleGate(toolCalls: toolCalls)
    if !flushFirst { t.flushDeferred() }
    return titled
}
check("OLD order, foreground: titled", run(suspended: false, flushFirst: false))
check("OLD order, background text-only turn: NOT titled (the reported bug)", !run(suspended: true, flushFirst: false))
check("OLD order, background with tool calls: titled (why it looked intermittent)", run(suspended: true, flushFirst: false, toolCalls: 1))
check("NEW order, background text-only turn: titled", run(suspended: true, flushFirst: true))
check("NEW order, foreground: unchanged", run(suspended: false, flushFirst: true))

// MARK: - [2] The agent loop flushes before it generates the title

print("\n══ [2] AIChatViewModel: flush → title, in the loop's stream-end block ══")
do {
    let vm = chatViewModelSource()
    let titleCall = "generateSessionTitleIfNeeded(toolEntries: toolEntries.map { (name: $0.name, args: $0.args) })"
    check("exactly one title call site in the loop", vm.components(separatedBy: titleCall).count - 1 == 1)
    if let t = vm.range(of: titleCall) {
        // The flush must be the call immediately preceding the title call.
        let before = vm[..<t.lowerBound]
        let lastFlush = before.range(of: "flushDeferredStreamingTextUpdateIfNeeded()", options: .backwards)
        let lastFinalFlushLog = before.range(of: "[StreamEnd] FINAL FLUSH", options: .backwards)
        check("a deferred-text flush precedes the title call",
              lastFlush != nil && lastFinalFlushLog != nil && lastFlush!.lowerBound > lastFinalFlushLog!.lowerBound)
        let between = lastFlush.map { String(vm[$0.upperBound..<t.lowerBound]) } ?? ""
        check("…with nothing but comments between them",
              between.split(separator: "\n").allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        // And no second flush left behind after it in the same block (would
        // mean the move was a copy, not a move).
        let after = vm[t.upperBound...]
        let nextPersist = after.range(of: "var assistantParts: [AgentContentPart] = []")
        let flushAfter = after.range(of: "flushDeferredStreamingTextUpdateIfNeeded()")
        check("…and not duplicated before persistence",
              nextPersist != nil && (flushAfter == nil || flushAfter!.lowerBound > nextPersist!.lowerBound))
    } else {
        check("title call found", false)
    }

    let title = source("Agent/Chat/AIChatViewModel+TitleGeneration.swift")
    check("the empty-text exit is logged, not silent",
          title.contains("[TitleGen] skip: no assistant text or tool calls to summarise yet"))
}

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
