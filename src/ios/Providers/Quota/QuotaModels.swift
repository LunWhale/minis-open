//
//  QuotaModels.swift
//  MinisApp
//
//  [T-provider-quota] Upstream quota / balance domain model (design v3 §4–§5,
//  plus the confirmed product decisions: manual mappings, daily capability
//  probing, 10-minute refresh).
//
//  "Quota" here means ONLY what the upstream model service itself reports or
//  enforces: prepaid balances, credits, request/token allowances, subscription
//  windows, rate limits. Minis's own token telemetry, cost estimates and relay
//  usage logs are NOT quota and have no representation in this file — there is
//  deliberately no `QuotaSource` case for them.
//
//  Foundation only: the standalone tests compile this file directly.
//

import Foundation

// MARK: - Identity

/// The upstream vendor a provider instance's quota comes from. Decided by
/// `QuotaVendorDetector` from provider type + credential + base URL host.
enum QuotaVendor: String, Codable, Sendable, CaseIterable {
    case deepSeek, moonshot, siliconFlow, openRouter
    case codexSubscription, openAIPlatform
    case claudeSubscription, anthropicPlatform
    case geminiAPIKey, geminiCodeAssist, antigravity
    case xAI, kimiCode, githubCopilot
    /// Xiaomi MiMo: its balance is only exposed to the web console's login
    /// session, never to the `sk-` API key.
    case xiaomiMiMo
    /// [ISS-031] MiniMax (api.minimax.io / api.minimaxi.com). Its Token Plan
    /// FAQ documents `GET /v1/token_plan/remains`, but not the response fields,
    /// so no adapter: console link only.
    case miniMax
    /// [ISS-031] OpenCode Zen / Go (an instance on the OpenCode channel). No
    /// usage or balance API is documented: console link only.
    case openCode
    case customRelay, unknown
}

/// Owner of a set of quota pools. Two instances resolving to the same subject
/// (same vendor + same API key) share every pool and are queried once.
struct QuotaSubjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    let vendor: QuotaVendor
    /// SHA-256 prefix of the API key, an upstream account id, or "instance:<id>".
    /// Never the credential itself.
    let accountKey: String

    var description: String { "\(vendor.rawValue):\(accountKey)" }
}

/// Canonical, adapter-stable pool key: "<vendor>:<accountKey>:<family>[:<qualifier>]".
/// The store keeps each pool ONCE under this key; bindings reference it.
struct QuotaPoolKey: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(subject: QuotaSubjectID, family: String, qualifier: String? = nil) {
        var s = "\(subject.vendor.rawValue):\(subject.accountKey):\(family)"
        if let qualifier, !qualifier.isEmpty { s += ":\(qualifier)" }
        self.rawValue = s
    }
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Subject

struct QuotaSubject: Codable, Sendable, Identifiable, Equatable {
    let id: QuotaSubjectID
    var kind: Kind
    var parent: QuotaSubjectID?
    /// Every instance resolving here (usually one).
    var instanceIds: Set<String>
    /// Masked key ("sk-…a1b2") — never the full credential.
    var accountLabel: String?
    var plan: QuotaPlan?
    var state: State
    var lastRefresh: QuotaRefreshRecord?

    enum Kind: String, Codable, Sendable { case account, credential, organization, project }

    enum State: Codable, Sendable, Equatable {
        /// No upstream quota signal this build can read.
        case unsupported(UnsupportedReason)
        /// Passive-only vendor, nothing observed yet (reserved; no passive channel ships yet).
        case awaitingFirstObservation
        case notConfigured(NotConfiguredReason)
        /// Has pools (individual pools may be stale).
        case available
        /// Tried, failed, nothing to show.
        case failed
    }
    enum UnsupportedReason: String, Codable, Sendable {
        /// The vendor has no quota/balance interface.
        case vendorHasNoQuotaAPI
        /// Unknown vendor or a custom endpoint whose capability probe found nothing.
        case unknownVendor
        /// The provider type/credential shape does not fit any adapter.
        case providerTypeUnsupported
        /// The vendor only exposes quota passively (headers / stream events), and
        /// passive observation is not implemented yet. Reported honestly instead
        /// of promising "shown after your next message".
        case passiveNotImplemented
        /// Capability probe or a query answered 404 / an unreadable structure.
        case capabilityProbeFailed
    }
    enum NotConfiguredReason: String, Codable, Sendable {
        case missingCredential, oauthNotSupported, instanceDisabled, relayProbeOff
    }
}

