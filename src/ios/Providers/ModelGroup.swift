import Foundation

/// How a model group routes requests across its members.
enum RoutingStrategy: String, Codable, Hashable, Sendable {
    /// Try models in order; advance to next on failure.
    case fallback
    /// Distribute sessions across models deterministically.
    case loadBalance
}

/// When to trigger fallback to the next model in a fallback group.
enum FallbackStrategy: String, Codable, Hashable, Sendable {
    /// Default behavior: only fallback on provider-level errors (rate limit, invalid key,
    /// provider rejection). Network and transient errors are retried on the current model first.
    case limited
    /// Fallback on any error — including network errors and transient server errors —
    /// without retrying on the current model. Cycles through all group members.
    case always
}

/// Named group of ModelEntry refs with a routing strategy.
struct ModelGroup: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    /// Ordered ModelEntry.id values (composite "{instanceId}:{modelId}").
    var memberEntryIds: [String]
    var strategy: RoutingStrategy
    /// Controls which errors trigger fallback. Only applies when `strategy == .fallback`.
    var fallbackStrategy: FallbackStrategy
    /// Default thinking level applied to new sessions bound to this group. nil = off (no override).
    var defaultThinkingLevel: ThinkingLevel?
    /// Context window limit override in tokens applied in-memory to sessions bound to this group.
    /// nil = unlimited (use model's native context window).
    var contextLimitTokens: Int?
    /// Last user-selected context limit, retained while `contextLimitTokens` is nil
    /// so toggling "Limit Context Window" off then back on restores the previous
    /// choice instead of resetting to 128K.
    var lastContextLimitTokens: Int?

    /// [T-icloud-provider-sync-consistency] Per-member add/remove timestamps
    /// for conflict-free multi-device member merging. `memberEntryIds` stays a
    /// plain ordered `[String]` (router and UI are unchanged); these two
    /// side-maps drive the UNION merge on inbound sync:
    ///   - addedMembers[m]   = when m was last added to this group
    ///   - removedMembers[m] = when m was last removed from this group
    /// Merge rule (per member, after unioning both devices' maps by max-time):
    ///   m is present in the group  iff  addedAt(m) >= removedAt(m)
    /// i.e. the most recent intent wins per member. Two devices each adding a
    /// different model both keep their addition (union); a removal on one
    /// device only drops the member if no newer re-add exists anywhere. Empty
    /// maps mean "legacy group, treat every current member as added at time 0".
    var addedMembers: [String: Date]
    var removedMembers: [String: Date]

    init(
        id: String = UUID().uuidString,
        name: String,
        memberEntryIds: [String],
        strategy: RoutingStrategy = .fallback,
        fallbackStrategy: FallbackStrategy = .limited,
        defaultThinkingLevel: ThinkingLevel? = nil,
        contextLimitTokens: Int? = nil,
        lastContextLimitTokens: Int? = nil,
        addedMembers: [String: Date] = [:],
        removedMembers: [String: Date] = [:]
    ) {
        self.id = id
        self.name = name
        self.memberEntryIds = memberEntryIds
        self.strategy = strategy
        self.fallbackStrategy = fallbackStrategy
        self.defaultThinkingLevel = defaultThinkingLevel
        self.contextLimitTokens = contextLimitTokens
        self.lastContextLimitTokens = lastContextLimitTokens
        self.addedMembers = addedMembers
        self.removedMembers = removedMembers
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memberEntryIds, strategy, fallbackStrategy, defaultThinkingLevel, contextLimitTokens, lastContextLimitTokens, addedMembers, removedMembers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        memberEntryIds = try container.decode([String].self, forKey: .memberEntryIds)
        strategy = try container.decode(RoutingStrategy.self, forKey: .strategy)
        fallbackStrategy = try container.decodeIfPresent(FallbackStrategy.self, forKey: .fallbackStrategy) ?? .limited
        if let raw = try container.decodeIfPresent(String.self, forKey: .defaultThinkingLevel) {
            defaultThinkingLevel = ThinkingLevel.decoded(raw)
        } else {
            defaultThinkingLevel = nil
        }
        contextLimitTokens = try container.decodeIfPresent(Int.self, forKey: .contextLimitTokens)
        lastContextLimitTokens = try container.decodeIfPresent(Int.self, forKey: .lastContextLimitTokens)
        addedMembers = try container.decodeIfPresent([String: Date].self, forKey: .addedMembers) ?? [:]
        removedMembers = try container.decodeIfPresent([String: Date].self, forKey: .removedMembers) ?? [:]
    }
}

