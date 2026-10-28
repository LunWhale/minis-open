//
//  SessionOverrideListParts.swift
//  MinisApp
//
//  Pieces shared by the in-chat per-session override sheets ("Skills in
//  Session", "MCPs in Session"): the Enable All / Disable All header, the
//  footer that states the search scope, and the empty-state card.
//

import SwiftUI

// BEGIN SessionBulkToggleRules
/// Pure rules behind the Enable All / Disable All buttons.
enum SessionBulkToggleRules {
    struct Availability: Equatable {
        /// At least one item in scope is off, so Enable All changes something.
        let canEnable: Bool
        /// At least one item in scope is on, so Disable All changes something.
        let canDisable: Bool
    }

    static func availability(_ enabledStates: [Bool]) -> Availability {
        Availability(canEnable: enabledStates.contains(false),
                     canDisable: enabledStates.contains(true))
    }

    /// Whether the list is narrowed by a search, i.e. the bulk actions do not
    /// cover every item. Matches the trimming the sheets' filters do.
    static func isFiltered(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
// END SessionBulkToggleRules

/// Enable All and Disable All as two fixed buttons, instead of one button
/// whose title flipped with the current state. They sit in the list's section
/// header rather than the toolbar because iOS hides the navigation bar while
/// the search field is active, which made a toolbar button unreachable exactly
/// when the list was filtered. Both act on what the list shows; a button that
/// would change nothing is disabled rather than hidden so the pair stays put.
struct SessionBulkToggleHeader: View {
    let availability: SessionBulkToggleRules.Availability
    let apply: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            Button(AppLocalized("Enable All")) { apply(true) }
                .disabled(!availability.canEnable)
            Button(AppLocalized("Disable All")) { apply(false) }
                .disabled(!availability.canDisable)
        }
        // Borderless so each button keeps its own hit area inside the list.
        .buttonStyle(.borderless)
        .font(.subheadline)
        .textCase(nil)
    }
}

/// The sheet's override note, plus the search-scope line while filtered.
struct SessionOverrideListFooter: View {
    let note: Text
    let searchQuery: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            note
            if SessionBulkToggleRules.isFiltered(searchQuery) {
                Text(AppLocalized("Enable All and Disable All apply only to the search results."))
            }
        }
    }
}

/// Shown when nothing is configured at all: says so and points to where items
/// are added. Mirrors Android's EmptySkillsCard / EmptyMcpsCard.
struct SessionOverrideEmptyCard: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
    }
}
