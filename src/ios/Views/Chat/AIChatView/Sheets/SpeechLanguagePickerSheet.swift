//
//  SpeechLanguagePickerSheet.swift
//  Minis - chat page (AIChatView)
//
//  Picker for the speech recognition language, opened from the composer's
//  language badge.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Speech Language Picker Sheet

private struct SpeechLanguagePickerSheet: View {
    @ObservedObject var speechManager: SpeechRecognitionManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredLocales: [Locale] {
        if searchText.isEmpty { return speechManager.availableLocales }
        let query = searchText.lowercased()
        return speechManager.availableLocales.filter { loc in
            let name = speechManager.displayName(for: loc).lowercased()
            let id = loc.identifier.lowercased()
            return name.contains(query) || id.contains(query)
        }
    }

    /// Indices where the preferred/non-preferred boundary lies for section headers.
    private var preferredCodes: Set<String> {
        Set(Locale.preferredLanguages.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" })
    }

    var body: some View {
        NavigationStack {
            List {
                let preferred = filteredLocales.filter { preferredCodes.contains($0.language.languageCode?.identifier ?? "") }
                let others = filteredLocales.filter { !preferredCodes.contains($0.language.languageCode?.identifier ?? "") }

                if !preferred.isEmpty {
                    Section(AppLocalized("Preferred", comment: "Section header for preferred speech languages")) {
                        ForEach(preferred, id: \.identifier) { loc in
                            languageRow(loc)
                        }
                    }
                }

                if !others.isEmpty {
                    Section(AppLocalized("All Languages", comment: "Section header for all speech languages")) {
                        ForEach(others, id: \.identifier) { loc in
                            languageRow(loc)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: Text("Search Languages", comment: "Search field placeholder for speech language picker"))
            .navigationTitle(Text("Voice Language", comment: "Navigation title for speech language picker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Done", comment: "Dismiss speech language picker")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func languageRow(_ loc: Locale) -> some View {
        Button {
            speechManager.setLanguage(loc)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speechManager.displayName(for: loc))
                        .foregroundStyle(.primary)
                    Text(loc.identifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if loc.identifier == speechManager.locale.identifier {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
