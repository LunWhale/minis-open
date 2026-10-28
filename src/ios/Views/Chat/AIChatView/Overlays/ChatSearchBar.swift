//
//  ChatSearchBar.swift
//  Minis - chat page (AIChatView)
//
//  [T-in-chat-search] The bar "Search in Chat" opens under the navigation
//  bar: query field, "3/12" counter, previous (older) / next (newer), Done.
//  Mounted in AIChatView's `topBanners`, so the list's top inset already
//  makes room for it. Observes only the search controller - typing here
//  never re-renders the chat page.
//
//  Keys: Return = next result, Shift-Return = previous.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import SwiftUI
import UIKit

struct ChatSearchBar: View {
    @ObservedObject var search: ChatSearchController
    /// Called after Done: the page restores its composer.
    var onDone: () -> Void
    @FocusState private var fieldFocused: Bool

    private var hasQuery: Bool { !search.normalizedQuery.isEmpty }
    private var hasResults: Bool { search.matchCount > 0 }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ChatColors.secondaryText)
                TextField(AppLocalized("Search this chat"), text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($fieldFocused)
                    .onSubmit {
                        search.next()
                        // Return must not dismiss the keyboard: the user is
                        // stepping through results.
                        fieldFocused = true
                    }
                    .accessibilityIdentifier("chatSearchField")
                if hasQuery {
                    counter
                    Button {
                        search.query = ""
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(ChatColors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppLocalized("Clear"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            navButton(systemName: "chevron.up", label: AppLocalized("Previous Result")) { search.previous() }
                .keyboardShortcut(.return, modifiers: .shift)
                .accessibilityIdentifier("chatSearchPrevious")
            navButton(systemName: "chevron.down", label: AppLocalized("Next Result")) { search.next() }
                .accessibilityIdentifier("chatSearchNext")

            Button {
                fieldFocused = false
                search.deactivate()
                onDone()
            } label: {
                Text(AppLocalized("Done"))
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.leading, 2)
            .accessibilityIdentifier("chatSearchDone")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .bottom) { noticeView.offset(y: 34) }
        .onAppear { fieldFocused = true }
        .onChange(of: search.focusRequest) { _ in fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatSearchBar")
    }

    @ViewBuilder
    private var counter: some View {
        if search.isSearching && !hasResults {
            ProgressView().scaleEffect(0.7).frame(width: 20)
        } else if hasResults {
            Text(verbatim: ChatSearchNavigation.counterText(index: search.currentIndex, count: search.matchCount,
                                                            truncated: search.isTruncated))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(search.currentIndex.map { AppLocalized("Result \($0 + 1) of \(search.matchCount)") } ?? "")
                .accessibilityIdentifier("chatSearchCounter")
        } else {
            Text(AppLocalized("No results"))
                .font(.system(size: 13))
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("chatSearchCounter")
        }
    }

    private func navButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasResults ? Color.accentColor : ChatColors.tertiaryText)
        .disabled(!hasResults)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = search.notice {
            Text(ChatSearchController.noticeText(notice))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75), in: Capsule())
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// [T-in-chat-search] The chat page's side of search, kept out of AIChatView's
/// body: offers "Search in Chat" to the long-press menus while this page shows
/// the conversation, mirrors whether the bar is open into `isActive` (which
/// shows the bar and hides the composer), and closes the bar when the page
/// goes away.
struct ChatSearchHostModifier: ViewModifier {
    let search: ChatSearchController
    @Binding var isActive: Bool
    @Binding var inputFocused: Bool
    /// This page's claim on the opener (see `openSearchOwner`).
    @State private var ownerId = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                search.highlights.openSearchOwner = ownerId
                search.highlights.openSearch = { [weak search] prefill in
                    search?.activate(prefill: prefill)
                }
            }
            .onDisappear {
                // A page re-created for the same conversation may already have
                // taken over (its onAppear can run before this onDisappear).
                guard search.highlights.openSearchOwner == ownerId else { return }
                search.deactivate()
                search.highlights.openSearch = nil
                search.highlights.openSearchOwner = nil
            }
            .onReceive(search.$isActive.removeDuplicates()) { active in
                guard active != isActive else { return }
                // The composer is hidden while searching: two text fields
                // would fight over the keyboard.
                if active { inputFocused = false }
                isActive = active
            }
    }
}

/// [T-in-chat-search] Hides the composer while the search bar is open. It
/// keeps its place in the layout (only fades out and stops taking touches), so
/// the list's bottom inset - and with it the scroll position - is the same
/// before, during and after a search.
struct ChatSearchComposerHider: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}