struct QuotaPlan: Codable, Sendable, Equatable {
    var rawId: String
    var tierName: String?
}

// MARK: - Snapshot (one fetch / one observation)

/// The unit of one fetch. Carries provenance and the pools/bindings of THIS
/// fetch only; the store merges it (see `QuotaMerge`).
struct UpstreamQuotaSnapshot: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let subjectId: QuotaSubjectID
    var provenance: QuotaProvenance
    /// Local clock.
    var capturedAt: Date
    /// server − local, from the response `Date` header.
    var serverClockOffset: TimeInterval?
    var plan: QuotaPlan?
    var pools: [QuotaPool]
    var bindings: [QuotaPoolBinding]
    /// Upstream says the whole account can serve requests (DeepSeek `is_available`).
    var accountAvailable: Bool?
}

/// Persisted digest of the latest snapshot per (subject, source). No bodies,
/// no headers — just what an audit/debug view needs.
struct QuotaSnapshotSummary: Codable, Sendable, Equatable {
    let subjectId: QuotaSubjectID
    var source: QuotaSource
    var adapterId: String
    var capturedAt: Date
    var poolKeys: [QuotaPoolKey]
}

struct QuotaProvenance: Codable, Sendable, Equatable {
    var source: QuotaSource
    var confidence: QuotaConfidence
    var adapterId: String
    /// Host + path only; never query strings or secrets.
    var endpoint: String?
    /// Set when the data came from / through a relay.
    var relayHost: String?
}

enum QuotaSource: String, Codable, Sendable, CaseIterable {
    /// Vendor balance / quota endpoint.
    case officialQuery
    /// Headers on a real model response.
    case officialHeaders
    /// e.g. codex.rate_limits.
    case officialStreamEvent
    /// 429 body, e.g. Gemini QuotaFailure.
    case officialErrorSignal
    /// Vendor dashboard / console API that is not documented as public.
    case providerDashboardAPI
    /// A compatible or reverse-engineered interface (e.g. a relay mimicking a vendor).
    case compatibleInterface
    /// Relay's own enforced quota for this key (One/New API billing).
    case relayAccountLedger
    /// Minis-computed from the above (reset passed, etc.).
    case derived
    // Deliberately absent: any local telemetry / relay usage log / cost estimate.
}

enum QuotaConfidence: String, Codable, Sendable {
    /// Official public documentation.
    case documented
    /// Used by the vendor's client or a mature OSS proxy, not documented.
    case observedClient
    /// Unverified candidate.
    case unverified
    /// Relay-reported.
    case thirdParty
    /// Declared by the user (manual mapping).
    case userDeclared
}

// MARK: - Pool & windows

struct QuotaPool: Codable, Sendable, Identifiable, Equatable {
    var id: QuotaPoolKey
    var subjectId: QuotaSubjectID
    var kind: Kind
    var unit: QuotaUnit
    /// Raw name from upstream ("GPT-5.3-Codex-Spark", "CNY balance").
    var vendorLabel: String?
    /// Non-windowed amounts (prepaid balances, spend caps). nil for pure window pools.
    var amounts: QuotaAmounts?
    /// Zero or more windows; never merged into one number.
    var windows: [QuotaWindow]
    /// is_available / status: allowed | warning | rejected.
    var verdict: Verdict?
    var unlimited: Bool
    var provenance: QuotaProvenance
    /// Newest of amounts/windows.
    var observedAt: Date

