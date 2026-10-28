//
//  ProviderQuotaSection.swift
//  MinisApp
//
//  [T-provider-quota] "Quota" section of the provider detail page (design
//  §9.2): the upstream balance / quota of this instance's account, from the
//  vendor itself — never Minis's own token counts.
//
//  - Shared pools appear once, labelled as shared by every model on the account.
//  - Amounts are shown in their own unit; a prepaid balance has no bar and no
//    percent.
//  - Windows are listed side by side with their own reset time, never summed.
//  - Colour carries state only: no green, so "nothing shown" never reads as
//    "plenty left".
//

import SwiftUI

struct ProviderQuotaSection: View {
    let instance: ProviderInstance
    /// [T-quota-console-links] Owned by the detail view, which presents the
    /// in-app browser: a .sheet on a Section inside a Form has no stable host
    /// ([T-thinking-rules-ui-fix]).
    @Binding var consoleURL: URL?

    @ObservedObject private var quota = QuotaStore.shared
    @State private var blockedMessage: String?

    var body: some View {
        let display = quota.display(for: instance)
        if display != .hidden {
            Section {
                content(display)
                if let url = QuotaConsoleLink.url(for: QuotaStore.descriptor(for: instance)) {
                    QuotaConsoleLinkRow(url: url) { consoleURL = url }
                }
            } header: {
                header(display)
            } footer: {
                footer(display)
            }
            // [T-quota-attention-refresh] Refreshes on open when due, and keeps
            // the watched interval while the page is open.
            .quotaWatch(instanceId: instance.id, reason: "detailAppeared")
        }
    }

    // MARK: - Header / footer

    @ViewBuilder
    private func header(_ display: QuotaInstanceDisplay) -> some View {
        HStack {
            Text("Quota")
            Spacer()
            if canRefresh(display) {
                if quota.isRefreshing(instance.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await manualRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Refresh quota"))
                }
            }
        }
    }

