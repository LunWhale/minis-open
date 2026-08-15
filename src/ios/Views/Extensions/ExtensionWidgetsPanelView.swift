//
//  ExtensionWidgetsPanelView.swift
//  MinisApp
//
//  Renders all enabled extension UI widgets (ui/widget.html from .minisx
//  bundles) via ExtensionWebView. Surfaced from the chat "…" menu so users
//  can actually see extension widgets. Each widget's html file is loaded
//  from the unpacked bundle; the "ui" permission is confirmed on first use.
//

import SwiftUI

struct ExtensionWidgetsPanelView: View {
    @State private var widgets: [(extensionID: String, widget: ExtensionManifest.UIDef, bundleURL: URL)] = []
    @State private var rendered: [String: Bool] = [:]  // extID:widgetIndex → allowed
    @State private var widgetMessages: [String: String] = [:]  // log of widget→native msgs

    var body: some View {
        NavigationStack {
            List {
                if widgets.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "rectangle.inset.filled.and.person.filled")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No extension widgets")
                                .font(.headline)
                            Text("Extensions can ship WebView components (ui/widget.html). Install a .minisx bundle with ui-widget kind to see them here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else {
                    ForEach(Array(widgets.enumerated()), id: \.offset) { idx, entry in
                        widgetSection(idx, entry: entry)
                    }
                }
            }
            .navigationTitle("Extension Widgets")
            .navigationBarTitleDisplayMode(.inline)
            .task { reload() }
        }
    }

    private func reload() {
        widgets = ExtensionRegistry.shared.uiWidgets()
    }

    @ViewBuilder
    private func widgetSection(_ idx: Int, entry: (extensionID: String, widget: ExtensionManifest.UIDef, bundleURL: URL)) -> some View {
        let key = "\(entry.extensionID):\(idx)"
        let allowed = rendered[key] ?? false

        Section {
            if allowed {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(entry.extensionID)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.widget.type)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    let htmlURL = entry.bundleURL.appendingPathComponent(entry.widget.file)
                    ExtensionWebView(
                        extensionID: entry.extensionID,
                        htmlURL: htmlURL,
                        onMessage: { extID, payload in
                            widgetMessages[key] = String(describing: payload)
                        }
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
                    if let msg = widgetMessages[key] {
                        Text("widget → native: \(msg)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            } else {
                Button {
                    Task {
                        let granted = await ExtensionWidgetGate.canRender(
                            extensionID: entry.extensionID,
                            permissions: permissions(for: entry.extensionID)
                        )
                        rendered[key] = granted
                    }
                } label: {
                    HStack {
                        Image(systemName: "play.rectangle")
                        Text("Show widget: \(entry.extensionID)")
                        Spacer()
                    }
                }
            }
        } header: {
            Text("Widget \(idx + 1)")
        }
    }

    private func permissions(for extensionID: String) -> [String] {
        // Look up the manifest permissions from the registry's cached manifests.
        ExtensionRegistry.shared.manifestPermissions(for: extensionID)
    }
}
