//
//  QuotaAdapters.swift
//  MinisApp
//
//  [T-provider-quota] Vendor detection, the adapter protocol / registry, and
//  the P1 active-query adapters (DeepSeek, Moonshot, SiliconFlow, OpenRouter)
//  plus the unsupported fallback.
//
//  Works on `QuotaInstanceDescriptor` instead of `ProviderInstance` so this file
//  depends on Foundation + CryptoKit only and the standalone tests can compile it.
//
//  Safety rules every adapter follows:
//  - A credential is only ever sent to the vendor's own fixed HTTPS host, the
//    same host the instance is already configured to talk to. No adapter builds
//    a request URL from user-supplied path components.
//  - Response bodies are parsed into the structured model and then dropped;
//    nothing raw is persisted or logged. Personal fields (SiliconFlow's name /
//    email) are never read.
//

import CryptoKit
import Foundation

// MARK: - Instance descriptor

/// The quota-relevant, secret-free facts about one provider instance.
struct QuotaInstanceDescriptor: Sendable, Equatable {
    enum ProviderKind: String, Sendable {
        case openAI, anthropic, gemini, antigravity, openRouter, openAIResponses
        case xAI, kimiCode, githubCopilot, unsupported
    }

    var instanceId: String
    var label: String
    var providerKind: ProviderKind
    var isOAuth: Bool
    var isEnabled: Bool
    var customBaseURL: String?
    /// [ISS-031] `ProviderInstance.isOpenCodeChannel` - the app's own OpenCode
    /// detection, carried in so this file does not grow a second one.
    var isOpenCodeChannel: Bool = false

    var customHost: String? {
        guard let raw = customBaseURL, !raw.isEmpty,
              let host = URL(string: raw)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    var capabilityKey: QuotaCapabilityKey {
        QuotaCapabilityKey(providerType: providerKind.rawValue,
                           baseURL: QuotaCapabilityKey.normalize(customBaseURL))
    }
}

// MARK: - Vendor detection (design §7.2)

enum QuotaVendorDetector {
    static func vendor(for d: QuotaInstanceDescriptor) -> QuotaVendor {
        if d.providerKind == .unsupported { return .unknown }
        if d.isOpenCodeChannel { return .openCode }
        if let host = d.customHost {
            if let v = vendor(forHost: host) { return v }
            // A custom endpoint on the vendor's own public host behaves like the default.
            if host == "api.openai.com" { return d.isOAuth ? .codexSubscription : .openAIPlatform }
            if host == "api.anthropic.com" { return d.isOAuth ? .claudeSubscription : .anthropicPlatform }
            if host == "generativelanguage.googleapis.com" { return .geminiAPIKey }
            return .customRelay
        }
        switch d.providerKind {
        case .openAI, .openAIResponses: return d.isOAuth ? .codexSubscription : .openAIPlatform
        case .anthropic: return d.isOAuth ? .claudeSubscription : .anthropicPlatform
        case .gemini: return d.isOAuth ? .geminiCodeAssist : .geminiAPIKey
        case .antigravity: return .antigravity
        case .openRouter: return .openRouter
        case .xAI: return .xAI
        case .kimiCode: return .kimiCode
        case .githubCopilot: return .githubCopilot
        case .unsupported: return .unknown
        }
    }

    static func vendor(forHost host: String) -> QuotaVendor? {
        switch host {
        case "api.deepseek.com": return .deepSeek
        case "api.moonshot.cn", "api.moonshot.ai": return .moonshot
        case "api.siliconflow.cn", "api.siliconflow.com": return .siliconFlow
        case "openrouter.ai": return .openRouter
        // [ISS-031] Kimi Code: China and overseas hosts (both in the official
        // Kimi Code docs; both answer 401, not 404, on /coding/v1/usages).
        case "api.kimi.com", "api.kimi.ai": return .kimiCode
        case "api.minimax.io", "api.minimaxi.com": return .miniMax
        case "api.x.ai": return .xAI
        case "api.xiaomimimo.com": return .xiaomiMiMo
        default: return nil
        }
    }
}

// MARK: - Transport

struct QuotaHTTPResponse: Sendable {
    var status: Int
    var body: Data
    /// Lower-cased names.
    var headers: [String: String]
}

protocol QuotaHTTPTransport: Sendable {
    /// `headers` are extra request headers (e.g. the Claude CLI fingerprint);
    /// never logged.
    func get(_ url: URL, bearer: String, headers: [String: String]) async throws -> QuotaHTTPResponse
}

extension QuotaHTTPTransport {
    func get(_ url: URL, bearer: String) async throws -> QuotaHTTPResponse {
        try await get(url, bearer: bearer, headers: [:])
    }
}

/// Dedicated ephemeral session: 10 s timeout, no URL cache, no cookies — a
/// balance response must never land in the shared URLCache.
final class QuotaURLSessionTransport: QuotaHTTPTransport, @unchecked Sendable {
    static let shared = QuotaURLSessionTransport()
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        session = URLSession(configuration: cfg)
    }

    func get(_ url: URL, bearer: String, headers: [String: String]) async throws -> QuotaHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaFetchError(kind: .badResponse, detail: "not HTTP")
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let k = k as? String, let v = v as? String else { continue }
            let name = k.lowercased()
            // Allow-list: only what the quota layer reads.
            guard name == "retry-after" || name == "date" else { continue }
            headers[name] = v
        }
        return QuotaHTTPResponse(status: http.statusCode, body: data, headers: headers)
    }
}

/// Thrown by adapters; converted to the persisted `QuotaError` by the store.
struct QuotaFetchError: Error, Sendable, Equatable {
    var kind: QuotaError.Kind
    var detail: String
    var httpStatus: Int?
    var retryAfter: Date?

    func persisted(at: Date) -> QuotaError {
        QuotaError(kind: kind, detail: detail, httpStatus: httpStatus, at: at, retryAfter: retryAfter)
    }
}

enum QuotaHTTP {
    /// Maps a non-2xx response to an error; nil for 2xx.
    static func error(for r: QuotaHTTPResponse, endpoint: String, now: Date) -> QuotaFetchError? {
        switch r.status {
        case 200..<300: return nil
        case 401: return QuotaFetchError(kind: .unauthorized, detail: "HTTP 401 \(endpoint)", httpStatus: 401)
        case 403: return QuotaFetchError(kind: .forbidden, detail: "HTTP 403 \(endpoint)", httpStatus: 403)
        case 404: return QuotaFetchError(kind: .notFound, detail: "HTTP 404 \(endpoint)", httpStatus: 404)
        case 429:
            return QuotaFetchError(kind: .rateLimited, detail: "HTTP 429 \(endpoint)", httpStatus: 429,
                                   retryAfter: retryAfter(r.headers["retry-after"], now: now))
        case 500..<600:
            return QuotaFetchError(kind: .server, detail: "HTTP \(r.status) \(endpoint)", httpStatus: r.status,
                                   retryAfter: retryAfter(r.headers["retry-after"], now: now))
        default:
            return QuotaFetchError(kind: .badResponse, detail: "HTTP \(r.status) \(endpoint)", httpStatus: r.status)
        }
    }

    /// `Retry-After` as delta-seconds or an HTTP-date. Capped at one day so a
    /// broken header cannot park a subject forever.
    static func retryAfter(_ raw: String?, now: Date) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let cap: TimeInterval = 24 * 3600
        if let secs = TimeInterval(raw), secs >= 0 {
            return now.addingTimeInterval(min(secs, cap))
        }
        guard let date = httpDate(raw) else { return nil }
        return min(max(date, now), now.addingTimeInterval(cap))
    }

    static func httpDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: raw)
    }

    /// server − local, when the response carries a `Date` header.
    static func clockOffset(_ r: QuotaHTTPResponse, now: Date) -> TimeInterval? {
        httpDate(r.headers["date"]).map { $0.timeIntervalSince(now) }
    }

    static func jsonObject(_ data: Data, endpoint: String) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "unreadable JSON \(endpoint)")
        }
        return obj
    }
}

// MARK: - Credential-derived account key

