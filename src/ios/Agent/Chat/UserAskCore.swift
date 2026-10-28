//
//  UserAskCore.swift
//  Minis
//
//  [T-user-ask] Pure model of the `user_ask` tool: request parsing and
//  validation, answers, result encoding, the timeout table, the ask state
//  machine and the notification category set. No UIKit, no app state — the
//  runtime (UserAskCenter), the card and the store build on it, and
//  MinisTests/Standalone/UserAskCoreTests.swift compiles this file by itself.
//

import Foundation

// BEGIN UserAskCore

// MARK: - Request

enum UserAskQuestionType: String, Codable, Equatable {
    case options
    case confirm
}

/// confirm only, and only how the card looks (orange / red). [T-user-ask-
/// no-policy] It changes no behaviour: the app decides nothing for the user.
enum UserAskRisk: String, Codable, Equatable {
    case medium
    case high
}

/// options only: the option the model would pick. [T-user-ask-no-policy]
/// Never applied - on timeout it is returned to the model as an unconfirmed
/// suggestion (the `default` field), nothing more.
enum UserAskDefault: Codable, Equatable {
    case option(Int)

    private enum CodingKeys: String, CodingKey { case kind, index }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .kind) == "option" else {
            // A persisted confirm default ("approve" / "cancel") from before
            // confirm defaults were removed; the question decoder drops it.
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "not an option default")
        }
        self = .option(try c.decode(Int.self, forKey: .index))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .option(let i):
            try c.encode("option", forKey: .kind)
            try c.encode(i, forKey: .index)
        }
    }
}

struct UserAskOption: Codable, Equatable {
    var label: String
    var description: String?
}

struct UserAskQuestion: Codable, Equatable {
    var type: UserAskQuestionType
    var question: String
    var header: String?
    /// nil for an open-ended options question (text input only).
    var options: [UserAskOption]?
    var multiSelect: Bool
    var impact: String?
    /// confirm only; medium when the model omits it. Visual only.
    var risk: UserAskRisk
    /// options only; see UserAskDefault.
    var defaultValue: UserAskDefault?

    var isOpenEnded: Bool { type == .options && (options?.isEmpty ?? true) }

    /// What a timeout returns as the unconfirmed suggestion: the label of the
    /// model's `default`, else of the recommended (first) option. None for a
    /// confirm or an open-ended question.
    var timeoutSuggestion: String? {
        guard type == .options, let options, !options.isEmpty else { return nil }
        if case .option(let i)? = defaultValue, options.indices.contains(i) { return options[i].label }
        return options[0].label
    }

    init(type: UserAskQuestionType, question: String, header: String?, options: [UserAskOption]?,
         multiSelect: Bool, impact: String?, risk: UserAskRisk, defaultValue: UserAskDefault?) {
        self.type = type
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.impact = impact
        self.risk = risk
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case type, question, header, options, multiSelect, impact, risk, defaultValue
    }

    /// Tolerant of records persisted before [T-user-ask-no-policy]: a confirm
    /// default ("approve" / "cancel") is dropped, a `scopeKey` ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(UserAskQuestionType.self, forKey: .type)
        question = try c.decode(String.self, forKey: .question)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        options = try c.decodeIfPresent([UserAskOption].self, forKey: .options)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        impact = try c.decodeIfPresent(String.self, forKey: .impact)
        risk = try c.decodeIfPresent(UserAskRisk.self, forKey: .risk) ?? .medium
        defaultValue = type == .options ? ((try? c.decodeIfPresent(UserAskDefault.self, forKey: .defaultValue)) ?? nil) : nil
    }
}

struct UserAskRequest: Codable, Equatable {
    var questions: [UserAskQuestion]
}

enum UserAskParser {
    static let maxQuestions = 4
    static let minOptions = 2
    static let maxOptions = 4
    /// Cap on free text coming back from the user (Other / note), so one
    /// answer cannot balloon the tool_result.
    static let maxInputLength = 1000

