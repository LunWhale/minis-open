//
//  ChatSendButton.swift
//  Minis - chat page (AIChatView)
//
//  The composer's trailing send / stop button. Observes AgentJobRegistry so the
//  conversation reads as busy while a background sub agent is still running,
//  and offers the Return-key mode in its long-press menu.
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

// MARK: - Composer send / stop button  [T-sub-agents-busy]

/// The composer's trailing button, in its own struct so it can observe
/// `AgentJobRegistry` directly.
///
/// The state it renders is "is this conversation still busy", which is NOT the
/// same as "is its own loop running". A background sub agent keeps working
/// after the parent's turn ends and posts its result back as a new turn, so
/// while one is alive the conversation is going to speak again — showing an
/// idle composer there tells the user it is finished when it is not, and takes
/// away the control that stops it.
struct ChatSendButton: View {
    @ObservedObject var vm: AIChatViewModel
    let canSend: Bool
    let canEnqueue: Bool
    /// [T-voice-send-lock] Send was tapped while voice input still owed text:
    /// the mic is stopping and recognition is finishing, then the message goes
    /// out by itself. Until then the button is busy, not tappable.
    var isWaitingToSendVoice: Bool = false
    let onSend: () -> Void
    let onEnqueue: () -> Void

    @ObservedObject private var jobs = AgentJobRegistry.shared
    /// [T-scheduled-active-session] The tracker's ACTIVE conversations — the
    /// same set background keep-alive and the list spinner read.
    @ObservedObject private var tracker = SessionActivityTracker.shared

    /// [T-scheduled-stop-confirm] Confirmation before Stop takes this
    /// conversation's timers down with the reply.
    @State private var showScheduledStopConfirm = false

    /// [T-stop-confirm] Settings > Appearance > Confirm Before Stopping.
    /// [T-stop-mode-longpress] OFF by default (stop at once); a long-press
    /// on the stop button switches it on the spot.
    @AppStorage(StopConfirmPolicy.settingsKey) private var confirmBeforeStopping: Bool = StopConfirmPolicy.defaultValue
    @State private var showStopConfirm = false
    /// Whether the reply loop itself was running when the dialog opened. If
    /// so, the dialog belongs to that turn and goes away when it ends.
    @State private var stopConfirmOpenedWhileProcessing = false
    /// Times the reply loop has stopped running since this button appeared,
    /// and that count when the dialog opened: a different count means the
    /// turn the dialog was about has ended, even if a queued one now runs.
    @State private var processingEndCount = 0
    @State private var stopConfirmEndCount = 0

    /// [T-send-longpress-return-mode] Same key as Settings > Appearance >
    /// Return Key (0 = newline, 1 = send) and the composer's Return handling,
    /// so the long-press menu and Settings are one setting.
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0

    /// [T-send-menu-stale-primary-action] Holds the CURRENT tap action.
    /// `Menu(primaryAction:)` on iOS 16-18 keeps the closure from the Menu's
    /// first render and never picks up later ones. That first render has an
    /// empty composer, so the captured `if canSend { … }` saw `false` forever
    /// and tapping Send did nothing. The Menu calls through this box instead,
    /// and every render stores the fresh closure in it.
    @State private var primaryActionBox = SendPrimaryActionBox()
    /// [T-stop-mode-longpress] The stop button's own box, for the same reason:
    /// its tap reads `hasLiveScheduled` and `confirmBeforeStopping`, which a
    /// closure kept from the first render would see frozen.
    @State private var stopActionBox = SendPrimaryActionBox()

    /// True when this conversation owns a timer that will still fire.
    private var hasLiveScheduled: Bool {
        guard let sid = vm.sessionId else { return false }
        return jobs.hasLiveScheduledJobs(createdBy: sid)
    }

    /// True while a delegated sub agent of this conversation is still running.
    private var hasRunningSubAgent: Bool {
        guard let sid = vm.sessionId else { return false }
        return jobs.hasActiveChildren(parent: sid)
    }

    /// Busy = own loop running, a sub agent still working for us, or — since
    /// [T-scheduled-active-session] — a scheduled follow-up of ours still due:
    /// the conversation is ACTIVE (`SessionActivityTracker.isBusy`), so it
    /// keeps Stop, which also cancels those timers.
    private var isBusy: Bool {
        vm.isProcessing || hasRunningSubAgent || (vm.sessionId.map(tracker.isBusy) ?? false)
    }

