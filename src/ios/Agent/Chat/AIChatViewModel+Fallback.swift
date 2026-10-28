import Foundation

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Auto-Retry + Group-Level Fallback

extension AIChatViewModel {

    // MARK: - Auto-Retry on Network Errors

    static let retryDelays = [3, 5, 10, 15, 30]

    /// [T-fallback-503-budget] Budget for a transient the SERVER answered with
    /// a 5xx (`isServerCapacityTransient`). Waiting 63s across five attempts is
    /// the right shape for a flaky link, but the wrong one for "this deployment
    /// has no workers": another group member is likely free right now, so try
    /// twice, briefly, then let the caller fall back. Only reached in a group
    /// context — a session with no group keeps the full budget, since there is
    /// nothing to fall back to.
    static let serverCapacityRetryDelays = [2, 5]

    /// [T-fallback-503-budget] Which retry budget this error gets on the
    /// current model before the group falls back.
    ///
    /// The short budget applies ONLY to a transient the server answered with a
    /// 5xx status AND only inside a group. Deliberately not applied to every
    /// `transientError`: a dropped connection, a DNS failure, a TTFB stall or
    /// an empty response carries no status code, and switching models does not
    /// fix any of them — those keep the full 3/5/10/15/30s ladder. `always`
    /// never reaches here (it falls back before auto-retry), and `rateLimited`
    /// / `providerError` are `isFallbackable` and never reach here either.
    nonisolated static func retryDelaysFor(error: Error, hasGroup: Bool) -> [Int] {
        guard hasGroup, (error as? LLMError)?.isServerCapacityTransient == true else {
            return retryDelays
        }
        return serverCapacityRetryDelays
    }

    nonisolated func retryDelaysFor(error: Error, hasGroup: Bool) -> [Int] {
        Self.retryDelaysFor(error: error, hasGroup: hasGroup)
    }

    func streamWithAutoRetry(
        provider initialProvider: any AgentProvider,
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        chatMessage: ChatMessage?,
        delays: [Int]? = nil,
        entryId: String? = nil
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        var lastError: Error?
        var currentProvider = initialProvider
        // [T-provider-live-check] The entry `currentProvider` was built for,
        // so each attempt can ask whether its provider instance still exists.
        var checkedEntryId = entryId
        let retryDelays = delays ?? Self.retryDelays
        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                // [T-stop-queued-cancel-error] A stopped turn must not start a
                // countdown: the failure it would show is most likely the
                // Stop itself, and Stop has already reset the retry counters.
                try Task.checkCancellation()
                let delay = retryDelays[attempt - 1]
                self.autoRetryAttempt = attempt
                // Show the network error on the message during countdown
                if let lastError {
                    let desc = (lastError as? LocalizedError)?.errorDescription ?? String(describing: lastError)
                    chatMessage?.error = desc
                }
                // [T-retry-log-sheet] One row per countdown, with the real
                // ladder length (this call's `retryDelays`, not the static one).
                RetryLogStore.shared.record(RetryLogEvent(
                    kind: .autoRetry,
                    attempt: attempt, maxAttempts: retryDelays.count, delaySeconds: delay,
                    reason: lastError.map(Self.retryLogReason) ?? "",
                    model: retryLogModelLabel(entryId: resolveCurrentEntry()?.id)
                ), key: retryLogKey)
                do {
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        self.autoRetryCountdown = remaining
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        try Task.checkCancellation()
                    }
                } catch {
                    // Stopped mid-countdown. Take down what the countdown put
                    // up, or the row keeps the error and a "Retry in Ns" pill
                    // that nothing will ever advance.
                    self.autoRetryAttempt = 0
                    self.autoRetryCountdown = 0
                    chatMessage?.error = nil
                    throw error
                }
                self.autoRetryCountdown = 0
                chatMessage?.error = nil