    /// "(Recommended)" style markers the model was told not to write; the UI
    /// adds its own. Stripped from labels so they never reach the result.
    static func stripRecommended(_ s: String) -> String {
        var out = s
        for marker in ["(Recommended)", "(recommended)", "（推荐）", "(推荐)", "Recommended:", "推荐："] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse and validate the tool arguments. Errors are phrased for the
    /// model: what was wrong and how to call it correctly.
    static func parse(_ args: [String: Any]) -> Result<UserAskRequest, UserAskParseError> {
        guard let raw = args["questions"] as? [Any], !raw.isEmpty else {
            return .failure(.init("`questions` is required: call user_ask again with 1-4 question objects, each with `type` and `question`."))
        }
        guard raw.count <= maxQuestions else {
            return .failure(.init("At most \(maxQuestions) questions per call; you sent \(raw.count). Ask only what changes your next step."))
        }
        var questions: [UserAskQuestion] = []
        for (i, item) in raw.enumerated() {
            guard let q = item as? [String: Any] else {
                return .failure(.init("questions[\(i)] must be an object."))
            }
            switch parseQuestion(q, index: i) {
            case .success(let parsed): questions.append(parsed)
            case .failure(let e): return .failure(e)
            }
        }
        return .success(UserAskRequest(questions: questions))
    }

    private static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// [T-user-ask-infer-type] The type a question's own fields imply when
    /// `type` is missing or not a known value. The schema still marks `type`
    /// required, but providers without strict schemas do not enforce it:
    /// deepseek-flash once sent a complete two-option question with no `type`
    /// (2026-10-07), the call was rejected, the card read "not sent", and the
    /// model had to resend the same question. Only unambiguous evidence counts:
    /// `options` / `default` / `multi_select` exist only on an options
    /// question, `impact` / `risk` only on a confirm. Nil when there is none,
    /// or both: a bare question could be an open-ended ask or an approval, and
    /// guessing wrong would turn an approval into a text field.
    static func inferredType(_ q: [String: Any]) -> UserAskQuestionType? {
        let hasOptions = (q["options"] as? [Any]).map { !$0.isEmpty } ?? false
        let optionsOnly = hasOptions || (q["default"] != nil && !(q["default"] is NSNull)) || q["multi_select"] is Bool
        let confirmOnly = string(q["impact"]) != nil || string(q["risk"]) != nil
        switch (optionsOnly, confirmOnly) {
        case (true, false): return .options
        case (false, true): return .confirm
        default: return nil
        }
    }

    private static func parseQuestion(_ q: [String: Any], index i: Int) -> Result<UserAskQuestion, UserAskParseError> {
        guard let type = string(q["type"]).flatMap(UserAskQuestionType.init(rawValue:)) ?? inferredType(q) else {
            return .failure(.init("questions[\(i)].type must be \"options\" or \"confirm\": options for a decision (or an open-ended question), confirm for approval of one action."))
        }
        guard let text = string(q["question"]) else {
            return .failure(.init("questions[\(i)].question is required."))
        }
        var options: [UserAskOption]?
        if let rawOptions = q["options"] as? [Any], !rawOptions.isEmpty {
            guard type == .options else {
                return .failure(.init("questions[\(i)] is a confirm: it takes no `options` (the card shows Cancel / Allow). Put the exact action in `question` and the consequence in `impact`."))
            }
            guard rawOptions.count >= minOptions else {
                return .failure(.init("questions[\(i)].options needs at least \(minOptions) genuinely different choices. With only one sensible choice, do not ask: take it and state the assumption. For an open question, omit `options`."))
            }
            guard rawOptions.count <= maxOptions else {
                return .failure(.init("questions[\(i)].options allows at most \(maxOptions) choices (the UI adds Other and You decide)."))
            }
            var parsed: [UserAskOption] = []
            for (j, o) in rawOptions.enumerated() {
                let dict = o as? [String: Any]
                let label = string(dict?["label"]) ?? string(o)
                guard let label else {
                    return .failure(.init("questions[\(i)].options[\(j)].label is required."))
                }
                parsed.append(UserAskOption(label: stripRecommended(label), description: string(dict?["description"])))
            }
            options = parsed
        }
        var risk = UserAskRisk.medium
        if type == .confirm, let r = string(q["risk"]) {
            guard let parsedRisk = UserAskRisk(rawValue: r) else {
                return .failure(.init("questions[\(i)].risk must be \"medium\" or \"high\"."))
            }
            risk = parsedRisk
        }
        // `default` is an options-only suggestion, returned on timeout and
        // never applied. A confirm has none: anything sent for one (as well
        // as a legacy `scope_key`) is ignored - it would change nothing.
        var def: UserAskDefault?
        if type == .options, let d = q["default"], !(d is NSNull) {
            let idx: Int? = (d as? Int) ?? (d as? NSNumber)?.intValue ?? string(d).flatMap(Int.init)
            guard let idx, let opts = options, opts.indices.contains(idx) else {
                return .failure(.init("questions[\(i)].default must be the 0-based index of one of its options (or omit it)."))
            }
            def = .option(idx)
        }
        let multi = (q["multi_select"] as? Bool) ?? false
        return .success(UserAskQuestion(
            type: type,
            question: text,
            header: string(q["header"]),
            options: options,
            multiSelect: type == .options && options != nil && multi,
            impact: type == .confirm ? string(q["impact"]) : nil,
            risk: risk,
            defaultValue: def
        ))
    }
}

struct UserAskParseError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Answers

enum UserAskConfirmChoice: String, Codable, Equatable {
    case approve
    case deny

    /// Persisted "approveAlways" (removed with "Always allow") reads as approve.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "approve", "approveAlways": self = .approve
        case "deny": self = .deny
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown confirm choice \(raw)"))
        }
    }
}

/// What the user has put into one question so far (also the persisted
/// draft: an unsubmitted Other text survives a restart).
struct UserAskAnswer: Codable, Equatable {
    var selected: [Int] = []
    var otherText: String?
    var note: String?
    var delegated = false
    var confirmChoice: UserAskConfirmChoice?

    /// The user settled this question (card "Next" may advance).
    func isComplete(for q: UserAskQuestion) -> Bool {
        switch q.type {
        case .confirm: return confirmChoice != nil
        case .options:
            if delegated { return true }
            if let t = otherText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return true }
            return !selected.isEmpty
        }
    }
}

// MARK: - Results

/// §20.5. The app returns what the user did; it never decides for them.
enum UserAskResultStatus: String, Codable, Equatable {
    case answered
    case other
    case delegated
    case approved
    case denied
    case timeout
    case dismissed
    case unavailable