    var body: some View {
        Group {
            // [T-voice-send-lock] First, before every other state: while the send
            // waits for recognition the button would otherwise still look like
            // Send (or Queue) and take taps for seconds with nothing visible
            // happening, which reads as "the tap did not register". Not a control:
            // nothing to press, so nothing to press twice. Same 34 pt footprint as
            // the glyphs below, so the row does not move.
            if isWaitingToSendVoice {
                ZStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(ChatColors.sendButtonDisabled)
                    ProgressView()
                        .controlSize(.small)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Transcribing, then sending…", comment: "Voice input: status while a tapped Send waits for speech recognition to finish"))
            } else if vm.isProcessing && canEnqueue {
                returnModeMenu(primaryAction: onEnqueue) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(ChatColors.sendButton)
                }
                .accessibilityLabel(Text("Add to queue", comment: "VoiceOver label for the send button while a reply is generating"))
                .accessibilityHint(Text("Queues this message to send after the current reply finishes", comment: "VoiceOver hint for the queue button"))
            } else if isBusy && !canSend {
                // Stop. When only a sub agent is running, cancelling stops it
                // rather than a (non-existent) reply — vm.cancel() covers both,
                // and the label says which one the user is stopping.
                // [T-stop-mode-longpress] Tap stops; long-press picks between
                // stopping at once and confirming first.
                stopModeMenu(primaryAction: {
                    // [T-scheduled-stop-confirm] Stop now also cancels this
                    // conversation's scheduled tasks (see AIChatViewModel.cancel),
                    // which is a bigger, less reversible action than stopping a
                    // reply — a loop the user set up hours ago disappears, so that
                    // stronger warning wins over the plain one below.
                    // [T-stop-confirm] Otherwise the plain "Stop this task?"
                    // confirmation, unless Confirm Before Stopping is off.
                    switch StopConfirmPolicy.onTap(hasLiveScheduled: hasLiveScheduled,
                                                   confirmEnabled: confirmBeforeStopping) {
                    case .confirmScheduled:
                        showScheduledStopConfirm = true
                    case .confirmStop:
                        stopConfirmOpenedWhileProcessing = vm.isProcessing
                        stopConfirmEndCount = processingEndCount
                        showStopConfirm = true
                    case .stopNow:
                        // [T-subagent-stop-from-own-page] On a sub agent's page this
                        // stops it the way its card does, not with a raw cancel().
                        vm.stopByUser()
                    }
                }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                }
                // Hosted here rather than on the chat root: this button owns the
                // decision, and the existing "Task Running" alert up there belongs
                // to a different action (New Chat from the "…" menu), so the two
                // can never contend — they are driven by separate flags and
                // separate user gestures.
                .alert(AppLocalized("Scheduled Tasks Planned"), isPresented: $showScheduledStopConfirm) {
                    Button(AppLocalized("Stop All"), role: .destructive) { vm.stopByUser() }
                    Button(AppLocalized("Cancel"), role: .cancel) {}
                } message: {
                    Text(AppLocalized("This conversation has scheduled tasks planned. Stopping will also cancel them."))
                }
                .alert(AppLocalized("Stop this task?"), isPresented: $showStopConfirm) {
                    Button(AppLocalized("Stop"), role: .destructive) {
                        // The turn may have ended while the dialog was up; never
                        // let this tap stop whatever runs next.
                        guard StopConfirmPolicy.confirmStillApplies(openedWhileProcessing: stopConfirmOpenedWhileProcessing,
                                                                    endCountAtOpen: stopConfirmEndCount,
                                                                    endCountNow: processingEndCount,
                                                                    isBusy: isBusy) else {
                            minisLogger.info("[StopConfirm] Stop tapped after the task ended; ignored")
                            return
                        }
                        vm.stopByUser()
                    }
                    Button(AppLocalized("Keep Running"), role: .cancel) {}
                } message: {
                    Text(AppLocalized("The current reply and any running tools will be stopped."))
                }
                .accessibilityLabel(vm.isProcessing
                    ? Text("Stop generating", comment: "VoiceOver label for the stop button")
                    : hasRunningSubAgent
                        ? Text("Stop sub agents", comment: "VoiceOver label for the stop button while only background sub agents are running")
                        : Text("Stop scheduled tasks", comment: "VoiceOver label for the stop button while the conversation only waits on its scheduled tasks"))
                .accessibilityHint(Text("Stops the reply that is being generated", comment: "VoiceOver hint for the stop button"))
            } else {
                // Typing while a sub agent runs must still be sendable: the user
                // may want to redirect it, and the parent loop is free to answer.
                // [T-send-longpress-return-mode] Not `.disabled(!canSend)`: a
                // disabled control also ignores the long-press, and the menu must
                // open from the grey button too (switching Return mode before
                // typing is the common case). The tap is gated instead.
                returnModeMenu(primaryAction: { if canSend { onSend() } }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? ChatColors.sendButton : ChatColors.sendButtonDisabled)
                }
                .accessibilityLabel(Text("Send", comment: "VoiceOver label for the send button"))
            }
        }
        // [T-stop-confirm] Close the confirmation when what it would stop
        // is gone. Observed on the publisher rather than via onChange so a
        // turn that ends and is immediately followed by a queued one
        // (false then true in one transaction) still closes it: the dialog
        // must never stop the next turn. Also clears the flags, which live
        // on this struct and would otherwise re-present the alert the next
        // time the stop button appears.
        .onReceive(vm.$isProcessing) { processing in
            guard !processing else { return }
            processingEndCount &+= 1
            if showStopConfirm && stopConfirmOpenedWhileProcessing {
                showStopConfirm = false
            }
        }
        .onChange(of: isBusy) { busy in
            if !busy {
                showStopConfirm = false
                showScheduledStopConfirm = false
            }
        }
    }

    /// [T-send-longpress-return-mode] The send control: tap = `primaryAction`,
    /// long-press = a single-choice menu for what the Return key does, to
    /// switch it on the spot instead of via Settings > Appearance.
    ///
    /// `Menu(primaryAction:)` is exactly that gesture split, and on iOS 26+
    /// the system renders the menu as Liquid Glass that morphs out of the
    /// button itself (the "grows from the send button" effect). Earlier iOS
    /// uses a Button + context menu instead, because the Menu's tap is broken
    /// there (see below). ⌘Return keeps sending: through a hidden button on
    /// iOS 26, since a keyboard shortcut on a Menu would open the menu.
    @ViewBuilder
    private func returnModeMenu<Label: View>(primaryAction: @escaping () -> Void,
                                             @ViewBuilder label: () -> Label) -> some View {
        if #available(iOS 26, *) {
            glassReturnModeMenu(primaryAction: primaryAction, label: label)
        } else {
            // [T-send-menu-stale-primary-action] iOS 16-25: a plain Button for
            // the tap plus a context menu for the long-press. On iOS 16 (seen
            // on an iPhone 8 / 16.1) SwiftUI backs `Menu(primaryAction:)` with
            // a UIKit button whose tap never reached the action — Send did
            // nothing at all, even with a live action box. A Button always
            // taps; `.contextMenu` still opens from the button on long-press.
            Button(action: primaryAction) { label() }
                .keyboardShortcut(.return, modifiers: .command)
                .contextMenu { returnModePicker }
                .accessibilityAction(named: Text("Return key options", comment: "VoiceOver action on the send button that opens the Return-key mode menu")) {
                    setReturnMode(returnKeyBehavior == 1 ? 0 : 1)
                }
        }
    }

    private var returnModePicker: some View {
        Picker(selection: returnModeBinding) {
            SwiftUI.Label(AppLocalized("Return sends"), systemImage: "paperplane").tag(1)
            SwiftUI.Label(AppLocalized("Return adds a new line"), systemImage: "return").tag(0)
        } label: {
            Text("Return Key")
        }
        .pickerStyle(.inline)
    }

    /// iOS 26+: `Menu(primaryAction:)`, rendered as Liquid Glass that morphs
    /// out of the button itself.
    @available(iOS 26, *)
    private func glassReturnModeMenu<Label: View>(primaryAction: @escaping () -> Void,
                                                  @ViewBuilder label: () -> Label) -> some View {
        primaryActionBox.action = primaryAction
        return Menu {
            returnModePicker
        } label: {
            label()
        } primaryAction: { [primaryActionBox] in
            primaryActionBox.action()
        }
        .menuIndicator(.hidden)
        .background(
            Button("", action: primaryAction)
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .accessibilityAction(named: Text("Return key options", comment: "VoiceOver action on the send button that opens the Return-key mode menu")) {
            // VoiceOver users get the same switch without the long-press:
            // flip to the other mode (the only other option).
            setReturnMode(returnKeyBehavior == 1 ? 0 : 1)
        }
    }

    /// [T-stop-mode-longpress] The stop control: tap = `primaryAction`,
    /// long-press = a single-choice menu for Confirm Before Stopping, the same
    /// gesture split (and the same iOS 26 / iOS 16-25 split) as the send
    /// button's Return-key menu above. No keyboard shortcut: Stop never had one.
    @ViewBuilder
    private func stopModeMenu<Label: View>(primaryAction: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        if #available(iOS 26, *) {
            glassStopModeMenu(primaryAction: primaryAction, label: label)
        } else {
            Button(action: primaryAction) { label() }
                .contextMenu { stopModePicker }
                .accessibilityAction(named: Text("Stop button options", comment: "VoiceOver action on the stop button that switches between stopping at once and confirming first")) {
                    setStopMode(confirm: !confirmBeforeStopping)
                }
        }
    }

    @available(iOS 26, *)
    private func glassStopModeMenu<Label: View>(primaryAction: @escaping () -> Void,
                                                @ViewBuilder label: () -> Label) -> some View {
        stopActionBox.action = primaryAction
        return Menu {
            stopModePicker
        } label: {
            label()
        } primaryAction: { [stopActionBox] in
            stopActionBox.action()
        }
        .menuIndicator(.hidden)
        .accessibilityAction(named: Text("Stop button options", comment: "VoiceOver action on the stop button that switches between stopping at once and confirming first")) {
            setStopMode(confirm: !confirmBeforeStopping)
        }
    }

    private var stopModePicker: some View {
        Picker(selection: Binding(get: { confirmBeforeStopping }, set: { setStopMode(confirm: $0) })) {
            SwiftUI.Label(AppLocalized("Stop Immediately"), systemImage: "stop.circle").tag(false)
            SwiftUI.Label(AppLocalized("Confirm Before Stopping"), systemImage: "questionmark.circle").tag(true)
        } label: {
            Text(AppLocalized("Stop Button"))
        }
        .pickerStyle(.inline)
    }

    private func setStopMode(confirm: Bool) {
        guard confirm != confirmBeforeStopping else { return }
        confirmBeforeStopping = confirm
        UISelectionFeedbackGenerator().selectionChanged()
        minisLogger.info("[StopConfirm] set from stop-button menu: \(confirm ? "confirm" : "immediate")")
    }

    private var returnModeBinding: Binding<Int> {
        Binding(get: { returnKeyBehavior }, set: { setReturnMode($0) })
    }

    private func setReturnMode(_ mode: Int) {
        guard mode != returnKeyBehavior else { return }
        returnKeyBehavior = mode
        UISelectionFeedbackGenerator().selectionChanged()
        minisLogger.info("[ReturnMode] set from send-button menu: \(mode == 1 ? "send" : "newline")")
    }
}

