//
//  DeleteConfirmSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Confirmation sheet for deleting sessions, listing what will be removed
//  (DeleteInfo from ContentView+SessionActions).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Delete Confirm Sheet

struct DeleteConfirmSheet: View {
    @Binding var info: ContentView.DeleteInfo?
    let isLoading: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading || info == nil {
                    Spacer()
                    ProgressView("Calculating…")
                        .controlSize(.large)
                    Spacer()
                    let _ = print("[DELETE] DeleteConfirmSheet showing ProgressView. isLoading=\(isLoading), info is \(info == nil ? "nil" : "non-nil")")
                } else if let info {
                    let _ = print("[DELETE] DeleteConfirmSheet showing info. sessionCount=\(info.sessionCount)")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Sessions
                            infoRow(
                                title: "Sessions",
                                value: info.childCount > 0
                                    ? "\(info.sessionCount - info.childCount) session\(info.sessionCount - info.childCount == 1 ? "" : "s") + \(info.childCount) agent session\(info.childCount == 1 ? "" : "s") and all messages"
                                    : "\(info.sessionCount) session\(info.sessionCount == 1 ? "" : "s") and all messages"
                            )

                            // Files
                            if info.totalFileCount > 0 {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Associated Files")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                    ForEach(info.fileNames, id: \.self) { name in
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(name)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if info.totalFileCount > info.fileNames.count {
                                        Text("and \(info.totalFileCount - info.fileNames.count) more file\(info.totalFileCount - info.fileNames.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            // Storage
                            infoRow(title: "Releases Storage", value: info.formattedSize)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    // Buttons
                    VStack(spacing: 10) {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Text("Delete (\(info.formattedSize))")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button {
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Confirm Deletion")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