                // Re-read current model binding — user may have switched models during countdown
                if let entry = resolveCurrentEntry() {
                    let newProvider = await makeAgentProvider(for: entry)
                    if newProvider.model.id != currentProvider.model.id {
                        logger.info("🔄 Retry: model changed during countdown \(currentProvider.model.id) → \(newProvider.model.id)")
                        currentProvider = newProvider
                        checkedEntryId = entry.id
                    }
                }
            }
            do {
                var thinkLvl = sessionId.flatMap { ProviderConfigStore.shared.inferenceConfig(for: $0)?.thinkingLevel } ?? .off
                // [T-fallback-thinking-preclamp] Clamp to the CURRENT entry's
                // effective max BEFORE building the request — the session's
                // persisted level may exceed what this (possibly re-resolved)
                // model accepts, and the protocol-extension clamp only knows
                // the catalog max, not the entry-level override.
                if let entry = resolveCurrentEntry() {
                    thinkLvl = min(thinkLvl, entry.effectiveMaxThinkingLevel)
                }
                // [T-provider-live-check] This ladder re-sends on ONE provider
                // and has nowhere to move to, so a provider that was removed
                // or disabled since it was built ends the ladder with the
                // reason. It is fallbackable: callers with a group go on to
                // `streamWithGroupFallback`, which picks the next member.
                if let hit = providerProblem(forEntryId: checkedEntryId) {
                    logger.error("🔀ROUTE auto-retry: entry=\(checkedEntryId ?? "nil") \(String(describing: hit.problem)) instance=\(hit.identity.instanceId) — not sending")
                    throw LLMError.providerError(message: ProviderAvailabilityRules.message(hit.problem, identity: hit.identity))
                }
                let stream = try await currentProvider.streamAgentMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    maxTokens: maxTokens,
                    thinkingLevel: thinkLvl
                )
                if attempt > 0 {
                    RetryLogStore.shared.resolvePending(key: retryLogKey, outcome: .succeeded, kind: .autoRetry)
                }
                self.autoRetryAttempt = 0
                return stream
            } catch let error as LLMError where error.isRetryable {
                lastError = error
                continue
            } catch {
                self.autoRetryAttempt = 0
                if attempt > 0 {
                    RetryLogStore.shared.resolvePending(key: retryLogKey, outcome: .failed, kind: .autoRetry)
                }
                throw error
            }
        }
        self.autoRetryAttempt = 0
        RetryLogStore.shared.resolvePending(key: retryLogKey, outcome: .failed, kind: .autoRetry)
        throw lastError!
    }


    // MARK: - Exhausted-group error

    /// The error the three exhaustion branches of `streamWithGroupFallback`
    /// throw: the "⚠️ model (instance): reason" trail plus the last model's own
    /// words, so the user sees why every candidate was passed over.
    ///
    /// [T-compact-last-resort-removed] This used to return a sentinel asking the
    /// agent loop for one forced compaction and another lap. That layer is
    /// gone by product decision: "every candidate failed" is equally true when
    /// the link drops, and a compaction triggered by a network blip threw away
    /// the user's history to fix a failure it could not fix. Exhaustion now
    /// surfaces the real errors and nothing else.
    func groupExhaustedError(fallbackTrail: [(model: String, instance: String, reason: String)],
                             finalError: Error) -> Error {
        guard !fallbackTrail.isEmpty else { return finalError }
        let trailLines = fallbackTrail.map { "⚠️ \($0.model) (\($0.instance)): \($0.reason)" }
        let finalDesc = (finalError as? LocalizedError)?.errorDescription ?? finalError.localizedDescription
        return LLMError.providerError(message: trailLines.joined(separator: "\n") + "\n" + finalDesc)
    }

    // MARK: - Group-Level Fallback

    /// Resolve the entry and open a stream. This is the entry point for EVERY
    /// LLM request in the agent loop — it tries the current entry first and
    /// returns its stream on success. The `🔀ROUTE start → success with original
    /// entry` log on every request is therefore the normal happy path, NOT error
    /// recovery; only the `advancing`/`fallbackable` branches below are actual
    /// fallback. [diag-0800 Q1]
    ///
    /// On provider-level errors (rate limit, invalid key, provider rejection)
    /// immediately fallback to the next model in the group. On retryable errors
    /// (network, 5xx), retry with countdown on the current entry via
    /// `streamWithAutoRetry`; if retries are exhausted, also fallback to the next
    /// model in the group.
    func streamWithGroupFallback(
        provider initialProvider: any AgentProvider,
        messages: [AgentMessage],
        baseSystemPrompt: String,
        systemPrompt initialSystemPrompt: String?,
        tools: [AgentToolDefinition],
        model: LLMModel,
        lastContextTokens: Int = 0,
        chatMessage: ChatMessage?,
        activeGroupId: inout String?,
        activeEntryId: inout String?
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        var currentProvider = initialProvider
        var currentSystemPrompt = initialSystemPrompt
        var currentEntryId = activeEntryId
        var triedEntries: Set<String> = []
        if let eid = currentEntryId { triedEntries.insert(eid) }

        do {
            let _aeid = activeEntryId; let _agid = activeGroupId
            logger.info("🔀ROUTE start: activeEntryId=\(_aeid ?? "nil") activeGroupId=\(_agid ?? "nil") provider=\(initialProvider.name)")
        }

        while true {
            // [T-provider-live-check] Before EVERY request: is the provider
            // instance this request would go to still there, and enabled?
            //
            // `currentProvider` was built once and carries its credential in
            // memory, so removing or disabling the provider in Settings did
            // not stop a running task: it kept sending for as long as it ran
            // (reported 2026-09-29: "deleted every provider, the models are
            // gone, and it still works"). An unusable provider is treated as
            // one more reason to move on, through the same router and trail
            // the error paths below use; only when no member is left does it
            // fail, with the reason instead of a 401 from the network.
            //
            // Outside the `do`: the `catch` clauses below are for errors the
            // REQUEST returned and would send this to the retry ladder.
            // A stream that is already open is never interrupted - this runs
            // only when a new request is about to be made.
            if let hit = providerProblem(forEntryId: currentEntryId), let unavailableEid = currentEntryId {
                let store = ProviderConfigStore.shared
                let trailLine = (model: hit.identity.modelName, instance: hit.identity.instanceLabel,
                                 reason: ProviderAvailabilityRules.reason(hit.problem))
                let group = activeGroupId.flatMap { store.group(for: $0) }
                let candidate = group.flatMap {
                    ModelGroupRouter.nextFallback(group: $0, currentEntryId: unavailableEid, store: store)
                }
                let step = ProviderAvailabilityRules.nextStep(
                    hasGroup: group != nil,
                    candidate: candidate.flatMap { store.entry(for: $0) != nil ? $0 : nil },
                    tried: triedEntries)
                logger.error("🔀ROUTE entry=\(unavailableEid) provider \(String(describing: hit.problem)) instance=\(hit.identity.instanceId) group=\(activeGroupId ?? "nil") → \(String(describing: step))")
                switch step {
                case .failNoGroup:
                    // A conversation pinned to one model, or a group that was
                    // deleted with its only provider: nothing to move to.
                    throw LLMError.providerError(message: ProviderAvailabilityRules.message(hit.problem, identity: hit.identity))
                case .failExhausted:
                    fallbackReasons.append(trailLine)
                    if let group {
                        // The router's own list of skipped members, minus the
                        // line just written for this one.
                        let skipped = ModelGroupRouter.unavailableMembers(group: group, store: store)
                            .filter { !($0.model == trailLine.model && $0.instance == trailLine.instance) }
                        fallbackReasons.append(contentsOf: skipped)
                    }
                    throw groupExhaustedError(
                        fallbackTrail: fallbackReasons,
                        finalError: LLMError.providerError(message: AppLocalized("No usable model is left in this model group.")))
                case .advance(let nextEntryId):
                    guard let nextEntry = store.entry(for: nextEntryId) else {
                        // `candidate` was just looked up; never loop on it.
                        throw LLMError.providerError(message: ProviderAvailabilityRules.message(hit.problem, identity: hit.identity))
                    }
                    fallbackReasons.append(trailLine)
                    logger.info("🔀ROUTE provider unavailable, advancing: \(unavailableEid) → \(nextEntryId) (model=\(nextEntry.model.id) instance=\(nextEntry.providerInstanceId))")
                    triedEntries.insert(nextEntryId)
                    currentEntryId = nextEntryId
                    currentProvider = await makeAgentProvider(for: nextEntry)
                    var rebuiltPrompt = baseSystemPrompt
                    if let capFragment = nextEntry.model.capabilityPromptFragment {
                        rebuiltPrompt += "\n\n" + capFragment
                    }
                    if let behaviorFragment = nextEntry.model.agentBehaviorPromptFragment {
                        rebuiltPrompt += "\n\n" + behaviorFragment
                    }
                    currentSystemPrompt = rebuiltPrompt
                    // Check the member just chosen as well before sending.
                    continue
                }
            }
            do {
                logger.info("🔀ROUTE trying entry=\(currentEntryId ?? "nil") provider=\(currentProvider.name) tried=\(triedEntries)")
                // First attempt: call provider directly (no auto-retry) so we can
                // distinguish fallbackable errors from network errors.
                let currentModel = currentEntryId.flatMap { ProviderConfigStore.shared.entry(for: $0)?.model } ?? model
                let maxTok = dynamicMaxTokens(provider: currentProvider, model: currentModel, lastContextTokens: lastContextTokens)
                var thinkLvl = sessionId.flatMap { ProviderConfigStore.shared.inferenceConfig(for: $0)?.thinkingLevel } ?? .off
                // [T-fallback-thinking-preclamp] When falling back (e.g. a
                // Responses-API primary at xhigh → a Chat-API seed model that
                // tops out at high), the session's persisted level was passed
                // through unclamped and 400'd ("Invalid reasoning_effort:
                // xhigh"): the existing effectiveMaxThinkingLevel clamp below
                // runs only AFTER a successful request, to update the
                // persisted config. Clamp for THIS request up front; the
                // post-success write-back stays so the next turn starts right.
                if let eid = currentEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                    thinkLvl = min(thinkLvl, entry.effectiveMaxThinkingLevel)
                }
                let stream = try await currentProvider.streamAgentMessage(
                    messages: messages,
                    systemPrompt: currentSystemPrompt,
                    tools: tools,
                    maxTokens: maxTok,
                    thinkingLevel: thinkLvl
                )
                // Success — update binding if we fell back to a different entry
                let prevEntryId = activeEntryId
                if currentEntryId != activeEntryId, let currentEntryId,
                   let groupId = activeGroupId, let sid = sessionId {
                    logger.info("🔀ROUTE success with different entry: \(prevEntryId ?? "nil") → \(currentEntryId)")
                    activeEntryId = currentEntryId
                    // [T-ios-switch-model-fallback-clobber] The user picked another model
                    // while this request was open: that pick is already in the binding
                    // and is applied at the next request. Writing the fallback member
                    // here would erase it (the loop head would then see no change and
                    // the header would revert), so only this request moves to it.
                    if pendingModelSwitch {
                        logger.info("🔀ROUTE binding NOT updated — user switch pending, keeping their pick")
                        return stream
                    }
                    let binding = SessionModelBinding(
                        sessionId: sid,
                        primarySource: .group(groupId: groupId, resolvedEntryId: currentEntryId),
                        subModelSource: ProviderConfigStore.shared.binding(for: sid)?.subModelSource
                    )
                    ProviderConfigStore.shared.setBinding(binding, for: sid)
                    if let entry = ProviderConfigStore.shared.entry(for: currentEntryId) {
                        Task { await ChatStore.shared.updateSessionModelId(sid, modelId: entry.model.id) }
                    }
                    if let newEntry = ProviderConfigStore.shared.entry(for: currentEntryId) {
                        let maxLevel = newEntry.effectiveMaxThinkingLevel
                        if var cfg = ProviderConfigStore.shared.inferenceConfig(for: sid),
                           cfg.thinkingLevel > maxLevel {
                            cfg.thinkingLevel = maxLevel
                            ProviderConfigStore.shared.setInferenceConfig(cfg, for: sid)
                        }
                    }
                    logger.info("🔀ROUTE binding updated to entry \(currentEntryId)")
                } else {
                    logger.info("🔀ROUTE success with original entry=\(currentEntryId ?? "nil")")
                }
                return stream
            } catch let error as LLMError where error.isFallbackable {
                // Provider-level error (rate limit, invalid key, provider rejection):
                // immediately try next model in group without retry countdown.
                logger.error("🔀ROUTE entry=\(currentEntryId ?? "nil") fallbackable error: \(error.localizedDescription)")
                if let eid = currentEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                    let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                    fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: error.fallbackReason))
                }

                let gid = activeGroupId
                let eid = currentEntryId
                guard let groupId = gid,
                      let currentEid = eid,
                      let group = ProviderConfigStore.shared.group(for: groupId) else {
                    logger.error("🔀ROUTE no group context, re-throwing. groupId=\(gid ?? "nil") entryId=\(eid ?? "nil")")
                    throw error
                }

                let nextEntryId = ModelGroupRouter.nextFallback(
                    group: group, currentEntryId: currentEid, store: ProviderConfigStore.shared
                )
                logger.info("🔀ROUTE nextFallback returned: \(nextEntryId ?? "nil")")

                guard let nextEntryId,
                      !triedEntries.contains(nextEntryId),
                      let nextEntry = ProviderConfigStore.shared.entry(for: nextEntryId) else {
                    logger.error("🔀ROUTE exhausted: nextEntryId=\(nextEntryId ?? "nil") alreadyTried=\(nextEntryId.map { triedEntries.contains($0) } ?? false)")
                    let skipped = ModelGroupRouter.unavailableMembers(group: group, store: ProviderConfigStore.shared)
                    fallbackReasons.append(contentsOf: skipped)
                    throw groupExhaustedError(fallbackTrail: fallbackReasons, finalError: error)
                }

                logger.info("🔀ROUTE advancing: \(currentEid) → \(nextEntryId) (model=\(nextEntry.model.id) instance=\(nextEntry.providerInstanceId))")
                triedEntries.insert(nextEntryId)
                currentEntryId = nextEntryId
                currentProvider = await makeAgentProvider(for: nextEntry)
                // Rebuild system prompt for the new model's capabilities
                var rebuiltPrompt = baseSystemPrompt
                if let capFragment = nextEntry.model.capabilityPromptFragment {
                    rebuiltPrompt += "\n\n" + capFragment
                }
                if let behaviorFragment = nextEntry.model.agentBehaviorPromptFragment {
                    rebuiltPrompt += "\n\n" + behaviorFragment
                }
                currentSystemPrompt = rebuiltPrompt
                // continue loop — will try next entry immediately
            } catch {
                // Check if group uses "always" fallback strategy — if so, treat all
                // errors as immediately fallbackable (skip auto-retry on current model).
                let groupFallbackStrategy = activeGroupId
                    .flatMap { ProviderConfigStore.shared.group(for: $0) }?.fallbackStrategy ?? .limited
                if groupFallbackStrategy == .always {
                    logger.error("🔀ROUTE entry=\(currentEntryId ?? "nil") always-strategy, immediate fallback for: \(error.localizedDescription)")
                    if let eid = currentEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                        let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                        fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: (error as? LLMError)?.fallbackReason ?? AppLocalized("Error")))
                    }

                    let gid = activeGroupId
                    let eid = currentEntryId
                    guard let groupId = gid,
                          let currentEid = eid,
                          let group = ProviderConfigStore.shared.group(for: groupId) else {
                        logger.error("🔀ROUTE no group context (always), re-throwing. groupId=\(gid ?? "nil") entryId=\(eid ?? "nil")")
                        throw error
                    }

                    let nextEntryId = ModelGroupRouter.nextFallback(
                        group: group, currentEntryId: currentEid, store: ProviderConfigStore.shared
                    )
                    logger.info("🔀ROUTE always-strategy nextFallback returned: \(nextEntryId ?? "nil")")

                    guard let nextEntryId,
                          !triedEntries.contains(nextEntryId),
                          let nextEntry = ProviderConfigStore.shared.entry(for: nextEntryId) else {
                        logger.error("🔀ROUTE always-strategy exhausted: nextEntryId=\(nextEntryId ?? "nil") alreadyTried=\(nextEntryId.map { triedEntries.contains($0) } ?? false)")
                        let skipped = ModelGroupRouter.unavailableMembers(group: group, store: ProviderConfigStore.shared)
                        fallbackReasons.append(contentsOf: skipped)
                        throw groupExhaustedError(fallbackTrail: fallbackReasons, finalError: error)
                    }

                    logger.info("🔀ROUTE always-strategy advancing: \(currentEid) → \(nextEntryId) (model=\(nextEntry.model.id) instance=\(nextEntry.providerInstanceId))")
                    triedEntries.insert(nextEntryId)
                    currentEntryId = nextEntryId
                    currentProvider = await makeAgentProvider(for: nextEntry)
                    var rebuiltPrompt = baseSystemPrompt
                    if let capFragment = nextEntry.model.capabilityPromptFragment {
                        rebuiltPrompt += "\n\n" + capFragment
                    }
                    if let behaviorFragment = nextEntry.model.agentBehaviorPromptFragment {
                        rebuiltPrompt += "\n\n" + behaviorFragment
                    }
                    currentSystemPrompt = rebuiltPrompt
                    continue
                }

                // Network error, unknown error, etc.: use auto-retry with countdown
                // on the *current* entry first. If retries are exhausted, fallback to
                // the next model in the group.
                logger.error("🔀ROUTE entry=\(currentEntryId ?? "nil") non-fallbackable error, using auto-retry: \(error.localizedDescription)")
                // [T-fallback-503-budget] The short ladder is only worth taking
                // when there is somewhere to fall back TO. Gating on "has a
                // group" alone cut a single-member group (or one whose other
                // members are disabled / uncredentialed / hidden) from 63s to
                // ~7s and then threw with nowhere to go — strictly worse than
                // the full ladder it used to get. Ask the router, which applies
                // the same availability filter the fallback branch will.
                let hasFallbackTarget: Bool = {
                    guard let gid = activeGroupId, let eid = currentEntryId,
                          let group = ProviderConfigStore.shared.group(for: gid) else { return false }
                    return ModelGroupRouter.nextFallback(group: group, currentEntryId: eid, store: ProviderConfigStore.shared) != nil
                }()
                if (error as? LLMError)?.isServerCapacityTransient == true, hasFallbackTarget {
                    let code = (error as? LLMError)?.httpStatusCode ?? 0
                    logger.info("🔀ROUTE HTTP \(code) from the server — short retry budget \(Self.serverCapacityRetryDelays)s before falling back")
                }
                let retryModel = currentEntryId.flatMap { ProviderConfigStore.shared.entry(for: $0)?.model } ?? model
                do {
                    let stream = try await streamWithAutoRetry(
                        provider: currentProvider,
                        messages: messages,
                        systemPrompt: currentSystemPrompt,
                        tools: tools,
                        maxTokens: dynamicMaxTokens(provider: currentProvider, model: retryModel, lastContextTokens: lastContextTokens),
                        chatMessage: chatMessage,
                        delays: retryDelaysFor(error: error, hasGroup: hasFallbackTarget),
                        entryId: currentEntryId
                    )
                    // Auto-retry succeeded
                    let prevEntryId = activeEntryId
                    if currentEntryId != activeEntryId, let currentEntryId,
                       let groupId = activeGroupId, let sid = sessionId {
                        logger.info("🔀ROUTE auto-retry success with different entry: \(prevEntryId ?? "nil") → \(currentEntryId)")
                        activeEntryId = currentEntryId
                        // [T-ios-switch-model-fallback-clobber] See the first success
                        // path: a pending user switch owns the binding.
                        if !pendingModelSwitch {
                            let binding = SessionModelBinding(
                                sessionId: sid,
                                primarySource: .group(groupId: groupId, resolvedEntryId: currentEntryId),
                                subModelSource: ProviderConfigStore.shared.binding(for: sid)?.subModelSource
                            )
                            ProviderConfigStore.shared.setBinding(binding, for: sid)
                            if let entry = ProviderConfigStore.shared.entry(for: currentEntryId) {
                                Task { await ChatStore.shared.updateSessionModelId(sid, modelId: entry.model.id) }
                            }
                        }
                    }
                    return stream
                } catch {
                    // Auto-retry exhausted — attempt group fallback
                    logger.error("🔀ROUTE auto-retry exhausted for entry=\(currentEntryId ?? "nil"), attempting group fallback")
                    if let eid = currentEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                        let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                        fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: AppLocalized("Retries exhausted")))
                    }

                    let gid = activeGroupId
                    let eid = currentEntryId
                    guard let groupId = gid,
                          let currentEid = eid,
                          let group = ProviderConfigStore.shared.group(for: groupId) else {
                        logger.error("🔀ROUTE no group context after retry exhaustion, re-throwing. groupId=\(gid ?? "nil") entryId=\(eid ?? "nil")")
                        throw error
                    }

                    let nextEntryId = ModelGroupRouter.nextFallback(
                        group: group, currentEntryId: currentEid, store: ProviderConfigStore.shared
                    )
                    logger.info("🔀ROUTE after retry exhaustion, nextFallback returned: \(nextEntryId ?? "nil")")

                    guard let nextEntryId,
                          !triedEntries.contains(nextEntryId),
                          let nextEntry = ProviderConfigStore.shared.entry(for: nextEntryId) else {
                        logger.error("🔀ROUTE exhausted all entries after retry: nextEntryId=\(nextEntryId ?? "nil") alreadyTried=\(nextEntryId.map { triedEntries.contains($0) } ?? false)")
                        let skipped = ModelGroupRouter.unavailableMembers(group: group, store: ProviderConfigStore.shared)
                        fallbackReasons.append(contentsOf: skipped)
                        throw groupExhaustedError(fallbackTrail: fallbackReasons, finalError: error)
                    }

                    logger.info("🔀ROUTE after retry exhaustion, advancing: \(currentEid) → \(nextEntryId) (model=\(nextEntry.model.id) instance=\(nextEntry.providerInstanceId))")
                    triedEntries.insert(nextEntryId)
                    currentEntryId = nextEntryId
                    currentProvider = await makeAgentProvider(for: nextEntry)
                    var rebuiltPrompt = baseSystemPrompt
                    if let capFragment = nextEntry.model.capabilityPromptFragment {
                        rebuiltPrompt += "\n\n" + capFragment
                    }
                    if let behaviorFragment = nextEntry.model.agentBehaviorPromptFragment {
                        rebuiltPrompt += "\n\n" + behaviorFragment
                    }
                    currentSystemPrompt = rebuiltPrompt
                    // continue loop — will try next entry
                }
            }
        }
    }

    // MARK: - Group Fallback Until Content

    /// Wraps `streamWithGroupFallback` + `processStreamEvents` in a loop that
    /// keeps advancing through group entries when a model returns an empty response
    /// (HTTP 200 but no content blocks). This handles the case where one provider
    /// is silently failing (e.g. Anthropic overloaded returning empty SSE) and the
    /// group should advance to a different provider (e.g. OpenAI).
    func streamWithGroupFallbackUntilContent(
        provider: any AgentProvider,
        messages: [AgentMessage],
        baseSystemPrompt: String,
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        model: LLMModel,
        lastContextTokens: Int,
        chatMessage: ChatMessage?,
        msgIdx: Int,
        activeGroupId: inout String?,
        activeEntryId: inout String?
    ) async throws -> StreamResult {
        // Track entries we've gotten empty responses from to avoid infinite loops.
        var emptyResponseEntries: Set<String> = []

        while true {
            let fbStream = try await streamWithGroupFallback(
                provider: provider,
                messages: messages,
                baseSystemPrompt: baseSystemPrompt,
                systemPrompt: systemPrompt,
                tools: tools,
                model: model,
                lastContextTokens: lastContextTokens,
                chatMessage: chatMessage,
                activeGroupId: &activeGroupId,
                activeEntryId: &activeEntryId
            )
            let result = try await processStreamEvents(
                stream: fbStream,
                msgIdx: msgIdx,
                provider: provider
            )

            // Empty-response detection: HTTP 200 + stream finished, but no text,
            // no tool calls, no reasoning. Some providers (e.g. OpenAI gpt-5.5
            // on long contexts) emit `finish_reason=stop` with zero output, which
            // the provider maps to `.endTurn`. Treat any such "ghost" turn as
            // empty regardless of the reported stopReason — only `.maxTokens` is
            // excluded since it has its own surfaced error path. `.toolUse` is
            // implicitly excluded because toolEntries would be non-empty.
            let hasReasoning = !(result.reasoningContent ?? "").isEmpty
            let isEmpty = result.assistantText.isEmpty && result.toolEntries.isEmpty
                && !hasReasoning && !result.isStreamInterrupted
                && result.stopReason != .maxTokens

            guard isEmpty else { return result }

            // Empty response — record this entry and force-fail so the next
            // streamWithGroupFallback call advances to a different entry.
            let entryKey = activeEntryId ?? "unknown"
            logger.error("🔀ROUTE-CONTENT entry=\(entryKey) returned empty response, advancing")
            if let eid = activeEntryId, let entry = ProviderConfigStore.shared.entry(for: eid) {
                let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
                fallbackReasons.append((model: entry.model.displayName, instance: inst, reason: AppLocalized("Empty response")))
            }

            emptyResponseEntries.insert(entryKey)

            // Check if we've exhausted all entries
            if let gid = activeGroupId, let group = ProviderConfigStore.shared.group(for: gid) {
                let available = group.memberEntryIds.filter { !emptyResponseEntries.contains($0) }
                if available.isEmpty {
                    logger.error("🔀ROUTE-CONTENT all entries returned empty, giving up")
                    return result  // Return the empty result — caller will surface the error
                }
            } else {
                return result  // No group context — can't fallback further
            }

            // Clear the incomplete in-flight tail before trying the next entry.
            // [T-ios-stream-retry-text-disappear] Bound the clear to the
            // uncommitted tail (>= committedBlockCount) so text/tool blocks
            // already committed+persisted by earlier rounds of this loop stay on
            // screen — the old unbounded removeAll wiped them from the UI on a
            // mid-stream fallback even though they were still in the DB.
            await MainActor.run {
                guard msgIdx < self.messages.count else { return }
                AIChatViewModel.clearUncommittedStreamTail(self.messages[msgIdx], committedBlockCount: self.committedBlockCount)
            }

            // Throw a fallbackable error so streamWithGroupFallback skips the
            // current entry and picks the next one.
            // We catch it immediately in the next loop iteration.
            // But wait — streamWithGroupFallback creates its own triedEntries...
            // We need to make the current entry "fail" from streamWithGroupFallback's
            // perspective. The simplest way: temporarily disable the entry? No.
            // Better: just call streamWithGroupFallback again — it starts fresh with
            // triedEntries = {activeEntryId}. If the activeEntryId hasn't changed,
            // it will try the same entry again.
            //
            // Fix: update activeEntryId to force streamWithGroupFallback to start
            // from a different entry. We do this by finding the next available entry
            // ourselves and updating the binding.
            if let gid = activeGroupId, let currentEid = activeEntryId,
               let group = ProviderConfigStore.shared.group(for: gid) {
                let nextEid = ModelGroupRouter.nextFallback(
                    group: group, currentEntryId: currentEid, store: ProviderConfigStore.shared
                )
                if let nextEid, !emptyResponseEntries.contains(nextEid) {
                    logger.info("🔀ROUTE-CONTENT manually advancing: \(currentEid) → \(nextEid)")
                    activeEntryId = nextEid
                    // [T-ios-switch-model-fallback-clobber] A pending user switch owns
                    // the binding; this path has the widest window (the whole empty
                    // stream was consumed before it runs).
                    if let sid = sessionId, !pendingModelSwitch {
                        let binding = SessionModelBinding(
                            sessionId: sid,
                            primarySource: .group(groupId: gid, resolvedEntryId: nextEid),
                            subModelSource: ProviderConfigStore.shared.binding(for: sid)?.subModelSource
                        )
                        ProviderConfigStore.shared.setBinding(binding, for: sid)
                    }
                } else {
                    logger.error("🔀ROUTE-CONTENT no more untried entries")
                    return result
                }
            }
        }
    }

}