// BEGIN GroupOrderDiff
// [T-group-order-log] Self-contained on purpose (Foundation only):
// MinisTests/Standalone/GroupOrderLogTests compiles this block as it ships.

/// What happened to a group's member list between two states.
///
/// A fallback group tries its members in order, so the order IS the priority.
/// Users reported it changing by itself ("1 used to be before 2, now 2 is
/// first") and reading the code did not settle who does it. These are the
/// read-only comparisons behind the `[GroupOrder]` log lines: nothing here, or
/// anywhere it is called from, changes a merge rule, a timestamp or an order.
enum GroupOrderDiff {
    struct Summary: Equatable {
        /// The members both lists hold come in a different relative order.
        var reordered: Bool
        /// In `after` only / in `before` only, in list order.
        var added: [String]
        var removed: [String]
        /// Every added member sits after every member that was already there.
        var addedOnlyAtTail: Bool

        var isUnchanged: Bool { !reordered && added.isEmpty && removed.isEmpty }
        /// `reorder` when the surviving members changed places, `members` when
        /// only the set changed, `none` otherwise.
        var change: String { reordered ? "reorder" : (added.isEmpty && removed.isEmpty ? "none" : "members") }
    }

    /// True when the members present in BOTH lists appear in a different
    /// relative order. Appending, inserting or removing members is not a
    /// reorder as long as the ones that stay keep their order.
    static func relativeOrderChanged(before: [String], after: [String]) -> Bool {
        guard before != after else { return false }
        let afterSet = Set(after), beforeSet = Set(before)
        return firstOccurrences(before.filter { afterSet.contains($0) })
            != firstOccurrences(after.filter { beforeSet.contains($0) })
    }

    static func summary(before: [String], after: [String]) -> Summary {
        guard before != after else {
            return Summary(reordered: false, added: [], removed: [], addedOnlyAtTail: false)
        }
        let afterSet = Set(after), beforeSet = Set(before)
        let added = firstOccurrences(after.filter { !beforeSet.contains($0) })
        let removed = firstOccurrences(before.filter { !afterSet.contains($0) })
        var onlyAtTail = false
        if !added.isEmpty {
            let lastKept = after.lastIndex { beforeSet.contains($0) } ?? -1
            let firstAdded = after.firstIndex { !beforeSet.contains($0) } ?? after.count
            onlyAtTail = firstAdded > lastKept
        }
        return Summary(reordered: relativeOrderChanged(before: before, after: after),
                       added: added, removed: removed, addedOnlyAtTail: onlyAtTail)
    }

