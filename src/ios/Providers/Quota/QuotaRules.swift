//
//  QuotaRules.swift
//  MinisApp
//
//  [T-provider-quota] Pure rules over the quota model: percent derivation,
//  freshness, pool / model status, snapshot merging, and the refresh / probe
//  rate gates. No I/O, no UIKit, no app types — the standalone tests compile
//  this file together with QuotaModels.swift.
//

import Foundation

// MARK: - Percent (design §3 rules 3–4)

extension QuotaAmounts {
    /// `computed` utilization — only for capped pool kinds, a positive total,
    /// and a used/remaining figure in the same amounts (hence the same unit).
    func computedUtilization(kind: QuotaPool.Kind, unlimited: Bool) -> QuotaUtilization? {
        guard !unlimited else { return nil }
        switch kind {
        case .spendCap, .allowance, .usageWindow: break
        // Prepaid balances can be topped up without limit, and rate limits are
        // not consumable quota: neither gets a percent.
        case .prepaidBalance, .rateLimit: return nil
        }
        guard let total, total > 0 else { return nil }
        let used: Decimal
        if let u = self.used {
            used = u
        } else if let r = remaining {
            used = total - r
        } else {
            return nil
        }
        return QuotaUtilization(percent: used / total * 100, basis: .computed)
    }
}

extension QuotaWindow {
    func utilization(poolKind: QuotaPool.Kind, unlimited: Bool) -> QuotaUtilization? {
        guard !unlimited else { return nil }
        if poolKind == .prepaidBalance { return nil }
        if let f = reportedUsedFraction {
            return QuotaUtilization(percent: f * 100, basis: .reported)
        }
        if let f = reportedRemainingFraction {
            return QuotaUtilization(percent: (1 - f) * 100, basis: .reportedComplement)
        }
        return amounts?.computedUtilization(kind: poolKind, unlimited: unlimited)
    }
}

// MARK: - Freshness (design §8.4, adjusted to the 10-minute refresh decision)

struct QuotaFreshnessPolicy: Sendable {
    /// Active queries refresh at most every 10 minutes; anything younger than
    /// this is shown as current.
    var activeFresh: TimeInterval = 15 * 60
    /// Balances / spend caps: shown greyed with "N min ago" up to this age.
    var activeAmountsStale: TimeInterval = 6 * 3600
    /// Allowances / windows move faster; hide their numbers sooner.
    var activeWindowStale: TimeInterval = 3600

    init() {}

    func freshness(ofAmountsIn pool: QuotaPool, now: Date) -> QuotaFreshness {
        let age = now.timeIntervalSince(pool.observedAt)
        if age < activeFresh { return .fresh }
        return age <= activeAmountsStale ? .stale : .expired
    }

    func freshness(of window: QuotaWindow, now: Date) -> QuotaFreshness {
        if let reset = window.resetsAt, reset <= now { return .expired }
        let age = now.timeIntervalSince(window.observedAt)
        if age < activeFresh { return .fresh }
        return age <= activeWindowStale ? .stale : .expired
    }

    /// A pool is as fresh as its freshest part (amounts or any live window).
    func freshness(of pool: QuotaPool, now: Date) -> QuotaFreshness {
        var parts: [QuotaFreshness] = []
        if pool.amounts != nil || pool.windows.isEmpty {
            parts.append(freshness(ofAmountsIn: pool, now: now))
        }
        parts.append(contentsOf: pool.windows.map { freshness(of: $0, now: now) })
        if parts.contains(.fresh) { return .fresh }
        if parts.contains(.stale) { return .stale }
        return .expired
    }
}

// MARK: - Status (design §6.1)

enum QuotaStatusRules {
    static func status(for utilization: QuotaUtilization, thresholds: QuotaThresholds) -> QuotaStatus {
        if utilization.percent >= thresholds.exhaustedPercent { return .exhausted }
        if utilization.percent >= thresholds.lowPercent { return .low }
        return .available
    }

