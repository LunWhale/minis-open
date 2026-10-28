//
//  SubAgentRunDetail.swift
//  Minis - chat page (AIChatView)
//
//  [T-subagent-detail-rich] What the sub agent detail card (HelperDetailCard,
//  in the "Minis Computer" sheet) shows beyond status and model: the task it
//  was given, how much it has done (tool calls, turns, tokens, time against
//  its budget), its recent tool calls and what it last said - plus Stop and a
//  course correction while it runs.
//
//  Nothing here is invented or estimated. Every figure is read from data the
//  app already holds: the delegation's own arguments (the parent block's tool
//  input), the sub agent's session (its tool blocks and token counters) and,
//  while the app has not been restarted, the job registry's start / finish
//  times. A fact that cannot be read is left out, not shown as a dash.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import SwiftUI
import UIKit

// BEGIN SubAgentRunDigest
// Pure (values in, values out): MinisTests/Standalone/SubAgentRunDigestTests
// compiles this block as it ships.

/// What a sub agent's session says about the run so far.
struct SubAgentRunDigest: Equatable {
    enum CallState: String, Equatable {
        case running, ok, failed, cancelled
    }

    /// One tool call the sub agent made.
    struct Call: Equatable, Identifiable {
        let id: String
        /// Wire name: shell_execute, file_read, browser_use ...
        let tool: String
        /// What it did, in a line (the tool's title, else its command / path).
        let title: String
        let state: CallState
        /// Wall-clock time it took; nil while running or when not recorded.
        let duration: TimeInterval?
    }

    /// Every tool call, oldest first.
    var calls: [Call] = []
    /// Model turns taken.
    var turns = 0
    var tokensIn = 0
    var tokensOut = 0
    var cacheRead = 0
    /// The sub agent's newest text, trimmed; nil when it has written none.
    var latestText: String?

    var total: Int { calls.count }
    var okCount: Int { calls.filter { $0.state == .ok }.count }
    var failedCount: Int { calls.filter { $0.state == .failed }.count }
    var cancelledCount: Int { calls.filter { $0.state == .cancelled }.count }
    var runningCount: Int { calls.filter { $0.state == .running }.count }
    var hasTokens: Bool { tokensIn > 0 || tokensOut > 0 }
    var isEmpty: Bool { calls.isEmpty && turns == 0 && !hasTokens && latestText == nil }

