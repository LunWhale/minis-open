//
//  ChatSearchEngine.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] The pure half of "Search in Chat": what a search unit
//  is, how a query matches its text, and how the current result moves.
//  Foundation only, no app types, so MinisTests/Standalone/ChatSearchEngineTests
//  compiles this file as-is.
//
//  A match is identified by (unit key, ordinal) - "the Nth occurrence of the
//  query in this piece of visible text" - never by a character range. The
//  search runs over a text snapshot taken off the view models, and the cell
//  that draws the highlight finds the Nth occurrence again in the text it
//  actually displays. Both sides call `ChatSearchMatcher.ranges`, so as long
//  as the two texts agree on the occurrences, the ordinals agree too.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import Foundation

// BEGIN chat-search-engine

/// Which visible piece of a message a search unit is. One message can show
/// several separately drawn texts (a user bubble and its file tiles, a sub
/// agent card's title and status line), and each is its own unit so the
/// highlighter can find the occurrence inside the Text that draws it.
enum ChatSearchField: Hashable {
    /// The main text: user bubble, assistant text block, tool capsule line,
    /// compact divider, system info row.
    case body
    /// A user file tile's name, by index into the message's attachments.
    case attachmentName(Int)
    /// A card's headline: agent callback title, sub agent card title, the
    /// "switched model" line of an info block.
    case title
    /// A card's second line: sub agent activity or status.
    case activity
    /// One line of an info block's reason list.
    case line(Int)
    /// A user_ask question, by index.
    case question(Int)
    /// A user_ask option label (question index, option index).
    case option(Int, Int)
    /// The error line in an assistant reply's footer.
    case footerError
}

struct ChatSearchUnitKey: Hashable {
    let messageId: UUID
    let blockId: UUID?
    let field: ChatSearchField
}

/// One piece of visible text, in display order.
struct ChatSearchUnit {
    let key: ChatSearchUnitKey
    let text: String
}

/// One occurrence of the query: the `ordinal`-th (0-based) non-overlapping
/// occurrence inside the unit's text.
struct ChatSearchMatch: Hashable {
    let key: ChatSearchUnitKey
    let ordinal: Int
}

enum ChatSearchMatcher {
    /// Case and diacritic insensitive: "cafe" finds "Café".
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query as searched: surrounding whitespace dropped, inner spaces
    /// kept. The whole string is ONE substring - "apple pie" does not find
    /// "apple" alone (unlike the home screen's keyword OR search).
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-overlapping occurrences of `query` in `text`, first to last, at
    /// most `limit`. Empty for an empty query.
    static func ranges(of query: String, in text: String, limit: Int = .max) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: query, options: compareOptions, range: from..<text.endIndex) {
            // A match never has zero length for a non-empty query, but guard
            // against an infinite loop on any surprising normalisation.
            guard !r.isEmpty else { break }
            out.append(r)
            if out.count >= limit { break }
            from = r.upperBound
        }
        return out
    }

    /// Same as `ranges`, as UTF-16 ranges (what TextKit and NSString use).
    static func nsRanges(of query: String, in text: String, limit: Int = .max) -> [NSRange] {
        ranges(of: query, in: text, limit: limit).map { NSRange($0, in: text) }
    }

    /// Number of occurrences, capped at `limit`.
    static func count(of query: String, in text: String, limit: Int) -> Int {
        ranges(of: query, in: text, limit: limit).count
    }
}

struct ChatSearchResult: Equatable {
    /// Every match in display order (unit order, then ordinal).
    let matches: [ChatSearchMatch]
    /// Matches per unit, for the highlighter.
    let countByUnit: [ChatSearchUnitKey: Int]
    /// True when the total limit cut the list short ("2000+").
    let truncated: Bool

    static let empty = ChatSearchResult(matches: [], countByUnit: [:], truncated: false)
}

enum ChatSearchEngine {
    /// Highlights drawn in one unit; also the matches counted for it.
    static let perUnitLimit = 200
    /// Matches kept for the whole chat; the count then reads "2000+".
    static let totalLimit = 2000

    /// Searches `units` (already in display order). Returns nil when
    /// `isCancelled` turns true part-way, so a stale run never publishes.
    static func search(units: [ChatSearchUnit], query rawQuery: String,
                       perUnitLimit: Int = perUnitLimit, totalLimit: Int = totalLimit,
                       isCancelled: () -> Bool = { false }) -> ChatSearchResult? {
        let query = ChatSearchMatcher.normalizedQuery(rawQuery)
        guard !query.isEmpty else { return .empty }
        var matches: [ChatSearchMatch] = []
        var countByUnit: [ChatSearchUnitKey: Int] = [:]
        var truncated = false
        for (i, unit) in units.enumerated() {
            if i % 64 == 0, isCancelled() { return nil }
            let remaining = totalLimit - matches.count
            guard remaining > 0 else {
                // Only report truncation when something was actually dropped.
                if ChatSearchMatcher.count(of: query, in: unit.text, limit: 1) > 0 {
                    truncated = true
                    break
                }
                continue
            }
            let n = ChatSearchMatcher.count(of: query, in: unit.text, limit: min(perUnitLimit, remaining + 1))
            guard n > 0 else { continue }
            let kept = min(n, remaining, perUnitLimit)
            if n > remaining { truncated = true }
            countByUnit[unit.key] = kept
            for ordinal in 0..<kept {
                matches.append(ChatSearchMatch(key: unit.key, ordinal: ordinal))
            }
        }
        return ChatSearchResult(matches: matches, countByUnit: countByUnit, truncated: truncated)
    }
}

/// Moving through the results. Index 0 is the earliest match; "next" goes
/// toward newer messages, "previous" toward older ones, both wrapping.
enum ChatSearchNavigation {
    /// Where a fresh search lands: the newest match (chat reads bottom-up).
    static func initialIndex(count: Int) -> Int? {
        count > 0 ? count - 1 : nil
    }

    /// One step from `index`. `wrapped` is true when the step went past an
    /// end and came round to the other one.
    static func step(from index: Int?, count: Int, forward: Bool) -> (index: Int, wrapped: Bool)? {
        guard count > 0 else { return nil }
        guard let index, index >= 0, index < count else {
            return (forward ? 0 : count - 1, false)
        }
        if forward {
            return index + 1 < count ? (index + 1, false) : (0, count > 1)
        }
        return index > 0 ? (index - 1, false) : (count - 1, count > 1)
    }

    /// The current match after the results were recomputed (new content
    /// streamed in): the same match if it still exists, otherwise the old
    /// index clamped to the new count.
    static func relocate(previous: ChatSearchMatch?, previousIndex: Int?,
                         in matches: [ChatSearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let previous, let i = matches.firstIndex(of: previous) { return i }
        guard let previousIndex else { return nil }
        return min(max(previousIndex, 0), matches.count - 1)
    }

    /// The "3/12" counter (1-based), "2000+" when truncated.
    static func counterText(index: Int?, count: Int, truncated: Bool) -> String {
        let total = truncated ? "\(count)+" : "\(count)"
        guard let index, count > 0 else { return "0/\(total)" }
        return "\(index + 1)/\(total)"
    }
}

// END chat-search-engine
