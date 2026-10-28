import SwiftUI
import UIKit

// MARK: - Sources [T-crash-diag-export]

/// The crash diagnostics on this device - earlier runs' breadcrumbs, the
/// minimal signal contexts, MetricKit JSON - as a list for Settings > Logs and
/// the debug RPC, and as the export bundle. Everything a caller reads through
/// here is already sanitised (LogRedaction).
enum CrashDiagnostics {
    struct Item: Identifiable, Hashable {
        enum Kind: String { case breadcrumbs, currentRun = "current", context, metricKit = "metrickit" }
        let id: String          // "<kind>:<file name>"
        let kind: Kind
        let url: URL
        let title: String
        let size: Int64
        let modified: Date?
    }

    static var contextArchiveDir: URL {
        URL(fileURLWithPath: CrashBreadcrumbs.directory()).appendingPathComponent("contexts", isDirectory: true)
    }

    private static var logsDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    static func items() -> [Item] {
        var out: [Item] = []
        let fm = FileManager.default
        func attrs(_ url: URL) -> (Int64, Date?) {
            let a = try? fm.attributesOfItem(atPath: url.path)
            return ((a?[.size] as? NSNumber)?.int64Value ?? 0, a?[.modificationDate] as? Date)
        }
        let current = URL(fileURLWithPath: CrashBreadcrumbs.directory()).appendingPathComponent("current.bin")
        if fm.fileExists(atPath: current.path) {
            let (s, m) = attrs(current)
            out.append(Item(id: "current:current.bin", kind: .currentRun, url: current,
                            title: AppLocalized("This run"), size: s, modified: m))
        }
        for path in CrashBreadcrumbs.previousRunFiles() {
            let url = URL(fileURLWithPath: path)
            let (s, m) = attrs(url)
            out.append(Item(id: "breadcrumbs:\(url.lastPathComponent)", kind: .breadcrumbs, url: url,
                            title: runTitle(url.lastPathComponent), size: s, modified: m))
        }
        for url in files(in: contextArchiveDir, prefix: "context-", suffix: ".txt") {
            let (s, m) = attrs(url)
            out.append(Item(id: "context:\(url.lastPathComponent)", kind: .context, url: url,
                            title: url.deletingPathExtension().lastPathComponent, size: s, modified: m))
        }
        for url in files(in: logsDir, prefix: "metrickit-", suffix: ".json") {
            let (s, m) = attrs(url)
            out.append(Item(id: "metrickit:\(url.lastPathComponent)", kind: .metricKit, url: url,
                            title: url.deletingPathExtension().lastPathComponent, size: s, modified: m))
        }
        return out
    }

    /// Sanitised text of one item; nil when the id is unknown.
    static func read(id: String) -> String? {
        guard let item = items().first(where: { $0.id == id }) else { return nil }
        return LogRedaction.sanitizeForExport(rawText(item))
    }

