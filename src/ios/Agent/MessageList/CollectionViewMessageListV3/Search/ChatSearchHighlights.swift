//
//  ChatSearchHighlights.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] How search highlights reach the cells without touching
//  the list.
//
//  Each piece of visible text observes one small token (per unit key), not
//  the search as a whole. Moving to the next result changes two tokens - the
//  unit losing the current mark and the unit gaining it - so exactly those
//  two views redraw, and nothing reconfigures a cell, clears a height cache
//  or re-measures: a highlight never changes a text's size.
//
//    ChatSearchController --apply/setCurrent--> ChatSearchHighlightCenter
//        --token(for: key).state--> SearchHighlightText (SwiftUI Text rows)
//                                 \-> SelectableMarkdownTextView (TextKit,
//                                     draws in MinisLayoutManager)
//
//  The center reaches a cell through the `chatSearchHighlights` environment
//  value, injected by the list's cell configuration (a UIHostingConfiguration
//  does not inherit the chat view's environment). Anything rendered outside
//  the list (share export, previews) has no center and draws plain text.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine

/// What one unit highlights: the first `count` occurrences of `query`, with
/// occurrence `current` (if any) drawn as the current result.
struct ChatSearchUnitHighlight: Equatable {
    let query: String
    let count: Int
    let current: Int?

    /// Occurrences to draw: the first `ChatSearchEngine.perUnitLimit`, and
    /// the current one is always among them (it is < count <= limit).
    var drawLimit: Int { min(count, ChatSearchEngine.perUnitLimit) }
}

/// One unit's highlight, observed by the view that draws that unit.
@MainActor
final class ChatSearchHighlightToken: ObservableObject {
    @Published fileprivate(set) var state: ChatSearchUnitHighlight?
    init(state: ChatSearchUnitHighlight?) { self.state = state }
}

@MainActor
final class ChatSearchHighlightCenter {
    /// Opens the chat's search bar with an optional query. Set by the chat
    /// page while it shows this conversation (nil in lists with no search
    /// bar, such as a sub agent's transcript), so the long-press menus can
    /// offer "Search in Chat" without a callback threaded through every cell.
    var openSearch: ((String?) -> Void)?
    /// Which chat page installed `openSearch`, so a page going away cannot
    /// clear the opener a newer page for the same conversation installed.
    var openSearchOwner: UUID?

    private var tokens: [ChatSearchUnitKey: ChatSearchHighlightToken] = [:]
    private var states: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]

    /// The token for `key`, created on first use with the current state.
    /// Tokens live as long as the center (one per chat view model), so a view
    /// that keeps its token across cell reuse still receives later updates.
    func token(for key: ChatSearchUnitKey) -> ChatSearchHighlightToken {
        if let t = tokens[key] { return t }
        let t = ChatSearchHighlightToken(state: states[key])
        tokens[key] = t
        return t
    }

    func state(for key: ChatSearchUnitKey) -> ChatSearchUnitHighlight? { states[key] }

    /// A new result set. Only units whose state actually changed publish.
    func apply(result: ChatSearchResult, query: String, current: ChatSearchMatch?) {
        var next: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]
        next.reserveCapacity(result.countByUnit.count)
        for (key, count) in result.countByUnit {
            next[key] = ChatSearchUnitHighlight(query: query, count: count,
                                                current: current?.key == key ? current?.ordinal : nil)
        }
        let changed = Set(next.keys).union(states.keys).filter { next[$0] != states[$0] }
        states = next
        for key in changed { tokens[key]?.state = next[key] }
    }

    /// Moves the current mark: touches at most the two units involved.
    func setCurrent(from old: ChatSearchMatch?, to new: ChatSearchMatch?) {
        var keys: [ChatSearchUnitKey] = []
        if let old { keys.append(old.key) }
        if let new, new.key != old?.key { keys.append(new.key) }
        for key in keys {
            guard let s = states[key] else { continue }
            let current = new?.key == key ? new?.ordinal : nil
            let updated = ChatSearchUnitHighlight(query: s.query, count: s.count, current: current)
            guard updated != s else { continue }
            states[key] = updated
            tokens[key]?.state = updated
        }
    }

    /// Search closed: every highlight goes away.
    func clear() {
        let keys = Array(states.keys)
        states.removeAll()
        for key in keys { tokens[key]?.state = nil }
    }
}

// MARK: - Environment

private struct ChatSearchHighlightsKey: EnvironmentKey {
    static let defaultValue: ChatSearchHighlightCenter? = nil
}

