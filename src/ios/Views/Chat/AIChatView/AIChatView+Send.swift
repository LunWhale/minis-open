//
//  AIChatView+Send.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, sending: whether the composer can send or enqueue, waiting for
//  voice recognition to finish before sending, and performEnqueue /
//  performSend.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    var canSend: Bool {
        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let ready = vm.isReady
        // [T-ios-photo-pick-placeholder] Block sending while any picked photo is
        // still loading. Only count `.ready` attachments as sendable content, so
        // a composer holding ONLY failed/loading chips (and no text) can't send.
        let hasReadyAttachment = vm.attachments.contains { $0.loadState == .ready }
        return ready && !vm.hasLoadingAttachments && (hasText || hasReadyAttachment || voiceOwesText)
    }

    var canEnqueue: Bool {
        vm.isProcessing && (!vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voiceOwesText)
    }

    /// [T-voice-send-waits-for-asr] Voice mode has captured speech that is not
    /// text yet. Send must be tappable then — tapping it is how the user says
    /// "I'm done" — even though the composer may still be empty.
    private var voiceOwesText: Bool {
        voiceInputActive && (voiceVM.hasUntranscribedAudio || voiceVM.isFinishingForSend)
    }

    /// [T-voice-send-lock] Send was tapped and the message is on its way, but
    /// not out yet: the mic is being stopped and recognition has to finish
    /// first. The send button shows this as busy and takes no taps - and only
    /// for this: every way the wait can end (sent, failed, timed out,
    /// cancelled, text edited, recording restarted, voice mode or the chat
    /// left) clears `isFinishingForSend` in one place, VoiceInputViewModel's
    /// `concludeFinishForSend`.
    var isWaitingToSendVoice: Bool {
        voiceInputActive && voiceVM.isFinishingForSend
    }

    /// [T-voice-send-waits-for-asr] If voice input still owes text, stop the
    /// mic, let every captured sample finish recognition, then come back
    /// through `submitAfterVoice` to send (or queue). Returns true when the
    /// send was deferred and the caller must stop.
    ///
    /// The completion captures only the action channel, never this view (see
    /// ComposerActionChannel for why that matters).
    private func deferSendUntilVoiceFinished() -> Bool {
        guard voiceInputActive,
              voiceVM.hasUntranscribedAudio || voiceVM.isFinishingForSend else { return false }
        voiceVM.finishCaptureForSend { [composerActions] ok in
            if ok { composerActions.send(.submitAfterVoice) }
        }
        return true
    }

    /// [T-voice-send-waits-for-asr] Second half of a deferred voice send. The
    /// transcript reaches `inputText` through a SwiftUI onChange, i.e. on a
    /// later render, so copy the final transcript over explicitly before
    /// deciding what to do; then send or queue exactly as the tap would have.
    ///
    /// [T-voice-send-lock] This runs once per wait (VoiceSendGate), and what it
    /// starts must not wait again: `afterVoice` skips the deferral, so a
    /// capture that would not stop, or audio that arrived in the meantime,
    /// cannot turn one tap into a second wait and a second send. Whether there
    /// is anything to send is decided by what the composer holds NOW, not by
    /// "voice still owes text" - recognition can come back empty.
    func submitAfterVoice() {
        guard voiceInputActive else {
            minisLogger.info("[voice-send] recognition finished after voice mode was left — not sending")
            return
        }
        let transcript = voiceVM.transcript
        if !transcript.isEmpty, vm.inputText != transcript {
            vm.inputText = transcript
        }
        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyAttachment = vm.attachments.contains { $0.loadState == .ready }
        if vm.isProcessing && hasText {
            performEnqueue(afterVoice: true)
        } else if vm.isReady && !vm.hasLoadingAttachments && (hasText || hasReadyAttachment) {
            performSend(afterVoice: true)
        } else {
            minisLogger.info("[voice-send] nothing to send after recognition finished (text=\(hasText) attachment=\(hasReadyAttachment) ready=\(vm.isReady))")
        }
    }

    /// Whether the composer actually holds something worth moving to another
    /// session — non-blank text or at least one attachment. Gates the
    /// "Move to…" pill so it never appears over an empty composer.
    var hasMovableShareContent: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !vm.attachments.isEmpty
    }


    /// `afterVoice`: the call that follows a finished voice wait (see
    /// `submitAfterVoice`) - it must not start another one.
    func performEnqueue(afterVoice: Bool = false) {
        if !afterVoice, deferSendUntilVoiceFinished() { return }
        // Dismiss the software keyboard on enqueue. With a hardware keyboard,
        // keep focus so the user can continue typing the next candidate.
        if GCKeyboard.coalesced == nil {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        vm.forceScrollToBottom.send()
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        vm.enqueuePrompt()
        // [inline-voice] Enqueue consumed the text — clear the voice transcript
        // too, otherwise it lingers in the panel (the "residual after swipe-send"
        // bug). performSend already does this; the enqueue path (taken while the
        // agent is processing) was missing it.
        if voiceInputActive {
            voiceVM.clearAndRearm()
        }
    }

    /// Dismiss keyboard (commit dictation/marked text) before sending.
    func performSend(afterVoice: Bool = false) {
        if !afterVoice, deferSendUntilVoiceFinished() { return }
        // Intercept slash commands — execute instead of sending to LLM
        if vm.tryExecuteInputAsSlashCommand() { return }

        minisLogger.info("🔑DRAFT performSend vm=\(vm.vmInstanceId) vm.sessionId=\(vm.sessionId ?? "nil") draftId=\(draftId ?? "nil") inputText='\(String(vm.inputText.prefix(50)))' isProcessing=\(vm.isProcessing)")
        // Keep SwiftUI focus when a hardware keyboard is connected — dropping
        // it would force the user to tap the field again before typing the
        // next message. With only the software keyboard, clear focus and
        // dismiss it so the @FocusState binding stays in sync.
        let hasHardwareKeyboard = GCKeyboard.coalesced != nil
        if !hasHardwareKeyboard {
            inputFocused = false
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // User actively sending — force scroll-to-bottom so the response scrolls into view
        vm.forceScrollToBottom.send()
        // Stop recording and clear recognized text so it doesn't linger after send
        if speechManager.state == .recording {
            speechManager.stopRecording()
        }
        speechManager.recognizedText = ""
        lastRecognizedLength = 0
        hasInjectedShareContent = false
        // Send FIRST while inputText still holds the recognized text. Clearing the
        // voice transcript here (clearAndRearm) mirrors "" into inputText via the
        // onChange binding, so doing it before send() left send() with empty text
        // → "send() GUARD FAILED" and nothing was sent. send() consumes and clears
        // inputText itself; we re-arm voice listening only AFTER it has run.
        vm.send()
        // [inline-voice] Stay in voice mode after sending — clear the recognized
        // text and re-arm listening for the next utterance (close with ✕).
        if voiceInputActive {
            voiceVM.clearAndRearm()
        }
    }
}
