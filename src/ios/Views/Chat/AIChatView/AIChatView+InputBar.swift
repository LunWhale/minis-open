//
//  AIChatView+InputBar.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, input bar: wires the composer's key callbacks through
//  ComposerActionChannel (return, arrows, tab, caret) and builds `inputBar` -
//  suspended / fork / edit states, swipe-to-send, and the input bar height
//  measurement that the message list's bottom inset follows.
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

extension AIChatView {
    // MARK: - Input keyboard handlers (extracted to avoid inflating the
    // generic type of `inputBar` past what Swift can demangle at runtime).

    /// [T-ios-crash-objectdestroy-composer-uaf] Point the composer's action
    /// relay at this view's handlers. The closure lives in the @State-held
    /// channel, not in PastableTextView's stored properties, so the child
    /// view never carries a copy of AIChatView.
    func wireComposerActions() {
        composerActions.handler = { [self] action in
            switch action {
            case .returnKey: handleReturnKey(); return true
            case .arrowUp: return handleArrowUp()
            case .arrowDown: return handleArrowDown()
            case .tab: return handleTabKey()
            case .caret(let caret): handleCaretChange(caret); return true
            case .submitAfterVoice: submitAfterVoice(); return true
            case .releaseFocus: inputFocused = false; return true
            }
        }
    }

    private func handleReturnKey() {
        if vm.showMentionMenu && vm.executeSelectedMention() { return }
        if vm.showSlashMenu && vm.executeSelectedSlashCommand() { return }
        if canEnqueue { performEnqueue() }
        else if canSend { performSend() }
    }

    private func handleArrowUp() -> Bool {
        if vm.showMentionMenu { vm.mentionMenuUp(); return true }
        guard vm.showSlashMenu else { return false }
        vm.slashMenuUp()
        return true
    }

    private func handleArrowDown() -> Bool {
        if vm.showMentionMenu { vm.mentionMenuDown(); return true }
        guard vm.showSlashMenu else { return false }
        vm.slashMenuDown()
        return true
    }

    private func handleTabKey() -> Bool {
        if vm.showMentionMenu { return vm.executeSelectedMention() }
        guard vm.showSlashMenu else { return false }
        vm.slashMenuAutocomplete()
        return true
    }

    private func handleCaretChange(_ caret: Int) {
        vm.inputCaret = caret
    }

