//
//  AIChatViewModel+Speech.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, speech output: speed / pause, read a reply from the start,
//  speak text, dynamic cloud-TTS windowing (feedDynamicTTS with its coherent
//  cut), the queued speech path and per-reply engine choice. State it keeps
//  (replyUsesCloudTTS, hasClearedTTSForCurrentTurn, the synthesizer) is stored
//  in AIChatViewModel.swift.
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

extension AIChatViewModel {
    /// Explicitly set the playback speed (player control speed chip).
    func setSpeechSpeed(_ s: Float) {
        VoiceOutputPreferences.speedMultiplier = s
        speechSpeed = s
        // Apply to the currently-playing cloud audio in real time (System TTS
        // can't re-rate a queued utterance, so it takes effect on the next one).
        VoiceOutputPlayer.shared.setRate(s)
        syncSpeechStateToGlobal()
    }

    /// Cycle to the next speed step (1.0→1.25→1.5→2.0→1.0).
    func nextSpeechSpeed() {
        let steps = VoiceOutputPreferences.speedSteps
        let cur = VoiceOutputPreferences.speedMultiplier
        let idx = steps.firstIndex(of: cur) ?? 0
        setSpeechSpeed(steps[(idx + 1) % steps.count])
    }

    /// Pause or resume speech playback (handles both System + cloud engines).
    func toggleSpeechPause() {
        if speechPaused {
            // Resume
            if speechSynthesizer.isPaused { speechSynthesizer.continueSpeaking() }
            VoiceOutputPlayer.shared.resume()
            speechPaused = false
        } else {
            // Pause
            if speechSynthesizer.isSpeaking { speechSynthesizer.pauseSpeaking(at: .word) }
            VoiceOutputPlayer.shared.pause()
            speechPaused = true
        }
        syncSpeechStateToGlobal()
    }

    /// Read an entire assistant reply aloud FROM THE START. Clears any in-progress
    /// TTS (so it doesn't overlap), enables read-replies, then queues the whole
    /// reply split into sentences. No-op while that reply is still streaming (the
    /// caller greys the menu item out, but we guard here too).
    func readReplyFromStart(_ message: ChatMessage) {
        // Build the reply's plain text from its text blocks.
        let fullText = message.blocks
            .compactMap { block -> String? in
                if case .text = block.kind { return block.content }
                return nil
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        // Clear whatever THIS session is playing/queuing so the replay starts
        // clean — other concurrent sessions' queued speech is left alone.
        stopSpeechForThisSession()
        // [T-tts-external-pause-stuck] An explicit tap overrides a leftover
        // external-audio pause, which would otherwise hold every queued unit.
        VoiceOutputPlayer.shared.clearPauseForExplicitReadAloud()
        // Ensure read-replies is on (and reflected in prefs/voice VM).
        if !speakEnabled {
            speakEnabled = true
            VoiceOutputPreferences.isEnabled = true
        }
        // [T-readaloud-menu-force-unmute] Explicit user intent beats the mute
        // switch. Enabling `speakEnabled` alone was not enough: `canSpeakNow`
        // resolves to `VoiceOutputState.canPlay` == `isEnabled && !isMuted`, so
        // while muted every `speakQueued` below returned early and the tap did
        // nothing at all — silently, with no feedback.
        unmuteForExplicitReadAloud()
        isReadingAloud = true
        // Split into sentences and queue each — reuses the streaming segmenter so
        // sizing / dynamic window behave the same as live playback.
        let (sentences, _) = extractNewSentences(from: fullText, spokenOffset: 0)
        let units = sentences.isEmpty ? [fullText] : sentences
        for s in units { speakQueued(s) }
    }

    /// [T-readaloud-menu-force-unmute] Lift a TEMPORARY mute because the user
    /// explicitly asked for read-aloud from a long-press menu.
    ///
    /// The mute switch (capsule speaker) is meant to silence *automatic* reply
    /// TTS, not to veto a deliberate "read this" tap. Since `canSpeakNow` folds
    /// `isMuted` into its gate, leaving it set made those menu actions no-ops
    /// with no user-visible feedback.
    ///
    /// Only `isMuted` is touched — deliberately NOT `isEnabled`, so this cannot
    /// resurrect read-replies for someone who switched the feature fully off;
    /// callers that want it on (e.g. `readReplyFromStart`) enable it themselves.
    /// `isMuted`'s `didSet` persists the change, matching what a manual un-mute
    /// tap on the capsule does. Mirrors `SelectableMarkdownView`'s
    /// `activateReadAloudState()`, which already did this for the menus that
    /// bypass this view model.
    private func unmuteForExplicitReadAloud() {
        let state = VoiceOutputState.shared
        guard state.isMuted else { return }
        VoiceLog.log("[ReadAloud] explicit menu action — clearing temporary mute")
        state.isMuted = false
    }

    /// Turn read-replies off entirely, stopping playback.
    func disableSpeech(resetSpeed: Bool) {
        stopSpeech()
        speakEnabled = false
        VoiceOutputPreferences.isEnabled = false
        if resetSpeed {
            VoiceOutputPreferences.speedMultiplier = 1.0
            speechSpeed = 1.0
        }
    }

    /// [T-tts-external-pause-stuck] Mirror an external-audio pause in the UI.
    /// Only while reading: a pause latched when nothing is being read must not
    /// flip an idle capsule to "paused". Only the cloud engine is paused by the
    /// coordinator, so the System synthesizer is left alone.
    func reflectExternalPause(_ paused: Bool) {
        guard isReadingAloud, speechPaused != paused else { return }
        speechPaused = paused
        syncSpeechStateToGlobal()
    }

    /// Push this VM's live read-aloud state up to the global VoiceOutputState so
    /// the home-screen capsule reflects it. Also registers this VM as the active
    /// controller so global-capsule actions forward here.
    func syncSpeechStateToGlobal(registerActive: Bool = false) {
        if registerActive { VoiceOutputState.shared.registerActive(self) }
        VoiceOutputState.shared.syncState(reading: isReadingAloud,
                                          paused: speechPaused,
                                          speed: speechSpeed)
    }

    /// Stop all speech and reset paused state.
    func stopSpeech() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        VoiceOutputPlayer.shared.stopAll()
        speechPaused = false
        isReadingAloud = false
        // End the reply-TTS intent (coordinator drops .replyTTS; if nothing else
        // needs audio it deactivates the session).
        AudioSessionCoordinator.shared.end(.replyTTS)
        syncSpeechStateToGlobal()
    }