enum QuotaAccountKey {
    /// First 16 hex chars of SHA-256(credential). Enough to tell keys apart and
    /// to share pools between two instances holding the same key; not reversible.
    static func derive(from credential: String) -> String {
        let digest = SHA256.hash(data: Data(credential.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "sk-…a1b2" — safe to persist / show.
    static func mask(_ credential: String) -> String {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "…" }
        let prefix = trimmed.hasPrefix("sk-") ? "sk-" : ""
        return "\(prefix)…\(trimmed.suffix(4))"
    }
}

// MARK: - Adapter protocol & registry (design §7.1, trimmed to P1)

struct QuotaFetchContext: Sendable {
    let descriptor: QuotaInstanceDescriptor
    let subjectId: QuotaSubjectID
    let credential: String
    let transport: QuotaHTTPTransport
    let now: Date
    /// Extra request headers the adapter needs (the Claude CLI fingerprint for
    /// the subscription usage query). Supplied by the store; never logged.
    var extraHeaders: [String: String] = [:]
    /// [T-quota-relay-probe] A relay's type detected by an earlier probe
    /// (within a day); nil = probe now.
    var relayKindHint: RelayKind?
    /// [ISS-031] DEBUG builds only (set by QuotaStore under `#if DEBUG`): send
    /// the request here instead of the vendor host, so a fake server can stand
    /// in for an endpoint whose real reply has never been captured. Only the
    /// Kimi Code adapter reads it.
    var endpointOverride: URL? = nil
}

/// One active fetch. `isComplete == false` when part of a multi-endpoint fetch
/// failed: the store then merges without retiring pools it did not see.
struct QuotaFetchOutcome: Sendable {
    var snapshot: UpstreamQuotaSnapshot
    var isComplete: Bool
    /// Errors of the parts that failed (for logging only).
    var partialErrors: [QuotaFetchError] = []
    /// [T-quota-relay-probe] The relay type this fetch used (probed or hinted).
    var relayKind: RelayKind? = nil
    /// [ISS-031] Field names and value types of the response, never a value -
    /// logged once per launch for an adapter whose response shape is not yet
    /// confirmed by a captured reply (Kimi Code).
    var responseShape: String? = nil
}

protocol ProviderQuotaAdapter: Sendable {
    var adapterId: String { get }
    var vendor: QuotaVendor { get }
    /// Static, no I/O.
    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability
    /// Active query → one snapshot with ALL pools of the subject. One call per
    /// subject; multiple currencies / windows come back from the same call.
    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome
    // Passive observation (headers / stream events / error bodies) is design §8.3,
    // phase P2+; no adapter implements it yet, so the hook is not declared here.
}

enum QuotaAdapterRegistry {
    static func adapter(for vendor: QuotaVendor) -> any ProviderQuotaAdapter {
        switch vendor {
        case .deepSeek: return DeepSeekQuotaAdapter()
        case .moonshot: return MoonshotQuotaAdapter()
        case .siliconFlow: return SiliconFlowQuotaAdapter()
        case .openRouter: return OpenRouterQuotaAdapter()
        case .claudeSubscription:
            return ClaudeSubscriptionQuotaAdapter()
        case .codexSubscription:
            return CodexSubscriptionQuotaAdapter()
        case .openAIPlatform, .anthropicPlatform, .geminiAPIKey:
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .passiveNotImplemented)
        case .antigravity:
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .passiveNotImplemented)
        case .xAI, .xiaomiMiMo, .openCode:
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .vendorHasNoQuotaAPI)
        case .kimiCode:
            return KimiCodeQuotaAdapter()
        case .miniMax:
            // [ISS-031] The endpoint is official but its response fields are
            // not documented, and the one known field is reported misnamed
            // (MiniMax-AI/MiniMax-M2#99): no parser until a reply confirms it.
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .providerTypeUnsupported)
        case .geminiCodeAssist, .githubCopilot:
            // Candidate interfaces exist but no captured response has confirmed
            // their fields (design §7.3 ❓); never ship an unverified parser.
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .providerTypeUnsupported)
        case .customRelay:
            // [T-quota-relay-probe] The relay's own account ledger, labelled as
            // relay-reported (never as the upstream vendor's balance).
            return RelayQuotaAdapter()
        case .unknown:
            return UnsupportedQuotaAdapter(vendor: vendor, reason: .unknownVendor)
        }
    }

    static func adapter(for d: QuotaInstanceDescriptor) -> any ProviderQuotaAdapter {
        adapter(for: QuotaVendorDetector.vendor(for: d))
    }
}

struct UnsupportedQuotaAdapter: ProviderQuotaAdapter {
    let vendor: QuotaVendor
    let reason: QuotaSubject.UnsupportedReason
    var adapterId: String { "unsupported.\(vendor.rawValue)" }

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .unsupported(reason) }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        throw QuotaFetchError(kind: .unsupportedResponse, detail: "no active quota query for \(vendor.rawValue)")
    }
}

// MARK: - Shared helpers for balance adapters

private extension QuotaInstanceDescriptor {
    /// The configured host when it is one of `hosts`, else the first (default) host.
    func vendorHost(among hosts: [String]) -> String {
        if let h = customHost, hosts.contains(h) { return h }
        return hosts[0]
    }
}

private func officialProvenance(adapterId: String, endpoint: String) -> QuotaProvenance {
    QuotaProvenance(source: .officialQuery, confidence: .documented, adapterId: adapterId,
                    endpoint: endpoint, relayHost: nil)
}

private func accountWideBinding(_ key: QuotaPoolKey) -> QuotaPoolBinding {
    QuotaPoolBinding(poolKey: key, target: .subject, evidence: .vendorDocumented)
}

// MARK: - DeepSeek

/// `GET https://api.deepseek.com/user/balance` (documented).
/// `{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00",
///   "granted_balance":"10.00","topped_up_balance":"100.00"}]}`
/// One prepaid pool PER currency — currencies are never converted or summed.
struct DeepSeekQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "deepseek.balance" }
    var vendor: QuotaVendor { .deepSeek }
    static let endpoint = "api.deepseek.com/user/balance"

    // An OAuth-typed instance on this host carries a manually pasted bearer
    // token, which is the API key; the store resolves either.
    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .activeQuery() }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        let r = try await ctx.transport.get(URL(string: "https://\(Self.endpoint)")!, bearer: ctx.credential)
        if let e = QuotaHTTP.error(for: r, endpoint: Self.endpoint, now: ctx.now) { throw e }
        let snap = try Self.parse(r.body, subjectId: ctx.subjectId, adapterId: adapterId, now: ctx.now,
                                  clockOffset: QuotaHTTP.clockOffset(r, now: ctx.now))
        return QuotaFetchOutcome(snapshot: snap, isComplete: true)
    }

    static func parse(_ data: Data, subjectId: QuotaSubjectID, adapterId: String = "deepseek.balance",
                      now: Date, clockOffset: TimeInterval? = nil) throws -> UpstreamQuotaSnapshot {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        guard let infos = obj["balance_infos"] as? [[String: Any]] else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "missing balance_infos")
        }
        let available = obj["is_available"] as? Bool
        let prov = officialProvenance(adapterId: adapterId, endpoint: endpoint)
        var pools: [QuotaPool] = []
        for info in infos {
            guard let currency = (info["currency"] as? String)?.uppercased(), !currency.isEmpty else { continue }
            let total = QuotaDecimalParser.parse(info["total_balance"])
            var parts: [QuotaAmounts.Part] = []
            if let g = QuotaDecimalParser.parse(info["granted_balance"]) { parts.append(.init(role: .granted, amount: g)) }
            if let t = QuotaDecimalParser.parse(info["topped_up_balance"]) { parts.append(.init(role: .toppedUp, amount: t)) }
            // An item without a readable total carries no amount we can show.
            guard total != nil || !parts.isEmpty else { continue }
            let key = QuotaPoolKey(subject: subjectId, family: "balance", qualifier: currency)
            pools.append(QuotaPool(
                id: key, subjectId: subjectId, kind: .prepaidBalance, unit: .currency(code: currency),
                vendorLabel: "\(currency) balance",
                amounts: QuotaAmounts(remaining: total, breakdown: parts),
                windows: [],
                verdict: available.map { $0 ? .allowed : .rejected },
                unlimited: false, provenance: prov, observedAt: now))
        }
        guard !pools.isEmpty || infos.isEmpty else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no readable balance_infos")
        }
        return UpstreamQuotaSnapshot(
            id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
            serverClockOffset: clockOffset, plan: nil, pools: pools,
            bindings: pools.map { accountWideBinding($0.id) }, accountAvailable: available)
    }
}

// MARK: - Moonshot

/// `GET https://api.moonshot.cn/v1/users/me/balance` (documented; the `.ai`
/// platform bills in USD, the `.cn` one in CNY).
/// `{"code":0,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3.00},"status":true}`
struct MoonshotQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "moonshot.balance" }
    var vendor: QuotaVendor { .moonshot }
    static let hosts = ["api.moonshot.cn", "api.moonshot.ai"]

    // An OAuth-typed instance on this host carries a manually pasted bearer
    // token, which is the API key; the store resolves either.
    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .activeQuery() }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        let host = ctx.descriptor.vendorHost(among: Self.hosts)
        let endpoint = "\(host)/v1/users/me/balance"
        let r = try await ctx.transport.get(URL(string: "https://\(endpoint)")!, bearer: ctx.credential)
        if let e = QuotaHTTP.error(for: r, endpoint: endpoint, now: ctx.now) { throw e }
        let snap = try Self.parse(r.body, host: host, subjectId: ctx.subjectId, adapterId: adapterId,
                                  now: ctx.now, clockOffset: QuotaHTTP.clockOffset(r, now: ctx.now))
        return QuotaFetchOutcome(snapshot: snap, isComplete: true)
    }

    static func currency(forHost host: String) -> String { host.hasSuffix(".ai") ? "USD" : "CNY" }

    static func parse(_ data: Data, host: String, subjectId: QuotaSubjectID, adapterId: String = "moonshot.balance",
                      now: Date, clockOffset: TimeInterval? = nil) throws -> UpstreamQuotaSnapshot {
        let endpoint = "\(host)/v1/users/me/balance"
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        guard let d = obj["data"] as? [String: Any],
              let available = QuotaDecimalParser.parse(d["available_balance"]) else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "missing data.available_balance")
        }
        var parts: [QuotaAmounts.Part] = []
        if let v = QuotaDecimalParser.parse(d["voucher_balance"]) { parts.append(.init(role: .voucher, amount: v)) }
        if let c = QuotaDecimalParser.parse(d["cash_balance"]) { parts.append(.init(role: .cash, amount: c)) }
        let cur = currency(forHost: host)
        let key = QuotaPoolKey(subject: subjectId, family: "balance", qualifier: cur)
        let prov = officialProvenance(adapterId: adapterId, endpoint: endpoint)
        let pool = QuotaPool(
            id: key, subjectId: subjectId, kind: .prepaidBalance, unit: .currency(code: cur),
            vendorLabel: "\(cur) balance", amounts: QuotaAmounts(remaining: available, breakdown: parts),
            windows: [], verdict: nil, unlimited: false, provenance: prov, observedAt: now)
        return UpstreamQuotaSnapshot(
            id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
            serverClockOffset: clockOffset, plan: nil, pools: [pool],
            bindings: [accountWideBinding(key)], accountAvailable: nil)
    }
}

