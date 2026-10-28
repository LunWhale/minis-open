import Foundation

final class LoggingManager: ObservableObject {
    static let shared = LoggingManager()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "loggingEnabled")
            if isEnabled {
                startCapture()
            } else {
                stopCapture()
            }
        }
    }

    let logDirectory: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = lib.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Original file descriptors
    private var origStdout: Int32 = -1
    private var origStderr: Int32 = -1

    // Pipe for capturing
    private var pipeFds: [Int32] = [-1, -1] // [read, write]
    private var readerThread: Thread?
    private var logFileHandle: FileHandle?
    private var currentLogDate: String = ""

    // Writer queue: reader thread hands raw chunks off here so it can return
    // to `read()` as fast as possible. If file I/O on this queue ever blocks
    // (slow disk, fsync stall, FileHandle re-open), the pipe buffer absorbs
    // the backlog instead of stalling whichever thread called NSLog/print.
    // Without this queue, a slow writer back-pressures every logger on the
    // main thread (root cause of the writev hang in v1.4.0-dev).
    private let writerQueue = DispatchQueue(label: "LoggingManager.writer", qos: .utility)
    private var writeCount = 0

    // [T-logging-writer-alloc-abort] Backpressure for the writer queue. The
    // reader thread hands every 4KB pipe chunk to `writerQueue.async` with no
    // bound. Under a burst of concurrent iSH shell commands flooding stdout/
    // stderr (e.g. several `firecrawl scrape` running at once), the reader can
    // enqueue chunks far faster than the writer drains them to disk. Each queued
    // closure retains a `Data`; an unbounded backlog becomes a growing pile of
    // allocations on top of the iSH emulator's already heavy VM address-space
    // reservations (multi-GB Gigacage + per-thread VM_ALLOCATE regions). When a
    // Swift object allocation on the writer queue then returns NULL, the runtime
    // calls `swift_abortAllocationFailure` → SIGABRT (observed 2026-07-11 on the
    // `LoggingManager.writer` queue mid shell-flood). We cap the in-flight queued
    // bytes: past the cap, drop the chunk and count it, logging a single summary
    // line once we recover. `pendingBytes` is only touched under `pendingLock`.
    private var pendingBytes = 0
    private var droppedChunks = 0
    private var droppedBytes = 0
    private let pendingLock = NSLock()
    /// Max bytes allowed to sit queued-but-not-yet-written before we start
    /// dropping incoming chunks. 8 MB is far more than the writer needs under
    /// normal load, but bounds the worst case during a shell-output flood.
    private static let maxPendingBytes = 8 * 1024 * 1024

    // Date formatter for log file names
    private let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // Time formatter for log line timestamps
    private let timeDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// [T-ios-log-verbose-tier] The recorded detail level.
    ///
    /// Lives here rather than only on `AppLogger` because two things have to
    /// move together: the Swift-side threshold, and the iSH kernel's C traces,
    /// which write to stderr and are captured into the same file by the dup2
    /// in `startCapture()`. A level switch that moved only one of them would
    /// leave the biggest single contributor (183 MB/day of per-entry readdir
    /// traces) untouched.
    @Published var level: AppLogger.Level {
        didSet {
            AppLogger.level = level
            Self.applyKernelVerbose(level)
        }
    }

    /// Mirror the level into the iSH kernel's trace gate.
    private static func applyKernelVerbose(_ level: AppLogger.Level) {
        ish_set_verbose_trace(level <= .verbose)
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "loggingEnabled")
        level = AppLogger.level
        // The kernel flag defaults to false, so it only needs pushing when the
        // stored level is verbose — but set it unconditionally so the two can
        // never drift after a restart.
        Self.applyKernelVerbose(AppLogger.level)
    }

    /// Called at app launch to restore capture if previously enabled.
    ///
    /// [T-log-prune-at-launch] Also runs the 15-day prune unconditionally.
    /// The prune used to live only in `rotateLogFileIfNeeded()`, which runs
    /// only while capture is ON, and capture defaults to OFF. So with logging
    /// off, old daily logs were never deleted, and crash reports (which
    /// CrashReporter writes whether or not logging is on) were only capped
    /// by count (20), never by age.
    func startIfEnabled() {
        let dir = logDirectory
        DispatchQueue.global(qos: .utility).async {
            Self.pruneOldLogs(in: dir)
        }
        if isEnabled {
            startCapture()
        }
    }

    // MARK: - Capture

    private func startCapture() {
        guard origStdout == -1 else { return } // Already capturing

        // Save original fds
        origStdout = dup(STDOUT_FILENO)
        origStderr = dup(STDERR_FILENO)
        // [T-log-tee-nonblocking] The writer tees every chunk back to the
        // original stdout. When that is a console someone stopped reading
        // (Xcode / `devicectl --console` over a Wi-Fi link that went away when
        // the phone locked), a blocking write() there never returns: the
        // writer queue stalls, the reader drops every later chunk, and the
        // log file silently stops growing for the rest of the run (field:
        // 2026-10-02 19:10 on an iPhone 17 Pro). Non-blocking, a full
        // console just loses its copy; the file keeps everything.
        Self.setNonBlocking(origStdout, true)
        Self.setNonBlocking(origStderr, true)

        // Create pipe
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            origStdout = -1
            origStderr = -1
            return
        }
        pipeFds = fds

        // Redirect stdout and stderr to pipe write end
        dup2(pipeFds[1], STDOUT_FILENO)
        dup2(pipeFds[1], STDERR_FILENO)
        // Close the extra write fd — stdout/stderr now own it
        close(pipeFds[1])
        pipeFds[1] = -1

        // Open (or rotate to) today's log file
        rotateLogFileIfNeeded()

        // Start reader thread
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "LoggingManager.reader"
        thread.qualityOfService = .utility
        readerThread = thread
        thread.start()
    }

    private func stopCapture() {
        guard origStdout != -1 else { return }

        // [T-log-tee-nonblocking] Back to blocking before stdout/stderr own them again.
        Self.setNonBlocking(origStdout, false)
        Self.setNonBlocking(origStderr, false)
        // Restore original fds
        dup2(origStdout, STDOUT_FILENO)
        dup2(origStderr, STDERR_FILENO)
        close(origStdout)
        close(origStderr)
        origStdout = -1
        origStderr = -1

        // Close pipe read end — this will cause the reader thread to exit
        if pipeFds[0] != -1 {
            close(pipeFds[0])
            pipeFds[0] = -1
        }

        readerThread?.cancel()
        readerThread = nil

        // Drain any in-flight writes before closing the file handle.
        writerQueue.sync {
            self.logFileHandle?.closeFile()
            self.logFileHandle = nil
        }

        // [T-logging-writer-alloc-abort] Reset backpressure accounting so a later
        // startCapture() begins with an empty in-flight budget.
        pendingLock.lock()
        pendingBytes = 0
        droppedChunks = 0
        droppedBytes = 0
        pendingLock.unlock()
    }

    private func readLoop() {
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while !Thread.current.isCancelled {
            let bytesRead = read(pipeFds[0], buffer, bufferSize)
            if bytesRead <= 0 { break }

            let chunk = Data(bytes: buffer, count: bytesRead)
            let capturedAt = Date()
            let teeFd = origStdout

            // [T-logging-writer-alloc-abort] Backpressure: if the writer queue is
            // already saturated (a shell-output flood the disk can't keep up
            // with), drop this chunk instead of piling another retained `Data`
            // onto an unbounded backlog. Dropping log bytes is strictly better
            // than aborting the whole app on an allocation failure. The tee to
            // the original stdout (console) still happens so nothing is lost
            // there; only the on-disk daily log skips the dropped chunk.
            pendingLock.lock()
            if pendingBytes + bytesRead > Self.maxPendingBytes {
                droppedChunks += 1
                droppedBytes += bytesRead
                pendingLock.unlock()
                // Still tee to console so interactive output is preserved.
                if teeFd != -1 {
                    chunk.withUnsafeBytes { ptr in
                        if let base = ptr.baseAddress { _ = Darwin.write(teeFd, base, bytesRead) }
                    }
                }
                continue
            }
            pendingBytes += bytesRead
            pendingLock.unlock()

            // Hand the chunk to the writer queue and immediately loop back
            // to `read()`. All file I/O happens off this thread so a slow
            // disk can't back-pressure the pipe.
            writerQueue.async { [weak self] in
                self?.processChunk(chunk, capturedAt: capturedAt, teeFd: teeFd)
            }
        }
    }

    /// Runs on `writerQueue`. Owns all file-handle state and persistence.
    private func processChunk(_ data: Data, capturedAt: Date, teeFd: Int32) {
        // [T-logging-writer-alloc-abort] This chunk is no longer "in flight"
        // regardless of how it's handled below — release its reservation so the
        // reader can enqueue more. Deferred so every exit path accounts for it.
        defer {
            pendingLock.lock()
            pendingBytes = max(0, pendingBytes - data.count)
            pendingLock.unlock()
        }

        // Tee back to the saved stdout so console output is preserved.
        if teeFd != -1 {
            data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    _ = Darwin.write(teeFd, base, data.count)
                }
            }
        }

        // Check for date rollover
        rotateLogFileIfNeeded()

        // Surface a one-line summary of any chunks dropped while the writer was
        // saturated, now that we've caught up. Composed here (on writerQueue) so
        // it lands in-order in the same file.
        flushDroppedSummaryIfNeeded()

        // Add a timestamp prefix to each line and write to the log file. Compose
        // the whole chunk into ONE buffer and issue a SINGLE safeWrite, instead
        // of three writeData: calls (prefix / line / newline) PER LINE. Under a
        // shell-output flood the old per-line path was a storm of small Data
        // allocations + syscalls on the writer queue — the allocation pressure
        // that tipped `swift_allocObject` into `swift_abortAllocationFailure`.
        // safeWrite still wraps writeData: in ObjC @try/@catch so a closed pipe /
        // invalidated fd can't raise an NSException Swift can't catch.
        if let text = String(data: data, encoding: .utf8) {
            let timestamp = timeDateFormatter.string(from: capturedAt)
            let prefixBytes = Array("[\(timestamp)] ".utf8)
            var out = Data()
            out.reserveCapacity(data.count + prefixBytes.count * 4 + 16)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .dropLast(text.hasSuffix("\n") ? 1 : 0)
            for line in lines {
                out.append(contentsOf: prefixBytes)
                out.append(contentsOf: line.utf8)
                out.append(0x0A) // "\n"
            }
            if !out.isEmpty { _ = safeWrite(out) }
        } else {
            // Binary data — write raw
            _ = safeWrite(data)
        }

        // Periodically check file size (~every 4 MB of writes)
        writeCount += 1
        if writeCount % 1000 == 0 {
            truncateIfNeeded()
        }
    }

    /// [T-logging-writer-alloc-abort] If chunks were dropped during a writer
    /// saturation burst, emit a single accounting line once the queue drains and
    /// reset the counters. Runs on `writerQueue`.
    private func flushDroppedSummaryIfNeeded() {
        pendingLock.lock()
        let chunks = droppedChunks
        let bytes = droppedBytes
        if chunks > 0 {
            droppedChunks = 0
            droppedBytes = 0
        }
        pendingLock.unlock()
        guard chunks > 0 else { return }
        let ts = timeDateFormatter.string(from: Date())
        let note = "[\(ts)] [LoggingManager] dropped \(chunks) log chunk(s) (\(bytes) bytes) under writer backpressure\n"
        _ = safeWrite(Data(note.utf8))
    }

    /// Write `data` to the current log file handle, catching any ObjC
    /// NSException. Returns `false` on failure so the caller can stop
    /// trying to write to a broken handle. On first failure the handle is
    /// dropped so we don't thrash the same bad fd.
    @discardableResult
    private func safeWrite(_ data: Data) -> Bool {
        guard let handle = logFileHandle else { return false }
        var reason: NSString?
        let ok = MinisFileHandleSafeWrite(handle, data, &reason)
        if !ok {
            // Drop the handle — next rotateLogFileIfNeeded() will recreate
            // it against a fresh fd (or the next calendar-day rollover).
            logFileHandle = nil
            // Force next rotate call to re-open, even on the same day.
            currentLogDate = ""
            if let reason {
                // Use fputs directly — we're already in the capture path,
                // NSLog/print here would reenter the pipe.
                let msg = "[LoggingManager] writeData failed: \(reason as String)\n"
                msg.withCString { cstr in
                    if origStderr != -1 { _ = Darwin.write(origStderr, cstr, strlen(cstr)) }
                }
            }
        }
        return ok
    }

    /// Maximum size per log file (500 MB). Once exceeded the file is truncated
    /// to its last `maxLogFileSize/2` bytes to avoid unbounded disk growth.
    /// [T-log-cap-500mb] Raised from 100 MB so a heavy day (Verbose, shell
    /// floods) keeps more history; truncation streams, so the size of the
    /// kept half no longer matters for memory.
    private let maxLogFileSize: UInt64 = 500 * 1024 * 1024

    /// [T-log-tee-nonblocking] Last failed open of the day's log file; a
    /// failed open is retried at most this often instead of never.
    private var lastOpenFailure: Date?
    private static let reopenRetryInterval: TimeInterval = 5

    private static func setNonBlocking(_ fd: Int32, _ on: Bool) {
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK))
    }

    private func rotateLogFileIfNeeded() {
        let today = fileDateFormatter.string(from: Date())
        // [T-log-tee-nonblocking] Also re-open when the handle is gone (a
        // failed write drops it, see safeWrite). Before, the date was marked
        // current even when the open failed, so one failure left every later
        // chunk with no handle - dropped without a trace - until midnight.
        guard today != currentLogDate || logFileHandle == nil else { return }
        let dayChanged = today != currentLogDate
        if !dayChanged, let last = lastOpenFailure,
           Date().timeIntervalSince(last) < Self.reopenRetryInterval { return }

        logFileHandle?.closeFile()

        let fileURL = logDirectory.appendingPathComponent("minis-\(today).log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        logFileHandle = try? FileHandle(forWritingTo: fileURL)
        logFileHandle?.seekToEndOfFile()
        currentLogDate = today
        if logFileHandle == nil {
            lastOpenFailure = Date()
            // Not NSLog: that would re-enter the pipe this writer drains.
            let msg = "[LoggingManager] cannot open \(fileURL.lastPathComponent); retrying in \(Int(Self.reopenRetryInterval))s\n"
            msg.withCString { cstr in
                if origStderr != -1 { _ = Darwin.write(origStderr, cstr, strlen(cstr)) }
            }
            return
        }
        lastOpenFailure = nil
        guard dayChanged else { return }

        // [T-log-auto-prune] Every rotation (first write of a launch + each
        // calendar-day rollover) prunes logs older than the retention window.
        // Runs detached on a utility queue: rotate is on the log-capture path
        // and must stay cheap (see 97197a72 backpressure history).
        let dir = logDirectory
        DispatchQueue.global(qos: .utility).async {
            Self.pruneOldLogs(in: dir)
        }
    }

    /// [T-log-auto-prune] Days of log history to keep. Files whose modification
    /// date is older than this are deleted whenever a NEW daily log file is
    /// created (calendar-day rollover / first launch of a new day) — covers
    /// running logs, crash logs, and anything else `.log` in the directory.
    private static let logRetentionDays = 15

    /// The log's OWN date: parsed from the filename when it matches a known
    /// pattern (`minis-YYYY-MM-DD.log`, `crash-YYYYMMDD-HHmmss.log`) — the
    /// filename day is the log's true content day, immune to mtime drift from
    /// backups/copies — falling back to the modification date otherwise.
    private static func logDate(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        if name.hasPrefix("minis-") {
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: String(name.dropFirst("minis-".count))) { return d }
        } else if name.hasPrefix("crash-") {
            df.dateFormat = "yyyyMMdd-HHmmss"
            if let d = df.date(from: String(name.dropFirst("crash-".count))) { return d }
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private static func pruneOldLogs(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(logRetentionDays) * 24 * 3600)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        var removed: [String] = []
        // [T-log-prune-at-launch] Never delete a file written in the last day,
        // whatever date its name carries: now that the prune runs at launch,
        // the crash report for a crash that happened >15 days ago (app not
        // opened since) is written moments before this runs, and would
        // otherwise be deleted before the user can see it.
        let recentWrite = Date().addingTimeInterval(-24 * 3600)
        for url in files where url.pathExtension == "log" {
            // Unknown date (unparseable name AND unreadable attrs) → keep.
            let date = logDate(of: url) ?? .distantFuture
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantFuture
            if date < cutoff && modified < recentWrite {
                do {
                    try fm.removeItem(at: url)
                    removed.append(url.lastPathComponent)
                } catch {
                    NSLog("[LoggingManager] prune failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        if !removed.isEmpty {
            NSLog("[LoggingManager] pruned \(removed.count) log file(s) older than \(logRetentionDays)d: \(removed.joined(separator: ","))")
        }
    }

    /// Truncates the current log file to its newest `maxLogFileSize/2` bytes
    /// once it exceeds `maxLogFileSize`. Runs on `writerQueue`.
    ///
    /// [T-log-cap-500mb] Streams the kept tail through a temp file in 4 MB
    /// chunks. The previous version read the whole kept half into one `Data`
    /// (`readToEnd()`): 50 MB at the old 100 MB cap, 250 MB at 500 MB — a
    /// single allocation on the logging path, which already aborted once under
    /// memory pressure (T-logging-writer-alloc-abort). Every step is guarded so
    /// a failure (full disk, closed handle) can't escape the reader thread; on
    /// failure the file is left as it was and logging resumes into it.
    private func truncateIfNeeded() {
        guard let handle = logFileHandle else { return }
        let size = handle.offsetInFile
        guard size > maxLogFileSize, !currentLogDate.isEmpty else { return }

        let keepBytes = maxLogFileSize / 2
        let fm = FileManager.default
        let fileURL = logDirectory.appendingPathComponent("minis-\(currentLogDate).log")
        let tmpURL = fileURL.appendingPathExtension("truncating")

        // Close first; rotateLogFileIfNeeded() reopens (and seeks to the end)
        // on the next write because currentLogDate is cleared.
        try? handle.close()
        logFileHandle = nil
        currentLogDate = ""

        do {
            try? fm.removeItem(at: tmpURL)
            let marker = "[log truncated: kept the newest \(keepBytes / 1024 / 1024) MB]\n"
            guard fm.createFile(atPath: tmpURL.path, contents: Data(marker.utf8)) else { return }
            let reader = try FileHandle(forReadingFrom: fileURL)
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: tmpURL)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try reader.seek(toOffset: size - keepBytes)
            var copying = true
            while copying {
                try autoreleasepool {
                    guard let chunk = try reader.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else {
                        copying = false
                        return
                    }
                    try writer.write(contentsOf: chunk)
                }
            }
            try writer.close()
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            try? fm.removeItem(at: tmpURL)
        }
    }

    // MARK: - Log File Management

    /// Lists all `.log` files in the Logs directory, tagging each with a `type`:
    /// `"running"` for `minis-*.log`, `"crash"` for `crash-*.log` (written by
    /// CrashReporter into the same directory), `"other"` for anything else.
    func logFiles() -> [(name: String, url: URL, date: Date, size: Int64, type: String)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "log" }
            .compactMap { url -> (String, URL, Date, Int64, String)? in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(values?.fileSize ?? 0)
                let date = values?.contentModificationDate ?? Date.distantPast
                let name = url.lastPathComponent
                let type: String
                if name.hasPrefix("minis-") {
                    type = "running"
                } else if name.hasPrefix("crash-") {
                    type = "crash"
                } else {
                    type = "other"
                }
                return (name, url, date, size, type)
            }
            .sorted { $0.2 > $1.2 } // newest first
    }

    /// Reads a log file. For files larger than `maxBytes` only the last `maxBytes` are returned
    /// to avoid out-of-memory crashes on very large logs.
    func readLog(at url: URL, maxBytes: Int = 2 * 1024 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize > maxBytes {
            handle.seek(toFileOffset: fileSize - UInt64(maxBytes))
            guard let data = try? handle.readToEnd() else { return "" }
            let text = String(data: data, encoding: .utf8) ?? ""
            // Drop the first (likely partial) line
            if let firstNewline = text.firstIndex(of: "\n") {
                return "… (\(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)) total, showing last \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)))\n" + text[text.index(after: firstNewline)...]
            }
            return text
        } else {
            handle.seek(toFileOffset: 0)
            guard let data = try? handle.readToEnd() else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    func deleteLog(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        // [T-logging-zombie-fd-ios] removeItem only unlinks the file on disk;
        // the open fd in logFileHandle stays valid, so subsequent writes
        // succeed silently into the now-deleted "zombie" file (invisible on
        // disk) until a capture toggle rebuilds the handle. If we just deleted
        // today's active log, close + nil the handle and clear currentLogDate
        // so rotateLogFileIfNeeded recreates the file + handle on the next write.
        writerQueue.async { [weak self] in
            guard let self else { return }
            let today = self.fileDateFormatter.string(from: Date())
            if url.lastPathComponent == "minis-\(today).log" {
                self.logFileHandle?.closeFile()
                self.logFileHandle = nil
                self.currentLogDate = ""
            }
        }
    }

    func deleteAllLogs() {
        for file in logFiles() {
            try? FileManager.default.removeItem(at: file.url)
        }
        // [T-logging-zombie-fd-ios] As in deleteLog, drop the stale handle to
        // today's now-deleted log so the next write reopens a fresh file via
        // rotateLogFileIfNeeded (gated on currentLogDate == "").
        writerQueue.async { [weak self] in
            self?.logFileHandle?.closeFile()
            self?.logFileHandle = nil
            self?.currentLogDate = ""
        }
    }

    func totalLogSize() -> Int64 {
        logFiles().reduce(0) { $0 + $1.size }
    }

    // TEMP(2026-05-13): direct-write path that bypasses NSLog → stderr pipe →
    // readLoop entirely. Used by HangDetector dumps and streaming-flush
    // landings so a watchdog SIGKILL can't strand bytes in the kernel pipe
    // buffer. Format matches what `processChunk` would have produced.
    // Remove once we are confident hang dumps reliably land on disk via the
    // normal NSLog path.
    func writeRawLine(category: String, level: String = "INFO", message: String) {
        guard isEnabled else { return }
        // Compose the line up-front on the caller's thread so the writerQueue
        // only ever does I/O. Mirrors AppLogger's "[<category>] [<level>] <msg>"
        // shape so `processChunk` formatting matches.
        let timestamp = timeDateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(category)] [\(level)] \(message)\n"
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.rotateLogFileIfNeeded()
            _ = self.safeWrite(Data(line.utf8))
        }
    }

    // TEMP(2026-05-13): force the in-flight file-handle chain to land on
    // disk. Added to confirm whether HangDetector dumps actually reach the
    // daily log before a watchdog SIGKILL. Remove once we have data.
    //
    // `flush()` is best-effort, non-blocking from the caller side:
    //   - Hop onto writerQueue with `.async` so callers (incl. main thread
    //     hot paths) never wait on disk I/O.
    //   - Inside writerQueue, fsync the underlying fd so APFS commits.
    // Use `flushSync()` only when you must guarantee that bytes are durable
    // before returning (e.g. about to crash on purpose). For SIGKILL races
    // we don't bother — the data will land "soon", and that's the best we
    // can do without blocking the producer.
    func flush() {
        guard isEnabled else { return }
        writerQueue.async { [weak self] in
            self?.performFsyncLocked()
        }
    }

    func flushSync() {
        guard isEnabled else { return }
        writerQueue.sync { [weak self] in
            self?.performFsyncLocked()
        }
    }

    private func performFsyncLocked() {
        guard let handle = logFileHandle else { return }
        do {
            try handle.synchronize()
        } catch {
            logFileHandle = nil
            currentLogDate = ""
        }
    }
}
