//
//  ProviderImportPrompt.swift
//  Minis - chat page (AIChatView)
//
//  Shared / opened Provider-export JSON: ProviderImportPromptModifier presents
//  ProviderImportSheet, which offers "Import as Provider" or "Add as Chat
//  Attachment".
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

// MARK: - Provider Import Prompt

/// Presents the import-vs-attach choice for a shared/opened Provider-export
/// JSON, plus a result alert. Extracted from AIChatView.body so the (already
/// large) body's type-checker stays cheap. [T-ios-json-open-provider-import-prompt]
struct ProviderImportPromptModifier: ViewModifier {
    @Binding var pending: AIChatView.PendingProviderImport?
    @Binding var result: String?
    /// Import the provider from JSON; returns the new instance label on success.
    let onImport: (String) -> String?
    /// Add the (temp-copied) file to the chat as an attachment.
    let onAttach: (URL) -> Void

    func body(content: Content) -> some View {
        content
            // [T-ios-provider-import-prompt-bottom-sheet] Use a real bottom
            // sheet, not .confirmationDialog. On iPad / regular width SwiftUI
            // renders .confirmationDialog (and a UIAlertController .actionSheet)
            // as a SOURCE-ANCHORED POPOVER; with no anchor it floats a centered
            // rounded card over the messages — the "not a system dialog" look
            // the user reported. A `.sheet` with detents is a genuine
            // bottom-pinned sheet on BOTH iPhone and iPad.
            .sheet(item: $pending) { item in
                ProviderImportSheet(
                    onImport: {
                        pending = nil
                        if let label = onImport(item.json) {
                            result = AppLocalized("Imported provider \"\(label)\".")
                        } else {
                            result = AppLocalized("Could not import this provider configuration.")
                        }
                        try? FileManager.default.removeItem(at: item.fileURL)
                    },
                    onAttach: {
                        pending = nil
                        onAttach(item.fileURL)
                    },
                    onCancel: {
                        try? FileManager.default.removeItem(at: item.fileURL)
                        pending = nil
                    }
                )
            }
            .alert(
                AppLocalized("Provider Import"),
                isPresented: Binding(
                    get: { result != nil },
                    set: { if !$0 { result = nil } }
                )
            ) {
                Button(AppLocalized("OK"), role: .cancel) { result = nil }
            } message: {
                Text(result ?? "")
            }
    }
}

// MARK: - Provider Import Bottom Sheet

/// Bottom sheet offering "Import as Provider" vs "Add as Chat Attachment" for a
/// shared/opened Provider-export JSON. A real sheet (not .confirmationDialog)
/// so it pins to the bottom on iPad too, instead of floating a centered popover
/// card. [T-ios-provider-import-prompt-bottom-sheet]
private struct ProviderImportSheet: View {
    let onImport: () -> Void
    let onAttach: () -> Void
    let onCancel: () -> Void

    /// Set once the user taps any explicit button, so the `.onDisappear`
    /// safety-cleanup only fires for a genuine swipe-to-dismiss (no choice).
    @State private var chose = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .padding(.top, 8)
                Text(AppLocalized("Provider Configuration Detected"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(AppLocalized("This JSON file looks like an exported provider configuration. Import it as a new provider, or add it to the chat as a file attachment?"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(action: { chose = true; onImport() }) {
                    Text(AppLocalized("Import as Provider"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { chose = true; onAttach() }) {
                    Text(AppLocalized("Add as Chat Attachment"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(role: .cancel, action: { chose = true; onCancel() }) {
                    Text(AppLocalized("Cancel"))
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(24)
        .presentationDetents([.height(360), .medium])
        .presentationDragIndicator(.visible)
        // Swipe-to-dismiss without tapping a button still needs cleanup.
        .onDisappear { if !chose { onCancel() } }
    }
}