// MARK: - SiliconFlow

/// `GET https://api.siliconflow.cn/v1/user/info` (documented). Only the three
/// balance fields are read; id / name / email / image are never touched.
/// `{"code":20000,"status":true,"data":{"balance":"0.88","chargeBalance":"88.00","totalBalance":"88.88",...}}`
struct SiliconFlowQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "siliconflow.userinfo" }
    var vendor: QuotaVendor { .siliconFlow }
    static let hosts = ["api.siliconflow.cn", "api.siliconflow.com"]

    // An OAuth-typed instance on this host carries a manually pasted bearer
    // token, which is the API key; the store resolves either.
    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .activeQuery() }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        let host = ctx.descriptor.vendorHost(among: Self.hosts)
        let endpoint = "\(host)/v1/user/info"
        let r = try await ctx.transport.get(URL(string: "https://\(endpoint)")!, bearer: ctx.credential)
        if let e = QuotaHTTP.error(for: r, endpoint: endpoint, now: ctx.now) { throw e }
        let snap = try Self.parse(r.body, host: host, subjectId: ctx.subjectId, adapterId: adapterId,
                                  now: ctx.now, clockOffset: QuotaHTTP.clockOffset(r, now: ctx.now))
        return QuotaFetchOutcome(snapshot: snap, isComplete: true)
    }

    static func currency(forHost host: String) -> String { host.hasSuffix(".com") ? "USD" : "CNY" }

    static func parse(_ data: Data, host: String, subjectId: QuotaSubjectID, adapterId: String = "siliconflow.userinfo",
                      now: Date, clockOffset: TimeInterval? = nil) throws -> UpstreamQuotaSnapshot {
        let endpoint = "\(host)/v1/user/info"
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        guard let d = obj["data"] as? [String: Any],
              let total = QuotaDecimalParser.parse(d["totalBalance"]) else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "missing data.totalBalance")
        }
        var parts: [QuotaAmounts.Part] = []
        if let c = QuotaDecimalParser.parse(d["chargeBalance"]) { parts.append(.init(role: .toppedUp, amount: c)) }
        if let g = QuotaDecimalParser.parse(d["balance"]) { parts.append(.init(role: .granted, amount: g)) }
        let cur = currency(forHost: host)
        let key = QuotaPoolKey(subject: subjectId, family: "balance", qualifier: cur)
        let prov = officialProvenance(adapterId: adapterId, endpoint: endpoint)
        let pool = QuotaPool(
            id: key, subjectId: subjectId, kind: .prepaidBalance, unit: .currency(code: cur),
            vendorLabel: "\(cur) balance", amounts: QuotaAmounts(remaining: total, breakdown: parts),
            windows: [], verdict: nil, unlimited: false, provenance: prov, observedAt: now)
        return UpstreamQuotaSnapshot(
            id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
            serverClockOffset: clockOffset, plan: nil, pools: [pool],
            bindings: [accountWideBinding(key)], accountAvailable: nil)
    }
}

// MARK: - OpenRouter

/// Two documented endpoints, fetched in parallel, failing independently:
/// - `GET /api/v1/key` → `data.limit` (null = no cap), `usage`, `limit_remaining`, `limit_reset`
///   → a `spendCap` pool, only when `limit` is set.
/// - `GET /api/v1/credits` → `data.total_credits`, `total_usage`
///   → a `prepaidBalance` pool, remaining = total_credits − total_usage.
struct OpenRouterQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "openrouter.key+credits" }
    var vendor: QuotaVendor { .openRouter }
    static let keyEndpoint = "openrouter.ai/api/v1/key"
    static let creditsEndpoint = "openrouter.ai/api/v1/credits"

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability { .activeQuery() }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        async let keyResult = Self.run(ctx, endpoint: Self.keyEndpoint)
        async let creditsResult = Self.run(ctx, endpoint: Self.creditsEndpoint)
        let (k, c) = await (keyResult, creditsResult)
        return try Self.combine(key: k, credits: c, subjectId: ctx.subjectId, adapterId: adapterId, now: ctx.now)
    }

    private static func run(_ ctx: QuotaFetchContext, endpoint: String) async -> Result<QuotaHTTPResponse, QuotaFetchError> {
        do {
            let r = try await ctx.transport.get(URL(string: "https://\(endpoint)")!, bearer: ctx.credential)
            if let e = QuotaHTTP.error(for: r, endpoint: endpoint, now: ctx.now) { return .failure(e) }
            return .success(r)
        } catch let e as QuotaFetchError {
            return .failure(e)
        } catch {
            return .failure(QuotaFetchError(kind: .network, detail: "\(endpoint): \((error as NSError).code)"))
        }
    }

    /// Pure; exposed for tests.
    static func combine(key: Result<QuotaHTTPResponse, QuotaFetchError>,
                        credits: Result<QuotaHTTPResponse, QuotaFetchError>,
                        subjectId: QuotaSubjectID, adapterId: String = "openrouter.key+credits",
                        now: Date) throws -> QuotaFetchOutcome {
        var pools: [QuotaPool] = []
        var errors: [QuotaFetchError] = []
        var offset: TimeInterval?
        // A /key answer with limit == null is a complete answer that yields no pool.
        var keyAnswered = false, creditsAnswered = false

        switch key {
        case .success(let r):
            offset = QuotaHTTP.clockOffset(r, now: now)
            do {
                if let p = try parseKey(r.body, subjectId: subjectId, adapterId: adapterId, now: now) { pools.append(p) }
                keyAnswered = true
            } catch let e as QuotaFetchError { errors.append(e) }
        case .failure(let e): errors.append(e)
        }
        switch credits {
        case .success(let r):
            offset = offset ?? QuotaHTTP.clockOffset(r, now: now)
            do {
                pools.append(try parseCredits(r.body, subjectId: subjectId, adapterId: adapterId, now: now))
                creditsAnswered = true
            } catch let e as QuotaFetchError { errors.append(e) }
        case .failure(let e): errors.append(e)
        }

        guard keyAnswered || creditsAnswered else {
            // Both failed: surface the most actionable error (auth first).
            let order: [QuotaError.Kind] = [.unauthorized, .forbidden, .rateLimited, .server, .notFound]
            throw order.lazy.compactMap { k in errors.first { $0.kind == k } }.first ?? errors[0]
        }
        let prov = officialProvenance(adapterId: adapterId, endpoint: "openrouter.ai/api/v1/{key,credits}")
        let snap = UpstreamQuotaSnapshot(
            id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
            serverClockOffset: offset, plan: nil, pools: pools,
            bindings: pools.map { accountWideBinding($0.id) }, accountAvailable: nil)
        return QuotaFetchOutcome(snapshot: snap, isComplete: keyAnswered && creditsAnswered, partialErrors: errors)
    }

    static func parseKey(_ data: Data, subjectId: QuotaSubjectID, adapterId: String = "openrouter.key+credits",
                         now: Date) throws -> QuotaPool? {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: keyEndpoint)
        guard let d = obj["data"] as? [String: Any] else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "missing data \(keyEndpoint)")
        }
        // limit == null (or absent) → the key has no spend cap: no pool, never "100% left".
        guard let limit = QuotaDecimalParser.parse(d["limit"]) else { return nil }
        let remaining = QuotaDecimalParser.parse(d["limit_remaining"])
        // With a periodic reset (`limit_reset` set) `usage` is lifetime spend and
        // does not line up with the cap; only trust it for a lifetime cap.
        let periodic = (d["limit_reset"] as? String).map { !$0.isEmpty } ?? false
        let used = (periodic || remaining != nil) ? nil : QuotaDecimalParser.parse(d["usage"])
        return QuotaPool(
            id: QuotaPoolKey(subject: subjectId, family: "key-limit"), subjectId: subjectId,
            kind: .spendCap, unit: .currency(code: "USD"), vendorLabel: "Key limit",
            amounts: QuotaAmounts(total: limit, used: used, remaining: remaining),
            windows: [], verdict: nil, unlimited: false,
            provenance: officialProvenance(adapterId: adapterId, endpoint: keyEndpoint), observedAt: now)
    }

    static func parseCredits(_ data: Data, subjectId: QuotaSubjectID, adapterId: String = "openrouter.key+credits",
                             now: Date) throws -> QuotaPool {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: creditsEndpoint)
        guard let d = obj["data"] as? [String: Any],
              let total = QuotaDecimalParser.parse(d["total_credits"]),
              let usage = QuotaDecimalParser.parse(d["total_usage"]) else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "missing data.total_credits")
        }
        // A prepaid balance: no total/used, so no percent is ever derived from it.
        return QuotaPool(
            id: QuotaPoolKey(subject: subjectId, family: "account-credits"), subjectId: subjectId,
            kind: .prepaidBalance, unit: .currency(code: "USD"), vendorLabel: "Credits",
            amounts: QuotaAmounts(remaining: total - usage),
            windows: [], verdict: nil, unlimited: false,
            provenance: officialProvenance(adapterId: adapterId, endpoint: creditsEndpoint), observedAt: now)
    }
}

