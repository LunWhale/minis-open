//
//  AlwaysOnController.swift
//  MinisApp
//
//  [T-always-on] Always On mode: while the chat on screen runs an agent task,
//  keep the screen on, and — when the Screen Saver is on — after the chosen
//  idle time without a touch cover the app with a black screen that shows only
//  the current step (AlwaysOnOverlay). A tap anywhere returns. Part of Keep
//  Screen Awake: the global switch is its `keepScreenAwakeDuringTasks` key
//  (Appearance, `chat.keepScreenAwake`), and the chat's … menu can override it
//  for one chat.
//
//  [T-keep-awake-sticky-off] The per-chat override is the user's choice for
//  that chat and is saved (UserDefaults `sessionOverridesKey`): it survives
//  leaving the chat and relaunching. It used to live in memory and be dropped
//  whenever the user left the chat, so with Keep Screen Awake on in Settings a
//  chat switched off from its … menu was back on the next time it was opened
//  (TestFlight report 2026-09-28: "turned it off and it turns itself back on").
//
//  [T-always-on-idle-setting] The Screen Saver is a sub-setting of Keep Screen
//  Awake: `alwaysOnIdleSeconds` (`chat.alwaysOnIdleSeconds`), Off by default,
//  or 30 s / 1 / 2 / 5 min. Off keeps everything else — the screen is still
//  held (a chat switched on from its … menu relies on this lease) — and only
//  the black screen never comes.
//
//  [T-always-on-now] "Use Screen Saver" in a chat's … menu (under "Keep
//  Screen On"): this chat keeps the screen awake AND uses the Screen Saver
//  (even if it is Off in Settings). Held in `screenSaverNowKey`, layered over
//  — never written into — the per-chat override and the idle setting, so when
//  it is switched off or the user leaves the chat, both come back exactly as
//  they were.
//
//  [T-keepawake-submenu] It can be chosen at any time. It used to be "this
//  run only": the row was disabled with no task running and the choice ended
//  with the task, which users read as a broken button. Now it lasts until the
//  user unchecks it (or "Keep Screen On") or leaves the chat. Chosen during a
//  run, the screen goes black right away; chosen while idle, nothing happens
//  until this chat runs a task, then the idle timer (Settings' delay, or
//  `forcedIdleDelay` when Settings is Off) turns it black — the black screen
//  shows the current step, so there is nothing to show without a run, and
//  going black the instant the user presses Send would hide the reply start.
//
//  The screen is held from the moment the task starts, not after the idle
//  time: iOS Auto-Lock can be as short as 30 s and dims the screen before
//  locking, so waiting for the overlay would lock or dim the phone first.
//
//  This class decides; AlwaysOnWindowPresenter draws. State:
//    watching - the visible chat's switch is on, nothing running
//    armed    - running: lease .alwaysOn held; the idle timer runs if the
//               Screen Saver is on
//    showing  - armed and idle for the chosen time, no blocker: overlay visible
//  A task ending, leaving the chat, the app leaving the foreground or the
//  switch turning off hides the overlay and gives the lease back.
//

import UIKit
import Combine

@MainActor
final class AlwaysOnController: ObservableObject {
    static let shared = AlwaysOnController()

    /// [T-always-on-idle-setting] Seconds without a touch before the black
    /// screen; 0 (or unset) = Screen Saver off. Written by Appearance and
    /// `minis-config set chat.alwaysOnIdleSeconds`.
    static let idleSecondsKey = "alwaysOnIdleSeconds"
    /// What Settings offers, in seconds. 0 = Off, the default: a black screen
    /// taking over the chat is surprising unless the user asked for it.
    static let idleChoices = [0, 30, 60, 120, 300]

    /// Idle time before the black screen, or nil when the Screen Saver is off.
    static var idleDelay: TimeInterval? {
        let seconds = UserDefaults.standard.integer(forKey: idleSecondsKey)
        return seconds > 0 ? TimeInterval(seconds) : nil
    }

    private let logger = AppLogger(category: "AlwaysOn")

