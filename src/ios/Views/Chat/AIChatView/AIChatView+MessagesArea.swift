//
//  AIChatView+MessagesArea.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, message area: the message list container with its top inset,
//  scroll-to-top / bottom buttons, the floating tool preview, and the content
//  width cap for regular size classes.
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
    // MARK: - Messages

    /// [T-scheduled-banner] On iOS 26 the content runs behind the navigation
    /// bar and the top banners, so the list adds their height to its top
    /// inset; earlier iOS lays the list out below both.
    static func listTopInset(forTopBanners height: CGFloat) -> CGFloat {
        if #available(iOS 26, *) { return height }
        return 0
    }

    var messagesArea: some View {
        ZStack {
            CollectionViewMessageListV3(
                vm: vm,
                inputFocused: inputFocused,
                onRetryMessage: { vm.retryFromMessage($0); vm.forceScrollToBottom.send() },
                onRetryLast: { vm.retry(); vm.forceScrollToBottom.send() },
                // [T-ios-assistant-header-open-soul] Routed through the same
                // handler every `minis://` link in the transcript uses, so the
                // identity row and an agent-authored
                // `[Soul](minis://settings/soul)` link land identically —
                // no second navigation path to keep in sync.
                onOpenSoulSettings: {
                    guard let url = URL(string: "minis://settings/soul") else { return }
                    _ = handleMinisURLTap(url)
                },
                onEdit: { [self] msgId in
                    vm.editMessage(msgId)
                    inputFocused = true
                },
                onDeleteFrom: { vm.deleteFromMessage($0) },
                onWithdraw: { vm.withdrawQueuedMessage($0) },
                onResume: { vm.resume(); vm.forceScrollToBottom.send() },
                onStop: { vm.stopCurrentCommand() },
                onBrowserTakeover: { vm.browserTakeoverActive = true },
                onTakeoverDone: { vm.resumeFromBrowserTakeover() },
                onCompact: { msgId in compactConfirmMessageId = msgId },
                onRevertCompact: { Task { await vm.revertCompact() } },
                onForceSync: { [self] in
                    guard let sid = vm.sessionId else { return }
                    Task {
                        let count = await ChatStore.shared.forceSyncSession(sid)
                        if #available(iOS 17.0, *), count > 0 {
                            SyncCore.shared.scheduleSend(delay: 1)
                        }
                    }
                },
                onShareMessages: { messageId in openSharePicker(selecting: messageId) },
                maxContentWidth: maxContentWidth ?? 0,
                floatingBarHeight: floatingBarHeight,
                inputBarHeight: inputBarHeight,
                extraTopInset: Self.listTopInset(forTopBanners: topBannersHeight),
                composerLiveHeight: composerLiveHeight
            )
            // Empty/loading overlay for tap-to-dismiss-keyboard.
            // Placed BEFORE the directory timeline in the ZStack so the
            // timeline can sit on top and receive its own taps (folder-card
            // arrow buttons). Taps that miss the timeline content fall
            // through to this background overlay.
            if vm.messages.isEmpty || vm.isLoadingSession {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { inputFocused = false }
            }
            // Empty-chat onboarding tip: a single card explaining the
            // per-session vs cross-session /var/minis/ layout. Only shown
            // on a true draft (vm.sessionId == nil) — opening an existing
            // session would otherwise flash the card during the brief
            // window before its messages load. Returning users with any
            // prior chat skip the tip even on a fresh draft (so it's a
            // genuine first-launch hint).
            if vm.sessionId == nil
                && vm.messages.isEmpty
                && !vm.isLoadingSession
                && (totalSessionCount ?? Int.max) == 0 {
                EmptyChatDirectoryTimeline(onBrowse: { showFileBrowser = true })
                    .padding(.horizontal, 24)
            }
        }
        .overlay(alignment: .bottom) {
            // Open the overlay only when at least one button will actually
            // render — i.e. the gate is the OR of the two buttons' own
            // conditions. Otherwise an in-between state (e.g. far from top but
            // within one screen of the bottom, at rest) would mount an empty
            // VStack.
            if !vm.messages.isEmpty && !vm.isNearBottom {
                VStack(spacing: 10) {
                    // Up-button: walk back one user turn at a time. Visible when
                    // off the bottom AND there's still an earlier turn to jump to
                    // (isAtFirstTurn == false). Once the user has walked all the
                    // way up to the first turn, it hides — nothing further up.
                    if !vm.isAtFirstTurn {
                        Button {
                            vm.forceScrollToTop.send()
                        } label: {
                            // arrow.up.to.line: "jump to a top anchor" reads truer
                            // for the turn-walk / scroll-to-top action than a plain
                            // chevron, and distinguishes it from the down button's
                            // chevron.down. Available since iOS 16 (both our legacy
                            // and iOS 26 floors).
                            scrollFloatingButtonLabel("arrow.up.to.line")
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    // Scroll to bottom — ORIGINAL behavior: shown whenever not
                    // near the bottom (within the 20pt nearBottom threshold), so
                    // it appears as soon as you leave the bottom.
                    Button {
                        vm.forceScrollToBottom.send()
                    } label: {
                        scrollFloatingButtonLabel("chevron.down")
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                .padding(.trailing, 4)
                .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.bottom, inputBarHeight + (hasFloatingPreview ? 80 : 12))
                .animation(.easeInOut(duration: 0.2), value: vm.isNearBottom)
                .animation(.easeInOut(duration: 0.2), value: vm.isAtFirstTurn)
                .animation(.easeInOut(duration: 0.2), value: hasFloatingPreview)
                // The capsule must not cover these floating scroll-jump buttons.
                .capsuleProtectedFrame("scrollButtons")
            }
        }
        // [T-browser-download-ux-v2] Floating download button — same visual
        // family as the scroll buttons, stacked ABOVE their slot (the scroll
        // group can show up to two 36pt buttons + spacing, so offset by 92pt)
        // so the two never overlap regardless of scroll state. Hidden while
        // the session has no download records.
        .overlay(alignment: .bottom) {
            BrowserDownloadFloatingButton(sessionId: vm.sessionId ?? "") {
                showDownloadsPanel = true
            }
            .padding(.trailing, 4)
            .frame(maxWidth: maxContentWidth ?? .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
            .padding(.bottom, inputBarHeight + (hasFloatingPreview ? 80 : 12) + 92)
            .animation(.easeInOut(duration: 0.2), value: hasFloatingPreview)
            .capsuleProtectedFrame("downloadButton")
        }
    }

    /// Shared label style for the floating scroll buttons (up / down).
    /// Surface lives in `FloatingCircleButtonSurface` (glass on iOS 26+).
    private func scrollFloatingButtonLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(FloatingCircleButtonSurface.glyphStyle)
            .frame(width: 36, height: 36)
            .modifier(FloatingCircleButtonSurface())
    }

    // MARK: - Floating Tool Preview

    @ViewBuilder
    var floatingToolPreview: some View {
        let allToolBlocks = vm.messages
            .filter { $0.role == .assistant && !$0.isCompactedHistory }
            .flatMap { $0.blocks.filter { $0.toolStatus != nil } }
        if !allToolBlocks.isEmpty {
            // [T-ios-crash-objectdestroy-composer-uaf] Capture `vm` itself, not
            // `self`: these closures are stored in FloatingToolBar, and a
            // captured AIChatView copy crashed in `destroy for FloatingToolBar`
            // (build 25, iOS 16.6).
            let vm = self.vm
            FloatingToolBar(toolBlocks: allToolBlocks, toolSnapshots: vm.toolSnapshots, browserPool: vm.browserTabPool, onBrowserTakeover: { [vm] in
                vm.browserTakeoverActive = true
            }, onTakeoverDone: { [vm] in
                vm.resumeFromBrowserTakeover()
            })
                .frame(maxWidth: maxContentWidth)
                .padding(.horizontal, 12)
                // [T-ios-geometry-observer-crash] onGeometryChange replaces the
                // GeometryReader+onAppear+onChange scaffold: writing state from
                // onChange(of: geo.*) inside the geometry-observer path re-drives
                // layout and trips a precondition on the iOS 18 async renderer
                // (ViewGraphGeometryObservers.needsUpdate SIGTRAP). The action
                // also fires with the initial value, covering the old onAppear.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newH in
                    floatingBarHeight = newH
                }
                .onDisappear {
                    floatingBarHeight = 0
                }
        }
    }

    /// Whether the floating tool preview is visible.
    private var hasAnyToolBlocks: Bool {
        vm.messages.contains(where: {
            $0.role == .assistant && !$0.isCompactedHistory && $0.blocks.contains { $0.toolStatus != nil }
        })
    }

    // MARK: - Floating Speech Button

    /// Floating read-replies player control (compact ↔ expanded capsule), shown
    /// only when read-replies is enabled.
    @ViewBuilder
    // The read-replies speech capsule is now a SINGLE app-root instance (mounted
    // in MinisApp beside AudioPiPCapsule) so it persists across chat → home. No
    // per-session copy is rendered here anymore.
    var floatingSpeechButton: some View { EmptyView() }

    /// Height the floating scroll-jump button stack occupies right now (0 when
    /// hidden), used to lift the speech control so the two never overlap. Mirrors
    /// the visibility conditions of the jump-button overlay above.
    private var scrollJumpButtonsHeight: CGFloat {
        guard !vm.messages.isEmpty else { return 0 }
        // Up and down buttons now share one condition (!isNearBottom): both are
        // present together or both hidden.
        guard !vm.isNearBottom else { return 0 }
        // Sized for the TALLEST case (both buttons: 2×36 + 10 spacing = 82pt). The
        // control already rests +48pt above the buttons' baseline, so lift the
        // excess over that head start, plus a 10pt gap.
        let maxStack: CGFloat = 2 * 36 + 10
        return max(0, maxStack + 10 - 48)
    }

    /// Whether the floating tool preview is visible.
    private var hasFloatingPreview: Bool {
        hasAnyToolBlocks
    }

    /// Max content width — unconstrained in compact (portrait iPhone),
    /// capped in regular (landscape / iPad) for readability.
    var maxContentWidth: CGFloat? {
        hSizeClass == .regular ? 900 : nil
    }
}