// MARK: - Claude subscription (OAuth): active usage query + passive headers

/// [T-quota-claude-subscription] Claude Pro / Max usage windows, from two
/// sources that write the SAME pools and windows:
/// - passive: the `anthropic-ratelimit-unified-*` headers on every reply of an
///   OAuth instance (no extra request);
/// - active: `GET https://api.anthropic.com/api/oauth/usage`. The official CLI
///   uses it for `/usage`; it is not publicly documented, so it is labelled
///   `providerDashboardAPI` / `observedClient`, never "official API".
///
/// Pools (keys shared by both sources, so they merge per window):
/// - `subscription`, windows `5h` and `7d`: the account's limit, bound
///   account-wide (scope not stated upstream → assumedSubjectWide);
/// - `model:opus` / `model:sonnet` (`7d`): a per-model-family weekly limit,
///   bound to that family, named upstream (explicitUpstream);
/// - `product:oauth_apps` (`7d`): the limit for third-party OAuth apps, a
///   product pool (never bound to a model).
struct ClaudeSubscriptionQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "claude.oauth-usage" }
    var vendor: QuotaVendor { .claudeSubscription }
    static let endpoint = "api.anthropic.com/api/oauth/usage"
    /// Also this adapter's refresh interval: an active query is skipped while
    /// any source updated the data within it (product decision 2026-09-27).
    static let freshWindow: TimeInterval = 5 * 60

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability {
        d.isOAuth ? .activeQuery(source: .providerDashboardAPI, confidence: .observedClient)
                  : .unsupported(.providerTypeUnsupported)
    }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        var headers = ctx.extraHeaders
        headers["anthropic-beta"] = "oauth-2025-04-20"
        let r = try await ctx.transport.get(URL(string: "https://\(Self.endpoint)")!, bearer: ctx.credential,
                                            headers: headers)
        if let e = QuotaHTTP.error(for: r, endpoint: Self.endpoint, now: ctx.now) { throw e }
        let snap = try Self.parseUsage(r.body, subjectId: ctx.subjectId, adapterId: adapterId, now: ctx.now)
        return QuotaFetchOutcome(snapshot: snap, isComplete: true)
    }

    // MARK: Window mapping (shared by both sources)

    struct WindowSpec: Equatable {
        var poolFamily: String
        var windowId: String
        var duration: TimeInterval?
        var target: QuotaPoolBinding.Target
        var evidence: QuotaPoolBinding.Evidence
    }

    /// Maps an upstream window name — API key (`five_hour`, `seven_day_opus`)
    /// or header segment (`5h`, `7d`, `7d_opus`) — to its pool / window.
    static func spec(for rawName: String) -> WindowSpec {
        let n = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        let family: String? = {
            for f in ["opus", "sonnet", "haiku"] where n.hasSuffix("_" + f) { return f }
            return nil
        }()
        let base: String = {
            if n.hasPrefix("five_hour") || n.hasPrefix("5h") { return "5h" }
            if n.hasPrefix("seven_day") || n.hasPrefix("7d") { return "7d" }
            return n
        }()
        let duration: TimeInterval? = base == "5h" ? 5 * 3600 : (base == "7d" ? 7 * 86400 : nil)
        if let family {
            return WindowSpec(poolFamily: "model:\(family)", windowId: base, duration: duration,
                              target: .modelFamily(pattern: "claude-\(family)*"), evidence: .explicitUpstream)
        }
        if n.contains("oauth_apps") {
            return WindowSpec(poolFamily: "product:oauth_apps", windowId: base, duration: duration,
                              target: .product(name: "oauth_apps"), evidence: .explicitUpstream)
        }
        return WindowSpec(poolFamily: "subscription", windowId: base, duration: duration,
                          target: .subject, evidence: .assumedSubjectWide)
    }

    /// Utilization as a 0…1 fraction. The API reports percent (0–100) and the
    /// headers a fraction (0–1). A header value above 2 is read as a percent
    /// too, so a format change degrades to the right number, not 100×.
    static func fraction(_ value: Decimal, isPercent: Bool) -> Decimal {
        if isPercent || value > 2 { return value / 100 }
        return value
    }

    // MARK: Active: /api/oauth/usage

    /// `{"five_hour":{"utilization":6.0,"resets_at":"2025-11-04T04:59:59.94+00:00"},
    ///   "seven_day":{…}, "seven_day_opus":{…}|null, "seven_day_oauth_apps":null, "extra_usage":{…}}`
    static func parseUsage(_ data: Data, subjectId: QuotaSubjectID, adapterId: String = "claude.oauth-usage",
                           now: Date) throws -> UpstreamQuotaSnapshot {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        let prov = QuotaProvenance(source: .providerDashboardAPI, confidence: .observedClient,
                                   adapterId: adapterId, endpoint: endpoint, relayHost: nil)
        var windows: [(WindowSpec, QuotaWindow)] = []
        for (key, value) in obj {
            guard key.hasPrefix("five_hour") || key.hasPrefix("seven_day"),
                  let w = value as? [String: Any],
                  let u = QuotaDecimalParser.parse(w["utilization"]) else { continue }
            let spec = spec(for: key)
            let resets = (w["resets_at"] as? String).flatMap(parseISODate)
            windows.append((spec, QuotaWindow(id: spec.windowId, duration: spec.duration, isRolling: true,
                                              reportedUsedFraction: fraction(u, isPercent: true),
                                              resetsAt: resets, observedAt: now, provenance: prov)))
        }
        guard !windows.isEmpty else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no usage windows in \(endpoint)")
        }
        return snapshot(windows, subjectId: subjectId, provenance: prov, verdict: nil, now: now)
    }

    // MARK: Passive: anthropic-ratelimit-unified-* headers

    static let headerPrefix = "anthropic-ratelimit-unified-"

    /// nil when the response carries no unified window. `headers` keys are
    /// matched case-insensitively.
    static func parseHeaders(_ headers: [String: String], subjectId: QuotaSubjectID,
                             adapterId: String = "claude.oauth-usage", now: Date) -> UpstreamQuotaSnapshot? {
        var byWindow: [String: [String: String]] = [:]
        var overallStatus: String?
        for (rawKey, value) in headers {
            let key = rawKey.lowercased()
            guard key.hasPrefix(headerPrefix) else { continue }
            let rest = String(key.dropFirst(headerPrefix.count))
            if rest == "status" { overallStatus = value.lowercased(); continue }
            for field in ["utilization", "reset", "status"] where rest.hasSuffix("-" + field) {
                let window = String(rest.dropLast(field.count + 1))
                byWindow[window, default: [:]][field] = value
            }
        }
        let prov = QuotaProvenance(source: .officialHeaders, confidence: .observedClient,
                                   adapterId: adapterId, endpoint: "response headers", relayHost: nil)
        var windows: [(WindowSpec, QuotaWindow)] = []
        for (name, fields) in byWindow {
            guard let raw = fields["utilization"], let u = QuotaDecimalParser.parse(string: raw) else { continue }
            let spec = spec(for: name)
            let resets = fields["reset"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
            windows.append((spec, QuotaWindow(id: spec.windowId, duration: spec.duration, isRolling: true,
                                              reportedUsedFraction: fraction(u, isPercent: false),
                                              resetsAt: resets, observedAt: now, provenance: prov)))
        }
        guard !windows.isEmpty else { return nil }
        let verdict: QuotaPool.Verdict? = {
            switch overallStatus {
            case "allowed": return .allowed
            case "allowed_warning": return .warning
            case "rejected": return .rejected
            default: return nil
            }
        }()
        return snapshot(windows, subjectId: subjectId, provenance: prov, verdict: verdict, now: now)
    }

    // MARK: Shared assembly

    private static func snapshot(_ windows: [(WindowSpec, QuotaWindow)], subjectId: QuotaSubjectID,
                                 provenance: QuotaProvenance, verdict: QuotaPool.Verdict?,
                                 now: Date) -> UpstreamQuotaSnapshot {
        var pools: [QuotaPoolKey: QuotaPool] = [:]
        var bindings: [QuotaPoolBinding] = []
        for (spec, window) in windows.sorted(by: { $0.1.id < $1.1.id }) {
            let key = QuotaPoolKey(subject: subjectId, family: spec.poolFamily)
            if pools[key] == nil {
                pools[key] = QuotaPool(
                    id: key, subjectId: subjectId, kind: .usageWindow, unit: .percentOnly,
                    vendorLabel: spec.poolFamily == "subscription" ? "Claude subscription" : spec.poolFamily,
                    amounts: nil, windows: [],
                    // The overall status describes the account limit, not a family pool.
                    verdict: spec.poolFamily == "subscription" ? verdict : nil,
                    unlimited: false, provenance: provenance, observedAt: now)
                bindings.append(QuotaPoolBinding(poolKey: key, target: spec.target, evidence: spec.evidence))
            }
            pools[key]?.windows.append(window)
        }
        return UpstreamQuotaSnapshot(id: UUID(), subjectId: subjectId, provenance: provenance, capturedAt: now,
                                     serverClockOffset: nil, plan: nil,
                                     pools: pools.values.sorted { $0.id.rawValue < $1.id.rawValue },
                                     bindings: bindings, accountAvailable: nil)
    }

    static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Official usage / balance pages

/// [T-quota-console-links] The vendor's own page for usage or balance, opened
/// in the in-app browser from the quota section and sheet. It is offered even
/// where Minis cannot query the figure itself (API-key Claude / OpenAI, Kimi
/// Code, Xiaomi MiMo), so the user still gets there in one tap. Fixed per
/// vendor: never built from a user-supplied base URL, and nil for relays and
/// unknown hosts.
enum QuotaConsoleLink {
    static func url(for d: QuotaInstanceDescriptor) -> URL? {
        let host = d.customHost ?? ""
        let raw: String?
        switch QuotaVendorDetector.vendor(for: d) {
        case .codexSubscription: raw = "https://chatgpt.com/codex/cloud/settings/analytics#usage"
        case .openAIPlatform: raw = "https://platform.openai.com/usage"
        case .claudeSubscription: raw = "https://claude.ai/settings/usage"
        case .anthropicPlatform: raw = "https://console.anthropic.com/settings/billing"
        case .deepSeek: raw = "https://platform.deepseek.com/usage"
        case .moonshot:
            raw = host.hasSuffix(".ai") ? "https://platform.moonshot.ai/console/account"
                                        : "https://platform.moonshot.cn/console/account"
        // Kept next to the quota windows: the top-up pack balance is only
        // shown on the site.
        case .kimiCode: raw = "https://www.kimi.com/code"
        case .openRouter: raw = "https://openrouter.ai/settings/credits"
        case .xiaomiMiMo: raw = "https://platform.xiaomimimo.com/console/plan-manage"
        // [ISS-031] The pages the official Token Plan FAQ links from "How to
        // check Token Plan usage": Billing > Token Plan (international) and
        // Subscription billing > Plan usage (China).
        case .miniMax:
            raw = host == "api.minimaxi.com" ? "https://platform.minimaxi.com/console/usage"
                                             : "https://platform.minimax.io/user-center/payment/token-plan"
        // [ISS-031] The "console" link of opencode.ai/docs/go ("You can track
        // your current usage in the console").
        case .openCode: raw = "https://opencode.ai/auth"
        case .siliconFlow, .geminiAPIKey, .geminiCodeAssist, .antigravity, .xAI, .githubCopilot,
             .customRelay, .unknown:
            raw = nil
        }
        return raw.flatMap(URL.init(string:))
    }
}

// MARK: - Per-vendor rate policy / capability failure

extension QuotaRefreshPolicy {
    /// A subscription (Claude / ChatGPT OAuth) refreshes on a 5-minute window
    /// measured from the last update by EITHER source — a reply's headers or an
    /// active query (product decision 2026-09-27); with no data yet the first
    /// query runs at once. Every other vendor keeps the 10-minute interval.
    static func forVendor(_ vendor: QuotaVendor) -> QuotaRefreshPolicy {
        var p = QuotaRefreshPolicy()
        switch vendor {
        case .claudeSubscription: p.normalInterval = ClaudeSubscriptionQuotaAdapter.freshWindow
        case .codexSubscription: p.normalInterval = CodexSubscriptionQuotaAdapter.freshWindow
        default: break
        }
        return p
    }
}

enum QuotaCapabilityRules {
    static func isSubscription(_ v: QuotaVendor) -> Bool { v == .claudeSubscription || v == .codexSubscription }

    /// Whether a failed query marks the endpoint unusable (24 h pause, user
    /// re-check allowed). A 404 or an unreadable answer always does. For a
    /// subscription, 401 / 403 do too: its chat requests work with the same
    /// token, so the refusal is about the undocumented usage endpoint, not the
    /// credential — and passive header updates would otherwise clear the error
    /// and re-arm a query every 5 minutes against an endpoint that refuses.
    static func failureDisablesEndpoint(_ kind: QuotaError.Kind, vendor: QuotaVendor) -> Bool {
        switch kind {
        case .notFound, .unsupportedResponse: return true
        case .unauthorized, .forbidden: return isSubscription(vendor)
        default: return false
        }
    }
}

// MARK: - ChatGPT / Codex subscription (OAuth): active usage query + passive headers

/// [T-quota-codex-subscription] Same shape as Claude's: two sources, one set
/// of pools.
/// - passive: `x-codex-primary-*` / `x-codex-secondary-*` headers on every
///   Codex reply (used percent, window minutes, reset);
/// - active: `GET https://chatgpt.com/backend-api/wham/usage`, which the Codex
///   CLI uses for its status line. Undocumented → `providerDashboardAPI` /
///   `observedClient`.
///
/// Pools:
/// - `codex`: windows keyed by duration (300 min → `5h`, 10080 → `7d`,
///   otherwise `<n>m`), account-wide; the primary pool may be shared by the
///   credential, never assumed to be the current model's (design §1.3);
/// - `model:<name>`: an `additional_rate_limits` entry, named upstream, bound
///   to that model;
/// - `credits`: the credit balance when the account has one (unit: credits,
///   no percent).
struct CodexSubscriptionQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "codex.wham-usage" }
    var vendor: QuotaVendor { .codexSubscription }
    static let endpoint = "chatgpt.com/backend-api/wham/usage"
    static let freshWindow: TimeInterval = 5 * 60
    static let headerPrefix = "x-codex-"

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability {
        d.isOAuth ? .activeQuery(source: .providerDashboardAPI, confidence: .observedClient)
                  : .unsupported(.providerTypeUnsupported)
    }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        let r = try await ctx.transport.get(URL(string: "https://\(Self.endpoint)")!, bearer: ctx.credential,
                                            headers: ctx.extraHeaders)
        if let e = QuotaHTTP.error(for: r, endpoint: Self.endpoint, now: ctx.now) { throw e }
        let snap = try Self.parseUsage(r.body, subjectId: ctx.subjectId, adapterId: adapterId, now: ctx.now)
        return QuotaFetchOutcome(snapshot: snap, isComplete: true)
    }

    static func windowId(minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10080: return "7d"
        case let m where m % 1440 == 0: return "\(m / 1440)d"
        case let m where m % 60 == 0: return "\(m / 60)h"
        default: return "\(minutes)m"
        }
    }

    // MARK: Active: /backend-api/wham/usage

    /// `{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
    ///   "primary_window":{"used_percent":42,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1735693200},
    ///   "secondary_window":{…}},"credits":{"has_credits":true,"unlimited":false,"balance":"12.5"},
    ///   "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{…}}}]}`
    static func parseUsage(_ data: Data, subjectId: QuotaSubjectID, adapterId: String = "codex.wham-usage",
                           now: Date) throws -> UpstreamQuotaSnapshot {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        let prov = QuotaProvenance(source: .providerDashboardAPI, confidence: .observedClient,
                                   adapterId: adapterId, endpoint: endpoint, relayHost: nil)
        var groups: [(family: String, target: QuotaPoolBinding.Target, evidence: QuotaPoolBinding.Evidence,
                      windows: [QuotaWindow], verdict: QuotaPool.Verdict?)] = []

        func windows(of rateLimit: [String: Any]) -> [QuotaWindow] {
            ["primary_window", "secondary_window"].compactMap { key in
                guard let w = rateLimit[key] as? [String: Any],
                      let used = QuotaDecimalParser.parse(w["used_percent"]) else { return nil }
                let seconds = QuotaDecimalParser.parse(w["limit_window_seconds"])
                    .map { NSDecimalNumber(decimal: $0).intValue }
                let id = seconds.map { windowId(minutes: $0 / 60) } ?? (key == "primary_window" ? "primary" : "secondary")
                let reset: Date? = {
                    if let at = QuotaDecimalParser.parse(w["reset_at"]) {
                        return Date(timeIntervalSince1970: NSDecimalNumber(decimal: at).doubleValue)
                    }
                    if let after = QuotaDecimalParser.parse(w["reset_after_seconds"]) {
                        return now.addingTimeInterval(NSDecimalNumber(decimal: after).doubleValue)
                    }
                    return nil
                }()
                return QuotaWindow(id: id, duration: seconds.map(TimeInterval.init), isRolling: true,
                                   reportedUsedFraction: used / 100, resetsAt: reset, observedAt: now, provenance: prov)
            }
        }
        func verdict(of rateLimit: [String: Any]) -> QuotaPool.Verdict? {
            if (rateLimit["limit_reached"] as? Bool) == true || (rateLimit["allowed"] as? Bool) == false { return .rejected }
            return rateLimit["allowed"] as? Bool == true ? .allowed : nil
        }

        if let rl = obj["rate_limit"] as? [String: Any] {
            let ws = windows(of: rl)
            if !ws.isEmpty { groups.append(("codex", .subject, .assumedSubjectWide, ws, verdict(of: rl))) }
        }
        for extra in (obj["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            guard let name = extra["limit_name"] as? String, !name.isEmpty,
                  let rl = extra["rate_limit"] as? [String: Any] else { continue }
            let ws = windows(of: rl)
            if !ws.isEmpty {
                groups.append(("model:\(QuotaModelKey.normalize(name))", .model(key: QuotaModelKey.normalize(name)),
                               .explicitUpstream, ws, verdict(of: rl)))
            }
        }

        var pools: [QuotaPool] = []
        var bindings: [QuotaPoolBinding] = []
        for g in groups {
            let key = QuotaPoolKey(subject: subjectId, family: g.family)
            pools.append(QuotaPool(id: key, subjectId: subjectId, kind: .usageWindow, unit: .percentOnly,
                                   vendorLabel: g.family == "codex" ? "ChatGPT subscription" : g.family,
                                   amounts: nil, windows: g.windows, verdict: g.verdict, unlimited: false,
                                   provenance: prov, observedAt: now))
            bindings.append(QuotaPoolBinding(poolKey: key, target: g.target, evidence: g.evidence))
        }
        if let credits = obj["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true {
            let unlimited = (credits["unlimited"] as? Bool) == true
            let balance = QuotaDecimalParser.parse(credits["balance"])
            if balance != nil || unlimited {
                let key = QuotaPoolKey(subject: subjectId, family: "credits")
                pools.append(QuotaPool(id: key, subjectId: subjectId, kind: .prepaidBalance, unit: .credits(name: nil),
                                       vendorLabel: "Credits", amounts: balance.map { QuotaAmounts(remaining: $0) },
                                       windows: [], verdict: nil, unlimited: unlimited, provenance: prov, observedAt: now))
                bindings.append(QuotaPoolBinding(poolKey: key, target: .subject, evidence: .assumedSubjectWide))
            }
        }
        guard !pools.isEmpty else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no rate_limit windows in \(endpoint)")
        }
        let plan = (obj["plan_type"] as? String).map { QuotaPlan(rawId: $0, tierName: nil) }
        return UpstreamQuotaSnapshot(id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
                                     serverClockOffset: nil, plan: plan, pools: pools, bindings: bindings,
                                     accountAvailable: nil)
    }

    // MARK: Passive: x-codex-* headers

    /// `x-codex-primary-used-percent: 12.0`, `x-codex-primary-window-minutes: 300`,
    /// `x-codex-primary-reset-at: <epoch>` or `x-codex-primary-reset-after-seconds: <n>`,
    /// same for `secondary`. nil when the reply carries none.
    static func parseHeaders(_ headers: [String: String], subjectId: QuotaSubjectID,
                             adapterId: String = "codex.wham-usage", now: Date) -> UpstreamQuotaSnapshot? {
        var h: [String: String] = [:]
        for (k, v) in headers { h[k.lowercased()] = v }
        let prov = QuotaProvenance(source: .officialHeaders, confidence: .observedClient,
                                   adapterId: adapterId, endpoint: "response headers", relayHost: nil)
        var windows: [QuotaWindow] = []
        for slot in ["primary", "secondary"] {
            guard let raw = h["x-codex-\(slot)-used-percent"], let used = QuotaDecimalParser.parse(string: raw) else { continue }
            let minutes = h["x-codex-\(slot)-window-minutes"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let reset: Date? = {
                if let at = h["x-codex-\(slot)-reset-at"].flatMap({ TimeInterval($0) }) { return Date(timeIntervalSince1970: at) }
                if let after = h["x-codex-\(slot)-reset-after-seconds"].flatMap({ TimeInterval($0) }) {
                    return now.addingTimeInterval(after)
                }
                return nil
            }()
            windows.append(QuotaWindow(id: minutes.map(windowId(minutes:)) ?? slot,
                                       duration: minutes.map { TimeInterval($0 * 60) }, isRolling: true,
                                       reportedUsedFraction: used / 100, resetsAt: reset, observedAt: now,
                                       provenance: prov))
        }
        guard !windows.isEmpty else { return nil }
        let key = QuotaPoolKey(subject: subjectId, family: "codex")
        let pool = QuotaPool(id: key, subjectId: subjectId, kind: .usageWindow, unit: .percentOnly,
                             vendorLabel: "ChatGPT subscription", amounts: nil, windows: windows, verdict: nil,
                             unlimited: false, provenance: prov, observedAt: now)
        return UpstreamQuotaSnapshot(id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
                                     serverClockOffset: nil, plan: nil, pools: [pool],
                                     bindings: [QuotaPoolBinding(poolKey: key, target: .subject, evidence: .assumedSubjectWide)],
                                     accountAvailable: nil)
    }
}

