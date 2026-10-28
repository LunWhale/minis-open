//
//  AIChatView+TrailingMenu.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, the navigation bar's "..." menu: builds ChatTrailingMenu with
//  this page's actions, opens the share picker, starts a New Chat (confirming
//  first while a task runs) and runs Force Sync / Force Pull.
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
    // MARK: - Toolbar Trailing Menu

    @ViewBuilder
    var trailingMenu: some View {
        trailingMenuButton
    }

    /// [T-ios-navbar-menu-baritem] The menu with this page's actions; shown
    /// either inside the SwiftUI toolbar (`trailingMenu`) or as a real bar
    /// button by ChatNavMenuBarItemInstaller (`navBarMenuInstaller`).
    var trailingMenuButton: ChatTrailingMenuButton {
        // [T-ios-navbar-uikit-menu] FINAL: UIKit-owned button+menu. The
        // SwiftUI route is exhausted — with .equatable() the toolbar host
        // provably stopped ALL ToolbarContent rebuilds (device log
        // 2026-07-18 01:33: toolbarHostEval=1 across an entire session)
        // and the open menu STILL refreshed on tool-render/streaming
        // passes: SwiftUI's toolbar bridge re-pushes bar items on host
        // updates unconditionally, independent of content diffing. Only a
        // persistent UIKit anchor (the UIButton instance survives SwiftUI
        // updates; the presented UIMenu hangs off it) is immune — user-
        // verified to stop the refresh on 2026-07-17. sizeThatFits reports
        // the intrinsic icon size so the system wraps it in the same round
        // glass as a plain toolbar icon (fixes the earlier capsule).
        return ChatTrailingMenuButton(
            messagesEmpty: vm.messages.isEmpty,
            hasSession: vm.sessionId != nil,
            isForcePulling: isForcePulling,
            iCloudSyncEnabled: iCloudSyncEnabled,
            memoryEnabled: vm.memoryEnabled,
            speakEnabled: cached.vm.speakEnabled,
            showEnhancedCacheToggle: cached.vm.showEnhancedCacheToggle,
            enhancedCacheEnabled: cached.vm.enhancedCacheEnabled,
            showFastModeToggle: activeModelSupportsFastMode,
            speedTier: displayedSpeedTier,
            showUltrafast: activeModelSupportsUltrafast,
            keepAwakeEnabled: keepAwakeThisChat,
            screenSaverNowEnabled: screenSaverNowThisChat,
            onNewChat: { requestNewChatFromMenu() },
            // [T-chat-menu-compact-entry] Same effect as the /compact slash
            // command (AIChatViewModel+SlashCommands case "compact").
            onCompact: { vm.compactAll() },
            onClearChat: { showClearChatConfirm = true },
            onForceSync: { runForceSync() },
            onForcePull: { showForcePullConfirm = true },
            onOpenTerminal: { showTerminal = true },
            onOpenBrowser: { showBrowserSheet = true },
            onBrowseFiles: { showFileBrowser = true },
            onSkills: { showSessionSkills = true },
            onMCPs: { showSessionMCPs = true },
            onMemories: { showSessionMemory = true },
            setSpeakEnabled: { enabled in
                cached.vm.speakEnabled = enabled
                // Keep the persisted "Read replies" preference in lockstep.
                VoiceOutputPreferences.isEnabled = enabled
                if enabled {
                    // Explicit enable from the "…" menu → open expanded.
                    cached.vm.speechPlayerExpanded = true
                } else {
                    cached.vm.stopSpeech()
                }
            },
            setEnhancedCache: { newValue in
                if newValue && !UserDefaults.standard.bool(forKey: "enhancedCacheConfirmed") {
                    showEnhancedCacheAlert = true
                } else {
                    cached.vm.enhancedCacheEnabled = newValue
                }
            },
            // [T-codex-fast-mode] Persisted in UserDefaults; the providers read
            // it at request-build time, so a change applies to the very next
            // request. [T-codex-speed-tier] Tier + legacy Bool together.
            setSpeedTier: { tier in SpeedTierSettings.setTier(tier) },
            // [T-always-on] This chat only, in memory; cleared when the user
            // leaves the chat (ContentView).
            setKeepAwake: { on in
                if let key = vm.sessionId ?? vm.draftId {
                    AlwaysOnController.shared.setSessionOverride(on, for: key)
                }
            },
            // [T-always-on-now] This chat, any time ([T-keepawake-submenu]):
            // lasts until unchecked or the user leaves the chat.
            setScreenSaverNow: { on in
                if let key = vm.sessionId ?? vm.draftId {
                    AlwaysOnController.shared.setScreenSaverNow(on, for: key)
                }
            },
            onTokenUsage: { showTokenUsage = true },
            // LastAPIRequestBody + copySessionDataToClipboard are DEBUG-only (the
            // menu buttons that invoke these closures are #if DEBUG too); guard the
            // bodies so Release/archive builds — where those symbols are compiled
            // out — still link. Release keeps the closures as no-ops.
            onCopyRequests: {
                #if DEBUG
                let requests = LastAPIRequestBody.shared.getAll()
                if requests.isEmpty {
                    UIPasteboard.general.string = "(no requests captured)"
                } else {
                    let all = requests.enumerated().map { idx, req in
                        req.formatted(index: idx + 1)
                    }.joined(separator: "\n\n")
                    UIPasteboard.general.string = all
                }
                #endif
            },
            onCopySessionData: {
                #if DEBUG
                copySessionDataToClipboard()
                #endif
            },
            onShare: { openSharePicker(selecting: nil) },
            // [T-in-chat-search]
            onSearchInChat: { vm.chatSearch.activate(prefill: nil) }
        )
    }

    /// [T-ios-navbar-menu-baritem] Zero-size view that keeps the "..." on the
    /// navigation item as a UIBarButtonItem (see ChatNavMenuBarItemInstaller).
    @ViewBuilder
    var navBarMenuInstaller: some View {
        if ChatNavMenuBarItem.isEnabled {
            ChatNavMenuBarItemInstaller(menu: trailingMenuButton)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// [T-multi-select-share] Opens the share picker over this chat's messages as they
    /// are now, with the question or reply containing `messageId` selected (its text,
    /// not its tool calls or thinking; nil: nothing selected).
    func openSharePicker(selecting messageId: UUID?) {
        let messages = vm.messages
        let cells = ChatExportContent.cells(for: messages)
        guard !cells.isEmpty else { return }
        // [T-share-fold-tools] The same rows with tool runs folded the way the
        // chat folds them (and only as far, for a reply still being written).
        let folded = ChatExportContent.cells(for: messages, foldTools: true,
                                             runningMessageId: vm.toolFoldRunningMessageId,
                                             separators: vm.toolFoldSeparators)
        let startsFolded = ToolFoldPlanner.isEnabled
        let units = ChatShareUnits.group(messages.map(ChatShareUnitSource.init(message:)))
        let unit = messageId.flatMap { ChatShareUnits.unit(containing: $0, in: units)?.id }
        let title = titlePillSession?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        shareRequest = ChatShareRequest(
            cells: cells, foldedCells: folded, startsFolded: startsFolded, messages: messages,
            initialSelection: ChatShareCells.roundSelection(unit: unit, in: startsFolded ? folded : cells),
            title: (title?.isEmpty == false ? title : nil) ?? AppLocalized("New Chat"),
            vm: vm)
    }

    // MARK: - New Chat (menu entry)

    /// [T-new-chat-menu-entry] "New Chat" from the "…" menu. Streaming sessions
    /// get a confirm first (stopping the task is destructive); idle sessions go
    /// straight to the shared `.newChatRequested` path, which replaces the
    /// current chat with a fresh draft. Drafts aren't persisted until the first
    /// message, so leaving an empty/draft session this way leaves no residue,
    /// and a double-tap just re-mints the draft instead of creating two rows.
    private func requestNewChatFromMenu() {
        if vm.isProcessing {
            showNewChatStopConfirm = true
        } else {
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
        }
    }

    // MARK: - Force Sync / Pull

    private func runForceSync() {
        guard let sid = vm.sessionId, !isForcePulling else { return }
        isForcePulling = true
        forcePullToast = AppLocalized("Marking for upload…")
        Task {
            let n = await ChatStore.shared.forceSyncSession(sid)
            if #available(iOS 17.0, *) {
                await MainActor.run { SyncCore.shared.scheduleSend(delay: 0.5) }
            }
            await MainActor.run {
                isForcePulling = false
                forcePullToast = AppLocalized("Marked \(n) records for sync. iCloud is uploading now.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    forcePullToast = nil
                }
            }
        }
    }

    func runForcePull() {
        guard let sid = vm.sessionId, !isForcePulling else { return }
        isForcePulling = true
        forcePullToast = AppLocalized("Pulling from iCloud…")
        Task {
            let outcome = await ChatStore.shared.forcePullSession(sessionId: sid)
            // Inbound hydration runs asynchronously after applyPortables
            // hands batches off to MainActor.processInbound, so wait a
            // beat before reloading. Two reloads cover the case where
            // the first one lands mid-batch.
            try? await Task.sleep(nanoseconds: 800_000_000)
            await vm.reloadMessagesFromDB(reason: "forcePull-tick1")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await vm.reloadMessagesFromDB(reason: "forcePull-tick2")
            await MainActor.run {
                isForcePulling = false
                switch outcome {
                case .applied(let pulled, let deleted):
                    forcePullToast = AppLocalized("Pulled \(pulled) records · removed \(deleted) local")
                case .cloudEmpty:
                    forcePullToast = AppLocalized("iCloud has no records for this chat — local messages preserved")
                case .failed(let msg):
                    forcePullToast = AppLocalized("Force Pull failed: \(msg) — local messages preserved")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    forcePullToast = nil
                }
            }
        }
    }
}
