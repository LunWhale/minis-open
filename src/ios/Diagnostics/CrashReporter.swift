import Foundation
import MachO
import MetricKit
import UIKit
import os

private let logger = AppLogger(category: "CrashReporter")

final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    private let maxReports = 20

    private var crashReportsDir: URL {
        // Keep crash reports alongside running logs (LoggingManager.logDirectory)
        // so the unified Logs UI can list both from one directory.
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("Logs", isDirectory: true)
    }

    private var launchMarkerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("launch_marker")
    }

    static var hangSnapshotURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_hang_snapshot.txt")
    }

    static var crashStackURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_crash_stack.txt")
    }

    // MARK: - Tool-execution breadcrumb (durable, DEBUG-only)

#if DEBUG
    /// Runtime switch for the breadcrumb, toggleable over the debug server
    /// (`debug.toolExec.setEnabled`) so a device can be flipped mid-investigation
    /// without a rebuild.
    ///
    /// Defaults to ON: the write is two lines per `shell_execute` and this is a
    /// DEBUG-only build to begin with, so the diagnostic value outweighs the
    /// cost — and a breadcrumb that is off by default is useless for the crash
    /// it is meant to catch (the first occurrence would be missed).
    ///
    /// Persisted to UserDefaults. The reason to persist rather than keep it
    /// process-local: the thing being diagnosed KILLS THE PROCESS. A
    /// memory-only switch would reset to its default on every Jetsam/SIGKILL
    /// relaunch, so an investigator who turned it OFF would silently get it
    /// back on at the worst moment, and one who needs it across a crash-restart
    /// cycle could not rely on it. Surviving the restart is the point.
    static var toolBreadcrumbEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: toolBreadcrumbDefaultsKey) == nil { return true }
            return d.bool(forKey: toolBreadcrumbDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: toolBreadcrumbDefaultsKey) }
    }
    private static let toolBreadcrumbDefaultsKey = "debug.toolExec.breadcrumbEnabled"

    /// Rolling record of the tool invocations that were STARTED, written with
    /// `O_SYNC` so each line is on disk before the call returns.
    ///
    /// [T-tool-exec-breadcrumb] Both 2026-07-28 crash families (09:12 SIGKILL,
    /// 10:28 Jetsam + Signal 9) happened during dense `shell_execute` activity,
    /// but the log could only show `[ToolLifecycle] COMPLETED … duration=Xs` —
    /// emitted AFTER a tool finishes. A tool that never finished because the
    /// process was killed mid-execution left no trace at all, so "which command
    /// was running when we died?" was unanswerable.
    ///
    /// Why not the normal logger: `AppLogger` → `NSLog` → stderr pipe →
    /// `LoggingManager`'s reader thread → `writerQueue.async`. That path is
    /// asynchronous, and under exactly the condition we care about — a shell
    /// flood — `LoggingManager` applies backpressure and DROPS chunks
    /// (T-logging-writer-alloc-abort). The breadcrumb would be least reliable
    /// precisely when it matters most. `flushSync()` would fsync the file but
    /// cannot pull a line that is still sitting in the pipe. So this line
    /// bypasses that pipeline and goes straight to its own fd.
    static var toolBreadcrumbURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_tool_exec.txt")
    }

    /// Cap so a long-running session can't grow this file without bound. Small
    /// on purpose: only the tail matters after a kill.
    private static let toolBreadcrumbMaxBytes: off_t = 256 * 1024

    private static let breadcrumbLock = NSLock()

    /// Append one breadcrumb line, synchronously durable on return.
    ///
    /// Uses `O_SYNC` rather than write-then-fsync so the commit happens inside
    /// the same syscall — there is no window where the line is written but not
    /// yet durable. Deliberately does NOT go through `AppLogger`; see the note
    /// on `toolBreadcrumbURL`.
    static func writeToolBreadcrumb(_ line: String) {
        // Checked first: when off this is a single UserDefaults read and no
        // file I/O at all.
        guard toolBreadcrumbEnabled else { return }
        let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        guard let bytes = stamped.data(using: .utf8) else { return }
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }

        let path = toolBreadcrumbURL.path
        // O_APPEND keeps concurrent tool tasks from interleaving mid-line;
        // O_SYNC makes the write durable before it returns.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_SYNC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Truncate-and-restart when the cap is hit. Cheaper and more predictable
        // than rewriting a ring, and losing older breadcrumbs is acceptable —
        // only the last line before a kill is load-bearing.
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64,
           size > toolBreadcrumbMaxBytes {
            ftruncate(fd, 0)
        }
        _ = bytes.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }
    }

    /// Current breadcrumb state for `debug.toolExec.getStatus`: whether the
    /// switch is on, plus the file's path/size so a caller can decide whether a
    /// `debug.readFile` is worth issuing.
    static func toolBreadcrumbStatus() -> [String: Any] {
        let path = toolBreadcrumbURL.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let modified = (attrs?[.modificationDate] as? Date).map {
            ISO8601DateFormatter().string(from: $0)
        }
        return [
            "enabled": toolBreadcrumbEnabled,
            "path": path,
            "exists": FileManager.default.fileExists(atPath: path),
            "size": size,
            "maxBytes": Int(toolBreadcrumbMaxBytes),
            "modified": modified ?? NSNull(),
        ]
    }
