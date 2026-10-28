import Combine
import Foundation
import UIKit

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Session Activity Tracker

/// Tracks which sessions are currently processing, so the home screen
/// can display a spinner even when the user navigates away from the chat.
@MainActor
final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    /// Session IDs that are currently processing (streaming / running tools).
    /// Canonical keys are real session IDs (UUIDs). Draft IDs are mirrored
    /// through `draftAliases` instead — see `setDraftAlias` — so the tracker
    /// only ever stores one entry per active session, preserving the
    /// "processing ends → entry clears" invariant that Live Activity relies
    /// on.
    @Published var activeSessions: Set<String> = [] {
        didSet { recomputeBusy() }   // [T-scheduled-active-session]
    }
    /// Maps a sidebar draft ID to its real session ID after ensureSession
    /// migrates from draft→real. Allows sidebar proxy rows that still
    /// identify themselves by draftId (ContentView's `displaySessions`) to
    /// reflect the live state of their underlying real session without
    /// double-inserting into `activeSessions`.
    @Published var draftAliases: [String: String] = [:]
    @Published var currentToolStatus: String = ""

    // MARK: [T-scheduled-active-session] Active conversations
    //
    // `activeSessions` above means one narrow thing — this conversation's own
    // agent loop is running right now — and many paths depend on exactly that
    // (keep-screen-awake, the iCloud send hold, the Resume banner, Shortcuts
    // completion, VM eviction, the Live Activity cards). A conversation can be
    // ACTIVE without its loop running, though: it has a scheduled follow-up
    // still due to fire, or sub agents still working for it. Both will make it
    // speak again, so it must keep its background allowance, its Stop button
    // and its list spinner. `busySessions` is that wider set, and the one read
    // point for all of them; the narrow set is left exactly as it was.

    /// Conversations a scheduled follow-up keeps active between fires
    /// (`AgentJobRegistry.sessionsKeptActiveBySchedule`).
    @Published private(set) var scheduledSessions: Set<String> = []
    /// Conversations with sub agents running, pending or queued
    /// (`AgentJobRegistry.parentsWithActiveChildren`).
    @Published private(set) var delegatingSessions: Set<String> = []
    /// `activeSessions ∪ scheduledSessions ∪ delegatingSessions`.
    @Published private(set) var busySessions: Set<String> = []

    /// Pushed by `AgentJobRegistry.jobsDidChange()` after every job change.
    func setJobSessions(scheduled: Set<String>, delegating: Set<String>) {
        let scheduledChanged = scheduled != scheduledSessions
        if scheduledChanged {
            logger.info("⏰[Tracker] scheduledSessions \(scheduledSessions.count)→\(scheduled.count) ids=[\(scheduled.map { $0.prefix(8) }.joined(separator: ","))]")
            scheduledSessions = scheduled
        }
        if delegating != delegatingSessions { delegatingSessions = delegating }
        recomputeBusy()
        // [T-live-activity-scheduled] Waiting cards come and go with this set.
        // When nothing is busy any more, keep-alive's deactivation finishes the
        // activity instead; an empty push first would hard-end it.
        if scheduledChanged, !busySessions.isEmpty {
            BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "scheduledSessions")
        }
    }

    /// [T-live-activity-scheduled] The conversations the Live Activity shows a
    /// card for: loops running now, and conversations waiting for their next
    /// scheduled run. Sub agent parents are left out: their sub agents have
    /// cards of their own.
    var liveActivitySessions: Set<String> { activeSessions.union(scheduledSessions) }

    /// [T-live-activity-scheduled] Last title seen per conversation. Unlike
    /// `sessionToolInfo` it survives the loop going inactive, so a waiting
    /// card keeps the conversation's title.
    private(set) var knownTitles: [String: String] = [:]

    private func recomputeBusy() {
        let busy = activeSessions.union(scheduledSessions).union(delegatingSessions)
        guard busy != busySessions else { return }
        busySessions = busy
    }

    /// Is this conversation (or the draft standing in for it) active?
    func isBusy(_ sessionId: String) -> Bool {
        if busySessions.contains(sessionId) { return true }
        if let realId = draftAliases[sessionId], busySessions.contains(realId) { return true }
        return false
    }

    /// `isBusy` for a whole list at once: busy ids with draft aliases resolved
    /// in, like `resolvedActiveSessionIds`.
    var resolvedBusySessionIds: Set<String> {
        var out = busySessions
        for (draftId, realId) in draftAliases where busySessions.contains(realId) {
            out.insert(draftId)
        }
        return out
    }

    /// Per-session tool info for Live Activity carousel.
    struct SessionToolInfo {
        var title: String = ""
        var toolName: String = ""
        var toolStatus: String = ""
        var loopIteration: Int = 0
        /// When `toolName` last changed. Used to pick the most-recently-invoked
        /// tool across all sessions for the Dynamic Island minimal icon.
        var lastToolChange: Date = .distantPast
        /// [T-agent-inner-tool-front] Last time ANYTHING about this session's
        /// tool changed — the name or just the status line.
        ///
        /// Distinct from `lastToolChange`, which only moves when the tool NAME
        /// changes and drives the Dynamic Island's "most recent tool" pick. An
        /// agent doing ten browser_use operations in a row never changes its
        /// name, so a picker keyed on that would see it as idle the whole time.
        var lastActivity: Date = .distantPast
    }
    @Published var sessionToolInfo: [String: SessionToolInfo] = [:]

    /// The SF Symbol for the most-recently-invoked tool across all active
    /// sessions (the session whose `toolName` changed last). Drives the
    /// Dynamic Island minimal icon's "latest tool" frame. Nil when no active
    /// session has a tool yet.
    func latestToolName() -> String? {
        let active = activeSessions
        return sessionToolInfo
            .filter { active.contains($0.key) && !$0.value.toolName.isEmpty }
            .max { $0.value.lastToolChange < $1.value.lastToolChange }?
            .value.toolName
    }
    private var lastLiveActivityPush: Date = .distantPast
    private static let liveActivityThrottleInterval: TimeInterval = 5.0
    private var throttledUpdateWorkItem: DispatchWorkItem?

    func updateToolInfo(sessionId: String, toolName: String, toolStatus: String) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        let nameChanged = info.toolName != toolName
        let statusChanged = info.toolStatus != toolStatus
        info.toolName = toolName
        info.toolStatus = toolStatus
        if nameChanged {
            info.lastToolChange = Date()
        }
        if nameChanged || statusChanged {
            info.lastActivity = Date()
        }
        sessionToolInfo[sessionId] = info
        guard nameChanged || statusChanged else { return }
        // [T-log-noise-privacy] No `status` text: it is the model's own
        // description of what it is doing right now ("搜索苹果 Q4 财报详情") —
        // user-facing content, written to the log on EVERY tool step of every
        // running session, which sub agents multiply by the fan-out width.
        // The tool name and the changed flag are what the Live Activity and
        // the tool bar actually key off; the prose was only ever incidental.
        logger.info("[LiveActivity][toolInfo] sid=\(sessionId.prefix(8)) toolName=\(toolName) statusLen=\(toolStatus.count) nameChanged=\(nameChanged)")
        if nameChanged {
            throttledUpdateWorkItem?.cancel()
            throttledUpdateWorkItem = nil
            lastLiveActivityPush = Date()
            BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolNameChange")
        } else {
            let elapsed = Date().timeIntervalSince(lastLiveActivityPush)
            if elapsed >= Self.liveActivityThrottleInterval {
                throttledUpdateWorkItem?.cancel()
                throttledUpdateWorkItem = nil
                lastLiveActivityPush = Date()
                BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusChange")
            } else if throttledUpdateWorkItem == nil {
                let delay = Self.liveActivityThrottleInterval - elapsed
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lastLiveActivityPush = Date()
                    self.throttledUpdateWorkItem = nil
                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusThrottled")
                }
                throttledUpdateWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    func updateLoopIteration(_ sessionId: String, iteration: Int) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        info.loopIteration = iteration
        sessionToolInfo[sessionId] = info
    }

    func updateSessionTitle(_ sessionId: String, title: String) {
        knownTitles[sessionId] = title
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        guard info.title != title else { return }
        info.title = title
        sessionToolInfo[sessionId] = info
        BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "titleChange")
    }

    /// Thread-safe mirror of `activeSessions` + `draftAliases`, readable from
    /// non-MainActor contexts — notably the ChatStore actor's iCloud merge
    /// path, which must know whether a session is mid-run before applying a
    /// remote message. The `@MainActor`-isolated published state can't be read
    /// off-main, so every mutation also refreshes this lock-guarded snapshot.
    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var activeSessionsMirror: Set<String> = []
    nonisolated(unsafe) private static var draftAliasesMirror: [String: String] = [:]

    /// Non-MainActor query: is this session (or its draft alias) running
    /// locally? Used by sync to avoid clobbering a session that's actively
    /// streaming / running tools.
    nonisolated static func isActiveThreadSafe(_ sessionId: String) -> Bool {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        if activeSessionsMirror.contains(sessionId) { return true }
        if let real = draftAliasesMirror[sessionId], activeSessionsMirror.contains(real) { return true }
        return false
    }

    private func syncMirror() {
        Self.mirrorLock.lock()
        Self.activeSessionsMirror = activeSessions
        Self.draftAliasesMirror = draftAliases
        Self.mirrorLock.unlock()
    }

    func setActive(_ sessionId: String, source: String = #function) {
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.insert(sessionId)
        syncMirror()
        logger.info("🟢[Tracker] setActive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))]")
    }

    func setInactive(_ sessionId: String, source: String = #function) {
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.remove(sessionId)
        sessionToolInfo.removeValue(forKey: sessionId)
        // Drop any alias pointing at this session — if the real session is
        // no longer active, its draft alias should not linger either.
        let orphanedAliases = draftAliases.filter { $0.value == sessionId }.map { $0.key }
        for draftKey in orphanedAliases {
            draftAliases.removeValue(forKey: draftKey)
        }
        syncMirror()
        logger.info("🔴[Tracker] setInactive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))] clearedAliases=\(orphanedAliases.count)")
    }

    /// Register an alias from a draft ID to its newly-minted real session
    /// ID. After this, `isActive(draftId)` returns `isActive(realId)`.
    /// Removed automatically when the real session goes inactive.
    func setDraftAlias(draft draftId: String, real realId: String) {
        draftAliases[draftId] = realId
        syncMirror()
        logger.info("🔗[Tracker] setDraftAlias(\(draftId.prefix(8)) → \(realId.prefix(8)))")
    }

    func isActive(_ sessionId: String) -> Bool {
        if activeSessions.contains(sessionId) { return true }
        if let realId = draftAliases[sessionId],
           activeSessions.contains(realId) { return true }
        return false
    }

    /// `isActive` in aggregation-pass form: active ids with draft aliases
    /// resolved IN, so callers sweeping a whole list (the sidebar grouping)
    /// build this once and do plain hash lookups per member instead of
    /// entering the tracker per member. O(active + aliases) — tiny.
    var resolvedActiveSessionIds: Set<String> {
        var out = activeSessions
        for (draftId, realId) in draftAliases where activeSessions.contains(realId) {
            out.insert(draftId)
        }
        return out
    }
}