// MARK: - Kimi Code subscription (usage windows)

/// [ISS-031] Kimi Code membership usage, from `GET {base}/usages` with base
/// `https://api.kimi.com/coding/v1` (overseas `api.kimi.ai`). Source: the
/// official MoonshotAI/kimi-cli `/usage` command (src/kimi_cli/ui/shell/usage.py,
/// commit 9ab1286), which sends only `Authorization: Bearer <api key or OAuth
/// token>`. Not in Kimi's public API docs -> `providerDashboardAPI` /
/// `observedClient`, never "official API".
///
/// NOT verified against a real reply: the field names below are what the CLI
/// parses, and the CLI already accepts several spellings, so parsing is lenient
/// and `responseShape` (names + types only) is logged on the first fetch.
///
/// `{"usage": {limit, used | remaining, name/title, reset_at|resetAt|reset_time|resetTime
///   | reset_in|resetIn|ttl|window},
///   "limits": [{"detail": {...same...}, "window": {"duration": 300, "timeUnit": "MINUTE"},
///               "name"/"title"/"scope"}]}`
///
/// One pool (`subscription`, account-wide) with one window per entry, like
/// Claude's / Codex's: the worst window decides the status. A window carries
/// the upstream counts (total = limit, used / remaining as given); its percent
/// is computed from them. An entry without a positive limit and a used or
/// remaining count is skipped - the CLI shows such a row as "0 used", Minis
/// shows nothing rather than an invented number.
///
/// Requests go out with Minis's own User-Agent (the transport sets none): Kimi
/// Code's terms forbid spoofing the client identity.
struct KimiCodeQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "kimicode.usages" }
    var vendor: QuotaVendor { .kimiCode }
    static let hosts = ["api.kimi.com", "api.kimi.ai"]

    static func endpoint(host: String) -> String { "\(host)/coding/v1/usages" }

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability {
        .activeQuery(source: .providerDashboardAPI, confidence: .observedClient)
    }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        let host = ctx.descriptor.vendorHost(among: Self.hosts)
        let endpoint = Self.endpoint(host: host)
        let url = ctx.endpointOverride ?? URL(string: "https://\(endpoint)")!
        let r = try await ctx.transport.get(url, bearer: ctx.credential, headers: ctx.extraHeaders)
        if let e = QuotaHTTP.error(for: r, endpoint: endpoint, now: ctx.now) { throw e }
        let shape = (try? JSONSerialization.jsonObject(with: r.body)).map { QuotaResponseShape.describe($0) }
        let snap = try Self.parse(r.body, endpoint: endpoint, subjectId: ctx.subjectId, adapterId: adapterId,
                                  now: ctx.now)
        return QuotaFetchOutcome(snapshot: snap, isComplete: true, responseShape: shape)
    }

    static func parse(_ data: Data, endpoint: String = "api.kimi.com/coding/v1/usages",
                      subjectId: QuotaSubjectID, adapterId: String = "kimicode.usages",
                      now: Date) throws -> UpstreamQuotaSnapshot {
        let obj = try QuotaHTTP.jsonObject(data, endpoint: endpoint)
        let prov = QuotaProvenance(source: .providerDashboardAPI, confidence: .observedClient,
                                   adapterId: adapterId, endpoint: endpoint, relayHost: nil)
        var windows: [QuotaWindow] = []
        var usedIds: [String: Int] = [:]
        func uniqueId(_ id: String) -> String {
            let n = (usedIds[id] ?? 0) + 1
            usedIds[id] = n
            return n == 1 ? id : "\(id) #\(n)"
        }

        // Top-level `usage`: the CLI's default label for it is "Weekly limit".
        if let usage = obj["usage"] as? [String: Any], let amounts = amounts(usage) {
            let name = label(usage)
            windows.append(QuotaWindow(id: uniqueId(name ?? "weekly"), duration: nil,
                                       calendarPeriod: name == nil ? .week : nil, isRolling: false,
                                       amounts: amounts, resetsAt: resetsAt(usage, now: now),
                                       observedAt: now, provenance: prov))
        }
        // `limits[]`: each with its own window; `detail` holds the counts when present.
        for (index, element) in ((obj["limits"] as? [Any]) ?? []).enumerated() {
            guard let item = element as? [String: Any] else { continue }
            let detail = (item["detail"] as? [String: Any]) ?? item
            guard let amounts = amounts(detail) else { continue }
            let window = (item["window"] as? [String: Any]) ?? [:]
            let seconds = durationSeconds(window: window, item: item, detail: detail)
            let id = label(item) ?? label(detail)
                ?? seconds.map { CodexSubscriptionQuotaAdapter.windowId(minutes: Int($0 / 60)) }
                ?? "limit \(index + 1)"
            windows.append(QuotaWindow(id: uniqueId(id), duration: seconds, isRolling: seconds != nil,
                                       amounts: amounts, resetsAt: resetsAt(detail, now: now),
                                       observedAt: now, provenance: prov))
        }
        guard !windows.isEmpty else {
            throw QuotaFetchError(kind: .unsupportedResponse,
                                  detail: "no usable usage/limits in \(endpoint); shape=\(QuotaResponseShape.describe(obj))")
        }
        let key = QuotaPoolKey(subject: subjectId, family: "subscription")
        let pool = QuotaPool(id: key, subjectId: subjectId, kind: .usageWindow,
                             unit: .custom(name: "Kimi Code usage"), vendorLabel: "Kimi Code",
                             amounts: nil, windows: windows, verdict: nil, unlimited: false,
                             provenance: prov, observedAt: now)
        return UpstreamQuotaSnapshot(id: UUID(), subjectId: subjectId, provenance: prov, capturedAt: now,
                                     serverClockOffset: nil, plan: nil, pools: [pool],
                                     bindings: [QuotaPoolBinding(poolKey: key, target: .subject,
                                                                 evidence: .assumedSubjectWide)],
                                     accountAvailable: nil)
    }

    /// limit + used, or limit + remaining (the CLI derives used = limit - remaining).
    /// nil when there is no positive limit or neither count, or a count is negative.
    static func amounts(_ d: [String: Any]) -> QuotaAmounts? {
        guard let limit = QuotaDecimalParser.parse(d["limit"]), limit > 0 else { return nil }
        let used = QuotaDecimalParser.parse(d["used"])
        let remaining = QuotaDecimalParser.parse(d["remaining"])
        guard used != nil || remaining != nil else { return nil }
        if let used, used < 0 { return nil }
        if let remaining, remaining < 0 { return nil }
        return QuotaAmounts(total: limit, used: used, remaining: remaining)
    }

    static func label(_ d: [String: Any]) -> String? {
        for key in ["name", "title", "scope"] {
            if let s = d[key] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return String(t.prefix(40)) }
            }
        }
        return nil
    }

    /// `duration` + `timeUnit` (MINUTE / HOUR / DAY; anything else = seconds,
    /// as in the CLI), looked up in window, then item, then detail.
    static func durationSeconds(window: [String: Any], item: [String: Any], detail: [String: Any]) -> TimeInterval? {
        let raw = QuotaDecimalParser.parse(window["duration"]) ?? QuotaDecimalParser.parse(item["duration"])
            ?? QuotaDecimalParser.parse(detail["duration"])
        guard let raw, raw > 0 else { return nil }
        let value = NSDecimalNumber(decimal: raw).doubleValue
        let unit = ((window["timeUnit"] ?? item["timeUnit"] ?? detail["timeUnit"]) as? String ?? "").uppercased()
        if unit.contains("MINUTE") { return value * 60 }
        if unit.contains("HOUR") { return value * 3600 }
        if unit.contains("DAY") { return value * 86400 }
        return value
    }

    /// An absolute reset (ISO 8601 - the CLI trims nanoseconds - or epoch
    /// seconds / milliseconds), else a relative one in seconds.
    static func resetsAt(_ d: [String: Any], now: Date) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            guard let v = d[key], !(v is NSNull) else { continue }
            if let s = v as? String {
                if let date = parseISO(s) { return date }
                if let n = Double(s.trimmingCharacters(in: .whitespaces)) { return epoch(n) }
                continue
            }
            if let n = QuotaDecimalParser.parse(v) { return epoch(NSDecimalNumber(decimal: n).doubleValue) }
        }
        for key in ["reset_in", "resetIn", "ttl", "window"] {
            guard let n = QuotaDecimalParser.parse(d[key]) else { continue }
            let seconds = NSDecimalNumber(decimal: n).doubleValue
            if seconds > 0 { return now.addingTimeInterval(seconds) }
        }
        return nil
    }

    private static func epoch(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }

    /// "2025-12-23T05:24:18.443553353Z" included: the fraction is cut to
    /// milliseconds first, which ISO8601DateFormatter accepts.
    static func parseISO(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let fraction = s[s.index(after: dot)..<end]
            if fraction.count > 3 { s = String(s[..<dot]) + "." + fraction.prefix(3) + String(s[end...]) }
        }
        return ClaudeSubscriptionQuotaAdapter.parseISODate(s)
    }
}

