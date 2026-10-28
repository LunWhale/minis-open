//
//  MessageListV3Coordinator+BridgeUpdates.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  Refreshes a message's CellStateBridgeV2 (active / streaming flags,
//  callbacks, usage) and tracks the footer height shape so a changed footer
//  is re-measured.
//
//  Seam: one `extension CollectionViewMessageListV3.Coordinator`. Members keep
//  the 8-space indent of the class body they came from, so text searches and
//  the source-pinning tests in MinisTests/Standalone still match. Stored state
//  is declared in MessageListV3Coordinator.swift (search "Stored state of
//  +BridgeUpdates" there, or the prelude at the top of the class).
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

extension CollectionViewMessageListV3.Coordinator {

        // MARK: - Bridge Updates

        func updateBridge(_ bridge: CellStateBridgeV2, message: ChatMessage, in messages: [ChatMessage],
                                  isInitialBridgeSetup: Bool = false) {
            guard let vm else { return }
            let isLast = message.id == messages.last?.id
            // [T-queued-candidate-spacing] The running turn's message is the
            // live tail: a candidate queued below it does not end it. Resume
            // and Retry stay on the literal last message, as before.
            let isLiveTail = message.id == Self.liveTailMessage(in: messages)?.id
            let isActive = isLiveTail && vm.isProcessing

            // [T-ios-plaf-cache-footer-staleness] Snapshot the height-BEARING
            // subset before writing. These four decide whether the footer shows
            // a typing indicator / resume banner / retry row at all — i.e. the
            // difference between a ~4pt quiet footer and a ~48pt prominent one —
            // yet they are written here with no snapshot apply, no reconfigure
            // and no cache invalidation, so `SelfSizingCell`'s unbounded height
            // cache would keep reporting the pre-flip height forever.
            //
            // Compared as a BOOLEAN SHAPE, not by raw value: `autoRetryCountdown`
            // ticks once a second while only its zero/non-zero transition changes
            // the rendered height, and invalidating on every tick would re-enter
            // the hosting graph 30× per retry — exactly what the FB13213926
            // series exists to avoid.
            // [T-ios-first-block-footer-gap] Compare against the shape recorded
            // on the PREVIOUS call, not one taken from `message` at the top of
            // this one.
            //
            // The original code snapshotted `bridge` here and re-read it below,
            // which works because the lines in between mutate `bridge`. The two
            // new fields come from `message`, which this function never mutates
            // — comparing it with itself could never see a change. The edge we
            // need (`hasVisibleContent` false -> true) happens BETWEEN calls, as
            // the first block lands, so the previous call's shape is the only
            // valid baseline.
            let beforeShape = lastFooterShapeByMessage[message.id]
                ?? FooterHeightShape(bridge: bridge, message: message)

            bridge.isActiveMessage = isActive
            bridge.commandStartTime = vm.commandStartTime
            bridge.onStop = isActive ? { [weak self] in self?.onStop?() } : nil
            bridge.browserPool = vm.browserTabPool
            bridge.toolSnapshots = vm.toolSnapshots
            bridge.autoRetryAttempt = isLiveTail ? vm.autoRetryAttempt : 0
            bridge.autoRetryCountdown = isLiveTail ? vm.autoRetryCountdown : 0
            // [T-ios-session-status-mismatch] Defense-in-depth: even if vm.canResume
            // is somehow stale-true and vm.isProcessing hasn't flipped yet, do NOT
            // show the "Interrupted — tap Resume" banner while SessionActivityTracker
            // still lists this session as active (same signal the home list spinner
            // reads). This closes the residual gap where a new/reloaded VM sees a
            // toolResult-tail during a live loop's tool_result → next-model-call gap.
            let trackerActive: Bool = {
                guard isLast, let sid = vm.sessionId else { return false }
                return SessionActivityTracker.shared.isActive(sid)
            }()
            bridge.canResume = isLast ? (vm.canResume && !vm.isProcessing && !trackerActive) : false
            // [T-p1-delegate-task] Only offer Resume when the host actually
            // wired one — the read-only helper sheet passes nil, and a dead
            // "Resume" button in a mirror that forbids input is a lie.
            bridge.onResume = (isLast && self.onResume != nil) ? { [weak self] in self?.onResume?() } : nil
            bridge.onWithdraw = message.isQueued ? { [weak self] in self?.onWithdraw?(message.id) } : nil
            // "Read from Start": replay this whole reply via TTS. Only for assistant
            // messages; disabled while it's the actively-streaming reply.
            bridge.isStreaming = isActive
            bridge.onReadAloud = (message.role == .assistant)
                ? { [weak vm] in vm?.readReplyFromStart(message) }
                : nil
            // [T-selection-menu-minis-tts] "Read Selection" from the text
            // selection menu — speaks the selected snippet via the Minis TTS
            // stack (sanitizer + provider voices + fail-over).
            bridge.onSpeakText = { [weak vm] text in vm?.speakText(text) }
            // [T-multi-select-share] Replaces "Copy Screenshot" (which stitched a
            // live-scrolled screenshot of one question + answer): open the share
            // picker with this message's unit already selected.
            bridge.onShareMessages = { [weak self] in
                self?.onShareMessages?(message.id)
            }

            let retryMsg = onRetryMessage
            let retryLast = onRetryLast
            let edit = onEdit
            let deleteFrom = onDeleteFrom
            let compact = onCompact
            let forceSync = onForceSync
            bridge.onForceSync = forceSync

            bridge.onShowCompactSummary = { [weak self] summary in
                guard let self else { return }
                // Update the presenter's revert callback every time the sheet
                // opens so it always points at the current vm. Captured weakly
                // so a closed-over coordinator that's been discarded can't
                // pin the view-model's lifetime.
                self.compactSummaryPresenter.onRevert = { [weak self] in
                    self?.onRevertCompact?()
                }
                self.compactSummaryPresenter.summary = summary
            }

            if message.isCompactedHistory || message.role == .compactDivider || message.role == .systemInfo {
                bridge.onRetry = nil; bridge.onEdit = nil; bridge.onCompact = nil
                bridge.onDeleteFrom = nil
            } else if !vm.isProcessing && !vm.isCompacting {
                if message.role == .user {
                    bridge.onRetry = { retryMsg?(message.id) }
                } else if isLast {
                    bridge.onRetry = { retryLast?() }
                } else {
                    bridge.onRetry = nil
                }
                bridge.onEdit = message.role == .user ? { edit?(message.id) } : nil
                // [T-ios-delete-from-message] Same gate as Edit/Retry: user
                // bubbles only, never while streaming or compacting, never on
                // already-compacted history (its agentHistory anchor is gone).
                // A QUEUED bubble isn't in agentHistory/DB yet — Withdraw is
                // its removal path, so this stays off for it.
                bridge.onDeleteFrom = (message.role == .user && !message.isQueued)
                    ? { deleteFrom?(message.id) } : nil
                bridge.onCompact = { compact?(message.id) }
            } else {
                bridge.onRetry = nil; bridge.onEdit = nil; bridge.onCompact = nil
                bridge.onDeleteFrom = nil
            }

            // [T-ios-plaf-cache-footer-staleness] If the footer's rendered SHAPE
            // changed, the cached height belongs to the old shape — drop it.
            // No-op on the overwhelmingly common path where nothing flipped.
            //
            // Skipped for a freshly-created bridge: that call comes from inside
            // the cell provider during `dataSource.apply`, and reaching back
            // into `cellForItem` mid-apply is a re-entrancy hazard for no gain —
            // a new bridge's cell is being configured from scratch anyway, so
            // `applyContentConfiguration` has already cleared its cache.
            let afterShape = FooterHeightShape(bridge: bridge, message: message)
            lastFooterShapeByMessage[message.id] = afterShape
            if !isInitialBridgeSetup, afterShape != beforeShape {
                invalidateFooterHeightCaches(messageId: message.id)
                // [T-interrupt-banner-gap] The spacing above the footer depends
                // on the same shape, so it must follow the flip too.
                refreshFooterHug(messageId: message.id, message: message, in: messages)
                AppLogger(category: "BottomGapDiag").info(
                    "[BottomGapDiag][footer-shape] msg=\(message.id.uuidString.prefix(8)) changed "
                    + "active=\(beforeShape.isActiveMessage)→\(afterShape.isActiveMessage) "
                    + "typing=\(beforeShape.showsTypingIndicator)→\(afterShape.showsTypingIndicator) "
                    + "— footer height caches dropped")
            }
        }