    enum Kind: String, Codable, Sendable {
        /// Money/credits held, can be topped up → never a percent.
        case prepaidBalance
        /// Cap on spend (OpenRouter key limit, relay hard limit).
        case spendCap
        /// Sized periodic allowance (requests/tokens/credits per period).
        case allowance
        /// Subscription rolling windows (Codex, Claude, Antigravity).
        case usageWindow
        /// Throughput (RPM/TPM/concurrency) — NOT consumable quota.
        case rateLimit
    }
    enum Verdict: String, Codable, Sendable { case allowed, warning, rejected }
}

enum QuotaUnit: Codable, Hashable, Sendable {
    /// ISO 4217.
    case currency(code: String)
    /// Not convertible unless the vendor states a rate.
    case credits(name: String?)
    case requests
    case tokens(TokenKind)
    /// Upstream gives only a fraction / percent.
    case percentOnly
    case rateLimit(RateMetric)
    case custom(name: String)

    enum TokenKind: String, Codable, Sendable { case input, output, total }
    enum RateMetric: String, Codable, Sendable { case requests, tokens, inputTokens, outputTokens, concurrency }
}

/// All in the pool's unit; all optional; `Decimal` only. Persisted as strings
/// so no amount ever round-trips through `Double`.
struct QuotaAmounts: Codable, Sendable, Equatable {
    var total: Decimal?
    var used: Decimal?
    var remaining: Decimal?
    /// Same-unit components: granted / toppedUp / voucher / cash.
    var breakdown: [Part] = []

    struct Part: Codable, Sendable, Equatable {
        var role: Role
        var amount: Decimal
        var expiresAt: Date?

        enum Role: Codable, Sendable, Equatable, Hashable {
            case granted, toppedUp, voucher, cash
            case other(String)
        }

        init(role: Role, amount: Decimal, expiresAt: Date? = nil) {
            self.role = role
            self.amount = amount
            self.expiresAt = expiresAt
        }
        enum CodingKeys: String, CodingKey { case role, amount, expiresAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(Role.self, forKey: .role)
            amount = try QuotaDecimalCoding.decode(c, .amount) ?? 0
            expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try QuotaDecimalCoding.encode(amount, &c, .amount)
            try c.encodeIfPresent(expiresAt, forKey: .expiresAt)
        }
    }

    init(total: Decimal? = nil, used: Decimal? = nil, remaining: Decimal? = nil, breakdown: [Part] = []) {
        self.total = total
        self.used = used
        self.remaining = remaining
        self.breakdown = breakdown
    }
    enum CodingKeys: String, CodingKey { case total, used, remaining, breakdown }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try QuotaDecimalCoding.decode(c, .total)
        used = try QuotaDecimalCoding.decode(c, .used)
        remaining = try QuotaDecimalCoding.decode(c, .remaining)
        breakdown = try c.decodeIfPresent([Part].self, forKey: .breakdown) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try QuotaDecimalCoding.encode(total, &c, .total)
        try QuotaDecimalCoding.encode(used, &c, .used)
        try QuotaDecimalCoding.encode(remaining, &c, .remaining)
        try c.encode(breakdown, forKey: .breakdown)
    }
}

struct QuotaWindow: Codable, Sendable, Equatable, Identifiable {
    /// "5h", "7d", "day", "month", "300m" — stable per pool.
    var id: String
    var duration: TimeInterval?
    var calendarPeriod: CalendarPeriod?
    var isRolling: Bool
    /// For sized windows (requests/tokens per period).
    var amounts: QuotaAmounts?
    /// Verbatim from upstream (0…1).
    var reportedUsedFraction: Decimal?
    var reportedRemainingFraction: Decimal?
    /// Already corrected by the snapshot's server clock offset.
    var resetsAt: Date?
    var observedAt: Date
    /// Windows of one pool may come from different channels.
    var provenance: QuotaProvenance

    enum CalendarPeriod: String, Codable, Sendable { case day, week, month }