// BEGIN QuotaResponseShape
/// [ISS-031] A response's structure with every value replaced by its type:
/// `{"limits":[{"detail":{"limit":int,"used":int},...}]x2,"usage":{...}}`.
/// Object keys are kept (they are the schema); strings, numbers and booleans
/// never appear. Bounded in depth and length so a large reply cannot flood
/// the log.
enum QuotaResponseShape {
    static func describe(_ value: Any, depth: Int = 0) -> String {
        let text = shape(value, depth: depth)
        return text.count > 1200 ? String(text.prefix(1200)) + "..." : text
    }

    private static func shape(_ value: Any, depth: Int) -> String {
        if depth > 5 { return "..." }
        switch value {
        case let dict as [String: Any]:
            let parts = dict.keys.sorted().prefix(30).map { "\"\($0)\":\(shape(dict[$0]!, depth: depth + 1))" }
            return "{" + parts.joined(separator: ",") + (dict.count > 30 ? ",..." : "") + "}"
        case let array as [Any]:
            guard let first = array.first else { return "[]" }
            return "[" + shape(first, depth: depth + 1) + "]x\(array.count)"
        case is NSNull:
            return "null"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "bool" }
            return CFNumberIsFloatType(n) ? "num" : "int"
        case let s as String:
            return ClaudeSubscriptionQuotaAdapter.parseISODate(s) != nil || KimiCodeQuotaAdapter.parseISO(s) != nil
                ? "iso-date" : (Double(s) != nil ? "numeric-string" : "string")
        default:
            return "?"
        }
    }
}
// END QuotaResponseShape