    var inputBar: some View {
        VStack(spacing: 0) {
            if vm.isSuspended {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.yellow)
                    Text("Waiting for other tasks to complete...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.yellow.opacity(0.08))
            }

            // [T-ios-chat-body-stack-erase] Same as body: erase the composer
            // before its modifier chain so each opaque step copies a pointer,
            // not the whole composer (30 dynamic stack buffers in this closure).
            AnyView(VStack(spacing: 5) {
                // [T-paste-placeholder] Stashed long pastes referenced by the
                // draft. Removal also strips the literal from the input text.
                if !vm.pastedTexts.isEmpty {
                    PastedTextChipRow(pastedTexts: vm.pastedTexts) { id in
                        vm.removePastedText(id: id)
                    }
                }
                // Attachment preview chips — 3 per row
                if !vm.attachments.isEmpty || vm.loadingVideoCount > 0 {
                    ScrollView(.vertical, showsIndicators: true) {
                        inputAttachmentGrid
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: AttachmentGridHeightKey.self, value: geo.size.height)
                            })
                    }
                    .frame(height: min(attachmentGridHeight, 160))
                    .onPreferenceChange(AttachmentGridHeightKey.self) { attachmentGridHeight = $0 }
                    .padding(.top, 8)
                }

                inputFieldOrWaveform

                inputBottomRow
                    // [T-ios-de-voice-toolbar] Measure the row so the
                    // read-aloud toggle can decide whether its label fits.
                    // `onGeometryChange`, NOT a GeometryReader background —
                    // [T-ios-geometry-observer-crash] traced an async-renderer
                    // SIGTRAP to that scaffold, and this file already
                    // standardised on the observer for exactly that reason.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { w in
                        guard w > 0, abs(w - inputBottomRowWidth) > 0.5 else { return }
                        inputBottomRowWidth = w
                    }
                    // Padding applied AFTER the observer, so the measured
                    // width is the row's own usable space and needs no
                    // constant subtracted back out of it.
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            })
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .onTapGesture { inputFocused = true }
            .onReceive(speechManager.$recognizedText) { text in
                guard speechManager.state == .recording || !text.isEmpty else { return }
                // Append only the new delta to preserve existing input text
                let newLength = text.count
                if newLength > lastRecognizedLength {
                    let delta = String(text.dropFirst(lastRecognizedLength))
                    vm.inputText += delta
                }
                lastRecognizedLength = newLength
            }
            .overlay(alignment: .topTrailing) {
                // Only offer "Move to…" when there is actually something to
                // move. hasInjectedShareContent is flipped true after EVERY
                // share ingestion, even when the share produced no text and no
                // attachments (e.g. an unrecognized item, or all items diverted
                // to Provider-import). Gate on real movable content so the pill
                // doesn't linger over an empty composer. [T-ios-moveto-empty-content]
                if hasInjectedShareContent && hasMovableShareContent {
                    Button { showMoveToSheet = true } label: {
                        Label("Move to…", systemImage: "arrow.right.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatColors.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 10)
                }
            }
            .modifier(ComposerSurface())
            // [T-ios-context-usage-hint] Inner glow along the glass wall.
            // An overlay ABOVE the material (so the Liquid Glass backdrop
            // sampler never sees it) that clips itself to the same shape, so
            // it cannot spill past the outline (see ComposerContextGlow).
            .overlay {
                ComposerContextGlow(tier: vm.contextUsage?.tier ?? .normal)
            }
            .frame(maxWidth: maxContentWidth)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // [T-ios-geometry-observer-crash] onGeometryChange replaces the
            // GeometryReader scaffold (async-renderer SIGTRAP — see the
            // floating-bar site). Fires with the initial value too, so the
            // old onAppear seeding AND its diagnostic log are preserved as
            // a single unified line.
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                let newH = frame.size.height
                // [voice-inputbar-padding-zero] Guard against transient 0.
                guard newH > 0 else { return }

                // [T-voice-inputbar-cross-session-bleed] During session
                // transition animations, SwiftUI fires onGeometryChange for
                // BOTH the outgoing and incoming AIChatView. The outgoing
                // view's frame slides offscreen. Discard measurements from
                // offscreen views to prevent a stale cross-session height from
                // overwriting the correct one.
                //
                // [T-ipad-inputbar-height-zero] The test is "is this frame
                // horizontally inside the WINDOW", not "is its minX near zero".
                // The original form compared minX against ±25% of
                // UIScreen.main.bounds.width, which silently assumed the chat
                // pane starts at global x≈0 — true only on iPhone. In a split
                // view (iPad / Mac Catalyst with the sidebar open) the pane is
                // inset by the sidebar width, so minX is legitimately large,
                // EVERY measurement failed the guard, the leading-edge seed
                // never fired, and inputBarHeight stayed 0 forever. Since it is
                // the message list's bottom inset, the list reserved no space
                // and the last message was permanently stuck under the composer
                // — unable to scroll into view. Compare against the host
                // window's bounds (falling back to the screen) and accept any
                // frame that overlaps it horizontally: an outgoing view mid-
                // slide is pushed a full pane-width out and still fails, which
                // is the behaviour the guard was actually written for.
                // Measure the slide RELATIVE TO THE PANE, not to the screen. The
                // outgoing view is pushed by ~a full pane width, so its offset
                // from the settled x is huge; a genuine mid-animation frame of
                // the incoming view is only tens of points off. Keeping the same
                // ±25% ratio the original used reproduces the iPhone behaviour
                // exactly (there, pane == screen), while a sidebar-inset pane on
                // iPad / Mac now compares against its OWN left edge instead of
                // global x≈0 — which is what made every frame look "offscreen".
                let hostWindow = inputBarWindowBounds()
                let paneW = frame.width > 1 ? frame.width : hostWindow.width
                let tolerance = paneW * 0.25
                let onscreen = frame.minX >= hostWindow.minX - tolerance
                    && frame.maxX <= hostWindow.maxX + tolerance

                // [T-voice-inputbar-stale-height] Leading-edge first write,
                // trailing-edge thereafter. The FIRST non-zero height (session
                // open / initial composer layout) is applied synchronously so the
                // message list's bottom inset is correct on its first pass and it
                // snaps straight to the bottom — the pure-trailing debounce made
                // the list scroll once to a "fake bottom" (small/old height), then
                // again 300ms later when the real height landed ("scroll, pause,
                // scroll" on session open).
                // [T-voice-inputbar-anim-tail] Record the freshest ON-SCREEN
                // height BEFORE either commit path runs — both the seed's and the
                // debounce's settle-confirm read this, so it must already reflect
                // the current callback (writing it after the seed's `return`
                // would leave the confirm reading a stale/zero value).
                if onscreen {
                    latestInputBarFrameH = newH
                    composerLiveHeight.report(newH)
                }
                // [T-voice-inputbar-collapse-selfheal] Liveness, recorded for
                // EVERY callback — an off-screen sample is still proof the host
                // is laying out, which is exactly what the health probe asks.
                inputBarGeometryTick &+= 1
                inputBarLastGeometryAt = CFAbsoluteTimeGetCurrent()

                if !didSeedInputBarHeight, onscreen {
                    didSeedInputBarHeight = true
                    inputBarHeightDebounce?.cancel()
                    inputBarHeight = newH
                    AppLogger(category: "InputBarLayout").info("inputBarHeight seeded=\(newH) x=\(Int(frame.minX))")
                    // [T-inputbar-stale-across-reentry] The seed is applied
                    // SYNCHRONOUSLY (the message list needs a bottom inset on its
                    // very first pass, else it scrolls to a fake bottom). That
                    // means it can capture a mid-animation frame — the exact
                    // hazard the old code avoided by never re-arming the seed,
                    // at the cost of letting a stale height live forever. Keep
                    // the synchronous seed AND make it self-correcting: confirm
                    // against the freshest reported geometry once the panel's
                    // 280ms animation has provably finished. No new measurement
                    // is taken; we only re-read what onGeometryChange reported.
                    let voiceAtSeed = voiceInputActive
                    inputBarHeightDebounce = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        guard !Task.isCancelled, voiceAtSeed == voiceInputActive else { return }
                        let settled = latestInputBarFrameH
                        if settled > 0, abs(settled - newH) > 0.5 {
                            inputBarHeight = settled
                            AppLogger(category: "InputBarLayout").info("inputBarHeight SEED-CORRECTED \(newH)→\(settled) — seed had caught an animation frame")
                        }
                    }
                    return
                }
                // Subsequent changes debounce: onGeometryChange fires during
                // SwiftUI layout animation frames, sampling mid-transition
                // heights. If the height then stabilizes (e.g. compact voice
                // mode = fixed size), no further callback fires to correct it —
                // inputBarHeight gets stuck at the animation mid-frame value.
                // Wait 300ms (> animation duration 200ms) to capture the settled
                // post-animation value.
                guard onscreen else {
                    AppLogger(category: "InputBarLayout").info("inputBarHeight discarded=\(newH) offscreen x=\(Int(frame.minX))…\(Int(frame.maxX)) win=\(Int(hostWindow.minX))…\(Int(hostWindow.maxX))")
                    return
                }
                inputBarHeightDebounce?.cancel()
                let voiceAtCapture = voiceInputActive
                inputBarHeightDebounce = Task { @MainActor in
                    // [T-voice-inputbar-anim-tail] 380ms, not 300ms. The panel's
                    // expand/collapse and transcript-band animations are
                    // .easeInOut(duration: 0.28) — the old 300ms window left only
                    // 20ms of margin (its comment claimed the animation was
                    // 200ms, which is stale), so the timer routinely expired
                    // while the panel was still moving and SwiftUI's final
                    // geometry callback had not landed yet.
                    try? await Task.sleep(for: .milliseconds(380))
                    guard !Task.isCancelled else { return }
                    // [T-voice-inputbar-branch-swap] During rapid streaming
                    // re-renders, voiceInputActive can glitch for one frame,
                    // swapping the AnyView branch from InlineVoiceInputView
                    // to PastableTextView. The text view's height (~115pt)
                    // is wrong for the voice panel (~161pt compact). Discard
                    // if the branch flipped back by the time debounce fires.
                    if voiceAtCapture != voiceInputActive {
                        AppLogger(category: "InputBarLayout").info("inputBarHeight discarded=\(newH) branchSwap voice=\(voiceAtCapture)→\(voiceInputActive)")
                        return
                    }
                    // Commit the LATEST height, not the one that armed the timer.
                    let committed = latestInputBarFrameH > 0 ? latestInputBarFrameH : newH
                    inputBarHeight = committed
                    let armed = newH
                    AppLogger(category: "InputBarLayout").info("inputBarHeight settled=\(committed) x=\(Int(frame.minX))\(abs(committed - armed) > 0.5 ? " (armedWith=\(armed), used latest)" : "")")

                    // [T-voice-inputbar-anim-tail] Settle-confirm. Even the
                    // latest recorded frame can be a tail sample if the final
                    // callback lands after this task wakes. Re-check once more
                    // after another animation-length beat and correct if the
                    // panel moved — this is the backstop that guarantees the
                    // bottom inset can never stay frozen on a transitional
                    // height, which is the bottom-gap symptom. No new
                    // measurement is taken: we only re-read what
                    // onGeometryChange already reported.
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    guard voiceAtCapture == voiceInputActive else { return }
                    let settled = latestInputBarFrameH
                    if settled > 0, abs(settled - committed) > 0.5 {
                        inputBarHeight = settled
                        AppLogger(category: "InputBarLayout").info("inputBarHeight CORRECTED \(committed)→\(settled) — commit had caught an animation-tail frame")
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                // Extracted into a named struct + AnyView-erased so the
                // overlay does not deepen `inputBar`'s already-fragile
                // generic chain. See crash 2026-04-17 (line ~1981): SwiftUI's
                // runtime type-metadata decoder recurses into every nested
                // modifier, and an inline `.overlay { HStack { Image...; Text
                // .padding.frame.background(Capsule).shadow.opacity } ...}`
                // blew the stack on `inputBottomRow.getter` during a swipe.
                SwipeToSendHint(progress: sendSwipeProgress,
                                armFraction: Self.kSendSwipeArmFraction,
                                location: sendSwipeLocation,
                                // While the agent is mid-stream the gesture
                                // queues the prompt instead of sending it,
                                // so the capsule advertises that — matches
                                // the send-button's send/enqueue toggle.
                                isEnqueue: vm.isProcessing && !canSend)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        // [T-ios-composer-swipe-send-at-bottom] While the inner
                        // scroll still owns the drag, keep the anchor cleared so
                        // that the instant it hands off (user reaches the bottom
                        // mid-drag) progress re-anchors HERE instead of counting
                        // the scrolling that came before.
                        guard !inputHasSelection, swipeToSendAllowed else {
                            sendSwipeAnchor = nil
                            return
                        }
                        // Priority in voice mode: component gestures > collapse/
                        // expand > swipe-to-send. The panel's own drags (collapse/
                        // expand, delete control) are handled inside the panel; the
                        // swipe-to-send only engages once the finger has been
                        // dragged ABOVE the input container (location.y < 0), i.e.
                        // out toward the message area — making it the lowest
                        // priority and never colliding with in-panel drags.
                        if voiceInputActive && value.location.y >= 0 {
                            if sendSwipeProgress != 0 { sendSwipeProgress = 0 }
                            return
                        }
                        let isVertical = abs(value.translation.height) > abs(value.translation.width)
                        guard isVertical, value.translation.height < 0 else {
                            if sendSwipeProgress != 0 { sendSwipeProgress = 0 }
                            return
                        }
                        // Empty input: no swipe-to-send hint. Keyboard
                        // activation (if collapsed) is handled in onEnded so
                        // we don't pop the keyboard during scroll-like drags.
                        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        guard hasText else {
                            if sendSwipeProgress != 0 { sendSwipeProgress = 0 }
                            return
                        }
                        // [T-ios-composer-swipe-send-at-bottom] Anchor progress
                        // at the hand-off point. For a plain short-text drag
                        // this is the drag origin (0) and behaves exactly as
                        // before; for a drag that first scrolled a long value to
                        // its end, it discards the scrolling part so only the
                        // EXTRA pull past the bottom counts toward sending.
                        if sendSwipeAnchor == nil { sendSwipeAnchor = value.translation.height }
                        let dragUp = -(value.translation.height - (sendSwipeAnchor ?? 0))
                        guard dragUp > 0 else {
                            if sendSwipeProgress != 0 { sendSwipeProgress = 0 }
                            return
                        }
                        let newProgress = max(0, min(1, dragUp / Self.kSendSwipeThreshold))
                        // Haptic tick the first time we cross the arming
                        // fraction (0.8) — matches the capsule's full-opacity
                        // point so the cue and the release zone agree.
                        let arm = Self.kSendSwipeArmFraction
                        if newProgress >= arm && sendSwipeProgress < arm {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        sendSwipeProgress = newProgress
                        sendSwipeLocation = value.location
                    }
                    .onEnded { value in
                        // [T-ios-composer-swipe-send-at-bottom] Consume the
                        // hand-off anchor: whatever happens below, the next
                        // gesture must re-anchor from scratch.
                        let anchor = sendSwipeAnchor ?? 0
                        sendSwipeAnchor = nil
                        guard !inputHasSelection, swipeToSendAllowed else {
                            sendSwipeProgress = 0
                            return
                        }
                        // Voice mode: only a release dragged OUT of the input
                        // container (toward the message area) sends — in-panel
                        // drags belong to collapse/expand and the delete control.
                        //
                        // [T-voice-scroll-gesture-priority] This location test is
                        // also what already satisfies "scroll must win over
                        // swipe-to-send" inside the voice panel's transcript, in
                        // BOTH the editing and read-only modes: any drag whose
                        // release lands inside the input container (y >= 0) —
                        // which is every drag that stays within the transcript
                        // ScrollView — is rejected here before it can send. So a
                        // scroll gesture can never be reinterpreted as a send,
                        // and no separate isScrollable/at-bottom channel needs to
                        // be plumbed from the panel to this gesture. Send only
                        // engages once the finger has genuinely left the panel and
                        // moved up toward the message list, which is exactly the
                        // required behaviour.
                        if voiceInputActive && value.location.y >= 0 {
                            if sendSwipeProgress != 0 { sendSwipeProgress = 0 }
                            return
                        }
                        let isVertical = abs(value.translation.height) > abs(value.translation.width)
                        let endY = value.location.y
                        let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        // Measure the send-relevant travel from the hand-off
                        // anchor, not the drag origin, so the scrolling portion
                        // of a scroll-then-pull drag doesn't read as a swipe-up.
                        let anchoredHeight = value.translation.height - anchor
                        let swipedUp = isVertical && anchoredHeight < 0
                        if swipedUp && hasText {
                            // Swipe-up release with text: send if past
                            // arming fraction (0.8). When the agent is
                            // mid-stream the request is queued instead —
                            // mirrors the send-button which falls back to
                            // performEnqueue while `vm.isProcessing` makes
                            // `canSend` false. Without this branch a long
                            // run blocked the swipe gesture entirely.
                            if sendSwipeProgress >= Self.kSendSwipeArmFraction {
                                // Match the tap/return-key precedence:
                                // when the agent is busy AND a queue slot
                                // is available, ENQUEUE first. Previously
                                // this branch checked `canSend` first —
                                // and `canSend = vm.isReady && hasText`
                                // doesn't consult `isProcessing`, so a
                                // busy run with text in the composer
                                // bypassed enqueue and started a fresh
                                // send that got dropped (T-drag-send-queue).
                                if canEnqueue {
                                    performEnqueue()
                                } else if canSend {
                                    performSend()
                                }
                            }
                            withAnimation(.easeOut(duration: 0.18)) {
                                sendSwipeProgress = 0
                            }
                        } else if swipedUp && !hasText && !inputFocused {
                            // Swipe-up release with empty input + collapsed
                            // keyboard -> activate the keyboard (enter input
                            // mode). If the keyboard is already up, do
                            // nothing so the gesture isn't misinterpreted.
                            inputFocused = true
                            sendSwipeProgress = 0
                        } else if isVertical && inputFocused && (endY > inputBarHeight || endY < 0) {
                            // Swipe-down (or out of bounds) while focused
                            // still dismisses the keyboard — unchanged.
                            inputFocused = false
                            sendSwipeProgress = 0
                        } else {
                            sendSwipeProgress = 0
                        }
                    }
            )
        }
        .background(
            // Fade from transparent (top) to solid background (bottom half)
            // so scrolling content doesn't bleed through below the input bar,
            // while keeping the gap between tool status bar and input bar clear.
            LinearGradient(
                stops: [
                    .init(color: ChatColors.background.opacity(0), location: 0),
                    .init(color: ChatColors.background, location: 0.8),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