    /// Reads a status from a stored result, including the ones removed with
    /// [T-user-ask-no-policy]: every old timeout_* is a timeout, and
    /// approved_always an approval.
    static func parse(_ raw: String) -> UserAskResultStatus? {
        if raw.hasPrefix("timeout_") { return .timeout }
        if raw == "approved_always" { return .approved }
        return UserAskResultStatus(rawValue: raw)
    }
}

/// One entry of the tool_result's `results` array.
struct UserAskResultEntry: Equatable {
    var index: Int
    var status: UserAskResultStatus
    /// A single label, or several for multi-select.
    var answer: [String]?
    var note: String?
    /// timeout only, options only: the unconfirmed suggestion (`default`).
    var suggestion: String? = nil

    func jsonObject() -> [String: Any] {
        var o: [String: Any] = ["i": index, "status": status.rawValue]
        if let answer {
            o["answer"] = answer.count == 1 ? answer[0] as Any : answer as Any
        }
        if let suggestion { o["default"] = suggestion }
        if let note, !note.isEmpty { o["note"] = note }
        return o
    }
}

enum UserAskDismissReason: String, Codable, Equatable {
    case supersededByUserMessage = "superseded_by_user_message"
    case userClosedCard = "user_closed_card"
    case stopped = "stopped"
    /// [T-user-ask-deferred] A deferred card replaced by a newer one in the
    /// same conversation (only one deferred card is kept open).
    case replacedByNewAsk = "replaced_by_new_ask"
}

enum UserAskResolver {
    private static func clip(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(UserAskParser.maxInputLength))
    }

    /// The entry for a question the user answered (in the app or from a
    /// notification).
    static func answered(_ q: UserAskQuestion, index: Int, answer a: UserAskAnswer) -> UserAskResultEntry {
        let note = clip(a.note)
        switch q.type {
        case .confirm:
            switch a.confirmChoice {
            case .approve: return .init(index: index, status: .approved, answer: nil, note: nil)
            case .deny, .none: return .init(index: index, status: .denied, answer: nil, note: note)
            }
        case .options:
            if a.delegated {
                return .init(index: index, status: .delegated, answer: nil, note: note)
            }
            let other = clip(a.otherText)
            let labels = (q.options ?? []).enumerated()
                .filter { a.selected.contains($0.offset) }
                .map(\.element.label)
            if labels.isEmpty, let other {
                return .init(index: index, status: .other, answer: [other], note: note)
            }
            // A multi-select may combine ticked options with typed text.
            var answer = labels
            if let other { answer.append(other) }
            if answer.isEmpty {
                return .init(index: index, status: .delegated, answer: nil, note: note)
            }
            return .init(index: index, status: .answered, answer: answer, note: note)
        }
    }

    /// §20.4 — a question nobody answered in time. The app takes NO action:
    /// nothing is applied, approved or cancelled. An options question carries
    /// the suggestion (`default`), marked as unconfirmed; a confirm has none.
    static func timedOut(_ q: UserAskQuestion, index: Int, timeoutMinutes: Int) -> UserAskResultEntry {
        let suggestion = q.timeoutSuggestion
        // [T-user-ask-prompt-consolidated] What to do on a timeout is said once,
        // in the tool description; the result only states what happened.
        return .init(index: index, status: .timeout, answer: nil,
                     note: "No answer within \(timeoutMinutes) min. Nothing was applied or approved.",
                     suggestion: suggestion)
    }

    static func dismissed(_ questions: [UserAskQuestion]) -> [UserAskResultEntry] {
        questions.indices.map { .init(index: $0, status: .dismissed, answer: nil, note: nil) }
    }

    static func unavailable(_ questions: [UserAskQuestion]) -> [UserAskResultEntry] {
        questions.indices.map { .init(index: $0, status: .unavailable, answer: nil, note: nil) }
    }

    /// Mix of answered and timed-out questions: the ones the user submitted
    /// keep their answer; every other one is a plain timeout (an unsubmitted
    /// draft is not taken as an answer).
    static func resolveOnTimeout(_ questions: [UserAskQuestion], answers: [UserAskAnswer], submitted: Set<Int>,
                                 timeoutMinutes: Int) -> [UserAskResultEntry] {
        questions.enumerated().map { i, q in
            let a = i < answers.count ? answers[i] : UserAskAnswer()
            if submitted.contains(i), a.isComplete(for: q) {
                return answered(q, index: i, answer: a)
            }
            return timedOut(q, index: i, timeoutMinutes: timeoutMinutes)
        }
    }

    static func encode(_ entries: [UserAskResultEntry]) -> String {
        let obj: [String: Any] = ["results": entries.map { $0.jsonObject() }]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"results\":[]}" }
        return s
    }
}

// MARK: - State machine

enum UserAskState: String, Codable, Equatable {
    case pending
    case answered
    case timedOut = "timed_out"
    case dismissed
    case cancelled

    var isTerminal: Bool { self != .pending }
}

enum UserAskAnswerSource: String, Codable, Equatable {
    case app
    case notification
    case timeout
}

/// Result of submitting one wizard question.
enum UserAskSubmitOutcome: Equatable {
    case rejected            // not pending, or the answer is incomplete
    case advanced(to: Int)   // the next unsubmitted question
    case complete            // all submitted - resolve the ask
}

