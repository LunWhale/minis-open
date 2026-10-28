//
//  UserAskCardView.swift
//  Minis
//
//  [T-user-ask] The user_ask card in the chat. Same family as the sub-agent
//  card (HelperBlockView: 12pt continuous corners, tinted fill, 0.8pt tinted
//  stroke, 14/12 padding) — theme blue for questions, orange / red for
//  confirms. Pending: header (type, progress, countdown), a scrollable body
//  capped at ~50% of the screen, and a fixed action bar. Resolved: a
//  one-line summary that expands to the questions and answers.
//
//  Free text (Other…, a note, a cancel reason) is typed in a sheet presented
//  from the top view controller, not in the cell: message cells have no text
//  input today, the list dismisses the keyboard on drag, and a recycled cell
//  must not take the half-typed answer with it. Drafts go to UserAskCenter
//  (persisted), so an interrupted sheet loses nothing.
//

import Combine
import SwiftUI
import UIKit

// MARK: - Model helpers

enum UserAskCardModel {
    static func request(_ block: AssistantBlock) -> UserAskRequest? {
        guard let json = block.toolInputArgs, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if case .success(let r) = UserAskParser.parse(obj) { return r }
        return nil
    }

    struct Result {
        var status: UserAskResultStatus
        var answer: [String]
        var note: String?
    }

    static func results(_ content: String) -> [Result] {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["results"] as? [[String: Any]] else { return [] }
        return arr.compactMap { r in
            guard let s = (r["status"] as? String).flatMap(UserAskResultStatus.parse) else { return nil }
            let answer: [String] = (r["answer"] as? [String]) ?? ((r["answer"] as? String).map { [$0] } ?? [])
            return Result(status: s, answer: answer, note: r["note"] as? String)
        }
    }

    static func questionsSummary(_ block: AssistantBlock) -> String {
        request(block)?.questions.map(\.question).joined(separator: " / ") ?? ""
    }

    /// One-line summary for a resolved question.
    static func summary(_ r: Result, question: UserAskQuestion?) -> String {
        let a = r.answer.joined(separator: ", ")
        switch r.status {
        case .answered: return AppLocalized("Selected: \(a)")
        case .other: return AppLocalized("Answered: \(a)")
        case .delegated: return AppLocalized("Left to Minis")
        case .approved: return AppLocalized("Allowed once")
        case .denied: return AppLocalized("Cancelled")
        // [T-user-ask-no-policy] Nothing was applied, approved or cancelled.
        case .timeout: return AppLocalized("Timed out")
        case .dismissed: return AppLocalized("Skipped")
        case .unavailable: return AppLocalized("Could not ask")
        }
    }

    static func isTimeout(_ s: UserAskResultStatus) -> Bool { s == .timeout }
}

// MARK: - Palette

private enum UserAskTint {
    static func color(for q: UserAskQuestion?) -> Color {
        guard let q, q.type == .confirm else { return Color.accentColor }
        return q.risk == .high ? .red : .orange
    }
}

// MARK: - Typography

// Kept byte-identical with MinisTests/Standalone/UserAskTypographyTests.swift.
// BEGIN UserAskTypography
/// [T-user-ask-font-scale] Every text size on the user_ask card, derived from
/// the chat body size - FontSettings.scaledMessage(bodyReference), the same
/// "message" font the bubbles use (Settings › Appearance) - so the card
/// follows the user's font setting instead of fixed points. Ratios keep the
/// hierarchy: question ≈ body, option titles and buttons just under it,
/// descriptions one step smaller but never below the previous fixed 12pt.
struct UserAskTypography: Equatable {
    /// Chat body size at the default scale (ChatMessageViews / markdown).
    static let bodyReference: CGFloat = 16.5
    /// Minimum height of every tappable button on the card.
    static let minTapHeight: CGFloat = 44

    /// The chat body size the card derives from (already scaled).
    let body: CGFloat

    /// Rounded to half points so a scale change cannot produce 16.005-style
    /// sizes that re-measure without visibly changing.
    private func size(_ ratio: CGFloat, floor: CGFloat) -> CGFloat {
        max(floor, (body * ratio * 2).rounded() / 2)
    }
    var question: CGFloat { size(1.0, floor: 13) }
    var optionTitle: CGFloat { size(0.97, floor: 13) }
    var optionDetail: CGFloat { size(0.82, floor: 12) }
    /// Note / cancel-reason rows, impact line, the confirm command.
    var secondary: CGFloat { size(0.88, floor: 12.5) }
    var title: CGFloat { size(0.91, floor: 13) }
    /// Countdown, progress, timeout hint, status lines.
    var meta: CGFloat { size(0.76, floor: 11) }
    /// Header tag and "Recommended" badges.
    var chip: CGFloat { size(0.66, floor: 10) }
    var button: CGFloat { size(0.97, floor: 14) }
    /// Radio / checkbox glyphs.
    var icon: CGFloat { size(1.03, floor: 15) }
    var resolvedTopic: CGFloat { size(0.88, floor: 13) }
    var resolvedDetail: CGFloat { size(0.79, floor: 12) }
    /// [T-user-ask-thumbnail] The mini preview tile above the composer is a
    /// fixed 100x65pt picture, so its text follows the setting only inside a
    /// narrow band that still fits the tile: 7 / 5.5 at the default step.
    var thumbTitle: CGFloat { min(8, size(0.42, floor: 6)) }
    var thumbLine: CGFloat { min(6.5, size(0.34, floor: 5)) }
}
// END UserAskTypography

extension UserAskTypography {
    /// The current chat body size (live: views observe FontSettings).
    @MainActor static var current: UserAskTypography {
        UserAskTypography(body: FontSettings.shared.scaledMessage(bodyReference))
    }
}

// MARK: - Card

// BEGIN UserAskCardPhase
/// [T-user-ask-not-asked-row] Which face a user_ask block shows.
///
/// `notAsked` is the call that never became a question: preflight rejected it
/// (empty or invalid arguments), so no PendingAsk exists and none ever will.
/// It used to fall through to `waiting`, a "Waiting for your answer…" shell
/// that stayed above the real, answered card from the model's retry forever,
/// live and after every reload.
///
/// The signal is that the call has ENDED (its tool status left
/// streaming/running) with arguments that do not parse into a request. The
/// status, not the content, is used because:
/// - it is the same on both paths: preflight sets `.failed` live, and a
///   reload maps the stored error result to `.failed`;
/// - the content is not reliable: it is non-empty while the call streams (the
///   "Tool: user_ask" placeholder), and its text differs between the live
///   path ("Blocked invalid tool call") and a reload (the model-facing
///   "Error: …").
///
/// An unparseable request is the other half on purpose: such a call can
/// never be asked, so the row is right whatever ended it. A parseable call
/// with no live ask keeps today's behaviour (stored result, or waiting while
/// recovery scans).
enum UserAskCardPhase: Equatable {
    case pending
    case resolvedLive
    case resolvedStored
    case notAsked
    case waiting

    static func resolve(livePending: Bool, liveTerminal: Bool, hasContent: Bool,
                        requestParses: Bool, callEnded: Bool) -> UserAskCardPhase {
        if livePending { return .pending }
        if liveTerminal { return .resolvedLive }
        if hasContent && requestParses { return .resolvedStored }
        if callEnded && !requestParses { return .notAsked }
        return .waiting
    }

    static func callEnded(_ status: ToolBlockStatus?) -> Bool {
        switch status {
        case .success?, .failed?, .cancelled?: return true
        case .streaming?, .running?, nil: return false
        }
    }
}
// END UserAskCardPhase

// BEGIN UserAskNotSentGrouping
/// [T-user-ask-notsent-merge] A model that sends user_ask with empty or
/// invalid arguments tends to do it several times in a row, each one rejected
/// before it reaches the user. One "Question not sent" row per attempt filled
/// the turn with identical rows, so a run of them shows as ONE row with the
/// count: "Question not sent (3 times)".
///
/// A run is consecutive not-sent calls within one assistant message. Thinking
/// and still-empty text between them do not end it; anything else does - a
/// user_ask that was asked (pending, answered, …), another tool, real text.
/// The first call of a run leads and carries the count; the rest are members,
/// which the message list leaves out. Display only: the blocks, the stored
/// messages and the replayed tool results are untouched.
enum UserAskNotSentRole: Equatable {
    case none
    case lead(count: Int)
    case member(count: Int)

    /// How many calls the run holds (1 for a lone not-sent call).
    var count: Int {
        switch self {
        case .none: return 0
        case .lead(let n), .member(let n): return n
        }
    }
}