// MARK: - Provider still usable? [T-provider-live-check]

// BEGIN ProviderAvailabilityRules
/// Whether the provider instance behind a model entry can still be used, and
/// what a request about to be sent should do when it cannot. Pure: no store,
/// no view model - the callers pass in what they looked up.
enum ProviderAvailabilityRules {
    /// Who a provider object was built for, remembered when it is built.
    /// Removing a provider also removes its model entries, so by the time the
    /// check fails the store can no longer say which model or provider it was.
    struct Identity: Equatable {
        let entryId: String
        let modelName: String
        let instanceId: String
        let instanceLabel: String
    }

    enum Problem: Equatable {
        /// The provider instance is no longer in the config.
        case removed
        /// The provider instance is switched off in Settings.
        case disabled
    }

    /// Only these two make a provider unusable here. A hidden model entry is
    /// a list-display choice and does not; neither does a missing model entry
    /// on a provider that is still present and enabled.
    static func problem(instanceExists: Bool, instanceEnabled: Bool) -> Problem? {
        if !instanceExists { return .removed }
        if !instanceEnabled { return .disabled }
        return nil
    }

    enum Step: Equatable {
        /// Switch to this group member and check it too.
        case advance(to: String)
        /// No group to take another member from.
        case failNoGroup
        /// A group, but no member left that is usable and not yet tried.
        case failExhausted
    }