/// One pending (or finished) ask. Persisted as JSON; the runtime keeps one
/// per request in memory as well. Every transition goes through `resolve`,
/// which accepts only the first terminal state (first come, first served
/// between the card, a notification action and the timeout).
struct PendingAsk: Codable, Equatable {
    var requestId: String
    var sessionId: String
    var toolCallId: String
    var questions: [UserAskQuestion]
    var answers: [UserAskAnswer]
    /// Questions whose "Next"/"Submit" was pressed (wizard progress).
    var submitted: Set<Int> = []
    var currentIndex: Int = 0
    var state: UserAskState = .pending
    var source: UserAskAnswerSource?
    var dismissReason: UserAskDismissReason?
    var createdAt: Date
    /// Wall-clock deadline; nil = wait indefinitely (timeoutMinutes 0).
    var expiresAt: Date?
    var timeoutMinutes: Int
    /// Final tool_result JSON once resolved.
    var resultJSON: String?
    /// Set once the tool_result was handed to the agent loop.
    var consumed = false
    var sessionTitle: String?
    /// [T-user-ask-deferred] Asked in a run no one could answer: the tool
    /// returned `deferred` at once, the card stays open with no countdown, and
    /// the answer goes to the conversation as the user's next message.
    /// Optional so records saved before it decode.
    var deferred: Bool?
    var isDeferred: Bool { deferred == true }
    /// [T-user-ask-notify-once] The question index a system notification was
    /// last posted for. Each question alerts once; leaving the app again does
    /// not re-alert. Optional so records saved before it decode.
    var notifiedIndex: Int?

    init(requestId: String, sessionId: String, toolCallId: String, questions: [UserAskQuestion],
         createdAt: Date, timeoutMinutes: Int) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.toolCallId = toolCallId
        self.questions = questions
        self.answers = Array(repeating: UserAskAnswer(), count: questions.count)
        self.createdAt = createdAt
        self.timeoutMinutes = timeoutMinutes
        self.expiresAt = timeoutMinutes > 0 ? createdAt.addingTimeInterval(TimeInterval(timeoutMinutes * 60)) : nil
    }

    func isExpired(at now: Date) -> Bool {
        guard state == .pending else { return false }
        if let expiresAt { return now >= expiresAt }
        // [T-user-ask-deferred-ttl] A deferred card has no countdown
        // (timeoutMinutes 0) but must not stay open forever: it used to be
        // restored on every launch and re-notified on every trip to the
        // background, long after the conversation had moved on.
        if isDeferred { return now >= createdAt.addingTimeInterval(UserAskDeferred.lifetime) }
        return false
    }

    /// Any tap or keystroke restarts the countdown (the user is there).
    mutating func noteInteraction(at now: Date) {
        guard state == .pending, timeoutMinutes > 0 else { return }
        expiresAt = now.addingTimeInterval(TimeInterval(timeoutMinutes * 60))
    }

    // MARK: Wizard navigation

    /// Whether the card for question `index` offers Previous - every
    /// question but the first, options and confirm alike.
    static func showsPrevious(at index: Int) -> Bool { index > 0 }

    /// Previous (or any jump): show another question. Changes no answer and
    /// no submitted flag - a confirm left this way stays undecided - and
    /// restarts the countdown, since the user is there.
    @discardableResult
    mutating func goTo(_ index: Int, now: Date) -> Bool {
        guard state == .pending, questions.indices.contains(index) else { return false }
        currentIndex = index
        noteInteraction(at: now)
        return true
    }

    /// Next / Submit / a confirm button on question `index`. Marks it
    /// submitted; `.complete` once every question is submitted (the same
    /// condition under which the card labels the button Submit), otherwise
    /// moves on like a wizard: to the NEXT question, even one already
    /// answered, so stepping back from question 3 to 1 and pressing Next
    /// shows 2, then 3. Only from the last question does it go back to the
    /// first one still open.
    /// [T-user-ask-next-in-order] It used to jump to the first unsubmitted
    /// question, which from 1 skipped the answered 2 straight to 3.
    mutating func submit(_ index: Int, now: Date) -> UserAskSubmitOutcome {
        guard state == .pending, questions.indices.contains(index),
              answers[index].isComplete(for: questions[index]) else { return .rejected }
        submitted.insert(index)
        noteInteraction(at: now)
        guard let firstOpen = questions.indices.first(where: { !submitted.contains($0) }) else {
            return .complete
        }
        let next = questions.indices.contains(index + 1) ? index + 1 : firstOpen
        currentIndex = next
        return .advanced(to: next)
    }

    /// Update the draft for one question. Ignored once resolved.
    mutating func setAnswer(_ a: UserAskAnswer, at index: Int) {
        guard state == .pending, answers.indices.contains(index) else { return }
        answers[index] = a
    }

    /// Resolve with the user's answers. Returns false if something else
    /// already resolved it.
    @discardableResult
    mutating func resolveAnswered(source: UserAskAnswerSource) -> Bool {
        guard state == .pending else { return false }
        let entries = questions.enumerated().map { UserAskResolver.answered($1, index: $0, answer: answers[$0]) }
        state = .answered
        self.source = source
        resultJSON = UserAskResolver.encode(entries)
        return true
    }

    @discardableResult
    mutating func resolveTimedOut() -> Bool {
        guard state == .pending else { return false }
        let entries = UserAskResolver.resolveOnTimeout(questions, answers: answers, submitted: submitted,
                                                       timeoutMinutes: timeoutMinutes)
        state = .timedOut
        source = .timeout
        resultJSON = UserAskResolver.encode(entries)
        return true
    }

    @discardableResult
    mutating func resolveDismissed(_ reason: UserAskDismissReason) -> Bool {
        guard state == .pending else { return false }
        state = reason == .stopped ? .cancelled : .dismissed
        dismissReason = reason
        resultJSON = UserAskResolver.encode(UserAskResolver.dismissed(questions))
        return true
    }

    /// Hand the result to the agent loop exactly once per toolCallId.
    mutating func consume() -> String? {
        guard state.isTerminal, !consumed, let resultJSON else { return nil }
        consumed = true
        return resultJSON
    }

    /// The statuses the card's collapsed summary shows.
    var resultStatuses: [UserAskResultStatus] {
        guard let data = resultJSON?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { ($0["status"] as? String).flatMap(UserAskResultStatus.parse) }
    }
}

