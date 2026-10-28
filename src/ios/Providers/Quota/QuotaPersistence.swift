//
//  QuotaPersistence.swift
//  MinisApp
//
//  [T-provider-quota] The store's on-disk shape, its keyed single-flight, the
//  manual-mapping validity rule, and display formatting. Foundation only: the
//  standalone tests compile this with QuotaModels / QuotaRules / QuotaAdapters.
//

import Foundation

// MARK: - On-disk file

/// `Application Support/Quota/store.json`. Device-local only: the directory is
/// excluded from device backup, the Minis backup exporter never reads it, and
/// iCloud sync has no record type for it.
///
/// Holds structured, secret-free data only: pools, bindings, subject
/// bookkeeping (a masked key label, never the key), capability records,
/// manual mappings and snapshot digests. No response bodies, headers or
/// credentials are persisted.
struct QuotaStoreFile: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = QuotaStoreFile.currentVersion
    var subjects: [QuotaSubject] = []
    var pools: [QuotaPool] = []
    var bindings: [QuotaPoolBinding] = []
    var capabilities: [QuotaCapabilityRecord] = []
    var mappings: [QuotaManualMapping] = []
    var summaries: [QuotaSnapshotSummary] = []
    /// Instance id → the subject it last resolved to.
    var instanceSubjects: [String: QuotaSubjectID] = [:]

    init() {}

    static func encode(_ file: QuotaStoreFile) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(file)
    }

    /// nil for an unreadable or future-version file. The caller then starts
    /// empty: quota data is a cache and is re-fetched, never worth a crash.
    static func decode(_ data: Data) -> QuotaStoreFile? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(QuotaStoreFile.self, from: data),
              file.version <= currentVersion else { return nil }
        return file
    }
}

// MARK: - Single flight

/// One in-flight operation per key. Concurrent callers with the same key (two
/// instances sharing one account, a tick racing a manual refresh) await the
/// same task instead of each issuing a request.
@MainActor
final class QuotaSingleFlight<Key: Hashable, Value> {
    private var inFlight: [Key: Task<Value, Never>] = [:]

    init() {}

    func isRunning(_ key: Key) -> Bool { inFlight[key] != nil }

    func run(_ key: Key, _ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor in await operation() }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}

// MARK: - Manual mapping validity

enum QuotaMappingRules {
    /// A mapping is never silently re-pointed; when something it names is
    /// gone, it is reported invalid so the user can fix or delete it.
    static func validity(_ m: QuotaManualMapping,
                         instanceExists: Bool,
                         instanceModelIds: Set<String>,
                         instanceSubject: QuotaSubjectID?,
                         pools: [QuotaPoolKey: QuotaPool]) -> QuotaMappingValidity {
        guard instanceExists else { return .instanceMissing }
        guard instanceModelIds.contains(m.modelId) else { return .modelMissing }
        guard let pool = pools[m.poolKey], pool.subjectId == instanceSubject else { return .poolMissing }
        return .valid
    }

    /// The binding a valid mapping contributes, marked as the user's own.
    static func binding(for m: QuotaManualMapping) -> QuotaPoolBinding {
        QuotaPoolBinding(poolKey: m.poolKey, target: .model(key: m.modelId), evidence: .userManualMapping)
    }
}

// MARK: - Formatting

enum QuotaFormat {
    /// Amount in the pool's own unit. Currencies via the system currency style
    /// (symbol + minor digits); nothing is converted.
    static func amount(_ value: Decimal, unit: QuotaUnit, locale: Locale = .current) -> String {
        switch unit {
        case .currency(let code):
            return value.formatted(.currency(code: code).locale(locale))
        case .credits(let name):
            return "\(number(value, locale: locale)) \(name ?? String(localized: "credits"))"
        case .requests:
            return String(format: String(localized: "%@ requests"), number(value, locale: locale))
        case .tokens:
            return String(format: String(localized: "%@ tokens"), compact(value, locale: locale))
        case .percentOnly:
            return percent(value)
        case .rateLimit:
            return number(value, locale: locale)
        case .custom(let name):
            return "\(number(value, locale: locale)) \(name)"
        }
    }

    static func number(_ value: Decimal, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    static func compact(_ value: Decimal, locale: Locale = .current) -> String {
        value.formatted(.number.notation(.compactName).locale(locale))
    }

    /// "81%": whole numbers, one decimal below 10% so a small value is not
    /// shown as 0%.
    /// Rounded in Decimal (half up), so 4.25 is 4.3% on every device rather
    /// than whatever the binary double happens to round to.
    static func percent(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, (value > 0 && value < 10) ? 1 : 0, .plain)
        return "\(rounded.quotaString)%"
    }

