import Foundation

/// [T-crash-diag-export] Builds the crash-diagnostics bundle a user / tester
/// sends after an unexpected exit: breadcrumbs of earlier runs, the minimal
/// signal contexts, MetricKit JSON, the current run's breadcrumbs (fixed page
/// and resource slots included) and the last ~2 MB of the log - all passed
/// through LogRedaction before they are written.
///
/// Foundation only (no UIKit, no app singletons): the caller hands in the
/// sources, so MinisTests/Standalone/CrashDiagnosticsExportTests.swift can run
/// it as shipped.
enum CrashDiagnosticsExport {
    /// How much of the newest log goes into the bundle.
    static let logTailBytes = 2 * 1024 * 1024

    enum Kind: String {
        case breadcrumbs, context, metricKit = "metrickit", log, readme
        /// Sanitising for each kind: logs also lose request bodies.
        func sanitize(_ text: String) -> String {
            self == .log ? LogRedaction.sanitizeLogForExport(text) : LogRedaction.sanitizeForExport(text)
        }
    }

    /// One file of the bundle: where it goes and how to get its text.
    struct Source {
        let kind: Kind
        /// Path inside the bundle, e.g. "breadcrumbs/run-1790866208036.txt".
        let path: String
        let text: () -> String?
    }

    /// Writes every source (sanitised) under `root`, plus a manifest README.
    /// Returns the relative paths written.
    @discardableResult
    static func writeBundle(_ sources: [Source], into root: URL, header: String) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var written: [String] = []
        for source in sources {
            guard let raw = source.text(), !raw.isEmpty else { continue }
            let url = root.appendingPathComponent(source.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.kind.sanitize(raw).utf8).write(to: url, options: .atomic)
            written.append(source.path)
        }
        let readme = header + "\n\nFiles:\n" + written.map { "  \($0)" }.joined(separator: "\n")
            + "\n\nRedacted before export: API keys (sk-...), Bearer tokens, Authorization values, "
            + "URL query parameters, e-mail addresses; request bodies in logs are reduced to their size.\n"
        try Data(readme.utf8).write(to: root.appendingPathComponent("README.txt"), options: .atomic)
        return written + ["README.txt"]
    }

    /// The last `maxBytes` of a text file, starting at a line boundary.
    static func tail(of url: URL, maxBytes: Int = logTailBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    /// Zips `folder` into `destination` with the system's own archiver
    /// (NSFileCoordinator .forUploading) - no third-party code.
    static func zip(folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
    }
}