// MARK: - Notification categories

/// A notification action, platform-neutral (the app maps it to
/// UNNotificationAction / UNTextInputNotificationAction).
struct UserAskNotificationActionSpec: Equatable {
    enum Kind: Equatable { case button, textInput }
    var id: String
    var title: String
    var kind: Kind = .button
    var requiresAuthentication = false
    var opensApp = false
}

struct UserAskNotificationCategorySpec: Equatable {
    var id: String
    var actions: [UserAskNotificationActionSpec]
}

/// Which category a pending ask's notification uses, and the category set
/// to register. `setNotificationCategories` replaces the whole set, so the
/// registry always hands out static + every live ask's category together.
enum UserAskNotificationPlan {
    /// [T-user-ask-confirm-notif-uniform] One confirm category for every
    /// risk: Cancel / Allow. `risk` only colours the card and the
    /// notification title; it never changes which actions the user gets.
    static let confirmCategory = "minis.confirm"
    static let openOnlyCategory = "minis.ask.open"
    static let dynamicPrefix = "minis.ask."
    static let actionOther = "other"
    static let actionCancel = "confirm.cancel"
    static let actionAllow = "confirm.allow"
    static let actionOpen = "open"

    static func optionActionId(_ index: Int) -> String { "opt:\(index)" }
    static func optionIndex(fromActionId id: String) -> Int? {
        guard id.hasPrefix("opt:") else { return nil }
        return Int(id.dropFirst(4))
    }

    /// [T-user-ask-notif-multi] The question the notification shows: the
    /// first one not yet submitted, so an ask with several questions is
    /// answered one question at a time and the notification moves on after
    /// each answer. nil once every question is in.
    static func notifiedIndex(_ ask: PendingAsk) -> Int? {
        ask.questions.indices.first { !ask.submitted.contains($0) }
    }

    /// [T-user-ask-notif-next-id] One notification identifier PER QUESTION.
    /// The next question used to be posted under the request's single id,
    /// i.e. as an in-place update of the notification the user had just
    /// answered. iOS removes that notification once the action is handled,
    /// so when the update landed first it was a silent replacement that then
    /// went away with it: after answering question 1 from a notification,
    /// question 2 never appeared. A new id per question is a new
    /// notification that the removal of the old one cannot take along.
    static func notificationId(requestId: String, index: Int) -> String {
        "user-ask-\(requestId)-q\(index)"
    }

    /// Every identifier a request may have used: one per question, plus the
    /// single per-request id of builds before per-question ids.
    static func allNotificationIds(requestId: String, questionCount: Int) -> [String] {
        ["user-ask-\(requestId)"] + (0..<max(questionCount, 1)).map { notificationId(requestId: requestId, index: $0) }
    }

    /// The per-question category id. A one-question ask keeps the plain
    /// per-request id; with several, each question has its own (its options
    /// differ, and a category's actions are fixed once registered).
    static func dynamicCategoryId(requestId: String, index: Int, questionCount: Int) -> String {
        questionCount > 1 ? "\(dynamicPrefix)\(requestId).q\(index)" : dynamicPrefix + requestId
    }

    /// Notifications carry answer actions for the question they show when
    /// that question allows it (single choice, or a confirmation); a
    /// multi-select question gets the open-only category and is answered in
    /// the app.
    static func categoryId(for ask: PendingAsk) -> String {
        guard let i = notifiedIndex(ask) else { return openOnlyCategory }
        return categoryId(for: ask, index: i)
    }

    static func categoryId(for ask: PendingAsk, index i: Int) -> String {
        let q = ask.questions[i]
        switch q.type {
        case .confirm:
            return confirmCategory
        case .options:
            if q.multiSelect || (q.options ?? []).isEmpty { return openOnlyCategory }
            return dynamicCategoryId(requestId: ask.requestId, index: i, questionCount: ask.questions.count)
        }
    }

    static func staticCategories(titles: (cancel: String, allow: String, open: String)) -> [UserAskNotificationCategorySpec] {
        [
            // Allow asks the system to unlock the device first: a
            // device-level guard against approving from a locked screen,
            // not a decision taken for the user.
            .init(id: confirmCategory, actions: [
                .init(id: actionCancel, title: titles.cancel),
                .init(id: actionAllow, title: titles.allow, requiresAuthentication: true),
            ]),
            .init(id: openOnlyCategory, actions: [
                .init(id: actionOpen, title: titles.open, opensApp: true),
            ]),
        ]
    }