#endif

    private var launched = false

    // MARK: - Run identity + heartbeat [T-crash-heartbeat]

    /// Identifies THIS process's launch marker. The relaunched process used to
    /// rewrite the dead run's marker (scenePhase → inactive fires before
    /// `onAppLaunch` classifies it), so every SIGKILL report showed the new
    /// process: "inactive since <relaunch time>", 16 MB, 0 sessions - and a
    /// background CPU kill was filed as a FOREGROUND CRASH. Marker writes
    /// after launch are now only made to a marker carrying this id.
    let runId = UUID().uuidString

    static let heartbeatInterval: TimeInterval = 10
    private let heartbeatQueue = DispatchQueue(label: "com.minis.crashHeartbeat", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    /// heartbeatQueue only.
    private var lastHeartbeatCPU: (cpuSeconds: Double, at: Date)?

    static var heartbeatURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("last_heartbeat.json")
    }

    // MARK: - Log Ring Buffer

    private var logRing: [String] = []
    private let logRingCapacity = 20
    private var logRingLock = os_unfair_lock()

    func appendLog(_ line: String) {
        os_unfair_lock_lock(&logRingLock)
        if logRing.count >= logRingCapacity {
            logRing.removeFirst()
        }
        logRing.append(line)
        os_unfair_lock_unlock(&logRingLock)
    }

    func logRingSnapshot() -> [String] {
        os_unfair_lock_lock(&logRingLock)
        let snapshot = logRing
        os_unfair_lock_unlock(&logRingLock)
        return snapshot
    }

    // MARK: - Last API Tracking

    private var lastAPILock = os_unfair_lock()
    private var _lastAPIProvider: String?
    private var _lastAPIModel: String?

    func setLastAPI(provider: String, model: String) {
        os_unfair_lock_lock(&lastAPILock)
        _lastAPIProvider = provider
        _lastAPIModel = model
        os_unfair_lock_unlock(&lastAPILock)
    }

    private func lastAPI() -> (provider: String?, model: String?) {
        os_unfair_lock_lock(&lastAPILock)
        let p = _lastAPIProvider
        let m = _lastAPIModel
        os_unfair_lock_unlock(&lastAPILock)
        return (p, m)
    }

    private override init() {
        super.init()
    }

    // MARK: - Crash-loop protection [T-ios-session-crash-loop]

    /// A session that faults while loading kills the app, and the app then
    /// re-opens that same session on the next launch — an unrecoverable loop the
    /// user cannot escape from inside the app (they cannot reach Settings to
    /// change the launch screen, or the session list to delete the bad session).
    ///
    /// `checkStaleMarker()` already classifies "the previous run died in the
    /// foreground"; this turns that existing signal into an actual behaviour
    /// change instead of only writing it into a report file.
    private static let crashLoopLastCrashAtKey = "crashLoop_lastCrashAt"
    private static let crashLoopTriggeredKey = "crashLoop_triggered"

    /// Two foreground crashes inside this window count as a loop rather than two
    /// unrelated incidents. Short on purpose: a genuine restore loop crashes
    /// again within seconds of relaunching, whereas two crashes minutes apart
    /// are far more likely to be independent and should not cost the user their
    /// preferred launch screen.
    private static let crashLoopWindowSeconds: TimeInterval = 60

    /// True when the previous two launches both died in the foreground within
    /// `crashLoopWindowSeconds`. The launch path reads this to skip restoring
    /// the last session and fall back to the session list.
    ///
    /// Self-evaluating: `onAppLaunch()` runs from a `scenePhase → .active`
    /// observer, which is NOT guaranteed to fire before `ContentView.task`
    /// reads this on a cold launch. Rather than depend on that ordering (a
    /// stale read would silently disable the whole protection), force the
    /// stale-marker evaluation here if it has not happened yet. Both paths are
    /// idempotent — `checkStaleMarker()` is guarded by `launched`/`evaluated`
    /// so whichever runs second is a no-op.
    var shouldBypassSessionRestore: Bool {
        evaluateCrashLoopIfNeeded()
        return UserDefaults.standard.bool(forKey: Self.crashLoopTriggeredKey)
    }

    /// Guard so the stale-marker → crash-loop evaluation happens exactly once
    /// per process, whichever caller gets there first.
    private var crashLoopEvaluated = false

    /// Run the previous-run classification and update the crash-loop counter.
    /// Safe to call repeatedly and from either the launch path or the first
    /// `shouldBypassSessionRestore` read.
    private func evaluateCrashLoopIfNeeded() {
        guard !crashLoopEvaluated else { return }
        crashLoopEvaluated = true
        let hadStaleMarker = checkStaleMarker()
        if !hadStaleMarker || !lastRunWasForegroundCrash {
            resetCrashLoopState()
        }
    }

    /// Clear the bypass flag once it has been acted on, so the NEXT launch
    /// behaves normally. Deliberately does not clear the timestamp: if that
    /// launch also dies in the foreground within the window we want to trip the
    /// bypass again rather than restore the bad session a second time.
    func clearCrashLoopFlag() {
        UserDefaults.standard.removeObject(forKey: Self.crashLoopTriggeredKey)
        logger.info("[CrashLoop] bypass flag consumed and cleared")
    }

    /// Record that the previous run ended in a foreground crash, and decide
    /// whether that makes a loop. Called from `checkStaleMarker()`, which is the
    /// one place that already knows the previous run's last phase.
    private func noteForegroundCrash() {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let previous = defaults.double(forKey: Self.crashLoopLastCrashAtKey)
        // `double(forKey:)` returns 0 for an absent key — treat that as "no
        // prior crash recorded" rather than as the Unix epoch.
        let gap = previous > 0 ? now - previous : .infinity
        if gap < Self.crashLoopWindowSeconds {
            defaults.set(true, forKey: Self.crashLoopTriggeredKey)
            logger.warning("[CrashLoop] second foreground crash in \(String(format: "%.1f", gap))s — next launch will skip session restore")
        } else {
            defaults.removeObject(forKey: Self.crashLoopTriggeredKey)
            logger.info("[CrashLoop] foreground crash recorded (gap=\(previous > 0 ? String(format: "%.1fs", gap) : "first"))")
        }
        defaults.set(now, forKey: Self.crashLoopLastCrashAtKey)
    }

    /// Forget the crash history after a launch that did NOT follow a foreground
    /// crash — i.e. the app is healthy again, so an old timestamp must not
    /// combine with some future crash to look like a loop.
    private func resetCrashLoopState() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.crashLoopLastCrashAtKey) != nil
            || defaults.object(forKey: Self.crashLoopTriggeredKey) != nil else { return }
        defaults.removeObject(forKey: Self.crashLoopLastCrashAtKey)
        defaults.removeObject(forKey: Self.crashLoopTriggeredKey)
        logger.info("[CrashLoop] clean launch — crash-loop state reset")
    }

    // MARK: - Public API

    func onAppLaunch() {
        guard !launched else { return }
        launched = true
        CrashSignalHandler.install()
        // [T-ios-session-crash-loop] Classifies the previous run and updates the
        // crash-loop counter. May already have run if the launch path read
        // `shouldBypassSessionRestore` first — it is idempotent either way.
        evaluateCrashLoopIfNeeded()
        try? FileManager.default.removeItem(at: Self.hangSnapshotURL)
        try? FileManager.default.removeItem(at: Self.crashStackURL)
        // [T-crash-signal-refault] Consumed by the report above (if any); a
        // stale one must not attach itself to a later, unrelated report.
        // [T-crash-diag-export] Moved, not deleted: the last 5 stay listed under
        // Settings > Logs > Crash Diagnostics and in its export.
        Self.archivePreviousCrashContext()
        writeLaunchMarker()
        // [T-crash-heartbeat] After the previous run's heartbeat was read by
        // the classification above - the first write replaces it.
        startHeartbeat()
        // [T-crash-injected-dylib-tag] Scan + cache BEFORE registering the
        // MetricKit subscriber: `didReceive` delivers on a background queue
        // and its report writer reads the cache — priming it here (main
        // thread, single writer) keeps the static cache race-free. Also
        // gives one launch log line so injection is visible in the running
        // log, not only in post-mortem reports.
        let foreign = Self.detectInjectedDylibs()
        if !foreign.isEmpty {
            logger.warning("⚠️ Injected tweak/hook dylibs detected in-process: \(foreign.joined(separator: ", "))")
        }
        MXMetricManager.shared.add(self)
        logger.info("CrashReporter initialized, signal handlers + MetricKit subscriber registered")
    }

    /// [T-crash-injected-dylib-tag] Names of loaded images that match known
    /// tweak/hook-framework markers (Substrate, Substitute, ElleKit, libhooker,
    /// TweakInject, …). Detection only — no enforcement, no exit, no UI. The
    /// marker list is matched against the full image path lowercased, so both
    /// runtime-injected (/usr/lib/TweakInject/…) and repackaged-into-bundle
    /// (Minis.app/Frameworks/SomeTweak.dylib via CydiaSubstrate) variants hit.
    /// Cached after the first scan: the loaded-image set relevant to this
    /// check is fixed at process start.
    private static var cachedInjectedDylibs: [String]?
    static func detectInjectedDylibs() -> [String] {
        if let cached = cachedInjectedDylibs { return cached }
        let markers = [
            "cydiasubstrate", "mobilesubstrate", "substrate.dylib",
            "substitute", "ellekit", "libhooker", "tweakinject",
            "librocketbootstrap", "libblackjack", "choicy",
        ]
        var found: [String] = []
        for i in 0..<_dyld_image_count() {
            guard let cPath = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cPath)
            let lower = path.lowercased()
            if markers.contains(where: { lower.contains($0) }) {
                found.append((path as NSString).lastPathComponent)
            }
        }
        // A hook framework rarely rides alone — when one is present, also name
        // its payload: any non-Apple image inside our own Frameworks dir that
        // is not part of the shipped app (heuristic: .dylib files; our own
        // embedded frameworks are .framework bundles).
        if !found.isEmpty {
            let bundleFrameworks = Bundle.main.bundlePath + "/Frameworks/"
            for i in 0..<_dyld_image_count() {
                guard let cPath = _dyld_get_image_name(i) else { continue }
                let path = String(cString: cPath)
                if path.hasPrefix(bundleFrameworks), path.hasSuffix(".dylib") {
                    let name = (path as NSString).lastPathComponent
                    if !found.contains(name) { found.append(name) }
                }
            }
        }
        cachedInjectedDylibs = found
        return found
    }

    func onWillTerminate() {
        removeLaunchMarker()
        try? FileManager.default.removeItem(at: Self.heartbeatURL)
        try? FileManager.default.removeItem(at: Self.hangSnapshotURL)
        try? FileManager.default.removeItem(at: Self.crashStackURL)
        logger.info("Launch marker removed (normal termination)")
    }

    @MainActor
    func updateMarkerPhase(phase: String) {
        // [T-crash-breadcrumbs] Every foreground/background switch lands here
        // (active / inactive / background): one breadcrumb + an extra sample.
        CrashBreadcrumbs.record("life", detail: phase)
        ResourceSampler.shared.sampleNow(reason: phase)
        let url = launchMarkerURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // [T-crash-heartbeat] Not our marker yet: it is the previous run's,
        // still waiting to be classified by onAppLaunch. Leave it alone.
        guard (marker["runId"] as? String) == runId else {
            logger.info("[Heartbeat] phase \(phase) before launch classification - previous run's marker left intact")
            return
        }
        recordHeartbeat(reason: phase)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        marker["lastPhase"] = phase
        marker["lastPhaseAt"] = df.string(from: Date())
        marker["memoryMB"] = currentMemoryMB()
        marker["memoryFreeMB"] = systemFreeMB()
        marker["activeSessionCount"] = SessionActivityTracker.shared.activeSessions.count
        marker["runningShellCommand"] = ShellCommandRingBuffer.hasRunningCommand
        // [T-ios-bgkeepalive-diag] Two DIFFERENT signals, previously
        // conflated into one misleading "BG task active" line:
        //   keepAliveIntent — BackgroundKeepAliveManager.isActive, i.e. "we WANT
        //     to stay alive" (derived from SessionActivityTracker).
        //   liveBackgroundTaskCount — how many real UIBackgroundTaskIdentifier
        //     grants the OS has actually given us.
        // The old field reported the intent flag under a name that reads as the
        // OS grant, so every crash report looked like "background task healthy"
        // regardless of the real grant state.
        marker["bgKeepAliveIntent"] = BackgroundKeepAliveManager.shared.isActive
        marker["bgTaskGrants"] = AIChatViewModel.liveBackgroundTaskCount
        marker["bgSilentAudioLeg"] = BackgroundKeepAliveManager.shared.silentAudioIsPlaying

        let remaining = UIApplication.shared.backgroundTimeRemaining
        marker["bgTaskRemaining"] = remaining > 99999 ? -1 : remaining

        // [T-bg-keepalive-debounce] BackgroundKeepAlive snapshot — so a crash
        // report shows the exact audio keep-alive state at the last phase change.
        let bka = BackgroundKeepAliveManager.shared
        marker["bkaSilentAudioPlaying"] = bka.silentAudioIsPlaying
        marker["bkaAudioSessionActive"] = bka.audioSessionIsActive
        marker["bkaStopDebouncePending"] = bka.stopDebouncePending
        if let evt = bka.lastBKAEvent {
            let at = bka.lastBKAEventAt.map { df.string(from: $0) } ?? "?"
            marker["bkaLastEvent"] = "[\(at)] \(evt)"
        }
        if let lc = bka.lastLifecycle {
            let at = bka.lastLifecycleAt.map { df.string(from: $0) } ?? "?"
            marker["bkaLastLifecycle"] = "[\(at)] \(lc)"
        }
        if bka.lastAudioInterruption != "none" {
            let at = bka.lastAudioInterruptionAt.map { df.string(from: $0) } ?? "?"
            marker["bkaAudioInterruption"] = "\(bka.lastAudioInterruption)(\(at))"
        } else {
            marker["bkaAudioInterruption"] = "none"
        }

        let api = lastAPI()
        if let p = api.provider { marker["lastAPIProvider"] = p }
        if let m = api.model { marker["lastAPIModel"] = m }

        let shellSnap = ShellCommandRingBuffer.syncSnapshot
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        marker["shellCommands"] = shellSnap.map { entry -> [String: Any] in
            var d: [String: Any] = [
                "index": entry.index,
                "startedAt": timeFmt.string(from: entry.startedAt),
                "command": entry.command,
                "sessionId": entry.sessionId
            ]
            if let code = entry.exitCode { d["exitCode"] = code }
            if let dur = entry.duration { d["duration"] = dur }
            // [T-ios-shellring-counter-leak] `exitedAt` set with no exitCode
            // means the command terminated WITHOUT a status (thrown / cancelled /
            // killed). Distinguishing that from genuinely-still-running is what
            // makes "Shell running: yes" trustworthy in a crash report.
            if entry.exitCode == nil, entry.exitedAt != nil { d["aborted"] = true }
            return d
        }

        let registry = BrowserTabPoolRegistry.shared
        marker["webViewTotalTabs"] = registry.totalLiveTabs()
        marker["webViewGlobalCap"] = BrowserTabPoolRegistry.globalTabCap
        let tabSnapshots = registry.allTabSnapshots()
        marker["webViewTabs"] = tabSnapshots.map { tab -> [String: Any] in
            [
                "sessionId": tab.sessionId,
                "tabId": tab.tabId,
                "url": tab.url,
                "title": tab.title,
                "isLoading": tab.isLoading,
                "inUse": tab.inUse,
                "lastActivityAgo": round(tab.lastActivityAgo * 10) / 10
            ]
        }

        if let updated = try? JSONSerialization.data(withJSONObject: marker),
           let json = String(data: updated, encoding: .utf8) {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Memory

    private func currentMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Int(info.phys_footprint / (1024 * 1024))
        }
        return 0
    }

    private func systemFreeMB() -> Int {
        return Int(os_proc_available_memory() / (1024 * 1024))
    }

    // MARK: - Launch Marker

    /// [T-crash-install-false-positive] The app's data-container UUID — the
    /// directory name iOS assigns per install. Stable for the life of an
    /// install, rotated on every update/reinstall.
    static func currentContainerId() -> String {
        URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent
    }

    private func writeLaunchMarker() {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let pid = ProcessInfo.processInfo.processIdentifier

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let now = df.string(from: Date())

        let marker: [String: Any] = [
            "build": "\(version) (\(build))",
            "pid": pid,
            "launchedAt": now,
            "lastPhase": "active",
            "lastPhaseAt": now,
            "memoryMB": currentMemoryMB(),
            "memoryFreeMB": systemFreeMB(),
            // [T-crash-install-false-positive] Data-container UUID of the run
            // that wrote this marker. iOS re-homes the data container to a NEW
            // UUID on every install/update (verified: four consecutive
            // installs → four UUIDs, contents migrated). A stale marker whose
            // UUID differs from the current run's therefore means "the process
            // was replaced by an install", never "the app crashed".
            "containerId": Self.currentContainerId(),
            // [T-crash-heartbeat] See `runId`.
            "runId": runId,
        ]

        let url = launchMarkerURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: marker),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func removeLaunchMarker() {
        try? FileManager.default.removeItem(at: launchMarkerURL)
    }

    /// [T-ios-session-crash-loop] Set while `checkStaleMarker()` runs, so
    /// `onAppLaunch()` can tell "previous run crashed in the FOREGROUND" from
    /// "previous run crashed in the background / was jetsammed". Only the
    /// foreground case feeds the crash-loop counter — a background jetsam does
    /// not reproduce on relaunch and must not cost the user their launch screen.
    private var lastRunWasForegroundCrash = false

    /// Returns true when a stale launch marker was found, i.e. the previous run
    /// did NOT exit cleanly.
    @discardableResult
    private func checkStaleMarker() -> Bool {
        let url = launchMarkerURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        var markerInfo: [String: Any]?
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            markerInfo = json
        }

        let markedPhase = (markerInfo?["lastPhase"] as? String) ?? "unknown"
        let lastPhaseAt = markerInfo?["lastPhaseAt"] as? String
        // [T-crash-heartbeat] The dead run's last 10 s sample. Newer than the
        // last phase change, so its app state wins when the two disagree.
        let heartbeat = Self.previousHeartbeat(matching: markerInfo)
        let heartbeatAt = (heartbeat?["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let lastPhase: String = {
            guard let state = heartbeat?["appState"] as? String, state != markedPhase,
                  ["active", "inactive", "background"].contains(state) else { return markedPhase }
            let phaseDf = DateFormatter()
            phaseDf.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            let phaseDate = lastPhaseAt.flatMap { phaseDf.date(from: $0) } ?? .distantPast
            return (heartbeatAt ?? .distantPast) >= phaseDate ? state : markedPhase
        }()
        let governor = heartbeat?["governor"] as? [String: Any]
        let governorWindow = (governor?["running"] as? Bool) == true ? governor?["windowCPU"] as? Double : nil
        let heartbeatCPU = heartbeat?["cpuPercent"] as? Int
        let memoryMB = markerInfo?["memoryMB"] as? Int
        let memoryFreeMB = markerInfo?["memoryFreeMB"] as? Int
        let markerBuild = markerInfo?["build"] as? String
        let runningShell = markerInfo?["runningShellCommand"] as? Bool ?? false
        // [T-ios-bgkeepalive-diag] `bgTaskActive` was the old, misleadingly
        // named field carrying the keep-alive INTENT flag. Read the new split
        // fields, falling back to the legacy key so reports written by an older
        // build still render.
        let bgKeepAliveIntent = (markerInfo?["bgKeepAliveIntent"] as? Bool)
            ?? (markerInfo?["bgTaskActive"] as? Bool) ?? false
        let bgTaskGrants = markerInfo?["bgTaskGrants"] as? Int
        let bgSilentAudioLeg = markerInfo?["bgSilentAudioLeg"] as? Bool
        let bgTaskRemaining = markerInfo?["bgTaskRemaining"] as? Double
        let activeSessionCount = markerInfo?["activeSessionCount"] as? Int
        let bkaSilentAudioPlaying = markerInfo?["bkaSilentAudioPlaying"] as? Bool
        let bkaAudioSessionActive = markerInfo?["bkaAudioSessionActive"] as? Bool
        let bkaStopDebouncePending = markerInfo?["bkaStopDebouncePending"] as? Bool
        let bkaLastEvent = markerInfo?["bkaLastEvent"] as? String
        let bkaLastLifecycle = markerInfo?["bkaLastLifecycle"] as? String
        let bkaAudioInterruption = markerInfo?["bkaAudioInterruption"] as? String
        let lastAPIProvider = markerInfo?["lastAPIProvider"] as? String
        let lastAPIModel = markerInfo?["lastAPIModel"] as? String
        let webViewTotalTabs = markerInfo?["webViewTotalTabs"] as? Int
        let webViewGlobalCap = markerInfo?["webViewGlobalCap"] as? Int
        let webViewTabs = markerInfo?["webViewTabs"] as? [[String: Any]]
        let memPressure: String = {
            if let free = memoryFreeMB {
                if free < 200 { return "critical" }
                if free < 500 { return "warning" }
            }
            return "normal"
        }()

        // [T-crash-install-false-positive] Rule out the install/update case
        // BEFORE any crash classification. Two independent hard signals, either
        // of which is conclusive on its own:
        //   • container UUID changed — iOS re-homes the data container on every
        //     install/update, so the previous run literally cannot have been
        //     this same install (markers written before this build ship without
        //     the field, so a missing value is NOT treated as a match);
        //   • build string changed — an update to a different version/build.
        // Field evidence (iPhone10,2, 2026-08-01): five "FOREGROUND CRASH
        // (SIGKILL)" reports in one day, all with 56-81MB footprint, 700MB+
        // free, pressure=normal, clean didEnterBackground tails — and a
        // different container UUID on every relaunch. All five were the
        // installer replacing a running process, not crashes.
        let markerContainerId = markerInfo?["containerId"] as? String
        let currentContainerId = Self.currentContainerId()
        let currentBuild = { () -> String in
            let info = Bundle.main.infoDictionary
            let v = (info?["CFBundleShortVersionString"] as? String) ?? "?"
            let b = (info?["CFBundleVersion"] as? String) ?? "?"
            return "\(v) (\(b))"
        }()
        let containerChanged = markerContainerId != nil && markerContainerId != currentContainerId
        let buildChanged = markerBuild != nil && markerBuild != currentBuild
        if containerChanged || buildChanged {
            let why = containerChanged
                ? "data container re-homed (\(markerContainerId?.prefix(8) ?? "?")… → \(currentContainerId.prefix(8))…)"
                : "build changed (\(markerBuild ?? "?") → \(currentBuild))"
            logger.info("Previous run ended because the app was installed/updated — \(why). Not a crash; no report written.")
            // Deliberately NOT counted as a foreground crash: leaving
            // `lastRunWasForegroundCrash` false also keeps the crash-loop
            // detector (T-ios-session-crash-loop) from arming on two
            // consecutive installs, which would wrongly suppress session
            // restore for the user.
            resetCrashLoopState()
            removeLaunchMarker()
            return false
        }

        let crashType: String
        if lastPhase == "active" || lastPhase == "inactive" {
            // [T-ios-session-crash-loop] The previous run died while the user
            // was looking at it — the shape of the session-restore loop. Feed
            // the counter that decides whether to skip restore next launch.
            lastRunWasForegroundCrash = true
            noteForegroundCrash()
            if runningShell {
                crashType = "⚠️ FOREGROUND CRASH during shell execution"
            } else if let mem = memoryMB, mem >= 350 {
                crashType = "⚠️ FOREGROUND CRASH (high memory: \(mem)MB)"
            } else {
                crashType = "⚠️ FOREGROUND CRASH (SIGKILL — app was in use)"
            }
        } else if lastPhase == "background" {
            if let window = governorWindow, window >= 38 {
                // [T-crash-heartbeat] iOS kills a background app that bills
                // 48 CPU-s in 60 s, with no dialog and no stack. 38 is the
                // governor's RED line: the brake was already on and losing.
                let cpu = heartbeatCPU.map { ", CPU \($0)%" } ?? ""
                crashType = "Background CPU limit kill (likely) — \(String(format: "%.1f", window)) of 48 CPU-s used in the last 60 s at the last heartbeat\(cpu)"
            } else if let cpu = heartbeatCPU, cpu >= 80 {
                crashType = "Background CPU limit kill (possible) — CPU \(cpu)% at the last heartbeat"
            } else if let lost = BackgroundKillClassifier.keepAliveLost(heartbeat?["keepAlive"] as? [String: Any]) {
                // [T-crash-keepalive-heartbeat] Background time was running out
                // at the last heartbeat and nothing was holding the app.
                crashType = lost
            } else if let rem = bgTaskRemaining, rem > 0 && rem < 5 {
                crashType = "Background Task Timeout (task expired with \(String(format: "%.1f", rem))s left)"
            } else if let mem = memoryMB, mem >= 300 {
                crashType = "Background Jetsam (high memory: \(mem)MB)"
            } else if let free = memoryFreeMB, free < 500 {
                crashType = "Background Jetsam (system memory pressure)"
            } else if runningShell || (activeSessionCount ?? 0) > 0 {
                // [T-ios-bgkeepalive-diag] Report the observable facts only —
                // memory was not tight, work was tracked as in flight, and these
                // keep-alive legs were recorded — WITHOUT asserting a cause. The
                // earlier wording ("WITH WORK IN FLIGHT" + ⚠️) implied the kill
                // was caused by keep-alive stopping too early; the three reports
                // that prompted it never established that (their last BKA event
                // predates the kill by 1-28 min, so the evaluation may simply not
                // have run in that window). Keep this branch purely descriptive so
                // it does not pre-commit a future investigation to one hypothesis.
                //
                // Note `shell=running` is only as trustworthy as the ring-buffer
                // counter: it could latch high on builds before the didAbort fix,
                // and could under-count on duplicate-terminal races before the
                // liveStarts fix.
                let legs = [
                    bgSilentAudioLeg == true ? "audio" : nil,
                    (bgTaskGrants ?? 0) > 0 ? "bgTask×\(bgTaskGrants ?? 0)" : nil,
                ].compactMap { $0 }
                let legStr = legs.isEmpty ? "none recorded" : legs.joined(separator: "+")
                let workBits = [
                    runningShell ? "shell=running" : nil,
                    (activeSessionCount ?? 0) > 0 ? "sessions=\(activeSessionCount ?? 0)" : nil,
                ].compactMap { $0 }.joined(separator: ",")
                crashType = "Background Termination (memory not tight; \(workBits); keep-alive legs: \(legStr)) — cause undetermined"
            } else {
                // Idle + memory fine: the ordinary way iOS reclaims a suspended app.
                crashType = "Background Termination (idle app reclaimed — normal)"
            }
        } else {
            crashType = "Unknown Termination"
        }

        logger.warning("Stale launch marker found — previous exit was abnormal: phase=\(lastPhase)")

        let savedShellCommands = (markerInfo?["shellCommands"] as? [[String: Any]]) ?? []

        writeReport(
            type: crashType,
            callStack: nil,
            savedShellCommands: savedShellCommands,
            lastPhase: lastPhase,
            lastPhaseAt: lastPhaseAt,
            heartbeat: heartbeat,
            memoryMB: memoryMB,
            memoryFreeMB: memoryFreeMB,
            memoryPressure: memPressure,
            activeSessionCount: activeSessionCount,
            runningShellCommand: runningShell,
            bgKeepAliveIntent: bgKeepAliveIntent,
            bgTaskGrants: bgTaskGrants,
            bgSilentAudioLeg: bgSilentAudioLeg,
            bgTaskRemaining: bgTaskRemaining,
            lastAPIProvider: lastAPIProvider,
            lastAPIModel: lastAPIModel,
            markerBuild: markerBuild,
            bkaSilentAudioPlaying: bkaSilentAudioPlaying,
            bkaAudioSessionActive: bkaAudioSessionActive,
            bkaStopDebouncePending: bkaStopDebouncePending,
            bkaLastEvent: bkaLastEvent,
            bkaLastLifecycle: bkaLastLifecycle,
            bkaAudioInterruption: bkaAudioInterruption,
            webViewTotalTabs: webViewTotalTabs,
            webViewGlobalCap: webViewGlobalCap,
            webViewTabs: webViewTabs
        )
        return true
    }

    /// [T-crash-diag-export] Moves last_crash_context.prev.txt (if any) to
    /// Crumbs/contexts/context-<time>.txt and keeps the newest 5.
    static func archivePreviousCrashContext() {
        let fm = FileManager.default
        let prev = CrashSignalHandler.previousCrashContextPath()
        guard !prev.isEmpty, fm.fileExists(atPath: prev) else { return }
        let dir = CrashDiagnostics.contextArchiveDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let modified = (try? fm.attributesOfItem(atPath: prev)[.modificationDate] as? Date) ?? Date()
        let dest = dir.appendingPathComponent("context-\(df.string(from: modified)).txt")
        try? fm.removeItem(at: dest)
        if (try? fm.moveItem(atPath: prev, toPath: dest.path)) == nil {
            try? fm.removeItem(atPath: prev)
        }
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("context-") }.sorted(by: >)
        for name in names.dropFirst(5) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    // MARK: - MetricKit

    /// [T-crash-breadcrumbs] Saves a MetricKit diagnostic's full JSON next to
    /// the crash reports and returns the file name.
    @discardableResult
    private func saveMetricKitJSON(_ data: Data, kind: String) -> String? {
        let dir = crashReportsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "metrickit-\(kind)-\(df.string(from: Date()))-\(UUID().uuidString.prefix(4)).json"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            logger.warning("[MetricKit] could not save diagnostic JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// [T-crash-breadcrumbs] The breadcrumbs of the run a diagnostic belongs to:
    /// by the pid in its metaData when present, else the newest earlier run
    /// launched before the payload window ended (approximate - says so).
    static func breadcrumbsForDiagnostic(_ json: Data, payloadEnd: Date) -> (text: String?, source: String?) {
        let dict = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        let meta = dict?["diagnosticMetaData"] as? [String: Any] ?? dict?["metaData"] as? [String: Any]
        if let pid = (meta?["pid"] as? NSNumber)?.int32Value,
           let path = CrashBreadcrumbs.previousRunFile(forPid: pid) {
            return (CrashBreadcrumbs.renderFile(atPath: path), "pid \(pid)")
        }
        if let path = CrashBreadcrumbs.previousRunFileCovering(payloadEnd) {
            return (CrashBreadcrumbs.renderFile(atPath: path), "time match, approximate")
        }
        return (nil, nil)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashDiags = payload.crashDiagnostics, !crashDiags.isEmpty {
                for diag in crashDiags {
                    let exceptionType = diag.exceptionType?.description ?? "unknown"
                    let signal = diag.signal?.description ?? "unknown"
                    let type = "Exception: \(exceptionType) / Signal: \(signal)"

                    var stack: String?
                    let callStackTree = diag.callStackTree
                    let data = callStackTree.jsonRepresentation()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let threads = json["callStacks"] as? [[String: Any]] {
                        var lines: [String] = []
                        for (ti, thread) in threads.enumerated() {
                            let crashed = (thread["threadAttributed"] as? Bool) ?? false
                            lines.append("Thread \(ti)\(crashed ? " (Crashed)" : ""):")
                            if let frames = thread["callStackRootFrames"] as? [[String: Any]] {
                                appendFrames(frames, to: &lines, depth: 0)
                            }
                        }
                        stack = lines.joined(separator: "\n")
                    }

                    // [T-crash-breadcrumbs] The diagnostic describes an EARLIER
                    // run. Attaching THIS run's shell-command ring (as before)
                    // paired that crash with unrelated commands - in raw text.
                    // Instead keep MetricKit's full JSON and attach the
                    // breadcrumbs of the run it belongs to: matched by pid when
                    // the payload carries one, else by the payload's time window.
                    let diagJSON = diag.jsonRepresentation()
                    let crumbs = Self.breadcrumbsForDiagnostic(diagJSON, payloadEnd: payload.timeStampEnd)
                    let savedJSON = saveMetricKitJSON(diagJSON, kind: "crash")
                    writeReport(type: type, callStack: stack,
                                breadcrumbs: crumbs.text, breadcrumbsSource: crumbs.source,
                                metricKitFile: savedJSON)
                }
            }

            if let hangDiags = payload.hangDiagnostics, !hangDiags.isEmpty {
                for diag in hangDiags {
                    let durationMs = diag.hangDuration.converted(to: .milliseconds).value
                    let type = "Hang: \(String(format: "%.0f", durationMs))ms"
                    var stack: String?
                    let data = diag.callStackTree.jsonRepresentation()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let threads = json["callStacks"] as? [[String: Any]] {
                        var lines: [String] = []
                        for (ti, thread) in threads.enumerated() {
                            let attributed = (thread["threadAttributed"] as? Bool) ?? false
                            lines.append("Thread \(ti)\(attributed ? " (Hung)" : ""):")
                            if let frames = thread["callStackRootFrames"] as? [[String: Any]] {
                                appendFrames(frames, to: &lines, depth: 0)
                            }
                        }
                        stack = lines.joined(separator: "\n")
                    }
                    writeReport(type: type, callStack: stack, savedShellCommands: [])
                    logger.warning("[MetricKit] Hang diagnostic: \(type)")
                }
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exitMetrics = payload.applicationExitMetrics else { continue }
            let fg = exitMetrics.foregroundExitData
            let bg = exitMetrics.backgroundExitData
            logger.info("[ExitMetrics] FG: normal=\(fg.cumulativeNormalAppExitCount) badAccess=\(fg.cumulativeBadAccessExitCount) watchdog=\(fg.cumulativeAppWatchdogExitCount) abnormal=\(fg.cumulativeAbnormalExitCount)")
            logger.info("[ExitMetrics] BG: normal=\(bg.cumulativeNormalAppExitCount) memLimit=\(bg.cumulativeMemoryResourceLimitExitCount) memPressure=\(bg.cumulativeMemoryPressureExitCount) watchdog=\(bg.cumulativeAppWatchdogExitCount) bgTimeout=\(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount) cpu=\(bg.cumulativeCPUResourceLimitExitCount)")
        }
    }

    private func appendFrames(_ frames: [[String: Any]], to lines: inout [String], depth: Int) {
        for frame in frames {
            let binary = (frame["binaryName"] as? String) ?? "?"
            let offset = (frame["offsetIntoBinaryTextSegment"] as? Int) ?? 0
            let address = (frame["address"] as? Int) ?? 0
            let indent = String(repeating: "  ", count: depth)
            lines.append("\(indent)\(binary) 0x\(String(address, radix: 16)) +\(offset)")
            if let subFrames = frame["subFrames"] as? [[String: Any]] {
                appendFrames(subFrames, to: &lines, depth: depth + 1)
            }
        }
    }

    // MARK: - Report Writing

    private func writeReport(
        type: String,
        callStack: String?,
        savedShellCommands: [[String: Any]] = [],
        breadcrumbs: String? = nil,
        breadcrumbsSource: String? = nil,
        metricKitFile: String? = nil,
        lastPhase: String? = nil,
        lastPhaseAt: String? = nil,
        heartbeat: [String: Any]? = nil,
        memoryMB: Int? = nil,
        memoryFreeMB: Int? = nil,
        memoryPressure: String? = nil,
        activeSessionCount: Int? = nil,
        runningShellCommand: Bool = false,
        bgKeepAliveIntent: Bool = false,
        bgTaskGrants: Int? = nil,
        bgSilentAudioLeg: Bool? = nil,
        bgTaskRemaining: Double? = nil,
        lastAPIProvider: String? = nil,
        lastAPIModel: String? = nil,
        markerBuild: String? = nil,
        bkaSilentAudioPlaying: Bool? = nil,
        bkaAudioSessionActive: Bool? = nil,
        bkaStopDebouncePending: Bool? = nil,
        bkaLastEvent: String? = nil,
        bkaLastLifecycle: String? = nil,
        bkaAudioInterruption: String? = nil,
        webViewTotalTabs: Int? = nil,
        webViewGlobalCap: Int? = nil,
        webViewTabs: [[String: Any]]? = nil
    ) {
        let fm = FileManager.default
        let dir = crashReportsDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()
        let df = DateFormatter()

        var crashDate: Date
        if let ts = lastPhaseAt {
            let inputDf = DateFormatter()
            inputDf.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            crashDate = inputDf.date(from: ts) ?? now
        } else {
            crashDate = now
        }
        // [T-crash-heartbeat] The last heartbeat is the closest known time to the death.
        if let at = heartbeat?["at"] as? Double, Date(timeIntervalSince1970: at) > crashDate, lastPhaseAt != nil {
            crashDate = Date(timeIntervalSince1970: at)
        }

        df.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "crash-\(df.string(from: crashDate)).log"

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let displayBuild = markerBuild ?? "\(version) (\(build))"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        var deviceModel = "unknown"
        var sysinfo = utsname()
        uname(&sysinfo)
        deviceModel = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = df.string(from: crashDate)

        var report = """
        === Minis Crash Report ===
        Date:    \(dateStr)
        Type:    \(type)
        Build:   \(displayBuild)
        OS:      \(osVersion)
        Device:  \(deviceModel)
        """

        // [T-crash-injected-dylib-tag] Surface tweak/hook injection right in
        // the header. Field case 2026-08-01 (1.11 build 14, iPhone14,3): five
        // "launch crash" SIGABRTs burned hours of triage before the Apple-side
        // .ips revealed ActionBarReborn.dylib + CydiaSubstrate injected into
        // the app bundle — the tweak forwarded a nonexistent selector from a
        // UIButton action (doesNotRecognizeSelector → NSInvalidArgumentException).
        // Our own reports carried no hint of the injection. Detection is for
        // the CURRENT run (injection is install-stable, so it describes the
        // crashed run too); a report about a crash is exactly where the fact
        // belongs — no enforcement, no user-facing behavior.
        let foreign = Self.detectInjectedDylibs()
        if !foreign.isEmpty {
            report += "\n⚠️ Injected: \(foreign.joined(separator: ", "))"
            report += "\n         (third-party tweak/hook libraries loaded in-process — crashes may originate there, not in Minis)"
        }

        if let phase = lastPhase {
            var phaseTime = ""
            if let ts = lastPhaseAt {
                let inputDf = DateFormatter()
                inputDf.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                if let date = inputDf.date(from: ts) {
                    let timeDf = DateFormatter()
                    timeDf.dateFormat = "HH:mm:ss"
                    phaseTime = " (since \(timeDf.string(from: date)))"
                }
            }
            report += "\nLast Phase:  \(phase)\(phaseTime)"
        }

        if let mem = memoryMB {
            report += "\nMemory:      \(mem) MB"
        }

        // Memory State section
        if memoryMB != nil || memoryFreeMB != nil || activeSessionCount != nil {
            report += "\n\n--- Memory State (at last phase change) ---"
            if let mem = memoryMB {
                report += "\nApp footprint:    \(mem) MB"
            }
            if let free = memoryFreeMB {
                report += "\nSystem free:      \(free) MB"
            }
            if let pressure = memoryPressure {
                report += "\nMemory pressure:  \(pressure)"
            }
            if let sessions = activeSessionCount {
                report += "\nActive sessions:  \(sessions)"
            }
            report += "\nShell running:    \(runningShellCommand ? "yes" : "no")"
            // [T-crash-heartbeat] The counters below are read now, in the
            // relaunched process - they do not describe the crashed run (its
            // own numbers are in the heartbeat section).
            report += "\n(next lines sampled at relaunch, not from the crashed run:)"
            // [T-resource-diag] Port/thread-churn accounting. The 2026-09-15
            // PORT_SPACE kills left no in-app trace at all: footprint was 18MB
            // and pressure normal, so every existing field said "healthy".
            // These are the numbers that would have named the cause.
            report += ResourceDiagnostics.crashReportLines()
            // [T-ios-bgkeepalive-diag] Keep the INTENT and the real OS
            // grant on separate lines — the single old "BG task active" line
            // reported the intent flag and read as the grant.
            report += "\nKeep-alive intent: \(bgKeepAliveIntent)"
            if let grants = bgTaskGrants {
                report += "\nBG task grants:   \(grants)\(grants == 0 ? "  ← no UIBackgroundTask held" : "")"
            }
            if let audioLeg = bgSilentAudioLeg {
                report += "\nSilent-audio leg: \(audioLeg ? "yes" : "no")"
            }
            if let rem = bgTaskRemaining {
                if rem < 0 {
                    // `unlimited` means backgroundTimeRemaining returned
                    // .greatestFiniteMagnitude, which is what iOS reports while an
                    // audio/location background mode is holding the process — it is
                    // NOT evidence that a finite bgTask grant was alive.
                    report += "\nBG time remaining: unlimited (background mode active, not a bgTask guarantee)"
                } else {
                    report += "\nBG time remaining: \(String(format: "%.1f", rem))s"
                }
            }
            // [T-bg-keepalive-debounce] BackgroundKeepAlive audio state at crash.
            if let playing = bkaSilentAudioPlaying {
                report += "\nSilent audio playing: \(playing ? "yes" : "no")"
            }
            if let active = bkaAudioSessionActive {
                report += "\nAudio session active: \(active ? "yes" : "no")"
            }
            if let pending = bkaStopDebouncePending {
                report += "\nStop debounce pending: \(pending ? "yes" : "no")"
            }
            if let evt = bkaLastEvent {
                report += "\nLast BKA event:   \(evt)"
            }
            if let lc = bkaLastLifecycle {
                report += "\nLast lifecycle:   \(lc)"
            }
            if let interrupt = bkaAudioInterruption {
                report += "\nAudio interruption: \(interrupt)"
            }
            if let provider = lastAPIProvider, let model = lastAPIModel {
                report += "\nLast API:         \(provider) / \(model)"
            } else if let provider = lastAPIProvider {
                report += "\nLast API:         \(provider)"
            }
        }

        if let heartbeat {
            report += Self.heartbeatReportSection(heartbeat)
        } else if lastPhase != nil {
            report += "\n\n--- Last Heartbeat ---\n(none from the crashed run)"
        }

        // WebView section
        report += "\n\n--- Active WebViews (at last phase change) ---\n"
        if let total = webViewTotalTabs, let cap = webViewGlobalCap {
            report += "Total tabs: \(total) / \(cap) (global cap)\n"
        }
        if let tabs = webViewTabs, !tabs.isEmpty {
            report += "\n"
            for tab in tabs {
                let sid = (tab["sessionId"] as? String) ?? "?"
                let tabId = (tab["tabId"] as? Int) ?? 0
                let isLoading = (tab["isLoading"] as? Bool) ?? false
                let inUse = (tab["inUse"] as? Bool) ?? false
                let lastAgo = (tab["lastActivityAgo"] as? Double) ?? 0
                let rawUrl = (tab["url"] as? String) ?? ""
                let rawTitle = (tab["title"] as? String) ?? ""
                let url = rawUrl.isEmpty ? "(blank)" : String(rawUrl.prefix(80))
                let title = rawTitle.isEmpty ? "(untitled)" : rawTitle

                let statusIcon = isLoading ? "●" : (rawUrl.isEmpty ? "○" : "✓")
                let statusText = isLoading ? "loading" : (rawUrl.isEmpty ? "idle" : "loaded")
                var flags = ""
                if inUse { flags += " (in use)" }
                if lastAgo < 5 { flags += " (just active)" }

                report += "  [\(sid)] Tab \(tabId)  \(statusIcon) \(statusText)\(flags)  \(url)\n"
                report += "                               \(title)\n"
            }
        } else {
            report += "(no active WebViews)\n"
        }

        report += "\n--- Last Shell Commands (before exit) ---\n"

        if savedShellCommands.isEmpty {
            report += "(none recorded)\n"
        } else {
            for entry in savedShellCommands {
                let idx = (entry["index"] as? Int) ?? 0
                let num = String(format: "%2d", idx)
                let time = (entry["startedAt"] as? String) ?? "?"
                let command = (entry["command"] as? String) ?? "?"
                let status: String
                if let code = entry["exitCode"] as? Int, let dur = entry["duration"] as? Double {
                    status = String(format: "+%.1fs  exit=%d", dur, code)
                } else if (entry["aborted"] as? Bool) == true {
                    // Terminated without a status (thrown / cancelled / killed).
                    if let dur = entry["duration"] as? Double {
                        status = String(format: "+%.1fs  ABORTED", dur)
                    } else {
                        status = "ABORTED        "
                    }
                } else {
                    status = "RUNNING        "
                }
                report += "[\(num)] \(time)  \(status)  \(command)\n"
            }
        }

        // [T-crash-heartbeat] The ring is this process's; the crashed run's
        // tail comes from its heartbeat. Without one, say whose lines these are.
        let heartbeatLog = heartbeat?["logTail"] as? [String]
        let logLines = heartbeatLog ?? logRingSnapshot()
        if heartbeatLog != nil {
            report += "\n--- Last \(logLines.count) Log Lines (crashed run, at its last heartbeat) ---\n"
        } else if lastPhase != nil {
            report += "\n--- Last \(logLines.count) Log Lines (THIS launch, not the crashed run - see that day's log file) ---\n"
        } else {
            report += "\n--- Last \(logLines.count) Log Lines (before exit) ---\n"
        }
        if logLines.isEmpty {
            report += "(none recorded)\n"
        } else {
            for line in logLines {
                report += "\(line)\n"
            }
        }

        let hangSnapshot = (try? String(contentsOf: Self.hangSnapshotURL, encoding: .utf8)) ?? ""
        if !hangSnapshot.isEmpty {
            report += "\n--- Last HangDetector Stacks (before exit) ---\n"
            report += hangSnapshot + "\n"
        }

        // [T-crash-breadcrumbs] What the crashed run was doing just before.
        if let breadcrumbs, !breadcrumbs.isEmpty {
            report += "\n--- Breadcrumbs (\(breadcrumbsSource ?? "?")) ---\n"
            report += breadcrumbs + "\n"
        }
        if let metricKitFile {
            report += "\nMetricKit JSON: \(metricKitFile)\n"
        }

        let crashStack = (try? String(contentsOf: Self.crashStackURL, encoding: .utf8)) ?? ""
        if !crashStack.isEmpty {
            report += "\n--- Signal/Exception Crash Stack ---\n"
            report += crashStack + "\n"
        }

        // [T-crash-signal-refault] The fault address and registers the signal
        // handler recorded, which the system report can lose.
        let signalContext = (try? String(contentsOfFile: CrashSignalHandler.previousCrashContextPath(),
                                         encoding: .utf8)) ?? ""
        if !signalContext.isEmpty {
            report += "\n--- Signal Context (si_addr / pc / lr / sp / far / esr) ---\n"
            report += signalContext + "\n"
        }

        report += "\n--- MetricKit Call Stack ---\n"
        if let stack = callStack {
            report += stack + "\n"
        } else {
            report += "(none — SIGKILL has no stack)\n"
        }
        report += "\n=== End ===\n"

        let fileURL = dir.appendingPathComponent(filename)
        try? report.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Crash report written: \(filename)")

        pruneOldReports()
    }

    private func pruneOldReports() {
        let fm = FileManager.default
        let dir = crashReportsDir
        // Only prune crash reports (crash-*.log). Running logs (minis-*.log) now
        // share this directory and are pruned by LoggingManager, not here.
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("crash-") })
            .sorted(by: { ($0.lastPathComponent) < ($1.lastPathComponent) })
        else { return }

        if files.count > maxReports {
            for file in files.prefix(files.count - maxReports) {
                try? fm.removeItem(at: file)
                logger.info("Pruned old crash report: \(file.lastPathComponent)")
            }
        }
    }
}