/// Keeps the screen awake while any chat session is running a task, when the
/// user has opted in via Appearance Settings. Toggles
/// `UIApplication.isIdleTimerDisabled` from transitions of
/// `SessionActivityTracker.activeSessions`; revokes the lock as soon as all
/// sessions go idle so we don't keep the screen on longer than necessary.
@MainActor
final class KeepScreenAwakeController {
    static let shared = KeepScreenAwakeController()

    static let userDefaultsKey = "keepScreenAwakeDuringTasks"

    private var activityCancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var lockHeld = false
    private var appInBackground = false

    private init() {}

    /// Wire up observers. Safe to call once at app launch.
    func start() {
        // Use a strong `self` capture — this is a singleton and the
        // cancellables/observers live for the app lifetime. A `[weak self]`
        // here would never actually fire anyway, but writing `self` avoids
        // the class of bugs where a subtle retain-cycle audit removes the
        // shared reference and the sink silently becomes a no-op.
        activityCancellable = SessionActivityTracker.shared.$activeSessions
            .receive(on: DispatchQueue.main)
            .sink { _ in
                KeepScreenAwakeController.shared.refresh(reason: "tracker")
            }

        // `UserDefaults.didChangeNotification` fires for every key in the
        // suite, which is very chatty but cheap — refresh() is idempotent
        // and short-circuits when shouldHoldLock matches the current state.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { _ in
            KeepScreenAwakeController.shared.refresh(reason: "defaults")
        }