    private static func firstOccurrences(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// A member id short enough for a log line and free of anything secret.
    /// Ids are `<instanceUUID>/<modelId>` (ModelEntry.compositeKey): the first
    /// 8 characters of the instance id, then the model id. A legacy bare uuid
    /// is cut to 8. Model ids are names, but a custom one is typed by the
    /// user, so anything shaped like a URL or carrying credentials is masked.
    static func shortId(_ entryId: String) -> String {
        guard let slash = entryId.firstIndex(of: "/") else { return String(entryId.prefix(8)) }
        let instance = entryId[..<slash].prefix(8)
        let model = String(entryId[entryId.index(after: slash)...])
        if model.contains("://") || model.contains("@") || model.contains("?") || model.contains("=") {
            return "\(instance)/<masked>"
        }
        return "\(instance)/\(model.prefix(48))"
    }

    /// `[a, b, c]`, at most 24 members.
    static func describe(_ ids: [String]) -> String {
        let shown = ids.prefix(24).map(shortId).joined(separator: ", ")
        return ids.count > 24 ? "[\(shown), …+\(ids.count - 24)]" : "[\(shown)]"
    }

    /// `ab12cd34(Name)`.
    static func groupTag(id: String, name: String) -> String {
        "\(id.prefix(8))(\(name.prefix(32)))"
    }

    /// The line for one group, or nil when its member list did not change in
    /// order or membership. `reason` is one of the fixed, greppable values.
    static func line(reason: String, groupId: String, name: String,
                     before: [String], after: [String], detail: String = "") -> (text: String, summary: Summary)? {
        let s = summary(before: before, after: after)
        guard !s.isUnchanged else { return nil }
        var text = "reason=\(reason) change=\(s.change) group=\(groupTag(id: groupId, name: name))"
            + " before=\(describe(before)) after=\(describe(after))"
        if !s.added.isEmpty { text += " added=\(describe(s.added)) addedAtTail=\(s.addedOnlyAtTail)" }
        if !s.removed.isEmpty { text += " removed=\(describe(s.removed))" }
        if !detail.isEmpty { text += " \(detail)" }
        return (text, s)
    }
}
// END GroupOrderDiff

/// [T-group-order-log] Writes the `[GroupOrder]` lines. AppLogger goes through
/// NSLog into the daily log file in Release builds too (info and warning are
/// not compiled out; only debug is).
///
/// Quiet by construction: a call whose two lists are equal returns after one
/// array comparison, so the callers - every path that can rewrite a group's
/// members - cost nothing on an ordinary save.
enum GroupOrderLog {
    private static let logger = AppLogger(category: "GroupOrder")

    /// Log one group if its member order or membership changed. A reorder is
    /// logged at warning when `warnOnReorder` is set (the paths nobody asked
    /// for: sync, merges, pruning), otherwise at info; a membership-only
    /// change is always info.
    @discardableResult
    static func note(reason: String, groupId: String, name: String,
                     before: [String], after: [String],
                     warnOnReorder: Bool = false,
                     detail: @autoclosure () -> String = "") -> GroupOrderDiff.Summary? {
        guard before != after,
              let line = GroupOrderDiff.line(reason: reason, groupId: groupId, name: name,
                                             before: before, after: after, detail: detail())
        else { return nil }
        emit(line.text, warning: warnOnReorder && line.summary.reordered)
        return line.summary
    }

    /// The same for every group present in both lists (matched by id).
    static func noteAll(reason: String, before: [ModelGroup], after: [ModelGroup],
                        warnOnReorder: Bool = true,
                        detail: @autoclosure () -> String = "") {
        guard before != after else { return }
        let prior = Dictionary(before.map { ($0.id, $0.memberEntryIds) }, uniquingKeysWith: { a, _ in a })
        for group in after {
            guard let was = prior[group.id], was != group.memberEntryIds else { continue }
            note(reason: reason, groupId: group.id, name: group.name,
                 before: was, after: group.memberEntryIds,
                 warnOnReorder: warnOnReorder, detail: detail())
        }
    }

    /// A timestamp as local wall-clock time plus the raw epoch seconds the
    /// merge compares, e.g. `10-05T21:43:17.120(1791207797.120)`.
    static func stamp(_ epoch: Double?) -> String {
        guard let epoch else { return "-" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd'T'HH:mm:ss.SSS"
        return "\(f.string(from: Date(timeIntervalSince1970: epoch)))(\(String(format: "%.3f", epoch)))"
    }

    /// A line built by the caller (the sync and database paths, which have
    /// more to say than before / after).
    static func emit(_ text: String, warning: Bool = false) {
        if warning {
            logger.warning("[GroupOrder] \(text)")
        } else {
            logger.info("[GroupOrder] \(text)")
        }
    }
}
