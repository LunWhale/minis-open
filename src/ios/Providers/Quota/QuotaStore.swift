//
//  QuotaStore.swift
//  MinisApp
//
//  [T-provider-quota] Owns upstream quota state: resolves provider instances
//  to quota subjects, runs adapter fetches under the refresh / capability
//  gates with per-subject single flight, merges snapshots, persists a
//  secret-free cache locally, and schedules foreground refreshes.
//
//  Rate rules (product decisions §3):
//  - [T-quota-attention-refresh] attention decides the interval. A provider
//    is WATCHED while a view showing its quota is on screen: the chat's nav
//    bar dot (the current model), a picker section header or Model Group
//    member pill scrolled into view, the provider page, the quota sheet.
//    Coming into view refreshes it if due, and while watched it keeps the
//    normal interval below. Everything else is refreshed at most once an
//    hour;
//  - normal refresh: at most every 10 minutes per subject (one subject =
//    one credential = one canonical pool set; every currency / window of it
//    comes back from the same single request);
//  - no automatic request for a subject is ever sooner than 5 minutes after
//    the previous one, failures included (backoff starts at 5 min);
//  - forced refresh (the user's button) bypasses the 10-minute cache but not
//    Retry-After, the single-flight lock, or a 30 s debounce;
//  - capability: a failed probe (404 / unreadable answer) blocks queries for
//    that provider type + base URL for 24 h, unless the user re-checks;
//  - foreground only: on becoming active (after a 3 s settle) and then on a
//    60 s tick, every eligible subject that is due is refreshed — due by the
//    watched interval or the unattended hour. Nothing runs in the background.
//
//  Never logs or persists a credential, an Authorization header or a raw
//  response body.
//

import Combine
import Foundation
import UIKit

private let logger = AppLogger(category: "Quota")

/// What the detail section shows for one instance.
enum QuotaInstanceDisplay: Equatable {
    /// Hidden: disabled instance or no credential (the credential section
    /// above already asks for one).
    case hidden
    case unsupported(QuotaSubject.UnsupportedReason)
    case loading
    /// Queried; upstream reported no pool for this credential.
    case empty(QuotaSubjectID)
    /// Queried and failed, nothing cached to show.
    case failed(QuotaError)
    case pools(QuotaSubjectID)
}

enum QuotaRefreshResult: Equatable {
    case refreshed
    case failed(QuotaError)
    case blocked(QuotaRefreshDecision)
    case unsupported
    case notConfigured(QuotaSubject.NotConfiguredReason)
    case capabilityFailed
}

