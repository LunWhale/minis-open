// [T-tts-external-pause-stuck] Read-aloud spun forever and never spoke.
//
// A route change while another app played over Bluetooth latched an
// external-audio pause (secondaryAudioShouldBeSilencedHint = true). The matching
// clear never came, so VoiceOutputPlayer.isPaused stayed true: every later
// read-aloud synthesized its whole queue and pumpPlayback held all of it, while
// the UI still showed "reading". Explicit read-aloud / resume now clears the
// latch, and an external pause is mirrored as "paused" in the UI.
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift TTSExternalPauseStuckTests.swift`

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
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func src(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}

/// The markdown renderer module (Views/Chat/Markdown/, formerly the single file
/// SelectableMarkdownView.swift), read as one text with its files in path order.
func markdownModuleSource() -> String {
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Views/Chat/Markdown")
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
    return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

let player = src("Providers/Voice/VoiceOutputPlayer.swift")
let coord = src("Providers/Voice/AudioSessionCoordinator.swift")
let state = src("Providers/Voice/VoiceProviderResolver.swift")
let vm = chatViewModelSource()
let md = markdownModuleSource()
check("sources found", ![player, coord, state, vm, md].contains { $0.isEmpty })

/// Port of the coordinator latch + player pause gate.
final class Model {
    var externalLatch = false
    var isPaused = false
    var uiPaused = false
    var reading = false
    var queue: [Int] = []
    var played: [Int] = []
    func externalPause() {
        guard !externalLatch else { return }
        externalLatch = true; isPaused = true
        if reading { uiPaused = true }
    }
    func externalClear() {
        guard externalLatch else { return }
        externalLatch = false; resume()
        if reading { uiPaused = false }
    }
    func resume() {
        externalLatch = false
        guard isPaused else { return }
        isPaused = false; pump()
    }
    func clearForExplicitReadAloud() {
        let had = externalLatch; externalLatch = false
        guard isPaused || had else { return }
        resume()
    }
    func pump() { guard !isPaused else { return }; played += queue; queue.removeAll() }
    /// stopSession with nothing of ours playing leaves isPaused alone (as shipped).
    func readReplyFromStart(_ units: [Int], fixed: Bool) {
        if fixed { clearForExplicitReadAloud() }
        reading = true; uiPaused = false
        queue += units; pump()
    }
}

print("\n▶️  1. latched external pause vs explicit read-aloud")
do {
    let old = Model()
    old.externalPause()                       // 19:37 route change, never cleared
    old.readReplyFromStart([1, 2, 3], fixed: false)
    check("before: nothing plays (the reported bug)", old.played.isEmpty)
    check("before: UI claims not paused → spins", old.reading && !old.uiPaused)

    let m = Model()
    m.externalPause()
    m.readReplyFromStart([1, 2, 3], fixed: true)
    check("after: explicit read-aloud plays everything", m.played == [1, 2, 3])
    check("after: latch cleared, so the next interruption pauses again", !m.externalLatch)
    m.externalPause()
    check("…a new external pause is honoured", m.isPaused && m.uiPaused)
    m.queue = [4]; m.pump()
    check("…and holds new audio", m.played == [1, 2, 3])
    m.resume()
    check("user resume plays it and clears the latch", m.played == [1, 2, 3, 4] && !m.externalLatch)
}
do {
    let m = Model()
    m.readReplyFromStart([1], fixed: true)
    m.externalPause()
    check("external pause while reading shows paused", m.uiPaused)
    m.externalClear()
    check("external clear un-pauses the UI", !m.uiPaused && !m.isPaused)
    let idle = Model()
    idle.externalPause()
    check("external pause while idle does not flip the UI", !idle.uiPaused)
}

print("\n▶️  2. source invariants")
check("coordinator exposes clearExternalPauseLatch",
      coord.contains("func clearExternalPauseLatch(reason: String) -> Bool {\n        guard pausedByExternalAudio else { return false }\n        pausedByExternalAudio = false"))
check("coordinator mirrors pause/resume into the UI",
      coord.contains("VoiceOutputState.shared.reflectExternalPause(true)")
      && coord.contains("VoiceOutputState.shared.reflectExternalPause(false)"))
check("player.resume clears the latch before its isPaused guard",
      player.contains("AudioSessionCoordinator.shared.clearExternalPauseLatch(reason: \"resume\")\n        guard isPaused else { return }"))
check("player has the explicit read-aloud override",
      player.contains("func clearPauseForExplicitReadAloud() {"))
check("pumpPlayback logs a held unit", player.contains("TTS hold #"))
check("readReplyFromStart clears the pause after stopping this session",
      vm.contains("stopSpeechForThisSession()\n        // [T-tts-external-pause-stuck]")
      && vm.contains("VoiceOutputPlayer.shared.clearPauseForExplicitReadAloud()"))
check("VM mirrors external pause only while reading",
      vm.contains("guard isReadingAloud, speechPaused != paused else { return }"))
check("menu read-aloud (read all / selection) clears the pause",
      md.contains("static func activateReadAloudState() {\n        // [T-tts-external-pause-stuck]"))
check("SpeechControlling carries reflectExternalPause", state.contains("func reflectExternalPause(_ paused: Bool)\n}"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
