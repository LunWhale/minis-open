//
//  AIChatViewModel+Lifecycle.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, lifecycle outside init / deinit: marking long-running
//  background browser tasks on foreground return, invalidating attributed
//  string caches on a font change, and the non-destructive teardown a cached
//  VM goes through when the VM cache evicts it (releaseForEviction /
//  releaseRenderState - display state only, never work it owns; cancel()
//  is the destructive counterpart).
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

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {
    /// [T-tool-bg-suspended-hint] On foreground return, mark still-running
    /// browser tool blocks that spanned the just-ended background period and
    /// have now run longer than `bgHintBrowserThreshold`. Skips entirely when
    /// enhanced background is already effective (nothing to suggest) — same
    /// gate as the BackgroundInterruptionTracker banner. In-memory only.
    ///
    /// [T-bka-continued-hint] Also: when the background period that just ended
    /// ran on iOS 26's continued-processing task (the slow fallback keep-alive),
    /// flag the tool blocks that overlapped it by at least
    /// `bgHintContinuedMinOverlap`, so the ⓘ suggests the faster
    /// background-audio keep-alive. Shorter overlaps are left alone: the lower
    /// CPU share barely shows on them, and marking every quick tool of a long
    /// background run would bury the chat in icons.
    @MainActor
    func markLongBackgroundBrowserTasks() {
        defer { bgHintBackgroundEntryDate = nil }
        guard let bgEntry = bgHintBackgroundEntryDate else { return }
        guard !BackgroundKeepAliveManager.shared.enhancedBackgroundEffective else { return }
        let now = Date()
        if let lastTick = BackgroundKeepAliveManager.shared.continuedLastBackgroundTick, lastTick >= bgEntry {
            markToolsThatRanOnContinuedTask(from: bgEntry, to: lastTick, now: now)
        }
        for msg in messages where msg.role == .assistant {
            for block in msg.blocks {
                guard case .browserTool = block.kind else { continue }
                guard case .running = block.toolStatus else { continue }
                guard let start = block.toolStartTime,
                      now.timeIntervalSince(start) > Self.bgHintBrowserThreshold else { continue }
                block.wasBackgroundSuspended = true
            }
        }
    }

    static let bgHintContinuedMinOverlap: TimeInterval = 10

    @MainActor
    private func markToolsThatRanOnContinuedTask(from start: Date, to end: Date, now: Date) {
        var marked = 0
        for msg in messages where msg.role == .assistant {
            for block in msg.blocks where block.toolStatus != nil {
                // Waiting, not computing: a question waits for the user, a
                // delegate block for its sub agent (whose own tools are
                // marked in that session).
                switch block.kind {
                case .userAskTool, .delegateTool: continue
                default: break
                }
                guard let toolStart = block.toolStartTime else { continue }
                let toolEnd = block.toolDuration.map { toolStart.addingTimeInterval($0) } ?? now
                let overlap = min(toolEnd, end).timeIntervalSince(max(toolStart, start))
                guard overlap >= Self.bgHintContinuedMinOverlap else { continue }
                ContinuedRunHintStore.blockIds.insert(block.id)
                if !block.wasBackgroundSuspended { block.wasBackgroundSuspended = true }
                marked += 1
            }
        }
        if marked > 0 {
            logger.info("[BKA][ContinuedHint] marked \(marked) tool block(s) that ran on the continued task in the background")
        }
    }

    /// Clear all cached attributed strings so they re-render with the new font size.
    /// Called by the coordinator before reconfiguring cells to guarantee ordering.
    @MainActor
    func invalidateAttributedStringCaches() {
        for msg in messages {
            for block in msg.blocks {
                if block.cachedAttributedString != nil {
                    block.cachedAttributedString = nil
                }
            }
        }
        if !transitionSuspended { objectWillChange.send() }
    }

    // MARK: - [T-vmcache-release] Non-destructive teardown

    /// Free everything a cached VM holds for DISPLAY, without touching any
    /// work it owns.
    ///
    /// This is the counterpart to `cancel()`, and the distinction is the whole
    /// point of it. `cancel()` is the user pressing Stop: it drops queued
    /// delegations and calls `AgentJobRegistry.cancelAll(parent:silent:)`.
    /// Eviction used to call exactly that, so a cache-size policy silently
    /// killed live sub agents and logged them as
    /// `reason=user stopped the conversation (silent)` — see 761be79da.
    ///
    /// A release, by contrast, must be invisible to the model and to the job
    /// registry: nothing is cancelled, nothing is reported, and every durable
    /// record has already been written (the sub agent result lands in SQLite
    /// via `persistFinalDelegateResult`, and `then.followUpParent` re-creates
    /// this VM through `getOrCreate` + `loadSession` if it needs it). What is
    /// dropped is only what can be rebuilt from the database.
    @MainActor
    func releaseForEviction() {
        releaseRenderState()
        // Deliberately NOT touched: `currentTask`, AgentJobRegistry jobs,
        // SessionActivityTracker, browserTabPool ownership. A VM reaching here
        // has already been vetted by `isEvictable`, which refuses anything with
        // a live loop or live children — so there is no in-flight work to stop,
        // and if that guard is ever loosened the work must SURVIVE, not die.
        logger.info("♻️ releaseForEviction session=\(self.sessionId ?? "nil") vm=\(self.vmInstanceId) messages=\(self.messages.count)")
    }

    /// Drop render-only state (parsed markdown + laid-out attributed strings)
    /// while keeping the message text itself.
    ///
    /// Used both by eviction and by a child conversation leaving the screen:
    /// a sub agent that nobody is watching should not keep TextKit layout
    /// trees alive for output only the model reads. Everything dropped here is
    /// regenerated lazily on the next render.
    @MainActor
    func releaseRenderState() {
        var cleared = 0
        for msg in messages {
            for block in msg.blocks {
                if block.cachedAttributedString != nil { block.cachedAttributedString = nil; cleared += 1 }
                if block.cachedMarkdown != nil { block.cachedMarkdown = nil }
            }
            // The per-message renderer lives in a STATIC cache that VM
            // eviction never reached (it is keyed by message id, not session),
            // so it has to be dropped explicitly or it outlives everything.
            SelectableMarkdownView.dropRenderer(for: msg.id)
        }
        if cleared > 0 { logger.info("♻️ releaseRenderState session=\(self.sessionId ?? "nil") cleared=\(cleared) block cache(s)") }
    }
}

/// [T-bka-continued-hint] Tool blocks whose ⓘ means "ran slowly on the
/// continued-processing task" rather than "may have been paused". A side
/// table, not a field on AssistantBlock (adding stored fields there crashed
/// launch before). In memory only, like `wasBackgroundSuspended`; the ⓘ
/// itself is still driven by that published flag, this only picks the text.
@MainActor
enum ContinuedRunHintStore {
    static var blockIds = Set<UUID>()
}