    init(id: String, duration: TimeInterval? = nil, calendarPeriod: CalendarPeriod? = nil,
         isRolling: Bool, amounts: QuotaAmounts? = nil,
         reportedUsedFraction: Decimal? = nil, reportedRemainingFraction: Decimal? = nil,
         resetsAt: Date? = nil, observedAt: Date, provenance: QuotaProvenance) {
        self.id = id
        self.duration = duration
        self.calendarPeriod = calendarPeriod
        self.isRolling = isRolling
        self.amounts = amounts
        self.reportedUsedFraction = reportedUsedFraction
        self.reportedRemainingFraction = reportedRemainingFraction
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.provenance = provenance
    }
    enum CodingKeys: String, CodingKey {
        case id, duration, calendarPeriod, isRolling, amounts
        case reportedUsedFraction, reportedRemainingFraction, resetsAt, observedAt, provenance
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        calendarPeriod = try c.decodeIfPresent(CalendarPeriod.self, forKey: .calendarPeriod)
        isRolling = try c.decode(Bool.self, forKey: .isRolling)
        amounts = try c.decodeIfPresent(QuotaAmounts.self, forKey: .amounts)
        reportedUsedFraction = try QuotaDecimalCoding.decode(c, .reportedUsedFraction)
        reportedRemainingFraction = try QuotaDecimalCoding.decode(c, .reportedRemainingFraction)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        provenance = try c.decode(QuotaProvenance.self, forKey: .provenance)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(calendarPeriod, forKey: .calendarPeriod)
        try c.encode(isRolling, forKey: .isRolling)
        try c.encodeIfPresent(amounts, forKey: .amounts)
        try QuotaDecimalCoding.encode(reportedUsedFraction, &c, .reportedUsedFraction)
        try QuotaDecimalCoding.encode(reportedRemainingFraction, &c, .reportedRemainingFraction)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(provenance, forKey: .provenance)
    }
}

// MARK: - Binding (many-to-many)

struct QuotaPoolBinding: Codable, Sendable, Hashable {
    var poolKey: QuotaPoolKey
    var target: Target
    var evidence: Evidence

    enum Target: Codable, Sendable, Hashable {
        /// Every model under the subject.
        case subject
        /// Normalized upstream model key — ONLY with .explicitUpstream or .userManualMapping.
        case model(key: String)
        /// Glob — ONLY with .explicitUpstream or .vendorDocumented.
        case modelFamily(pattern: String)
        /// Non-model product ("code_review").
        case product(name: String)
    }
    enum Evidence: String, Codable, Sendable {
        /// Upstream named the model/product.
        case explicitUpstream
        /// Vendor docs say account-wide.
        case vendorDocumented
        /// Scope unstated → treated as shared (default).
        case assumedSubjectWide
        /// The USER declared this model draws on the pool. Never produced by an
        /// adapter; lives only in `QuotaManualMapping` and is merged at read time,
        /// so it can never overwrite or masquerade as an upstream binding.
        case userManualMapping

        /// Higher wins when de-duplicating the same (pool, target).
        var rank: Int {
            switch self {
            case .explicitUpstream: return 3
            case .vendorDocumented: return 2
            case .assumedSubjectWide: return 1
            case .userManualMapping: return 0
            }
        }
    }
}

/// [T-provider-quota] User-declared "model X of instance Y draws on pool P".
///
/// Stored separately from adapter bindings so it can be edited/deleted without
/// touching them, and so an adapter refresh can never erase it. Keyed by
/// instance + Minis model id + target pool key; holds no secret.
///
/// Invalidation: when the target pool no longer exists for the instance's
/// subject, or the model is gone from the instance, the mapping is kept but
/// reported as invalid (`QuotaMappingValidity`) so the user can fix or delete
/// it — it is never silently re-pointed.
struct QuotaManualMapping: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var instanceId: String
    /// Minis `ModelEntry.baseModel.id` (the id the user sees).
    var modelId: String
    var poolKey: QuotaPoolKey
    var note: String?
    var createdAt: Date
    var updatedAt: Date
}

