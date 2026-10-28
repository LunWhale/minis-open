import Foundation

/// [T-filetool-io-offmain] The blocking half of file_read / file_write /
/// file_edit, kept off the main thread.
///
/// Background: on 2026-10-02 at 14:23:48 a file_edit on
/// /var/minis/mounts/nssurge/Mobile.conf (a mounted folder inside Surge's
/// iCloud container, .../Library/Mobile Documents/iCloud~com~nssurge~inc/...)
/// called `String(contentsOf:)` on the main actor. read() did not return for
/// 75s, so the whole app froze until FrontBoard's scene-update watchdog killed
/// it (0x8BADF00D). When the chat was reopened, the resumed turn issued the
/// same edit and the app was killed again a minute later. A plain read() of an
/// iCloud file that is not downloaded (or is being written by its owner app)
/// waits for the file provider for as long as that takes.
///
/// What this file does:
///   - `run` executes the work on a dedicated concurrent GCD queue: not the
///     main thread, and not Swift concurrency's cooperative pool, which a few
///     stuck read()s would exhaust. It gives up after a timeout and returns an
///     error the agent can act on. A read() already stuck in the kernel cannot
///     be interrupted; it keeps one background thread busy, not the UI.
///   - For iCloud / File Provider files it asks for the content
///     (startDownloadingUbiquitousItem, failing at once on a download error
///     iCloud reports), then reads and writes through NSFileCoordinator. A
///     coordinated read of a not-yet-local item downloads it before the reader
///     runs, so the wait for the download IS the coordinated access: bounded by
///     run()'s timeout and cancelled when it fires. [T-filetool-icloud-wait]
///   - A timeout on a cloud file reports the item's iCloud state (downloaded
///     or not, downloading, download error, conflicts), so the agent and the
///     log see why instead of a bare "timed out".
///   - The file_edit matching and replacement runs here too, so a large file
///     no longer costs the main thread its normalization pass.
///
/// Foundation only - MinisTests/Standalone/FileToolIOTests.swift compiles this
/// file as shipped.
enum FileToolIO {

    // MARK: - Limits

    /// Overall time allowed for one file tool's I/O, the iCloud download
    /// (inside the coordinated access) included.
    static let ioTimeout: TimeInterval = 45
    /// file_edit refuses files larger than this (the fuzzy matcher keeps an
    /// index per character); `sed` / a script in the shell handles those.
    static let maxEditBytes = 8 * 1024 * 1024

    enum IOError: Error, CustomStringConvertible {
        /// `cloudState`: the item's iCloud state when the timeout fired (nil
        /// for a file that is not in iCloud).
        case timedOut(operation: String, seconds: Int, mayHaveWritten: Bool, cloudState: String? = nil)
        /// iCloud reported that it cannot download the item.
        case downloadFailed(reason: String)

        var description: String {
            switch self {
            case let .timedOut(operation, seconds, mayHaveWritten, cloudState):
                let cause = cloudState.map { " The file is in iCloud: \($0)." }
                    ?? " The file may be in iCloud or another file provider that is not responding."
                return "\(operation) did not finish within \(seconds)s.\(cause)"
                    + (mayHaveWritten ? " The write may still complete; re-read the file before retrying." : " Retry in a moment; do not work from an older copy.")
            case let .downloadFailed(reason):
                return "the file is in iCloud and iCloud could not download it to this device: \(reason). Nothing was read or written."
            }
        }
    }

    // MARK: - Runner

    private static let queue = DispatchQueue(label: "minis.filetool.io", qos: .userInitiated, attributes: .concurrent)

