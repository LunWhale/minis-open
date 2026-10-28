// Voice mode: Send waits for recognition, and failed recognition asks to retry.
//
//   [1] T-voice-send-waits-for-asr
//       Tapping Send while voice input still owes text (mic capturing, audio
//       held below the segment threshold, or a transcription in flight) stops
//       the mic, flushes every sample to ASR, waits, copies the final
//       transcript into the composer and only then sends. Before, Send
//       invalidated the in-flight transcription and dropped pending audio, so
//       the last sentence before the tap was lost.
//   [2] T-voice-asr-failure-retry-prompt
//       Every failed transcription (error or timeout) keeps its audio and asks
//       Retry / Discard, one utterance at a time. Before, only network errors
//       were retried (once, on a countdown) and everything else was dropped.
//   [3] System ASR watchdog scales with the audio and an empty timeout is a
//       failure, not "no speech".
//
// Standalone: `cd src/ios/MinisTests/Standalone && swift VoiceSendWaitsForASRTests.swift`

import Foundation

/// The chat page's sources, read as one text: AIChatView.swift (state and
/// `body`) first, then every other file under Views/Chat/AIChatView/ - the
/// old single AIChatView.swift was split into them.
func chatViewSource() -> String {
    let ios = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = ios.appendingPathComponent("Views/Chat/AIChatView")
    let main = dir.appendingPathComponent("AIChatView.swift")
    let rest = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "AIChatView.swift" }
        .sorted { $0.path < $1.path }
    return ([main] + rest).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
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
let panel = src("Views/Chat/Voice/VoiceInputPanel.swift")
let inline = src("Views/Chat/Voice/InlineVoiceInputView.swift")
let chat = chatViewSource()
let system = src("Providers/Voice/VoiceProvider+System.swift")
check("sources found", !panel.isEmpty && !inline.isEmpty && !chat.isEmpty && !system.isEmpty)

// MARK: - [1] finish before send

print("\n▶️  1. Send waits for recognition (T-voice-send-waits-for-asr)")

/// Port of the poll loop's decision in finishCaptureForSend.
enum Outcome: Equatable { case wait, send, holdForRetry, timeout }
struct Tick { var pendingSegments: Int; var inFlight: Int; var failedSince: Bool; var elapsed: Double }
func decide(_ ticks: [Tick], timeout: Double = 60) -> Outcome {
    var idle = 0
    for t in ticks {
        let isIdle = t.pendingSegments == 0 && t.inFlight == 0
        idle = (isIdle && t.elapsed >= 0.3) ? idle + 1 : 0
        guard idle >= 2 || t.failedSince || t.elapsed >= timeout else { continue }
        if t.failedSince { return .holdForRetry }
        if idle >= 2 { return .send }
        return .timeout
    }
    return .wait
}
check("idle immediately is NOT trusted before the flushed segment lands (settle 0.3 s)",
      decide([Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 0.1),
              Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 0.2)]) == .wait)
check("the late segment arrives and is transcribed, then send",
      decide([Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 0.1),
              Tick(pendingSegments: 1, inFlight: 0, failedSince: false, elapsed: 0.2),
              Tick(pendingSegments: 0, inFlight: 1, failedSince: false, elapsed: 0.3),
              Tick(pendingSegments: 0, inFlight: 1, failedSince: false, elapsed: 1.5),
              Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 1.6),
              Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 1.7)]) == .send)
check("one idle tick is not enough (needs two in a row)",
      decide([Tick(pendingSegments: 0, inFlight: 0, failedSince: false, elapsed: 0.4),
              Tick(pendingSegments: 0, inFlight: 1, failedSince: false, elapsed: 0.5)]) == .wait)
check("a failure while waiting holds the send for the retry prompt",
      decide([Tick(pendingSegments: 0, inFlight: 1, failedSince: false, elapsed: 0.4),
              Tick(pendingSegments: 0, inFlight: 0, failedSince: true, elapsed: 2.0)]) == .holdForRetry)
check("recognition still running at the cap → abandon, don't send half",
      decide([Tick(pendingSegments: 0, inFlight: 1, failedSince: false, elapsed: 60)]) == .timeout)

check("source: VM owes text only for DETECTED speech, pending audio or in-flight work",
      panel.contains("(vad.isCapturing && speechAwaitingSegment) || !pendingSegments.isEmpty || pendingTranscriptions > 0"))
check("source: an open-but-silent mic does not make a typed send wait",
      panel.contains("state = .recording\n        speechAwaitingSegment = true")
      && panel.contains("speechAwaitingSegment = false\n        guard !audioData.isEmpty else { return }"))
// [T-voice-send-lock] The wait is now keyed by an attempt (VoiceSendGate, see
// VoiceSendGateTests); these pins follow the same rules to their new places.
check("source: repeated sends while finishing are ignored",
      panel.contains("guard !sendGate.isWaiting else {"))
check("source: nothing owed → completes synchronously (normal send unchanged)",
      panel.contains("guard hasUntranscribedAudio else { completion(true); return }"))
check("source: capture is paused through the shared pause path (flush + raw fallback)",
      panel.contains("if vad.isCapturing {\n            pauseCapture(rawFallback: false)\n        } else {\n            flushPendingSegments()\n        }"))