    static func poolStatus(_ pool: QuotaPool, now: Date,
                           freshness policy: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                           thresholds: QuotaThresholds = QuotaThresholds()) -> PoolStatus {
        let freshness = policy.freshness(of: pool, now: now)
        if freshness == .expired {
            return PoolStatus(status: .unknown, decidingWindowId: nil, utilization: nil, freshness: .expired)
        }
        if pool.verdict == .rejected {
            return PoolStatus(status: .exhausted, decidingWindowId: nil, utilization: nil, freshness: freshness)
        }

        if pool.kind == .rateLimit {
            let limited = pool.windows.first { w in
                guard policy.freshness(of: w, now: now) != .expired else { return false }
                return w.amounts?.remaining == 0 && (w.resetsAt.map { $0 > now } ?? false)
            }
            return PoolStatus(status: limited != nil ? .rateLimited : .available,
                              decidingWindowId: limited?.id, utilization: nil, freshness: freshness)
        }

        // Windows: worst window wins; windows are never averaged.
        var best: (status: QuotaStatus, window: QuotaWindow, util: QuotaUtilization?)?
        for w in pool.windows where policy.freshness(of: w, now: now) != .expired {
            let u = w.utilization(poolKind: pool.kind, unlimited: pool.unlimited)
            let s: QuotaStatus
            if let u {
                s = status(for: u, thresholds: thresholds)
            } else if let remaining = w.amounts?.remaining {
                s = remaining <= 0 ? .exhausted : .available
            } else {
                s = .unknown
            }
            if let current = best {
                let tighter = s > current.status
                    || (s == current.status && (u?.percent ?? -1) > (current.util?.percent ?? -1))
                if tighter { best = (s, w, u) }
            } else {
                best = (s, w, u)
            }
        }

        // Non-windowed amounts.
        var amountStatus: QuotaStatus = .unknown
        var amountUtil: QuotaUtilization?
        if let amounts = pool.amounts {
            switch pool.kind {
            case .prepaidBalance:
                if let remaining = amounts.remaining {
                    if remaining <= 0 {
                        amountStatus = .exhausted
                    } else if case .currency(let code) = pool.unit,
                              let low = thresholds.lowBalance[pool.subjectId]?[code.uppercased()],
                              remaining < low {
                        amountStatus = .low
                    } else {
                        amountStatus = .available
                    }
                }
            case .spendCap, .allowance, .usageWindow:
                if pool.unlimited {
                    // [T-quota-low-dot] Checked first: an unlimited cap reporting
                    // 0 "remaining" (no cap to subtract from) is not exhausted.
                    amountStatus = .available
                } else if let u = amounts.computedUtilization(kind: pool.kind, unlimited: pool.unlimited) {
                    amountUtil = u
                    amountStatus = status(for: u, thresholds: thresholds)
                } else if let remaining = amounts.remaining {
                    amountStatus = remaining <= 0 ? .exhausted : .available
                }
            case .rateLimit:
                break
            }
        }

        var result = PoolStatus(status: amountStatus, decidingWindowId: nil,
                                utilization: amountUtil, freshness: freshness)
        if let best, best.status >= result.status, best.status != .unknown {
            result = PoolStatus(status: best.status, decidingWindowId: best.window.id,
                                utilization: best.util, freshness: freshness)
        }
        if pool.verdict == .warning, result.status < .low {
            result.status = .low
        }
        return result
    }
}

// MARK: - Model key matching and effective status (design §4.4)

enum QuotaModelKey {
    /// Lower-cased slug: "GPT-5.3-Codex-Spark" and "gpt-5.3-codex-spark" match.
    static func normalize(_ s: String) -> String {
        let lowered = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// `*` glob over normalized keys.
    static func matches(pattern: String, key: String) -> Bool {
        let p = normalize(pattern), k = normalize(key)
        let parts = p.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return p == k }
        var rest = Substring(k)
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if i == parts.count - 1 {
                return rest.hasSuffix(part)
            } else {
                guard let r = rest.range(of: part) else { return false }
                rest = rest[r.upperBound...]
            }
        }
        return true
    }
}