        /// [T-ios-plaf-cache-footer-staleness] The bridge fields that decide
        /// whether a footer row is rendered at all, reduced to the booleans the
        /// footer body actually branches on (see `hasFooterContent`).
        struct FooterHeightShape: Equatable {
            let isActiveMessage: Bool
            let canResume: Bool
            let showUsage: Bool
            let hasRetryRow: Bool
            // [T-ios-first-block-footer-gap] The typing indicator's OTHER
            // input. This shape once tracked only `isActiveMessage`, so when
            // the indicator stopped being drawn the shape still compared EQUAL,
            // the cache was not dropped, and the footer kept the ~48pt height
            // it had measured while the indicator was on screen — a footer
            // occupying indicator-sized space with nothing in it, i.e. the
            // blank strip users reported.
            //
            // [T-ios-typing-indicator-scope] Now tracks the rendered predicate
            // itself rather than its ingredients. It toggles both ways within a
            // turn (each tool round: waiting -> producing -> waiting), and the
            // footer's height must follow every one of those edges.
            let showsTypingIndicator: Bool

            init(bridge: CellStateBridgeV2, message: ChatMessage) {
                isActiveMessage = bridge.isActiveMessage
                canResume = bridge.canResume
                showUsage = bridge.showUsage
                // Zero/non-zero only — see the note in updateBridge about the
                // per-second countdown tick.
                hasRetryRow = bridge.autoRetryAttempt != 0
                showsTypingIndicator = bridge.isActiveMessage
                    && message.shouldShowTypingIndicator
            }
        }


        func updateLastCellBridge() {
            guard let vm else { return }
            let messages = vm.messages
            guard let lastMsg = messages.last else { return }
            if let bridge = cellBridges[lastMsg.id] {
                updateBridge(bridge, message: lastMsg, in: messages)
            }
            // [T-queued-candidate-spacing] With a queued candidate last, the
            // message in progress is further up: keep it active too. The loop
            // below used to switch it off, which removed its "is thinking…"
            // row and Stop while the turn was still running.
            let liveTail = Self.liveTailMessage(in: messages)
            if let liveTail, liveTail.id != lastMsg.id, let bridge = cellBridges[liveTail.id] {
                updateBridge(bridge, message: liveTail, in: messages)
            }
            if messages.count >= 2 {
                let prev = messages[messages.count - 2]
                if let prevBridge = cellBridges[prev.id], prevBridge.canResume {
                    prevBridge.canResume = false
                    prevBridge.onResume = nil
                }
            }
            for msg in messages.dropLast() where msg.id != liveTail?.id {
                if msg.role == .assistant, let b = cellBridges[msg.id], b.isActiveMessage {
                    b.isActiveMessage = false
                }
            }
            for msg in messages where msg.role == .user {
                if let b = cellBridges[msg.id] {
                    updateBridge(b, message: msg, in: messages)
                }
            }
        }
}
