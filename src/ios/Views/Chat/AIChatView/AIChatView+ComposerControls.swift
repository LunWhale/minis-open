//
//  AIChatView+ComposerControls.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, composer controls: the attachments "+" button, the bottom row
//  (slash, edit-exit, language badge, read-aloud toggle, mic, send), the input
//  field or voice waveform, and the iPad composer resize handle / height.
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
    /// Attachment "+" button.
    /// iOS 16's Menu has a vertical alignment bug inside HStack that causes it
    /// to sit higher than sibling buttons when the keyboard is up.
    /// Use confirmationDialog on iOS 16, Menu on iOS 17+.
    @ViewBuilder
    private var attachmentMenuButton: some View {
        // [T-ios-voiceover-labels] Labelled on the shared `icon` so both the
        // iOS 17 Menu branch and the iOS 16 confirmationDialog branch below
        // announce the same thing; otherwise VoiceOver reads "plus".
        let icon = Image(systemName: "plus")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(ChatColors.secondaryText)
            .frame(width: 34, height: 34)
            .accessibilityLabel(Text("Add attachment", comment: "VoiceOver label for the attachment button"))
            .background(ChatColors.inputIconBg)
            .clipShape(Circle())
            .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))

        if #available(iOS 17, *) {
            Menu {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                Button { showPhotoPicker = true } label: { Label("Choose Photos & Videos", systemImage: "photo.on.rectangle") }
                Button { showDocumentPicker = true } label: { Label("Add File", systemImage: "doc") }
            } label: {
                icon
            }
        } else {
            Button { showAttachmentMenu = true } label: {
                icon
            }
            .confirmationDialog("Add Attachment", isPresented: $showAttachmentMenu) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                Button { showPhotoPicker = true } label: { Label("Choose Photos & Videos", systemImage: "photo.on.rectangle") }
                Button { showDocumentPicker = true } label: { Label("Add File", systemImage: "doc") }
            }
        }
    }

    /// Bottom toolbar under the text field (+ / edit-exit / mic / send).
    /// Returns AnyView to keep `inputBar`'s generic type compact; SwiftUI
    /// runtime demangle chokes on deep nested types otherwise.
    var inputBottomRow: AnyView {
        let row = HStack(spacing: 12) {
            attachmentMenuButton
            slashMenuButton
            if vm.editingMessageIndex != nil { editExitButton }
            Spacer()
            // Mutually exclusive with editExitButton: while editing a past
            // message the exit capsule owns this row — showing both capsules
            // overflows the row and they render overlapped.
            if voiceInputActive, vm.editingMessageIndex == nil {
                readAloudToolbarToggle
                Spacer()
            }
            micButtonContainer
            sendButton
        }
        return AnyView(row)
    }

    /// [T-ios-de-voice-toolbar] Fixed controls in `inputBottomRow`: two 34pt
    /// leading buttons, the 34pt mic and the 34pt send button, plus the four
    /// 12pt HStack gaps between them. Everything left over is what the
    /// read-aloud capsule may use.
    private static let readAloudRowFixedWidth: CGFloat = 34 * 4 + 12 * 4

    /// Free width below which the toggle drops its text and becomes icon-only.
    ///
    /// Measured, not guessed. Capsule width is icon(16) + spacing(5) + text +
    /// padding(20); at `minimumScaleFactor(0.75)` the shipped translations need
    /// 86pt (zh-Hans) to 161pt (fil), with German at 141pt and English 105pt.
    ///
    /// 130pt is the point where a mid-length label still reads comfortably.
    /// It is deliberately BELOW the longest string's 161pt: the gate is on
    /// available width, and between 130pt and a given string's own need the
    /// scale factor absorbs the difference — so a long label degrades by
    /// shrinking (readable) before it degrades by vanishing. Only when the row
    /// drops under 130pt, where even a short label would be cramped against
    /// the mic and send buttons, does the text go entirely.
    ///
    /// Effect per device (usable = width − 24 side padding − 184 fixed):
    /// 320pt SE → 112pt → icon-only (the reported German case);
    /// 375pt mini → 167pt, 393pt → 185pt, 430pt → 222pt → label kept.
    private static let readAloudLabelMinWidth: CGFloat = 130

    /// Whether the read-aloud toggle shows its text label.
    ///
    /// Width-driven rather than size-class or locale driven: the failure is
    /// "this particular string does not fit in this particular row", and a
    /// size class says nothing about string length. A locale allow-list would
    /// have to be revisited on every new translation.
    private var showReadAloudLabel: Bool {
        // Before the first measurement, assume room. On every real device the
        // wide case is the common one, and a label that flickers in on the
        // second frame is worse than one that briefly overflows on a phone
        // narrow enough to be rare.
        guard inputBottomRowWidth > 0 else { return true }
        return inputBottomRowWidth - Self.readAloudRowFixedWidth >= Self.readAloudLabelMinWidth
    }

    /// "Read replies aloud" toggle shown centered in the toolbar during voice
    /// input (TTS on/off). Styled like the other secondary toolbar controls.
    private var readAloudToolbarToggle: some View {
        // Source of truth = vm.speakEnabled (also driven by the floating speaker's
        // tap-cycle / long-press-off), so this toggle reflects those changes too.
        // Three states, in lockstep with the global voice-output capsule:
        //  • disabled  (!isEnabled)        → gray, slashed speaker
        //  • muted     (isEnabled & muted) → accent, slashed speaker
        //  • active    (isEnabled & !muted)→ accent, wave speaker
        let on = voiceOutput.isEnabled
        let muted = voiceOutput.isMuted
        return Button {
            if on && !muted {
                // Active → mute (temporary silence, capsule stays visible).
                voiceOutput.isMuted = true
            } else if on && muted {
                // Muted → fully off (capsule hides).
                vm.speakEnabled = false
                VoiceOutputPreferences.isEnabled = false
            } else {
                // Off → turn on (resume last speed, un-muted).
                voiceOutput.isMuted = false
                vm.speakEnabled = true
                VoiceOutputPreferences.isEnabled = true
            }
        } label: {
            HStack(spacing: 5) {
                // Fixed-width icon slot so the size stays constant when the glyph
                // swaps between wave / slash.
                // [T-ios-voiceover-labels] The glyph only mirrors the on/off
                // state that the accessibilityValue below already announces,
                // and the row carries visible text — so it is pure decoration
                // for VoiceOver and would otherwise be read as
                // "speaker wave 2 fill".
                Image(systemName: (on && !muted) ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                // [T-ios-de-voice-toolbar] The label is the only part of this
                // row that may shrink, and past a point it disappears entirely,
                // leaving the speaker glyph as an icon-only control.
                //
                // Two stages because one is not enough: `minimumScaleFactor`
                // recovers ~25% of the width, which covers the mild cases
                // (fr/pl/tr on a 375pt screen) but not German at 320pt, where
                // the capsule needs 174pt against 112pt of free space. Rather
                // than let the text squash to an unreadable size, the label is
                // dropped below `readAloudLabelMinWidth` and the glyph — which
                // already carries the on/off/muted state — stands alone.
                if showReadAloudLabel {
                    Text("Read replies", comment: "Voice TTS toggle (compact)")
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(-1)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(on ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
        // [T-ios-de-voice-toolbar] Name the control explicitly. It used to be
        // named implicitly by the visible Text, which is exactly what the
        // icon-only fallback removes — and the glyph beside it is
        // `accessibilityHidden`, so without this the button would announce as
        // unnamed on a narrow screen. Stating it unconditionally keeps the name
        // identical in both layouts rather than having it appear and disappear.
        .accessibilityLabel(Text("Read replies", comment: "Voice TTS toggle (compact)"))
        // [T-ios-voiceover-labels] State goes in the VALUE, not the label:
        // folding "on"/"off" into the label would lose VoiceOver's own
        // "on/off" semantics and make the control's name change as it toggles.
        // Muted is a third state the glyph distinguishes visually, so it is
        // announced too rather than being flattened into "on".
        .accessibilityValue(Text(
            on ? (muted
                    ? AppLocalized("On, muted", comment: "VoiceOver value for the read-replies toggle when enabled but muted")
                    : AppLocalized("On", comment: "VoiceOver value for the read-replies toggle when enabled"))
               : AppLocalized("Off", comment: "VoiceOver value for the read-replies toggle when disabled")
        ))
        .accessibilityHint(Text("Toggles reading replies aloud", comment: "VoiceOver hint for the read-replies toggle"))
    }

    /// `/` button that opens the slash command menu.
    private var slashMenuButton: some View {
        Button {
            if vm.showSlashMenu {
                vm.dismissSlashMenu()
            } else {
                vm.showSlashMenuOverInput()
                inputFocused = true
            }
        } label: {
            Text("/")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .italic()
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
    }

    /// "Exit Edit Mode" capsule shown while editing a past message.
    private var editExitButton: some View {
        Button {
            vm.cancelEdit()
        } label: {
            Text("Exit Edit Mode", comment: "Cancel message editing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ChatColors.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ChatColors.inputIconBg)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
    }

    /// Speech language badge shown only while recording.
    private var languageBadgeButton: some View {
        Button {
            speechManager.showLanguagePicker = true
        } label: {
            Text(speechManager.languageLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChatColors.secondaryText)
                .frame(width: 34, height: 34)
                .background(ChatColors.inputIconBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(ChatColors.inputIconBorder, lineWidth: 0.5))
        }
    }

    /// Mic button plus the attached language-picker sheet.
    private var micButtonContainer: some View {
        MicButton(speechManager: speechManager, inputFocused: $inputFocused, onTap: {
            if voiceInputActive {
                // Already in voice mode — the "T" button switches back to text.
                // [T-ios-voice-keyboard-text-carry] Keep the transcript: the
                // composer mirrors it, so clearing here would empty the input
                // box and lose the dictated text on the way back to keyboard.
                voiceVM.reset(clearTranscript: false)
                withAnimation(.easeInOut(duration: 0.2)) { voiceInputActive = false }
            } else {
                // Mark the composition as voice-assisted (committed to the
                // "voice" input-mode preference only at send time). Switch the
                // composer into inline voice mode — the single voice entry point.
                vm.voiceUsedInComposition = true
                // Switching text→voice opens the panel expanded this one time;
                // afterwards it resumes the remembered expand/compact state.
                VoiceModePreference.shared.enteredFromText = true
                withAnimation(.easeInOut(duration: 0.2)) { voiceInputActive = true }
            }
        }, isVoiceActive: voiceInputActive)
    }

    /// Send / Enqueue / Stop circular button.
    ///
    /// [T-ios-voiceover-labels] All three states are icon-only, and two of them
    /// (send / enqueue) use the SAME glyph, so without explicit labels
    /// VoiceOver reads "arrow up circle fill" for both and a blind user cannot
    /// tell what pressing it will do. Each branch therefore names its own
    /// action; the destructive one also carries a hint.
    /// [T-sub-agents-busy] Extracted into its own struct so it can observe
    /// `AgentJobRegistry` without adding another `@StateObject` to
    /// `AIChatView` — the same reason `SessionLockGateOverlay` was split out
    /// (this body's generic depth already blew iOS 26's metadata budget once).
    private var sendButton: some View {
        ChatSendButton(vm: vm,
                       canSend: canSend,
                       canEnqueue: canEnqueue,
                       isWaitingToSendVoice: isWaitingToSendVoice,
                       onSend: { performSend() },
                       onEnqueue: { performEnqueue() })
    }

    /// Either the multi-line text field or the audio waveform, depending on
    /// whether speech recording is active. Returning `AnyView` erases the
    /// nested `PastableTextView` generic so SwiftUI's runtime type metadata
    /// decoder doesn't recurse past its stack limit (see crash 2026-04-17
    /// where `AIChatView.inputBar.getter` blew the stack via
    /// `__swift_instantiateConcreteTypeFromMangledNameV2`).
    var inputFieldOrWaveform: AnyView {
        // [T-ios-chat-body-stack-erase] Deepest app frame of the chat page's
        // body; record how much main-thread stack is left here (new lows only).
        MainStackHeadroom.note("chat-input")
        let topPadding: CGFloat = (vm.attachments.isEmpty && vm.loadingVideoCount == 0) ? 16 : 11
        if voiceInputActive {
            return AnyView(
                // [voice-correction §6] Recent conversation turns, straight from the
                // already-loaded in-memory list (§12.1 forbids a DB query on this path),
                // budgeted by CorrectionContextBuilder.
                InlineVoiceInputView(
                    viewModel: voiceVM,
                    inputText: inputTextBinding,
                    onPasteImage: { image in vm.addImageAttachment(image) },
                    onPasteFile: { url in vm.addFileAttachment(from: url) },
                    onPasteLongText: { text in vm.stashPastedText(text) },
                    conversationContext: {
                        voiceCorrectionContext(from: vm.messages,
                                               viewport: vm.captureViewportSnapshot?())
                    },
                    // [T-ios-context-usage-hint] Same request the text composer
                    // gets; the voice panel renders it in its status line.
                    contextUsageHint: vm.contextUsageHint
                )
            )
        }
        if speechManager.state == .recording {
            // Transcript area grows with content up to a cap (~5 lines),
            // then scrolls internally. ScrollView is greedy in its scroll
            // axis, so we measure the Text's intrinsic height via a
            // GeometryReader preference and clamp the ScrollView frame to
            // min(measured, cap).
            let transcriptMaxHeight: CGFloat = 100
            let waveform = VStack(spacing: 6) {
                AudioWaveformView(levels: speechManager.audioLevels)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                if !speechManager.recognizedText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(speechManager.recognizedText)
                                .font(.subheadline)
                                .foregroundStyle(ChatColors.secondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: TranscriptHeightKey.self, value: geo.size.height)
                                })
                                .id("transcriptTail")
                        }
                        .frame(height: min(max(transcriptHeight, 22), transcriptMaxHeight))
                        .onPreferenceChange(TranscriptHeightKey.self) { transcriptHeight = $0 }
                        .onReceive(speechManager.$recognizedText) { _ in
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo("transcriptTail", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, topPadding)
            .padding(.bottom, 10)
            return AnyView(waveform)
        }
        _ = returnKeyBehavior  // [T-send-longpress-return-mode] dependency, see declaration
        let field = PastableTextView(
            text: inputTextBinding,
            isFocused: $inputFocused,
            hasSelection: $inputHasSelection,
            isScrollable: $inputIsScrollable,
            isAtScrollBottom: $inputAtScrollBottom,
            // `String(localized:)` with an interpolation extracts the
            // `%@` form ("Message %@ (@ to mention files)") as the lookup
            // key in Localizable.xcstrings, so translators get one
            // parameterized entry per locale instead of one per soul name.
            placeholder: AppLocalized("Message \(soulName) (@ to mention files)"),
            // [T-ios-composer-placeholder-rotation] Feature hints cycled
            // while the composer sits empty. Same parameterized-`%@` rule as
            // the default above: the soul name is interpolated INTO the
            // localized key, never concatenated onto it, so each hint stays
            // one translatable entry rather than one per soul name.
            placeholderRotation: [
                AppLocalized("Try @ to mention files for \(soulName) to read"),
                AppLocalized("Type / for SKILLs and quick commands"),
                AppLocalized("Try dragging text into the chat to send it"),
                AppLocalized("Long-press anywhere in a reply to select and copy it all"),
                // Unlike the hints above, this one points at a Setting rather
                // than an in-composer gesture, and so takes no soul name — the
                // Return Key preference (Settings -> Appearance) is global.
                AppLocalized("Minis can make the Return key send or insert a newline"),
            ],
            // [T-ios-composer-placeholder-rotation] Rotate on the very first
            // focus too, but only when there is already a conversation to
            // apply the hints to. In an empty session the default ("Message
            // <soul>…") is the one line that tells a new user what the field
            // is for, so it stays put until they have actually sent something.
            placeholderRotatesOnFirstFocus: !vm.messages.isEmpty,
            // [T-ios-context-usage-hint] One request per finished turn; the
            // Coordinator debounces and shows it for a few seconds.
            contextUsageHint: vm.contextUsageHint,
            // [T-ios-crash-objectdestroy-composer-uaf] Every stored closure
            // below captures ONLY a class reference (`vm`, `composerActions`),
            // never this view. Passing `handleReturnKey` & co. (instance
            // methods) or reading `vm` through `self` put a whole AIChatView
            // copy into each closure context; when SwiftUI's graph teardown
            // released it, the stale copy was destroyed after its @State boxes
            // were gone — `objectdestroy.NNTm` under `destroy for
            // PastableTextView` (build 25, iOS 16.0.3 / 17.3.1).
            onPasteImage: { [vm] image in vm.addImageAttachment(image) },
            onPasteFile: { [vm] url in vm.addFileAttachment(from: url) },
            // [T-paste-placeholder] Long pasted text stays inline: the vm
            // stashes it and the composer inserts the returned `[pasted#N]`.
            onPasteLongText: { [vm] text in vm.stashPastedText(text) },
            onReturnKey: { [composerActions] in _ = composerActions.send(.returnKey) },
            onArrowUp: { [composerActions] in composerActions.send(.arrowUp) },
            onArrowDown: { [composerActions] in composerActions.send(.arrowDown) },
            onTab: { [composerActions] in composerActions.send(.tab) },
            onCaretChange: { [composerActions] caret in _ = composerActions.send(.caret(caret)) },
            onSelectionReplace: { before, after in
                // [T-text-input-correction-source] Feed composer select-and-
                // replace edits into the SAME correction learner as voice
                // transcript fixes, tagged source=text_input. Fire-and-forget
                // off the keystroke path (design §12.2). The recorder applies
                // the phonetic-admission + consent gate, so a plain reword is
                // dropped and nothing is stored without opt-in. locale "zh" is
                // the only phonetic normalizer currently active; the composer
                // has no ASR language context, and a non-normalizable locale
                // would just be discarded downstream.
                Task.detached(priority: .utility) {
                    await VoiceCorrectionRecorder.shared.recordEdit(
                        before: before, after: after,
                        locale: "zh", source: "text_input")
                }
            },
            desiredCaret: vm.pendingCaret,
            // [T-ipad-composer-resize] Raise the text view's growth cap in
            // lockstep with the dragged frame, otherwise text would scroll at
            // 120pt inside a taller box and the extra space would be dead.
            maxHeightOverride: composerTextHeight
        )
        return AnyView(composerBody(field: field, topPadding: topPadding))
    }

    /// [T-ipad-composer-resize] Wraps the text field with its (optional) fixed
    /// height and the iPad drag handle.
    ///
    /// `.fixedSize(vertical:)` and an explicit `.frame(height:)` are mutually
    /// exclusive: fixedSize asks the view for its intrinsic height, which is
    /// exactly what we're overriding once the user has resized. So the two
    /// modes are separate branches rather than modifiers stacked on one view.
    private func composerBody(field: PastableTextView, topPadding: CGFloat) -> some View {
        Group {
            if let height = composerTextHeight {
                field.frame(height: height)
            } else {
                field.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            if composerResizeEnabled { composerResizeHandle }
        }
    }

    /// The grab affordance. Dragging UP makes the composer taller, so the drag
    /// translation is negated. Double-tapping toggles between the two extremes.
    private var composerResizeHandle: some View {
        Capsule()
            .fill(ChatColors.secondaryText.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.top, 4)
            .contentShape(Rectangle().inset(by: -12))  // enlarge the hit area
            // Order matters: the double-tap must be registered BEFORE the drag,
            // otherwise the drag (minimumDistance 2) claims the touch sequence
            // first and the second tap never forms.
            .onTapGesture(count: 2) { toggleComposerHeight() }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in composerDragOffset = -value.translation.height }
                    .onEnded { value in
                        let resolved = min(
                            max(currentComposerHeight - value.translation.height,
                                Self.composerDefaultHeight),
                            composerMaxHeight)
                        composerDragOffset = 0
                        persistComposerHeight(resolved)
                    }
            )
            .accessibilityLabel(AppLocalized("Resize input box"))
            .accessibilityHint(AppLocalized("Drag to resize, double tap to toggle"))
    }

    /// Double-tap: jump between the 50% cap and the default height. Anything
    /// short of the cap counts as "not expanded" and expands, so a partially
    /// dragged composer grows rather than collapsing unexpectedly.
    private func toggleComposerHeight() {
        let isExpanded = currentComposerHeight >= composerMaxHeight - 0.5
        withAnimation(.easeOut(duration: 0.2)) {
            persistComposerHeight(isExpanded ? Self.composerDefaultHeight : composerMaxHeight)
        }
    }

    /// Store a resolved composer height as a screen fraction. Collapsing to the
    /// default clears the preference entirely, so the composer returns to
    /// content-driven sizing rather than being pinned at the default.
    private func persistComposerHeight(_ height: CGFloat) {
        composerHeightFraction = height <= Self.composerDefaultHeight + 0.5
            ? 0
            : height / UIScreen.main.bounds.height
    }

    /// The composer's height right now, used as the drag's starting point.
    private var currentComposerHeight: CGFloat {
        composerHeightFraction > 0
            ? min(max(UIScreen.main.bounds.height * composerHeightFraction,
                      Self.composerDefaultHeight), composerMaxHeight)
            : Self.composerDefaultHeight
    }
}