enum QuotaModelResolver {
    /// The model's view over every pool that applies to it. Manual mappings are
    /// passed separately and merged here, at read time only.
    static func view(instanceId: String,
                     modelId: String,
                     subjectId: QuotaSubjectID?,
                     pools: [QuotaPoolKey: QuotaPool],
                     bindings: [QuotaPoolBinding],
                     manualBindings: [QuotaPoolBinding],
                     now: Date,
                     freshness: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                     thresholds: QuotaThresholds = QuotaThresholds()) -> ModelQuotaView {
        let modelKey = QuotaModelKey.normalize(modelId)
        guard let subjectId else { return .empty(instanceId: instanceId, modelKey: modelKey) }

        var chosen: [QuotaPoolKey: QuotaPoolBinding] = [:]
        func consider(_ b: QuotaPoolBinding) {
            guard let pool = pools[b.poolKey], pool.subjectId == subjectId else { return }
            let applies: Bool
            switch b.target {
            case .subject: applies = true
            case .model(let key): applies = QuotaModelKey.normalize(key) == modelKey
            case .modelFamily(let pattern): applies = QuotaModelKey.matches(pattern: pattern, key: modelKey)
            // Products are not models: code-review style pools never bind to a model.
            case .product: applies = false
            }
            guard applies else { return }
            // A pool that binds both as shared and model-specific (e.g. a manual
            // mapping onto an account pool) is reported by its most specific binding.
            if let existing = chosen[b.poolKey] {
                if specificity(b) > specificity(existing)
                    || (specificity(b) == specificity(existing) && b.evidence.rank > existing.evidence.rank) {
                    chosen[b.poolKey] = b
                }
            } else {
                chosen[b.poolKey] = b
            }
        }
        bindings.forEach(consider)
        manualBindings.forEach(consider)

        let bound: [ModelQuotaView.BoundPool] = chosen.values.compactMap { b in
            guard let pool = pools[b.poolKey] else { return nil }
            return ModelQuotaView.BoundPool(poolKey: b.poolKey, binding: b,
                                            status: QuotaStatusRules.poolStatus(pool, now: now,
                                                                                freshness: freshness,
                                                                                thresholds: thresholds))
        }.sorted { $0.poolKey.rawValue < $1.poolKey.rawValue }

        let known = bound.filter { $0.status.status != .unknown }
        let deciding = known.max { a, b in
            if a.status.status != b.status.status { return a.status.status < b.status.status }
            return (a.status.utilization?.percent ?? -1) < (b.status.utilization?.percent ?? -1)
        }
        return ModelQuotaView(
            instanceId: instanceId,
            modelKey: modelKey,
            subjectId: subjectId,
            bound: bound,
            effective: deciding?.status.status ?? .unknown,
            deciding: deciding,
            isIncomplete: !known.isEmpty && known.count < bound.count,
            hasModelSpecificPool: bound.contains { !$0.isShared })
    }

    private static func specificity(_ b: QuotaPoolBinding) -> Int {
        switch b.target {
        case .subject: return 0
        case .modelFamily: return 1
        case .product: return 1
        case .model: return 2
        }
    }
}

// MARK: - Merging snapshots (design §4.3 / §8.4)

