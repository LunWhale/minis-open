//
//  QuotaPickerHints.swift
//  MinisApp
//
//  [T-provider-quota P2] Lightweight quota hints for UnifiedModelPicker
//  (design §9.5). The rules, from QuotaPickerHintRules:
//  - No trailing control is added, and the active / default badges and the
//    provider "Edit" link keep their places.
//  - Section header: the account's short text ("Balance ¥110.00"). This is
//    the only place a shared pool appears, as the account's, never as a
//    model's own.
//  - Model row: only when a pool bound to THIS model (upstream-named or
//    user-mapped) is the tightest constraint and is low / exhausted / rate
//    limited. It is a small icon + a short text at the start of the second
//    line; a manual mapping says so.
//  - No data, stale-expired data or a healthy state shows nothing (no green).
//
//  Each view observes QuotaStore itself, so a quota update redraws the hint
//  and not the whole picker.
//

import SwiftUI

// [T-quota-pill-align] Centre a quota capsule on the CAPITALS of the text
// beside it, not on that text's frame. A text frame reserves descender space,
// so its centre sits below the letters' visual middle, and a capsule taller
// than the capitals then pokes out above them (device screenshot 2026-09-27
// 22:59: capsule 8 px above "OpenAI"'s cap top, 6 px below its baseline).
extension VerticalAlignment {
    private enum QuotaCapCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// Label side: `.alignmentGuide(.quotaCapCenter) { $0.quotaCapCenter }`.
    /// Capsule side: its default (frame centre).
    static let quotaCapCenter = VerticalAlignment(QuotaCapCenter.self)
}

extension ViewDimensions {
    /// Middle of the capital letters of a single-line text: baseline minus half
    /// the cap height. SF's cap height is 0.74 of its ascent (0.705 / 0.952 em),
    /// so this is 0.63 × the first baseline. CJK glyphs centre within 1 px of it.
    var quotaCapCenter: CGFloat { self[.firstTextBaseline] * 0.63 }
}

/// After the provider name in a picker section header.
///
/// [T-quota-badge-ui] A gray capsule ("Balance CN¥36.51 ›") in the same style
/// as the picker's other small tags (the Active badge's type and padding,
/// the modality badges' tertiarySystemFill). The chevron says it opens more:
/// a tap calls `onTap`, and the picker presents QuotaDetailSheet. The pill
/// stays gray; only its text turns orange / red for a warning, never green.
struct QuotaSectionHeaderBadge: View {
    let instanceId: String
    var onTap: (() -> Void)? = nil
    @ObservedObject private var quota = QuotaStore.shared