// MARK: - Runtime heartbeat [T-crash-heartbeat]

/// What the app was doing in the seconds before it died, for SIGKILL reports.
///
/// A SIGKILL leaves no stack and runs no code, and the launch marker is only
/// rewritten on foreground/background switches - the background CPU kills of
/// 2026-10-07/08 came ~50 s after the last switch, so the marker could not
/// show the 100%+ CPU, the RED governor or the sub-agents that were running.
/// Every 10 s (and on each switch) one small JSON file is rewritten with the
/// numbers that decide a kill: footprint, CPU, threads, thermal state, the
/// background CPU governor's window, the running agents and their current
/// tool, the running shell commands and the last log lines. The next launch
/// reads it into the crash report.
///
/// Cost: two task_info calls, one task_threads, one small atomic file write
/// on a utility queue, plus a few property reads on the main thread.
extension CrashReporter {
    func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: Self.heartbeatInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.recordHeartbeat(reason: "tick") }
        }
        t.resume()
        heartbeatTimer = t
    }

    /// Collects the main-thread state, then samples and writes off the main thread.
    @MainActor
    func recordHeartbeat(reason: String) {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let tracker = SessionActivityTracker.shared
        let now = Date()
        let sessions: [[String: Any]] = tracker.resolvedBusySessionIds.sorted().prefix(12).map { sid in
            let info = tracker.sessionToolInfo[sid]
            var d: [String: Any] = ["id": String(sid.prefix(8))]
            if let info {
                d["title"] = String(info.title.prefix(40))
                d["tool"] = info.toolName
                d["status"] = String(info.toolStatus.prefix(80))
                if info.lastToolChange != .distantPast {
                    d["toolForS"] = Int(now.timeIntervalSince(info.lastToolChange))
                }
            }
            return d
        }
        let mainState: [String: Any] = [
            "appState": appState,
            "sessions": sessions,
            "busyCount": tracker.resolvedBusySessionIds.count,
            "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
            // [T-crash-keepalive-heartbeat]
            "keepAlive": BackgroundKeepAliveManager.shared.keepAliveHeartbeat,
        ]
        heartbeatQueue.async { [self] in
            writeHeartbeat(reason: reason, mainState: mainState, at: now)
        }
    }

    /// heartbeatQueue only.
    private func writeHeartbeat(reason: String, mainState: [String: Any], at now: Date) {
        var hb = mainState
        hb["runId"] = runId
        hb["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        hb["at"] = now.timeIntervalSince1970
        hb["reason"] = reason
        let vm = ResourceSampler.vmInfo()
        hb["footprintMB"] = Int(vm.footprint >> 20)
        hb["availMB"] = Int(os_proc_available_memory() >> 20)
        hb["threads"] = ResourceSampler.threadCount()
        let cpu = Self.processCPUSeconds()
        if let last = lastHeartbeatCPU, cpu > 0 {
            let wall = now.timeIntervalSince(last.at)
            if wall > 0.5 {
                // Percent of one core, as Instruments and the [CPUTop] log show it.
                hb["cpuPercent"] = Int((cpu - last.cpuSeconds) / wall * 100)
            }
        }
        if cpu > 0 { lastHeartbeatCPU = (cpu, now) }
        hb["thermal"] = Self.thermalName(ProcessInfo.processInfo.thermalState)
        let kernel = ISHKernel.shared
        if kernel.isBooted {
            hb["governor"] = kernel.backgroundCPUGovernorStatus()
        }
        hb["shellRunning"] = ShellCommandRingBuffer.syncSnapshot
            .filter { $0.exitCode == nil && $0.exitedAt == nil }
            .suffix(6)
            .map { e -> [String: Any] in
                ["command": String(e.command.prefix(160)),
                 "session": String(e.sessionId.prefix(8)),
                 "runningForS": Int(now.timeIntervalSince(e.startedAt))]
            }
        hb["logTail"] = logRingSnapshot()
        guard let data = try? JSONSerialization.data(withJSONObject: hb) else { return }
        try? data.write(to: Self.heartbeatURL, options: .atomic)
    }

    /// The previous run's last heartbeat, if it belongs to the run that wrote `marker`.
    static func previousHeartbeat(matching marker: [String: Any]?) -> [String: Any]? {
        guard let data = try? Data(contentsOf: heartbeatURL),
              let hb = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Markers from builds before the run id: fall back to the pid.
        if let markerRun = marker?["runId"] as? String {
            return (hb["runId"] as? String) == markerRun ? hb : nil
        }
        if let markerPid = marker?["pid"] as? Int, let hbPid = hb["pid"] as? Int {
            return markerPid == hbPid ? hb : nil
        }
        return nil
    }

    /// Process CPU time (live + exited threads), seconds; what iOS bills.
    static func processCPUSeconds() -> Double {
        var basic = mach_task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr1 = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bcount)
            }
        }
        var times = task_thread_times_info()
        var tcount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &times) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &tcount)
            }
        }
        guard kr1 == KERN_SUCCESS, kr2 == KERN_SUCCESS else { return 0 }
        func secs(_ t: time_value_t) -> Double { Double(t.seconds) + Double(t.microseconds) / 1e6 }
        return secs(basic.user_time) + secs(basic.system_time) + secs(times.user_time) + secs(times.system_time)
    }

    static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Report section for the dead run's last heartbeat.
    static func heartbeatReportSection(_ hb: [String: Any]) -> String {
        let at = Date(timeIntervalSince1970: hb["at"] as? Double ?? 0)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        // Written every 10 s while the process runs, so the death came after
        // this - usually within ~10 s, later only if the app was suspended.
        var out = "\n\n--- Last Heartbeat of the crashed run (written \(tf.string(from: at)), every \(Int(heartbeatInterval))s while running) ---"
        out += "\nApp state:        \(hb["appState"] as? String ?? "?") (sample: \(hb["reason"] as? String ?? "?"))"
        out += "\nFootprint:        \(hb["footprintMB"] as? Int ?? -1) MB, system avail \(hb["availMB"] as? Int ?? -1) MB"
        if let cpu = hb["cpuPercent"] as? Int {
            out += "\nCPU (last ~10s):  \(cpu)% of one core"
        }
        out += "\nThreads:          \(hb["threads"] as? Int ?? -1)"
        out += "\nThermal:          \(hb["thermal"] as? String ?? "?")   low power: \((hb["lowPower"] as? Bool ?? false) ? "on" : "off")"
        if let gov = hb["governor"] as? [String: Any], gov["running"] as? Bool == true {
            out += String(format: "\nBG CPU governor:  zone=%@ window=%.1f of 48 CPU-s/60s rate=%.2f CPU-s/s, %.0fs in background",
                          gov["zone"] as? String ?? "?", gov["windowCPU"] as? Double ?? 0,
                          gov["rate"] as? Double ?? 0, gov["secondsInBackground"] as? Double ?? 0)
        } else {
            out += "\nBG CPU governor:  not running"
        }
        if let line = BackgroundKillClassifier.heartbeatLine(hb["keepAlive"] as? [String: Any]) {
            out += "\nKeep-alive:       \(line)"
        }
        let sessions = hb["sessions"] as? [[String: Any]] ?? []
        out += "\nRunning agents:   \(hb["busyCount"] as? Int ?? sessions.count)"
        for s in sessions {
            let age = (s["toolForS"] as? Int).map { " (\($0)s)" } ?? ""
            out += "\n  [\(s["id"] as? String ?? "?")] \(s["title"] as? String ?? "") — \(s["tool"] as? String ?? "?"): \(s["status"] as? String ?? "")\(age)"
        }
        let shells = hb["shellRunning"] as? [[String: Any]] ?? []
        out += "\nRunning shell:    \(shells.isEmpty ? "none" : "\(shells.count)")"
        for c in shells {
            out += "\n  [\(c["session"] as? String ?? "?")] +\(c["runningForS"] as? Int ?? 0)s  \(c["command"] as? String ?? "")"
        }
        return out
    }
}