    /// Session-scoped stop: clears only THIS session's units from the shared
    /// cloud TTS queue (other concurrent chats' queued speech keeps playing) and
    /// stops the System synthesizer (engine-global — it has no queue to scope).
    /// Used at reply start / read-from-start so one chat starting a new reply
    /// can't wipe another chat's in-flight speech, which the old global
    /// `stopSpeech()` did (queue hijack + text loss across concurrent sessions).
    func stopSpeechForThisSession() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        VoiceOutputPlayer.shared.stopSession(sessionId ?? "")
        speechPaused = false
        isReadingAloud = false
        if !useCloudTTS {
            // System engine path: nothing else shares the intent, release it.
            // The cloud path releases inside stopSession only when the WHOLE
            // queue is idle — ending it here would tear the audio session out
            // from under another session's still-playing audio.
            AudioSessionCoordinator.shared.end(.replyTTS)
        }
        syncSpeechStateToGlobal()
    }

    /// Speak text aloud if speakEnabled is on. Interrupts any current speech.
    /// When Background Speak is enabled, configures audio session for .playback
    /// so TTS continues in the background and keeps the process alive.
    func speakText(_ rawText: String) {
        // Strip emoji / non-speakable glyphs before TTS.
        let text = VoiceTextSanitizer.sanitize(rawText)
        // [T-readaloud-menu-force-unmute] Sole caller is the "Read Selection"
        // long-press menu action, i.e. an explicit request to hear THIS text —
        // so lift a temporary mute rather than dropping the request on the
        // floor. Ordered before the `canSpeakNow` guard, which folds in
        // `isMuted` and would otherwise return early.
        unmuteForExplicitReadAloud()
        // [T-issue316-read-selection-enable] `canSpeakNow` also folds in the
        // read-replies MASTER switch, which defaults to off — so for anyone who
        // never turned reply-TTS on, "Read Selection" hit the guard below and
        // returned silently while "Read from Start" worked, because that path
        // enables the switch itself. Do the same here: picking this menu item is
        // an explicit request to hear something, exactly as it is for
        // `readReplyFromStart` and `activateReadAloudState`, which were the only
        // two of the three read-aloud entry points doing this. Setting
        // `speakEnabled` persists via `VoiceOutputState.isEnabled`'s didSet.
        if !speakEnabled { speakEnabled = true }
        guard canSpeakNow, !text.isEmpty else {
            VoiceLog.log("speakText SKIP — canSpeakNow=\(canSpeakNow) capturing=\(VoiceModePreference.shared.isCapturing) empty=\(text.isEmpty)")
            return
        }
        isReadingAloud = true
        syncSpeechStateToGlobal(registerActive: true)
        // Reply TTS (System + cloud are the SAME source/intent) — declare it once
        // up front; the resolved provider then picks the engine.
        AudioSessionCoordinator.shared.begin(.replyTTS)
        if useCloudTTS {
            VoiceOutputPlayer.shared.enqueue(text, sessionId: sessionId ?? "")
            return
        }
        if BackgroundKeepAliveManager.shared.backgroundSpeakEnabled {
            BackgroundKeepAliveManager.shared.stopSilentAudio()
            speechSynthesizer.delegate = speechDelegate
        }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .word)
        }
        let utterance = makeUtterance(text)
        speechSynthesizer.speak(utterance)
    }

    /// Dynamic TTS window: decide how much of the accumulated `buffer` to send to
    /// cloud TTS now, returning the LEFTOVER text the caller should keep buffering.
    /// Rules:
    ///  • Idle (no buffered/playing audio) → send the FIRST batch ASAP (low latency).
    ///  • Otherwise wait until the buffer reaches the player's recommended minimum
    ///    (grows with buffered audio → longer, more coherent batches mid/late reply).
    ///  • PARAGRAPH-COHERENT: once eligible, prefer cutting at a PARAGRAPH boundary
    ///    (blank line / newline) so a whole paragraph is synthesized in ONE request
    ///    and doesn't get split across batches (which made Gemini render the two
    ///    halves in slightly different timbres). Only fall back to a sentence cut
    ///    if the paragraph would exceed `maxBatchChars` (synth-timeout guard).
    ///  • `force` (stream end / tool) → send everything left.
    /// System TTS has no synth metrics → it just sends immediately, whole buffer.
    /// Returns the unsent leftover (caller stores it back into the buffer).
    func feedDynamicTTS(_ buffer: String, force: Bool) -> String {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // REAL-TIME global gate: if read-replies was turned off mid-stream (e.g.
        // the user muted from the global capsule), drop any remaining buffered /
        // force-flushed text instead of speaking it. `speakEnabled` is a live proxy
        // for VoiceOutputState.shared, so this reflects the latest global state —
        // not a stream-start snapshot.
        guard canSpeakNow else {
            VoiceLog.log("feedDynamicTTS DROP — read-replies off (speakEnabled=\(speakEnabled) capturing=\(VoiceModePreference.shared.isCapturing))")
            return ""
        }

        // System path: no dynamic window, speak each batch as it arrives.
        guard useCloudTTS else {
            speakQueued(trimmed)
            return ""
        }

        let player = VoiceOutputPlayer.shared
        let minChars = player.recommendedMinChars
        let maxChars = VoiceOutputPlayer.maxBatchChars
        let idle = !player.hasPendingAudio
        let len = trimmed.count

        if force {
            VoiceLog.log("dyn-window FLUSH(force) len=\(len)")
            speakQueued(trimmed)
            return ""
        }

        // Not yet eligible → keep accumulating (unless idle: send ASAP for latency).
        guard idle || len >= minChars else {
            VoiceLog.log("dyn-window HOLD len=\(len) < minChars=\(minChars)")
            return trimmed
        }

        // Eligible. Send the largest whole-PARAGRAPH prefix that fits maxChars; if a
        // single paragraph already exceeds maxChars, fall back to a sentence cut.
        let cut = Self.coherentCutIndex(in: trimmed, minChars: idle ? 1 : minChars, maxChars: maxChars)
        let head = String(trimmed[trimmed.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(trimmed[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty {
            // No boundary found within maxChars and below min → keep waiting.
            VoiceLog.log("dyn-window HOLD(no-boundary) len=\(len)")
            return trimmed
        }
        VoiceLog.log("dyn-window FLUSH len=\(head.count) (of \(len)) minChars=\(minChars) idle=\(idle) leftover=\(tail.count)")
        speakQueued(head)
        return tail
    }

    /// Find the index to cut `text` at: the LAST paragraph boundary (newline) at or
    /// before `maxChars` and at/after `minChars`; else the last sentence-ender in
    /// that window; else `maxChars` (hard cap) if the text already exceeds it; else
    /// `endIndex` (send all — it's a complete short unit).
    nonisolated private static func coherentCutIndex(in text: String, minChars: Int, maxChars: Int) -> String.Index {
        let chars = Array(text)
        let n = chars.count
        if n <= maxChars {
            // Whole buffer fits a batch — prefer ending on a paragraph break if the
            // buffer doesn't already end at one; otherwise send it all as one unit.
            // (Sending all keeps a multi-sentence paragraph intact.)
            return text.endIndex
        }
        // Buffer exceeds maxChars: must cut. Search [minChars, maxChars] for the
        // best boundary — paragraph (newline) first, then sentence-ender.
        let lo = max(1, min(minChars, maxChars))
        var paragraphCut = -1, sentenceCut = -1
        let enders = AIChatViewModel.speechEndersForCut
        var i = lo - 1
        while i < min(maxChars, n) {
            let c = chars[i]
            if c == "\n" { paragraphCut = i + 1 }
            else if enders.contains(c) { sentenceCut = i + 1 }
            i += 1
        }
        let idx = paragraphCut > 0 ? paragraphCut : (sentenceCut > 0 ? sentenceCut : maxChars)
        return text.index(text.startIndex, offsetBy: idx)
    }

    /// Sentence-ender set used by the coherent-cut fallback (mirrors the SSE
    /// segmenter's tier-1 enders).
    nonisolated static let speechEndersForCut: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";"]

    /// Enqueue text for speech without interrupting current utterance.
    /// Used for streaming text playback — sentences are queued in order.
    /// AVSpeechSynthesizer automatically queues multiple speak() calls; the cloud
    /// player keeps its own ordered queue + synthesize pipeline.
    func speakQueued(_ rawText: String) {
        // Strip emoji / non-speakable glyphs before TTS.
        let text = VoiceTextSanitizer.sanitize(rawText)
        guard canSpeakNow, !text.isEmpty else {
            VoiceLog.log("speakQueued SKIP — speakEnabled=\(speakEnabled) isCapturing=\(AudioSessionCoordinator.shared.isCapturing) empty=\(text.isEmpty)")
            return
        }
        isReadingAloud = true
        syncSpeechStateToGlobal(registerActive: true)
        AudioSessionCoordinator.shared.begin(.replyTTS)
        if useCloudTTS {
            VoiceOutputPlayer.shared.enqueue(text, sessionId: sessionId ?? "")
            return
        }
        if BackgroundKeepAliveManager.shared.backgroundSpeakEnabled {
            BackgroundKeepAliveManager.shared.stopSilentAudio()
            speechSynthesizer.delegate = speechDelegate
        }
        let utterance = makeUtterance(text)
        speechSynthesizer.speak(utterance)  // queues automatically, does NOT interrupt
    }

    /// Declare the reply-TTS audio intent before System TTS speaks. The
    /// coordinator applies the `.playback/.spokenAudio/.duckOthers` profile (audible
    /// even on silent switch) with a FULL category+mode+options reconfigure — fixing
    /// the bug where a stale `.playback/.mixWithOthers` profile (from the keep-alive
    /// track) was inherited and left System TTS silent / un-ducked.
    @MainActor
    static func ensureSpeechPlaybackSession() {
        AudioSessionCoordinator.shared.begin(.replyTTS)
    }

    /// Whether reply TTS may speak right now: enabled AND the mic isn't capturing
    /// (capture and playback are mutually exclusive — no echo / session fight).
    private var canSpeakNow: Bool {
        // Enabled AND not muted AND not capturing. `canPlay` folds in the temporary
        // mute (capsule speaker) on top of the full on/off `isEnabled`.
        VoiceOutputState.shared.canPlay && !VoiceModePreference.shared.isCapturing
    }

    /// True when a configured cloud TTS model is selected (not the offline System
    /// provider). Snapshotted once per reply (`replyUsesCloudTTS`) so a mid-reply
    /// provider change can't split one reply across two engines playing at once.
    private var useCloudTTS: Bool {
        if let snap = replyUsesCloudTTS { return snap }
        let v = !(VoiceProviderResolver.outputProvider() is SystemVoiceProvider)
        replyUsesCloudTTS = v
        return v
    }

    /// Reset the per-reply TTS engine snapshot (call at the start of each reply).
    func resetReplyTTSEngine() { replyUsesCloudTTS = nil }

    /// Create an AVSpeechUtterance with the user's speech settings applied.
    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let mgr = BackgroundKeepAliveManager.shared
        let utterance = AVSpeechUtterance(string: text)
        let lang = text.range(of: "\\p{Han}", options: .regularExpression) != nil ? "zh-CN" : "en-US"
        // Stage 1: if the user picked a SPECIFIC System voice model in the Voice
        // Output selection, honor it directly (one voice for all languages). Only
        // fall back to the legacy per-language auto-selection when no specific
        // voice is chosen — so existing users see no behavior change.
        if let vid = VoiceProviderResolver.resolvedSystemOutputVoiceId(),
           let picked = AVSpeechSynthesisVoice(identifier: vid) {
            utterance.voice = picked
        } else {
            utterance.voice = mgr.voiceForLanguage(lang)
        }
        // Apply the read-replies speed multiplier on top of the user's base rate,
        // clamped to AVSpeechUtterance's valid range.
        let mult = VoiceOutputPreferences.speedMultiplier
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, mgr.speechRate * mult))
        utterance.pitchMultiplier = SystemVoicePreferences.pitch
        // [T-readaloud-volume] The read-aloud volume (shared with cloud TTS).
        // Fixed per utterance once queued, so a slider change applies from the
        // next sentence queued after it.
        utterance.volume = SystemVoicePreferences.volume
        VoiceLog.log(String(format: "TTS system utterance volume=%.2f chars=%d", utterance.volume, text.count))
        return utterance
    }
}
