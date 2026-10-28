//
//  AIChatViewModel+ContextUsage.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, context usage and model capabilities: session token
//  totals, the composer's context-usage glow / hint (publishContextUsage and
//  its compaction and mid-loop variants), and what the current model or
//  group supports - reasoning, thinking levels, max output tokens, window.
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
    /// Session-level token totals.
    var sessionTokenStats: (input: Int, output: Int, cacheRead: Int, cacheWrite: Int, context: Int, loopCount: Int) {
        var context = 0
        var toolCalls = 0
        for msg in messages where msg.role == .assistant {
            if let u = msg.usage, u.latestContextTokens > 0 {
                context = u.latestContextTokens
            }
            for block in msg.blocks {
                switch block.kind {
                case .text, .info: break
                default: toolCalls += 1
                }
            }
        }
        let assistantCount = messages.filter({ $0.role == .assistant }).count
        return (sessionInputTokens, sessionOutputTokens, sessionCacheReadTokens, sessionCacheWriteTokens, context, max(toolCalls, assistantCount))
    }

    /// Context window size of the current model (from models.dev or heuristic).
    /// Resolved via `resolveCurrentEntry()` so the UI shows the same window the
    /// send path and capacity checks use (availability re-routing included).
    var currentModelContextWindow: Int? {
        guard let entry = resolveCurrentEntry() else { return nil }
        return effectiveContextWindow(for: entry.model)
    }

    /// [T-ios-context-usage-hint] Recompute `contextUsage` from the newest
    /// assistant message that carries a non-zero `latestContextTokens`, against
    /// the current model's window. Publishes only on change, so the repeated
    /// calls from the usage-write sites and session loads do not churn the
    /// composer. Sets nil (hiding glow + hint) when either side is unknown.
    ///
    /// [T-ios-context-usage-realtime-crossing] `liveContextTokens` lets the
    /// running agent loop publish the context size of the API call that just
    /// returned, before that usage is stamped on the message at turn end —
    /// this is what makes the glow follow a multi-tool turn in real time
    /// instead of changing colour only when the whole turn finishes. The
    /// message-side usage (and the footer capsule) is untouched.
    func publishContextUsage(liveContextTokens: Int? = nil) {
        let reported = messages.last(where: {
            $0.role == .assistant && ($0.usage?.latestContextTokens ?? 0) > 0
        })
        var used = liveContextTokens ?? (reported?.usage?.latestContextTokens ?? 0)
        // [T-ctx-usage-after-compact] A report taken before the latest
        // compaction describes the context that compaction replaced. Showing
        // it after a manual or automatic compaction made the glow and the
        // placeholder read as if compaction had done nothing. Until a newer
        // turn reports, use the measured size of what will actually be sent.
        // `isCompactedHistory` covers a reload, where the in-memory marker
        // from the compaction itself is gone.
        if liveContextTokens == nil, cachedLatestMarker != nil, let reported,
           reported.id == usageReportSupersededByCompaction || reported.isCompactedHistory {
            ensureContextFixedTokens()
            let measured = measureOutboundContextTokens()
            if measured > 0 { used = measured }
        }
        let window = currentModelContextWindow ?? 0
        let next: ContextUsage? = (used > 0 && window > 0)
            ? ContextUsage(usedTokens: used, windowTokens: window) : nil
        if next != contextUsage { contextUsage = next }
    }

    /// [T-ctx-usage-after-compact] Called when a compaction (manual or
    /// automatic — every path goes through `compactBefore`) has installed its
    /// marker. Re-measures the glow from the compacted context and issues a
    /// new placeholder line with the post-compaction estimate, superseding the
    /// pre-compaction figure the composer was still showing. Without this the
    /// line kept the old percentage until the user typed, so compaction looked
    /// like it had no effect.
    func announceContextUsageAfterCompaction() {
        usageReportSupersededByCompaction = messages.last(where: {
            $0.role == .assistant && ($0.usage?.latestContextTokens ?? 0) > 0
        })?.id
        // Live measured size, not the message-derived path: it also works when
        // no turn has reported usage yet.
        publishMeasuredContextUsage()
        guard let usage = contextUsage else {
            logger.info("[ContextUsageHint] post-compact → NO hint: usage unknown")
            return
        }
        let now = Date()
        // Record the (usually lower) tier so a later climb back over 70% / 80%
        // counts as a fresh upward crossing and is announced again.
        _ = contextTierTracker.observe(usage.tier, now: now)
        guard inputText.isEmpty else {
            logger.info("[ContextUsageHint] post-compact → NO hint: composer not empty (\(usage.usedTokens)/\(usage.windowTokens))")
            return
        }
        contextUsageHintGeneration += 1
        // Deliberately not `markFired`: the next turn's loop-end line carries
        // the real reported size and must not be deduplicated against this
        // estimate.
        contextUsageHint = ContextUsageHint.make(usage: usage, generation: contextUsageHintGeneration,
                                                              quota: composerQuotaPart())
        logger.info("[ContextUsageHint] post-compact → hint gen\(contextUsageHintGeneration) '\(contextUsageHint?.text ?? "")' (\(usage.usedTokens)/\(usage.windowTokens))")
    }

    /// [T-quota-composer-hint] The current model's quota for the composer's
    /// usage line, from data the quota store already holds (no request here:
    /// the store refreshes on its own schedule). nil when the model has no
    /// quota data — the line is then the context figures alone, as before.
    func composerQuotaPart() -> ContextUsageHint.QuotaPart? {
        guard let entry = resolveCurrentEntry() else { return nil }
        let quota = QuotaStore.shared
        let view = quota.modelView(instanceId: entry.providerInstanceId, modelId: entry.baseModel.id)
        guard let seg = QuotaComposerHintRules.segment(view, pools: quota.pools) else { return nil }
        let tier: ContextUsage.Tier
        switch seg.level {
        case .normal: tier = .normal
        case .low: tier = .warning
        case .depleted: tier = .critical
        }
        return ContextUsageHint.QuotaPart(text: seg.text, highlight: seg.highlight, tier: tier)
    }

    /// [T-ios-context-usage-realtime-crossing] Called after every API call
    /// inside the agent loop with that call's context size. Publishes the
    /// live usage (glow) and raises the placeholder line immediately when the
    /// tier crosses 70% / 80% upward for the first time since it was last
    /// below — the loop-end path stays as the fallback for turns that end
    /// without a crossing. Same eligibility as the loop-end hint: a turn the
    /// user started and has not cancelled, with an empty composer.
    func noteContextUsageMidLoop(liveContextTokens: Int) {
        // [T-ctx-measure-outbound] The report now feeds the capacity guard by
        // calibrating ContextSizeMeter (calibrateContextSize, at the call site)
        // rather than being mirrored in as a raw size.
        publishContextUsage(liveContextTokens: liveContextTokens)
        guard let usage = contextUsage else { return }
        let now = Date()
        guard contextTierTracker.observe(usage.tier, now: now) else { return }
        guard !userDidCancel, !programmaticSilentTurn, inputText.isEmpty else {
            logger.info("[ContextUsageHint] mid-loop crossing → \(usage.tier) NOT shown: cancel=\(userDidCancel) silent=\(programmaticSilentTurn) inputEmpty=\(inputText.isEmpty) (\(usage.usedTokens)/\(usage.windowTokens))")
            return
        }
        contextUsageHintGeneration += 1
        contextUsageHint = ContextUsageHint.make(usage: usage, generation: contextUsageHintGeneration,
                                                              quota: composerQuotaPart())
        contextTierTracker.markFired(usage.tier, now: now)
        logger.info("[ContextUsageHint] mid-loop crossing → \(usage.tier) hint gen\(contextUsageHintGeneration) '\(contextUsageHint?.text ?? "")' (\(usage.usedTokens)/\(usage.windowTokens))")
    }

    /// Whether the current model (or any model in the group) supports reasoning/thinking.
    ///
    /// Tri-state handling of `model.supportsReasoning`:
    /// - `true`  → supported
    /// - `false` → not supported
    /// - `nil`   → unknown (e.g. DeepSeek V4 fetched from `/v1/models`, which
    ///            returns no capability metadata). Treat as allowed so users
    ///            can still opt into thinking manually; sending the thinking
    ///            params to a non-reasoning model is generally a no-op on the
    ///            server side, whereas hiding the toggle on a reasoning-capable
    ///            model makes the feature unreachable.
    var currentModelSupportsReasoning: Bool {
        let store = ProviderConfigStore.shared

        // Try session binding first
        if let sid = sessionId, let binding = store.binding(for: sid) {
            return checkBindingSupportsReasoning(binding, store: store)
        }

        // No session yet — resolve from default group
        if let entry = resolveCurrentEntry() {
            return Self.entryAllowsReasoning(entry, store: store)
        }

        // Fallback: if user already set pending thinking, honor it
        return (pendingThinkingLevel ?? .off) != .off
    }

    var availableThinkingLevels: [ThinkingLevel] {
        // [T-thinking-levels-data-driven] Offer one option per DISTINCT wire
        // tier the model declares, instead of every level below a ceiling.
        // The old ladder let four options collapse onto a single
        // `reasoning_effort` — verified on-device 2026-08-01: glm-5.2
        // (declares ["high","max"]) sent "high" for Low/Med/High/XHigh alike,
        // while "max" was declared yet unreachable. See
        // `ModelEntry.selectableThinkingLevels` for the fallback rules.
        guard let entry = resolveCurrentEntry() else {
            return ThinkingLevel.allCases.filter { $0 != .off && $0 <= .xhigh }
        }
        return entry.selectableThinkingLevels
    }

    /// Whether a model entry should expose the thinking toggle.
    ///
    /// Base rule (tri-state, unchanged): `supportsReasoning ?? true` — `true`
    /// and unknown (`nil`) both allow the toggle, only an explicit `false`
    /// hides it.
    ///
    /// OpenAI-compatible providers additionally OVERRIDE an explicit `false`:
    /// their backend usually accepts thinking params even when models.dev
    /// tagged the model non-reasoning, so we let the user opt in. Two groups:
    ///   - `.openAI` / `.openAIResponses` ONLY when they have a `customBaseURL`
    ///     (Ollama / LM Studio / DashScope / self-hosted gateways). Official
    ///     OpenAI (no custom base) keeps the strict `?? true` rule so a model
    ///     genuinely marked `false` there still hides the toggle.
    ///   - `.openRouter` / `.xAI` always — these are inherently third-party /
    ///     aggregator OpenAI-compatible backends (no official-vs-custom split;
    ///     their `customBaseURL` is nil because they use a fixed built-in base),
    ///     and their thinking injection (`reasoning.effort` / OpenAIProvider
    ///     path) is model-id driven, not gated on `supportsReasoning`.
    /// All other provider types (anthropic, gemini, …) keep the strict rule,
    /// so a model genuinely marked `false` there still hides the toggle.
    static func entryAllowsReasoning(_ entry: ModelEntry, store: ProviderConfigStore) -> Bool {
        if entry.model.supportsReasoning != false {
            return true  // true or nil → allowed
        }
        // Explicit false: allow for OpenAI-compatible providers.
        guard let instance = store.instance(for: entry.providerInstanceId) else { return false }
        switch instance.providerType {
        case .openAI, .openAIResponses:
            // Custom/local base only — never official OpenAI.
            return instance.customBaseURL?.isEmpty == false
        case .openRouter, .xAI, .kimiCode:
            return true
        // [T-copilot-provider] Copilot's /models reports `supports.thinking`
        // per model, so an explicit false there is authoritative — it belongs
        // with the strict group, not the permissive one.
        case .anthropic, .gemini, .antigravity, .githubCopilot, .unsupported:
            return false
        }
    }

    private func checkBindingSupportsReasoning(_ binding: SessionModelBinding, store: ProviderConfigStore) -> Bool {
        switch binding.primarySource {
        case .directEntry(let id, _):
            guard let entry = store.entry(for: id) else { return false }
            return Self.entryAllowsReasoning(entry, store: store)
        case .group(let groupId, let resolvedId):
            // Check resolved model first
            if let entry = store.entry(for: resolvedId),
               Self.entryAllowsReasoning(entry, store: store) {
                return true
            }
            // Check any model in the group
            guard let group = store.group(for: groupId) else { return false }
            return group.memberEntryIds.contains { memberId in
                guard let entry = store.entry(for: memberId) else { return false }
                return Self.entryAllowsReasoning(entry, store: store)
            }
        }
    }

    /// Max output tokens of the current model (from models.dev).
    var currentModelMaxOutputTokens: Int? {
        guard let sid = sessionId,
              let binding = ProviderConfigStore.shared.binding(for: sid) else { return nil }
        let entryId: String? = switch binding.primarySource {
        case .directEntry(let id, _): id
        case .group(_, let resolvedId): resolvedId
        }
        guard let entryId, let entry = ProviderConfigStore.shared.entry(for: entryId) else { return nil }
        return entry.model.maxOutputTokens
    }

    /// Thinking mode info for the current model.
    var currentModelThinkingInfo: (supported: Bool, enabled: Bool, level: String)? {
        guard let sid = sessionId,
              let binding = ProviderConfigStore.shared.binding(for: sid) else { return nil }
        // Resolve entry: for groups, try resolved first, fallback to first member
        let entryId: String? = switch binding.primarySource {
        case .directEntry(let id, _): id
        case .group(_, let resolvedId): resolvedId
        }
        guard let entryId else { return nil }
        // If resolved entry is gone (stale UUID), try first group member
        let entry: ModelEntry?
        if let e = ProviderConfigStore.shared.entry(for: entryId) {
            entry = e
        } else if case .group(let gid, _) = binding.primarySource,
                  let group = ProviderConfigStore.shared.group(for: gid),
                  let firstId = group.memberEntryIds.first {
            entry = ProviderConfigStore.shared.entry(for: firstId)
        } else {
            entry = nil
        }
        guard let entry,
              let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId) else { return nil }
        let model = entry.model
        // Use the same allow-rule as `currentModelSupportsReasoning` so the
        // thinking info card stays consistent with the slash-menu toggle
        // availability: `nil` allowed, and custom-base OpenAI-compatible
        // providers also allowed even when explicitly `false`.
        let supported = Self.entryAllowsReasoning(entry, store: ProviderConfigStore.shared)
        let cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
        let enabled = cfg.thinkingEnabled

        let level: String
        if !enabled {
            level = "—"
        } else {
            let thinkLvl = cfg.thinkingLevel
            switch instance.providerType {
            case .anthropic:
                level = "budget: \(AnthropicAgentProvider.thinkingBudget(for: model, maxTokens: 64000, level: thinkLvl))"
            case .gemini:
                level = thinkLvl.displayName
            case .openAI, .openAIResponses, .openRouter, .xAI, .kimiCode, .githubCopilot:
                level = OpenAIAgentProvider.reasoningEffort(for: model, level: thinkLvl) ?? "—"
            case .unsupported:
                level = "—"
            case .antigravity:
                let lid = model.id.lowercased()
                if lid.contains("claude") { level = "budget: \(AnthropicAgentProvider.thinkingBudget(for: model, maxTokens: 64000, level: thinkLvl))" }
                else { level = thinkLvl.displayName }
            }
        }
        return (supported, enabled, level)
    }

    /// Average output tokens per second across this session.
    var sessionOutputTokensPerSecond: Double {
        guard sessionStreamDuration > 0 else { return 0 }
        return Double(sessionStreamOutputTokens) / sessionStreamDuration
    }
}
