//
//  ExportPreviewSheet.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  Export result: ExportSummary and the preview sheet, with the share sheet
//  and document picker it presents (private to this file).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

// MARK: - Export Summary

struct ExportSummary {
    var format: String = ""
    var sessionCount: Int = 0
    var totalMessages: Int = 0
    var attachmentCount: Int = 0
    var earliest: Date? = nil
    var latest: Date? = nil
    var fileSizeBytes: Int64 = 0
}

// MARK: - Export Preview Sheet

struct ExportPreviewSheet: View {
    /// The artifact the user shares / saves — normally a `.zip`.
    let fileURL: URL?
    /// [T-export-preview-blank] The text payload to RENDER. Distinct from
    /// `fileURL` because the shared artifact is zipped, and zip bytes never
    /// decode as UTF-8 — reading `fileURL` left the pane blank while the file
    /// size (read from filesystem attributes, not the content) still showed,
    /// which is exactly how the bug presented. Falls back to `fileURL` when the
    /// caller has nothing separate to offer.
    var previewURL: URL? = nil
    let summary: ExportSummary?

    /// File to read for the on-screen text.
    private var textSourceURL: URL? { previewURL ?? fileURL }
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var showFilePicker = false
    @State private var copied = false
    @State private var previewText: String = ""
    @State private var fileSize: String = ""
    @State private var isLoadingPreview = true

    private let previewLimit = 10000

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Preview — summary for multi-select, full content for single.
                if let summary {
                    summaryView(summary)
                } else if isLoadingPreview {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    ScrollView {
                        Text(previewText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color(UIColor.label))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                    .background(Color(UIColor.secondarySystemBackground))
                }

                Divider()

                // File size info
                if !fileSize.isEmpty {
                    Text(fileSize)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 6)
                }

                // Action buttons
                HStack(spacing: 0) {
                    // [T-export-preview-blank] Copy needs a TEXT source. It used to
                    // test `fileURL`, which is the zip, so Copy silently vanished
                    // from every single-session export — the same zip-vs-payload
                    // confusion that blanked the preview. Test the payload we
                    // actually read instead, so Copy is offered exactly when there
                    // is something readable to copy.
                    if summary == nil, textSourceURL?.pathExtension.lowercased() != "zip" {
                        actionButton(icon: "doc.on.doc", label: copied ? AppLocalized("Copied") : AppLocalized("Copy")) {
                            if let url = textSourceURL, let content = try? String(contentsOf: url, encoding: .utf8) {
                                UIPasteboard.general.string = content
                            }
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }
                    actionButton(icon: "square.and.arrow.up", label: AppLocalized("Share")) {
                        showShareSheet = true
                    }
                    actionButton(icon: "folder", label: AppLocalized("Save to Files")) {
                        showFilePicker = true
                    }
                }
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(AppLocalized("Export Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = fileURL {
                    ShareSheet(url: url)
                }
            }
            .sheet(isPresented: $showFilePicker) {
                if let url = fileURL {
                    DocumentExportPicker(url: url)
                }
            }
            .task {
                if summary == nil {
                    await loadPreview()
                } else {
                    // Still compute file size for the action bar.
                    if let url = fileURL,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int64 {
                        let formatter = ByteCountFormatter()
                        formatter.countStyle = .file
                        fileSize = formatter.string(fromByteCount: size)
                    }
                    isLoadingPreview = false
                }
            }
        }
    }

    @ViewBuilder
    private func summaryView(_ s: ExportSummary) -> some View {
        let dateFmt: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f
        }()
        let sizeStr: String = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f.string(fromByteCount: s.fileSizeBytes)
        }()
        let timeRange: String = {
            guard let e = s.earliest, let l = s.latest else { return "—" }
            return "\(dateFmt.string(from: e)) ~ \(dateFmt.string(from: l))"
        }()

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryRow(AppLocalized("Format"), s.format)
                summaryRow(AppLocalized("Sessions"), "\(s.sessionCount)")
                summaryRow(AppLocalized("Messages"), "\(s.totalMessages)")
                summaryRow(AppLocalized("Time range"), timeRange)
                summaryRow(AppLocalized("Attachments"), "\(s.attachmentCount)")
                summaryRow(AppLocalized("Estimated size"), sizeStr)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func summaryRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadPreview() async {
        guard let url = textSourceURL else {
            isLoadingPreview = false
            return
        }

        // Load file size — of the SHARED artifact (`fileURL`), not the preview
        // payload. The number under the pane labels the file the user is about to
        // share or save, so it has to be the zip's size even though the text above
        // it comes from the uncompressed payload.
        if let sizeURL = fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: sizeURL.path),
           let size = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            fileSize = formatter.string(fromByteCount: size)
        }

        // Read only the preview portion to avoid loading huge files into memory
        await Task.detached(priority: .utility) {
            var preview = ""
            if let handle = FileHandle(forReadingAtPath: url.path) {
                // Read at most previewLimit bytes worth of data
                let data = handle.readData(ofLength: previewLimit * 4) // UTF-8 can be up to 4 bytes per char
                handle.closeFile()
                // [T-export-preview-blank] Decode defensively. `readData` cuts at a
                // byte offset, so on any file larger than the read window the cut
                // can land mid-UTF-8-sequence and strict decoding returns nil —
                // another silent blank page, this time only for big exports.
                // Retry by trimming up to 3 trailing bytes (the longest possible
                // partial sequence), then fall back to a lossy decode so the user
                // sees the content rather than nothing.
                var decoded = String(data: data, encoding: .utf8)
                if decoded == nil, data.count > 3 {
                    for drop in 1...3 {
                        if let t = String(data: data.dropLast(drop), encoding: .utf8) {
                            decoded = t
                            break
                        }
                    }
                }
                let text = decoded ?? String(decoding: data, as: UTF8.self)
                if !text.isEmpty {
                    if text.count > previewLimit {
                        preview = String(text.prefix(previewLimit)) + "\n\n…"
                    } else {
                        preview = text
                    }
                }
            }
            await MainActor.run {
                previewText = preview
                isLoadingPreview = false
            }
        }.value
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // [T-share-sheet-uti] Defense against ShareKit's
        // UTTypeGetForIdentifier assert on Mac Catalyst — see
        // MinisShareSheet.sanitizedShareURL for context.
        let safeURL = MinisShareSheet.sanitizedShareURL(url) ?? url
        return UIActivityViewController(activityItems: [safeURL], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Document Export Picker

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url])
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}