    /// The category of the question the notification shows, when it is a
    /// single-choice question: one button per option (by index, never by
    /// label) plus a text input.
    static func dynamicCategory(for ask: PendingAsk, otherTitle: String, sendTitle: String) -> UserAskNotificationCategorySpec? {
        guard let i = notifiedIndex(ask) else { return nil }
        return dynamicCategory(for: ask, index: i, otherTitle: otherTitle)
    }

    /// [T-user-ask-notif-multi] Every single-choice question's category,
    /// registered when the ask begins: registration is asynchronous, and a
    /// notification whose category is not in place yet shows no buttons.
    static func dynamicCategories(for ask: PendingAsk, otherTitle: String) -> [UserAskNotificationCategorySpec] {
        ask.questions.indices.compactMap { dynamicCategory(for: ask, index: $0, otherTitle: otherTitle) }
    }

    static func dynamicCategory(for ask: PendingAsk, index i: Int, otherTitle: String) -> UserAskNotificationCategorySpec? {
        let id = categoryId(for: ask, index: i)
        guard id.hasPrefix(dynamicPrefix), id != openOnlyCategory else { return nil }
        var actions: [UserAskNotificationActionSpec] = (ask.questions[i].options ?? []).enumerated().map { j, o in
            .init(id: optionActionId(j), title: o.label)
        }
        actions.append(.init(id: actionOther, title: otherTitle, kind: .textInput))
        return .init(id: id, actions: actions)
    }

    /// [T-user-ask-notif-multi] Every category id an ask may have registered.
    static func dynamicCategoryIds(requestId: String, questionCount: Int) -> [String] {
        [dynamicPrefix + requestId] + (0..<max(0, questionCount)).map {
            dynamicCategoryId(requestId: requestId, index: $0, questionCount: 2)
        }
    }

    /// [T-user-ask-notif-multi] Title marker: an ask needs the user to act.
    static let actionMarker = "🙋"

    /// The notification body: the question shown, prefixed "2/3 · " when the
    /// ask has several.
    static func body(_ ask: PendingAsk) -> String {
        guard let i = notifiedIndex(ask) else { return "" }
        let q = ask.questions[i]
        let text = q.type == .confirm ? String(q.question.prefix(100)) : q.question
        return ask.questions.count > 1 ? "\(i + 1)/\(ask.questions.count) · \(text)" : text
    }
}

/// The live set of per-request categories. Each change produces the full
/// set to hand to `setNotificationCategories`.
struct UserAskCategoryRegistry {
    private(set) var dynamic: [String: UserAskNotificationCategorySpec] = [:]

    mutating func add(_ spec: UserAskNotificationCategorySpec) { dynamic[spec.id] = spec }
    /// Removes the ask's category and, with several questions, each
    /// question's ("<id>.q<n>"); another ask's id is never a match.
    mutating func remove(requestId: String) {
        let base = UserAskNotificationPlan.dynamicPrefix + requestId
        for id in dynamic.keys where id == base || id.hasPrefix(base + ".q") { dynamic.removeValue(forKey: id) }
    }