enum QuotaMerge {
    /// Upsert a snapshot's pools by key (windows merged by id, newer wins) and
    /// its bindings by (pool, target) (higher evidence wins).
    ///
    /// `authoritative` snapshots — a complete active query — also retire pools
    /// the SAME adapter produced for this subject earlier but no longer returns
    /// (e.g. a currency the account no longer holds), so a vanished balance is
    /// not shown forever.
    static func ingest(_ snapshot: UpstreamQuotaSnapshot,
                       authoritative: Bool,
                       pools: inout [QuotaPoolKey: QuotaPool],
                       bindings: inout [QuotaPoolBinding]) {
        if authoritative {
            let returned = Set(snapshot.pools.map(\.id))
            let retired = pools.values.filter {
                $0.subjectId == snapshot.subjectId
                    && $0.provenance.adapterId == snapshot.provenance.adapterId
                    && !returned.contains($0.id)
            }.map(\.id)
            for key in retired { pools[key] = nil }
            if !retired.isEmpty {
                let gone = Set(retired)
                bindings.removeAll { gone.contains($0.poolKey) }
            }
        }

        for incoming in snapshot.pools {
            guard var existing = pools[incoming.id] else {
                pools[incoming.id] = incoming
                continue
            }
            if incoming.observedAt >= existing.observedAt {
                existing.kind = incoming.kind
                existing.unit = incoming.unit
                existing.vendorLabel = incoming.vendorLabel ?? existing.vendorLabel
                existing.amounts = incoming.amounts
                existing.verdict = incoming.verdict
                existing.unlimited = incoming.unlimited
                existing.provenance = incoming.provenance
            }
            var byId = Dictionary(existing.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for w in incoming.windows {
                if let old = byId[w.id], old.observedAt > w.observedAt { continue }
                byId[w.id] = w
            }
            existing.windows = existing.windows.compactMap { byId.removeValue(forKey: $0.id) }
                + incoming.windows.compactMap { byId.removeValue(forKey: $0.id) }
            existing.observedAt = max(existing.observedAt, incoming.observedAt)
            pools[incoming.id] = existing
        }

        for b in snapshot.bindings where b.evidence != .userManualMapping {
            if let i = bindings.firstIndex(where: { $0.poolKey == b.poolKey && $0.target == b.target }) {
                if b.evidence.rank > bindings[i].evidence.rank { bindings[i] = b }
            } else {
                bindings.append(b)
            }
        }
    }
}

// MARK: - Rate gates (product decisions §3)

struct QuotaRefreshPolicy: Sendable {
    /// Normal refresh: at most once per canonical pool set / credential.
    var normalInterval: TimeInterval = 10 * 60
    /// A user-forced refresh bypasses `normalInterval` but not this debounce.
    var forcedMinInterval: TimeInterval = 30
    /// [T-quota-attention-refresh] A provider nobody is looking at (not the
    /// current chat's model, not on a visible picker / group / quota row) is
    /// refreshed at most this often. `normalInterval` applies only while it
    /// is on screen.
    var unattendedInterval: TimeInterval = 60 * 60
    /// Failure backoff steps (5 min → 60 min). Starts at 5 min so a failing
    /// provider on screen cannot be retried in a tight loop: no automatic
    /// request for one subject is ever sooner than 5 min after the last.
    var backoff: [TimeInterval] = [300, 600, 1200, 1800, 3600]
    /// Capability probe: at most once per day per provider type + base URL.
    var capabilityProbeInterval: TimeInterval = 24 * 3600

    init() {}
}

enum QuotaRefreshDecision: Equatable, Sendable {
    case allowed
    /// Retry-After from the server — binds forced refreshes too.
    case serverCooldown(until: Date)
    /// Normal 10-minute interval not yet elapsed.
    case tooSoon(until: Date)
    /// Failure backoff not yet elapsed.
    case backoff(until: Date)
    /// Forced refresh within the debounce.
    case forcedDebounce(until: Date)
    /// Credential rejected; automatic refresh stops until the key changes or
    /// the user forces a refresh.
    case credentialRejected