// MARK: - Relays (sub2api / New API / OpenAI-compatible billing)

/// [T-quota-relay-probe] Which relay family answered, and so which endpoint
/// to use next time.
enum RelayKind: String, Codable, Sendable, CaseIterable {
    case sub2api, newAPI, openAIBilling

    var displayName: String {
        switch self {
        case .sub2api: return "Sub2API"
        case .newAPI: return "New API"
        case .openAIBilling: return "OpenAI-compatible billing"
        }
    }
    var path: String {
        switch self {
        case .sub2api: return "/v1/usage"
        case .newAPI: return "/api/usage/token"
        case .openAIBilling: return "/v1/dashboard/billing/subscription"
        }
    }
    var adapterId: String { "relay.\(rawValue)" }
    static func from(adapterId: String) -> RelayKind? {
        guard adapterId.hasPrefix("relay.") else { return nil }
        return RelayKind(rawValue: String(adapterId.dropFirst("relay.".count)))
    }
}

/// [T-quota-relay-probe] A custom relay's own balance / key quota.
///
/// What a relay reports is its LEDGER for this key or account — what the user
/// pays the relay — not the upstream vendor's balance, so every pool is
/// `relayAccountLedger` / `thirdParty` and the UI says so.
///
/// The type is not configured; it is detected by probing the documented
/// endpoints in order, identified by their data structure:
/// 1. Sub2API `GET /v1/usage` — a boolean `isValid` marks it. Modes:
///    `quota_limited` (quota.remaining / limit / used), wallet (`balance`),
///    subscription (`remaining`, -1 = unlimited). USD.
/// 2. New API `GET /api/usage/token` — `data.total_granted / total_used /
///    total_available / unlimited_quota` in the relay's quota units (shown as
///    units: the per-dollar rate is a per-site setting, never assumed).
/// 3. OpenAI-compatible `GET /v1/dashboard/billing/subscription` (+ `/usage`):
///    `hard_limit_usd` (≥ 1e8 = unlimited), `total_usage` in cents (One API,
///    older New API).
/// CLIProxyAPI has no endpoint a client key can read (its quota API needs the
/// management key), so it probes as "none found".
///
/// Requests go only to the relay the instance already sends its chats to,
/// with the same key; the root is the base URL without its trailing `/v1`.
struct RelayQuotaAdapter: ProviderQuotaAdapter {
    var adapterId: String { "relay.probe" }
    var vendor: QuotaVendor { .customRelay }
    static let unlimitedSentinelUSD: Decimal = 100_000_000

    func capability(for d: QuotaInstanceDescriptor) -> QuotaCapability {
        guard d.customHost != nil, Self.root(of: d) != nil else { return .unsupported(.unknownVendor) }
        return .activeQuery(source: .relayAccountLedger, confidence: .thirdParty)
    }