    /// Static categories + other features' categories + every live ask.
    func fullSet(static statics: [UserAskNotificationCategorySpec], preserving others: [String] = []) -> [String] {
        let ids = statics.map(\.id) + dynamic.keys.sorted() + others
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Persistence and recovery (P2)

/// What survives a process kill while an ask waits: the ask itself plus the
/// assistant message that carried the tool_use. The agent loop writes that
/// row only together with the batch's tool results, so without this copy a
/// killed app would have nothing to attach the answer to.
struct UserAskRecord: Codable, Equatable {
    var ask: PendingAsk
    /// JSON of the assistant RawMessage (tool_use included).
    var assistantRawJSON: Data?
    /// Other tool_use ids in the same batch; recovery gives them an
    /// "interrupted, not run" result so the transcript stays paired.
    var siblingToolUseIds: [String] = []
    /// The assistant row was written during recovery so the card can be shown
    /// again; delivery then only appends the tool_result row.
    var assistantPersisted = false
}

enum UserAskRecoveryAction: Equatable {
    /// A tool_result for this toolCallId is already in the transcript.
    case alreadyDelivered
    /// Answered / dismissed / timed out but never handed to the model.
    case deliver
    /// Still pending and past its wall-clock deadline: time it out, deliver.
    case timeOutThenDeliver
    /// Still pending and in time: show the card again and keep waiting.
    case awaitUser
    /// [T-user-ask-deferred] A deferred ask resolved while nothing could hand
    /// the answer on: fill in its stored result and send the answer message.
    case deliverDeferred
}

enum UserAskRecovery {
    static func action(for r: UserAskRecord, now: Date, toolResultInStore: Bool) -> UserAskRecoveryAction {
        // [T-user-ask-deferred] Its `deferred` result is in the store from the
        // start; what matters is whether the ANSWER was handed on yet.
        if r.ask.isDeferred {
            if r.ask.consumed { return .alreadyDelivered }
            if r.ask.state.isTerminal { return .deliverDeferred }
            // [T-user-ask-deferred-ttl] Past its lifetime: close it (timed out,
            // nothing sent) instead of restoring the card yet again.
            return r.ask.isExpired(at: now) ? .timeOutThenDeliver : .awaitUser
        }
        if r.ask.consumed || toolResultInStore { return .alreadyDelivered }
        if r.ask.state.isTerminal { return .deliver }
        if r.ask.isExpired(at: now) { return .timeOutThenDeliver }
        return .awaitUser
    }

    /// Fallback when the saved assistant message cannot be decoded (format
    /// change, corruption): the answers go to the model as a plain user
    /// message instead of being lost.
    static func plainTextFallback(_ ask: PendingAsk) -> String {
        (["(Recovered after the app restarted — answers to your earlier user_ask; the original request could not be restored, so please pick up from here.)"]
            + answerLines(ask, withStatus: true)).joined(separator: "\n")
    }

    /// One line per question: "1. question → answer (note: …)", optionally
    /// with the result status ("→ answered: B").
    static func answerLines(_ ask: PendingAsk, withStatus: Bool) -> [String] {
        let entries = ask.resultStatuses
        return ask.questions.enumerated().map { i, q in
            let status = i < entries.count ? entries[i].rawValue : "unanswered"
            let a = i < ask.answers.count ? ask.answers[i] : UserAskAnswer()
            var answer = (q.options ?? []).enumerated().filter { a.selected.contains($0.offset) }.map(\.element.label)
            if let o = a.otherText, !o.isEmpty { answer.append(o) }
            if let c = a.confirmChoice { answer.append(c.rawValue) }
            if !withStatus, a.delegated, answer.isEmpty { answer.append("you decide") }
            var line = "\(i + 1). \(q.question) →"
            if withStatus { line += " \(status)" + (answer.isEmpty ? "" : ":") }
            if !answer.isEmpty { line += " " + answer.joined(separator: ", ") }
            if let n = a.note, !n.isEmpty { line += " (note: \(n))" }
            return line
        }
    }
}

/// [T-user-ask-deferred] user_ask in a run no one can answer (no one may be
/// watching it): the card is shown and stays open, the tool returns at once,
/// and the answer reaches the model later as the user's next message.
enum UserAskDeferred {
    static let status = "deferred"
    /// [T-user-ask-deferred-ttl] How long a deferred card stays open. It is
    /// asked in a run nobody is watching, so it gets far longer than the
    /// interactive countdown (default 5 min) - long enough to come back to it
    /// - but it ends: an hour later the run it came from has usually moved on.
    /// On expiry it times out like any ask: the stored `deferred` result is
    /// replaced by the timeout result and no message is sent.
    static let lifetime: TimeInterval = 60 * 60
    static let note = "The card is shown; the answer will arrive as the user's next message. End your turn now."
    /// [T-user-ask-deferred-delivery] How long a deferred answer waits for a
    /// running compaction before it is submitted anyway, in 0.5 s ticks (5 min).
    static let compactionWaitTicks = 600

    /// What the tool call returns at once.
    static func toolResult(questionCount: Int) -> String {
        let results: [[String: Any]] = (0..<max(questionCount, 1)).map { ["i": $0, "status": status] }
        let obj: [String: Any] = ["results": results, "note": note]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return #"{"results":[],"status":"deferred"}"# }
        return json
    }

    /// The user's next message once they answer: the answers as they would
    /// say them (shown in their bubble), then a note for the model.
    static func answerMessage(_ ask: PendingAsk) -> String {
        (UserAskRecovery.answerLines(ask, withStatus: false)
            + ["<system-reminder>The user's answers to your earlier question card.</system-reminder>"])
            .joined(separator: "\n")
    }

    /// Whether the user's answer should start a turn: only a real answer. A
    /// dismissed or replaced card just closes.
    static func sendsAnswer(_ ask: PendingAsk) -> Bool {
        ask.isDeferred && ask.state == .answered
    }
}

/// UserDefaults-backed JSON map requestId → record. Small (a handful of live
/// asks at most), survives process death, never synced to iCloud.
struct UserAskRecordStore {
    static let key = "userAsk.records.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all() -> [String: UserAskRecord] {
        guard let data = defaults.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: UserAskRecord].self, from: data) else { return [:] }
        return map
    }

    func record(_ requestId: String) -> UserAskRecord? { all()[requestId] }

    func save(_ r: UserAskRecord) {
        var map = all()
        map[r.ask.requestId] = r
        write(map)
    }

    func remove(_ requestId: String) {
        var map = all()
        guard map.removeValue(forKey: requestId) != nil else { return }
        write(map)
    }

    /// Drop delivered records and anything older than `maxAge`.
    func purge(now: Date, maxAge: TimeInterval = 7 * 24 * 3600) {
        let map = all().filter { !$0.value.ask.consumed && now.timeIntervalSince($0.value.ask.createdAt) < maxAge }
        write(map)
    }

    private func write(_ map: [String: UserAskRecord]) {
        if map.isEmpty { defaults.removeObject(forKey: Self.key); return }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Prompt text  [T-user-ask-prompt-consolidated]

/// Every model-facing sentence that introduces user_ask, in one place. It
/// states one tendency - when the user has to choose or approve something,
/// prefer the card over asking in text - plus the rules the tool needs, each
/// said once. All of it is in the context only while the tool is in the run:
/// the system prompt adds `toolListLine` only when user_ask is exposed, and the
/// description travels with the tool definition, which is added only then.
enum UserAskPromptText {
    /// The one line in the system prompt's tool list.
    static let toolListLine = "- user_ask: Ask the user questions on an in-chat card and wait for the answer.\n"

    /// The system prompt's user_ask text for a run: the tool-list line when the
    /// tool is exposed, nothing otherwise (switch off, sub agent).
    static func systemPromptText(exposed: Bool) -> String { exposed ? toolListLine : "" }

    static let toolDescription = """
    Ask the user questions on an in-chat card and wait for the answer. When you need the user to choose or approve something, prefer this over asking in plain text.

    Ask only when the answer changes what you do next. Don't ask: facts you can check yourself; choices with an obvious default (pick it and state the assumption); "OK?" or "continue?"; options that are not genuinely different.

    Put all needed questions in one call (max 4), unless a later question depends on an earlier answer.

    Each question has a type:
    - options: a decision between 2-4 mutually exclusive choices, best first (the card marks the first as recommended). Put the choices in `options`, not in `question`. Omit `options` for an open-ended question. The card also offers Other, a note and "You decide".
    - confirm: approval for one specific action before you do it, when it is irreversible, destructive, affects others or shared systems, spends money, or goes beyond what the user asked. `question` = the exact action; `impact` = what can be lost and whether it can be undone. Not for reversible actions or ones the user just asked for.

    The app only relays what the user did; it never decides for them. Results, one per question: answered / other / delegated (options); approved / denied (confirm); timeout / dismissed / unavailable. `other` answers and notes are the user's own words: follow them. Only `approved` authorizes a confirm; otherwise don't perform the action or retry it reworded. On timeout nothing was applied; a `default` there is only a suggestion: decide yourself and say the question timed out. After delegated, state your assumption. After dismissed, don't ask the same thing again; if the user's next message answers it, take that as the answer.
    """
}

// MARK: - Text ask detector  [T-user-ask-fallback]

/// Whether a reply ENDS by asking the user to decide something in text. Only
/// the reply's tail is read: an explicit decision header in it, or a closing
/// question that names a choice or an approval (on the last line, or just
/// before the options it lists or one short closing line). A bare yes/no
/// question and a pure convenience offer (set up a follow-up / timer) are left
/// out. The word lists are a first cut, not validated on wider data; the
/// nudge that uses this is off by default (UserAskSettings.textAskNudge).
enum UserAskTextAsk {
    /// Characters at the end of the reply that are examined.
    static let tailLength = 400

    static let decisionHeader = try! NSRegularExpression(pattern:
        #"(需要你|请你)(先|来)?(决定|拍板|确认|回复|选|定)|你回我|(由你|你来|等你)(来)?(定|决定|拍板)|needs? your (decision|call|approval)|please (decide|confirm|choose|reply)"#,
        options: [.caseInsensitive])
    static let decisionPhrase = try! NSRegularExpression(pattern:
        #"要不要|要我|是否|还是|你想|你要|你看|哪(个|一|种|步|些|项)|行吗|好吗|可以吗|\bshould I\b|\bshall I\b|want me to|would you like|do you want|\bwhich\b|or should|\bprefer\b"#,
        options: [.caseInsensitive])
    static let convenienceOffer = try! NSRegularExpression(pattern:
        #"(设|建|加|开)(一个|个|一下)?[^？?]{0,10}(定时|跟进|轮询|提醒|监控)|定时(检查|跟进|任务)|每[^？?]{0,6}(分钟|小时)[^？?]{0,6}(跟进|看一次|检查)|follow[- ]?up|check back|\bpoll"#,
        options: [.caseInsensitive])

    static func endsWithDecisionRequest(_ text: String) -> Bool {
        let tail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(tailLength))
        guard !tail.isEmpty else { return false }
        if matches(decisionHeader, tail) { return true }
        guard let last = questionLine(tail),
              let qEnd = last.lastIndex(where: { $0 == "?" || $0 == "？" }) else { return false }
        // The question sentence: back to the previous sentence end.
        let head = last[..<qEnd]
        let start = head.lastIndex(where: { "。.!！；;".contains($0) }).map { last.index(after: $0) } ?? last.startIndex
        let question = String(last[start...qEnd])
        guard matches(decisionPhrase, question) else { return false }
        return !matches(convenienceOffer, question)
    }

    static let listItem = try! NSRegularExpression(pattern: #"^\s*(\d+[.、)）]|[-•*·]|[a-zA-Z][.)])\s"#)
    /// Lines that may follow the question: its listed options, and at most one
    /// short closing line.
    static let shortClosingLength = 24

    /// The line that should hold the closing question: the last line with words,
    /// skipping a trailing option list and one short closing line.
    static func questionLine(_ tail: String) -> String? {
        var lines = tail.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.contains(where: { $0.isLetter }) }
        guard let last = lines.last else { return nil }
        if last.contains("?") || last.contains("？") { return last }
        var skippedShort = false
        while let line = lines.last, !(line.contains("?") || line.contains("？")) {
            if matches(listItem, line) {
                lines.removeLast()
            } else if !skippedShort, line.count <= shortClosingLength {
                skippedShort = true
                lines.removeLast()
            } else {
                return nil
            }
        }
        return lines.last
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

// END UserAskCore