        // Release the lock when the app is not in the foreground so we
        // don't keep a backgrounded device awake (the system puts us to
        // sleep soon anyway, but being explicit avoids holding the lock
        // across a background→foreground cycle if iOS ever keeps us
        // scheduled longer than expected).
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            KeepScreenAwakeController.shared.onScenePhaseChanged(background: true)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            // [T-ios-scenephase-active-sigkill] Defer the foreground transition
            // off the synchronous notification delivery. Writing isIdleTimerDisabled
            // synchronously here overlaps with SwiftUI view-graph re-evaluation
            // during the foreground transition → SIGKILL. Matches the deferral
            // pattern in BackgroundKeepAliveManager (6e54b5fd). The background
            // observer above stays synchronous — backgrounding has no view-graph risk.
            Task { @MainActor in
                await Task.yield()
                KeepScreenAwakeController.shared.onScenePhaseChanged(background: false)
            }
        }

        refresh(reason: "start")
    }

    private func onScenePhaseChanged(background: Bool) {
        appInBackground = background
        refresh(reason: background ? "background" : "foreground")
        // [T-idle-timer-lease] iOS may reset the flag while backgrounded; put
        // back whatever the other owners (backup, migration sheet) still hold.
        // Runs in the deferred foreground path set up in start().
        if !background { IdleTimerLease.reapply() }
    }

    /// Evaluate the desired idle-timer state and apply it when it differs
    /// from the current held state. Safe to call from any observer.
    /// Internal so AlwaysOnController can re-evaluate when a chat's … menu
    /// override changes.
    func refresh(reason: String) {
        let enabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        // [T-always-on] A chat switched off from its … menu ("Keep Screen
        // Awake (This Chat)") does not keep the screen on by itself.
        let sessionCount = SessionActivityTracker.shared.activeSessions
            .filter { !AlwaysOnController.shared.isOverriddenOff($0) }.count
        let hasRunningTask = sessionCount > 0
        // Three ways to release the lock:
        //   - user turned the setting off
        //   - nothing is running
        //   - app went to background (system will sleep us anyway; we just
        //     want to not hold a stale lock)
        let shouldHoldLock = enabled && hasRunningTask && !appInBackground

        guard shouldHoldLock != lockHeld else {
            logger.debug("[KeepScreen] noop reason=\(reason) sessions=\(sessionCount) enabled=\(enabled) bg=\(self.appInBackground) held=\(self.lockHeld)")
            return
        }
        // [T-idle-timer-lease] Our own lease only: releasing it no longer turns
        // off a lock the backup or the migration sheet is holding.
        IdleTimerLease.set(.keepScreenAwake, held: shouldHoldLock, reason: reason)
        lockHeld = shouldHoldLock
        logger.info("[KeepScreen] lease=\(shouldHoldLock) reason=\(reason) sessions=\(sessionCount) enabled=\(enabled) bg=\(self.appInBackground)")
    }
}

// MARK: - Session Concurrency Manager

// BEGIN ConcurrencyLimits
/// [T-limits-per-parent] Every concurrency cap of the agent runtime, in one
/// place. The same numbers ship on Android.
///
///   - `sessionSlots` (6): agent loops of conversations running at once,
///     across the app, counted per session (SessionConcurrencyManager). A sub
///     agent run - a delegate_task child or a scheduled child-of-current - does
///     NOT take one: a parent waiting on its own sub agents already holds one,
///     and routing the children through the same pool could leave every parent
///     waiting behind its own children.
///   - `childJobsPerParent` (3): sub agents running at once PER PARENT
///     conversation (AgentJobRegistry). Each parent has its own 3; parents do
///     not compete for them.
///   - `queuedDelegationsPerParent` (10): delegations waiting for one of those
///     slots, per parent. Past it a delegation is refused, and told it was NOT
///     queued.
///   - `toolsPerTurn` (10): tool calls one turn runs in parallel.
///
/// Worst case these allow: 6 parents x 3 sub agents + the 6 parents = 24 agent
/// loops at once, with no shell concurrency cap on iOS. Raise any of them with
/// that in mind.
enum ConcurrencyLimits {
    static let shippingSessionSlots = 6
    static let shippingChildJobsPerParent = 3
    static let shippingQueuedDelegationsPerParent = 10
    static let shippingToolsPerTurn = 10

    #if DEBUG
    static var sessionSlots: Int { LoadTestLimits.sessionSlots ?? shippingSessionSlots }
    static var childJobsPerParent: Int { LoadTestLimits.childJobs ?? shippingChildJobsPerParent }
    static var queuedDelegationsPerParent: Int { LoadTestLimits.queuedDelegations ?? shippingQueuedDelegationsPerParent }
    static var toolsPerTurn: Int { LoadTestLimits.toolsPerTurn ?? shippingToolsPerTurn }
    #else
    static var sessionSlots: Int { shippingSessionSlots }
    static var childJobsPerParent: Int { shippingChildJobsPerParent }
    static var queuedDelegationsPerParent: Int { shippingQueuedDelegationsPerParent }
    static var toolsPerTurn: Int { shippingToolsPerTurn }
    #endif
}

#if DEBUG
/// [T-loadtest-limits] DEBUG-only overrides of the hard concurrency limits,
/// for the on-device load test (debug.loadtest.setLimits). nil = the shipping
/// value. In memory only: a relaunch restores the defaults. Release builds
/// compile none of this; their limits are the plain constants.
enum LoadTestLimits {
    /// ConcurrencyLimits.sessionSlots (shipping: 6).
    nonisolated(unsafe) static var sessionSlots: Int?
    /// ConcurrencyLimits.childJobsPerParent (shipping: 3 per parent).
    nonisolated(unsafe) static var childJobs: Int?
    /// ConcurrencyLimits.queuedDelegationsPerParent (shipping: 10 per parent).
    nonisolated(unsafe) static var queuedDelegations: Int?
    /// ConcurrencyLimits.toolsPerTurn (shipping: 10).
    nonisolated(unsafe) static var toolsPerTurn: Int?
}
#endif
// END ConcurrencyLimits