    /// What to do about an unusable provider. `candidate` is the router's next
    /// member (already filtered to usable ones), nil when it has none.
    /// `tried` holds every member this request has been on, so the same one is
    /// never picked twice and the walk always ends.
    static func nextStep(hasGroup: Bool, candidate: String?, tried: Set<String>) -> Step {
        guard hasGroup else { return .failNoGroup }
        guard let candidate, !tried.contains(candidate) else { return .failExhausted }
        return .advance(to: candidate)
    }

    /// The short reason on a fallback trail line.
    static func reason(_ problem: Problem) -> String {
        switch problem {
        case .removed: return AppLocalized("Provider removed")
        case .disabled: return AppLocalized("Provider disabled")
        }
    }

    /// The whole error, when there is nothing to fall back to.
    static func message(_ problem: Problem, identity: Identity) -> String {
        switch problem {
        case .removed:
            return AppLocalized("The provider \(identity.instanceLabel) was removed, so \(identity.modelName) can no longer be used. Choose another model to continue.")
        case .disabled:
            return AppLocalized("The provider \(identity.instanceLabel) is disabled, so \(identity.modelName) cannot be used. Enable it in Settings or choose another model to continue.")
        }
    }
}
// END ProviderAvailabilityRules

extension AIChatViewModel {
    /// Remember who a provider object is being built for (see `Identity`).
    func noteProviderIdentity(for entry: ModelEntry) {
        let label = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
        providerIdentities[entry.id] = ProviderAvailabilityRules.Identity(
            entryId: entry.id, modelName: entry.model.displayName,
            instanceId: entry.providerInstanceId, instanceLabel: label)
    }