    private static func rawText(_ item: Item) -> String {
        switch item.kind {
        case .breadcrumbs, .currentRun:
            return CrashBreadcrumbs.renderFile(atPath: item.url.path)
        case .context, .metricKit:
            return (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        }
    }

    /// Builds the zip: breadcrumbs (the current run's include its page/sheet
    /// slots), the resource samples pulled out of every run, the minimal
    /// contexts, MetricKit JSON and the last ~2 MB of the newest log.
    static func exportZip() throws -> URL {
        let stamp: String = {
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"; return df.string(from: Date())
        }()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("CrashDiagnostics", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let folder = base.appendingPathComponent("Minis-crash-diagnostics-\(stamp)", isDirectory: true)
        let all = items()
        var sources: [CrashDiagnosticsExport.Source] = all.map { item in
            let path: String
            switch item.kind {
            case .currentRun: path = "breadcrumbs/current-run.txt"
            case .breadcrumbs: path = "breadcrumbs/\(item.url.deletingPathExtension().lastPathComponent).txt"
            case .context: path = "contexts/\(item.url.lastPathComponent)"
            case .metricKit: path = "metrickit/\(item.url.lastPathComponent)"
            }
            let kind: CrashDiagnosticsExport.Kind = item.kind == .context ? .context
                : (item.kind == .metricKit ? .metricKit : .breadcrumbs)
            return .init(kind: kind, path: path) { rawText(item) }
        }
        sources.append(.init(kind: .breadcrumbs, path: "resources.txt") {
            all.filter { $0.kind == .breadcrumbs || $0.kind == .currentRun }.map { item -> String in
                let lines = rawText(item).split(separator: "\n").filter { $0.contains(" res ") || $0.hasPrefix("[res]") }
                return "== \(item.title)\n" + lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        })
        if let log = LoggingManager.shared.logFiles().filter({ $0.type == "running" }).max(by: { $0.date < $1.date }) {
            sources.append(.init(kind: .log, path: "logs/\(log.name)") { CrashDiagnosticsExport.tail(of: log.url) })
        }
        let info = Bundle.main.infoDictionary
        let header = "Minis crash diagnostics\nApp \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
            + "\nSystem \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\nExported \(stamp)"
        try CrashDiagnosticsExport.writeBundle(sources, into: folder, header: header)
        let zip = base.appendingPathComponent("\(folder.lastPathComponent).zip")
        try CrashDiagnosticsExport.zip(folder: folder, to: zip)
        return zip
    }

    private static func files(in dir: URL, prefix: String, suffix: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.sorted(by: >)
            .map { dir.appendingPathComponent($0) }
    }

    private static func runTitle(_ name: String) -> String {
        // crumbs-<launch ms>.bin
        let digits = name.dropFirst("crumbs-".count).prefix { $0.isNumber }
        guard let ms = Double(digits) else { return name }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
        return df.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}

// MARK: - Views

struct CrashDiagnosticsView: View {
    @State private var items: [CrashDiagnostics.Item] = []
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                Button {
                    export()
                } label: {
                    HStack {
                        Label("Export Diagnostics", systemImage: "square.and.arrow.up")
                        Spacer()
                        if exporting { ProgressView() }
                    }
                }
                .disabled(exporting)
            } footer: {
                Text("A zip of the breadcrumbs, crash contexts, MetricKit reports and the last 2 MB of the log. Keys, tokens, URL parameters, e-mail addresses and request bodies are removed first.")
            }
            section("Earlier Runs", kinds: [.breadcrumbs])
            section("Crash Contexts", kinds: [.context])
            section("MetricKit Reports", kinds: [.metricKit])
            section("This Run", kinds: [.currentRun])
        }
        .navigationTitle("Crash Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { items = CrashDiagnostics.items() }
        .sheet(item: Binding(get: { exportURL.map(ExportedFile.init) }, set: { exportURL = $0?.url })) { file in
            CrashDiagnosticsShareSheet(url: file.url)
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, kinds: Set<CrashDiagnostics.Item.Kind>) -> some View {
        let rows = items.filter { kinds.contains($0.kind) }
        Section(title) {
            if rows.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(rows) { item in
                    NavigationLink {
                        CrashDiagnosticTextView(id: item.id, title: item.title)
                    } label: {
                        HStack {
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func export() {
        exporting = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try CrashDiagnostics.exportZip() }
            await MainActor.run {
                exporting = false
                switch result {
                case .success(let url): exportURL = url
                case .failure(let error): exportError = error.localizedDescription
                }
            }
        }
    }
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct CrashDiagnosticTextView: View {
    let id: String
    let title: String
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let id = self.id
            text = await Task.detached { CrashDiagnostics.read(id: id) ?? "" }.value
        }
    }
}

private struct CrashDiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // [T-share-sheet-uti] Same sanitising as the log share sheet.
        UIActivityViewController(activityItems: [MinisShareSheet.sanitizedShareURL(url) ?? url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