    /// How many calls each tool got, most used first; ties in order of first use.
    var byTool: [(tool: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for call in calls {
            if counts[call.tool] == nil { order.append(call.tool) }
            counts[call.tool, default: 0] += 1
        }
        return order.enumerated()
            .sorted { a, b in
                let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map { ($0.element, counts[$0.element] ?? 0) }
    }

    /// The last `limit` calls, newest first.
    func recent(_ limit: Int) -> [Call] {
        Array(calls.suffix(max(0, limit)).reversed())
    }

    /// 950 -> "950", 1234 -> "1.2k", 45678 -> "46k", 2_300_000 -> "2.3M".
    static func compact(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 10_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        if n < 1_000_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// 0.84 -> "0.8s", 12.4 -> "12s", 75 -> "1m 15s", 3720 -> "1h 2m".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "0s" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// The arguments a delegation was started with, as the parent's tool call
/// recorded them.
struct SubAgentTaskArgs: Equatable {
    var task = ""
    var context = ""
    /// As asked for; the granted budget is `SubAgentTimeBudget.minutes`.
    var maxMinutes: Int?
    var wait: Bool?
    /// "none" | "moderate" | "frequent".
    var progressReport: String?
    var agent: String?

    /// nil when `json` is not the arguments of a delegation (a control call
    /// - status / cancel / steer - carries no task).
    static func parse(_ json: String?) -> SubAgentTaskArgs? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            ((obj[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let task = text("task")
        guard !task.isEmpty else { return nil }
        var out = SubAgentTaskArgs()
        out.task = task
        out.context = text("context")
        out.maxMinutes = (obj["max_minutes"] as? Int) ?? (obj["max_minutes"] as? Double).map { Int($0) }
        out.wait = obj["wait"] as? Bool
        let progress = text("progress_report").lowercased()
        out.progressReport = ["none", "moderate", "frequent"].contains(progress) ? progress : nil
        let agent = text("agent")
        out.agent = agent.isEmpty ? nil : agent
        return out
    }
}

/// The run's wall-clock allowance.
enum SubAgentTimeBudget {
    /// The minutes actually granted: what the run's own start record says,
    /// else what was asked for, clamped the way the runner clamps it; nil
    /// when neither is known (no number is made up).
    static func minutes(recorded: Int?, requested: Int?, hasArgs: Bool,
                        defaultMinutes: Int, maxMinutes: Int) -> Int? {
        if let recorded, recorded > 0 { return recorded }
        guard hasArgs else { return nil }
        return max(1, min(maxMinutes, requested ?? defaultMinutes))
    }

    /// Seconds left of the allowance; negative once it is spent.
    static func remaining(budgetMinutes: Int, startedAt: Date, now: Date) -> TimeInterval {
        TimeInterval(budgetMinutes * 60) - now.timeIntervalSince(startedAt)
    }

    /// "8m left", "45s left", or nil once nothing is left (the run is being
    /// asked to wrap up; "0s left" would only look like a broken counter).
    static func remainingLabel(_ seconds: TimeInterval) -> (minutes: Int, seconds: Int)? {
        guard seconds >= 1 else { return nil }
        let s = Int(seconds)
        return (s / 60, s % 60)
    }
}

/// Long text shown short first.
enum SubAgentTextPreview {
    /// Whether `text` needs a "Show more": more lines or characters than fit
    /// the collapsed block.
    static func isLong(_ text: String, lines: Int = 4, characters: Int = 220) -> Bool {
        if text.count > characters { return true }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count > lines
    }
}
// END SubAgentRunDigest

// MARK: - Reading a sub agent's session

extension SubAgentRunDigest {
    /// Built from the sub agent's loaded session.
    @MainActor
    static func make(child: AIChatViewModel) -> SubAgentRunDigest {
        var digest = SubAgentRunDigest()
        var latest: String?
        for message in child.messages where message.role == .assistant {
            for block in message.blocks {
                if case .text = block.kind {
                    let text = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { latest = text }
                    continue
                }
                guard let status = block.toolStatus else { continue }
                let state: CallState
                switch status {
                case .streaming, .running: state = .running
                case .success: state = .ok
                case .failed: state = .failed
                case .cancelled: state = .cancelled
                }
                let summary = (block.toolSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = summary.isEmpty ? block.toolDescription : summary
                digest.calls.append(Call(
                    id: block.id.uuidString,
                    tool: AIChatViewModel.toolWireName(block.kind),
                    title: title.split(whereSeparator: \.isNewline).first.map(String.init) ?? "",
                    state: state,
                    duration: state == .running ? nil : block.toolDuration))
            }
        }
        let stats = child.sessionTokenStats
        digest.turns = stats.loopCount
        digest.tokensIn = stats.input
        digest.tokensOut = stats.output
        digest.cacheRead = stats.cacheRead
        digest.latestText = latest
        return digest
    }
}

/// When the run started and ended, for as long as the app remembers: the job
/// registry is in memory, so after a restart these are nil and the card shows
/// the elapsed time the result recorded instead.
struct SubAgentRunClock: Equatable {
    var startedAt: Date?
    var finishedAt: Date?
    /// A job of this run is still pending or running in the registry.
    var jobIsLive = false

    @MainActor
    static func read(childSessionId: String?, block: AssistantBlock) -> SubAgentRunClock {
        var clock = SubAgentRunClock()
        if let childSessionId,
           let job = AgentJobRegistry.shared.list().first(where: { $0.runSessionId == childSessionId }) {
            clock.startedAt = job.startedAt
            clock.finishedAt = job.finishedAt
            clock.jobIsLive = job.state == .running || job.state == .pending
        }
        // The parent block's own start stamp covers a run with no job left.
        if clock.startedAt == nil { clock.startedAt = block.toolStartTime }
        return clock
    }
}

/// [T-subagent-detail-rich] A course correction typed by the user in the
/// detail card.
///
/// The same delivery the parent model's `steer` action uses (HelperRunner):
/// the message waits in the child's queue and is read at its next turn, so a
/// tool call in flight is not interrupted; a child that is between turns is
/// nudged to take one. Marked as coming from the user, because the child is
/// otherwise told every correction comes from the delegating agent.
@MainActor
enum SubAgentUserSteer {
    /// False when there is nothing live to steer.
    static func send(_ text: String, childSessionId: String) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              let job = AgentJobRegistry.shared.list().first(where: { $0.runSessionId == childSessionId }),
              job.state == .running || job.state == .pending,
              let child = ViewModelCache.shared.get(for: childSessionId) else { return false }
        child.pendingSteerMessages.append("(sent directly by the user) \(message)")
        if !child.isProcessing {
            _ = child.submitProgrammaticPrompt(AIChatViewModel.steerNudgePrompt,
                                               origin: .job(jobId: job.id), silent: true)
        }
        AppLogger(category: "SubAgentDetail").info(
            "[subagent_task] user steer queued job=\(job.id.prefix(8)) child=\(childSessionId.prefix(8)) chars=\(message.count)")
        return true
    }
}

// MARK: - Summary chips

/// A row of small facts under the header: tool calls, their outcome, turns,
/// tokens, time left. Wraps onto more lines on a narrow screen.
struct SubAgentStatChips: View {
    let digest: SubAgentRunDigest
    /// Seconds left of the time budget while the run is live.
    let remaining: TimeInterval?
    let budgetMinutes: Int?

    var body: some View {
        ChipFlow(spacing: 6) {
            if digest.total > 0 {
                chip("wrench.and.screwdriver",
                     String(format: AppLocalized("%lld tool calls"), digest.total))
            }
            if digest.okCount > 0 {
                chip("checkmark.circle.fill", "\(digest.okCount)", tint: .green,
                     label: String(format: AppLocalized("%lld succeeded"), digest.okCount))
            }
            if digest.failedCount > 0 {
                chip("xmark.circle.fill", "\(digest.failedCount)", tint: .red,
                     label: String(format: AppLocalized("%lld failed"), digest.failedCount))
            }
            if digest.turns > 0 {
                chip("arrow.triangle.2.circlepath",
                     String(format: AppLocalized("%lld turns"), digest.turns))
            }
            if digest.hasTokens {
                chip("arrow.up.arrow.down",
                     "\(SubAgentRunDigest.compact(digest.tokensIn)) / \(SubAgentRunDigest.compact(digest.tokensOut))",
                     label: String(format: AppLocalized("Tokens: %1$@ in, %2$@ out"),
                                   SubAgentRunDigest.compact(digest.tokensIn),
                                   SubAgentRunDigest.compact(digest.tokensOut)))
            }
            if let remaining, let left = SubAgentTimeBudget.remainingLabel(remaining) {
                chip("timer", left.minutes > 0
                     ? String(format: AppLocalized("%lldm left"), left.minutes)
                     : String(format: AppLocalized("%llds left"), left.seconds),
                     tint: remaining < 60 ? .orange : nil)
            } else if let budgetMinutes {
                chip("timer", String(format: AppLocalized("%lldm budget"), budgetMinutes))
            }
        }
    }

    private func chip(_ symbol: String, _ text: String, tint: Color? = nil, label: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint ?? Color(UIColor.secondaryLabel))
            // Proportional with fixed-width digits: a monospaced face spread
            // "6 次工具调用" out with double-width gaps around the number.
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color(UIColor.label))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(UIColor.secondarySystemFill)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? text)
    }
}

/// Leading-aligned wrapping row.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in placed.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

// MARK: - Collapsible text

/// Text shown four lines tall with "Show more" when it is longer.
struct SubAgentCollapsibleText: View {
    let text: String
    var monospaced = false
    @State private var expanded = false

    var body: some View {
        let long = SubAgentTextPreview.isLong(text)
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Color(UIColor.label))
                .lineLimit(long && !expanded ? 4 : nil)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Text(expanded ? AppLocalized("Show less") : AppLocalized("Show more"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HelperAccent.color)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Task card

/// What the sub agent was asked to do: the task, and the extra context when
/// the delegation carried any.
struct SubAgentTaskCard: View {
    let args: SubAgentTaskArgs

    var body: some View {
        AgentDetailCard(title: AppLocalized("Task"), icon: "text.alignleft") {
            VStack(alignment: .leading, spacing: 10) {
                SubAgentCollapsibleText(text: args.task)
                if !args.context.isEmpty {
                    Divider()
                    Text(AppLocalized("Context"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(UIColor.secondaryLabel))
                    SubAgentCollapsibleText(text: args.context)
                }
            }
        }
    }
}

// MARK: - Tool timeline

/// The sub agent's most recent tool calls, newest first, and how its calls
/// split across tools.
struct SubAgentToolTimelineCard: View {
    let digest: SubAgentRunDigest
    var limit = 8

    var body: some View {
        AgentDetailCard(title: AppLocalized("Recent tool calls"), icon: "list.bullet.rectangle",
                        trailing: { trailing }) {
            VStack(alignment: .leading, spacing: 10) {
                let split = digest.byTool
                if split.count > 1 {
                    ChipFlow(spacing: 6) {
                        ForEach(Array(split.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 4) {
                                Image(systemName: HelperAccent.symbol(forTool: entry.tool))
                                    .font(.system(size: 9, weight: .semibold))
                                Text("\(HelperAccent.displayName(forTool: entry.tool)) ×\(entry.count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color(UIColor.secondaryLabel))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().stroke(Color(UIColor.separator), lineWidth: 0.5))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(digest.recent(limit)) { call in
                        row(call)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if digest.total > limit {
            Text(String(format: AppLocalized("Latest %1$lld of %2$lld"), limit, digest.total))
                .font(.system(size: 10))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
    }

    private func row(_ call: SubAgentRunDigest.Call) -> some View {
        HStack(alignment: .top, spacing: 8) {
            stateGlyph(call.state)
                .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: HelperAccent.symbol(forTool: call.tool))
                        .font(.system(size: 10, weight: .semibold))
                    Text(HelperAccent.displayName(forTool: call.tool))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(call.state == .running ? HelperAccent.color : Color(UIColor.label))
                if !call.title.isEmpty {
                    Text(call.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(UIColor.secondaryLabel))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 6)
            if let duration = call.duration {
                Text(SubAgentRunDigest.durationLabel(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(UIColor.tertiaryLabel))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stateGlyph(_ state: SubAgentRunDigest.CallState) -> some View {
        switch state {
        case .running:
            ReattachingSpinner(size: 11, lineWidth: 1.6, color: HelperAccent.color)
        case .ok:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").font(.system(size: 12))
                .foregroundStyle(Color(UIColor.tertiaryLabel))
        }
    }
}

// MARK: - Actions

/// While the run is live: send it a course correction, or stop it.
struct SubAgentActionsCard: View {
    let childSessionId: String
    /// A job is live in the registry, so a correction has somewhere to go.
    let canSteer: Bool
    @State private var draft = ""
    @State private var sentCount = 0
    @State private var confirmStop = false
    @FocusState private var focused: Bool

    var body: some View {
        AgentDetailCard(title: AppLocalized("Actions"), icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                if canSteer {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField(AppLocalized("Send a course correction…"), text: $draft, axis: .vertical)
                            .font(.system(size: 13))
                            .lineLimit(1...4)
                            .focused($focused)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.tertiarySystemFill)))
                        Button {
                            if SubAgentUserSteer.send(draft, childSessionId: childSessionId) {
                                draft = ""
                                sentCount += 1
                                focused = false
                            }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(isBlank ? Color(UIColor.tertiaryLabel) : HelperAccent.color)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBlank)
                        .accessibilityLabel(AppLocalized("Send"))
                    }
                    Text(sentCount > 0
                         ? AppLocalized("Sent. The sub agent reads it at its next turn.")
                         : AppLocalized("Read at the sub agent's next turn; a tool call already running is not interrupted."))
                        .font(.system(size: 11))
                        .foregroundStyle(Color(UIColor.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) { confirmStop = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                        Text(AppLocalized("Stop agent"))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(AppLocalized("Stop this sub agent?"), isPresented: $confirmStop, titleVisibility: .visible) {
            Button(AppLocalized("Stop agent"), role: .destructive) { stop() }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Sub agents started in the same turn are stopped too. Work finished so far is kept."))
        }
    }

    private var isBlank: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The same two steps as the Stop control on the block in the transcript
    /// (HelperBlockView): through the registry, which also stops the sibling
    /// set and drops the "cancelled" callback; and the loop itself when no
    /// job is left behind it.
    private func stop() {
        let stopped = AgentJobRegistry.shared.stopSubAgentByUser(
            childSessionId: childSessionId, reason: "user stopped this sub agent")
        if stopped == 0 { ViewModelCache.shared.get(for: childSessionId)?.cancel() }
    }
}