    /// What the overlay shows, refreshed once a second while it is up.
    struct Snapshot: Equatable {
        var toolName = ""
        /// The model's tool_title for the running step (SessionActivityTracker
        /// stores it as `toolStatus`); "" before the first tool.
        var toolTitle = ""
        var sessionTitle = ""
        var runningSince: Date?
    }

    @Published private(set) var isShowing = false
    @Published private(set) var snapshot = Snapshot()
    /// Seconds since the overlay appeared; drives its 1 Hz redraw (elapsed
    /// time, pulse, drift every 15 ticks). A RunLoop timer here rather than a
    /// SwiftUI Timer.publish in the view: a graph-bound Timer.publish was
    /// released mid-transaction before (sidebar migration-timer UAF).
    @Published private(set) var tick = 0
    /// Each title stays at least this long, so fast tool calls do not flicker.
    static let minTitleDuration: TimeInterval = 2
    private var lastTitleChange = Date.distantPast
    /// Per-chat override from the … menu, keyed like visibleKey (session id, or
    /// the draft id before the first send). [T-keep-awake-sticky-off] Saved
    /// under `sessionOverridesKey`, so it lasts until the user changes it.
    @Published private(set) var sessionOverrides: [String: Bool] = [:] {
        didSet { Self.saveOverrides(sessionOverrides) }
    }
    static let sessionOverridesKey = "alwaysOn.sessionOverrides"
    /// Enough for every chat a user realistically toggles; keeps the saved
    /// dictionary bounded if chats come and go for years.
    static let maxSavedOverrides = 500
    /// The switch for the chat on screen, for its … menu checkmark. Published
    /// only when it changes (a global flip, `minis-config set`, the menu).
    @Published private(set) var visibleEffective = false

    /// [T-always-on-now] The chat "Use Screen Saver" is on for (its session or
    /// draft id), until the user switches it off or leaves the chat.
    @Published private(set) var screenSaverNowKey: String?
    /// The … menu row's checkmark, published only when it changes.
    @Published private(set) var visibleScreenSaverNow = false
    /// Idle time before going black again after the user taps out, when the
    /// menu forced the Screen Saver on while Settings has it Off.
    static let forcedIdleDelay: TimeInterval = 30

    /// Session id (or draft id before the first send) of the chat on screen.
    private(set) var visibleKey: String?

    private var lastActivity = Date()
    private var appInBackground = false
    private var appActive = true
    private var idleTask: Task<Void, Never>?
    /// The delay the pending idle timer was scheduled with, so a change in
    /// Settings (or turning the Screen Saver off) takes effect at once.
    private var scheduledDelay: TimeInterval?
    private var tickTimer: Timer?
    private var runStart: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private let monitor = UserActivityMonitor()
    private var started = false

    private init() {
        sessionOverrides = Self.loadOverrides()
    }

    private static func loadOverrides() -> [String: Bool] {
        (UserDefaults.standard.dictionary(forKey: sessionOverridesKey) as? [String: Bool]) ?? [:]
    }

    private static func saveOverrides(_ overrides: [String: Bool]) {
        var bounded = overrides
        if bounded.count > maxSavedOverrides {
            for key in bounded.keys.sorted().prefix(bounded.count - maxSavedOverrides) {
                bounded.removeValue(forKey: key)
            }
        }
        let stored = UserDefaults.standard.dictionary(forKey: sessionOverridesKey) as? [String: Bool]
        guard stored != bounded else { return }   // no didChange storm on no-op writes
        UserDefaults.standard.set(bounded, forKey: sessionOverridesKey)
    }

    /// The … menu's choice for this chat, looked up under its draft id and its
    /// real session id alike (the two name one chat around the first send).
    private func override(for key: String) -> Bool? {
        if let v = sessionOverrides[key] { return v }
        let aliases = SessionActivityTracker.shared.draftAliases
        if let real = aliases[key], let v = sessionOverrides[real] { return v }
        return sessionOverrides.first { aliases[$0.key] == key }?.value
    }

    // MARK: Switches