    /// [T-quota-percent-used] Every vendor's percent is shown as usage:
    /// "44% used". Claude (`utilization`) and ChatGPT / Codex (`used_percent`,
    /// codex-rs protocol.rs: "…of the window that has been consumed") both
    /// report what is used, so one wording fits all.
    static func percentUsedText(_ usedPercent: Decimal) -> String {
        String(format: String(localized: "%@ used"), percent(usedPercent))
    }

    static func role(_ role: QuotaAmounts.Part.Role) -> String {
        switch role {
        case .granted: return String(localized: "Granted")
        case .toppedUp: return String(localized: "Topped up")
        case .voucher: return String(localized: "Voucher")
        case .cash: return String(localized: "Cash")
        case .other(let s): return s
        }
    }

    /// "Granted ¥10.00 · Topped up ¥100.00".
    static func breakdown(_ amounts: QuotaAmounts, unit: QuotaUnit, locale: Locale = .current) -> String? {
        guard !amounts.breakdown.isEmpty else { return nil }
        return amounts.breakdown
            .map { "\(role($0.role)) \(amount($0.amount, unit: unit, locale: locale))" }
            .joined(separator: " · ")
    }

    /// Window id as shown: the stable id is already short ("5h", "7d", "day").
    static func windowLabel(_ w: QuotaWindow) -> String {
        switch w.calendarPeriod {
        case .day: return String(localized: "Daily")
        case .week: return String(localized: "Weekly")
        case .month: return String(localized: "Monthly")
        case nil: return w.id
        }
    }

    static func source(_ s: QuotaSource) -> String {
        switch s {
        case .officialQuery: return String(localized: "Official API")
        case .officialHeaders: return String(localized: "Official response headers")
        case .officialStreamEvent: return String(localized: "Official stream event")
        case .officialErrorSignal: return String(localized: "Official error response")
        case .providerDashboardAPI: return String(localized: "Provider dashboard API")
        case .compatibleInterface: return String(localized: "Compatible interface (unverified)")
        case .relayAccountLedger: return String(localized: "Relay account quota (relay-reported)")
        case .derived: return String(localized: "Estimated")
        }
    }

    /// Short headline for compact places (picker section header): unit-true,
    /// with a meaning prefix, never a percent for a prepaid balance.
    static func shortText(pool: QuotaPool, status: PoolStatus, locale: Locale = .current) -> String? {
        switch pool.kind {
        case .prepaidBalance:
            guard let r = pool.amounts?.remaining else { return nil }
            return String(format: String(localized: "Balance %@"), amount(r, unit: pool.unit, locale: locale))
        case .spendCap, .allowance, .usageWindow:
            if let u = status.utilization {
                let window = status.decidingWindowId.map { "\($0) " } ?? ""
                return String(format: String(localized: "Account %@"),
                              window + percentUsedText(u.percent))
            }
            if let r = pool.amounts?.remaining {
                return String(format: String(localized: "%@ left"), amount(r, unit: pool.unit, locale: locale))
            }
            return nil
        case .rateLimit:
            return nil
        }
    }
}

// MARK: - Model picker hints (design §9.5, P2)

/// What the model picker may say about quota. Deliberately quiet: nothing
/// unless there is real data AND a warning, never a percent for a prepaid
/// balance, never an "available" / green state.
enum QuotaPickerHintRules {
    enum Hint: Equatable {
        /// The tightest constraint is a pool bound to THIS model (upstream-named
        /// or user-mapped). `detail` is e.g. "5h 92%"; nil when no percent exists.
        case modelSpecific(status: QuotaStatus, detail: String?, isManual: Bool)
    }

    /// Provider section rows (`entryRow`): model-specific warnings only; the
    /// shared account is already shown on the section header.
    static func modelRow(_ v: ModelQuotaView) -> Hint? {
        guard v.effective.isWarning, let d = v.deciding, !d.isShared else { return nil }
        return .modelSpecific(status: d.status.status, detail: detail(d.status), isManual: d.isManual)
    }