    @ViewBuilder
    private func footer(_ display: QuotaInstanceDisplay) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .pools(let sid) = display, let subject = quota.subject(sid) {
                let pools = quota.pools(of: sid)
                if let newest = pools.map(\.observedAt).max(), let source = pools.first?.provenance.source {
                    Text(String(format: String(localized: "%@ · updated %@"),
                                QuotaFormat.source(source), Self.relative(newest)))
                }
                if let err = subject.lastRefresh?.error {
                    Text(String(format: String(localized: "Last refresh failed: %@"), Self.message(for: err)))
                        .foregroundStyle(.orange)
                }
                let sharing = quota.sharingInstanceIds(for: instance.id)
                    .compactMap { ProviderConfigStore.shared.instance(for: $0)?.label }
                if !sharing.isEmpty {
                    Text(String(format: String(localized: "Same account as “%@” — the same balance, don't add them up"),
                                sharing.joined(separator: "”, “")))
                }
            }
            if let blockedMessage {
                Text(blockedMessage)
            }
            if let detection = quota.relayDetection(for: instance) {
                Text(Self.relayDetectionText(detection))
            }
        }
    }

    /// [T-quota-relay-probe] "Relay type: Sub2API · /v1/usage (detected 2 h ago)"
    /// or what was checked when nothing answered.
    static func relayDetectionText(_ d: (text: String, found: Bool, at: Date)) -> String {
        d.found
            ? String(format: String(localized: "Relay type: %@ (detected %@)"), d.text, relative(d.at))
            : String(format: String(localized: "No balance endpoint found on this relay (%@, %@)"), d.text, relative(d.at))
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ display: QuotaInstanceDisplay) -> some View {
        switch display {
        case .hidden:
            EmptyView()
        case .unsupported(let reason):
            Text(Self.message(for: reason))
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking balance…")
                    .foregroundStyle(.secondary)
            }
        case .empty:
            Text("The provider reported no balance or quota for this key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let err):
            Label {
                Text(Self.message(for: err))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.orange)
        case .pools(let sid):
            let pools = quota.pools(of: sid)
            let sharedKeys = Set(quota.bindings(of: sid).filter { $0.target == .subject }.map(\.poolKey))
            if !sharedKeys.isEmpty {
                Label {
                    Text("Shared by all models on this account")
                } icon: {
                    Image(systemName: "person.2")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(pools) { pool in
                QuotaPoolRow(pool: pool, status: quota.poolStatus(pool))
            }
        }
    }

    // MARK: - Actions

    private func canRefresh(_ display: QuotaInstanceDisplay) -> Bool {
        switch display {
        case .hidden: return false
        case .unsupported(let reason): return reason == .capabilityProbeFailed
        default: return true
        }
    }

    private func manualRefresh() async {
        quota.noteViewed(instanceId: instance.id)
        let result = await quota.refresh(instanceId: instance.id, forced: true, reason: "manual")
        switch result {
        case .blocked(.serverCooldown(let until)):
            blockedMessage = String(format: String(localized: "The provider asked to wait until %@."),
                                    until.formatted(date: .omitted, time: .shortened))
        case .blocked(.forcedDebounce):
            blockedMessage = String(localized: "Just refreshed — try again in a few seconds.")
        default:
            blockedMessage = nil
        }
    }

    // MARK: - Text

    static func poolName(_ pool: QuotaPool) -> String {
        switch pool.kind {
        case .prepaidBalance:
            if case .currency(let code) = pool.unit {
                return String(format: String(localized: "Balance · %@"), code)
            }
            return pool.vendorLabel ?? String(localized: "Balance")
        case .spendCap: return pool.vendorLabel ?? String(localized: "Spend limit")
        case .allowance: return pool.vendorLabel ?? String(localized: "Allowance")
        case .usageWindow: return pool.vendorLabel ?? String(localized: "Usage limit")
        case .rateLimit: return pool.vendorLabel ?? String(localized: "Rate limit")
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func message(for reason: QuotaSubject.UnsupportedReason) -> String {
        switch reason {
        case .vendorHasNoQuotaAPI:
            return String(localized: "This provider doesn't offer a balance or quota lookup.")
        case .unknownVendor:
            return String(localized: "Balance lookup isn't available for this endpoint.")
        case .providerTypeUnsupported:
            return String(localized: "Balance lookup isn't supported for this provider yet.")
        case .passiveNotImplemented:
            return String(localized: "This provider only reports quota alongside replies; showing it isn't supported yet.")
        case .capabilityProbeFailed:
            return String(localized: "This endpoint didn't answer the balance lookup. Minis will check again tomorrow, or tap refresh to check now.")
        }
    }

    static func message(for err: QuotaError) -> String {
        switch err.kind {
        case .unauthorized:
            return String(localized: "The API key was rejected. Update the key to see the balance.")
        case .forbidden:
            return String(localized: "This key isn't allowed to read the balance.")
        case .notFound:
            return String(localized: "This endpoint doesn't offer a balance lookup.")
        case .rateLimited:
            return String(localized: "The provider is rate limiting balance lookups. Minis will try again later.")
        case .server:
            return String(localized: "The provider's server returned an error. Minis will try again later.")
        case .network:
            return String(localized: "Couldn't reach the provider.")
        case .badResponse, .unsupportedResponse:
            return String(localized: "The provider returned an unexpected answer.")
        case .missingCredential:
            return String(localized: "Add an API key to see the balance.")
        }
    }
}

// MARK: - Shared quota visuals (section row, detail sheet)

extension QuotaTone {
    /// Text / accent colour. Green only for `.healthy` (a reliable percent that
    /// is fine); an unmeasured balance stays neutral.
    var color: Color {
        switch self {
        case .normal: return .secondary
        case .healthy: return .green
        case .caution: return .orange
        case .critical: return .red
        case .muted: return Color(UIColor.tertiaryLabel)
        }
    }

    /// Emphasised amount text: neutral stays primary, warnings keep their colour.
    var amountColor: Color {
        switch self {
        case .normal, .healthy: return .primary
        default: return color
        }
    }
}

extension QuotaStatus {
    var localizedName: String {
        switch self {
        case .available: return String(localized: "Available")
        case .low: return String(localized: "Low")
        case .rateLimited: return String(localized: "Rate limited")
        case .exhausted: return String(localized: "Used up")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

/// A progress bar drawn ONLY from a reliable fraction (QuotaBarRules).
struct QuotaUsageBar: View {
    let fraction: Double
    let tone: QuotaTone

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(UIColor.tertiarySystemFill))
                Capsule().fill(tone.color)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Coloured status word ("Low", "Used up", "Stale").
struct QuotaStatusChip: View {
    let status: PoolStatus

    var body: some View {
        let tone = QuotaToneRules.tone(status)
        let label = status.freshness == .stale && tone != .muted
            ? String(format: String(localized: "%@ · stale"), status.status.localizedName)
            : (status.freshness == .expired ? String(localized: "Expired") : status.status.localizedName)
        HStack(spacing: 4) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tone == .normal ? Color.secondary : tone.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.color.opacity(tone == .normal ? 0.08 : 0.12), in: Capsule())
        .fixedSize()
    }
}

/// One window of a pool: label, used %, bar (only with a reliable percent), reset.
struct QuotaWindowLine: View {
    let window: QuotaWindow
    let pool: QuotaPool

    var body: some View {
        let util = window.utilization(poolKind: pool.kind, unlimited: pool.unlimited)
        let fraction = QuotaBarRules.windowFraction(window, in: pool)
        let tone = QuotaToneRules.tone(status: util.map { QuotaStatusRules.status(for: $0, thresholds: QuotaThresholds()) } ?? .unknown,
                                       freshness: .fresh, reliablePercent: util != nil)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(QuotaFormat.windowLabel(window))
                    .font(.caption.weight(.medium))
                Spacer()
                if let util {
                    Text(QuotaFormat.percentUsedText(util.percent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tone == .healthy ? Color.secondary : tone.color)
                } else if let r = window.amounts?.remaining {
                    Text(String(format: String(localized: "%@ left"), QuotaFormat.amount(r, unit: pool.unit)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction {
                QuotaUsageBar(fraction: fraction, tone: tone)
            }
            if let reset = window.resetsAt {
                Text(String(format: String(localized: "Resets %@"), ProviderQuotaSection.relative(reset)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pool row

/// A pool in the provider page's Quota section, and (with `detailed`) a full
/// card in QuotaDetailSheet: the same view, so both read the same numbers.
struct QuotaPoolRow: View {
    let pool: QuotaPool
    let status: PoolStatus
    var detailed: Bool = false

    var body: some View {
        let tone = QuotaToneRules.tone(status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(ProviderQuotaSection.poolName(pool))
                    .font(.subheadline)
                if detailed {
                    QuotaStatusChip(status: status)
                }
                Spacer()
                if status.freshness != .expired, let headline = headlineAmount {
                    Text(headline)
                        .font((detailed ? Font.title3 : Font.body).monospacedDigit().weight(.semibold))
                        .foregroundStyle(tone.amountColor)
                }
            }
            if status.freshness == .expired {
                Text("Data expired — refresh to update")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                details(tone: tone)
            }
        }
        .padding(.vertical, 2)
        .opacity(status.freshness == .stale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func details(tone: QuotaTone) -> some View {
        if let amounts = pool.amounts {
            if pool.kind == .spendCap || pool.kind == .allowance, let total = amounts.total {
                capLine(amounts: amounts, total: total, tone: tone)
            }
            if detailed, pool.kind == .prepaidBalance {
                Text("Prepaid balance — no total cap, so no percentage is shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let parts = QuotaFormat.breakdown(amounts, unit: pool.unit) {
                Text(parts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if pool.verdict == .rejected {
            Text("The provider says this account can't serve requests right now.")
                .font(.caption)
                .foregroundStyle(.red)
        }
        ForEach(pool.windows) { window in
            QuotaWindowLine(window: window, pool: pool)
        }
        if pool.unlimited {
            Text("No limit")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The pool's main figure: remaining balance / remaining allowance.
    private var headlineAmount: String? {
        guard let a = pool.amounts else { return nil }
        if let r = a.remaining { return QuotaFormat.amount(r, unit: pool.unit) }
        if let t = a.total, let u = a.used { return QuotaFormat.amount(t - u, unit: pool.unit) }
        return nil
    }

    @ViewBuilder
    private func capLine(amounts: QuotaAmounts, total: Decimal, tone: QuotaTone) -> some View {
        let used = amounts.used ?? amounts.remaining.map { total - $0 }
        if let used {
            let util = amounts.computedUtilization(kind: pool.kind, unlimited: pool.unlimited)
            VStack(alignment: .leading, spacing: 3) {
                if let fraction = QuotaBarRules.poolFraction(pool) {
                    QuotaUsageBar(fraction: fraction, tone: tone)
                }
                Text(String(format: String(localized: "%@ of %@ used"),
                            QuotaFormat.amount(used, unit: pool.unit), QuotaFormat.amount(total, unit: pool.unit))
                     + (util.map { " · " + QuotaFormat.percent($0.percent) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Official usage page link

/// [T-quota-console-links] "Usage on the provider's website" + its host, in
/// the Settings row-icon style; tapping opens the in-app browser (the host
/// view presents MinisLinkPreviewView).
struct QuotaConsoleLinkRow: View {
    let url: URL
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                BackupActionIcon(systemName: "safari.fill", tint: .blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage on the provider's website")
                        .foregroundStyle(Color(UIColor.label))
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint(Text("Opens in the in-app browser"))
    }
}