enum UserAskNotSentGrouping {
    enum Input: Equatable {
        /// A user_ask call that ended without being asked.
        case notSent
        /// A user_ask that was asked, or is still on its way.
        case asked
        /// Thinking, or text with no content yet: does not break a run.
        case transparent
        /// Anything else: ends a run.
        case other
    }

    static func roles(_ inputs: [Input]) -> [UserAskNotSentRole] {
        var roles = [UserAskNotSentRole](repeating: .none, count: inputs.count)
        var i = 0
        while i < inputs.count {
            guard inputs[i] == .notSent else { i += 1; continue }
            var members = [i]
            var j = i + 1
            scan: while j < inputs.count {
                switch inputs[j] {
                case .notSent: members.append(j)
                case .transparent: break
                case .asked, .other: break scan
                }
                j += 1
            }
            for (k, idx) in members.enumerated() {
                roles[idx] = k == 0 ? .lead(count: members.count) : .member(count: members.count)
            }
            i = j
        }
        return roles
    }
}
// END UserAskNotSentGrouping

/// [T-user-ask-notsent-merge] The run role of each not-sent user_ask block,
/// by block id. Derived and never persisted: written when a call is rejected
/// live and when a session loads (UserAskNotSentGrouping.annotate); read by
/// the card, the preview tile and the message list. Main thread only.
///
/// A side table rather than a stored property on AssistantBlock: adding a
/// field of a new type to that class pushed the first-frame type-metadata
/// instantiation on launch past the main thread's stack (SIGSEGV "Thread
/// stack size exceeded" under AIChatViewModel.inputText's key path).
final class UserAskNotSentStore: ObservableObject {
    static let shared = UserAskNotSentStore()
    @Published private(set) var roles: [UUID: UserAskNotSentRole] = [:]

    func role(_ blockId: UUID) -> UserAskNotSentRole { roles[blockId] ?? .none }

    /// Apply new roles for a set of blocks; `.none` clears an entry. Returns
    /// whether anything changed.
    @discardableResult
    func update(_ updates: [(UUID, UserAskNotSentRole)]) -> Bool {
        var next = roles
        for (id, r) in updates {
            if r == .none { next.removeValue(forKey: id) } else { next[id] = r }
        }
        guard next != roles else { return false }
        roles = next
        return true
    }
}

// BEGIN UserAskRetryRule
/// [T-user-ask-notsent-retry] When a "Question not sent" row offers Retry.
///
/// Only the session's LAST not-sent run, only while nothing runs, and only
/// while nothing has superseded it: an asked user_ask after it (the model
/// retried by itself) or a later user turn (the conversation moved on). The
/// assistant's own text after the run does not count - a model that gave up
/// usually says so. A run already retried never offers it again.
enum UserAskRetryRule {
    enum Item: Equatable {
        /// The first call of a not-sent run, by toolUseId.
        case notSentLead(String)
        /// A user_ask that was asked (or is on its way).
        case asked
        /// A visible user turn.
        case userTurn
    }

    static func retryableLead(_ items: [Item], isProcessing: Bool, retried: Set<String>) -> String? {
        guard !isProcessing else { return nil }
        for item in items.reversed() {
            switch item {
            case .asked, .userTurn: return nil
            case .notSentLead(let id): return retried.contains(id) || id.isEmpty ? nil : id
            }
        }
        return nil
    }
}

/// One tap, one retry: the first claim of an id wins, every later one -
/// a double tap, a tap racing a re-render - is refused.
struct UserAskRetryClaims: Equatable {
    private(set) var ids: [String] = []
    let cap: Int

    init(ids: [String] = [], cap: Int = 300) {
        self.ids = Array(ids.suffix(cap))
        self.cap = cap
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// True the first time `id` is claimed. Oldest ids fall off past `cap`.
    mutating func claim(_ id: String) -> Bool {
        guard !id.isEmpty, !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > cap { ids.removeFirst(ids.count - cap) }
        return true
    }

    mutating func release(_ id: String) { ids.removeAll { $0 == id } }
}
// END UserAskRetryRule

/// [T-user-ask-notsent-retry] Which not-sent run offers Retry (per session)
/// and which runs were retried. Main thread only.
///
/// The retried ids (the run lead's toolUseId, stable across reloads, unlike
/// block ids) persist in UserDefaults, so a reloaded row still reads
/// "Retried". Nothing is written to the transcript or the tool results; the
/// only transcript change is the hidden retry turn itself.
final class UserAskRetryStore: ObservableObject {
    static let shared = UserAskRetryStore()
    static let retriedKey = "agent.tools.userAsk.retriedNotSent"

    @Published private(set) var claims: UserAskRetryClaims
    /// sessionId → the lead toolUseId that offers Retry right now.
    @Published private(set) var retryable: [String: String] = [:]
    private var owners: [String: WeakChatVM] = [:]
    /// One `isProcessing` subscription per tracked vm (see track(_:)).
    private var tracking: [ObjectIdentifier: (owner: WeakChatVM, sub: AnyCancellable)] = [:]

    private struct WeakChatVM { weak var vm: AIChatViewModel? }

    /// Refresh `vm`'s Retry offer whenever one of its runs starts or ends.
    /// Idempotent; an entry whose vm is gone is replaced.
    @MainActor
    func track(_ vm: AIChatViewModel) {
        let key = ObjectIdentifier(vm)
        if tracking[key]?.owner.vm === vm { return }
        let sub = vm.$isProcessing.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak vm] _ in
                Task { @MainActor in vm?.refreshUserAskRetryable() }
            }
        tracking[key] = (WeakChatVM(vm: vm), sub)
    }

    init(defaults: UserDefaults = .standard) {
        claims = UserAskRetryClaims(ids: defaults.stringArray(forKey: Self.retriedKey) ?? [])
    }

    func isRetried(_ toolUseId: String?) -> Bool { toolUseId.map(claims.contains) ?? false }
    func isRetryable(_ toolUseId: String?) -> Bool {
        guard let toolUseId else { return false }
        return retryable.values.contains(toolUseId)
    }

    func setRetryable(sessionId: String, leadToolUseId: String?, owner: AIChatViewModel) {
        if let id = leadToolUseId { owners[id] = WeakChatVM(vm: owner) }
        guard retryable[sessionId] != leadToolUseId else { return }
        retryable[sessionId] = leadToolUseId
    }

    /// The tap. Marks the run retried (persisted) and hands back the session
    /// that should retry, once; nil for any later tap.
    func claim(_ toolUseId: String) -> AIChatViewModel? {
        guard isRetryable(toolUseId), let vm = owners[toolUseId]?.vm else { return nil }
        guard claims.claim(toolUseId) else { return nil }
        retryable = retryable.filter { $0.value != toolUseId }
        UserDefaults.standard.set(claims.ids, forKey: Self.retriedKey)
        return vm
    }

    /// The retry could not start after all (a run began in between).
    func release(_ toolUseId: String) {
        claims.release(toolUseId)
        UserDefaults.standard.set(claims.ids, forKey: Self.retriedKey)
    }
}

extension UserAskNotSentGrouping {
    /// The same "never asked" test as UserAskCardPhase.notAsked: the call has
    /// ended and its arguments do not parse into a request.
    static func input(_ block: AssistantBlock) -> Input {
        switch block.kind {
        case .userAskTool:
            return UserAskCardPhase.callEnded(block.toolStatus) && UserAskCardModel.request(block) == nil
                ? .notSent : .asked
        case .thinking: return .transparent
        case .text: return block.content.isEmpty ? .transparent : .other
        default: return .other
        }
    }

    /// Recompute and store the roles of one message's blocks. Returns whether
    /// any role changed. Cheap when the message has no user_ask at all.
    @discardableResult
    static func annotate(_ blocks: [AssistantBlock]) -> Bool {
        guard blocks.contains(where: { if case .userAskTool = $0.kind { return true }; return false }) else { return false }
        let roles = roles(blocks.map(input))
        return UserAskNotSentStore.shared.update(Array(zip(blocks.map(\.id), roles)))
    }
}