@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()

    /// Bumped on every visible change; views observe the store as a whole.
    @Published private(set) var revision: Int = 0
    /// Instances whose subject is being fetched right now.
    @Published private(set) var refreshingInstanceIds: Set<String> = []

    private(set) var subjects: [QuotaSubjectID: QuotaSubject] = [:]
    private(set) var pools: [QuotaPoolKey: QuotaPool] = [:]
    private(set) var bindings: [QuotaPoolBinding] = []
    private(set) var capabilities: [QuotaCapabilityKey: QuotaCapabilityRecord] = [:]
    private var summaries: [String: QuotaSnapshotSummary] = [:]
    private var instanceSubjects: [String: QuotaSubjectID] = [:]
    /// Not persisted: why the last refresh of an instance did not reach a subject.
    private var instanceNotes: [String: QuotaSubject.NotConfiguredReason] = [:]
    /// [ISS-031] Adapters whose response shape was already logged this launch.
    private var loggedResponseShapes: Set<String> = []
    private var lastViewed: [String: Date] = [:]
    /// [T-quota-attention-refresh] Instance id → number of on-screen views
    /// showing its quota right now (`beginWatching` / `endWatching`).
    private var watchCounts: [String: Int] = [:]

    private let singleFlight = QuotaSingleFlight<QuotaSubjectID, QuotaRefreshResult>()
    /// Diagnostic: instances whose first observed header set was logged verbatim.
    private var loggedObservationInstances: Set<String> = []
    let freshnessPolicy = QuotaFreshnessPolicy()
    let thresholds = QuotaThresholds()

    private var loaded = false
    private var started = false
    private var persistTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var authCancellable: AnyCancellable?

    static let foregroundTick: TimeInterval = 60
    static let postForegroundSettle: TimeInterval = 3
    /// Credential change: re-resolve instances seen within this window.
    static let recentUseWindow: TimeInterval = 30 * 60

    private init() {}

    // MARK: - Reads

    func subjectId(for instanceId: String) -> QuotaSubjectID? {
        ensureLoaded()
        return instanceSubjects[instanceId]
    }

    func subject(_ id: QuotaSubjectID) -> QuotaSubject? { subjects[id] }

    /// Each canonical pool of a subject exactly once, stable order.
    func pools(of subject: QuotaSubjectID) -> [QuotaPool] {
        pools.values.filter { $0.subjectId == subject }.sorted { a, b in
            if a.kind != b.kind { return Self.kindOrder(a.kind) < Self.kindOrder(b.kind) }
            return a.id.rawValue < b.id.rawValue
        }
    }

    func bindings(of subject: QuotaSubjectID) -> [QuotaPoolBinding] {
        bindings.filter { pools[$0.poolKey]?.subjectId == subject }
    }

    func isRefreshing(_ instanceId: String) -> Bool { refreshingInstanceIds.contains(instanceId) }

    /// Other instances resolving to the same account (for the "don't add them up" note).
    func sharingInstanceIds(for instanceId: String) -> [String] {
        guard let sid = instanceSubjects[instanceId], let s = subjects[sid] else { return [] }
        return s.instanceIds.filter { $0 != instanceId }.sorted()
    }

    func display(for instance: ProviderInstance) -> QuotaInstanceDisplay {
        ensureLoaded()
        let d = Self.descriptor(for: instance)
        let cap = QuotaAdapterRegistry.adapter(for: d).capability(for: d)
        guard cap.active else { return .unsupported(cap.unsupportedReason ?? .providerTypeUnsupported) }
        if !instance.isEnabled { return .hidden }
        if instanceNotes[instance.id] != nil { return .hidden }
        if let rec = capabilities[d.capabilityKey], rec.status == .failed,
           instanceSubjects[instance.id].flatMap({ pools(of: $0).isEmpty ? nil : $0 }) == nil {
            return .unsupported(.capabilityProbeFailed)
        }
        guard let sid = instanceSubjects[instance.id], let subject = subjects[sid] else {
            return .loading
        }
        if !pools(of: sid).isEmpty { return .pools(sid) }
        if isRefreshing(instance.id) || subject.lastRefresh == nil { return .loading }
        if let err = subject.lastRefresh?.error { return .failed(err) }
        return .empty(sid)
    }

    /// [T-quota-relay-probe] What the last probe of this relay found, for the
    /// details: "Sub2API · /v1/usage", or why nothing was found. nil for
    /// non-relays and relays not probed yet.
    func relayDetection(for instance: ProviderInstance) -> (text: String, found: Bool, at: Date)? {
        ensureLoaded()
        let d = Self.descriptor(for: instance)
        guard QuotaVendorDetector.vendor(for: d) == .customRelay, let rec = capabilities[d.capabilityKey] else { return nil }
        switch rec.status {
        case .supported:
            guard let kind = RelayKind.from(adapterId: rec.adapterId) else { return nil }
            return ("\(kind.displayName) · \(kind.path)", true, rec.probedAt)
        case .failed, .unsupported:
            return (rec.detail ?? "", false, rec.probedAt)
        }
    }

    func poolStatus(_ pool: QuotaPool, now: Date = Date()) -> PoolStatus {
        QuotaStatusRules.poolStatus(pool, now: now, freshness: freshnessPolicy, thresholds: thresholds)
    }

    /// The model's view over every pool that applies to it.
    /// [T-quota-no-manual-mapping] Upstream bindings only: the user-declared
    /// manual mapping was removed from the product (2026-09-27).
    func modelView(instanceId: String, modelId: String, now: Date = Date()) -> ModelQuotaView {
        ensureLoaded()
        return QuotaModelResolver.view(instanceId: instanceId, modelId: modelId, subjectId: instanceSubjects[instanceId],
                                       pools: pools, bindings: bindings, manualBindings: [], now: now,
                                       freshness: freshnessPolicy, thresholds: thresholds)
    }

    /// [T-quota-tag-level] The account's level over ALL its pools, for the picker
    /// header tag (yellow = low, red = nothing left).
    func subjectLevel(instanceId: String, now: Date = Date()) -> QuotaLevel {
        ensureLoaded()
        guard let sid = instanceSubjects[instanceId] else { return .normal }
        return QuotaLevelRules.level(pools(of: sid).map { (poolStatus($0, now: now), $0) })
    }

    /// The pool that best represents the instance's account in one short line.
    func headline(instanceId: String, now: Date = Date()) -> (pool: QuotaPool, status: PoolStatus)? {
        ensureLoaded()
        guard let sid = instanceSubjects[instanceId] else { return nil }
        return QuotaHeadline.pick(pools(of: sid), now: now, freshness: freshnessPolicy, thresholds: thresholds)
    }

    // MARK: - Refresh

    func noteViewed(instanceId: String) {
        lastViewed[instanceId] = Date()
    }

    /// [T-quota-attention-refresh] A view showing this instance's quota came on
    /// screen: from now on it refreshes on the watched interval, and right
    /// away when due. Balanced by `endWatching` (see `quotaWatch`).
    func beginWatching(instanceId: String, reason: String) {
        watchCounts[instanceId, default: 0] += 1
        refreshIfDue(instanceId: instanceId, reason: reason)
    }

    func endWatching(instanceId: String) {
        guard let n = watchCounts[instanceId] else { return }
        if n <= 1 { watchCounts[instanceId] = nil } else { watchCounts[instanceId] = n - 1 }
        noteViewed(instanceId: instanceId)
    }

    func isWatched(_ instanceId: String) -> Bool { watchCounts[instanceId] != nil }

    /// Picker appearance: mark the instance as in use and refresh only when its
    /// subject is due. A subject known to be within its gate is skipped
    /// without a Keychain read, so opening the picker costs nothing when the
    /// data is current.
    func refreshIfDue(instanceId: String, reason: String) {
        ensureLoaded()
        noteViewed(instanceId: instanceId)
        guard let instance = ProviderConfigStore.shared.instance(for: instanceId), instance.isEnabled else { return }
        let d = Self.descriptor(for: instance)
        guard QuotaAdapterRegistry.adapter(for: d).capability(for: d).active else { return }
        if let sid = instanceSubjects[instanceId],
           !QuotaRefreshGate.decide(subjects[sid]?.lastRefresh, now: Date(), forced: false,
                                    policy: Self.policy(for: sid.vendor)).isAllowed {
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.refresh(instanceId: instanceId, forced: false, reason: reason)
        }
    }

    /// Refresh the instance's subject. `forced` = the user's refresh / re-check
    /// button: bypasses the 10-minute cache and the daily capability limit,
    /// never Retry-After, the in-flight lock, or the 30 s debounce.
    /// `attended == false` (the scheduler, for a provider not on screen) adds
    /// the unattended hour to the gate.
    @discardableResult
    func refresh(instanceId: String, forced: Bool, reason: String, attended: Bool = true) async -> QuotaRefreshResult {
        ensureLoaded()
        guard let instance = ProviderConfigStore.shared.instance(for: instanceId) else {
            detach(instanceId: instanceId)
            return .notConfigured(.instanceDisabled)
        }
        let d = Self.descriptor(for: instance)
        let adapter = QuotaAdapterRegistry.adapter(for: d)
        guard adapter.capability(for: d).active else { return .unsupported }
        guard instance.isEnabled else { return note(instanceId, .instanceDisabled) }

        // [T-quota-claude-subscription] An OAuth subscription is keyed by its
        // instance: the access token rotates on every refresh, so hashing it
        // would move the data to a new subject each time. Its token is only
        // fetched (possibly refreshed) once the gates below allow a request.
        let subjectId: QuotaSubjectID
        let credentialSource: @MainActor () async -> String?
        if adapter.vendor == .claudeSubscription {
            subjectId = Self.subscriptionSubject(vendor: adapter.vendor, instanceId: instanceId)
            attach(instanceId: instanceId, to: subjectId, maskedKey: "OAuth")
            credentialSource = { try? await ClaudeOAuthManager.shared.validAccessToken(instanceId: instanceId) }
        } else if adapter.vendor == .codexSubscription {
            subjectId = Self.subscriptionSubject(vendor: adapter.vendor, instanceId: instanceId)
            attach(instanceId: instanceId, to: subjectId, maskedKey: "OAuth")
            credentialSource = { try? await CodexOAuthManager.shared.validAccessToken(instanceId: instanceId) }
        } else if adapter.vendor == .kimiCode, d.isOAuth {
            // [ISS-031] Same token the Kimi Code chat requests use
            // (LLMProviderFactory.makeKimiProvider): a pasted bearer token
            // first, else the device-flow token (refreshed when due). Keyed by
            // instance: the device-flow token rotates.
            subjectId = Self.subscriptionSubject(vendor: adapter.vendor, instanceId: instanceId)
            attach(instanceId: instanceId, to: subjectId, maskedKey: "OAuth")
            credentialSource = {
                if let manual = ProviderKeychainHelper.loadOAuthString(instanceId: instanceId, account: "manual-oauth-token")?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
                    return manual
                }
                return try? await KimiOAuthManager.shared.validAccessToken(instanceId: instanceId)
            }
        } else {
            guard let credential = Self.credential(for: instance) else { return note(instanceId, .missingCredential) }
            subjectId = QuotaSubjectID(vendor: adapter.vendor, accountKey: QuotaAccountKey.derive(from: credential))
            attach(instanceId: instanceId, to: subjectId, maskedKey: QuotaAccountKey.mask(credential))
            credentialSource = { credential }
        }
        if instanceNotes.removeValue(forKey: instanceId) != nil { changed(persist: false) }
        let policy = Self.policy(for: subjectId.vendor)

        let now = Date()
        let capKey = d.capabilityKey
        if let rec = capabilities[capKey], rec.status == .failed,
           !QuotaCapabilityGate.shouldProbe(rec, now: now, userRequested: forced, policy: policy) {
            logger.info("[Quota] skip \(subjectId) — capability \(capKey) failed at \(rec.probedAt) (\(rec.detail ?? "-")), next probe after 24h or a user re-check")
            return .capabilityFailed
        }
        if singleFlight.isRunning(subjectId) {
            logger.info("[Quota] join in-flight fetch \(subjectId) reason=\(reason)")
        } else {
            let decision = QuotaRefreshGate.decide(subjects[subjectId]?.lastRefresh, now: now, forced: forced,
                                                   policy: policy, attended: attended)
            guard decision.isAllowed else { return .blocked(decision) }
        }
        return await singleFlight.run(subjectId) { [weak self] in
            guard let self else { return .unsupported }
            guard let credential = await credentialSource() else {
                logger.warning("[Quota] \(subjectId): no usable credential (OAuth signed out or refresh failed)")
                return self.note(instanceId, .missingCredential)
            }
            return await self.performFetch(adapter: adapter, descriptor: d, subjectId: subjectId,
                                           credential: credential, forced: forced, reason: reason)
        }
    }

    private func performFetch(adapter: any ProviderQuotaAdapter, descriptor d: QuotaInstanceDescriptor,
                              subjectId: QuotaSubjectID, credential: String, forced: Bool,
                              reason: String) async -> QuotaRefreshResult {
        let instanceIds = subjects[subjectId]?.instanceIds ?? [d.instanceId]
        refreshingInstanceIds.formUnion(instanceIds)
        defer { refreshingInstanceIds.subtract(instanceIds) }
        let started = Date()
        logger.info("[Quota] 🔄 fetch \(adapter.adapterId) subject=\(subjectId) forced=\(forced) reason=\(reason)")

        var ctx = QuotaFetchContext(descriptor: d, subjectId: subjectId, credential: credential,
                                    transport: QuotaURLSessionTransport.shared, now: started)
        switch adapter.vendor {
        case .claudeSubscription:
            // The usage endpoint answers the official CLI; send its fingerprint.
            ctx.extraHeaders = ClaudeCLIMimicry.headers
        case .codexSubscription:
            // Same identity the Codex chat requests send (OpenAIProvider).
            var h = ["User-Agent": "codex_cli_rs/\(OpenAIProvider.codexClientVersion) (iOS; arm64)",
                     "Originator": "codex_cli_rs"]
            if let account = CodexOAuthManager.shared.accountId(instanceId: d.instanceId) {
                h["ChatGPT-Account-Id"] = account
            }
            ctx.extraHeaders = h
        case .customRelay:
            // [T-quota-relay-probe] Reuse the type found by a probe less than a
            // day old; otherwise (none yet, stale, or last probe failed) probe.
            if let rec = capabilities[d.capabilityKey], rec.status == .supported,
               let kind = RelayKind.from(adapterId: rec.adapterId),
               !QuotaCapabilityGate.shouldProbe(rec, now: started, userRequested: false,
                                                policy: Self.policy(for: .customRelay)) {
                ctx.relayKindHint = kind
            }
        default:
            break
        }
        #if DEBUG
        if let override = Self.debugEndpointOverride(instanceId: d.instanceId) {
            ctx.endpointOverride = override
            logger.warning("[Quota] ⚠️ DEBUG endpoint override for \(adapter.adapterId) instance=\(d.instanceId) → \(override.absoluteString)")
        }
        #endif
        let outcome: QuotaFetchOutcome
        do {
            outcome = try await adapter.fetch(ctx)
        } catch {
            let fe = (error as? QuotaFetchError)
                ?? QuotaFetchError(kind: .network, detail: "\((error as NSError).domain) \((error as NSError).code)")
            return recordFailure(fe, adapterId: adapter.adapterId, subjectId: subjectId,
                                 capKey: d.capabilityKey, forced: forced)
        }

        let now = Date()
        QuotaMerge.ingest(outcome.snapshot, authoritative: outcome.isComplete, pools: &pools, bindings: &bindings)
        var subject = subjects[subjectId] ?? Self.newSubject(subjectId)
        subject.lastRefresh = QuotaRefreshGate.recordSuccess(subject.lastRefresh, now: now, forced: forced,
                                                             policy: Self.policy(for: subjectId.vendor))
        subject.state = .available
        if let plan = outcome.snapshot.plan { subject.plan = plan }
        subjects[subjectId] = subject
        summaries["\(subjectId)|\(outcome.snapshot.provenance.source.rawValue)"] = QuotaSnapshotSummary(
            subjectId: subjectId, source: outcome.snapshot.provenance.source, adapterId: adapter.adapterId,
            capturedAt: outcome.snapshot.capturedAt, poolKeys: outcome.snapshot.pools.map(\.id))
        let capKey = d.capabilityKey
        let rec = capabilities[capKey]
        let probedRelay = outcome.relayKind != nil && ctx.relayKindHint == nil
        if rec?.status != .supported || probedRelay
            || QuotaCapabilityGate.shouldProbe(rec, now: now, userRequested: false, policy: Self.policy(for: subjectId.vendor)) {
            capabilities[capKey] = QuotaCapabilityRecord(
                key: capKey, adapterId: outcome.relayKind?.adapterId ?? adapter.adapterId, status: .supported,
                source: outcome.snapshot.provenance.source, confidence: outcome.snapshot.provenance.confidence,
                probedAt: now,
                detail: outcome.relayKind.map { "\($0.displayName) · \($0.path)" })
            if let kind = outcome.relayKind, probedRelay {
                logger.info("[Quota] 🔎 relay \(capKey) detected as \(kind.displayName) (\(kind.path))")
            }
        }
        for e in outcome.partialErrors {
            logger.warning("[Quota] partial failure \(subjectId): \(e.kind.rawValue) \(e.detail)")
        }
        // [ISS-031] Field names + types only (no values), once per adapter per
        // launch: lets an installed build confirm an unverified response shape.
        if let shape = outcome.responseShape, !loggedResponseShapes.contains(adapter.adapterId) {
            loggedResponseShapes.insert(adapter.adapterId)
            logger.info("[Quota] 🧩 \(adapter.adapterId) response shape: \(shape)")
        }
        logger.info("[Quota] ✅ \(subjectId) pools=\(outcome.snapshot.pools.count) complete=\(outcome.isComplete) in \(String(format: "%.2f", now.timeIntervalSince(started)))s")
        changed()
        return .refreshed
    }

    private func recordFailure(_ fe: QuotaFetchError, adapterId: String, subjectId: QuotaSubjectID,
                               capKey: QuotaCapabilityKey, forced: Bool) -> QuotaRefreshResult {
        let now = Date()
        let err = fe.persisted(at: now)
        var subject = subjects[subjectId] ?? Self.newSubject(subjectId)
        subject.lastRefresh = QuotaRefreshGate.recordFailure(subject.lastRefresh, error: err, now: now,
                                                             forced: forced, policy: Self.policy(for: subjectId.vendor))
        subject.state = pools(of: subjectId).isEmpty ? .failed : .available
        subjects[subjectId] = subject
        // An endpoint that does not exist or answers something unreadable is a
        // capability failure for this provider type + base URL: stop until the
        // next daily probe or a user re-check. Auth failures are the key's
        // problem, not the endpoint's.
        if QuotaCapabilityRules.failureDisablesEndpoint(fe.kind, vendor: subjectId.vendor) {
            capabilities[capKey] = QuotaCapabilityRecord(key: capKey, adapterId: adapterId, status: .failed,
                                                         source: nil, confidence: nil, probedAt: now,
                                                         detail: fe.httpStatus.map { "HTTP \($0) · \(fe.detail)" } ?? fe.detail)
        }
        logger.warning("[Quota] ❌ \(subjectId) \(fe.kind.rawValue) \(fe.detail) next=\(subject.lastRefresh?.nextAllowedAt.map { "\($0)" } ?? "-") failures=\(subject.lastRefresh?.consecutiveFailures ?? 0)")
        changed()
        return .failed(err)
    }

    private func note(_ instanceId: String, _ reason: QuotaSubject.NotConfiguredReason) -> QuotaRefreshResult {
        if instanceNotes[instanceId] != reason {
            instanceNotes[instanceId] = reason
            changed(persist: false)
        }
        return .notConfigured(reason)
    }

    private static func newSubject(_ id: QuotaSubjectID) -> QuotaSubject {
        QuotaSubject(id: id, kind: .credential, parent: nil, instanceIds: [], accountLabel: nil, plan: nil,
                     state: .available, lastRefresh: nil)
    }

    /// Point the instance at `subjectId`; when its key changed, leave the old
    /// subject and drop it (with its pools) once no instance uses it.
    private func attach(instanceId: String, to subjectId: QuotaSubjectID, maskedKey: String) {
        var changedAny = false
        if let old = instanceSubjects[instanceId], old != subjectId {
            removeInstance(instanceId, from: old)
            changedAny = true
        }
        var subject = subjects[subjectId] ?? Self.newSubject(subjectId)
        if !subject.instanceIds.contains(instanceId) || subject.accountLabel != maskedKey {
            subject.instanceIds.insert(instanceId)
            subject.accountLabel = maskedKey
            changedAny = true
        }
        subjects[subjectId] = subject
        if instanceSubjects[instanceId] != subjectId {
            instanceSubjects[instanceId] = subjectId
            changedAny = true
        }
        if changedAny { changed() }
    }

    private func detach(instanceId: String) {
        guard let old = instanceSubjects.removeValue(forKey: instanceId) else { return }
        removeInstance(instanceId, from: old)
        changed()
    }

    private func removeInstance(_ instanceId: String, from sid: QuotaSubjectID) {
        guard var s = subjects[sid] else { return }
        s.instanceIds.remove(instanceId)
        if s.instanceIds.isEmpty {
            subjects[sid] = nil
            let gone = Set(pools.values.filter { $0.subjectId == sid }.map(\.id))
            for k in gone { pools[k] = nil }
            bindings.removeAll { gone.contains($0.poolKey) }
            summaries = summaries.filter { $0.value.subjectId != sid }
            logger.info("[Quota] dropped subject \(sid) (no instance left)")
        } else {
            subjects[sid] = s
        }
    }

    /// Instances deleted since the cache was written leave nothing behind.
    private func pruneDeletedInstances() {
        let live = Set(ProviderConfigStore.shared.instances.map(\.id))
        for id in instanceSubjects.keys where !live.contains(id) { detach(instanceId: id) }
    }

    // MARK: - Passive observation (response headers)

    /// [T-quota-claude-subscription] Rate policy per vendor. A Claude
    /// subscription refreshes on a 5-minute window measured from the last update
    /// by EITHER source: a reply's headers or an active query. Everyone else
    /// keeps the 10-minute query interval.
    static func policy(for vendor: QuotaVendor) -> QuotaRefreshPolicy {
        QuotaRefreshPolicy.forVendor(vendor)
    }

    static func subscriptionSubject(vendor: QuotaVendor, instanceId: String) -> QuotaSubjectID {
        QuotaSubjectID(vendor: vendor, accountKey: "instance:\(instanceId)")
    }

    /// A reply from an OAuth Claude instance carried `anthropic-ratelimit-unified-*`
    /// headers: merge them in as the same pools / windows the active query
    /// writes, and count them as a refresh so the scheduler does not query
    /// again within the 5-minute window.
    /// Also used for Codex replies ([T-quota-codex-subscription]): `vendor`
    /// says which parser applies.
    func observeSubscriptionHeaders(instanceId: String, vendor: QuotaVendor, headers: [String: String]) {
        ensureLoaded()
        guard let instance = ProviderConfigStore.shared.instance(for: instanceId), instance.isEnabled,
              QuotaVendorDetector.vendor(for: Self.descriptor(for: instance)) == vendor else { return }
        if loggedObservationInstances.insert(instanceId).inserted {
            // Header names and values only (usage fractions, reset times, status);
            // no credential is ever part of these response headers.
            let line = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            logger.info("[Quota][SubscriptionHeaders] first observation vendor=\(vendor.rawValue) instance=\(instanceId.prefix(8)) \(line)")
        }
        let subjectId = Self.subscriptionSubject(vendor: vendor, instanceId: instanceId)
        let now = Date()
        let parsed: UpstreamQuotaSnapshot?
        switch vendor {
        case .claudeSubscription:
            parsed = ClaudeSubscriptionQuotaAdapter.parseHeaders(headers, subjectId: subjectId, now: now)
        case .codexSubscription:
            parsed = CodexSubscriptionQuotaAdapter.parseHeaders(headers, subjectId: subjectId, now: now)
        default:
            parsed = nil
        }
        guard let snapshot = parsed else { return }
        attach(instanceId: instanceId, to: subjectId, maskedKey: "OAuth")
        QuotaMerge.ingest(snapshot, authoritative: false, pools: &pools, bindings: &bindings)
        var subject = subjects[subjectId] ?? Self.newSubject(subjectId)
        subject.lastRefresh = QuotaRefreshGate.recordObservation(subject.lastRefresh, now: now,
                                                                 policy: Self.policy(for: vendor))
        subject.state = .available
        subjects[subjectId] = subject
        summaries["\(subjectId)|\(snapshot.provenance.source.rawValue)"] = QuotaSnapshotSummary(
            subjectId: subjectId, source: snapshot.provenance.source, adapterId: snapshot.provenance.adapterId,
            capturedAt: now, poolKeys: snapshot.pools.map(\.id))
        changed()
    }

    // MARK: - Scheduling

    /// Called once at launch. Refreshes run only while the app is active.
    func start() {
        guard !started else { return }
        started = true
        ensureLoaded()
        pruneDeletedInstances()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            Task { @MainActor in self?.becameActive() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resignedActive() }
        })
        // A key added, changed or removed: forget "no credential" notes so the
        // section can reappear, and re-resolve instances the user is looking at
        // (a new key is a new subject, so its gate is open).
        authCancellable = ProviderConfigStore.shared.$authRevision.dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.credentialsChanged() }
            }
        if UIApplication.shared.applicationState == .active { becameActive() }
        logger.info("[Quota] started — subjects=\(self.subjects.count) pools=\(self.pools.count)")
    }

    private func becameActive() {
        foregroundTask?.cancel()
        foregroundTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.postForegroundSettle * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshDue(reason: "didBecomeActive")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.foregroundTick * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.refreshDue(reason: "tick")
            }
        }
    }

    private func credentialsChanged() {
        instanceNotes.removeAll()
        changed(persist: false)
        let now = Date()
        let recent = lastViewed.filter { now.timeIntervalSince($0.value) < Self.recentUseWindow }.map(\.key)
        guard !recent.isEmpty else { return }
        Task { @MainActor [weak self] in
            for id in recent {
                _ = await self?.refresh(instanceId: id, forced: false, reason: "credentialChanged")
            }
        }
    }

    private func resignedActive() {
        foregroundTask?.cancel()
        foregroundTask = nil
        flushPersist()
    }

    /// Refresh every eligible instance whose subject is due: on the watched
    /// interval when on screen, else on the unattended hour. Instances sharing
    /// a subject collapse into one request (the gate / single flight). At most
    /// two fetches run at once.
    private func refreshDue(reason: String) async {
        let now = Date()
        let candidates = ProviderConfigStore.shared.instances.filter { instance in
            guard instance.isEnabled else { return false }
            // Known to have no credential: nothing to send until a key is added
            // (credentialsChanged clears the note).
            guard instanceNotes[instance.id] == nil else { return false }
            let d = Self.descriptor(for: instance)
            guard QuotaAdapterRegistry.adapter(for: d).capability(for: d).active else { return false }
            // Skip without a Keychain read when the known subject is not due.
            if let sid = instanceSubjects[instance.id],
               !QuotaRefreshGate.decide(subjects[sid]?.lastRefresh, now: now, forced: false,
                                        policy: Self.policy(for: sid.vendor),
                                        attended: isWatched(instance.id)).isAllowed {
                return false
            }
            return true
        }
        guard !candidates.isEmpty else { return }
        logger.info("[Quota] ⏱️ \(reason): \(candidates.count) due (watched \(candidates.filter { self.isWatched($0.id) }.count))")
        var index = 0
        while index < candidates.count, !Task.isCancelled {
            let batch = candidates[index..<min(index + 2, candidates.count)]
            index += batch.count
            await withTaskGroup(of: Void.self) { group in
                for instance in batch {
                    let attended = isWatched(instance.id)
                    group.addTask { @MainActor [weak self] in
                        _ = await self?.refresh(instanceId: instance.id, forced: false, reason: reason,
                                                attended: attended)
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Quota", isDirectory: true).appendingPathComponent("store.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        guard let file = QuotaStoreFile.decode(data) else {
            logger.warning("[Quota] store.json unreadable (\(data.count) bytes) — starting empty")
            return
        }
        subjects = Dictionary(file.subjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        pools = Dictionary(file.pools.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        bindings = file.bindings
        capabilities = Dictionary(file.capabilities.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        // [T-quota-no-manual-mapping] Mappings saved by older builds are not
        // loaded; the next save writes an empty list, which clears them.
        summaries = Dictionary(file.summaries.map { ("\($0.subjectId)|\($0.source.rawValue)", $0) },
                               uniquingKeysWith: { a, _ in a })
        instanceSubjects = file.instanceSubjects
    }

    private func changed(persist: Bool = true) {
        revision &+= 1
        if persist { schedulePersist() }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPersist()
        }
    }

    private func flushPersist() {
        persistTask?.cancel()
        persistTask = nil
        guard loaded, let url = Self.fileURL else { return }
        var file = QuotaStoreFile()
        file.subjects = Array(subjects.values)
        file.pools = Array(pools.values)
        file.bindings = bindings
        file.capabilities = Array(capabilities.values)
        file.summaries = Array(summaries.values)
        file.instanceSubjects = instanceSubjects
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dirURL = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dirURL.setResourceValues(values)
            try QuotaStoreFile.encode(file).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            logger.error("[Quota] persist failed: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// [ISS-031] DEBUG builds only: `Library/Caches/quota-debug-endpoints.json`,
    /// `{"<instanceId>": "<http(s) URL>"}`, points ONE instance's query at a fake
    /// server (vphone verification of the Kimi Code `/usages` parser). Keyed by
    /// instance, never by vendor, so a real account's token on the same device
    /// never goes to the fake server. Absent in Release builds; no file = no
    /// override.
    static func debugEndpointOverride(instanceId: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: caches.appendingPathComponent("quota-debug-endpoints.json")),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let raw = map[instanceId], let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }
    #endif

    // MARK: - Instance → descriptor / credential

    static func descriptor(for instance: ProviderInstance) -> QuotaInstanceDescriptor {
        QuotaInstanceDescriptor(
            instanceId: instance.id,
            label: instance.label,
            providerKind: QuotaInstanceDescriptor.ProviderKind(rawValue: instance.providerType.rawValue) ?? .unsupported,
            isOAuth: instance.credentialType == .oauth,
            isEnabled: instance.isEnabled,
            customBaseURL: instance.effectiveCustomBaseURL,
            isOpenCodeChannel: instance.isOpenCodeChannel)
    }

    /// The bearer credential for an active balance query: the API key, else a
    /// manually pasted token. A real OAuth sign-in (Codex / Claude) never
    /// reaches here — those vendors have no active adapter.
    private static func credential(for instance: ProviderInstance) -> String? {
        if let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id, caller: "quota"),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let token = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token"),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func kindOrder(_ k: QuotaPool.Kind) -> Int {
        switch k {
        case .prepaidBalance: return 0
        case .spendCap: return 1
        case .usageWindow: return 2
        case .allowance: return 3
        case .rateLimit: return 4
        }
    }
}

/// [T-quota-claude-subscription] Entry point for the Anthropic URLProtocols:
/// called on the network delegate queue for every response. Filters on the
/// calling thread and allocates nothing unless the response carries unified
/// rate-limit headers; only then hops to the main actor.
enum QuotaObservationSink {
    static func recordAnthropicResponse(instanceId: String?, response: HTTPURLResponse) {
        guard let instanceId else { return }
        var found: [String: String]?
        for (k, v) in response.allHeaderFields {
            guard let key = (k as? String)?.lowercased(), key.hasPrefix("anthropic-ratelimit-") else { continue }
            if found == nil { found = [:] }
            found?[key] = "\(v)"
        }
        guard let headers = found,
              headers.keys.contains(where: { $0.hasPrefix(ClaudeSubscriptionQuotaAdapter.headerPrefix) }) else { return }
        Task { @MainActor in
            QuotaStore.shared.observeSubscriptionHeaders(instanceId: instanceId, vendor: .claudeSubscription,
                                                         headers: headers)
        }
    }

    /// [T-quota-codex-subscription] Codex replies (OpenAIProvider.streamRaw).
    static func recordCodexResponse(instanceId: String?, response: HTTPURLResponse) {
        guard let instanceId else { return }
        var found: [String: String]?
        for (k, v) in response.allHeaderFields {
            guard let key = (k as? String)?.lowercased(), key.hasPrefix(CodexSubscriptionQuotaAdapter.headerPrefix) else { continue }
            if found == nil { found = [:] }
            found?[key] = "\(v)"
        }
        guard let headers = found, headers.keys.contains(where: { $0.hasSuffix("-used-percent") }) else { return }
        Task { @MainActor in
            QuotaStore.shared.observeSubscriptionHeaders(instanceId: instanceId, vendor: .codexSubscription,
                                                         headers: headers)
        }
    }
}