check("source: the send path skips the raw-buffer fallback (no duplicate / silence transcription)",
      panel.contains("if rawFallback && !wasSpeaking && duration > 1.0 {"))
check("source: mic-button pause uses the same helper",
      panel.contains("if vad.isCapturing {\n            pauseCapture()\n            return\n        }"))
check("source: settle + two idle ticks",
      chat.contains("idleTicks = (idle && elapsed >= 0.3) ? idleTicks + 1 : 0")
      && panel.contains("let verdict = VoiceSendGate.verdict("))
check("source: timeout is 60 s", panel.contains("static let finishForSendTimeout: TimeInterval = 60"))

check("source: performSend defers first", chat.contains("func performSend(afterVoice: Bool = false) {\n        if !afterVoice, deferSendUntilVoiceFinished() { return }"))
check("source: performEnqueue defers first", chat.contains("func performEnqueue(afterVoice: Bool = false) {\n        if !afterVoice, deferSendUntilVoiceFinished() { return }"))
check("source: completion captures only the action channel",
      chat.contains("voiceVM.finishCaptureForSend { [composerActions] ok in\n            if ok { composerActions.send(.submitAfterVoice) }"))
check("source: final transcript is copied into the composer before sending",
      chat.contains("if !transcript.isEmpty, vm.inputText != transcript {\n            vm.inputText = transcript\n        }"))
check("source: send button is enabled while voice owes text",
      chat.contains("(hasText || hasReadyAttachment || voiceOwesText)")
      && chat.contains("voiceInputActive && (voiceVM.hasUntranscribedAudio || voiceVM.isFinishingForSend)"))

// MARK: - [2] failure keeps audio and asks

print("\n▶️  2. failed recognition asks Retry / Discard (T-voice-asr-failure-retry-prompt)")

final class Queue {
    struct Failed: Equatable { let id: Int; let seconds: Double }
    var items: [Failed] = []
    var prompt: Failed? { items.first }
    var transcribed: [Int] = []
    var generation = 0
    func fail(_ f: Failed, atGeneration g: Int) { if g == generation { items.append(f) } }
    func retry(editing: Bool = false) {
        guard let first = items.first, !editing else { return }
        items.removeFirst(); transcribed.append(first.id)
    }
    func discard() { if !items.isEmpty { items.removeFirst() } }
}
do {
    let q = Queue()
    q.fail(.init(id: 1, seconds: 42), atGeneration: 0)
    q.fail(.init(id: 2, seconds: 5), atGeneration: 0)
    check("a failure is kept and prompted", q.prompt?.id == 1)
    check("…one at a time, oldest first", q.items.count == 2)
    q.retry()
    check("Retry re-transcribes that audio", q.transcribed == [1])
    check("…and the next failure is asked next", q.prompt?.id == 2)
    q.discard()
    check("Discard drops it; nothing left to ask", q.prompt == nil)
    q.fail(.init(id: 3, seconds: 9), atGeneration: 0)
    q.retry(editing: true)
    check("Retry while the transcript editor is open keeps the audio queued", q.prompt?.id == 3)
    q.generation = 1
    q.fail(.init(id: 4, seconds: 3), atGeneration: 0)
    check("a failure for an already-sent composition is not prompted", !q.items.contains { $0.id == 4 })
}
check("source: every failure queues the audio (no network-only special case)",
      panel.contains("self.failedUtterances.append(FailedUtterance(\n                        audio: audioData,"))
check("source: the countdown auto-retry is gone",
      !panel.contains("startRetryCountdown") && !panel.contains("retryAudioData"))
check("source: retry while editing keeps the utterance",
      panel.contains("guard !isEditingTranscript else {\n            report(.droppedWhileEditing)\n            return\n        }\n        failedUtterances.removeFirst()"))
check("source: panel presents the prompt as an alert with Retry and Discard",
      inline.contains("presenting: viewModel.retryPrompt")
      && inline.contains("viewModel.retryFailedUtterance()")
      && inline.contains("viewModel.discardFailedUtterance()"))
check("source: countdown UI removed from the panel", !inline.contains("retryCountdown") && !inline.contains("manualRetry"))

// MARK: - [3] system ASR watchdog

print("\n▶️  3. system recognizer watchdog scales with the audio")
func watchdog(seconds: Double?) -> Double {
    guard let seconds else { return 8 }
    return min(max(8, seconds + 8), 120)
}
check("short utterance keeps the old 8 s floor", watchdog(seconds: 0) == 8)
check("a 60 s dictation gets 68 s, not 8", watchdog(seconds: 60) == 68)
check("capped at 2 minutes", watchdog(seconds: 600) == 120)
check("unreadable header falls back to 8 s", watchdog(seconds: nil) == 8)
check("source: watchdog helper matches", system.contains("return min(max(8, seconds + 8), 120)"))
check("source: empty result at the watchdog is a timeout failure",
      system.contains("finish(.failure(VoiceProviderError.timedOut))"))
check("source: partial text at the watchdog is still salvaged",
      system.contains("} else {\n                    finish(.success(salvage))\n                }"))

print("")
if failures == 0 { print("✅ ALL PASSED") } else { print("❌ \(failures) FAILURE(S)"); exit(1) }