    /// [T-quota-group-member-pill] Model Group member rows (picker group
    /// rows and the Model Group settings page). These rows have no provider
    /// header, and so no other way to reach the provider's quota. They show one
    /// short figure after the model name, which opens the quota sheet:
    /// - the model's OWN pool first (upstream-named or manually mapped), else
    ///   the account's pool — the tightest of the chosen kind;
    /// - remaining percent ("10%") when a reliable percent exists, else the
    ///   remaining amount in its unit ("$1.12", "CN¥36.51");
    /// - nothing without real, unexpired data.
    struct MemberPill: Equatable {
        var text: String
        var tone: QuotaTone
        var poolKey: QuotaPoolKey
        var isModelSpecific: Bool
        var isManual: Bool
        /// true = `text` is a used percent; false = a remaining amount.
        var isPercent: Bool
        /// [T-quota-tag-level] Yellow / red tag.
        var level: QuotaLevel = .normal
        /// [T-composer-hint-compact] The bare used percent behind `text` when
        /// `isPercent`, for surfaces that drop the "used" wording.
        var usedPercent: Decimal? = nil
    }

    static func memberPill(_ v: ModelQuotaView, pools: [QuotaPoolKey: QuotaPool],
                           locale: Locale = .current) -> MemberPill? {
        func usable(_ b: ModelQuotaView.BoundPool) -> Bool {
            b.status.status != .unknown && b.status.freshness != .expired
                && pools[b.poolKey].map { $0.kind != .rateLimit } == true
        }
        func tightest(_ list: [ModelQuotaView.BoundPool]) -> ModelQuotaView.BoundPool? {
            list.max { a, b in
                if a.status.status != b.status.status { return a.status.status < b.status.status }
                return (a.status.utilization?.percent ?? -1) < (b.status.utilization?.percent ?? -1)
            }
        }
        // [ISS-035] Same exception as the section header: an emptied money
        // balance does not stand in for an account that still holds another.
        let known = QuotaHeadline.withoutSpentCurrencyBalances(
            v.bound.filter(usable), pool: { pools[$0.poolKey] }, status: { $0.status.status })
        guard let chosen = tightest(known.filter { !$0.isShared }) ?? tightest(known.filter(\.isShared)),
              let pool = pools[chosen.poolKey] else { return nil }
        let status = chosen.status
        let text: String
        let isPercent: Bool
        let usedPercent = status.utilization?.percent
        if let u = status.utilization {
            text = QuotaFormat.percentUsedText(u.percent)
            isPercent = true
        } else if let r = pool.amounts?.remaining {
            text = QuotaFormat.amount(r, unit: pool.unit, locale: locale)
            isPercent = false
        } else if let t = pool.amounts?.total, let used = pool.amounts?.used {
            text = QuotaFormat.amount(t - used, unit: pool.unit, locale: locale)
            isPercent = false
        } else {
            return nil
        }
        return MemberPill(text: text, tone: QuotaToneRules.pillTone(status), poolKey: chosen.poolKey,
                          isModelSpecific: !chosen.isShared, isManual: chosen.isManual, isPercent: isPercent,
                          level: QuotaLevelRules.level(v, pools: pools), usedPercent: usedPercent)
    }

    /// Section header: the account's short text, only with real, non-expired data.
    static func headerText(pool: QuotaPool, status: PoolStatus, locale: Locale = .current) -> String? {
        guard status.status != .unknown, status.freshness != .expired else { return nil }
        return QuotaFormat.shortText(pool: pool, status: status, locale: locale)
    }

    private static func detail(_ s: PoolStatus) -> String? {
        guard let u = s.utilization else { return nil }
        return (s.decidingWindowId.map { "\($0) " } ?? "") + QuotaFormat.percent(u.percent)
    }
}

// MARK: - Composer placeholder quota segment  [T-quota-composer-hint]

/// The short quota figure appended to the composer's context-usage line
/// ("Context 62% used · 124k / 200k" · "Balance CN¥36.51"). It is shown only
/// when that line is shown (same trigger, same lifetime) and follows the
/// Model Group pill's choice exactly (`memberPill`): the model's own pool
/// first, else its account's; nothing without real, unexpired data.
enum QuotaComposerHintRules {
    struct Segment: Equatable {
        /// "Quota 14% used" / "Balance CN¥36.51" / "$4.20 left".
        var text: String
        /// The figure inside `text`, tinted when `level` is not normal.
        var highlight: String
        var level: QuotaLevel
    }