// BEGIN SessionSlots
/// [T-limits-per-parent] What `SessionConcurrencyManager.acquire` handed out.
/// `holdsSlot` is false for a sub agent run, which never takes a slot; `release`
/// gives back only a slot the lease actually holds, so an exempt run can never
/// free a slot that belongs to another session.
struct SessionSlotLease: Equatable {
    let sessionId: String
    let holdsSlot: Bool
}

/// Limits the number of sessions actively running LLM requests.
/// Excess sessions are suspended in FIFO order and resumed when slots free up.
/// Sub agent runs are exempt (see `ConcurrencyLimits`).
@MainActor
final class SessionConcurrencyManager: ObservableObject {
    static let shared = SessionConcurrencyManager()

    var maxConcurrent: Int { ConcurrencyLimits.sessionSlots }

    @Published private(set) var runningSessions: Set<String> = []
    @Published private(set) var suspendedSessions: [String] = []
    private var waiters: [(id: String, continuation: CheckedContinuation<Void, Never>)] = []

    /// [T-limits-per-parent] The only way in. An `exempt` run (a sub agent)
    /// gets a lease that holds no slot and never waits; everyone else waits for
    /// a slot exactly as before. Pair every successful call with `release`.
    func acquire(sessionId: String, exempt: Bool) async throws -> SessionSlotLease {
        if exempt { return SessionSlotLease(sessionId: sessionId, holdsSlot: false) }
        try await acquireSlot(sessionId: sessionId)
        return SessionSlotLease(sessionId: sessionId, holdsSlot: true)
    }

    /// Give back what `acquire` handed out. A lease without a slot is a no-op.
    func release(_ lease: SessionSlotLease) {
        guard lease.holdsSlot else { return }
        releaseSlot(sessionId: lease.sessionId)
    }

    /// Acquire a processing slot. Returns immediately if under limit, otherwise suspends until a slot opens.
    private func acquireSlot(sessionId: String) async throws {
        if runningSessions.count < maxConcurrent {
            runningSessions.insert(sessionId)
            return
        }

        // Over limit — suspend and wait
        suspendedSessions.append(sessionId)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((id: sessionId, continuation: continuation))
        }
        // After resuming, check if the task was cancelled while waiting
        try Task.checkCancellation()
        runningSessions.insert(sessionId)
    }

    /// Release a processing slot and resume the next waiting session (FIFO).
    private func releaseSlot(sessionId: String) {
        runningSessions.remove(sessionId)
        resumeNextWaiter()
    }

    /// Cancel a suspended session's wait so cancellation can propagate.
    func cancelWait(sessionId: String) {
        suspendedSessions.removeAll { $0 == sessionId }
        if let idx = waiters.firstIndex(where: { $0.id == sessionId }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume()
        }
    }

    /// Whether a session is currently suspended waiting for a slot.
    func isSuspended(_ sessionId: String) -> Bool {
        suspendedSessions.contains(sessionId)
    }

    private func resumeNextWaiter() {
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        suspendedSessions.removeAll { $0 == next.id }
        next.continuation.resume()
    }
}

// END SessionSlots

// MARK: - ViewModel Cache

/// Caches AIChatViewModel instances by session ID so re-entering a session
/// reuses the same (possibly still-running) ViewModel instead of creating a new one.
@MainActor
final class ViewModelCache {
    static let shared = ViewModelCache()

    /// [T-vmcache-pools] Which LRU pool a cached VM belongs to.
    ///
    /// Child (sub agent) conversations must not compete with the user's own
    /// for the ordinary budget: a fan-out of three sub agents used to evict
    /// three normal conversations, and a long-running child could hold a slot
    /// the user never sees. They get their own, larger pool instead.
    enum PoolKind: String {
        /// A conversation the user opens directly.
        case normal
        /// A sub agent / helper run. Created by HelperRunner, usually never
        /// displayed; see `releaseRenderState`.
        case child
    }

    private var cache: [String: AIChatViewModel] = [:]

    /// Pool membership per session id. Absent ⇒ `.normal`, so every existing
    /// call site keeps its previous behaviour without passing anything.
    private var poolKinds: [String: PoolKind] = [:]

    /// Session IDs in least-recently-used → most-recently-used order. Kept in
    /// sync with `cache`: appended/moved to the end on every access, removed
    /// with the entry. Drives soft-cap eviction so we don't retain a fully
    /// loaded ViewModel (messages + agentHistory + parsed markdown blocks) for
    /// every session opened since launch — the primary driver of the app's
    /// resident-memory baseline, which pushes the process toward jetsam once
    /// iSH (gh/python3) adds its own footprint. [T-ios-vmcache-lru-evict]
    private var lruOrder: [String] = []

    /// Soft cap on cached ViewModels. Beyond this, the least-recently-used
    /// NON-processing VMs are evicted (a processing VM is never evicted — its
    /// agent loop must keep running). Re-entering an evicted session rebuilds
    /// the VM and re-hydrates messages from SQLite via the normal isNew path.
    /// [T-ios-vmcache-lru-evict]
    ///
    /// [T-limits-per-parent] Tied to the session slots: `sessionSlots` running
    /// conversations plus `normalIdleHeadroom` idle ones (the one on screen and
    /// the last few the user switched between). It was a fixed 6 - equal to the
    /// new slot count, so six running conversations would have left no room
    /// for the one being viewed and every switch would evict the previous
    /// conversation. Deriving it keeps it above the slots when the DEBUG
    /// load-test override raises them. Shipping: 6 + 4 = 10.
    ///
    /// Cost: an idle VM holds its messages + agentHistory (text, kilobytes to
    /// a few MB for a long conversation) and the parsed markdown / attributed
    /// strings of what was rendered. Four extra idle VMs are a few MB to a few
    /// tens of MB in the worst case, against a jetsam line in the GBs; the
    /// memory-warning path below still drops every idle one at once.
    static let normalIdleHeadroom = 4
    static var softCap: Int { ConcurrencyLimits.sessionSlots + normalIdleHeadroom }

    /// [T-vmcache-pools] Separate cap for child (sub agent) VMs.
    ///
    /// Bounds IDLE children only. A running child is never evicted, so the
    /// worst case of 6 parents x `ConcurrencyLimits.childJobsPerParent` (3) =
    /// 18 running children simply sits above this cap until they finish; each
    /// new child then sweeps finished ones, LRU first. That is the right thing
    /// to drop: a finished child's result already went to its parent (the
    /// completion paths hold the vm they need), its transcript is in SQLite,
    /// and reopening it rebuilds the vm. A child the user is looking at is
    /// pinned (`setOnScreen`). Kept at 10 rather than raised to 18: a higher cap
    /// would only keep more finished children's text in memory.
    static let childSoftCap: Int = 10

