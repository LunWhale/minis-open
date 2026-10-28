//
//  AIChatViewModel+ThinkingLevel.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, thinking level: set / read the session's thinking level,
//  the group default, and flushing a level chosen before the session existed.
//  The pending level is stored in AIChatViewModel.swift.
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
    /// Set thinking level — persists if session exists, otherwise holds in memory.
    func setThinkingLevel(_ level: ThinkingLevel) {
        let maxLevel = resolveCurrentEntry()?.effectiveMaxThinkingLevel ?? .xhigh
        let clamped = level == .off ? level : min(level, maxLevel)
        if let sid = sessionId {
            var cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
            cfg.thinkingLevel = clamped
            ProviderConfigStore.shared.setInferenceConfig(cfg, for: sid)
        } else {
            pendingThinkingLevel = clamped
        }
        if !transitionSuspended { objectWillChange.send() }
    }

    /// Default thinking level the first send will seed, or .off. Resolved from the
    /// same group createInitialBinding binds - the long-press FAB group when there
    /// is one, else the default primary group - so the level shown before sending
    /// is the one the session starts with. [T-newchat-thinking-off-kept]
    private var defaultGroupThinkingLevel: ThinkingLevel {
        let store = ProviderConfigStore.shared
        guard let groupId = initialGroupId ?? store.defaultPrimaryGroupId,
              let group = store.group(for: groupId) else { return .off }
        return group.defaultThinkingLevel ?? .off
    }

    /// Current thinking level for this session.
    ///
    /// [T-ios-stale-thinking-level-display] The stored value can exceed the
    /// active model's current ceiling — e.g. a session/group config persisted
    /// `.ultra` (or `.max`) while a model's `effectiveMaxThinkingLevel` was higher,
    /// then the catalog cap was tightened (sol/terra .ultra→.max, etc.). The write
    /// path (`setThinkingLevel`) clamps, but a value persisted under a looser cap
    /// is never rewritten, so a raw read would surface a level the model no longer
    /// supports — the "is thinking…" pill would show "Ultra/极限" when the user's
    /// effective (and wire-sent) level is really "Max". Clamp on read so the
    /// displayed level always matches what will actually be requested (the request
    /// path re-clamps per-model too — AgentProvider: min(level, catalogMax)).
    var currentThinkingLevel: ThinkingLevel {
        let stored: ThinkingLevel = {
            if let sid = sessionId, let cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) {
                return cfg.thinkingLevel
            }
            return pendingThinkingLevel ?? defaultGroupThinkingLevel
        }()
        guard stored.isEnabled else { return stored }
        guard let entry = resolveCurrentEntry() else { return min(stored, .xhigh) }
        let clamped = min(stored, entry.effectiveMaxThinkingLevel)
        // [T-thinking-levels-data-driven] The offered set can be SPARSE (a model
        // declaring ["high","max"] offers only High/Max), and a level persisted
        // before that was known — or carried over from another model — may not
        // be in it. Snap onto the nearest offered tier at or below, mirroring
        // `clampEffort`'s prefer-downgrade rule, so the pill and the checkmark
        // agree with the value actually sent.
        let levels = entry.selectableThinkingLevels
        guard !levels.isEmpty, !levels.contains(clamped) else { return clamped }
        return levels.last(where: { $0 <= clamped }) ?? levels[0]
    }

    /// Flush pending thinking level to the store once sessionId is available.
    /// Returns `true` if a user-chosen level was written, so the caller can
    /// keep the group-default seeding (createInitialBinding) from clobbering it.
    ///
    /// [T-newchat-thinking-off-kept] An explicit Off counts as a choice too.
    /// "Unset" is `pendingThinkingLevel == nil`, not `.off`: the optional already
    /// tells the two apart, so an Off picked before the first send is written and
    /// the group default is not seeded over it. (It used to be skipped here, so a
    /// new chat switched to Off snapped back to the group's level on send.)
    @discardableResult
    func flushPendingThinkingLevel() -> Bool {
        guard let pending = pendingThinkingLevel, let sid = sessionId else { return false }
        var cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
        cfg.thinkingLevel = pending
        ProviderConfigStore.shared.setInferenceConfig(cfg, for: sid)
        pendingThinkingLevel = nil
        return true
    }
}