    static func segment(_ v: ModelQuotaView, pools: [QuotaPoolKey: QuotaPool], now: Date = Date(),
                        freshness: QuotaFreshnessPolicy = QuotaFreshnessPolicy(),
                        locale: Locale = .current) -> Segment? {
        guard let pill = QuotaPickerHintRules.memberPill(v, pools: pools, locale: locale) else { return nil }
        let text: String
        if pill.isPercent, let pool = pools[pill.poolKey],
           let windows = windowsFigure(pool, now: now, freshness: freshness) {
            // [T-quota-composer-windows] A subscription with a 5h AND a 7d limit
            // shows both: "Quota 5h 14% / 7d 32% used".
            // [T-composer-hint-carousel] The quota is its own placeholder line
            // now, so the "used" wording dropped by T-composer-hint-compact is
            // back.
            let used = String(format: String(localized: "%@ used"), windows)
            return Segment(text: "\(String(localized: "Quota")) \(used)", highlight: windows, level: pill.level)
        }
        if pill.isPercent {
            // "%@ used" already carries the meaning; the prefix says whose.
            text = "\(String(localized: "Quota")) \(pill.text)"
        } else if pools[pill.poolKey]?.kind == .prepaidBalance {
            text = String(format: String(localized: "Balance %@"), pill.text)
        } else {
            text = String(format: String(localized: "%@ left"), pill.text)
        }
        return Segment(text: text, highlight: pill.text, level: pill.level)
    }

    /// "5h 14% / 7d 32%": every live window of the pool that has a percent,
    /// shortest first. nil unless there are at least two — a single window
    /// keeps the plain "14% used" wording.
    static func windowsFigure(_ pool: QuotaPool, now: Date,
                              freshness: QuotaFreshnessPolicy = QuotaFreshnessPolicy()) -> String? {
        let rated: [(window: QuotaWindow, percent: Decimal)] = pool.windows.compactMap { w in
            guard freshness.freshness(of: w, now: now) != .expired,
                  let u = w.utilization(poolKind: pool.kind, unlimited: pool.unlimited) else { return nil }
            return (w, u.percent)
        }
        guard rated.count >= 2 else { return nil }
        return rated.sorted { a, b in
            let da = a.window.duration ?? .infinity, db = b.window.duration ?? .infinity
            return da != db ? da < db : a.window.id < b.window.id
        }
        .map { "\($0.window.id) \(QuotaFormat.percent($0.percent))" }
        .joined(separator: " / ")
    }
}

// MARK: - Status → tone, and when a bar may be drawn (quota detail UI)

/// Visual tier for a quota status. The view maps it to a colour; the rule
/// lives here so it is tested once and every surface agrees.
enum QuotaTone: String, Equatable, Sendable {
    /// Available, but nothing measures "how much" (a prepaid balance): neutral,
    /// never green, so "no warning" is not read as "plenty".
    case normal
    /// Available AND backed by a reliable percent: the one case green is used.
    case healthy
    /// Low or rate limited: orange.
    case caution
    /// Exhausted / rejected: red.
    case critical
    /// Unknown or expired data: grey, numbers are not trusted.
    case muted
}

enum QuotaToneRules {
    static func tone(status: QuotaStatus, freshness: QuotaFreshness, reliablePercent: Bool) -> QuotaTone {
        if freshness == .expired { return .muted }
        switch status {
        case .unknown: return .muted
        case .exhausted: return .critical
        case .low, .rateLimited: return .caution
        case .available: return reliablePercent ? .healthy : .normal
        }
    }

    static func tone(_ s: PoolStatus) -> QuotaTone {
        tone(status: s.status, freshness: s.freshness, reliablePercent: s.utilization != nil)
    }

    /// The compact picker pill never goes green; it only turns orange / red
    /// when there is something to warn about.
    static func pillTone(_ s: PoolStatus) -> QuotaTone {
        let t = tone(s)
        return t == .healthy ? .normal : t
    }
}

enum QuotaBarRules {
    /// 0…1 fill for a progress bar, or nil when no reliable percent exists.
    /// Over-100% (overage) draws full; the text still says the real figure.
    static func fraction(_ u: QuotaUtilization?) -> Double? {
        guard let u else { return nil }
        let d = NSDecimalNumber(decimal: u.percent / 100).doubleValue
        guard d.isFinite else { return nil }
        return min(1, max(0, d))
    }

    /// Bar for a pool's own amounts (spend cap / allowance). Never for a prepaid
    /// balance, a rate limit or an unlimited pool — those have no denominator.
    static func poolFraction(_ pool: QuotaPool) -> Double? {
        guard let a = pool.amounts else { return nil }
        return fraction(a.computedUtilization(kind: pool.kind, unlimited: pool.unlimited))
    }

    /// Bar for one window of a pool.
    static func windowFraction(_ w: QuotaWindow, in pool: QuotaPool) -> Double? {
        fraction(w.utilization(poolKind: pool.kind, unlimited: pool.unlimited))
    }
}

// MARK: - "Quota low" warning for the chat's selected model