    /// The reason the provider behind `entryId` can no longer be used, or nil
    /// when it can - or when nothing is known about it, which never blocks.
    ///
    /// Cost per request: one dictionary read, and `instance(for:)`, a scan of
    /// the provider instances (tens at most). No I/O; all on the main actor
    /// the caller is already on.
    func providerProblem(forEntryId entryId: String?) -> (problem: ProviderAvailabilityRules.Problem, identity: ProviderAvailabilityRules.Identity)? {
        guard let entryId else { return nil }
        let store = ProviderConfigStore.shared
        let known = providerIdentities[entryId] ?? store.entry(for: entryId).map { entry in
            ProviderAvailabilityRules.Identity(
                entryId: entry.id, modelName: entry.model.displayName,
                instanceId: entry.providerInstanceId,
                instanceLabel: store.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider)
        }
        guard let known else { return nil }
        let instance = store.instance(for: known.instanceId)
        guard let problem = ProviderAvailabilityRules.problem(
            instanceExists: instance != nil, instanceEnabled: instance?.isEnabled ?? false) else { return nil }
        return (problem, known)
    }
}

// MARK: - Retry log (one run) [T-retry-log-sheet]

// BEGIN RetryLogTypes
/// One retry-related event of an agent run, for the yellow retry marker in
/// front of "<name> is thinking…" and the details sheet it opens.
///
/// In memory only, for the current generation: the marker shows only WHILE a
/// retry is under way (an event is still pending) and the log is dropped
/// when the run ends - nothing is persisted on the message, and nothing is
/// left in the bubble afterwards. The existing persisted
/// `ChatMessage.streamInterruptCount` keeps being counted and synced as
/// before; only its "↻ N" badge is gone.
struct RetryLogEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A countdown before re-sending a request that failed to open.
        case autoRetry
        /// The stream broke off mid-reply; the turn is re-requested.
        case streamInterrupted
        /// The model group switched to another member.
        case modelSwitch
        /// An empty reply after a tool result; re-asked once with a reminder.
        case emptyResponse
    }
    enum Outcome: Equatable {
        case pending, succeeded, failed
        /// The run ended (stopped, or failed elsewhere) before this resolved.
        case unfinished
    }

    let id = UUID()
    let time = Date()
    let kind: Kind
    var attempt: Int? = nil
    var maxAttempts: Int? = nil
    var delaySeconds: Int? = nil
    var reason: String
    var model: String
    var switchedTo: String? = nil
    var outcome: Outcome = .pending
}