    /// The global switch: Keep Screen Awake.
    static var globalEnabled: Bool {
        UserDefaults.standard.bool(forKey: KeepScreenAwakeController.userDefaultsKey)
    }

    /// Screen Saver Now, else the per-chat override if there is one, else the
    /// global switch.
    func effective(for key: String?) -> Bool {
        guard let key else { return false }
        if isScreenSaverNow(key) { return true }
        return override(for: key) ?? Self.globalEnabled
    }

    private func isScreenSaverNow(_ key: String?) -> Bool {
        guard let key, let now = screenSaverNowKey else { return false }
        if key == now { return true }
        let aliases = SessionActivityTracker.shared.draftAliases
        return aliases[key] == now || aliases[now] == key
    }

    /// Idle time for the chat on screen: Settings' Screen Saver, forced on
    /// (never Off) while Screen Saver Now is on for it.
    private var visibleIdleDelay: TimeInterval? {
        if isScreenSaverNow(visibleKey) { return Self.idleDelay ?? Self.forcedIdleDelay }
        return Self.idleDelay
    }

    // MARK: Screen Saver Now (… menu)

    /// "Use Screen Saver" chosen (or unchecked) in the chat's … menu. Any time
    /// ([T-keepawake-submenu]): during a run it goes black right away,
    /// otherwise it waits for this chat's next task (see the file header).
    func setScreenSaverNow(_ on: Bool, for key: String) {
        guard on else {
            clearScreenSaverNow(reason: "menu off")
            return
        }
        screenSaverNowKey = key
        logger.info("[AlwaysOn] screen saver now ON \(key.prefix(8)) running=\(SessionActivityTracker.shared.isActive(key))")
        refresh(reason: "screen saver now")
        KeepScreenAwakeController.shared.refresh(reason: "screen saver now")
        // During a run: straight to black, no idle wait — after the menu's own
        // touch has finished: the activity monitor sees that touch and would
        // take a black screen shown during it straight down again. With no
        // run, showNow() is a no-op (not armed) and the idle timer takes over
        // once a task starts.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            let c = AlwaysOnController.shared
            guard c.screenSaverNowKey == key, c.isScreenSaverNow(c.visibleKey) else { return }
            c.showNow()
        }
    }

    private func clearScreenSaverNow(reason: String) {
        guard screenSaverNowKey != nil else { return }
        screenSaverNowKey = nil
        logger.info("[AlwaysOn] screen saver now OFF reason=\(reason)")
        refresh(reason: "screen saver now off")
        KeepScreenAwakeController.shared.refresh(reason: "screen saver now off")
    }

    private func showNow() {
        guard isArmed, appActive, !isShowing else { return }
        if let blocker {
            logger.info("[AlwaysOn] screen saver now: not showing yet (\(blocker)), idle timer takes over")
            return
        }
        idleTask?.cancel()
        idleTask = nil
        show()
    }

    func setSessionOverride(_ on: Bool, for key: String) {
        sessionOverrides[key] = on
        logger.info("[AlwaysOn] override \(key.prefix(8))=\(on)")
        // [T-keep-awake-sticky-off] Off means off: "Use Screen Saver" outranks
        // the override in effective(), so while it was on for this chat,
        // unchecking "Keep Screen On" changed nothing and the checkmark came
        // straight back. Unchecking it clears both.
        if !on, isScreenSaverNow(key) { clearScreenSaverNow(reason: "this chat off") }
        refresh(reason: "override")
        // The menu's "off" must also stop Keep Screen Awake's any-session lock
        // for this chat, or the switch would look broken.
        KeepScreenAwakeController.shared.refresh(reason: "override")
    }

    /// Switched off for this chat from its … menu (session or draft id).
    /// KeepScreenAwakeController leaves such sessions out.
    func isOverriddenOff(_ sessionId: String) -> Bool {
        if isScreenSaverNow(sessionId) { return false }
        return override(for: sessionId) == false
    }

    /// The selected chat changed (or the stack popped to the list, `key` nil).
    /// [T-always-on-now] Screen Saver Now belongs to the chat it was chosen
    /// in, so leaving that chat ends it. [T-keep-awake-sticky-off] The
    /// per-chat override is NOT touched: it is the user's saved choice.
    func chatSelectionChanged(to key: String?) {
        if screenSaverNowKey != nil, !isScreenSaverNow(key) {
            clearScreenSaverNow(reason: "left chat")
        }
    }

    // MARK: Chat on screen (AIChatView)

    func chatAppeared(key: String?) {
        visibleKey = key
        lastActivity = Date()
        refresh(reason: "appear")
    }

    func chatDisappeared(key: String?) {
        guard visibleKey == key else { return }
        visibleKey = nil
        refresh(reason: "disappear")
    }

    /// A draft got its real session id on the first send: keep its override
    /// and its place on screen.
    func chatKeyChanged(from old: String?, to new: String) {
        if let old, old != new, let value = sessionOverrides.removeValue(forKey: old) {
            sessionOverrides[new] = value
        }
        if let old, old != new, screenSaverNowKey == old { screenSaverNowKey = new }
        if visibleKey == old || visibleKey == nil { visibleKey = new }
        refresh(reason: "key change")
    }

    // MARK: Activity

    /// Any touch, keystroke or keyboard change; also the tap that closes the overlay.
    func userActivity() {
        lastActivity = Date()
        if isShowing { hide(reason: "activity") }
        if isArmed { scheduleIdle() }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        SessionActivityTracker.shared.$activeSessions
            .receive(on: DispatchQueue.main)
            .sink { _ in AlwaysOnController.shared.refresh(reason: "tracker") }
            .store(in: &cancellables)
        SessionLockStore.shared.$appIsLocked
            .receive(on: DispatchQueue.main)
            .sink { _ in AlwaysOnController.shared.refresh(reason: "app lock") }
            .store(in: &cancellables)
        let center = NotificationCenter.default
        // Keep Screen Awake written from Settings or `minis-config set chat.keepScreenAwake`.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AlwaysOnController.shared.refresh(reason: "defaults") }
        })
        observers.append(center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AlwaysOnController.shared.refresh(reason: "voiceover") }
        })
        // Background: synchronous, like KeepScreenAwakeController (no view-graph risk).
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = AlwaysOnController.shared
                c.appInBackground = true
                c.refresh(reason: "background")
            }
        })
        // Control Center, an incoming call, the app switcher: hide, keep the lease.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = AlwaysOnController.shared
                c.appActive = false
                c.idleTask?.cancel()
                c.idleTask = nil   // refresh() only schedules when none is pending
                if c.isShowing { c.hide(reason: "resign active") }
            }
        })
        // Coming back: deferred off the notification ([T-ios-scenephase-active-sigkill]).
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await Task.yield()
                let c = AlwaysOnController.shared
                c.appActive = true
                c.appInBackground = false
                c.lastActivity = Date()
                c.refresh(reason: "active")
            }
        })
        monitor.start { AlwaysOnController.shared.userActivity() }
        AlwaysOnWindowPresenter.shared.start()
        refresh(reason: "start")
    }

    // MARK: State

    private var runningKey: String? {
        guard let key = visibleKey, SessionActivityTracker.shared.isActive(key) else { return nil }
        return key
    }

    /// Conditions for holding the screen on (step `armed`).
    private var isArmed: Bool {
        !ProcessInfo.processInfo.isiOSAppOnMac
            && !UIAccessibility.isVoiceOverRunning
            && !appInBackground
            && !SessionLockStore.shared.appIsLocked
            && effective(for: visibleKey)
            && runningKey != nil
    }

    /// Something the user must see or is doing that a black screen would hide.
    private var blocker: String? {
        if SpeechRecognitionManager.shared.state == .recording { return "dictation" }
        if Self.alertIsPresented() { return "alert" }
        return nil
    }

    func refresh(reason: String) {
        // [T-keepawake-submenu] Screen Saver Now no longer ends with the task:
        // it lasts until switched off or the user leaves the chat.
        let nowVisible = isScreenSaverNow(visibleKey)
        if nowVisible != visibleScreenSaverNow { visibleScreenSaverNow = nowVisible }
        let visible = effective(for: visibleKey)
        if visible != visibleEffective { visibleEffective = visible }
        let armed = isArmed
        IdleTimerLease.set(.alwaysOn, held: armed, reason: reason)
        if let key = runningKey {
            if runStart[key] == nil { runStart[key] = Date() }
        }
        runStart = runStart.filter { SessionActivityTracker.shared.isActive($0.key) }
        guard armed else {
            idleTask?.cancel()
            idleTask = nil
            if isShowing { hide(reason: reason) }
            return
        }
        // [T-always-on-idle-setting] A new idle time restarts the pending timer;
        // Off cancels it and takes down a black screen already up.
        let idle = visibleIdleDelay
        if idle != scheduledDelay {
            idleTask?.cancel()
            idleTask = nil
            scheduledDelay = idle
        }
        guard idle != nil else {
            if isShowing { hide(reason: "screen saver off") }
            return
        }
        // didChangeNotification fires for every key the app writes: only start
        // a timer when none is pending, activity restarts it explicitly.
        if !isShowing, idleTask == nil { scheduleIdle() }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard let idle = visibleIdleDelay else { return }   // Screen Saver off
        scheduledDelay = idle
        let delay = max(0, lastActivity.addingTimeInterval(idle).timeIntervalSinceNow)
        idleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            AlwaysOnController.shared.idleTimerFired()
        }
    }

    private func idleTimerFired() {
        idleTask = nil
        guard isArmed, appActive, !isShowing, let idle = visibleIdleDelay else { return }
        guard Date().timeIntervalSince(lastActivity) >= idle - 0.05 else { scheduleIdle(); return }
        if let blocker {
            // Try again a full delay later rather than polling.
            logger.info("[AlwaysOn] not showing: \(blocker)")
            lastActivity = Date()
            scheduleIdle()
            return
        }
        show()
    }

    private func show() {
        tick = 0
        lastTitleChange = .distantPast
        updateSnapshot()
        isShowing = true
        logger.info("[AlwaysOn] show sid=\(visibleKey?.prefix(8) ?? "nil") idle=\(Int(visibleIdleDelay ?? 0))s now=\(isScreenSaverNow(visibleKey))")
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AlwaysOnController.shared.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func hide(reason: String) {
        tickTimer?.invalidate()
        tickTimer = nil
        isShowing = false
        logger.info("[AlwaysOn] hide reason=\(reason)")
    }

    private func onTick() {
        guard isShowing else { return }
        if let blocker {
            // An alert appeared under the overlay: get out of its way.
            hide(reason: blocker)
            lastActivity = Date()
            if isArmed { scheduleIdle() }
            return
        }
        tick += 1
        updateSnapshot()
    }

    private func updateSnapshot() {
        guard let key = visibleKey else { return }
        let tracker = SessionActivityTracker.shared
        let realId = tracker.draftAliases[key] ?? key
        let info = tracker.sessionToolInfo[realId]
        var next = Snapshot(toolName: info?.toolName ?? "",
                            toolTitle: info?.toolStatus ?? "",
                            sessionTitle: info?.title ?? "",
                            runningSince: runStart[key])
        if next.toolName != snapshot.toolName || next.toolTitle != snapshot.toolTitle {
            if Date().timeIntervalSince(lastTitleChange) < Self.minTitleDuration {
                next.toolName = snapshot.toolName
                next.toolTitle = snapshot.toolTitle
            } else {
                lastTitleChange = Date()
            }
        }
        if next != snapshot { snapshot = next }
    }

    /// A UIAlertController (SwiftUI .alert / .confirmationDialog included) on
    /// any foreground window's presentation chain.
    private static func alertIsPresented() -> Bool {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive {
            for window in scene.windows where !(window is AlwaysOnExcludedWindow) {
                var vc = window.rootViewController?.presentedViewController
                while let current = vc {
                    if current is UIAlertController { return true }
                    vc = current.presentedViewController
                }
            }
        }
        return false
    }
}