    /// Base URL without trailing "/" and "/v1" (case kept for the path).
    static func root(of d: QuotaInstanceDescriptor) -> URL? {
        guard var s = d.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }

    func fetch(_ ctx: QuotaFetchContext) async throws -> QuotaFetchOutcome {
        guard let root = Self.root(of: ctx.descriptor) else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "relay has no usable base URL")
        }
        let order = ctx.relayKindHint.map { [$0] } ?? RelayKind.allCases
        var errors: [QuotaFetchError] = []
        for kind in order {
            do {
                let snap = try await query(kind, root: root, ctx: ctx)
                return QuotaFetchOutcome(snapshot: snap, isComplete: true, partialErrors: errors, relayKind: kind)
            } catch let e as QuotaFetchError {
                // A known type that now refuses is reported as is (key rejected,
                // rate limited…). While probing, move on to the next family.
                if ctx.relayKindHint != nil { throw e }
                errors.append(e)
            }
        }
        // Every family refused the key → it is the key (or the relay's policy),
        // not a missing endpoint. Anything else → no endpoint found.
        if let first = errors.first,
           errors.allSatisfy({ $0.kind == .unauthorized || $0.kind == .forbidden }) {
            throw first
        }
        let checked = order.map(\.path).joined(separator: ", ")
        throw QuotaFetchError(kind: .notFound, detail: "no balance endpoint on this relay (checked \(checked))")
    }

    private func query(_ kind: RelayKind, root: URL, ctx: QuotaFetchContext) async throws -> UpstreamQuotaSnapshot {
        func get(_ path: String) async throws -> QuotaHTTPResponse {
            let url = root.appendingPathComponent(String(path.dropFirst()))
            let r = try await ctx.transport.get(url, bearer: ctx.credential, headers: ctx.extraHeaders)
            if let e = QuotaHTTP.error(for: r, endpoint: path, now: ctx.now) { throw e }
            return r
        }
        let host = root.host ?? ""
        switch kind {
        case .sub2api:
            return try Self.parseSub2API(try await get(kind.path).body, subjectId: ctx.subjectId, relayHost: host, now: ctx.now)
        case .newAPI:
            return try Self.parseNewAPI(try await get(kind.path).body, subjectId: ctx.subjectId, relayHost: host, now: ctx.now)
        case .openAIBilling:
            let sub = try await get(kind.path).body
            let usage = try? await get("/v1/dashboard/billing/usage").body
            return try Self.parseOpenAIBilling(subscription: sub, usage: usage, subjectId: ctx.subjectId,
                                               relayHost: host, now: ctx.now)
        }
    }

    private static func provenance(_ kind: RelayKind, host: String) -> QuotaProvenance {
        QuotaProvenance(source: .relayAccountLedger, confidence: .thirdParty, adapterId: kind.adapterId,
                        endpoint: kind.path, relayHost: host)
    }

    private static func snapshot(_ pool: QuotaPool, kind: RelayKind, subjectId: QuotaSubjectID, host: String,
                                 now: Date) -> UpstreamQuotaSnapshot {
        UpstreamQuotaSnapshot(id: UUID(), subjectId: subjectId, provenance: provenance(kind, host: host), capturedAt: now,
                              serverClockOffset: nil, plan: nil, pools: [pool],
                              bindings: [QuotaPoolBinding(poolKey: pool.id, target: .subject, evidence: .assumedSubjectWide)],
                              accountAvailable: nil)
    }

    private static func object(_ data: Data, _ kind: RelayKind) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "not JSON at \(kind.path)")
        }
        return obj
    }

    // MARK: Sub2API

    static func parseSub2API(_ data: Data, subjectId: QuotaSubjectID, relayHost: String, now: Date) throws -> UpstreamQuotaSnapshot {
        let obj = try object(data, .sub2api)
        guard obj["isValid"] is Bool else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no isValid: not Sub2API")
        }
        let prov = provenance(.sub2api, host: relayHost)
        let keyUsed = ((obj["usage"] as? [String: Any])?["total"] as? [String: Any]).flatMap { QuotaDecimalParser.parse($0["actual_cost"]) }
        let key = QuotaPoolKey(subject: subjectId, family: "relay")
        var pool = QuotaPool(id: key, subjectId: subjectId, kind: .prepaidBalance, unit: .currency(code: "USD"),
                             vendorLabel: "Sub2API", amounts: nil, windows: [], verdict: nil, unlimited: false,
                             provenance: prov, observedAt: now)
        if (obj["isValid"] as? Bool) == false { pool.verdict = .rejected }
        if (obj["mode"] as? String) == "quota_limited" {
            let q = obj["quota"] as? [String: Any] ?? [:]
            let limit = QuotaDecimalParser.parse(q["limit"])
            let remaining = QuotaDecimalParser.parse(q["remaining"]).map { max(0, $0) }
            let used = obj["quota"] != nil ? QuotaDecimalParser.parse(q["used"]) : keyUsed
            pool.kind = limit != nil ? .spendCap : .prepaidBalance
            pool.vendorLabel = "Sub2API key quota"
            pool.amounts = QuotaAmounts(total: limit, used: used, remaining: remaining)
        } else if obj.keys.contains("balance") {
            pool.vendorLabel = "Sub2API wallet"
            pool.amounts = QuotaAmounts(remaining: QuotaDecimalParser.parse(obj["balance"]), breakdown: [])
        } else {
            let remaining = QuotaDecimalParser.parse(obj["remaining"])
            pool.vendorLabel = "Sub2API subscription"
            if let r = remaining, r < 0 {
                pool.unlimited = true
                pool.amounts = keyUsed.map { QuotaAmounts(used: $0) }
            } else {
                pool.amounts = QuotaAmounts(used: keyUsed, remaining: remaining)
            }
        }
        guard pool.amounts?.remaining != nil || pool.amounts?.total != nil || pool.unlimited else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "Sub2API usage without amounts")
        }
        return snapshot(pool, kind: .sub2api, subjectId: subjectId, host: relayHost, now: now)
    }

    // MARK: New API

    static func parseNewAPI(_ data: Data, subjectId: QuotaSubjectID, relayHost: String, now: Date) throws -> UpstreamQuotaSnapshot {
        let obj = try object(data, .newAPI)
        guard let d = obj["data"] as? [String: Any], d["total_granted"] != nil || d["total_available"] != nil else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no data.total_granted: not New API")
        }
        let granted = QuotaDecimalParser.parse(d["total_granted"])
        let used = QuotaDecimalParser.parse(d["total_used"])
        let available = QuotaDecimalParser.parse(d["total_available"])
        let unlimited = (d["unlimited_quota"] as? Bool) == true || (granted.map { $0 < 0 } ?? false)
        let key = QuotaPoolKey(subject: subjectId, family: "relay")
        let pool = QuotaPool(id: key, subjectId: subjectId, kind: .allowance, unit: .custom(name: "quota"),
                             vendorLabel: (d["name"] as? String).map { "New API · \($0)" } ?? "New API token quota",
                             amounts: unlimited ? QuotaAmounts(used: used)
                                                : QuotaAmounts(total: granted, used: used, remaining: available),
                             windows: [], verdict: nil, unlimited: unlimited,
                             provenance: provenance(.newAPI, host: relayHost), observedAt: now)
        return snapshot(pool, kind: .newAPI, subjectId: subjectId, host: relayHost, now: now)
    }

    // MARK: OpenAI-compatible billing

    static func parseOpenAIBilling(subscription: Data, usage: Data?, subjectId: QuotaSubjectID, relayHost: String,
                                   now: Date) throws -> UpstreamQuotaSnapshot {
        func unwrap(_ o: [String: Any]) -> [String: Any] { (o["data"] as? [String: Any]) ?? o }
        let sub = unwrap(try object(subscription, .openAIBilling))
        let use = usage.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map(unwrap) ?? [:]
        let key = QuotaPoolKey(subject: subjectId, family: "relay")
        var pool = QuotaPool(id: key, subjectId: subjectId, kind: .spendCap, unit: .currency(code: "USD"),
                             vendorLabel: "Relay billing", amounts: nil, windows: [], verdict: nil, unlimited: false,
                             provenance: provenance(.openAIBilling, host: relayHost), observedAt: now)
        let usedUSD: Decimal? = QuotaDecimalParser.parse(use["total_usage"]).map { $0 / 100 }
            ?? QuotaDecimalParser.parse(use["used_usd"])
        if let balance = QuotaDecimalParser.parse(sub["balance"]) {
            pool.kind = .prepaidBalance
            pool.amounts = QuotaAmounts(used: usedUSD, remaining: balance)
        } else if let hard = QuotaDecimalParser.parse(sub["hard_limit_usd"]) {
            if hard >= unlimitedSentinelUSD {
                pool.unlimited = true
                pool.amounts = usedUSD.map { QuotaAmounts(used: $0) }
            } else {
                pool.amounts = QuotaAmounts(total: hard, used: usedUSD, remaining: usedUSD.map { max(0, hard - $0) })
            }
        } else {
            throw QuotaFetchError(kind: .unsupportedResponse, detail: "no hard_limit_usd / balance: not a billing API")
        }
        return snapshot(pool, kind: .openAIBilling, subjectId: subjectId, host: relayHost, now: now)
    }
}