/// [T-quota-low-dot] Whether the model a chat is on is running low, which turns
/// the nav bar's status dot from green to yellow. Only real, current data from a
/// vendor Minis can query counts; no data never warns.
///
/// Low when any pool bound to the model (its own or its account's):
/// - has a reliable percent and less than `lowRemainingPercent` left;
/// - is a currency spend cap / allowance with less than `lowBalanceUSD` left;
/// - is exhausted or refused by the vendor.
/// Prepaid balances of one account are judged TOGETHER: an account holding
/// ¥36 and $0 (DeepSeek keeps one balance per currency) is not low. Currencies
/// convert at the fixed rates below — an approximate threshold, never shown.
/// [T-quota-tag-level] Three levels, shared by the nav bar dot and the picker
/// tags so they can never disagree:
/// - `.depleted` (red tag): nothing left — a percent at or past 100% used, a
///   currency balance at or below 0, or the vendor refusing the account;
/// - `.low` (yellow tag / yellow dot): under `lowRemainingPercent` left, or
///   under `lowBalanceUSD`;
/// - `.normal`: otherwise, and whenever there is no usable data.
enum QuotaLevel: Int, Comparable, Sendable {
    case normal, low, depleted
    static func < (a: QuotaLevel, b: QuotaLevel) -> Bool { a.rawValue < b.rawValue }
}

enum QuotaLevelRules {
    static let lowRemainingPercent: Decimal = 10
    static let lowBalanceUSD: Decimal = 1
    /// Units of the currency per 1 USD. Deliberately fixed (no live FX): the
    /// rate only places a warning threshold.
    static let unitsPerUSD: [String: Decimal] = ["USD": 1, "CNY": Decimal(string: "7.2")!, "CNH": Decimal(string: "7.2")!]

    static func usd(_ amount: Decimal, currency: String) -> Decimal? {
        unitsPerUSD[currency.uppercased()].map { amount / $0 }
    }

    /// Remaining share of a used percent (stored fractions are normalised: a
    /// reported "remaining" fraction becomes its complement).
    static func remainingPercent(usedPercent: Decimal) -> Decimal { 100 - usedPercent }

    /// Over (status, pool) pairs. Prepaid currency balances of one account are
    /// judged TOGETHER (DeepSeek keeps one balance per currency: ¥36 + $0 is
    /// not low); every other pool on its own; the worst level wins.
    static func level(_ items: [(status: PoolStatus, pool: QuotaPool)]) -> QuotaLevel {
        var worst = QuotaLevel.normal
        var prepaidUSD: Decimal = 0
        var hasPrepaid = false
        for (status, p) in items {
            guard status.status != .unknown, status.freshness != .expired,
                  p.kind != .rateLimit, !p.unlimited else { continue }
            if p.verdict == .rejected { return .depleted }
            if let u = status.utilization {
                let left = remainingPercent(usedPercent: u.percent)
                if left <= 0 { return .depleted }
                if left < lowRemainingPercent { worst = max(worst, .low) }
            }
            guard let remaining = p.amounts?.remaining else {
                if status.status == .exhausted && p.kind != .prepaidBalance { return .depleted }
                continue
            }
            if case .currency(let code) = p.unit, let inUSD = usd(remaining, currency: code) {
                if p.kind == .prepaidBalance {
                    prepaidUSD += inUSD
                    hasPrepaid = true
                } else if inUSD <= 0 {
                    return .depleted
                } else if inUSD < lowBalanceUSD {
                    worst = max(worst, .low)
                }
            } else if remaining <= 0 {
                // Credits / relay quota units: only "nothing left" is judged by
                // amount (no rate to place a $1 threshold); the rest via percent.
                return .depleted
            }
        }
        if hasPrepaid {
            if prepaidUSD <= 0 { return .depleted }
            if prepaidUSD < lowBalanceUSD { worst = max(worst, .low) }
        }
        return worst
    }

    /// The model's bound pools (its own and its account's).
    static func level(_ v: ModelQuotaView, pools: [QuotaPoolKey: QuotaPool]) -> QuotaLevel {
        level(v.bound.compactMap { b in pools[b.poolKey].map { (b.status, $0) } })
    }
}

/// [T-quota-low-dot] The nav bar dot turns yellow at `.low` or worse.
enum QuotaLowRules {
    static let lowRemainingPercent = QuotaLevelRules.lowRemainingPercent
    static let lowBalanceUSD = QuotaLevelRules.lowBalanceUSD
    static let unitsPerUSD = QuotaLevelRules.unitsPerUSD

    static func usd(_ amount: Decimal, currency: String) -> Decimal? { QuotaLevelRules.usd(amount, currency: currency) }

    static func isLow(_ v: ModelQuotaView, pools: [QuotaPoolKey: QuotaPool]) -> Bool {
        QuotaLevelRules.level(v, pools: pools) != .normal
    }
}