    /// Cancels a pending NSFileCoordinator wait when the runner times out.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var coordinator: NSFileCoordinator?
        private var cancelled = false

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func attach(_ c: NSFileCoordinator) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { coordinator = c }
            lock.unlock()
            if alreadyCancelled { c.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let c = coordinator
            lock.unlock()
            c?.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Run blocking file work off the main thread; throw `IOError.timedOut`
    /// if it has not finished after `timeout` seconds.
    ///
    /// `url`: the file the work touches. When it is cloud-backed, a timeout
    /// reports its iCloud state (`cloudState(_:)`).
    static func run<T: Sendable>(
        _ operation: String,
        timeout: TimeInterval = ioTimeout,
        writes: Bool = false,
        url: URL? = nil,
        _ work: @escaping @Sendable (Cancellation) throws -> T
    ) async throws -> T {
        let once = Once()
        let cancellation = Cancellation()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                let result = Result { try work(cancellation) }
                if once.claim() { cont.resume(with: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                cancellation.cancel()
                let state = url.flatMap { isCloudBacked($0) ? cloudState($0) : nil }
                cont.resume(throwing: IOError.timedOut(operation: operation, seconds: Int(timeout),
                                                       mayHaveWritten: writes, cloudState: state))
            }
        }
    }

    // MARK: - iCloud / File Provider

    /// True when `url` is served by iCloud or another file provider rather
    /// than being a plain local file.
    static func isCloudBacked(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
            || path.contains("/File Provider Storage/") {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem == true
    }

    private static let cloudKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingErrorKey, .ubiquitousItemHasUnresolvedConflictsKey,
    ]

    private static func cloudValues(_ url: URL) -> URLResourceValues? {
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: cloudKeys), v.isUbiquitousItem == true else { return nil }
        return v
    }