    var isAllowed: Bool { self == .allowed }
}

enum QuotaRefreshGate {
    /// `attended` = the provider is on screen right now (or just came into
    /// view): the normal interval applies. Otherwise the unattended hour does
    /// too, counted from the last update by any source.
    static func decide(_ record: QuotaRefreshRecord?, now: Date, forced: Bool,
                       policy: QuotaRefreshPolicy = QuotaRefreshPolicy(),
                       attended: Bool = true) -> QuotaRefreshDecision {
        guard let record else { return .allowed }
        if let cooldown = record.serverCooldownUntil, cooldown > now {
            return .serverCooldown(until: cooldown)
        }
        if forced {
            // [T-quota-manual-refresh] Debounced only against the user's own
            // previous manual refresh. An automatic request (the one a view
            // fires when it opens, or the scheduler's) never blocks the button:
            // a tap right after opening the quota sheet must go through.
            guard let lastForced = record.lastForcedAt else { return .allowed }
            let until = lastForced.addingTimeInterval(policy.forcedMinInterval)
            return until > now ? .forcedDebounce(until: until) : .allowed
        }
        if let kind = record.error?.kind, kind == .unauthorized || kind == .forbidden {
            return .credentialRejected
        }
        if let next = record.nextAllowedAt, next > now {
            return record.error != nil ? .backoff(until: next) : .tooSoon(until: next)
        }
        if !attended {
            let last = max(record.succeededAt ?? .distantPast, record.attemptedAt)
            let until = last.addingTimeInterval(policy.unattendedInterval)
            if until > now { return .tooSoon(until: until) }
        }
        return .allowed
    }

    static func recordSuccess(_ record: QuotaRefreshRecord?, now: Date, forced: Bool,
                              policy: QuotaRefreshPolicy = QuotaRefreshPolicy()) -> QuotaRefreshRecord {
        var r = record ?? QuotaRefreshRecord(attemptedAt: now)
        r.attemptedAt = now
        r.succeededAt = now
        r.error = nil
        r.consecutiveFailures = 0
        r.serverCooldownUntil = nil
        r.nextAllowedAt = now.addingTimeInterval(policy.normalInterval)
        if forced { r.lastForcedAt = now }
        return r
    }

    /// [T-quota-claude-subscription] Fresh data from a passive observation
    /// (response headers) counts as a refresh for the scheduler: the next
    /// automatic query waits `policy.normalInterval` from it. A server cooldown
    /// and the forced-refresh debounce are left as they were, and so is a
    /// pending backoff that runs longer.
    static func recordObservation(_ record: QuotaRefreshRecord?, now: Date,
                                  policy: QuotaRefreshPolicy = QuotaRefreshPolicy()) -> QuotaRefreshRecord {
        var r = record ?? QuotaRefreshRecord(attemptedAt: .distantPast)
        r.succeededAt = now
        r.error = nil
        r.consecutiveFailures = 0
        r.nextAllowedAt = max(r.nextAllowedAt ?? .distantPast, now.addingTimeInterval(policy.normalInterval))
        return r
    }