private struct ChatSearchDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatSearchMessageIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The chat's highlight center; nil outside the message list.
    var chatSearchHighlights: ChatSearchHighlightCenter? {
        get { self[ChatSearchHighlightsKey.self] }
        set { self[ChatSearchHighlightsKey.self] = newValue }
    }

    /// The row is drawn at reduced opacity (compacted history): highlights
    /// use stronger colours so they still read through the fade.
    var chatSearchDimmed: Bool {
        get { self[ChatSearchDimmedKey.self] }
        set { self[ChatSearchDimmedKey.self] = newValue }
    }

    /// The message a block view belongs to, for views that only hold the
    /// block (tool capsule, sub agent card, user_ask card).
    var chatSearchMessageId: UUID? {
        get { self[ChatSearchMessageIdKey.self] }
        set { self[ChatSearchMessageIdKey.self] = newValue }
    }
}

// MARK: - Colours

enum ChatSearchHighlightStyle {
    /// Every match: a highlighter-pen yellow.
    static func matchColor(dimmed: Bool) -> UIColor {
        UIColor.systemYellow.withAlphaComponent(dimmed ? 0.9 : 0.45)
    }

    /// The current match: orange, clearly stronger than the others.
    static func currentColor(dimmed: Bool) -> UIColor {
        UIColor.systemOrange.withAlphaComponent(dimmed ? 1 : 0.85)
    }
}

// MARK: - SwiftUI text with highlights

/// Drop-in for `Text(text)` on a searchable row. Outside the message list (no
/// highlight center) it IS `Text(text)`. Font, colour and line limits applied
/// to it reach the inner Text through the environment, as with a plain Text.
///
/// `searchOffset` skips a leading part of `text` that is drawn but not
/// searched (the agent callback card's "Agent result · " label): matches are
/// counted in `text` from that character on, the same string the search unit
/// holds.
struct SearchHighlightText: View {
    let text: String
    let key: ChatSearchUnitKey?
    var searchOffset: Int = 0
    @Environment(\.chatSearchHighlights) private var center
    @Environment(\.chatSearchDimmed) private var dimmed

    init(_ text: String, key: ChatSearchUnitKey?, searchOffset: Int = 0) {
        self.text = text
        self.key = key
        self.searchOffset = searchOffset
    }

    /// For a block's views: the key from the message id in the environment.
    init(_ text: String, blockId: UUID, field: ChatSearchField, messageId: UUID?) {
        self.init(text, key: messageId.map { ChatSearchUnitKey(messageId: $0, blockId: blockId, field: field) })
    }

    var body: some View {
        if let center, let key {
            Observed(token: center.token(for: key), text: text, searchOffset: searchOffset, dimmed: dimmed)
        } else {
            Text(text)
        }
    }

    private struct Observed: View {
        @ObservedObject var token: ChatSearchHighlightToken
        let text: String
        let searchOffset: Int
        let dimmed: Bool

        var body: some View {
            if let state = token.state {
                Text(SearchHighlightText.attributed(text, searchOffset: searchOffset, state: state, dimmed: dimmed))
            } else {
                Text(text)
            }
        }
    }

    /// `text` with its first `state.drawLimit` occurrences backed in yellow
    /// and the current one in orange. Built piecewise, so its cost is linear
    /// in the text however many highlights it carries.
    static func attributed(_ text: String, searchOffset: Int, state: ChatSearchUnitHighlight,
                           dimmed: Bool) -> AttributedString {
        let start = text.index(text.startIndex, offsetBy: min(max(searchOffset, 0), text.count))
        let searchable = text[start...]
        let ranges = ChatSearchMatcher.ranges(of: state.query, in: String(searchable), limit: state.drawLimit)
        guard !ranges.isEmpty else { return AttributedString(text) }
        let searchableString = String(searchable)
        var out = AttributedString(String(text[..<start]))
        var cursor = searchableString.startIndex
        let match = Color(ChatSearchHighlightStyle.matchColor(dimmed: dimmed))
        let current = Color(ChatSearchHighlightStyle.currentColor(dimmed: dimmed))
        for (ordinal, r) in ranges.enumerated() {
            out += AttributedString(String(searchableString[cursor..<r.lowerBound]))
            var hit = AttributedString(String(searchableString[r]))
            hit.backgroundColor = ordinal == state.current ? current : match
            out += hit
            cursor = r.upperBound
        }
        out += AttributedString(String(searchableString[cursor...]))
        return out
    }
}