    var body: some View {
        Group {
            if let head = quota.headline(instanceId: instanceId),
               let text = QuotaPickerHintRules.headerText(pool: head.pool, status: head.status) {
                let tone = QuotaToneRules.pillTone(head.status)
                let level = quota.subjectLevel(instanceId: instanceId)
                Button {
                    onTap?()
                } label: {
                    HStack(spacing: 3) {
                        Text(text)
                            .lineLimit(1)
                        if onTap != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(QuotaTagStyle.foreground(level, normal: tone.color))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(QuotaTagStyle.background(level), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(onTap == nil)
                .fixedSize()
                // [T-quota-pill-align] Centred on the name's frame, a capsule
                // with 1 pt of padding rides ~2 pt high (the frame reserves
                // descender space below the capitals). Shift it down 2 pt: its
                // top then sits level with the name's capitals (rendered at
                // @3x: top 0 px from the cap top). Drawing offset only — the
                // header's layout is unchanged.
                .offset(y: 2)
                .textCase(nil)
                .accessibilityLabel(Text(String(format: String(localized: "Account quota: %@"), text)))
                .accessibilityHint(Text("Shows quota details"))
            }
        }
        .quotaWatch(instanceId: instanceId, reason: "pickerAppeared")
    }
}

/// [T-quota-group-member-pill] After the model name on a Model Group member
/// row (picker group rows, Model Group settings page): the model's own quota
/// if it has one, else its account's, as "10% ›" (remaining) or "$1.12 ›".
/// Group rows have no provider header, so this is their only way to the
/// provider's quota sheet; `onTap` opens it. Smaller than the header pill so
/// the name keeps its room; gray capsule, orange / red text only for a warning.
struct ModelQuotaMemberPill: View {
    let instanceId: String
    let modelId: String
    let onTap: () -> Void
    @ObservedObject private var quota = QuotaStore.shared

    var body: some View {
        let view = quota.modelView(instanceId: instanceId, modelId: modelId)
        Group {
            if let pill = QuotaPickerHintRules.memberPill(view, pools: quota.pools) {
                Button(action: onTap) {
                    HStack(spacing: 2) {
                        if pill.isManual {
                            Image(systemName: "hand.point.up.left.fill")
                                .font(.system(size: 7))
                        }
                        Text(pill.text)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 6, weight: .semibold))
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(QuotaTagStyle.foreground(pill.level, normal: pill.tone.color))
                    // [T-quota-member-pill-padding] 2 pt top/bottom, 5 pt sides: the
                    // same proportions as the picker's Active badge beside it (≈15 pt
                    // tall). With no vertical padding (T-quota-pill-align) the 9 pt
                    // text sat in an 11 pt capsule that read as squashed. Still
                    // within the model name's line height, so the row keeps its
                    // height (31 pt rendered before and after).
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(QuotaTagStyle.background(pill.level), in: Capsule())
                    .contentShape(Capsule())
                }
                // Borderless: inside a List row only the capsule takes the tap,
                // the row keeps its own selection / tap gesture.
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel(Text(Self.spoken(pill)))
                .accessibilityHint(Text("Shows quota details"))
            }
        }
        .quotaWatch(instanceId: instanceId, reason: "groupMemberAppeared")
    }

    static func spoken(_ p: QuotaPickerHintRules.MemberPill) -> String {
        // The text already says "used" ([T-quota-percent-used]).
        var value = p.text
        switch p.level {
        case .normal: break
        case .low: value += String(localized: ", quota low")
        case .depleted: value += ", " + String(localized: "Quota used up")
        }
        if p.isManual { return String(format: String(localized: "Manually mapped quota for this model: %@"), value) }
        if p.isModelSpecific { return String(format: String(localized: "This model's own quota: %@"), value) }
        return String(format: String(localized: "Account quota: %@"), value)
    }
}

/// At the start of a model row's second line (provider sections only).
struct ModelQuotaHintView: View {
    let instanceId: String
    let modelId: String
    @ObservedObject private var quota = QuotaStore.shared

    var body: some View {
        if let hint = QuotaPickerHintRules.modelRow(quota.modelView(instanceId: instanceId, modelId: modelId)) {
            content(hint)
        }
    }

    @ViewBuilder
    private func content(_ hint: QuotaPickerHintRules.Hint) -> some View {
        switch hint {
        case .modelSpecific(let status, let detail, let isManual):
            HStack(spacing: 2) {
                Image(systemName: QuotaHintStyle.icon(status))
                    .font(.system(size: 9))
                Text(detail ?? QuotaHintStyle.word(status))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                if isManual {
                    Text("(manual)", comment: "Picker quota hint: the pool comes from the user's manual mapping")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(QuotaHintStyle.color(status))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.spoken(detail ?? QuotaHintStyle.word(status), isManual: isManual)))
        }
    }
}

extension ModelQuotaHintView {
    static func spoken(_ value: String, isManual: Bool) -> String {
        isManual
            ? String(format: String(localized: "Manually mapped quota for this model: %@"), value)
            : String(format: String(localized: "This model's own quota: %@"), value)
    }
}

/// [T-quota-tag-level] Picker quota tags: gray normally, a yellow tag when
/// under 10% / $1 is left, a red tag at 0 or below (QuotaLevelRules). Filled
/// backgrounds with contrasting text so the state reads at a glance, in light
/// and dark mode alike.
enum QuotaTagStyle {
    static func background(_ level: QuotaLevel) -> Color {
        switch level {
        case .normal: return Color(UIColor.tertiarySystemFill)
        case .low: return .yellow
        case .depleted: return .red
        }
    }

    static func foreground(_ level: QuotaLevel, normal: Color) -> Color {
        switch level {
        case .normal: return normal
        case .low: return .black
        case .depleted: return .white
        }
    }
}

enum QuotaHintStyle {
    /// Same mapping as every other quota surface (QuotaToneRules); hints only
    /// ever show warnings, so this is orange or red in practice.
    static func color(_ s: QuotaStatus) -> Color {
        QuotaToneRules.tone(status: s, freshness: .fresh, reliablePercent: false).color
    }

    static func icon(_ s: QuotaStatus) -> String {
        s == .rateLimited ? "timer" : "exclamationmark.circle.fill"
    }

    static func word(_ s: QuotaStatus) -> String {
        switch s {
        case .exhausted: return String(localized: "Quota used up")
        case .rateLimited: return String(localized: "Rate limited")
        case .low: return String(localized: "Quota low")
        case .available, .unknown: return ""
        }
    }
}

// MARK: - Attention  [T-quota-attention-refresh]

/// Marks an instance as WATCHED for as long as this view is on screen (and
/// keyed by the id, so a changed id re-targets). Coming on screen refreshes it
/// if due; while watched it refreshes on the normal interval instead of the
/// unattended hour. A List row scrolled out of view ends its watch.
struct QuotaWatchModifier: ViewModifier {
    let instanceId: String?
    let reason: String

    func body(content: Content) -> some View {
        content.task(id: instanceId) {
            guard let instanceId else { return }
            let quota = QuotaStore.shared
            quota.beginWatching(instanceId: instanceId, reason: reason)
            // Held until the view disappears or the id changes (task cancelled).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            quota.endWatching(instanceId: instanceId)
        }
    }
}

extension View {
    func quotaWatch(instanceId: String?, reason: String) -> some View {
        modifier(QuotaWatchModifier(instanceId: instanceId, reason: reason))
    }
}

// MARK: - Chat nav bar status dot  [T-quota-low-dot]

/// The dot before the model name in the chat's nav bar:
/// - orange: no provider signed in (unchanged);
/// - yellow: signed in, but the current model's queryable quota is low —
///   under 10% left, or under $1 (or ≈¥7.2) of balance (QuotaLowRules);
/// - green: otherwise, including when there is no quota data at all.
/// Observes QuotaStore itself so a quota update redraws only the dot.
struct ModelQuotaStatusDot: View {
    let isAuthed: Bool
    let instanceId: String?
    let modelId: String?
    @ObservedObject private var quota = QuotaStore.shared

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            // Keyed by instance: switching the chat's model re-targets the watch.
            .quotaWatch(instanceId: instanceId, reason: "chatNavBar")
    }

    private var color: Color {
        guard isAuthed else { return .orange }
        return Self.isLow(instanceId: instanceId, modelId: modelId, quota: quota) ? .yellow : .green
    }

    @MainActor
    static func isLow(instanceId: String?, modelId: String?, quota: QuotaStore = .shared) -> Bool {
        guard let instanceId, let modelId else { return false }
        return QuotaLowRules.isLow(quota.modelView(instanceId: instanceId, modelId: modelId), pools: quota.pools)
    }
}