struct UserAskCardView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var center = UserAskCenter.shared
    @ObservedObject private var notSent = UserAskNotSentStore.shared
    @ObservedObject private var retry = UserAskRetryStore.shared
    @ObservedObject private var fonts = FontSettings.shared
    private var t: UserAskTypography { .current }

    var body: some View {
        let live = center.ask(forToolUseId: block.toolUseId)
        let request = UserAskCardModel.request(block)
        let phase = UserAskCardPhase.resolve(
            livePending: live?.state == .pending,
            liveTerminal: live?.state.isTerminal == true,
            hasContent: !block.content.isEmpty,
            requestParses: request != nil,
            callEnded: UserAskCardPhase.callEnded(block.toolStatus)
        )
        Group {
            switch phase {
            case .pending:
                if let live { UserAskPendingCard(ask: live, blockId: block.id) }
            case .resolvedLive:
                if let live {
                    UserAskResolvedCard(block: block, questions: live.questions,
                                        results: UserAskCardModel.results(live.resultJSON ?? ""),
                                        source: live.source, dismissReason: live.dismissReason)
                }
            case .resolvedStored:
                if let request {
                    UserAskResolvedCard(block: block, questions: request.questions,
                                        results: UserAskCardModel.results(block.content),
                                        source: nil, dismissReason: nil)
                }
            case .notAsked:
                notAskedRow
            case .waiting:
                waitingPlaceholder
            }
        }
        .accessibilityIdentifier("userAskCard")
    }

    /// The call never reached the user (see UserAskCardPhase.notAsked): one
    /// grey line, no accent, nothing that reads as still waiting.
    ///
    /// [T-user-ask-notsent-merge] Plain words, not tool terms: what happened
    /// ("Question not sent", with the count when several calls in a row were
    /// rejected) and what comes next. The reason sits on its own line and may
    /// wrap to a second one rather than truncate. A rejection that lands live
    /// re-measures the cell (AIChatViewModel.regroupUserAskNotSent).
    private var notAskedRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(ChatColors.tertiaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(UserAskSummary.notSentTitle(count: notSent.role(block.id).count))
                    .font(.system(size: t.secondary, weight: .medium))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                if case .failed? = block.toolStatus {
                    Text(AppLocalized("Details missing; the assistant will retry or ask in text"))
                        .font(.system(size: t.meta))
                        .foregroundStyle(ChatColors.tertiaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            retryAccessory
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.gray.opacity(0.25), lineWidth: 0.8))
    }

    /// [T-user-ask-notsent-retry] Retry on the session's last not-sent run
    /// (UserAskRetryRule), "Retried" once tapped. The tap marks the run retried
    /// before anything else, so the button is gone on the next render and a
    /// second tap finds nothing to claim.
    @ViewBuilder
    private var retryAccessory: some View {
        let id = block.toolUseId
        if retry.isRetried(id) {
            Text(AppLocalized("Retried"))
                .font(.system(size: t.meta))
                .foregroundStyle(ChatColors.tertiaryText)
                .lineLimit(1)
        } else if retry.isRetryable(id), let id {
            // Compact (no 44pt minimum height): it must not make the row taller
            // than its two text lines, or the row would change height in place
            // when the button appears. The hit area is grown instead.
            Button {
                guard let vm = UserAskRetryStore.shared.claim(id) else { return }
                Task { @MainActor in
                    if !(await vm.retryNotSentUserAsk(leadToolUseId: id)) {
                        UserAskRetryStore.shared.release(id)
                    }
                }
            } label: {
                Text(AppLocalized("Retry"))
                    .font(.system(size: t.meta, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(ChatColors.secondaryText)
                    .background(Capsule().fill(Color.gray.opacity(0.16)))
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("userAskRetry")
        }
    }

    /// No live state yet (e.g. just relaunched, recovery still scanning).
    private var waitingPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(Color.accentColor)
            Text(AppLocalized("Waiting for your answer…"))
                .font(.system(size: t.secondary))
                .foregroundStyle(ChatColors.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8))
    }
}

// MARK: - Pending

// BEGIN UserAskPendingLayoutCache
/// [T-user-ask-pending-reuse] The pending card's measured body height and its
/// "Show more" state, per ask and question, kept OUTSIDE the view.
///
/// As `@State` they reset whenever the list recycled the card's cell
/// (scrolled out and back): the body then rendered 1pt tall inside a cell
/// still sized for the full card, the height preference fired again, and that
/// posted a re-measure (invalidate + reconfigure + apply) on every re-entry,
/// often mid-scroll. Seeded from here, a returning card renders at its full
/// height in its first frame and posts nothing. Plain storage on purpose (not
/// observable): reading it must never re-render anything.
enum UserAskPendingLayoutCache {
    private static var bodyHeights: [String: CGFloat] = [:]
    private static var expanded: Set<String> = []
    /// A pending ask has a handful of questions; this only bounds a long
    /// session's leftovers.
    private static let limit = 256

    static func key(_ requestId: String, _ index: Int) -> String { "\(requestId)#\(index)" }

    static func bodyHeight(_ key: String) -> CGFloat { bodyHeights[key] ?? 0 }
    static func setBodyHeight(_ height: CGFloat, _ key: String) {
        if bodyHeights.count >= limit { bodyHeights.removeAll() }
        bodyHeights[key] = height
    }

    static func isExpanded(_ key: String) -> Bool { expanded.contains(key) }
    static func setExpanded(_ value: Bool, _ key: String) {
        if expanded.count >= limit { expanded.removeAll() }
        if value { expanded.insert(key) } else { expanded.remove(key) }
    }
}
// END UserAskPendingLayoutCache

private struct UserAskPendingCard: View {
    let ask: PendingAsk
    let blockId: UUID
    @ObservedObject private var fonts = FontSettings.shared
    private var t: UserAskTypography { .current }
    @State private var bodyHeight: CGFloat
    @State private var questionExpanded: Bool
    /// [T-user-ask-expand-measured] Heights of the question laid out with the
    /// 3-line limit and without it (hidden probes, see `questionText`). The
    /// Show more / Show less toggle exists only when the full text is taller,
    /// i.e. when the collapsed text really is truncated.
    @State private var questionClampedHeight: CGFloat = 0
    @State private var questionFullHeight: CGFloat = 0

    init(ask: PendingAsk, blockId: UUID) {
        self.ask = ask
        self.blockId = blockId
        // [T-user-ask-pending-reuse] Start from what this question last
        // measured, so a recycled cell does not render a 1pt body first.
        let key = UserAskPendingLayoutCache.key(ask.requestId, min(ask.currentIndex, ask.questions.count - 1))
        _bodyHeight = State(initialValue: UserAskPendingLayoutCache.bodyHeight(key))
        _questionExpanded = State(initialValue: UserAskPendingLayoutCache.isExpanded(key))
    }

    private var layoutKey: String { UserAskPendingLayoutCache.key(ask.requestId, index) }