// BEGIN BackgroundKillClassifier
/// [T-crash-keepalive-heartbeat] Reads the keep-alive state the heartbeat
/// recorded (`BackgroundKeepAliveManager.keepAliveHeartbeat`).
enum BackgroundKillClassifier {
    /// Background time at or under this at the last heartbeat (written every
    /// 10 s) means the app was inside its final ~30 s grant.
    static let lowBackgroundTime = 20

    /// The crash type when the app ran out of background time with nothing
    /// holding it, or nil when the heartbeat does not show that.
    static func keepAliveLost(_ keepAlive: [String: Any]?) -> String? {
        guard let k = keepAlive,
              let remaining = k["bgRemaining"] as? Int, remaining >= 0, remaining <= lowBackgroundTime,
              k["continued"] as? Bool != true, k["audioPlaying"] as? Bool != true else { return nil }
        let left = "\(remaining) s of background time left at the last heartbeat"
        guard k["configured"] as? Bool == true else {
            return "Background time ran out (likely) — no keep-alive was active; \(left)"
        }
        var why = "keep-alive audio was not playing"
        if k["audioInterruption"] as? String == "began", let ago = k["audioInterruptionAgoS"] as? Int {
            why += " (interrupted \(ago) s earlier, e.g. by a call, and not restored)"
        }
        return "Background time ran out (likely) — \(why); \(left)"
    }

    /// One line for the "Last Heartbeat" section of a report.
    static func heartbeatLine(_ keepAlive: [String: Any]?) -> String? {
        guard let k = keepAlive else { return nil }
        let remaining = k["bgRemaining"] as? Int ?? -1
        var parts = [
            "audio=\(k["audioPlaying"] as? Bool == true ? "playing" : "not playing")"
                + (k["configured"] as? Bool == true ? "" : " (off in Settings)"),
            "continued task=\(k["continued"] as? Bool == true ? "running" : "no")",
            "background time=\(remaining < 0 ? "unlimited" : "\(remaining) s")",
        ]
        if let kind = k["audioInterruption"] as? String, let ago = k["audioInterruptionAgoS"] as? Int {
            parts.append("last audio interruption \(kind) \(ago) s ago")
        }
        return parts.joined(separator: ", ")
    }
}
// END BackgroundKillClassifier