    /// Ask iCloud for the item's content when it is not on the device, and
    /// fail at once if iCloud reports it cannot download it. Does NOT wait for
    /// the download: the coordinated access that follows does (see the file
    /// comment). No-op for files that are not ubiquitous or already local.
    ///
    /// This replaces a 30s status poll that ended in "not downloaded yet"
    /// while the overall timeout still had time left, and that never looked
    /// at the download error, so a failing download read as a slow one.
    static func requestDownload(_ url: URL) throws {
        guard let v = cloudValues(url) else { return }   // not an iCloud item
        if let s = v.ubiquitousItemDownloadingStatus, s == .current || s == .downloaded { return }
        if let error = v.ubiquitousItemDownloadingError {
            throw IOError.downloadFailed(reason: describe(error))
        }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw IOError.downloadFailed(reason: describe(error))
        }
    }

    /// The item's iCloud state in a few words, for a timeout message; nil when
    /// the item is not ubiquitous (or its state cannot be read).
    static func cloudState(_ url: URL) -> String? {
        guard let v = cloudValues(url) else { return nil }
        var parts: [String] = []
        switch v.ubiquitousItemDownloadingStatus {
        case .current?: parts.append("downloaded (current)")
        case .downloaded?: parts.append("downloaded (an older version)")
        case .notDownloaded?: parts.append("not downloaded to this device")
        default: parts.append("download status unknown")
        }
        if v.ubiquitousItemIsDownloading == true { parts.append("download in progress") }
        else if v.ubiquitousItemDownloadingStatus == .notDownloaded { parts.append("no download running") }
        if let error = v.ubiquitousItemDownloadingError { parts.append("download error: \(describe(error))") }
        if v.ubiquitousItemHasUnresolvedConflicts == true { parts.append("has unresolved version conflicts") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    /// Run `body` under a coordinated read of `url` when it is cloud-backed,
    /// or directly otherwise.
    private static func coordinatedRead<T>(_ url: URL, cancellation: Cancellation, _ body: (URL) throws -> T) throws -> T {
        guard isCloudBacked(url) else { return try body(url) }
        try requestDownload(url)
        let coordinator = NSFileCoordinator()
        cancellation.attach(coordinator)
        var coordError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            result = Result { try body(readURL) }
        }
        if let coordError { throw coordError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    /// Run `body` under a coordinated write of `url` when it is cloud-backed,
    /// or directly otherwise. `.forMerging` because callers read-modify-write.
    private static func coordinatedWrite<T>(_ url: URL, cancellation: Cancellation, _ body: (URL) throws -> T) throws -> T {
        guard isCloudBacked(url) || isCloudBacked(url.deletingLastPathComponent()) else { return try body(url) }
        if FileManager.default.fileExists(atPath: url.path) {
            try requestDownload(url)
        }
        let coordinator = NSFileCoordinator()
        cancellation.attach(coordinator)
        var coordError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { writeURL in
            result = Result { try body(writeURL) }
        }
        if let coordError { throw coordError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    // MARK: - Operations

    /// file_read: the whole file's bytes.
    static func readData(_ url: URL, cancellation: Cancellation) throws -> Data {
        try coordinatedRead(url, cancellation: cancellation) { try Data(contentsOf: $0) }
    }

    /// file_write: write or append `data`, creating the parent directory if
    /// it is missing (or `createDirs` asks for it).
    static func writeData(_ data: Data, to url: URL, append: Bool, createDirs: Bool, cancellation: Cancellation) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if createDirs || !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try coordinatedWrite(url, cancellation: cancellation) { target in
            if append, fm.fileExists(atPath: target.path) {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: target)
            }
        }
    }

    enum EditOutcome: Sendable, Equatable {
        /// Written. `bytes` is the new file size.
        case edited(replacements: Int, bytes: Int, fuzzyNote: String?)
        /// Not written; `message` is the tool error text.
        case failed(String)
    }

    /// file_edit: read, replace and write back under one coordinated access,
    /// so the owner app (e.g. Surge editing its own config) cannot write in
    /// between.
    static func editFile(
        _ url: URL, path: String, oldString: String, newString: String, replaceAll: Bool,
        cancellation: Cancellation
    ) throws -> EditOutcome {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size > maxEditBytes {
            return .failed("Error: \(path) is \(size) bytes; file_edit handles files up to \(maxEditBytes) bytes. Use the shell (e.g. sed or a script) for larger files.")
        }
        let body: (URL) throws -> EditOutcome = { target in
            guard let data = try? Data(contentsOf: target),
                  let fileContent = String(data: data, encoding: .utf8) else {
                return .failed("Error: Could not read \(path) as UTF-8 text")
            }
            switch applyEdit(fileContent: fileContent, oldString: oldString, newString: newString,
                             replaceAll: replaceAll, path: path) {
            case let .failure(failure):
                return .failed(failure.message)
            case let .success(edit):
                guard let writeData = edit.updated.data(using: .utf8) else {
                    return .failed("Error: Updated content is not valid UTF-8")
                }
                do {
                    try writeData.write(to: target)
                } catch {
                    return .failed("Error writing \(path): \(error.localizedDescription)")
                }
                return .edited(replacements: edit.replacements, bytes: writeData.count, fuzzyNote: edit.fuzzyNote)
            }
        }
        if isCloudBacked(url) {
            try requestDownload(url)
            let coordinator = NSFileCoordinator()
            cancellation.attach(coordinator)
            var coordError: NSError?
            var result: Result<EditOutcome, Error>?
            coordinator.coordinate(readingItemAt: url, options: [], writingItemAt: url, options: .forMerging,
                                   error: &coordError) { readURL, _ in
                result = Result { try body(readURL) }
            }
            if let coordError { throw coordError }
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            return try result.get()
        }
        return try body(url)
    }

    // MARK: - file_edit matching (moved verbatim from AIChatViewModel+FileTools)

    struct EditResult { let updated: String; let replacements: Int; let fuzzyNote: String? }
    struct EditFailure: Error { let message: String }

    /// The replacement itself: strict match first, quote/whitespace-normalized
    /// fuzzy match as a fallback, one location unless `replaceAll`. Error
    /// messages are the ones file_edit has always returned.
    static func applyEdit(fileContent: String, oldString: String, newString: String,
                          replaceAll: Bool, path: String) -> Result<EditResult, EditFailure> {
        let strictRanges = findAllRanges(of: oldString, in: fileContent)

        // Fuzzy fallback. AIs routinely emit smart quotes as ASCII quotes
        // (Claude tokenizer especially) and drop trailing whitespace or
        // collapse runs of inline spaces when re-emitting code/prose they
        // just read. Strict byte-equality matching then rejects edits the
        // user clearly intended. When strict fails, normalize BOTH sides
        // (quotes, trailing whitespace, runs of inline spaces) and search
        // the normalized text — but apply the replacement against the
        // ORIGINAL byte range so the file's actual bytes are preserved
        // around the swap. Surface "fuzzy" in the success message so the
        // model learns its old_string didn't match verbatim.
        let fuzzyNote: String?
        let editRanges: [Range<String.Index>]
        if !strictRanges.isEmpty {
            editRanges = strictRanges
            fuzzyNote = nil
        } else {
            let (normFile, fileMap) = normalizeForFuzzyMatch(fileContent)
            let (normOld, _) = normalizeForFuzzyMatch(oldString)
            let normRanges = findAllRanges(of: normOld, in: normFile)
            if normRanges.isEmpty {
                let preview = buildFileEditPreview(
                    fileContent: fileContent,
                    oldString: oldString,
                    normFile: normFile,
                    normOld: normOld
                )
                return .failure(EditFailure(message: "Error: old_string not found in \(path). Use file_read to view current file contents before editing.\n\n\(preview)"))
            }
            // Map normalized character offsets back to original String.Index
            // ranges. The map array stores the original index for each char
            // in normFile; we look up the start char's mapping and walk to
            // the end char's mapping (+1) to get the matching original
            // range. This is robust across multi-byte UTF-8 because both
            // sides are operated on as Character sequences.
            var mapped: [Range<String.Index>] = []
            mapped.reserveCapacity(normRanges.count)
            for r in normRanges {
                let startOffset = normFile.distance(from: normFile.startIndex, to: r.lowerBound)
                let endOffset = normFile.distance(from: normFile.startIndex, to: r.upperBound)
                guard startOffset < fileMap.count else { continue }
                let originalStart = fileMap[startOffset]
                let originalEnd: String.Index
                if endOffset == 0 {
                    originalEnd = fileContent.startIndex
                } else if endOffset <= fileMap.count {
                    // Use the next char's mapped start (or file end) as the
                    // exclusive upper bound so we don't truncate.
                    let lastIncluded = fileMap[endOffset - 1]
                    originalEnd = fileContent.index(after: lastIncluded)
                } else {
                    originalEnd = fileContent.endIndex
                }
                mapped.append(originalStart..<originalEnd)
            }
            editRanges = mapped
            fuzzyNote = "fuzzy-matched: quotes/whitespace normalized"
        }

        if editRanges.count > 1 && !replaceAll {
            return .failure(EditFailure(message: "Error: old_string matches \(editRanges.count) locations in \(path). Provide more surrounding context to make the match unique, or set replace_all: true to replace all occurrences."))
        }

        // Apply replacements from the last range backwards so earlier
        // indices stay valid as we mutate the string.
        var updatedContent = fileContent
        for range in editRanges.reversed() {
            updatedContent.replaceSubrange(range, with: newString)
        }
        return .success(EditResult(updated: updatedContent, replacements: editRanges.count, fuzzyNote: fuzzyNote))
    }

    /// Find every (non-overlapping) range of `needle` in `haystack`,
    /// returning ranges in ascending order. Empty needle returns [].
    static func findAllRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var results: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            results.append(r)
            searchStart = r.upperBound
        }
        return results
    }

    /// Normalize text for fuzzy file_edit matching. Returns the normalized
    /// string AND a parallel array mapping each normalized character's
    /// position back to the corresponding original `String.Index`. The
    /// caller uses this map to translate a match position in the
    /// normalized string into the original file's byte range so the
    /// replacement preserves the file's actual bytes outside the match.
    ///
    /// Rules:
    ///   - Smart quotes → ASCII quotes
    ///     U+201C/U+201D → `"`,  U+2018/U+2019 → `'`
    ///   - Each line's trailing whitespace dropped
    ///   - Runs of inline ASCII spaces collapsed to a single space
    ///     (but only between non-whitespace — leading indent on a line
    ///     is preserved verbatim so source code formatting isn't lost)
    ///
    /// Tabs and other whitespace are left intact so indentation-significant
    /// files (Python, Makefile) are still matchable strictly when the
    /// model emits tabs correctly.
    static func normalizeForFuzzyMatch(_ text: String) -> (String, [String.Index]) {
        var out = String()
        out.reserveCapacity(text.count)
        var map: [String.Index] = []
        map.reserveCapacity(text.count)

        // First pass: substitute characters one-by-one, tracking trailing
        // whitespace per line and inline-space collapsing.
        // We process character-by-character, peeking at the next non-space
        // to decide whether trailing spaces should be dropped.
        let chars = Array(text)
        let indices = Array(text.indices)
        var i = 0
        var atLineStart = true   // true until first non-whitespace on the line
        while i < chars.count {
            let ch = chars[i]
            // Newline always emitted (with original mapping). Resets
            // atLineStart for the next line.
            if ch == "\n" {
                out.append(ch); map.append(indices[i])
                atLineStart = true
                i += 1
                continue
            }
            // Substitute smart quotes.
            var emit: Character = ch
            switch ch {
            case "\u{201C}", "\u{201D}": emit = "\""
            case "\u{2018}", "\u{2019}": emit = "'"
            default: break
            }
            // Trailing whitespace drop: if this is an ASCII space and
            // every remaining char before the next '\n' (or end) is also
            // a space, drop the run.
            if ch == " " {
                // Look ahead to next non-space
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                let isTrailing = (j == chars.count) || (chars[j] == "\n")
                if isTrailing {
                    // Skip this whole trailing whitespace run.
                    i = j
                    continue
                }
                // Inline space — collapse runs to a single space UNLESS
                // we're at the start of a line (preserve indentation).
                if atLineStart {
                    // Leading indent: emit every space verbatim.
                    for k in i..<j {
                        out.append(" "); map.append(indices[k])
                    }
                    i = j
                    atLineStart = false
                    continue
                }
                // Inline collapse: emit one space mapped to the first
                // space's index.
                out.append(" "); map.append(indices[i])
                i = j
                continue
            }
            out.append(emit); map.append(indices[i])
            atLineStart = false
            i += 1
        }
        return (out, map)
    }

    /// Build a context-rich preview for file_edit miss. We try to locate
    /// the most likely region using a heuristic: search the first 60 chars
    /// of the (normalized) old_string against the (normalized) file. If
    /// found, return ±10 lines of context around that hit. Otherwise fall
    /// back to the original first-20-lines preview so the AI at least sees
    /// the file head.
    static func buildFileEditPreview(
        fileContent: String,
        oldString: String,
        normFile: String,
        normOld: String
    ) -> String {
        // Use first ~60 chars of normalized old as anchor; many failed
        // matches differ later in the string but the start lines up.
        let probeLen = min(60, normOld.count)
        let probeEnd = normOld.index(normOld.startIndex, offsetBy: probeLen)
        let probe = String(normOld[..<probeEnd])
        var anchorLine: Int? = nil
        if !probe.isEmpty, let r = normFile.range(of: probe) {
            // Walk normFile up to the match, counting newlines; this is the
            // same line index in the original file because normalization
            // never adds or removes \n.
            let prefix = normFile[normFile.startIndex..<r.lowerBound]
            anchorLine = prefix.filter { $0 == "\n" }.count
        }
        let lines = fileContent.components(separatedBy: "\n")
        if let a = anchorLine {
            let start = max(0, a - 10)
            let end = min(lines.count, a + 11)
            var out = "Closest match in file (lines \(start + 1)–\(end), normalized old_string anchor at line \(a + 1)):\n"
            out += lines[start..<end].enumerated()
                .map { "\(start + $0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            out += "\n\nNote: file may use smart quotes (\u{201C}\u{201D}\u{2018}\u{2019}), tabs, or trailing whitespace your old_string omits. Re-read the file and copy the exact bytes."
            return out
        }
        let preview = lines.prefix(20).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return "First 20 lines:\n\(preview)"
    }
}