    private var index: Int { min(ask.currentIndex, ask.questions.count - 1) }
    private var q: UserAskQuestion { ask.questions[index] }
    private var answer: UserAskAnswer { ask.answers[index] }
    private var tint: Color { UserAskTint.color(for: q) }
    /// ~50% of the screen for the whole card; header and action bar are
    /// outside the scroll area, so the body gets that minus ~120pt.
    private var bodyCap: CGFloat { max(160, UIScreen.main.bounds.height * 0.5 - 120) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView(.vertical, showsIndicators: bodyHeight > bodyCap) {
                content
                    .background(GeometryReader { g in
                        Color.clear.preference(key: UserAskBodyHeightKey.self, value: g.size.height)
                    })
            }
            .frame(height: min(max(bodyHeight, 1), bodyCap))
            .onPreferenceChange(UserAskBodyHeightKey.self) { h in
                guard abs(h - bodyHeight) > 0.5 else { return }
                bodyHeight = h
                UserAskPendingLayoutCache.setBodyHeight(h, layoutKey)
                NotificationCenter.default.post(name: .thinkingBlockToggled, object: blockId)
            }
            actionBar
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
        .onChange(of: ask.currentIndex) { _ in
            // The new question starts from its own remembered state (collapsed
            // unless the user opened it earlier in this card).
            questionExpanded = UserAskPendingLayoutCache.isExpanded(layoutKey)
            NotificationCenter.default.post(name: .thinkingBlockToggled, object: blockId)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: q.type == .confirm ? "exclamationmark.shield.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: t.title, weight: .semibold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
            if let h = q.header, !h.isEmpty {
                Text(h)
                    .font(.system(size: t.chip, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if ask.questions.count > 1 {
                Text("\(index + 1)/\(ask.questions.count)")
                    .font(.system(size: t.meta, weight: .medium).monospacedDigit())
                    .foregroundStyle(ChatColors.secondaryText)
            }
            if let expires = ask.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                    Label(String(format: "%d:%02d", left / 60, left % 60), systemImage: "timer")
                        .font(.system(size: t.meta, weight: .medium).monospacedDigit())
                        .foregroundStyle(left <= 30 ? Color.orange : ChatColors.secondaryText)
                        .accessibilityLabel(left <= 30 ? AppLocalized("\(left) seconds left") : AppLocalized("Time left"))
                }
            }
        }
    }

    private var title: String {
        switch q.type {
        case .options: return AppLocalized("Needs your answer")
        case .confirm: return q.risk == .high ? AppLocalized("High-risk action") : AppLocalized("Needs your approval")
        }
    }

    // MARK: Body

    /// The question with its type's font - one definition for the visible
    /// text and both measuring probes, so they always wrap identically.
    private var questionText: Text {
        Text(q.question)
            .font(q.type == .confirm ? .system(size: t.secondary, design: .monospaced) : .system(size: t.question, weight: .medium))
    }

    /// [T-user-ask-expand-measured] True when the 3-line layout cuts the
    /// question off. Independent of `questionExpanded`, so an expanded
    /// question keeps its Show less.
    private var questionOverflows: Bool {
        questionFullHeight > questionClampedHeight + 1
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(questionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                // [T-user-ask-expand-measured] Two hidden copies at the same
                // width and font - capped at 3 lines and uncapped - measure
                // whether the collapsed text is cut off. They sit in the
                // background, so they never change the card's layout.
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        questionText
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: UserAskQuestionClampedHeightKey.self, value: g.size.height)
                            })
                        questionText
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: UserAskQuestionFullHeightKey.self, value: g.size.height)
                            })
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(UserAskQuestionClampedHeightKey.self) { h in
                    if abs(h - questionClampedHeight) > 0.5 { questionClampedHeight = h }
                }
                .onPreferenceChange(UserAskQuestionFullHeightKey.self) { h in
                    if abs(h - questionFullHeight) > 0.5 { questionFullHeight = h }
                }
                .padding(q.type == .confirm ? 8 : 0)
                .background(q.type == .confirm ? AnyShapeStyle(Color(UIColor.tertiarySystemFill)) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
                .padding(.bottom, 6)
            // [T-user-ask-expand-measured] Shown when the collapsed question
            // is actually truncated. It used to be `question.count > 140`,
            // which missed the common confirm case: monospaced text in a
            // padded box fits ~60 mixed CJK/Latin characters in 3 lines, so a
            // 61-140 character question was cut to "…" with no way to open it
            // (and a long one that fit got a useless toggle).
            if questionOverflows {
                Button {
                    questionExpanded.toggle()
                    UserAskPendingLayoutCache.setExpanded(questionExpanded, layoutKey)
                    UserAskCenter.shared.noteInteraction(requestId: ask.requestId)
                } label: {
                    Text(questionExpanded ? AppLocalized("Show less") : AppLocalized("Show more"))
                        .font(.system(size: t.secondary, weight: .medium))
                        .foregroundStyle(tint)
                        // A full-height row like every other control on this
                        // card; it was a bare ~26x15pt label.
                        .padding(.trailing, 16)
                        .frame(minHeight: UserAskTypography.minTapHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            switch q.type {
            case .options: optionsBody
            case .confirm: confirmBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var optionsBody: some View {
        if let options = q.options, !options.isEmpty {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                optionRow(i, o)
            }
        }
        otherRow
        if !q.isOpenEnded {
            choiceRow(icon: answer.delegated ? "checkmark.circle.fill" : "circle",
                      label: AppLocalized("You decide"), selected: answer.delegated) {
                var a = UserAskAnswer(); a.delegated = true; a.note = answer.note
                UserAskCenter.shared.updateAnswer(requestId: ask.requestId, index: index, a)
                haptic()
            }
        }
        noteRow
    }

    private func optionRow(_ i: Int, _ o: UserAskOption) -> some View {
        let selected = answer.selected.contains(i) && !answer.delegated
        let icon = q.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
        return Button {
            var a = answer
            a.delegated = false
            if q.multiSelect {
                if let pos = a.selected.firstIndex(of: i) { a.selected.remove(at: pos) } else { a.selected.append(i) }
            } else {
                a.selected = [i]
                a.otherText = nil
            }
            UserAskCenter.shared.updateAnswer(requestId: ask.requestId, index: index, a)
            haptic()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: t.icon))
                    .foregroundStyle(selected ? tint : ChatColors.tertiaryText)
                    .frame(width: t.icon + 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(o.label)
                            .font(.system(size: t.optionTitle, weight: selected ? .semibold : .regular))
                            .foregroundStyle(ChatColors.primaryText)
                        if i == 0 {
                            Text(AppLocalized("Recommended"))
                                .font(.system(size: t.chip, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(tint.opacity(0.14), in: Capsule())
                        }
                    }
                    if let d = o.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: t.optionDetail))
                            .foregroundStyle(ChatColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .frame(minHeight: UserAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(o.label), \(AppLocalized("option")) \(i + 1)/\(q.options?.count ?? 0)\(i == 0 ? ", " + AppLocalized("Recommended") : "")"))
    }

    private var otherRow: some View {
        let text = answer.otherText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = !text.isEmpty && !answer.delegated
        return choiceRow(icon: q.isOpenEnded ? "text.cursor" : (selected ? "largecircle.fill.circle" : "circle"),
                         label: selected ? text : (q.isOpenEnded ? AppLocalized("Type your answer…") : AppLocalized("Other…")),
                         selected: selected, trailingIcon: "mic") {
            UserAskInputPresenter.present(kind: .other, ask: ask, index: index)
        }
    }

    private var noteRow: some View {
        let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button {
            UserAskInputPresenter.present(kind: .note, ask: ask, index: index)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: note.isEmpty ? "plus" : "note.text")
                Text(note.isEmpty ? AppLocalized("Add a note") : note)
                    .lineLimit(1)
            }
            .font(.system(size: t.secondary))
            .foregroundStyle(note.isEmpty ? ChatColors.secondaryText : ChatColors.primaryText)
            .padding(.vertical, 7)
            .frame(minHeight: UserAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choiceRow(icon: String, label: String, selected: Bool, trailingIcon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: t.icon))
                    .foregroundStyle(selected ? tint : ChatColors.tertiaryText)
                    .frame(width: t.icon + 4)
                Text(label)
                    .font(.system(size: t.optionTitle, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? ChatColors.primaryText : ChatColors.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: t.secondary))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
            }
            .padding(.vertical, 7)
            .frame(minHeight: UserAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var confirmBody: some View {
        if let impact = q.impact, !impact.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: t.meta))
                    .foregroundStyle(tint)
                Text(impact)
                    .font(.system(size: t.secondary))
                    .foregroundStyle(ChatColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        let reason = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Button {
            UserAskInputPresenter.present(kind: .denyReason, ask: ask, index: index)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: reason.isEmpty ? "plus" : "arrow.uturn.backward")
                Text(reason.isEmpty ? AppLocalized("Cancel with a reason / do this instead") : reason)
                    .lineLimit(2)
            }
            .font(.system(size: t.secondary))
            .foregroundStyle(ChatColors.secondaryText)
            .padding(.vertical, 7)
            .frame(minHeight: UserAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Action bar

    @ViewBuilder
    private var actionBar: some View {
        switch q.type {
        case .options:
            // Previous and Next/Submit share the row equally; alone, the
            // primary button spans it.
            HStack(spacing: 10) {
                if PendingAsk.showsPrevious(at: index) {
                    previousButton(fill: true)
                }
                let last = !(0..<ask.questions.count).contains { $0 != index && !ask.submitted.contains($0) }
                Button(last ? AppLocalized("Submit") : AppLocalized("Next")) {
                    UserAskCenter.shared.submitQuestion(requestId: ask.requestId, index: index)
                    haptic()
                }
                .buttonStyle(UserAskButtonStyle(kind: .primary, tint: tint, fill: true, fontSize: t.button))
                .disabled(!answer.isComplete(for: q))
            }
        case .confirm:
            // [T-user-ask-confirm-row] One row: Previous on the left, Cancel and
            // Allow together on the right. A confirm button acts on one tap,
            // so Previous is kept apart from them by the flexible gap rather than
            // sitting next to one; without Previous the pair is still right-aligned.
            // [T-user-ask-no-policy] Two choices only - Cancel and Allow;
            // the app records no "always" rule.
            // A long locale at a large font falls back to the pair on its own
            // right-aligned row with Previous below on the left, then to a stack.
            let showsPrevious = PendingAsk.showsPrevious(at: index)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if showsPrevious {
                        previousButton(fill: false)
                    }
                    Spacer(minLength: 12)
                    cancelButton
                    allowOnceButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        cancelButton
                        allowOnceButton
                    }
                    if showsPrevious {
                        previousButton(fill: false)
                    }
                }
                VStack(alignment: .trailing, spacing: 8) {
                    cancelButton
                    allowOnceButton
                    if showsPrevious {
                        previousButton(fill: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Back to the previous question - the same string and secondary style as
    /// on an options card. Only shows it; submits and changes nothing.
    private func previousButton(fill: Bool) -> some View {
        Button(AppLocalized("Previous")) {
            UserAskCenter.shared.goTo(requestId: ask.requestId, index: index - 1)
        }
        .buttonStyle(UserAskButtonStyle(kind: .secondary, tint: tint, fill: fill, fontSize: t.button))
    }

    private var cancelButton: some View {
        // Cancel first: the safe choice sits where the thumb lands.
        Button(AppLocalized("Cancel")) {
            UserAskCenter.shared.confirm(requestId: ask.requestId, index: index, choice: .deny, note: answer.note)
            haptic()
        }
        .buttonStyle(UserAskButtonStyle(kind: .primary, tint: .gray, fontSize: t.button))
        .accessibilitySortPriority(2)
    }

    private var allowOnceButton: some View {
        // [T-user-ask-allow-label] "Allow", not "Allow once": the app keeps no
        // "always" rule ([T-user-ask-no-policy]), so there is nothing to contrast with.
        Button(AppLocalized("Allow")) {
            UserAskCenter.shared.confirm(requestId: ask.requestId, index: index, choice: .approve)
            haptic(heavy: q.risk == .high)
        }
        .buttonStyle(UserAskButtonStyle(kind: .secondary, tint: tint, fontSize: t.button))
    }

    // MARK: Helpers

    private func haptic(heavy: Bool = false) {
        UIImpactFeedbackGenerator(style: heavy ? .medium : .light).impactOccurred()
    }
}

/// [T-user-ask-expand-measured] Hidden question probes (3-line and full).
private struct UserAskQuestionClampedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct UserAskQuestionFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct UserAskBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct UserAskButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    let tint: Color
    /// Stretch to the width the row offers (shared equally with siblings).
    var fill: Bool = false
    /// UserAskTypography.button of the view using the style.
    var fontSize: CGFloat = UserAskTypography(body: UserAskTypography.bodyReference).button
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(minWidth: 72, maxWidth: fill ? .infinity : nil, minHeight: UserAskTypography.minTapHeight)
            .foregroundStyle(kind == .primary ? Color.white : tint)
            .background(
                Capsule(style: .continuous)
                    .fill(kind == .primary ? tint : tint.opacity(0.14))
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - Resolved

private struct UserAskResolvedCard: View {
    @ObservedObject var block: AssistantBlock
    let questions: [UserAskQuestion]
    let results: [UserAskCardModel.Result]
    let source: UserAskAnswerSource?
    let dismissReason: UserAskDismissReason?
    @ObservedObject private var fonts = FontSettings.shared
    private var t: UserAskTypography { .current }
    /// [T-in-chat-search] Set by the list cell; lets the topic, answer and
    /// questions carry search highlights.
    @Environment(\.chatSearchMessageId) private var searchMessageId

    private var tint: Color {
        if dismissReason != nil || results.allSatisfy({ $0.status == .dismissed }) { return .gray }
        return UserAskTint.color(for: questions.first)
    }

    private var isConfirm: Bool { questions.first?.type == .confirm }

    // Same shape and height as the sub-agent card (HelperBlockView): a 34pt
    // round icon, then the topic over a status + answer line. Tapping expands
    // the full questions and answers below.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                // A user tap. The list keeps this card's top in place
                // (ToggleAnchorMath) and applies the toggle itself, in the same
                // animated pass that resizes the cell - flipping the state here
                // drew the new content a frame before the cell was resized.
                let request = ToggleRequest { [block] in block.isThinkingExpanded.toggle() }
                NotificationCenter.default.post(name: .thinkingBlockToggled, object: block.id,
                                                userInfo: [ToggleAnchorMath.anchorTopKey: true,
                                                           ToggleAnchorMath.toggleRequestKey: request])
                // No list showing this card (nothing ran it): toggle anyway.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { request.run() }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: glyph)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if let badge {
                                Text(badge)
                                    .font(.system(size: t.chip, weight: .semibold))
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(tint.opacity(0.15))
                                    .clipShape(Capsule())
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            SearchHighlightText(topic, blockId: block.id, field: .title, messageId: searchMessageId)
                                .font(isConfirm ? .system(size: t.resolvedTopic - 1, weight: .medium, design: .monospaced)
                                                : .system(size: t.resolvedTopic, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            // Status wins the width but may truncate, so the
                            // answer after it is never squeezed to nothing.
                            Text(status)
                                .font(.system(size: t.meta, weight: .semibold))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if !digest.isEmpty {
                                SearchHighlightText(digest, blockId: block.id, field: .activity, messageId: searchMessageId)
                                    .font(.system(size: t.meta))
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .lineLimit(1)
                                    .frame(minWidth: 60, alignment: .leading)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: block.isThinkingExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if block.isThinkingExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                        VStack(alignment: .leading, spacing: 2) {
                            SearchHighlightText(q.question, blockId: block.id, field: .question(i), messageId: searchMessageId)
                                .font(.system(size: t.resolvedDetail))
                                .foregroundStyle(ChatColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if i < results.count {
                                Text(UserAskCardModel.summary(results[i], question: q)
                                     + (results[i].note.map { $0.isEmpty ? "" : " · " + $0 } ?? ""))
                                    .font(.system(size: t.secondary, weight: .medium))
                                    .foregroundStyle(ChatColors.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.leading, 46)
                .textSelection(.enabled)
                // Fades in / out while the card's height animates.
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 0.8))
        .opacity(dismissReason == .supersededByUserMessage ? 0.6 : 1)
        // [T-user-ask-expand-anim] While the height animates, the cell and
        // the card are briefly different heights; pin the card to the top of
        // the cell (the hosting content is otherwise centred) so its top
        // edge never moves. Measuring is unaffected: with only a maximum,
        // the frame takes the card's own height.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var glyph: String {
        if dismissReason != nil || results.allSatisfy({ $0.status == .dismissed }) { return "xmark" }
        if results.contains(where: { UserAskCardModel.isTimeout($0.status) }) { return "timer" }
        if results.contains(where: { $0.status == .denied }) { return "xmark" }
        return "checkmark"
    }

    private var statusColor: Color {
        if dismissReason != nil { return ChatColors.secondaryText }
        if results.contains(where: { UserAskCardModel.isTimeout($0.status) }) { return ChatColors.secondaryText }
        if results.contains(where: { $0.status == .denied }) { return ChatColors.secondaryText }
        return tint
    }

    /// The model's header tag for a single question; for several, the tags
    /// are the topic line instead.
    private var badge: String? {
        guard questions.count == 1, let h = questions.first?.header, !h.isEmpty else { return nil }
        return h
    }

    /// What was asked: the question (the command, for a confirm), or the
    /// questions' header tags when there are several.
    /// [T-in-chat-search] Shared with the search (ChatSearchDisplayText).
    private var topic: String { ChatSearchDisplayText.userAskTopic(questions) }

    private var status: String {
        var s: String
        switch dismissReason {
        case .supersededByUserMessage?: s = AppLocalized("Replaced by your new message")
        case .stopped?: s = AppLocalized("Stopped")
        case .userClosedCard?: s = AppLocalized("Skipped")
        case .replacedByNewAsk?: s = AppLocalized("Replaced by a newer question")
        case nil:
            if results.count > 1 {
                let answered = results.filter { !UserAskCardModel.isTimeout($0.status) && $0.status != .dismissed }.count
                s = AppLocalized("\(answered) of \(results.count) answered")
            } else {
                s = results.first.map { Self.shortStatus($0.status) } ?? AppLocalized("Skipped")
            }
        }
        if source == .notification { s += " " + AppLocalized("(from notification)") }
        return s
    }

    /// Status without the answer (the answer goes in `digest`).
    private static func shortStatus(_ s: UserAskResultStatus) -> String {
        switch s {
        case .answered, .other: return AppLocalized("Answered")
        case .delegated: return AppLocalized("Left to Minis")
        case .approved: return AppLocalized("Allowed once")
        case .denied: return AppLocalized("Cancelled")
        case .timeout: return AppLocalized("Timed out")
        case .dismissed: return AppLocalized("Skipped")
        case .unavailable: return AppLocalized("Could not ask")
        }
    }

    /// One line of what the user actually said, question by question: the
    /// chosen labels or typed text; "Left to Minis" when delegated; a cancel
    /// reason for a confirm.
    private var digest: String {
        // [T-in-chat-search] Shared with the search (ChatSearchDisplayText).
        return ChatSearchDisplayText.userAskDigest(results, dismissed: dismissReason != nil)
    }
}

// MARK: - Input sheet (Other… / note / cancel reason)

enum UserAskInputKind: Equatable { case other, note, denyReason }

@MainActor
enum UserAskInputPresenter {
    static func present(kind: UserAskInputKind, ask: PendingAsk, index: Int) {
        UserAskCenter.shared.noteInteraction(requestId: ask.requestId)
        guard let top = topViewController() else { return }
        let a = ask.answers[index]
        let initial: String
        switch kind {
        case .other: initial = a.otherText ?? ""
        case .note, .denyReason: initial = a.note ?? ""
        }
        // Dismiss THIS sheet only, at most once: the sheet can ask to close
        // from more than one path (Done, Cancel, its question being settled),
        // and a second `top.dismiss` would dismiss whatever `top` is.
        weak var hostRef: UIViewController?
        let close = {
            guard let host = hostRef, host.presentingViewController != nil, !host.isBeingDismissed else { return }
            host.presentingViewController?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: UserAskInputSheet(
            kind: kind, requestId: ask.requestId, index: index,
            question: ask.questions[index].question, initial: initial,
            onChange: { text in save(kind: kind, requestId: ask.requestId, index: index, text: text, commit: false) },
            onDone: { text in
                save(kind: kind, requestId: ask.requestId, index: index, text: text, commit: true)
                close()
            },
            onCancel: { close() }))
        hostRef = host
        if let sheet = host.sheetPresentationController {
            // [T-user-ask-dictation-style] One detent. With .medium as well,
            // dropping the keyboard for dictation let the sheet fall back to
            // the medium detent - a height jump - and on iOS 26 a partial-
            // height sheet is translucent Liquid Glass, so the whole sheet
            // turned grey with the conversation (blue card, red Stop button)
            // bleeding through. Full height keeps the text state's opaque
            // background in both input modes.
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }

    private static func save(kind: UserAskInputKind, requestId: String, index: Int, text: String, commit: Bool) {
        guard var a = UserAskCenter.shared.asks[requestId]?.answers[index] else { return }
        let t = String(text.prefix(UserAskParser.maxInputLength))
        switch kind {
        case .other:
            a.otherText = t
            if commit, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Last action wins: typing an answer replaces a picked option.
                if UserAskCenter.shared.asks[requestId]?.questions[index].multiSelect != true { a.selected = [] }
                a.delegated = false
            }
        case .note, .denyReason:
            a.note = t
        }
        UserAskCenter.shared.updateAnswer(requestId: requestId, index: index, a)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

private struct UserAskInputSheet: View {
    let kind: UserAskInputKind
    let requestId: String
    let index: Int
    let question: String
    let initial: String
    let onChange: (String) -> Void
    let onDone: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @ObservedObject private var center = UserAskCenter.shared
    @ObservedObject private var fonts = FontSettings.shared
    private var t: UserAskTypography { .current }
    /// [T-user-ask-dictation-double] Voice input is the chat composer's own
    /// inline voice panel and view model (configured ASR provider, VAD,
    /// system fallback) - not a second dictation stack. One instance per
    /// sheet: the VAD belongs to the view model.
    @StateObject private var voiceVM = VoiceInputViewModel()
    @State private var voiceActive = false
    @State private var closing = false
    /// The composer's remembered expanded/compact choice, put back when
    /// dictation here ends (this sheet shows the panel compact).
    @State private var savedVoiceExpanded: Bool?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(question)
                    .font(.system(size: t.resolvedDetail))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                // [T-user-ask-dictation-below] The text box stays in place in both
                // modes: the voice panel mirrors its transcript into `text`, so
                // what has been said shows up here as it is recognised. While
                // dictating it takes no taps and no focus (no keyboard, no
                // accidental edit); a double tap stops dictation and starts
                // editing with the keyboard. Grows with the text between 3 and 8
                // lines, then scrolls. One hairline frame: a TextEditor in a
                // filled box read as a thick double frame in dark mode.
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: t.question))
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(UIColor.separator), lineWidth: 0.5)
                    )
                    .allowsHitTesting(!voiceActive)
                    .overlay {
                        if voiceActive {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { editFromVoice() }
                                .accessibilityElement()
                                .accessibilityLabel(Text(text.isEmpty ? title : text))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: Text(AppLocalized("Edit"))) { editFromVoice() }
                        }
                    }
                HStack {
                    Button {
                        voiceActive ? leaveVoice() : enterVoice()
                    } label: {
                        Label(voiceActive ? AppLocalized("Stop dictation") : AppLocalized("Dictate"),
                              systemImage: voiceActive ? "keyboard" : "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("\(text.count)/\(UserAskParser.maxInputLength)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if voiceActive {
                    // [T-user-ask-dictation-below] The composer's own voice panel,
                    // under the Dictate / Stop dictation button, in its compact
                    // layout (mic + model chip): the text box above already shows
                    // the transcript, so the expanded layout's transcript band would
                    // show it twice and offer a second, competing way to edit it.
                    // The sheet is full height and top-aligned, so neither this
                    // panel coming and going nor the keyboard rising moves the text
                    // box or the button row.
                    InlineVoiceInputView(viewModel: voiceVM, inputText: $text)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color(UIColor.separator), lineWidth: 0.5)
                        )
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .animation(.easeOut(duration: 0.2), value: voiceActive)
            // The same opaque sheet background in both input modes (light and
            // dark follow the system colour).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .onChange(of: text) { t in onChange(t) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { leaveVoice(); onCancel() } }
                ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { leaveVoice(); onDone(text) } }
            }
        }
        .onAppear {
            text = initial
            focused = true
        }
        // The question this sheet answers was settled elsewhere (timeout,
        // superseded by a new message, answered from the notification, Stop)
        // or the wizard moved on: close, which also tears the voice panel down
        // and releases the microphone. The draft is already saved.
        .onReceive(center.$asks) { asks in
            guard !closing, UserAskInputSheet.shouldClose(ask: asks[requestId], index: index) else { return }
            closing = true
            leaveVoice()
            onCancel()
        }
    }

    // BEGIN UserAskInputSheetClose
    /// The sheet only makes sense while its question is still open.
    static func shouldClose(ask: PendingAsk?, index: Int) -> Bool {
        guard let ask else { return true }
        return ask.state != .pending || ask.currentIndex != index
    }
    // END UserAskInputSheetClose

    private var title: String {
        switch kind {
        case .other: return AppLocalized("Your answer")
        case .note: return AppLocalized("Add a note")
        case .denyReason: return AppLocalized("Reason / do this instead")
        }
    }

    /// Composer order (MicButton): drop the keyboard first, then voice mode -
    /// never both. The explicit resign covers a responder FocusState lost
    /// track of; the system keyboard's own dictation goes away with it.
    private func enterVoice() {
        focused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        // [T-user-ask-dictation-below] Compact panel here (see body). The
        // expanded/compact choice is shared with the chat composer, so remember
        // it and put it back in leaveVoice().
        let mode = VoiceModePreference.shared
        if savedVoiceExpanded == nil { savedVoiceExpanded = mode.expanded }
        mode.enteredFromText = false
        mode.expanded = false
        voiceActive = true
        // The user asked to dictate: start listening once the panel has
        // prepared its provider (its onAppear), via its own mic action.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard voiceActive, voiceVM.state == .waiting else { return }
            voiceVM.handleMainButtonTap()
        }
    }

    /// Back to typing. As in the composer the keyboard stays down; the
    /// panel's onDisappear stops the VAD and frees the microphone, and this
    /// stops it right away for the paths that close the sheet.
    private func leaveVoice() {
        guard voiceActive else { return }
        voiceVM.stopListening()
        voiceActive = false
        if let saved = savedVoiceExpanded {
            VoiceModePreference.shared.expanded = saved
            savedVoiceExpanded = nil
        }
    }

    /// [T-user-ask-dictation-below] Double tap on the text box while
    /// dictating: stop dictation, then focus the box so the keyboard comes up
    /// and editing starts where the transcript left it. Focus is set on the
    /// next turn of the run loop, after the panel has started leaving, so the
    /// panel fading out and the keyboard rising happen together.
    private func editFromVoice() {
        leaveVoice()
        DispatchQueue.main.async { focused = true }
    }
}

// MARK: - Summary (mini preview tile + tool sheet)

// BEGIN UserAskSummary
/// [T-user-ask-thumbnail] A readable digest of one user_ask for the mini
/// preview tile and the tool sheet. They used to print the raw tool output
/// with no title: "Tool: user_ask" while waiting, the result JSON once
/// answered.
///
/// One row per question: a short topic (the header chip, else the question
/// cut short) and what happened to it, in the same words the card uses.
struct UserAskSummaryRow: Equatable {
    var topic: String
    var value: String
    /// Not the user's own choice (timed out, skipped, cancelled, …): drawn
    /// in a neutral colour instead of the accent.
    var muted: Bool
}

enum UserAskSummary {
    /// The tile is 100pt wide: a topic longer than a header chip (max 12)
    /// pushes the answer off the line. The sheet has room for more.
    static let tileTopicLimit = 14
    static let sheetTopicLimit = 80

    static func topic(_ q: UserAskQuestion, limit: Int = tileTopicLimit) -> String {
        if let h = q.header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { return h }
        let flat = q.question.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func value(_ status: UserAskResultStatus, answer: [String]) -> (text: String, muted: Bool) {
        let given = answer.filter { !$0.isEmpty }.joined(separator: ", ")
        switch status {
        case .answered, .other: return (given.isEmpty ? AppLocalized("Answered") : given, false)
        case .delegated: return (AppLocalized("Left to Minis"), false)
        case .approved: return (AppLocalized("Allow"), false)
        case .denied: return (AppLocalized("Cancel"), true)
        case .timeout: return (AppLocalized("Timed out"), true)
        case .dismissed: return (AppLocalized("Skipped"), true)
        case .unavailable: return (AppLocalized("Could not ask"), true)
        }
    }

    /// Still waiting: the waiting line, then each question's topic.
    static func pendingRows(_ questions: [UserAskQuestion], topicLimit: Int = tileTopicLimit) -> [UserAskSummaryRow] {
        [UserAskSummaryRow(topic: AppLocalized("Waiting for your answer…"), value: "", muted: false)]
            + questions.map { UserAskSummaryRow(topic: topic($0, limit: topicLimit), value: "", muted: true) }
    }

    /// Resolved: one row per question, in order. A question with no result
    /// entry (a dismissal that recorded none) reads as skipped.
    static func resolvedRows(_ questions: [UserAskQuestion],
                             results: [(status: UserAskResultStatus, answer: [String])],
                             topicLimit: Int = tileTopicLimit) -> [UserAskSummaryRow] {
        questions.enumerated().map { i, q in
            let v = i < results.count ? value(results[i].status, answer: results[i].answer)
                                      : value(.dismissed, answer: [])
            return UserAskSummaryRow(topic: topic(q, limit: topicLimit), value: v.text, muted: v.muted)
        }
    }

    /// One muted row titled `title` (UserAskSummary.notSentTitle).
    static func notAskedRows(title: String) -> [UserAskSummaryRow] {
        [UserAskSummaryRow(topic: title, value: "", muted: true)]
    }

    /// How many rows fit under the title on the fixed tile, from the two
    /// derived sizes; line height ≈ 1.25 × size plus 1pt row spacing.
    static func capacity(tileHeight: Double, titleSize: Double, lineSize: Double) -> Int {
        let usable = tileHeight - 4 - 3 - (titleSize * 1.25 + 1)
        return max(1, Int(usable / (lineSize * 1.25 + 1)))
    }

    /// Rows that fit; when they do not all fit the last slot becomes "+N".
    static func fit(_ rows: [UserAskSummaryRow], capacity: Int) -> (rows: [UserAskSummaryRow], more: Int) {
        guard rows.count > capacity else { return (rows, 0) }
        let shown = max(0, capacity - 1)
        return (Array(rows.prefix(shown)), rows.count - shown)
    }
}

/// [T-user-ask-tile-rich] What the 100x65pt mini preview tile shows: a
/// miniature of the card, not just a list of header chips. Pending: the
/// question the user is on - card title with its header chip and progress,
/// the question (the command, for a confirm), the impact line or the
/// options with what is picked so far. Resolved: each question's text with
/// its answer under it.
struct UserAskTileLine: Equatable {
    enum Kind: Equatable {
        case question, command, impact, topic
        case option(marker: String, selected: Bool)
        case answer(muted: Bool)
    }
    var kind: Kind
    var text: String
    /// Lines this entry may wrap to (and what it costs in the line budget).
    var maxLines: Int
}

struct UserAskTileContent: Equatable {
    var title: String
    /// "1/3" on a multi-question ask, else empty.
    var trailing: String
    var lines: [UserAskTileLine]
}

extension UserAskSummary {
    /// The card's own title for question `q` ([T-user-ask-card] wording).
    static func cardTitle(_ q: UserAskQuestion) -> String {
        switch q.type {
        case .options: return AppLocalized("Needs your answer")
        case .confirm: return q.risk == .high ? AppLocalized("High-risk action") : AppLocalized("Needs your approval")
        }
    }

    private static func flat(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waiting for an answer: question `current` as a miniature card.
    static func pendingTile(questions: [UserAskQuestion], current: Int,
                            answer: UserAskAnswer?) -> UserAskTileContent {
        guard questions.indices.contains(current) else {
            return UserAskTileContent(title: AppLocalized("Question for you"), trailing: "", lines: [])
        }
        let q = questions[current]
        var title = cardTitle(q)
        if let h = q.header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { title += " · " + h }
        let trailing = questions.count > 1 ? "\(current + 1)/\(questions.count)" : ""
        var lines: [UserAskTileLine] = []
        let text = flat(q.question)
        if !text.isEmpty {
            lines.append(UserAskTileLine(kind: q.type == .confirm ? .command : .question, text: text, maxLines: 2))
        }
        switch q.type {
        case .confirm:
            if let impact = q.impact.map(flat), !impact.isEmpty {
                lines.append(UserAskTileLine(kind: .impact, text: impact, maxLines: 2))
            }
        case .options:
            let picked = Set(answer?.selected ?? [])
            for (i, option) in (q.options ?? []).enumerated() {
                let on = picked.contains(i)
                let marker = q.multiSelect ? (on ? "☑" : "☐") : (on ? "●" : "○")
                lines.append(UserAskTileLine(kind: .option(marker: marker, selected: on), text: flat(option.label), maxLines: 1))
            }
            if let other = answer?.otherText.map(flat), !other.isEmpty {
                lines.append(UserAskTileLine(kind: .option(marker: q.multiSelect ? "☑" : "●", selected: true),
                                             text: other, maxLines: 1))
            }
        }
        return UserAskTileContent(title: title, trailing: trailing, lines: lines)
    }

    /// Answered (or otherwise settled): each question's text, then its answer.
    static func resolvedTile(_ questions: [UserAskQuestion],
                             results: [(status: UserAskResultStatus, answer: [String])]) -> UserAskTileContent {
        var lines: [UserAskTileLine] = []
        for (i, q) in questions.enumerated() {
            let text = flat(q.question)
            let header = q.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let topicText = text.isEmpty ? header : text
            if !topicText.isEmpty {
                lines.append(UserAskTileLine(kind: .topic, text: topicText, maxLines: questions.count == 1 ? 2 : 1))
            }
            let v = i < results.count ? value(results[i].status, answer: results[i].answer) : value(.dismissed, answer: [])
            lines.append(UserAskTileLine(kind: .answer(muted: v.muted), text: v.text, maxLines: 1))
        }
        return UserAskTileContent(title: AppLocalized("Question for you"), trailing: "", lines: lines)
    }

    /// Entries that fit `capacity` lines (each costs its maxLines; a
    /// two-line entry squeezed into the last free line keeps one). What
    /// does not fit becomes "+N", which needs a line of its own.
    static func fitTile(_ lines: [UserAskTileLine], capacity: Int) -> (lines: [UserAskTileLine], more: Int) {
        let total = lines.reduce(0) { $0 + $1.maxLines }
        guard total > capacity else { return (lines, 0) }
        var budget = max(0, capacity - 1)
        var shown: [UserAskTileLine] = []
        for line in lines {
            guard budget > 0 else { break }
            var l = line
            l.maxLines = min(l.maxLines, budget)
            budget -= l.maxLines
            shown.append(l)
        }
        return (shown, lines.count - shown.count)
    }
}
// END UserAskSummary

extension UserAskSummary {
    /// [T-user-ask-notsent-merge] "Question not sent", or "Question not sent
    /// (N times)" for a run of N > 1 rejected calls (UserAskNotSentGrouping).
    /// The count goes through the catalog's plural variants, never string
    /// concatenation, and the plural category follows the language the text
    /// is in: AppLocalized resolves it with Locale.current, which is the
    /// system's, so an in-app Russian on an English system would read
    /// "5 раза" instead of "5 раз".
    static func notSentTitle(count: Int) -> String {
        guard count > 1 else { return AppLocalized("Question not sent") }
        let bundle = AppBundle.current
        let locale = bundle.bundleURL.pathExtension == "lproj"
            ? Locale(identifier: bundle.bundleURL.deletingPathExtension().lastPathComponent)
            : Locale.current
        return String(localized: "Question not sent (\(count) times)", bundle: bundle, locale: locale)
    }
}

/// The digest of one user_ask block, in its two places: the mini preview
/// tile (`compact`) and the tool sheet's content area.
struct UserAskSummaryView: View {
    @ObservedObject var block: AssistantBlock
    var compact: Bool
    @ObservedObject private var center = UserAskCenter.shared
    @ObservedObject private var notSent = UserAskNotSentStore.shared
    @ObservedObject private var fonts = FontSettings.shared
    private var t: UserAskTypography { .current }

    static let tileSize = CGSize(width: 100, height: 65)

    private var rows: [UserAskSummaryRow] {
        let live = center.ask(forToolUseId: block.toolUseId)
        let request = UserAskCardModel.request(block)
        let phase = UserAskCardPhase.resolve(
            livePending: live?.state == .pending,
            liveTerminal: live?.state.isTerminal == true,
            hasContent: !block.content.isEmpty,
            requestParses: request != nil,
            callEnded: UserAskCardPhase.callEnded(block.toolStatus)
        )
        let limit = compact ? UserAskSummary.tileTopicLimit : UserAskSummary.sheetTopicLimit
        switch phase {
        case .pending:
            return UserAskSummary.pendingRows(live?.questions ?? [], topicLimit: limit)
        case .resolvedLive:
            return UserAskSummary.resolvedRows(live?.questions ?? [], results: Self.entries(live?.resultJSON ?? ""),
                                               topicLimit: limit)
        case .resolvedStored:
            return UserAskSummary.resolvedRows(request?.questions ?? [], results: Self.entries(block.content),
                                               topicLimit: limit)
        case .notAsked:
            return UserAskSummary.notAskedRows(title: UserAskSummary.notSentTitle(count: notSent.role(block.id).count))
        case .waiting:
            return UserAskSummary.pendingRows(request?.questions ?? [], topicLimit: limit)
        }
    }

    private static func entries(_ json: String) -> [(status: UserAskResultStatus, answer: [String])] {
        UserAskCardModel.results(json).map { ($0.status, $0.answer) }
    }

    var body: some View {
        if compact { tile } else { sheet }
    }

    // MARK: Tile (always dark, like every other tool's tile)

    /// [T-user-ask-tile-rich] The tile's content and the tint of the question
    /// it shows (the card's blue / orange / red); nil = the list rows.
    private var tileContent: (content: UserAskTileContent, tint: Color)? {
        let live = center.ask(forToolUseId: block.toolUseId)
        let request = UserAskCardModel.request(block)
        let phase = UserAskCardPhase.resolve(
            livePending: live?.state == .pending,
            liveTerminal: live?.state.isTerminal == true,
            hasContent: !block.content.isEmpty,
            requestParses: request != nil,
            callEnded: UserAskCardPhase.callEnded(block.toolStatus)
        )
        switch phase {
        case .pending:
            guard let live, live.questions.indices.contains(live.currentIndex) else { return nil }
            let i = live.currentIndex
            return (UserAskSummary.pendingTile(questions: live.questions, current: i, answer: live.answers[i]),
                    UserAskTint.color(for: live.questions[i]))
        case .waiting:
            guard let q = request?.questions, let first = q.first else { return nil }
            return (UserAskSummary.pendingTile(questions: q, current: 0, answer: nil), UserAskTint.color(for: first))
        case .resolvedLive:
            guard let live else { return nil }
            return (UserAskSummary.resolvedTile(live.questions, results: Self.entries(live.resultJSON ?? "")), Color.accentColor)
        case .resolvedStored:
            return (UserAskSummary.resolvedTile(request?.questions ?? [], results: Self.entries(block.content)),
                    Color.accentColor)
        case .notAsked:
            return nil
        }
    }

    @ViewBuilder
    private var tile: some View {
        if let rich = tileContent {
            richTile(rich.content, tint: rich.tint)
        } else {
            listTile
        }
    }

    private func richTile(_ content: UserAskTileContent, tint: Color) -> some View {
        let capacity = UserAskSummary.capacity(tileHeight: Self.tileSize.height,
                                               titleSize: t.thumbTitle, lineSize: t.thumbLine)
        let fitted = UserAskSummary.fitTile(content.lines, capacity: capacity)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(content.title)
                    .font(.system(size: t.thumbTitle, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !content.trailing.isEmpty {
                    Spacer(minLength: 2)
                    Text(verbatim: content.trailing)
                        .font(.system(size: t.thumbLine, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .fixedSize()
                }
            }
            .padding(.bottom, 1)
            ForEach(Array(fitted.lines.enumerated()), id: \.offset) { _, line in
                tileLineText(line, tint: tint)
                    .lineLimit(line.maxLines)
                    .truncationMode(.tail)
            }
            if fitted.more > 0 {
                Text(verbatim: "+\(fitted.more)")
                    .font(.system(size: t.thumbLine, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height, alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    private func tileLineText(_ line: UserAskTileLine, tint: Color) -> Text {
        let size = t.thumbLine
        switch line.kind {
        case .question:
            return Text(line.text).font(.system(size: size, weight: .medium)).foregroundColor(Color.white.opacity(0.9))
        case .command:
            return Text(line.text).font(.system(size: size, design: .monospaced)).foregroundColor(Color.white.opacity(0.85))
        case .impact:
            return Text(verbatim: "⚠ ").font(.system(size: size)).foregroundColor(tint)
                + Text(line.text).font(.system(size: size)).foregroundColor(Color.white.opacity(0.6))
        case .topic:
            return Text(line.text).font(.system(size: size)).foregroundColor(Color.white.opacity(0.6))
        case let .option(marker, selected):
            return Text(verbatim: marker + " ").font(.system(size: size)).foregroundColor(selected ? tint : Color.white.opacity(0.45))
                + Text(line.text).font(.system(size: size, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? tint : Color.white.opacity(0.7))
        case let .answer(muted):
            return Text(verbatim: "→ ").font(.system(size: size)).foregroundColor(Color.white.opacity(0.35))
                + Text(line.text).font(.system(size: size, weight: .medium))
                    .foregroundColor(muted ? Color.white.opacity(0.45) : tint)
        }
    }

    /// The plain list: "Question not sent" and anything without a parsed request.
    private var listTile: some View {
        let capacity = UserAskSummary.capacity(tileHeight: Self.tileSize.height,
                                               titleSize: t.thumbTitle, lineSize: t.thumbLine)
        let fitted = UserAskSummary.fit(rows, capacity: capacity)
        return VStack(alignment: .leading, spacing: 1) {
            Text(AppLocalized("Question for you"))
                .font(.system(size: t.thumbTitle, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.bottom, 1)
            ForEach(Array(fitted.rows.enumerated()), id: \.offset) { _, row in
                rowText(row, size: t.thumbLine)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if fitted.more > 0 {
                Text(verbatim: "+\(fitted.more)")
                    .font(.system(size: t.thumbLine, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height, alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    private func rowText(_ row: UserAskSummaryRow, size: CGFloat) -> Text {
        let topic = Text(row.topic)
            .font(.system(size: size, weight: row.value.isEmpty && !row.muted ? .semibold : .regular))
            .foregroundColor(row.value.isEmpty && !row.muted ? Color.accentColor : Color.white.opacity(0.6))
        guard !row.value.isEmpty else { return topic }
        return topic
            + Text(verbatim: " → ").font(.system(size: size)).foregroundColor(Color.white.opacity(0.35))
            + Text(row.value).font(.system(size: size, weight: .medium))
                .foregroundColor(row.muted ? Color.white.opacity(0.45) : Color.accentColor)
    }

    // MARK: Sheet (system colours, card sizes)

    private var sheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label(AppLocalized("Question for you"), systemImage: "questionmark.bubble")
                    .font(.system(size: t.title, weight: .semibold))
                    .foregroundStyle(ChatColors.primaryText)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.topic)
                            .font(.system(size: t.secondary, weight: row.value.isEmpty && !row.muted ? .semibold : .regular))
                            .foregroundStyle(row.value.isEmpty && !row.muted ? Color.accentColor : ChatColors.secondaryText)
                        if !row.value.isEmpty {
                            Text(row.value)
                                .font(.system(size: t.question, weight: .medium))
                                .foregroundStyle(row.muted ? ChatColors.secondaryText : ChatColors.primaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if case .failed? = block.toolStatus, center.ask(forToolUseId: block.toolUseId) == nil,
                   UserAskCardModel.request(block) == nil {
                    Text(AppLocalized("Details missing; the assistant will retry or ask in text"))
                        .font(.system(size: t.meta))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ChatColors.background)
    }
}