    init() {
        // Evict aggressively under memory pressure — same hook BrowserTabPool
        // and ThumbnailCache use. Drops every non-processing cached VM (and
        // its messages / history / parsed-markdown trees).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evictOnMemoryWarning() }
        }
    }
    /// Session IDs whose underlying SQLite rows were mutated by an
    /// inbound iCloud merge while the user was NOT on that session's
    /// chat screen. The next `getOrCreate` HIT for one of these IDs
    /// returns `isStale=true` so AIChatView can trigger a reload
    /// instead of rendering the cached `messages` snapshot. The set is
    /// consumed (drained) on read — a single reload pays off the debt.
    /// See ChatStore.mergeRemoteMessage for the producer side
    /// (T-inbound-message-cached-vm-stale).
    private var staleSessionIds: Set<String> = []

    /// Get an existing ViewModel for the session, or create and cache a new one.
    /// Returns `(vm, isNew)` — caller should only call `loadSession()` when `isNew` is true.
    /// For staleness-aware callers (e.g. AIChatView's init), additionally check
    /// `consumeStaleFlag(sessionId:)` AFTER this call and trigger a reload
    /// when it returns true.
    func getOrCreate(for sessionId: String, kind: PoolKind = .normal) -> (vm: AIChatViewModel, isNew: Bool) {
        // A session's pool is decided by whoever FIRST caches it, and then
        // sticks. HelperRunner passes `.child`; everyone else gets `.normal`
        // by default, so the 18 non-helper call sites needed no change.
        //
        // [T-vmcache-pool-sticky] Assign only when unset. The tag has to be
        // immune in BOTH directions, not just one:
        //
        //  • child → normal: HelperBlockView / HelperSheet open a child for
        //    VIEWING and must not thereby move it into the user's budget.
        //    Covered by only writing on `.child`.
        //  • normal → child: a `.child` call naming an ordinary session would
        //    have silently re-tagged it, moving a conversation the user owns
        //    into the sub agent pool — where it is swept against a different
        //    cap and, worse, released by HelperSheet's disappear handler.
        //    Reachable today: `debug.agent.openHelperSheet` takes an arbitrary
        //    `childSessionId` from the caller (DebugJSONRPC.swift:2833), and
        //    nothing downstream proves it is really a child.
        //
        // Whichever kind wins is therefore the one the session was first
        // created under, which is the only one with real information behind it.
        if poolKinds[sessionId] == nil, cache[sessionId] == nil,
           kind == .child || Self.isChildJobSession(sessionId) {
            // [T-limits-per-parent] A caller that did not say `.child` but is
            // creating the vm of a session a child job runs in (sessions-cli,
            // a debug RPC, any future caller) still gets the child pool: a sub
            // agent must never spend the user's conversation budget.
            poolKinds[sessionId] = .child
        }
        if let existing = cache[sessionId] {
            touch(sessionId)
            logger.info("🔄SESSION ViewModelCache HIT session=\(sessionId) vm=\(existing.vmInstanceId) isProcessing=\(existing.isProcessing)")
            return (existing, false)
        }
        let vm = AIChatViewModel()
        vm.sessionId = sessionId
        cache[sessionId] = vm
        touch(sessionId)
        // A brand-new cache entry doesn't need the stale signal — its
        // `isNew` path already triggers loadSession — clear any
        // accumulated marker so we don't carry it past a remove+recreate.
        staleSessionIds.remove(sessionId)
        let isStillActive = SessionActivityTracker.shared.activeSessions.contains(sessionId)
        logger.info("🔄SESSION ViewModelCache MISS session=\(sessionId) vm=\(vm.vmInstanceId) — created new, trackerActive=\(isStillActive)")
        if isStillActive {
            logger.warning("[BlocksLost] ViewModelCache MISS for tracker-active session \(sessionId.prefix(8)) — agent loop running on a different VM; new VM will pick up results via detachedLoopEnd notification")
        }
        evictIfOverCap(keeping: sessionId)
        return (vm, true)
    }

    /// Returns true if the given session was marked stale by an inbound
    /// iCloud merge since the cached VM last loaded, and consumes the
    /// flag in the same call so a single reload pays off the debt. Safe
    /// to call even when no VM is cached (returns false).
    func consumeStaleFlag(sessionId: String) -> Bool {
        staleSessionIds.remove(sessionId) != nil
    }

    /// Mark a cached session as having stale messages (e.g. iCloud merged
    /// new MessageV2 rows into SQLite). No-op when the session has no
    /// cached VM. When the session IS the foreground-visible one,
    /// `.cloudSyncDidFetchChanges` already drove an in-place reload via
    /// `reloadMessagesFromDB`, so this only matters for background
    /// sessions opened later (T-inbound-message-cached-vm-stale).
    func markStale(sessionId: String) {
        guard cache[sessionId] != nil else { return }
        staleSessionIds.insert(sessionId)
    }

    /// Get an existing cached ViewModel without creating a new one.
    func get(for sessionId: String) -> AIChatViewModel? {
        if cache[sessionId] != nil { touch(sessionId) }
        return cache[sessionId]
    }

    /// Remove a session's ViewModel from the cache (e.g. on session delete).
    /// Deliberately still a `cancel()`: this is session DELETION, where the
    /// conversation and its in-flight work really are meant to stop. Only the
    /// capacity-driven paths above were changed to release instead.
    func remove(sessionId: String) {
        lruOrder.removeAll { $0 == sessionId }
        poolKinds.removeValue(forKey: sessionId)
        if let removed = cache.removeValue(forKey: sessionId) {
            removed.cancel()
            logger.info("🔄SESSION ViewModelCache REMOVE session=\(sessionId) vm=\(removed.vmInstanceId)")
        }
    }

    /// Create a fresh (uncached) ViewModel for draft sessions (nil sessionId).
    func createDraft() -> AIChatViewModel {
        let vm = AIChatViewModel()
        logger.info("🔄SESSION ViewModelCache createDraft vm=\(vm.vmInstanceId)")
        return vm
    }

    // MARK: - Unsent new chats [OpenMinis#433]

    /// New chats the user left with something typed but never sent, keyed by
    /// the model group the chat was opened for ("" = none).
    ///
    /// A new chat has no session id, so its ViewModel is never in `cache` and
    /// its composer text died with the view: typing in a new chat and going
    /// back lost the text, while an existing session kept it (its cached VM
    /// holds `inputText`). Parking the VM gives a new chat the same memory-only
    /// draft lifetime as an existing session, and the next new chat opened for
    /// the same group picks it up. Deliberately not a session row: writing one
    /// per abandoned draft would fill the list with empty sessions.
    ///
    /// [OpenMinis#433 TTL] A parked draft is kept for `ParkedDrafts.lifetime`
    /// (15 minutes) from the moment it is parked, then dropped: a new chat
    /// opened hours later starts empty instead of showing stale text, and an
    /// abandoned draft (with its attachments) does not stay in memory.
    private var parkedNewChats = ParkedDrafts<AIChatViewModel>()

    /// The clock the parking slots read. Replaced in tests; never slept on.
    var parkedDraftClock: () -> Date = { Date() }

    // BEGIN ParkedDrafts
    /// Slots for unsent drafts, one per key, each with the time it was parked.
    struct ParkedDrafts<Value: AnyObject> {
        /// How long a parked draft stays available, counted from parking.
        /// The one place to change it.
        static var lifetime: TimeInterval { 15 * 60 }

        private var slots: [String: (value: Value, parkedAt: Date)] = [:]

        var count: Int { slots.count }

        /// Put `value` in `key`'s slot, stamped `now`. Parking again restarts
        /// its lifetime.
        mutating func park(_ value: Value, key: String, now: Date) {
            purgeExpired(now: now)
            slots[key] = (value, now)
        }

        /// Empty `key`'s slot if it holds `value` (or nothing): a draft the
        /// user cleared before leaving must not come back, and must not
        /// evict another chat's draft.
        mutating func clear(key: String, ifHolding value: Value, now: Date) {
            purgeExpired(now: now)
            if let held = slots[key]?.value, held !== value { return }
            slots[key] = nil
        }

        /// The draft parked for `key`, removed so it backs at most one view.
        /// nil when there is none or it is older than `lifetime` - an expired
        /// one is dropped here, along with every other expired slot.
        mutating func take(key: String, now: Date) -> Value? {
            purgeExpired(now: now)
            return slots.removeValue(forKey: key)?.value
        }

        /// Forget `value` wherever it is parked (it is on screen again).
        mutating func remove(_ value: Value, now: Date) {
            purgeExpired(now: now)
            for (key, slot) in slots where slot.value === value { slots[key] = nil }
        }

        /// Drop every slot parked more than `lifetime` ago. Returns how many.
        @discardableResult
        mutating func purgeExpired(now: Date) -> Int {
            let expired = slots.filter { now.timeIntervalSince($0.value.parkedAt) > Self.lifetime }.map(\.key)
            for key in expired { slots[key] = nil }
            return expired.count
        }
    }
    // END ParkedDrafts

    /// Park `vm` if it is a never-sent new chat holding text or attachments.
    /// A VM with nothing to keep clears its group's slot instead, so a draft
    /// the user emptied before leaving is not brought back later.
    func parkNewChatIfUnsent(_ vm: AIChatViewModel, groupId: String?) {
        guard vm.sessionId == nil, vm.remoteDeviceId == nil, !vm.isProcessing else { return }
        let key = groupId ?? ""
        let now = parkedDraftClock()
        if vm.hasUnsentDraft {
            parkedNewChats.park(vm, key: key, now: now)
            logger.info("🔄SESSION ViewModelCache parkNewChat vm=\(vm.vmInstanceId) group=\(key.isEmpty ? "-" : key) keptFor=\(Int(ParkedDrafts<AIChatViewModel>.lifetime))s")
        } else {
            parkedNewChats.clear(key: key, ifHolding: vm, now: now)
        }
    }

    /// The parked new chat for `groupId`, removed from the slot so it can only
    /// ever back one view. nil once it has been parked for longer than
    /// `ParkedDrafts.lifetime`.
    func takeParkedNewChat(groupId: String?) -> AIChatViewModel? {
        let before = parkedNewChats.count
        guard let vm = parkedNewChats.take(key: groupId ?? "", now: parkedDraftClock()) else {
            if parkedNewChats.count < before {
                logger.info("🔄SESSION ViewModelCache takeParkedNewChat — \(before - parkedNewChats.count) expired draft(s) dropped")
            }
            return nil
        }
        logger.info("🔄SESSION ViewModelCache takeParkedNewChat vm=\(vm.vmInstanceId)")
        return vm
    }

    /// Back on screen (e.g. a page pushed over the new chat was popped): it is
    /// in use again, so another new chat must not take it.
    func unparkNewChat(_ vm: AIChatViewModel) {
        parkedNewChats.remove(vm, now: parkedDraftClock())
    }

    /// Move a draft ViewModel into the cache once its session ID is assigned.
    func cacheDraft(_ vm: AIChatViewModel, sessionId: String) {
        cache[sessionId] = vm
        touch(sessionId)
        logger.info("🔄SESSION ViewModelCache cacheDraft session=\(sessionId) vm=\(vm.vmInstanceId)")
        evictIfOverCap(keeping: sessionId)
    }

    // MARK: - LRU eviction

    /// [T-limits-per-parent] Whether `sessionId` is the session of a child job
    /// (delegate_task or scheduled child-of-current) the registry knows.
    static func isChildJobSession(_ sessionId: String) -> Bool {
        AgentJobRegistry.shared.jobs.values.contains { $0.target.isChildOfCurrent && $0.runSessionId == sessionId }
    }

    /// [T-limits-per-parent] Sessions shown somewhere other than the main chat
    /// screen (which `AIChatViewModel.activeSessionId` covers) - today the sub
    /// agent transcript sheet. Counted, not a set: two surfaces may show the
    /// same session and each releases its own claim.
    private var onScreenClaims: [String: Int] = [:]

    func setOnScreen(_ sessionId: String, _ visible: Bool) {
        let n = (onScreenClaims[sessionId] ?? 0) + (visible ? 1 : -1)
        onScreenClaims[sessionId] = n > 0 ? n : nil
    }

    /// True while some surface shows `sessionId`. An on-screen vm is never
    /// evicted, and a sub agent vm skips render work only while this is false.
    func isOnScreen(_ sessionId: String) -> Bool {
        onScreenClaims[sessionId] != nil || sessionId == AIChatViewModel.activeSessionId
    }

    /// Pool sizes for diagnostics and tests: (normal, child) cached vm counts.
    var poolCounts: (normal: Int, child: Int) {
        let child = cache.keys.filter { poolKind($0) == .child }.count
        return (cache.count - child, child)
    }

    /// Mark a session as most-recently-used.
    private func touch(_ sessionId: String) {
        lruOrder.removeAll { $0 == sessionId }
        lruOrder.append(sessionId)
    }

    /// Evict least-recently-used, non-processing VMs down to `softCap`.
    /// A processing VM (running agent loop) is skipped — it must stay alive —
    /// so the resident count can briefly exceed the cap when many sessions are
    /// processing at once, which is intended.
    /// A VM must stay resident if its agent loop is running OR it's the
    /// session the user is currently viewing (evicting the foreground VM would
    /// drop its unsent input draft / scroll state and force a reload mid-view).
    private func isEvictable(_ sessionId: String, _ vm: AIChatViewModel) -> Bool {
        if vm.isProcessing { return false }
        if isOnScreen(sessionId) { return false }   // main chat screen or the sub agent sheet
        if SessionActivityTracker.shared.activeSessions.contains(sessionId) { return false }
        // [T-ios-evict-cancels-subagents] A parent whose own loop has ENDED but
        // which still has sub agents running in the background is NOT idle.
        //
        // `isProcessing` describes this VM's own agent loop only. The ordinary
        // background-delegation shape is: the parent delegates, finishes its
        // turn (isProcessing → false) and waits for the callback. Such a VM
        // looked evictable, and `evict` calls `vm.cancel()` — which is the full
        // user-Stop path, including `cancelAll(parent:)`. So an LRU sweep
        // silently killed live sub agents and logged them as
        // `reason=user stopped the conversation (silent)`, blaming a user who
        // had touched nothing.
        //
        // Observed: 22 evictions in one session, all `over softCap(6)`; job
        // 3CBA002A died 189s into a 30m budget this way, its parent reading
        // `isProcessing=false lastBlocks=4`.
        if AgentJobRegistry.shared.hasActiveChildren(parent: sessionId) { return false }
        return true
    }

    /// [T-vmcache-pools] Each pool is swept against its OWN cap, so a burst of
    /// sub agents can no longer evict the conversations the user is working in
    /// (and vice versa). Within a pool the order is still plain LRU.
    ///
    /// [T-limits-per-parent] `keeping` is the entry being handed back to the
    /// caller right now. It was just created, so it is not processing YET; when
    /// every other member of its pool is (18 running sub agents against a child
    /// cap of 10, or a full set of running / waiting conversations) it used to
    /// be the only evictable entry - evicted the moment it was created, while
    /// the caller went on to run it. The cache then had no record of a live
    /// run, and the next lookup built a second vm for the same session.
    private func evictIfOverCap(keeping: String? = nil) {
        evictPool(.normal, cap: Self.softCap, keeping: keeping)
        evictPool(.child, cap: Self.childSoftCap, keeping: keeping)
    }

    private func poolKind(_ sessionId: String) -> PoolKind {
        poolKinds[sessionId] ?? .normal
    }

    private func evictPool(_ kind: PoolKind, cap: Int, keeping: String? = nil) {
        let members = lruOrder.filter { poolKind($0) == kind && cache[$0] != nil }
        guard members.count > cap else { return }
        var overflow = members.count - cap
        // Walk LRU → MRU within this pool only.
        for sessionId in members where overflow > 0 {
            guard sessionId != keeping, let vm = cache[sessionId], isEvictable(sessionId, vm) else { continue }
            evict(sessionId, vm: vm, reason: "over \(kind.rawValue)Cap(\(cap))")
            overflow -= 1
        }
    }

    /// On a memory warning, drop every evictable cached VM (and its
    /// messages / agentHistory / parsed-markdown trees). Re-entering a
    /// session rebuilds its VM from SQLite.
    private func evictOnMemoryWarning() {
        let victims = cache.filter { isEvictable($0.key, $0.value) }
        for (sessionId, vm) in victims {
            evict(sessionId, vm: vm, reason: "memory warning")
        }
        // [T-renderer-cache-bounded] The renderers survive VM eviction (they
        // are keyed by message, on a static), so under real pressure they have
        // to be dropped explicitly or the warning frees far less than it looks.
        // Every VM that stays resident rebuilds its renderers lazily.
        let renderers = SelectableMarkdownView.dropAllRenderers()
        logger.info("🔄SESSION ViewModelCache memory-warning evicted \(victims.count) VM(s), \(self.cache.count) remain, dropped \(renderers) renderer(s)")
    }

    /// [T-vmcache-release] Evicting is a RELEASE, never a cancel.
    ///
    /// This line used to be `vm.cancel()` — the full user-Stop path, including
    /// `AgentJobRegistry.cancelAll(parent:silent:)`. A cache-size policy
    /// therefore reached through into the job registry and killed live sub
    /// agents, reporting them as a user stop (761be79da). `releaseForEviction`
    /// frees the same memory and touches no jobs.
    private func evict(_ sessionId: String, vm: AIChatViewModel, reason: String) {
        vm.releaseForEviction()
        cache.removeValue(forKey: sessionId)
        poolKinds.removeValue(forKey: sessionId)
        lruOrder.removeAll { $0 == sessionId }
        // Clearing the stale marker too — a rebuilt VM loads fresh from SQLite.
        staleSessionIds.remove(sessionId)
        logger.info("🔄SESSION ViewModelCache EVICT session=\(sessionId) vm=\(vm.vmInstanceId) (\(reason))")
    }

    // MARK: - Background UI Suspension

    /// Suspend streaming UI updates on ALL cached VMs that are actively
    /// processing. Called from MinisApp on scenePhase → .inactive so that
    /// no MarkdownRenderer layout work runs on the main thread while the
    /// app is transitioning to background — iOS can SIGKILL for excessive
    /// background CPU/rendering otherwise.
    func suspendAllStreamingUI() {
        for (_, vm) in cache where vm.isProcessing {
            vm.setStreamingUIUpdatesSuspended(true)
        }
    }

    /// [T-ios-stacknav-transition-attributegraph-race] Suspend every streaming
    /// vm across a WHOLE-TREE re-mount, then resume after `seconds`.
    ///
    /// Distinct from `suspendAllStreamingUI` above: that one sets the
    /// scroll/background THROTTLE (`streamingUIUpdatesSuspended`), this one
    /// sets the teardown GUARD (`transitionSuspended`), which is what keeps
    /// `objectWillChange` out of a hosting subgraph UIKit is destroying.
    ///
    /// The one caller is `MinisApp`'s `.id(appLanguage)` re-key: changing the
    /// app language drops and re-mounts the entire view tree, including a chat
    /// that may be mid-stream underneath the Settings sheet. That is the same
    /// race the two ContentView observers guard for push/pop, but there is no
    /// "outgoing session" to name — every mounted vm is outgoing — so it fans
    /// out over the cache.
    func suspendAllForTreeRemount(resumeAfter seconds: TimeInterval = 0.4) {
        var suspended: [AIChatViewModel] = []
        for (_, vm) in cache where vm.isProcessing {
            vm.setSuspendedForTransition(true)
            suspended.append(vm)
        }
        guard !suspended.isEmpty else { return }
        // Strong refs to the suspended vms are intentional: they must outlive
        // the window to be resumed, and the cache owns them regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            for vm in suspended { vm.setSuspendedForTransition(false) }
        }
    }

    /// Resume streaming UI updates on ALL cached VMs, flushing any chunks
    /// that accumulated while backgrounded. Called from MinisApp on
    /// scenePhase → .active so the user sees the latest content
    /// immediately on return.
    func resumeAllStreamingUI() {
        var cleared = 0
        for (_, vm) in cache where vm.streamingUIUpdatesSuspended {
            vm.setStreamingUIUpdatesSuspended(false)
            cleared += 1
        }
        // [T-ios-scroll-suspend-leak] Record how many VMs this foreground-return
        // pass unblocked. A leaked scroll-suspend that survived a switch-away
        // gets cleared here on the NEXT foreground return — so a nonzero count
        // long after backgrounding is a signal the leak occurred.
        if cleared > 0 {
            logger.info("[SuspendState] resumeAllStreamingUI cleared \(cleared) suspended VM(s)")
            // [T-ios-tool-status-desync] Nudge the session list to re-query
            // the DB so the row subtitle picks up any tool_use blocks that
            // were persisted while the app was suspended. The per-VM
            // objectWillChange above covers in-chat views; this covers the
            // session list whose lastMessage comes from a DB query triggered
            // by .sessionDidUpdate.
            for (sid, vm) in cache where vm.isProcessing {
                NotificationCenter.default.post(name: .sessionDidUpdate, object: sid)
            }
        }
    }

    // MARK: - Pending Transfer

    /// Stash for input content being moved to another session.
    ///
    /// [T-ios-moveto-transfer-race] `targetId` and `createdAt` are load-bearing.
    /// The slot used to hold content only, so whichever AIChatView appeared
    /// first consumed it — if the push to the intended target was swallowed by
    /// a transition race, the content landed in whatever session the user
    /// happened to open next, or sat in the slot until they opened the target
    /// by hand. Consumers must now match `targetId` before consuming, and
    /// treat an entry older than `staleAfter` as abandoned.
    struct PendingTransfer {
        let targetId: String
        let inputText: String
        let attachments: [InputAttachment]
        let createdAt: Date

        /// A transfer that was never consumed this long after being staged has
        /// missed its navigation; it must not ambush a later session.
        static let staleAfter: TimeInterval = 30

        var isStale: Bool { Date().timeIntervalSince(createdAt) > Self.staleAfter }

        init(targetId: String, inputText: String, attachments: [InputAttachment]) {
            self.targetId = targetId
            self.inputText = inputText
            self.attachments = attachments
            self.createdAt = Date()
        }
    }

    /// Set by MoveToSessionSheet, consumed by AIChatView on appear — but only
    /// by the view whose session id matches `targetId`.
    static var pendingTransfer: PendingTransfer?

    // MARK: - Move-to seed  [T-ios-moveto-seed]

    /// The most recent session list any surface has loaded, kept so the
    /// "Move to…" sheet can paint populated on its first frame instead of
    /// waiting on the ChatStore actor.
    ///
    /// Why it lives here rather than being read from `ChatStore`: that store is
    /// a real `actor`, so its `sessionListCache` cannot be read synchronously
    /// from the main actor. Exposing it `nonisolated` would hand out an array
    /// that DB writes mutate concurrently — a genuine data race, not a
    /// theoretical one. This holder is `@MainActor` (the whole type is), so
    /// both the write and the read happen on the main actor and no isolation is
    /// crossed at all.
    ///
    /// Deliberately a plain snapshot, not a second source of truth: it is only
    /// ever used as a first-frame placeholder, and the sheet's own `.task`
    /// overwrites it with the authoritative query a moment later. Staleness is
    /// therefore bounded by one frame of display, and a wrong row corrects
    /// itself before it can be tapped in any realistic timing.
    private(set) static var recentSessionsSeed: [ChatSession] = []

    /// Record a freshly-loaded list as the seed. Callers pass whatever they
    /// just fetched; the child-session filter is applied here so every writer
    /// cannot forget it (child sessions are never move targets).
    static func noteSessionsLoaded(_ sessions: [ChatSession]) {
        let visible = sessions.filter { !$0.isChild }
        guard !visible.isEmpty else { return }   // never replace a good seed with nothing
        recentSessionsSeed = Array(visible.prefix(MoveToSeedLimit))
    }

    /// Cap on the stored seed. Matches the sheet's own `recentLimit`: holding
    /// more would just be retained memory the picker never shows.
    static let MoveToSeedLimit = 50

    /// Drop a staged transfer, deleting any attachment files it still owns so a
    /// discarded move doesn't leak cache entries.
    static func discardPendingTransfer(reason: String) {
        guard let transfer = pendingTransfer else { return }
        pendingTransfer = nil
        for a in transfer.attachments {
            try? FileManager.default.removeItem(at: a.cacheURL)
        }
        logger.info("[MoveTo] Discarded pending transfer for target=\(transfer.targetId) reason=\(reason)")
    }
}