// BEGIN StopConfirmPolicy
/// [T-stop-confirm] What a tap on the composer's stop button does. Only that
/// button asks: programmatic cancels (debug RPC, shortcuts, scheduled and sub
/// agent internals, a sub agent card's Stop, New Chat's own "Task Running"
/// alert) call `stopByUser()` / `cancel()` directly and never pass through here.
enum StopConfirmPolicy {
    /// UserDefaults key of Settings > Appearance > Confirm Before Stopping.
    static let settingsKey = "chat.confirmBeforeStopping"
    /// [T-stop-mode-longpress] OFF: the stop button stops at once unless the
    /// user opts in (Settings, the stop button's long-press, or minis-config).
    static let defaultValue = false

    enum TapAction: Equatable {
        /// Stopping would also cancel planned scheduled tasks: that warning.
        case confirmScheduled
        /// Ask "Stop this task?" first.
        case confirmStop
        /// Stop at once (the setting is off).
        case stopNow
    }

    /// Only reached while the stop button is shown, i.e. the conversation is busy.
    static func onTap(hasLiveScheduled: Bool, confirmEnabled: Bool) -> TapAction {
        if hasLiveScheduled { return .confirmScheduled }
        return confirmEnabled ? .confirmStop : .stopNow
    }

    /// Whether the dialog's Stop still refers to the task it was opened for.
    /// A dialog opened during a reply is void once that reply has ended
    /// (`endCount` moved on), even if another turn (a queued prompt) is
    /// already running. One opened while only sub agents or timers kept the
    /// conversation busy applies while it is still busy.
    static func confirmStillApplies(openedWhileProcessing: Bool, endCountAtOpen: Int,
                                    endCountNow: Int, isBusy: Bool) -> Bool {
        guard isBusy else { return false }
        return !openedWhileProcessing || endCountAtOpen == endCountNow
    }
}
// END StopConfirmPolicy