    static func recordFailure(_ record: QuotaRefreshRecord?, error: QuotaError, now: Date, forced: Bool,
                              policy: QuotaRefreshPolicy = QuotaRefreshPolicy()) -> QuotaRefreshRecord {
        var r = record ?? QuotaRefreshRecord(attemptedAt: now)
        r.attemptedAt = now
        r.error = error
        r.consecutiveFailures += 1
        let step = policy.backoff[min(r.consecutiveFailures - 1, policy.backoff.count - 1)]
        var next = now.addingTimeInterval(step)
        if let retryAfter = error.retryAfter {
            r.serverCooldownUntil = retryAfter
            next = max(next, retryAfter)
        }
        // Never retry a failure sooner than a success would have been.
        if error.kind == .notFound || error.kind == .unsupportedResponse {
            next = max(next, now.addingTimeInterval(policy.normalInterval))
        }
        r.nextAllowedAt = next
        if forced { r.lastForcedAt = now }
        return r
    }
}

enum QuotaCapabilityGate {
    /// Whether the capability for `record.key` may be (re-)probed now.
    static func shouldProbe(_ record: QuotaCapabilityRecord?, now: Date, userRequested: Bool,
                            policy: QuotaRefreshPolicy = QuotaRefreshPolicy()) -> Bool {
        guard let record else { return true }
        // [T-quota-manual-refresh] A manual refresh always re-checks a paused
        // endpoint; repeated taps are debounced by the refresh gate's
        // `forcedDebounce` (against the previous manual tap), not here —
        // an automatic probe a few seconds earlier must not block the button.
        if userRequested { return true }
        return now.timeIntervalSince(record.probedAt) >= policy.capabilityProbeInterval
    }
}

// MARK: - Headline pool (design §9.3)

enum QuotaHeadline {
    /// The pool that best represents a subject in one short line: the worst
    /// status first; when everything is fine, the busiest window, then a prepaid
    /// balance, then a sized allowance. Rate limits never headline.
    ///
    /// [ISS-035] One exception to "worst first": an emptied money balance does
    /// not headline while the same account still holds money in another
    /// currency (see `withoutSpentCurrencyBalances`).
    static func pick(_ pools: [QuotaPool], now: Date,
                     freshness: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                     thresholds: QuotaThresholds = QuotaThresholds()) -> (pool: QuotaPool, status: PoolStatus)? {
        let all = pools.filter { $0.kind != .rateLimit }.map {
            ($0, QuotaStatusRules.poolStatus($0, now: now, freshness: freshness, thresholds: thresholds))
        }.filter { $0.1.status != .unknown }
        let rated = withoutSpentCurrencyBalances(all, pool: { $0.0 }, status: { $0.1.status })
        guard !rated.isEmpty else { return nil }
        func rank(_ p: QuotaPool) -> Int {
            switch p.kind {
            case .usageWindow: return 3
            case .prepaidBalance: return 2
            case .spendCap, .allowance: return 1
            case .rateLimit: return 0
            }
        }
        return rated.max { a, b in
            if a.1.status != b.1.status { return a.1.status < b.1.status }
            let ua = a.1.utilization?.percent ?? -1, ub = b.1.utilization?.percent ?? -1
            if ua != ub { return ua < ub }
            if rank(a.0) != rank(b.0) { return rank(a.0) < rank(b.0) }
            return a.0.id.rawValue > b.0.id.rawValue
        }
    }

    /// A prepaid balance held as money (`.currency`), as opposed to credits or
    /// relay quota units.
    static func isCurrencyBalance(_ pool: QuotaPool) -> Bool {
        guard pool.kind == .prepaidBalance, case .currency = pool.unit else { return false }
        return true
    }

    /// [ISS-035] Removes the emptied money balances from a one-line choice when
    /// another money balance of the same set still has funds (available or
    /// low).
    ///
    /// Why: DeepSeek keeps one balance per currency, so an account with
    /// CN¥7.62 and US$0.00 has an exhausted USD pool next to an available CNY
    /// pool. Under "worst first", US$0.00 headlined and read as "no money
    /// left", while the account-level dot (`QuotaLevelRules.level`, which
    /// judges money balances together) correctly said otherwise.
    ///
    /// Scope, kept deliberately narrow:
    /// - only `.prepaidBalance` pools in a currency; credits, spend caps,
    ///   allowances and windows keep "worst first", so an exhausted window
    ///   still headlines over any balance;
    /// - a balance exhausted because the vendor rejected the account
    ///   (`verdict == .rejected`) is never dropped: that is not a zero amount
    ///   but a refusal, and it must stay visible;
    /// - when every money balance is exhausted, nothing is dropped and the
    ///   headline still says so.
    /// Among several funded currencies the caller's usual ordering decides
    /// (no exchange rate is applied here); the detail sheet lists them all.
    static func withoutSpentCurrencyBalances<T>(_ items: [T], pool: (T) -> QuotaPool?,
                                                status: (T) -> QuotaStatus) -> [T] {
        func spent(_ item: T) -> Bool {
            guard let p = pool(item), isCurrencyBalance(p) else { return false }
            return status(item) == .exhausted && p.verdict != .rejected
        }
        let funded = items.contains { item in
            guard let p = pool(item), isCurrencyBalance(p) else { return false }
            return status(item) == .available || status(item) == .low
        }
        return funded ? items.filter { !spent($0) } : items
    }
}