enum QuotaMappingValidity: String, Sendable, Equatable {
    case valid
    /// The target pool is not among the subject's pools (vendor stopped returning it,
    /// the key changed, or the instance now resolves to another subject).
    case poolMissing
    /// The instance no longer has this model.
    case modelMissing
    /// The instance itself is gone.
    case instanceMissing
}

// MARK: - Capability

/// "Provider type + normalized base URL" — the unit of capability probing,
/// limited to once per day.
struct QuotaCapabilityKey: Hashable, Codable, Sendable, CustomStringConvertible {
    var providerType: String
    /// Lower-cased scheme://host[:port][/path] with trailing "/" and "/v1" removed;
    /// "default" when the instance uses the provider's built-in endpoint.
    var baseURL: String
    var description: String { "\(providerType)@\(baseURL)" }

    static func normalize(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return "default" }
        s = s.lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// What an adapter can do for an instance.
struct QuotaCapability: Sendable, Equatable {
    /// Can actively query upstream.
    var active: Bool
    var source: QuotaSource
    var confidence: QuotaConfidence
    var manualRefresh: Bool
    /// When `active == false`: why.
    var unsupportedReason: QuotaSubject.UnsupportedReason?

    static func unsupported(_ reason: QuotaSubject.UnsupportedReason) -> QuotaCapability {
        QuotaCapability(active: false, source: .officialQuery, confidence: .documented,
                        manualRefresh: false, unsupportedReason: reason)
    }
    static func activeQuery(source: QuotaSource = .officialQuery,
                            confidence: QuotaConfidence = .documented) -> QuotaCapability {
        QuotaCapability(active: true, source: source, confidence: confidence,
                        manualRefresh: true, unsupportedReason: nil)
    }
}

/// Outcome of the (at most daily) capability probe for one `QuotaCapabilityKey`.
struct QuotaCapabilityRecord: Codable, Sendable, Equatable {
    var key: QuotaCapabilityKey
    var adapterId: String
    var status: Status
    var source: QuotaSource?
    var confidence: QuotaConfidence?
    var probedAt: Date
    /// Short, non-sensitive reason ("HTTP 404", "unreadable response").
    var detail: String?

    enum Status: String, Codable, Sendable {
        /// Queries may run.
        case supported
        /// Nothing to query for this endpoint.
        case unsupported
        /// A probe or a query hit 404 / an unsupported structure: stop until the
        /// next daily probe or an explicit user re-probe.
        case failed
    }
}

// MARK: - Refresh bookkeeping

struct QuotaRefreshRecord: Codable, Sendable, Equatable {
    var attemptedAt: Date
    var succeededAt: Date?
    var error: QuotaError?
    /// Earliest time an AUTOMATIC refresh may run again.
    var nextAllowedAt: Date?
    /// Server-imposed cooldown (Retry-After) — binds manual refreshes too.
    var serverCooldownUntil: Date?
    /// Consecutive failures, for exponential backoff.
    var consecutiveFailures: Int = 0
    /// Last user-forced attempt, for the manual debounce.
    var lastForcedAt: Date?
}

struct QuotaError: Codable, Sendable, Equatable {
    var kind: Kind
    /// Short, non-sensitive, NOT localized (the UI localizes by `kind`).
    var detail: String
    var httpStatus: Int?
    var at: Date
    var retryAfter: Date?

    enum Kind: String, Codable, Sendable {
        case network, unauthorized, forbidden, notFound, rateLimited, server
        case badResponse, unsupportedResponse, missingCredential
    }
}

// MARK: - Derived views (computed, never persisted)

struct QuotaUtilization: Sendable, Equatable {
    /// May exceed 100 on overage.
    var percent: Decimal
    var basis: Basis
    enum Basis: String, Sendable { case reported, reportedComplement, computed }
}

enum QuotaStatus: String, Codable, Sendable, Comparable {
    case unknown, available, low, rateLimited, exhausted