/// The retry events of each conversation's current run, keyed by
/// `AIChatViewModel.retryLogKey`. A run clears its key when it starts and
/// drops it when it ends (a one-line summary goes to the log).
@MainActor
final class RetryLogStore: ObservableObject {
    static let shared = RetryLogStore()
    @Published private(set) var events: [String: [RetryLogEvent]] = [:]

    func events(for key: String) -> [RetryLogEvent] { events[key] ?? [] }

    /// A retry is under way: started, and not yet recovered, failed for good
    /// or stopped. Drives the marker's visibility.
    func isRetrying(key: String) -> Bool {
        events[key]?.contains { $0.outcome == .pending } ?? false
    }

    func beginRun(key: String) {
        if events[key] != nil { events[key] = nil }
    }

    func record(_ event: RetryLogEvent, key: String) {
        events[key, default: []].append(event)
        logger.info("[RetryLog] key=\(key.prefix(8)) +\(String(describing: event.kind)) attempt=\(event.attempt.map(String.init) ?? "-")/\(event.maxAttempts.map(String.init) ?? "-") model=\(event.model) total=\(self.events[key]?.count ?? 0)")
    }

    /// Settle the run's still-pending events - all of them, or only `kind`.
    /// The auto-retry ladder settles just its own rows: a stream interruption
    /// before it may still recover through a model switch afterwards.
    func resolvePending(key: String, outcome: RetryLogEvent.Outcome, kind: RetryLogEvent.Kind? = nil) {
        func matches(_ e: RetryLogEvent) -> Bool { e.outcome == .pending && (kind == nil || e.kind == kind) }
        guard var list = events[key], list.contains(where: matches) else { return }
        for i in list.indices where matches(list[i]) { list[i].outcome = outcome }
        events[key] = list
    }

    /// The run is over (finished, failed, or stopped): settle and drop its log.
    func endRun(key: String) {
        guard let list = events[key] else { return }
        let pending = list.filter { $0.outcome == .pending }.count
        let summary = list.map { "\($0.kind)/\($0.outcome == .pending ? "unfinished" : String(describing: $0.outcome))" }
            .joined(separator: ",")
        logger.info("[RetryLog] key=\(key.prefix(8)) run ended: \(list.count) event(s), \(pending) unfinished [\(summary)]")
        events[key] = nil
    }
}
// END RetryLogTypes

extension AIChatViewModel {
    /// Which conversation a retry event belongs to; also handed to the footer
    /// that draws the marker. A draft with no session yet keys by this VM.
    var retryLogKey: String { sessionId ?? "vm-\(vmInstanceId)" }

    /// "Model (Instance)", the same shape as the fallback trail lines.
    func retryLogModelLabel(entryId: String?) -> String {
        guard let eid = entryId, let entry = ProviderConfigStore.shared.entry(for: eid) else {
            return AppLocalized("Unknown model")
        }
        let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
        return "\(entry.model.displayName) (\(inst))"
    }

    nonisolated static func retryLogReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