    /// By severity; `unknown` lowest.
    var severity: Int {
        switch self {
        case .unknown: return 0
        case .available: return 1
        case .low: return 2
        case .rateLimited: return 3
        case .exhausted: return 4
        }
    }
    static func < (a: QuotaStatus, b: QuotaStatus) -> Bool { a.severity < b.severity }
    /// Worth surfacing in compact UI.
    var isWarning: Bool { self == .low || self == .rateLimited || self == .exhausted }
}

enum QuotaFreshness: String, Sendable, Equatable { case fresh, stale, expired }

struct PoolStatus: Sendable, Equatable {
    var status: QuotaStatus
    /// Tightest window; nil for non-windowed.
    var decidingWindowId: String?
    /// Of that window, if any.
    var utilization: QuotaUtilization?
    var freshness: QuotaFreshness
}

struct ModelQuotaView: Sendable, Equatable {
    let instanceId: String
    let modelKey: String
    let subjectId: QuotaSubjectID?
    /// Every applicable pool.
    let bound: [BoundPool]
    let effective: QuotaStatus
    /// Tightest constraint.
    let deciding: BoundPool?
    /// Some bound pools unknown.
    let isIncomplete: Bool
    /// Any binding with a .model/.modelFamily/.product target (upstream or manual).
    let hasModelSpecificPool: Bool

    struct BoundPool: Sendable, Equatable {
        let poolKey: QuotaPoolKey
        let binding: QuotaPoolBinding
        let status: PoolStatus
        var isShared: Bool { binding.target == .subject }
        var isManual: Bool { binding.evidence == .userManualMapping }
    }

    static func empty(instanceId: String, modelKey: String) -> ModelQuotaView {
        ModelQuotaView(instanceId: instanceId, modelKey: modelKey, subjectId: nil, bound: [],
                       effective: .unknown, deciding: nil, isIncomplete: false, hasModelSpecificPool: false)
    }
}

struct QuotaThresholds: Sendable {
    var lowPercent: Decimal = 80
    var exhaustedPercent: Decimal = 100
    /// Optional per-subject, per-currency user thresholds for prepaid balances.
    /// Empty by default: without one a prepaid balance is never judged "low"
    /// (product decision still open, design §13.2).
    var lowBalance: [QuotaSubjectID: [String: Decimal]] = [:]
    /// Sentinels meaning "unlimited" for specific adapters (e.g. relay hard_limit_usd 1e8).
    var unlimitedSentinels: [String: Decimal] = [:]

    init() {}
}

// MARK: - Decimal coding

/// Decimals are persisted as strings: `JSONDecoder` reads a JSON number into a
/// `Double` before building the `Decimal`, which can change a stored amount.
enum QuotaDecimalCoding {
    static func encode<K: CodingKey>(_ value: Decimal?, _ c: inout KeyedEncodingContainer<K>, _ key: K) throws {
        guard let value else { return }
        try c.encode(value.quotaString, forKey: key)
    }
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Decimal? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return QuotaDecimalParser.parse(s)
        }
        return nil
    }
}

extension Decimal {
    /// Locale-independent canonical text ("110.00" stays "110", "-0.5" → "-0.5").
    var quotaString: String {
        var copy = self
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
    }
}

/// Parses upstream amounts. Strings and JSON numbers are accepted; anything
/// unparseable is nil — NEVER zero (design §3.1).
enum QuotaDecimalParser {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func parse(_ value: Any?) -> Decimal? {
        switch value {
        case let s as String:
            return parse(string: s)
        case let n as NSNumber:
            // Bool is bridged as NSNumber; a boolean is never an amount.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            // stringValue avoids binary-float artefacts (0.1 → "0.1").
            return parse(string: n.stringValue)
        case let d as Decimal:
            return d
        default:
            return nil
        }
    }

    static func parse(string raw: String) -> Decimal? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Whole-string validation: Decimal(string:) accepts a numeric PREFIX
        // ("12abc" → 12), which would turn a malformed field into a number.
        let allowed = CharacterSet(charactersIn: "0123456789.-+eE")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              s.contains(where: { $0.isNumber }) else { return nil }
        guard let d = Decimal(string: s, locale: posix), !d.isNaN else { return nil }
        return d
    }
}
