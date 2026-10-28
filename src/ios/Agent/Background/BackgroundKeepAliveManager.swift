import ActivityKit
import AVFoundation
import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import SwiftUI
import UserNotifications
import os.log

private let logger = AppLogger(category: "BackgroundKeepAlive")

// MARK: - Background Keep Alive Manager

@MainActor
final class BackgroundKeepAliveManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAliveManager()

    /// True when there are active sessions and enhanced background is enabled.
    /// Used by `waitIfBackgroundSuspended()` to skip suspension.
    @Published private(set) var isActive = false

    /// [T-keepalive-survival-tier] Background-survival capability shown in
    /// Settings → Background → Status. Independent of whether a task is
    /// running right now — it answers "if the app backgrounds at this moment,
    /// how long can it keep working": every iOS app gets only the standard
    /// ~30s grace window unless one of the long-lived legs is enabled.
    enum BackgroundSurvivalTier: Equatable {
        /// Only the standard iOS background grace window (~30 seconds).
        case short
        /// Long-lived, via whichever legs are currently enabled:
        /// location = enhanced background (coarse-location heartbeat, needs
        /// permission); audio = background audio session (TTS / playback).
        case extended(location: Bool, audio: Bool)
    }

    /// Whether the background-location leg can run at all on this OS.
    ///
    /// [T-bg-location-os-floor] The leg is implemented with
    /// `CLBackgroundActivitySession` + `CLLocationUpdate.liveUpdates`, both
    /// iOS 17+, and there is deliberately no iOS 16 fallback (the classic
    /// `startUpdatingLocation` path was removed rather than left half-working).
    /// Before this existed, `survivalTier` still reported
    /// `.extended(location: true)` on iOS 16 whenever the toggles + permission
    /// looked right — a green "Extended (Location)" badge over a leg that
    /// cannot start, i.e. a false success signal in exactly the screen users
    /// go to when background execution seems broken.
    static var backgroundLocationLegAvailable: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// Reactive: all inputs are @Published on this ObservableObject, so the
    /// Settings row re-renders on toggle/permission changes automatically.
    var survivalTier: BackgroundSurvivalTier {
        let locationLeg = enhancedBackgroundEnabled
            && Self.backgroundLocationLegAvailable
            && (locationAuthStatus == .authorizedAlways || locationAuthStatus == .authorizedWhenInUse)
        let audioLeg = backgroundSpeakEnabled
        if locationLeg || audioLeg {
            return .extended(location: locationLeg, audio: audioLeg)
        }
        return .short
    }

    @Published var enhancedBackgroundEnabled: Bool = UserDefaults.standard.bool(forKey: "enhancedBackgroundExecution") {
        didSet {
            UserDefaults.standard.set(enhancedBackgroundEnabled, forKey: "enhancedBackgroundExecution")
            // Turning on the master switch also opts the user into
            // Background Speak — without it, TTS narration cuts off the
            // instant the app backgrounds, which defeats the typical
            // "enable enhanced background so my long task can keep
            // narrating" intent users have when flipping this from the
            // interruption banner. Off → on only; flipping the master
            // back off leaves Background Speak alone so the user's
            // own choice isn't clobbered (T-enhanced-bg-auto-speak).
            if enhancedBackgroundEnabled && !backgroundSpeakEnabled {
                backgroundSpeakEnabled = true
            }
        }
    }

    @Published var locationTrackingEnabled: Bool = UserDefaults.standard.bool(forKey: "locationTrackingEnabled") {
        didSet { UserDefaults.standard.set(locationTrackingEnabled, forKey: "locationTrackingEnabled") }
    }

    /// [T-live-activity-toggle] User switch for the agent-progress Live
    /// Activity (Lock Screen / Dynamic Island). Defaults to ON — the key is
    /// absent until the user first flips it, so read via object(forKey:).
    /// AgentLiveActivityManager gates its start/update entry points on this;
    /// flipping OFF also tears down any currently-displayed activity so the
    /// Lock Screen doesn't keep a stale card.
    @Published var liveActivityEnabled: Bool = (UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool) ?? true {
        didSet {
            guard liveActivityEnabled != oldValue else { return }
            UserDefaults.standard.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            if liveActivityEnabled {
                // Re-enabled mid-task: restore the activity for any running sessions.
                updateLiveActivityIfNeeded(source: "liveActivityToggleOn")
            } else {
                AgentLiveActivityManager.shared.endActivity()
            }
        }
    }

    @Published var backgroundSpeakEnabled: Bool = UserDefaults.standard.bool(forKey: "backgroundSpeakEnabled") {
        didSet {
            UserDefaults.standard.set(backgroundSpeakEnabled, forKey: "backgroundSpeakEnabled")
            // Turning audio on mid-run ends the continued-task fallback; off starts it.
            evaluateContinuedProcessing(caller: "backgroundSpeakToggle")
        }
    }

    /// True only when the configuration can actually keep the app alive in the
    /// background. The master switch alone is not enough: silent-audio
    /// keep-alive (the mechanism that prevents background-task expiry) only
    /// plays when Background Speak is also on (see `evaluateSilentAudio`).
    /// So "master on but Background Speak off" still gets interrupted — and
    /// must be treated as "enhanced background NOT effective" everywhere we
    /// decide whether to count interruptions / surface the reminder banner.
    var enhancedBackgroundEffective: Bool {
        enhancedBackgroundEnabled && backgroundSpeakEnabled
    }

    /// When enabled, posts local notifications when agent tasks start and complete.
    @Published var backgroundNotificationsEnabled: Bool = {
        // Default to true if key hasn't been set
        UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "backgroundNotificationsEnabled")
    }() {
        didSet { UserDefaults.standard.set(backgroundNotificationsEnabled, forKey: "backgroundNotificationsEnabled") }
    }

    /// [T-ios-live-activity-privacy-mode] When enabled, the Live Activity, the
    /// Dynamic Island and background task notifications stop surfacing session
    /// content — no session title, tool status/icon or reply summary. They
    /// degrade to a neutral progress report: completed/total task count plus the
    /// elapsed timer.
    ///
    /// Deliberately NOT related to the pre-existing `envvars.privacyMode`
    /// (ConfigRegistry / EnvVarPrivacyStore), which masks environment-variable
    /// values in the config UI — different concept, hence the distinct
    /// `liveActivityPrivacyMode` key to avoid conflation.
    ///
    /// Defaults to OFF so existing installs keep their current behavior.
    @Published var liveActivityPrivacyMode: Bool =
        UserDefaults.standard.bool(forKey: "liveActivityPrivacyMode") {
        didSet { UserDefaults.standard.set(liveActivityPrivacyMode, forKey: "liveActivityPrivacyMode") }
    }

    /// [T-bka-continued-setting] Settings › Background: "Prefer Continued
    /// Background Processing (iOS 26+)". Off (default): the location keep-alive
    /// refreshes the Live Activity, no continued task. On: every run started in
    /// the foreground gets a BGContinuedProcessingTask, which keeps the Live
    /// Activity refreshing instead of location (see continuedMode). Toggling
    /// it mid-run completes / submits the task and re-evaluates location.
    static let continuedPreferredKey = "continuedProcessingPreferred"
    @Published var continuedProcessingPreferred: Bool =
        (UserDefaults.standard.object(forKey: BackgroundKeepAliveManager.continuedPreferredKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(continuedProcessingPreferred, forKey: Self.continuedPreferredKey)
            logger.info("[BKA][Continued] setting preferred=\(continuedProcessingPreferred)")
            evaluateContinuedProcessing(caller: "settingToggle")
            evaluateLocationUpdates()
            evaluateBackgroundActivitySession()
        }
    }

    // MARK: - Speech Settings

    /// Speech rate (0.0–1.0). Default is AVSpeechUtteranceDefaultSpeechRate (0.5).
    @Published var speechRate: Float = UserDefaults.standard.object(forKey: "speechRate") as? Float ?? AVSpeechUtteranceDefaultSpeechRate {
        didSet { UserDefaults.standard.set(speechRate, forKey: "speechRate") }
    }

    /// Pitch multiplier (0.5–2.0). Default is 1.0.
    @Published var speechPitch: Float = UserDefaults.standard.object(forKey: "speechPitch") as? Float ?? 1.0 {
        didSet { UserDefaults.standard.set(speechPitch, forKey: "speechPitch") }
    }

    /// Volume (0.0–1.0). Default is 1.0. [T-readaloud-volume] The read-aloud
    /// volume (`ReadAloudVolume`, same key); kept in step with the read-aloud
    /// capsule's slider (`VoiceOutputState.readAloudVolume`).
    @Published var speechVolume: Float = ReadAloudVolume.read(UserDefaults.standard) {
        didSet {
            ReadAloudVolume.write(speechVolume, to: UserDefaults.standard)
            let live = VoiceOutputState.shared
            if live.readAloudVolume != speechVolume { live.readAloudVolume = speechVolume }
        }
    }

    /// Voice identifier for Chinese TTS. nil = system default.
    @Published var speechVoiceZh: String = UserDefaults.standard.string(forKey: "speechVoiceZh") ?? "" {
        didSet { UserDefaults.standard.set(speechVoiceZh, forKey: "speechVoiceZh") }
    }

    /// Voice identifier for English TTS. nil = system default.
    @Published var speechVoiceEn: String = UserDefaults.standard.string(forKey: "speechVoiceEn") ?? "" {
        didSet { UserDefaults.standard.set(speechVoiceEn, forKey: "speechVoiceEn") }
    }

    /// Reset all speech settings to defaults.
    func resetSpeechSettings() {
        speechRate = AVSpeechUtteranceDefaultSpeechRate
        speechPitch = 1.0
        speechVolume = 1.0
        speechVoiceZh = ""
        speechVoiceEn = ""
    }

    /// Build a voice for the given language, respecting user's voice selection.
    func voiceForLanguage(_ lang: String) -> AVSpeechSynthesisVoice? {
        let identifier = lang.hasPrefix("zh") ? speechVoiceZh : speechVoiceEn
        if !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: lang)
    }

    @Published private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined

    /// Timer for periodic Live Activity updates.
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// [T-ios-scene-create-watchdog-corelocation] `lazy`, not a stored `let`:
    /// allocating a CLLocationManager opens a connection to locationd, so a
    /// plain stored property would drag that IPC into this singleton's `init()`
    /// — i.e. into whatever thread first touches `.shared`. Created on first
    /// real use (from `configureLocationManager()` onward), never at init.
    private lazy var locationManager = CLLocationManager()
    private var locationUpdating = false
    private var locationTimer: Timer?
    private var appIsInBackground = false

    // MARK: - Continued processing (iOS 26+) [T-bka-continued-processing]
    /// The running BGContinuedProcessingTask (iOS 26+), as Any so the stored
    /// property needs no availability.
    private var continuedTask: Any?
    /// Identifier of a submitted request whose task has not started yet.
    private var continuedPendingId: String?
    private var continuedProgressTimer: Timer?
    /// Released when the continued task is completed; the launch handler's
    /// thread waits on it, so the handler does not return while the task runs.
    private var continuedHandlerHold: DispatchSemaphore?
    /// Set when this run's continued task could not be submitted or expired:
    /// no second request is made for the rest of the run. Reset per run.
    private var continuedUnavailableThisRun = false
    /// [T-bka-continued-retry-foreground] The request was skipped only because
    /// the app was not in the foreground (the system refuses it there). Unlike
    /// `continuedUnavailableThisRun` this is not a failure: ask again the next
    /// time the app becomes active while the run is still going.
    private var continuedAwaitingForeground = false
    /// Whether any session is busy - a "run" for the continued task, which
    /// (unlike isActive) does not depend on Enhanced Background being on.
    private var continuedBusy = false
    /// One-shot callbacks for when the continued task ends before the run
    /// does (expired, stopped by the user, or no longer needed). See
    /// onContinuedTaskEndedMidRun.
    private var continuedEndCallbacks: [() -> Void] = []
    /// [T-bka-continued-hint] Last progress tick at which the continued task
    /// was holding the app in the background. A foreground return compares it
    /// with its own background-entry time to tell whether the period that just
    /// ended ran on the (slow) continued task.
    private(set) var continuedLastBackgroundTick: Date?

    // MARK: - CLBackgroundActivitySession (iOS 17+)
    private var bgActivitySession: Any?
    private var liveUpdatesTask: Task<Void, Never>?
    private var lastLocationLAUpdate: Date = .distantPast

    /// When the app last entered the background (diagnostics only).
    private var backgroundEnteredAt: Date?
    private static let locationLAMinInterval: TimeInterval = 5.0

    /// [T-ios-bg-location-arm-delay] Gate for background location keep-alive.
    /// Location updates + the CLBackgroundActivitySession only start once this
    /// is true, which happens `backgroundLocationArmDelay` seconds AFTER the app
    /// enters the background — so a brief background blip (or normal foreground
    /// use) never spins up location at all. Reset to false on foreground return.
    private var backgroundLocationArmed = false
    private var backgroundLocationArmTimer: Timer?
    /// How long to wait after backgrounding before arming location keep-alive.
    private static let backgroundLocationArmDelay: TimeInterval = 15.0

    /// [T-ios-scenephase-active-sigkill] True between a `willEnterForeground`
    /// notification and its deferred (yielded) handler running. Replaces the
    /// `applicationState != .background` guard, which was unreliable because
    /// `.inactive` is ambiguous — it can mean "entering foreground" OR "entering
    /// background". A synchronous `didEnterBackground` clears this flag, so a
    /// rapid bg→fg→bg blip cancels the in-flight foreground work cleanly. Also
    /// gates `reevaluate`'s @Published writes off the transition tick.
    private var pendingForegroundTransition = false

    // MARK: - Silent Audio Keep-Alive
    private var audioEngine: AVAudioEngine?
    private var silentPlayerNode: AVAudioPlayerNode?
    private var silentAudioActive = false

    /// [T-bg-keepalive-debounce] Pending debounced stop of silent audio. When
    /// the app receives a transient `foreground` signal (e.g. a call ending →
    /// Minis briefly foregrounds → immediately backgrounds again), stopping the
    /// keep-alive audio synchronously releases the audio session right before
    /// we go back to background, and iOS then kills the process. While sessions
    /// are active we instead DELAY the stop; if a `background` signal arrives
    /// within the window we cancel it and keep the audio running. nil when no
    /// stop is pending.
    private var pendingSilentAudioStop: DispatchWorkItem?
    /// Debounce window for a foreground-triggered stop while sessions are active.
    private static let silentAudioStopDebounce: TimeInterval = 1.5

    /// [T-bg-keepalive-debounce] How many consecutive `setActive(true)` failures
    /// we've retried for the current start attempt. Reset on success / when the
    /// budget is exhausted.
    private var silentAudioActivationRetries = 0
    private static let maxActivationRetries = 3
    private static let activationRetryDelay: TimeInterval = 0.5

    /// Wall-clock when the current debounced stop was scheduled, for logging the
    /// remaining window. nil when no stop is pending.
    private var pendingStopScheduledAt: Date?

    /// [T-ios-bg-idle-grace] One-shot timer holding keep-alive briefly after the
    /// last session ends. Non-nil ONLY while that window is open. A
    /// `DispatchSourceTimer` (not `Timer`) so it still fires with the run loop
    /// suspended in the background, and deliberately non-repeating so a missed
    /// cleanup can fire at most once. See `beginIdleGraceIfNeeded` for the full
    /// list of paths that clear it.
    private var idleGraceTimer: DispatchSourceTimer?
    /// When the current idle grace was armed, for log/diagnostic elapsed times.
    private var idleGraceStartedAt: Date?
    /// How long keep-alive survives after going idle. Distinct from — and much
    /// longer than — `silentAudioStopDebounce` (1.5s), which covers a transient
    /// foreground blip while sessions are STILL active. The two never overlap.
    private static let idleGracePeriod: TimeInterval = 60.0

    // MARK: - [BKA] Diagnostic snapshot state (read by CrashReporter)

    /// Last `[BKA][...]` action recorded, e.g. "Stop(reason=foreground,debounce=pending)".
    private(set) var lastBKAEvent: String?
    private(set) var lastBKAEventAt: Date?
    /// Last lifecycle transition, e.g. "Background" / "Foreground".
    private(set) var lastLifecycle: String?
    private(set) var lastLifecycleAt: Date?
    /// Audio-interruption state: "none" / "began" / "ended", with timestamp.
    private(set) var lastAudioInterruption: String = "none"
    private(set) var lastAudioInterruptionAt: Date?

    /// True if the keep-alive engine is genuinely running right now.
    var silentAudioIsPlaying: Bool { audioEngine?.isRunning ?? false }
    /// True if the shared audio session currently holds an active route.
    var audioSessionIsActive: Bool { silentAudioActive }
    /// True if a debounced stop is queued.
    var stopDebouncePending: Bool { pendingSilentAudioStop != nil }

    /// Record the most recent BKA action for the crash snapshot + log it.
    private func recordBKAEvent(_ event: String) {
        lastBKAEvent = event
        lastBKAEventAt = Date()
    }

    /// Human-readable debounce-timer state for the lifecycle snapshot line.
    private func debounceTimerDescription() -> String {
        guard pendingSilentAudioStop != nil else { return "nil" }
        guard let scheduledAt = pendingStopScheduledAt else { return "pending" }
        let left = Self.silentAudioStopDebounce - Date().timeIntervalSince(scheduledAt)
        return left > 0 ? "pending(\(String(format: "%.1f", left))s left)" : "pending(firing)"
    }

    /// One structured snapshot line covering every signal that decides whether
    /// the process survives in the background. Emitted on every lifecycle change.
    /// [BKA][Lifecycle]
    private func logLifecycleSnapshot(_ transition: String) {
        lastLifecycle = transition
        lastLifecycleAt = Date()
        let sessions = SessionActivityTracker.shared.busySessions.count
        let shellRunning = ShellCommandRingBuffer.hasRunningCommand
        let bgTask = isActive
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let remainingStr = remaining > 99999 ? "unlimited" : String(format: "%.0fs", remaining)
        logger.info("[BKA][Lifecycle] → \(transition) | isActive=\(self.isActive) bg=\(self.appIsInBackground) sessions=\(sessions) shellRunning=\(shellRunning) bgTask=\(bgTask) bgTaskRemaining=\(remainingStr) silentAudioPlaying=\(self.silentAudioIsPlaying) suspendCount=\(self.silentAudioSuspendCount) bgSpeak=\(self.backgroundSpeakEnabled) stopDebounceTimer=\(self.debounceTimerDescription())")
    }

    /// When > 0, silent audio is suspended so media playback gets full volume.
    /// Multiple callers can nest suspend/resume via this counter. Readable
    /// from outside for diagnostic logging at suspend/resume call sites.
    private(set) var silentAudioSuspendCount = 0

    /// Temporarily suspend silent audio for media playback (full volume).
    /// Each call must be balanced by a matching `resumeSilentAudioForMedia()`.
    func suspendSilentAudioForMedia(caller: String = #function) {
        let before = silentAudioSuspendCount
        silentAudioSuspendCount += 1
        logger.info("[BackgroundKeepAlive] suspendSilentAudioForMedia: count \(before) → \(self.silentAudioSuspendCount) caller=\(caller)")
        if silentAudioSuspendCount == 1 && silentAudioActive {
            stopSilentAudio()
        }
    }

    /// Resume silent audio after media playback ends. Only restarts if all
    /// suspenders have called resume and keep-alive conditions are still met.
    func resumeSilentAudioForMedia(caller: String = #function) {
        let before = silentAudioSuspendCount
        silentAudioSuspendCount = max(0, silentAudioSuspendCount - 1)
        logger.info("[BackgroundKeepAlive] resumeSilentAudioForMedia: count \(before) → \(self.silentAudioSuspendCount) caller=\(caller)")
        if silentAudioSuspendCount == 0 {
            evaluateSilentAudio(caller: "resumeMedia")
        }
    }

    // [T-ios-scene-create-watchdog-corelocation] `init()` deliberately does NO
    // CoreLocation work. Every CLLocationManager touch — the allocation itself
    // and `authorizationStatus` — is a synchronous XPC round-trip to locationd.
    // This is a `static let` singleton, so its init runs inside a dispatch_once
    // on whichever thread first reads `.shared`; that turned out to be the main
    // thread during SwiftUI's scene-create body evaluation, where a slow
    // locationd blocks the watchdog's 10s budget. See `configureLocationManager()`.
    private override init() {
        super.init()
    }

    private var didSetup = false

    /// Wire up the CLLocationManager. Split out of `init()` so no CoreLocation
    /// IPC can ever run as a side effect of merely touching `.shared`; callers
    /// reach this only from `setup()`, which runs after the scene exists.
    private func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.pausesLocationUpdatesAutomatically = false
        locationAuthStatus = locationManager.authorizationStatus
    }

    /// Read the current authorization status on demand, for UI that displays it
    /// without having necessarily gone through `setup()` first. Safe to call
    /// from a settings screen (the user is deep in the app by then, nowhere near
    /// the scene-create watchdog window) but NEVER from a view-body/init path
    /// that can run during launch — this performs synchronous locationd IPC.
    func refreshLocationAuthStatus() {
        locationAuthStatus = locationManager.authorizationStatus
    }

    func setup() {
        guard !didSetup else { return }
        didSetup = true
        configureLocationManager()
        logger.info("[BackgroundKeepAlive] Setup: enabled=\(self.enhancedBackgroundEnabled), locationTracking=\(self.locationTrackingEnabled)")

        if #available(iOS 17.0, *), !Self.debugAutoRetractDisabled {
            let probe = CLBackgroundActivitySession()
            probe.invalidate()
            logger.info("[BKA] unconditional orphan-session retract on setup")
        }

        // [T-ios-bgactivitysession-leak] A CLBackgroundActivitySession outlives
        // app termination by design: if the previous process was force-killed
        // without invalidating it, iOS keeps the system location indicator
        // pinned to the Dynamic Island and relaunches us when the user taps it.
        // On cold start, before deciding whether keep-alive should run, clear
        // any orphaned session + stale Live Activity so a leaked session from a
        // prior run doesn't keep the indicator (and a dead Live Activity) up.
        retractOrphanedLocationSession(caller: "setup")
        AgentLiveActivityManager.shared.cleanupStaleActivities(source: "BKA.setup")

        evaluateBackgroundActivitySession()

        // [T-ish-bg-cpu-governor] Background LAUNCH coverage: a process
        // relaunched directly into the background (RunningBoard after-life,
        // push/location wake) never receives didEnterBackgroundNotification,
        // so the governor sink below would leave background CPU unguarded —
        // exactly the state a post-kill relaunch resumes into. Arm it here
        // when setup finds the app already backgrounded (begin is idempotent;
        // a later real didEnterBackground is a no-op).
        if UIApplication.shared.applicationState == .background {
            appIsInBackground = true
            ISHKernel.shared.beginBackgroundCPUGovernor()
            logger.info("[BKA] launched in background — iSH CPU governor armed at setup")
        }

        // Observe app lifecycle
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // [T-ios-scenephase-active-sigkill] Cancel any in-flight
                // foreground transition: a bg→fg→bg blip must not let the
                // deferred willEnterForeground handler flip appIsInBackground.
                self.pendingForegroundTransition = false
                self.appIsInBackground = true
                self.backgroundEnteredAt = Date()
                // [T-ish-bg-cpu-governor] Closed-loop governor replaces the
                // old fixed 80% duty cycle (which sat exactly on the iOS
                // background kill line and still measured 91% — see
                // docs/internal/ish-bg-cpu-governor-design.md).
                ISHKernel.shared.beginBackgroundCPUGovernor()
                logger.info("[BKA] iSH background CPU governor STARTED")
                self.logLifecycleSnapshot("Background")
                // [T-ios-bg-location-arm-delay] Don't start location keep-alive
                // immediately on backgrounding — arm it after a delay so a brief
                // bg blip never spins up location. evaluateLocationUpdates() runs
                // inside scheduleBackgroundLocationArming() once disarmed → armed.
                self.scheduleBackgroundLocationArming()
                self.evaluateSilentAudio(caller: "didEnterBackground")
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pendingForegroundTransition = true
                // [T-ios-scenephase-active-sigkill] Defer @Published mutations
                // off the synchronous foreground-notification delivery. Flipping
                // appIsInBackground + evaluateSilentAudio triggers objectWillChange
                // on BackgroundKeepAliveManager, which invalidates any SwiftUI view
                // observing it — during the same tick as the foreground view-graph
                // transition. Yielding first avoids the overlap.
                Task { @MainActor in
                    await Task.yield()
                    // Guard against rapid bg→fg→bg cycling: if didEnterBackground
                    // fired between the notification and this yield it cleared the
                    // flag, so don't flip appIsInBackground. Uses a self-maintained
                    // flag rather than applicationState because `.inactive` is
                    // ambiguous (can mean "entering foreground" OR "entering
                    // background") and would let a backgrounding blip slip through.
                    guard self.pendingForegroundTransition else { return }
                    self.pendingForegroundTransition = false
                    self.appIsInBackground = false
                    ISHKernel.shared.endBackgroundCPUGovernor()
                    logger.info("[BKA] iSH background CPU governor STOPPED (foreground)")
                    self.logLifecycleSnapshot("Foreground")
                    // [T-ios-bg-location-arm-delay] Unified location-state
                    // cleanup on every foreground return — disarms, tears down
                    // our own session/timer, and retracts any orphaned session
                    // left pinned in the Dynamic Island (force-kill / crash).
                    self.cleanupLocationStateOnForeground()
                    self.evaluateSilentAudio(caller: "willEnterForeground")
                }
            }
            .store(in: &cancellables)

        // [BKA] willResignActive / didBecomeActive don't change appIsInBackground
        // (that's driven by did-enter-background / will-enter-foreground), but
        // they bracket the transient blip that the debounce defends against, so
        // we snapshot them too for the crash-time timeline.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.logLifecycleSnapshot("Inactive") }
            .store(in: &cancellables)

        // [T-bka-la-after-task] Synchronous (no receive(on:)): still foreground
        // here, which a Live Activity request needs.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.laRestartAfterTask == "resignActive", self.continuedTask != nil else { return }
                    AgentLiveActivityManager.shared.restartForIslandPriority(reason: "willResignActive")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.logLifecycleSnapshot("Active")
                self?.retractOrphanedLocationSession(caller: "didBecomeActive")
                // [T-bka-continued-retry-foreground]
                if self?.continuedAwaitingForeground == true {
                    self?.evaluateContinuedProcessing(caller: "didBecomeActive")
                }
            }
            .store(in: &cancellables)

        // Re-evaluate keep-alive whenever the active conversations or the
        // toggle change.
        //
        // [T-scheduled-active-session] Keep-alive reads the tracker's ACTIVE
        // conversations (`busySessions`), not just the running loops: a chat
        // waiting on its own scheduled follow-up, or on sub agents, is still
        // working, and ScheduledJobRunner fires from an in-process Task/sleep
        // that a suspended app never wakes. This replaces the former
        // job-registry special case ([T-scheduled-bka-keepalive]); keep-alive
        // itself knows nothing about jobs.
        Publishers.CombineLatest(
            SessionActivityTracker.shared.$busySessions,
            $enhancedBackgroundEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sessions, enabled in
            guard let self else { return }
            self.reevaluate(sessions: sessions, enabled: enabled)
        }
        .store(in: &cancellables)

        // App-icon badge: running-task count (gated by
        // `backgroundNotificationsEnabled`, the same toggle that controls
        // task-completion banners) plus unseen notifications. Coming back
        // clears the unseen part: `MinisApp.handleScenePhaseChange` on
        // iPhone/iPad, the Mac frontmost observer on a Mac.
        Publishers.CombineLatest(
            SessionActivityTracker.shared.$busySessions,
            $backgroundNotificationsEnabled
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] sessions, enabled in
            self?.refreshActiveTaskBadge(sessions: sessions, enabled: enabled)
        }
        .store(in: &cancellables)
        observeMacFrontmost()

        // Re-evaluate location when location toggle changes
        $locationTrackingEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateLocationUpdates()
            }
            .store(in: &cancellables)

        // Re-evaluate silent audio when background speak toggle changes
        $backgroundSpeakEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.evaluateSilentAudio(caller: "bgSpeakToggle")
            }
            .store(in: &cancellables)

        // [T-ios-live-activity-audio-toggle] Drive the Live Activity from the
        // read-aloud (TTS) engine state, NOT the chat audio-attachment player.
        // `VoiceOutputState.shared` mirrors both TTS engines: isReadingAloud ==
        // a reply is being read (starts/attaches the Live Activity, shows the
        // toggle), speechPaused flips the control icon, and reading-ends tears an
        // audio-only activity down. `removeDuplicates` avoids redundant pushes.
        // (Root-cause fix for b0f3f884: GlobalAudioPlayer.isPlaying/isLoaded
        // never change during read-aloud, so the toggle never appeared.)
        Publishers.CombineLatest(
            VoiceOutputState.shared.$isReadingAloud,
            VoiceOutputState.shared.$speechPaused
        )
        .removeDuplicates { $0 == $1 }
        .dropFirst() // skip the initial replay on subscribe
        .receive(on: DispatchQueue.main)
        .sink { [weak self] reading, paused in
            self?.audioPlaybackStateChanged(source: "voiceOut(reading=\(reading),paused=\(paused))")
        }
        .store(in: &cancellables)

        // Restart silent audio when an external app's audio interruption ends.
        // External media (Spotify, Apple Music, etc.) starting playback will
        // pause our AVAudioEngine via .interruptionTypeBegan; iOS sends
        // .ended once the foreign session relinquishes. Without re-evaluating
        // here, `silentAudioActive` stays true (engine is silently dead) and
        // the process becomes eligible for suspension/termination.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.lastAudioInterruption = "began"
                    self.lastAudioInterruptionAt = Date()
                    let wasSuspended = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                        == AVAudioSession.InterruptionReason.appWasSuspended.rawValue
                    logger.info("[BKA][Interrupt] began — appWasSuspended=\(wasSuspended) wasPlaying=\(self.silentAudioIsPlaying)")
                    self.recordBKAEvent("Interrupt began")
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                        AVAudioSession.InterruptionOptions(rawValue: $0)
                    }
                    let shouldResume = opts?.contains(.shouldResume) ?? false
                    self.lastAudioInterruption = "ended"
                    self.lastAudioInterruptionAt = Date()
                    logger.info("[BKA][Interrupt] ended — shouldResume=\(shouldResume) sessions=\(SessionActivityTracker.shared.busySessions.count) bg=\(self.appIsInBackground)")
                    // 0.5s grace so the foreign session fully releases before we
                    // re-acquire .playback.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.handleAudioInterruptionEnded()
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        // [T-bg-keepalive-debounce] Route changes (e.g. another app's session
        // taking over, headphones unplugged) can leave our engine running into
        // a dead session, or signal the system reclaimed audio focus. When that
        // happens while a background task is active, re-acquire the session.
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleAudioSessionPossiblyReclaimed(source: "routeChange", note: note)
            }
            .store(in: &cancellables)

        // [T-bg-keepalive-debounce] The secondary-audio hint fires when the
        // system asks us to silence secondary audio (`.begin`) and again when
        // it's safe to resume (`.end`). An `.end` while we're backgrounded with
        // active sessions is another cue to make sure our keep-alive audio is
        // actually live.
        NotificationCenter.default.publisher(for: AVAudioSession.silenceSecondaryAudioHintNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleAudioSessionPossiblyReclaimed(source: "silenceSecondaryAudioHint", note: note)
            }
            .store(in: &cancellables)

        // [T-bka-audio-dead-watchdog] The engine posts this when the system
        // changed its I/O under it (a call ending, a route change) - and it
        // has STOPPED by then. Look a moment later, once the route settled.
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let engine = note.object as? AVAudioEngine, engine === self.audioEngine else { return }
                logger.info("[BKA][EngineConfigChange] keep-alive engine reconfigured — running=\(engine.isRunning)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.reviveSilentAudioIfDead(source: "engineConfigChange")
                }
            }
            .store(in: &cancellables)
    }

    /// [T-bg-keepalive-debounce] Common handler for route-change /
    /// secondary-audio-hint notifications: if we're backgrounded with active
    /// sessions and our silent audio is supposed to be playing, verify the
    /// engine is genuinely alive and re-acquire the session if not. This catches
    /// the case where iOS quietly tore down our session (so `silentAudioActive`
    /// is a lie) and the process becomes eligible for termination.
    private func handleAudioSessionPossiblyReclaimed(source: String, note: Notification) {
        // [BKA][RouteChange] log the route transition (only routeChange carries
        // route info; secondary-hint just signals begin/end).
        if source == "routeChange",
           let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
           let reason = AVAudioSession.RouteChangeReason(rawValue: raw) {
            let outs = AVAudioSession.sharedInstance().currentRoute.outputs
                .map { $0.portType.rawValue }.joined(separator: "+")
            logger.info("[BKA][RouteChange] reason=\(reason) newRoute=\(outs.isEmpty ? "none" : outs) sessions=\(SessionActivityTracker.shared.busySessions.count) bg=\(self.appIsInBackground)")
        }

        reviveSilentAudioIfDead(source: source)
    }

    /// [T-bka-audio-dead-watchdog] Make sure the keep-alive audio that should
    /// be playing really is, and restart it when it is not.
    ///
    /// Called from three places, because no single signal is reliable:
    /// - route change / secondary-audio hint (the original callers);
    /// - AVAudioEngineConfigurationChange, which is how the engine reports
    ///   that the system stopped it;
    /// - the 5 s background timer, as the backstop.
    ///
    /// The backstop is what the 2026-10-09 kill needed. A phone call began
    /// (interruption began, route -> Receiver); the route-change restart ran
    /// DURING the call and "succeeded"; the call ended (route -> Speaker) with
    /// the engine still reporting running, so that check passed; the engine
    /// then stopped, no `.ended` interruption was ever delivered, and nothing
    /// looked again. `silentAudio=false` was logged every 5 s for 30 s while
    /// the background time ran from 27 s to 0, and the app was killed.
    @discardableResult
    func reviveSilentAudioIfDead(source: String) -> Bool {
        let sessionCount = SessionActivityTracker.shared.busySessions.count
        let wantsKeepAlive = isActive && backgroundSpeakEnabled
            && appIsInBackground && silentAudioSuspendCount == 0 && sessionCount > 0
        switch SilentAudioWatchdog.decide(wantsKeepAlive: wantsKeepAlive, markedActive: silentAudioActive,
                                          engineRunning: audioEngine?.isRunning ?? false) {
        case .none:
            return false
        case .restart:
            // We think audio is active but the engine is not running: iOS
            // pulled the session out from under us. Tear down and restart.
            logger.warning("[BKA][\(source)] silentAudioActive but engine NOT running — session reclaimed, restarting")
            recordBKAEvent("Session reclaimed (\(source))")
            silentPlayerNode?.stop()
            audioEngine?.stop()
            silentPlayerNode = nil
            audioEngine = nil
            silentAudioActive = false
            cancelPendingSilentAudioStop(reason: "\(source) reclaim")
            startSilentAudio(reason: "\(source)Reclaim")
            return true
        case .evaluate:
            // Should be playing but isn't — re-evaluate (also covers a stale
            // pending stop from a prior foreground blip).
            logger.info("[BKA][\(source)] keep-alive wanted but not playing — re-evaluating")
            cancelPendingSilentAudioStop(reason: "\(source) not playing")
            evaluateSilentAudio(caller: source)
            return true
        }
    }

    /// Force-reset silent audio state after an AVAudioSession interruption
    /// ends. The engine may have been stopped silently by iOS while we still
    /// believe `silentAudioActive == true`, which prevents `evaluateSilentAudio`
    /// from restarting it.
    private func handleAudioInterruptionEnded() {
        let sessionCount = SessionActivityTracker.shared.busySessions.count
        logger.info("[BackgroundKeepAlive] Audio session interruption ended — bg=\(self.appIsInBackground) sessions=\(sessionCount) playing=\(self.silentAudioActive)")
        // The engine may have been stopped silently by iOS while we still
        // believe `silentAudioActive == true`, which would block
        // `evaluateSilentAudio` from restarting it. Tear down the stale engine
        // unconditionally so evaluate can cleanly re-start.
        if silentAudioActive {
            silentPlayerNode?.stop()
            audioEngine?.stop()
            silentPlayerNode = nil
            audioEngine = nil
            silentAudioActive = false
        }
        // [T-bg-keepalive-debounce] An interruption ending mid-task (e.g. a
        // WeChat/phone call finishing while a background agent task is still
        // running) is exactly when we must re-acquire the session. If we're in
        // background with active sessions, force a fresh start with retry rather
        // than relying solely on evaluate (which is correct, but be explicit).
        if appIsInBackground && sessionCount > 0 {
            cancelPendingSilentAudioStop(reason: "interruption ended, sessions active")
        }
        evaluateSilentAudio(caller: "interruptionEnded")
    }

    // MARK: - Location Permission

    func requestLocationPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Termination

    /// Called from `applicationWillTerminate` so a clean exit tears the location
    /// session + Live Activity down. [T-ios-bgactivitysession-leak] Without this,
    /// the CLBackgroundActivitySession outlives the process and keeps the system
    /// location indicator pinned (and relaunches the app when tapped).
    /// `applicationWillTerminate` isn't guaranteed on force-kill, so the cold-start
    /// + foreground `retractOrphanedLocationSession(...)` paths are the backstop.
    func prepareForTermination() {
        logger.info("[BackgroundKeepAlive] prepareForTermination — stopping location session + Live Activity")
        // [T-ios-bg-idle-grace] Never carry a pending grace timer into termination.
        cancelIdleGrace(reason: "prepareForTermination")
        disarmBackgroundLocation()
        locationTimer?.invalidate()
        locationTimer = nil
        locationUpdating = false
        if locationManager.allowsBackgroundLocationUpdates {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
        }
        stopBackgroundActivitySession()
        // Belt-and-suspenders: after tearing down our owned session, probe-retract
        // so the system indicator is definitively cleared even if the handle was
        // already lost.
        retractOrphanedLocationSession(caller: "terminate")
        AgentLiveActivityManager.shared.endActivity()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationAuthStatus = status
            logger.info("[BackgroundKeepAlive] Authorization changed: \(status.rawValue)")
            self.evaluateLocationUpdates()
            self.evaluateBackgroundActivitySession()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            let lat = Self.maskCoordinate(loc.coordinate.latitude)
            let lon = Self.maskCoordinate(loc.coordinate.longitude)
            Task { @MainActor in
                logger.info("[BackgroundKeepAlive] Location update: (\(lat), \(lon)) accuracy=\(loc.horizontalAccuracy)m")
                // Piggyback Live Activity update on location callback —
                // Timer may be suspended in background, but location callbacks keep firing.
                self.updateLiveActivityIfNeeded(source: "location")
            }
        }
    }

    /// Mask a coordinate for privacy: keep first 2 and last 1 digits, replace middle with "..."
    /// e.g. 39.9042 → "39...2", 116.4074 → "11...4"
    nonisolated private static func maskCoordinate(_ value: Double) -> String {
        let s = String(format: "%.4f", value)
        guard s.count > 3 else { return s }
        return "\(s.prefix(2))...\(s.suffix(1))"
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            logger.warning("[BackgroundKeepAlive] Location error: \(error.localizedDescription)")
        }
    }

    // MARK: - Evaluate State

    private func reevaluate(sessions: Set<String>, enabled: Bool) {
        // [T-ios-scenephase-active-sigkill] If we're mid foreground transition
        // (between willEnterForeground and its deferred yield), defer this
        // reevaluation. It writes @Published isActive; doing so on the
        // transition tick overlaps the SwiftUI view-graph rebuild → potential
        // SIGKILL (same family as the 2026-06-19 mid-request crash).
        if pendingForegroundTransition {
            Task { @MainActor in
                await Task.yield()
                self.reevaluate(sessions: sessions, enabled: enabled)
            }
            return
        }

        // [T-bka-continued-fallback] The continued task follows the run, not
        // isActive: it is also the keep-alive when Enhanced Background is off.
        // [T-bka-la-before-task] The run state is updated here, BEFORE the
        // activate / deactivate branch, so the branch's own evaluate call sees
        // it (no stray submit at run end); the task itself is evaluated after
        // the Live Activity is requested - the user wants the Live Activity,
        // not the system task card, to hold the Dynamic Island (see also
        // AgentLiveActivityManager.relevanceScore).
        let busy = !sessions.isEmpty
        let busyChanged = busy != continuedBusy
        if busyChanged {
            continuedBusy = busy
            if busy { continuedUnavailableThisRun = false }
            if !busy { continuedAwaitingForeground = false }
        }

        let shouldBeActive = !sessions.isEmpty && enabled
        let sessionList = sessions.prefix(5).joined(separator: ",")
        // [T-ios-log-noise-reduction] INFO→DEBUG: reevaluate runs on every
        // session-set / toggle change and was ~482 lines/day even when nothing
        // transitioned. The actual state CHANGES (Activating / Deactivating
        // below) keep their INFO level, so production logs still show the
        // transitions without the per-call no-op chatter.
        logger.debug("[BackgroundKeepAlive] Reevaluate: sessions=\(sessions.count) enabled=\(enabled) isActive=\(self.isActive) shouldBeActive=\(shouldBeActive) ids=[\(sessionList)]")

        if shouldBeActive && !isActive {
            logger.info("[BackgroundKeepAlive] Activating keep-alive (sessions=\(sessions.count))")
            isActive = true
            AgentLiveActivityManager.shared.startActivity(sessions: buildSessionSnapshots())
            startUpdateTimer()
            evaluateContinuedProcessing(caller: "activate")
            evaluateLocationUpdates()
            evaluateBackgroundActivitySession()
            evaluateSilentAudio(caller: "reevaluate-activate")
        } else if !shouldBeActive && isActive {
            logger.info("[BackgroundKeepAlive] Deactivating keep-alive")
            stopUpdateTimer()
            isActive = false
            evaluateContinuedProcessing(caller: "deactivate")
            // [T-ios-live-activity-soft-finish] STOP LOCATION FIRST, fully, before
            // touching the Live Activity. The old order (end Live Activity, then
            // tear down location) let the probe-retract race surface a "ghost"
            // location arrow right as the task ended — it appeared and couldn't be
            // dismissed even though nothing was locating. Quiescing location first
            // closes that window. [T-ios-bgactivitysession-leak]
            disarmBackgroundLocation()
            evaluateLocationUpdates()
            evaluateBackgroundActivitySession()
            retractOrphanedLocationSession(caller: "deactivate")
            evaluateSilentAudio(caller: "reevaluate-deactivate")
            // THEN soft-finish the Live Activity: flip to a completed state
            // (checkmark + last message) and leave it on screen; it's dismissed
            // when the user taps it and Minis foregrounds.
            Task { await AgentLiveActivityManager.shared.finishActivity() }
        }

        // [T-bka-la-before-task] Evaluated after the activate branch: when
        // that branch runs, it has already requested the Live Activity and
        // then submitted the task (its own evaluate call), so this is a no-op
        // there; it does the submit when no Live Activity starts (Enhanced
        // Background off) and the completion at run end.
        if busyChanged {
            evaluateContinuedProcessing(caller: busy ? "runStart" : "runEnd")
        }
    }

    // MARK: - App Icon Badge

    /// Update the app-icon badge: the live count of running agent sessions
    /// plus the notifications posted while the user was away (see
    /// `AppBadge.total`). When the user has turned the task-notifications
    /// toggle off, running sessions are not counted — Apple HIG treats badge
    /// as a notification affordance, so it inherits that gate. Coming back
    /// to the app clears the unseen part (`clearUnseenBadge`).
    func refreshActiveTaskBadge() {
        refreshActiveTaskBadge(
            sessions: SessionActivityTracker.shared.busySessions,
            enabled: backgroundNotificationsEnabled
        )
    }

    private func refreshActiveTaskBadge(sessions: Set<String>, enabled: Bool) {
        let total = AppBadge.total(runningSessions: sessions.count, notificationsEnabled: enabled,
                                   unseenNotifications: unseenBadgeCount)
        UNUserNotificationCenter.current().setBadgeCount(total) { err in
            if let err {
                logger.error("[Badge] setBadgeCount failed: \(err.localizedDescription)")
            }
        }
    }

    // [T-mac-dock-badge] The badge used to be written two ways: this refresh
    // SET it to the running count, and each notification ADDED one to whatever
    // the icon showed. The next refresh (any busy-set change) overwrote the
    // additions, so finished tasks fell off the count. On iPhone the app is
    // usually suspended right after a task ends, which hid it; on a Mac it keeps
    // running. One ledger now: the badge is always recomputed from both parts.

    private static let unseenBadgeKey = "appBadgeUnseenNotificationCount"

    /// Notifications posted while the user was away, not yet seen. Persisted so
    /// a relaunch in the background does not reset the icon to the running count.
    private var unseenBadgeCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.unseenBadgeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.unseenBadgeKey) }
    }

    /// Count one more notification the user has not seen. Returns the new badge
    /// total for the notification's `content.badge`.
    @discardableResult
    func noteUnseenNotification() -> Int {
        unseenBadgeCount += 1
        refreshActiveTaskBadge()
        let total = AppBadge.total(runningSessions: SessionActivityTracker.shared.busySessions.count,
                                   notificationsEnabled: backgroundNotificationsEnabled,
                                   unseenNotifications: unseenBadgeCount)
        logger.info("[Badge] unseen notification -> unseen=\(unseenBadgeCount) total=\(total)")
        return total
    }

    /// The user is back in the app: what was posted while away has been seen.
    /// The running count stays.
    func clearUnseenBadge() {
        if unseenBadgeCount != 0 {
            logger.info("[Badge] user returned -> clearing unseen=\(unseenBadgeCount)")
        }
        unseenBadgeCount = 0
        refreshActiveTaskBadge()
    }

    // MARK: - User Attention (Mac frontmost)

    /// [T-mac-dock-badge] Mac only: whether Minis is the frontmost app. See
    /// `UserAttention` for why UIKit's own state cannot answer this on a Mac.
    /// Starts true: a launch normally brings the app to the front, and the
    /// first activate/resign notification corrects it.
    private(set) var macAppIsFrontmost = true

    /// Whether the user is not looking at Minis — the gate for "tell them when
    /// it is done" notifications and the badge.
    var userIsAway: Bool {
        UserAttention.isAway(appState: UIApplication.shared.applicationState,
                             onMac: ProcessInfo.processInfo.isiOSAppOnMac,
                             macAppIsFrontmost: macAppIsFrontmost)
    }

    private func observeMacFrontmost() {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }
        let center = NotificationCenter.default
        for (name, frontmost) in [(UserAttention.macDidBecomeActive, true), (UserAttention.macDidResignActive, false)] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.macFrontmostChanged(frontmost) }
                .store(in: &cancellables)
        }
    }

    private func macFrontmostChanged(_ frontmost: Bool) {
        guard frontmost != macAppIsFrontmost else { return }
        macAppIsFrontmost = frontmost
        logger.info("[Badge] mac frontmost=\(frontmost) running=\(SessionActivityTracker.shared.busySessions.count) unseen=\(unseenBadgeCount)")
        // Coming back to the window is the Mac's "opened the app": scenePhase
        // never turns .active again there, so MinisApp's clear does not run.
        if frontmost { clearUnseenBadge() }
    }

    // MARK: - Background Task Notifications

    /// Notification category for background task completion.
    private static let bgTaskCategoryId = "BACKGROUND_TASK"

    /// Post a local notification when a background task completes.
    /// - Parameters:
    ///   - sessionTitle: Session/conversation title (shown as notification title)
    ///   - responseSummary: Truncated assistant response text (shown as notification body)
    ///   - sessionId: The session ID for tap-to-open navigation
    ///   - outcome: completed / failed / interrupted (see the method below)
    /// [T-ios-live-activity-privacy-mode] Content-free notification body:
    /// "1 task completed · 2m 15s". The duration is appended only when a start
    /// time is available (a Live Activity run was in flight); otherwise the body
    /// degrades to just the count, per spec — no extra time tracking is added.
    private static func privacyNotificationBody(outcome: BackgroundTurnOutcome, startedAt: Date?) -> String {
        let base: String
        switch outcome {
        case .failed: base = AppLocalized("1 task failed")
        case .interrupted: base = AppLocalized("1 task paused")
        case .completed: base = AppLocalized("1 task completed")
        }
        guard let startedAt else { return base }
        let elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        guard elapsed > 0 else { return base }
        let formatted: String
        if elapsed >= 3600 {
            formatted = String(format: "%dh %dm", elapsed / 3600, (elapsed % 3600) / 60)
        } else if elapsed >= 60 {
            formatted = String(format: "%dm %ds", elapsed / 60, elapsed % 60)
        } else {
            formatted = String(format: "%ds", elapsed)
        }
        return "\(base) · \(formatted)"
    }

    /// - scheduledJobId: [T-sched-notif-in-place] The scheduled task whose firing
    ///   opened this run, if any: its runs update one notification in place.
    /// - outcome: [T-bgnotif-outcome] how the turn really ended; an interrupted
    ///   turn gets ⏸, never ✅.
    func postBackgroundTaskNotification(sessionTitle: String, responseSummary: String, sessionId: String, outcome: BackgroundTurnOutcome = .completed, wasBackground: Bool? = nil, scheduledJobId: String? = nil) {
        guard backgroundNotificationsEnabled else { return }
        // Use the caller-captured snapshot when available (the async Task in
        // endBackgroundProcessing may not run until the app is already active).
        // Fall back to the live check for other call sites.
        let isBackground = wasBackground ?? userIsAway
        guard isBackground else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let category = UNNotificationCategory(
            identifier: Self.bgTaskCategoryId,
            actions: [],
            intentIdentifiers: []
        )
        // [T-user-ask] Through the shared registry: a bare set() wipes other features' categories.
        NotificationCategoryCenter.shared.register([category])

        let content = UNMutableNotificationContent()
        if liveActivityPrivacyMode {
            // [T-ios-live-activity-privacy-mode] Neutral report only: no session
            // title, no reply summary. sessionId stays in userInfo below so the
            // tap-to-open jump keeps working, and the badge logic is untouched.
            switch outcome {
            case .failed: content.title = AppLocalized("❌ Task failed")
            case .interrupted: content.title = AppLocalized("⏸ Task paused")
            case .completed: content.title = AppLocalized("✅ Task completed")
            }
            content.body = Self.privacyNotificationBody(
                outcome: outcome,
                startedAt: AgentLiveActivityManager.shared.taskStartTime
            )
        } else {
            let mark: String
            switch outcome {
            case .failed: mark = "❌"
            case .interrupted: mark = "⏸"
            case .completed: mark = "✅"
            }
            content.title = "\(mark) \(sessionTitle)"
            content.body = responseSummary
        }
        content.sound = .default
        content.categoryIdentifier = Self.bgTaskCategoryId
        content.userInfo = ["sessionId": sessionId]
        // [T-sched-notif-in-place] A scheduled task's runs share one notification.
        let identifier = BackgroundTaskNotificationID.make(sessionId: sessionId, scheduledJobId: scheduledJobId, now: Date())
        logger.info("[BackgroundNotification] posting notification title=\(content.title.debugDescription) bodyLength=\(content.body.count) sessionId=\(sessionId) id=\(identifier)")

        guard scheduledJobId != nil else {
            deliverBackgroundTaskNotification(content, identifier: identifier, isNewEntry: true, center: center)
            return
        }
        // Updating the entry this task already has in Notification Center is not
        // a new notification: the badge counts it once, not once per run.
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            let isNewEntry = !delivered.contains { $0.request.identifier == identifier }
            self.deliverBackgroundTaskNotification(content, identifier: identifier, isNewEntry: isNewEntry, center: center)
        }
    }

    private func deliverBackgroundTaskNotification(_ content: UNMutableNotificationContent, identifier: String,
                                                   isNewEntry: Bool, center: UNUserNotificationCenter) {
        if isNewEntry {
            // [T-mac-dock-badge] Through the badge ledger, not "icon + 1".
            content.badge = NSNumber(value: noteUnseenNotification())
        } else {
            logger.info("[BackgroundNotification] updating the delivered notification in place id=\(identifier)")
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )
        center.add(request) { error in
            if let error {
                logger.error("[BackgroundNotification] Failed to post: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Background Location Arming (delay before keep-alive)

    /// [T-ios-bg-location-arm-delay] Start the delay timer that arms background
    /// location keep-alive `backgroundLocationArmDelay` seconds after the app
    /// backgrounds. If the app returns to foreground first, `disarmBackgroundLocation`
    /// cancels this and nothing ever spins up. Idempotent: a no-op if a timer is
    /// already pending or location is already armed.
    private func scheduleBackgroundLocationArming() {
        guard appIsInBackground, Self.locationKeepAliveUsed else { return }
        guard !backgroundLocationArmed, backgroundLocationArmTimer == nil else { return }
        let delay = Self.backgroundLocationArmDelay
        logger.info("[BKA][LocationArm] scheduling location keep-alive in \(Int(delay))s")
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.backgroundLocationArmTimer = nil
                // Re-check we're still backgrounded — a fg blip may have fired
                // after the timer was created but the disarm beat us here.
                guard self.appIsInBackground else {
                    logger.info("[BKA][LocationArm] arm fired but no longer backgrounded — skip")
                    return
                }
                self.backgroundLocationArmed = true
                logger.info("[BKA][LocationArm] armed — starting location keep-alive now")
                self.evaluateLocationUpdates()
                self.evaluateBackgroundActivitySession()
            }
        }
        backgroundLocationArmTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    /// Cancel a pending arm timer and disarm immediately (foreground return).
    private func disarmBackgroundLocation() {
        backgroundLocationArmTimer?.invalidate()
        backgroundLocationArmTimer = nil
        if backgroundLocationArmed {
            logger.info("[BKA][LocationArm] disarmed (foreground)")
        }
        backgroundLocationArmed = false
    }

    /// [T-ios-bgactivitysession-leak] Unified location-state cleanup run on every
    /// foreground return. Order matters:
    ///   1. disarm + stop the 5s requestLocation timer (foreground never needs it),
    ///   2. evaluate the iOS17 session — now disarmed, this tears OUR session down,
    ///   3. retract any ORPHANED session (a leak from a prior crash/force-kill that
    ///      our handle can't reach) so a stale indicator never survives a relaunch,
    ///   4. re-sync the Live Activity to the current session set.
    /// This is the single place that guarantees: back in the foreground ⇒ no
    /// location indicator, regardless of how the app last died.
    private func cleanupLocationStateOnForeground() {
        disarmBackgroundLocation()
        // Stop the legacy requestLocation timer immediately (foreground).
        locationTimer?.invalidate()
        locationTimer = nil
        locationUpdating = false
        if locationManager.allowsBackgroundLocationUpdates {
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
        }
        // Tear down our own iOS17 session (disarmed ⇒ shouldRun is false).
        evaluateBackgroundActivitySession()
        // Retract any orphaned session our handle can't reach.
        retractOrphanedLocationSession(caller: "foreground")
        // Keep the Live Activity consistent with the live session set.
        updateLiveActivityIfNeeded(source: "foregroundCleanup")
    }

    // MARK: - Location Updates

    private func evaluateLocationUpdates() {
        let shouldUpdate = isActive
            && Self.locationLAMode == .continuous
            && !continuedReplacesLocation
            && locationTrackingEnabled
            && appIsInBackground
            && backgroundLocationArmed
            && (locationAuthStatus == .authorizedAlways || locationAuthStatus == .authorizedWhenInUse)
            && liveUpdatesTask == nil

        if shouldUpdate && !locationUpdating {
            logger.info("[BackgroundKeepAlive] Starting location updates (5s interval)")
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = false
            locationUpdating = true
            // Request location immediately, then every 5 seconds
            locationManager.requestLocation()
            locationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.locationManager.requestLocation()
                }
            }
            RunLoop.current.add(locationTimer!, forMode: .common)
        } else if !shouldUpdate && locationUpdating {
            logger.info("[BackgroundKeepAlive] Stopping location updates")
            locationTimer?.invalidate()
            locationTimer = nil
            locationUpdating = false
        }
    }

    // MARK: - Background Activity Session (iOS 17+)

    private func evaluateBackgroundActivitySession() {
        let hasPermission = locationAuthStatus == .authorizedAlways || locationAuthStatus == .authorizedWhenInUse
        // `isActive` is false the moment no agent task is running (see
        // reevaluate). So as soon as the last task finishes, shouldRun flips to
        // false and the session below is torn down immediately — we never keep
        // the location stream (or its system indicator) alive past the work.
        //
        // [T-ios-bg-location-arm-delay] Also gated on appIsInBackground +
        // backgroundLocationArmed: the CLBackgroundActivitySession (and its
        // system location indicator) only starts 15s AFTER backgrounding, never
        // in the foreground. This gives a grace window so brief background blips
        // don't flash the indicator, and keeps the foreground free of location.
        let mode = Self.locationLAMode
        let shouldRun = isActive && mode != .off && !continuedReplacesLocation && enhancedBackgroundEnabled && hasPermission
            && appIsInBackground && backgroundLocationArmed

        // Singleton by construction: this manager is a `.shared` instance and
        // `liveUpdatesTask`/`bgActivitySession` are single-valued, so N
        // concurrent background sessions still drive exactly ONE global
        // CLBackgroundActivitySession + one liveUpdates stream — never one per
        // chat session. The `liveUpdatesTask == nil` guard makes start idempotent.
        if shouldRun && liveUpdatesTask == nil {
            startBackgroundActivitySession()
        } else if !shouldRun {
            // Tear down whenever we shouldn't be running — even if liveUpdatesTask
            // is already nil — so a session orphaned by a prior force-kill (task
            // nil, but the system indicator still pinned) gets explicitly
            // invalidated rather than lingering.
            stopBackgroundActivitySession()
        }
    }

    private func startBackgroundActivitySession() {
        guard liveUpdatesTask == nil else { return }

        if #available(iOS 17.0, *) {
            let session = CLBackgroundActivitySession()
            bgActivitySession = session
            logger.info("[BKA][LocationLA] CLBackgroundActivitySession created sinceBg=\(Self.ago(self.backgroundEnteredAt))s")
            // [T-bka-session-single-invalidate] Never read `session.diagnostics`
            // here. When that stream ends (the task iterating it is cancelled)
            // CoreLocation's Swift overlay invalidates the session by itself,
            // and stopBackgroundActivitySession() then invalidates it a second
            // time. Two invalidates in quick succession race inside CoreLocation
            // and crash on its queue (objc_msgSend from
            // _dispatch_call_block_and_release). The same status flags arrive
            // with every live update and are logged by updateFlags(_:).

            liveUpdatesTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let updates = CLLocationUpdate.liveUpdates(.otherNavigation)
                    for try await update in updates {
                        guard !Task.isCancelled else { break }
                        let now = Date()
                        let elapsed = now.timeIntervalSince(self.lastLocationLAUpdate)
                        guard elapsed >= Self.locationLAMinInterval else { continue }
                        self.lastLocationLAUpdate = now
                        let lat = update.location.map { Self.maskCoordinate($0.coordinate.latitude) } ?? "?"
                        let lon = update.location.map { Self.maskCoordinate($0.coordinate.longitude) } ?? "?"
                        logger.info("[BKA][LocationLA] tick (\(lat),\(lon)) \(Self.updateFlags(update)) sinceBg=\(Self.ago(self.backgroundEnteredAt))s — pushing LA update")
                        self.updateLiveActivityIfNeeded(source: "locationLA")
                    }
                } catch {
                    if !Task.isCancelled {
                        logger.error("[BKA][LocationLA] liveUpdates stream error: \(error.localizedDescription)")
                    }
                }
                logger.info("[BKA][LocationLA] stream ended")
                self.liveUpdatesTask = nil
            }
            logger.info("[BKA][LocationLA] liveUpdates stream started")
        } else {
            // [T-bg-location-os-floor] No iOS 16 implementation exists, so say so
            // in the log the user is told to send us when background execution
            // "doesn't work" — previously the arm path fell through silently.
            logger.warning("[BKA][LocationLA] background location leg requested but unavailable: iOS 17+ required (CLBackgroundActivitySession/liveUpdates), no fallback — silent-audio and Live Activity legs are unaffected")
        }
    }

    // MARK: - Location diagnostics ([T-bka-loc-pulse])

    /// Seconds since `date`, one decimal, or "-" when nil (log helper).
    private static func ago(_ date: Date?) -> String {
        guard let date else { return "-" }
        return String(format: "%.1f", Date().timeIntervalSince(date))
    }

    /// The status flags an update carries (iOS 18+), for the tick log.
    @available(iOS 17.0, *)
    private static func updateFlags(_ u: CLLocationUpdate) -> String {
        var f = ["hasLocation=\(u.location != nil)"]
        if #available(iOS 18.0, *) {
            if u.insufficientlyInUse { f.append("insufficientlyInUse") }
            if u.locationUnavailable { f.append("locationUnavailable") }
            if u.accuracyLimited { f.append("accuracyLimited") }
            if u.stationary { f.append("stationary") }
            if u.authorizationDenied { f.append("authorizationDenied") }
            if u.authorizationDeniedGlobally { f.append("authorizationDeniedGlobally") }
            if u.authorizationRestricted { f.append("authorizationRestricted") }
            if u.serviceSessionRequired { f.append("serviceSessionRequired") }
            if u.authorizationRequestInProgress { f.append("authorizationRequestInProgress") }
        }
        return f.joined(separator: " ")
    }

    /// One-line location/lifecycle state for the Live Activity push log, so a
    /// push can be matched to what the location side was doing at that moment.
    var liveActivityPushDiag: String {
        let app: String = {
            switch UIApplication.shared.applicationState {
            case .active: return "fg"
            case .inactive: return "inactive"
            case .background: return "bg"
            @unknown default: return "?"
            }
        }()
        let loc = liveUpdatesTask != nil ? "continuous" : "off"
        return "app=\(app) sinceBg=\(appIsInBackground ? Self.ago(backgroundEnteredAt) : "-")s locMode=\(Self.locationLAMode.rawValue) loc=\(loc) silentAudio=\(silentAudioActive) continued=\(continuedTask != nil)"
    }

    private func stopBackgroundActivitySession() {
        let hadSomething = liveUpdatesTask != nil || bgActivitySession != nil
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        if #available(iOS 17.0, *) {
            // The one and only invalidate this session ever gets
            // ([T-bka-session-single-invalidate]).
            (bgActivitySession as? CLBackgroundActivitySession)?.invalidate()
        }
        bgActivitySession = nil
        if hadSomething {
            logger.info("[BKA][LocationLA] stopped")
        }
    }

    /// Retract a CLBackgroundActivitySession orphaned by a prior force-kill /
    /// crash, clearing the pinned system location indicator.
    ///
    /// [T-ios-bgactivitysession-leak] When a previous process died without
    /// invalidating its session, iOS keeps the location indicator pinned and
    /// relaunches us on tap. That leaked session belongs to the dead process, so
    /// our `bgActivitySession` is nil and `stopBackgroundActivitySession()`
    /// can't reach it. The only reliable retraction is to create a fresh session
    /// and immediately invalidate it: that hands iOS a live handle for *this*
    /// process which we then explicitly end, clearing the "app is using
    /// background location" status (and its indicator).
    ///
    /// `caller` is logged so we can tell which path (cold start / foreground)
    /// actually cleared a leak. Safe to call whenever WE are not currently
    /// running our own session — guarded on `liveUpdatesTask == nil &&
    /// bgActivitySession == nil` so it never tears down a live, owned session.
    /// Note: it intentionally does NOT skip when a task is active — a leaked
    /// session must be retracted even mid-task; if keep-alive should genuinely
    /// run, the subsequent `evaluateBackgroundActivitySession()` recreates a
    /// fresh, owned session.
    private func retractOrphanedLocationSession(caller: String) {
        guard #available(iOS 17.0, *) else { return }
        guard liveUpdatesTask == nil, bgActivitySession == nil else { return }
        if Self.debugAutoRetractDisabled {
            logger.info("[BKA][RetractExp] automatic retract SKIPPED (caller=\(caller)) - experiment switch on")
            return
        }
        let probe = CLBackgroundActivitySession()
        probe.invalidate()
        logger.info("[BKA][LocationLA] retracted orphaned CLBackgroundActivitySession (caller=\(caller))")
    }

    // MARK: - Orphan-retract experiment ([T-bka-orphan-retract-exp], DEBUG)

    /// DEBUG only: when set, every automatic orphan retract (AppDelegate
    /// launch probe, setup, foreground) is skipped, so a session leaked by a
    /// killed process survives into the next one and a retract strategy can be
    /// tried on it in isolation. Always false in Release.
    static let debugAutoRetractDisabledKey = "debug.bka.autoRetractDisabled"
    nonisolated static var debugAutoRetractDisabled: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: debugAutoRetractDisabledKey)
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Run one retract strategy on a leaked session and log each step with
    /// its time, so the status bar can be checked against the log:
    ///   - probe:       new CLBackgroundActivitySession, invalidate at once (what ships)
    ///   - delayed1/5:  the same after 1s / 5s
    ///   - liveUpdates: new session + CLLocationUpdate.liveUpdates; after the
    ///                  first update (15s cap) stop the stream and invalidate
    func debugRetractExperiment(strategy: String) async -> [String: Any] {
        guard #available(iOS 17.0, *) else { return ["ok": false, "error": "iOS 17+ only"] }
        let t0 = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
        let tag = "[BKA][RetractExp] strategy=\(strategy)"
        logger.info("\(tag) BEGIN ownSession=\(self.bgActivitySession != nil) ownStream=\(self.liveUpdatesTask != nil) appState=\(UIApplication.shared.applicationState.rawValue)")
        var steps: [String] = []
        func step(_ s: String) { steps.append("\(ms())ms \(s)"); logger.info("\(tag) +\(ms())ms \(s)") }
        switch strategy {
        case "probe", "delayed1", "delayed5":
            let delay: UInt64 = strategy == "delayed1" ? 1 : strategy == "delayed5" ? 5 : 0
            if delay > 0 {
                step("waiting \(delay)s")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            let probe = CLBackgroundActivitySession()
            step("session created")
            probe.invalidate()
            step("session invalidated")
        case "liveUpdates":
            let session = CLBackgroundActivitySession()
            step("session created")
            let first = await withTaskGroup(of: String.self) { group -> String in
                group.addTask {
                    do {
                        for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                            return update.location == nil ? "update without location" : "update with location"
                        }
                        return "stream ended without an update"
                    } catch {
                        return "stream error \(error.localizedDescription)"
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    return "no update within 15s"
                }
                let r = await group.next() ?? "nothing"
                group.cancelAll()
                return r
            }
            step("liveUpdates: \(first); stream stopped")
            session.invalidate()
            step("session invalidated")
        default:
            return ["ok": false, "error": "strategy must be probe / delayed1 / delayed5 / liveUpdates"]
        }
        logger.info("\(tag) END")
        return ["ok": true, "strategy": strategy, "steps": steps]
    }
    #endif

    // MARK: - Silent Audio Keep-Alive

    private func evaluateSilentAudio(caller: String = #function) {
        // Self-heal a leaked suspendCount. suspend/resume should pair, but
        // task cancellation, network timeouts mid-playback, etc. occasionally
        // skip the resume call. If keepalive should be active and silent
        // audio is NOT running yet the count is stuck > 2, treat it as leaked
        // and reset so we can re-engage keepalive.
        if isActive && appIsInBackground && backgroundSpeakEnabled
            && !silentAudioActive && silentAudioSuspendCount > 2 {
            logger.warning("[BackgroundKeepAlive] silentAudioSuspendCount=\(self.silentAudioSuspendCount) looks leaked — resetting to 0")
            silentAudioSuspendCount = 0
        }

        let shouldPlay = isActive && backgroundSpeakEnabled && appIsInBackground && silentAudioSuspendCount == 0
        let sessions = SessionActivityTracker.shared.busySessions.count
        let reason: String = {
            if !isActive { return "isActive=false" }
            if !backgroundSpeakEnabled { return "bgSpeak=false" }
            if !appIsInBackground { return "bg=false" }
            if silentAudioSuspendCount > 0 { return "suspended=\(silentAudioSuspendCount)" }
            return "ok"
        }()
        // [BKA][Evaluate] decision chain — caller, all inputs, and the resolved
        // PLAY / STOP / NOOP decision so the crash-time timeline shows exactly
        // who triggered each evaluation and why it stopped or started audio.
        let decision: String = {
            if shouldPlay { return silentAudioActive ? "NOOP(already playing)" : "PLAY" }
            return silentAudioActive ? "STOP" : "NOOP(already stopped)"
        }()
        logger.info("[BKA][Evaluate] caller=\(caller) isActive=\(self.isActive) bgSpeak=\(self.backgroundSpeakEnabled) bg=\(self.appIsInBackground) sessions=\(sessions) suspended=\(self.silentAudioSuspendCount) playing=\(self.silentAudioActive) stopDebounce=\(self.stopDebouncePending ? "pending" : "nil") → decision=\(decision) reason=\(reason)")

        if shouldPlay {
            // [T-bg-idle-grace-cancel] Work is back (or never left): any idle
            // grace armed while the tracked set was briefly empty is moot.
            //
            // This used to live in a trailing `else if shouldPlay` branch that
            // could never run — the two branches below cover every shouldPlay
            // case first. The grace armed at a sub agent → parent handoff (the
            // child leaves the tracked set, the parent joins it milliseconds
            // later) therefore survived with the parent running, expired 60 s
            // later and stopped the keep-alive; iOS then terminated the app
            // mid-task with no crash report. Field log 2026-09-26: four
            // terminations, each `IdleGrace expired … sessions=1` followed by
            // `remaining: 0.0s`. Cancelled here, ahead of both branches.
            cancelIdleGrace(reason: "work resumed (shouldPlay)")
        }
        if shouldPlay && !silentAudioActive {
            // A fresh background signal (or any condition that re-enables play)
            // cancels any debounced stop in flight — the transient foreground
            // blip is over and we want to keep the audio running.
            cancelPendingSilentAudioStop(reason: "shouldPlay=true")
            startSilentAudio()
        } else if shouldPlay && silentAudioActive {
            // Already playing AND should keep playing — a transient foreground
            // blip that flipped back before its debounce fired. Make sure no
            // stale stop is still queued.
            cancelPendingSilentAudioStop(reason: "still shouldPlay")
        } else if !shouldPlay && silentAudioActive {
            // [T-ios-bg-idle-grace] Split the single "should stop" branch by WHY.
            // Only the pure-idle transition (isActive went false while every other
            // condition still says "keep playing") gets the 60s grace window.
            // Everything else — Background Speak switched off, an explicit media
            // suspend, a genuine foreground return — is an explicit intent to
            // stop and must take effect immediately, so those fall through to the
            // pre-existing path unchanged (which includes the 1.5s transient-
            // foreground debounce; the two windows never overlap because this
            // branch requires appIsInBackground && backgroundSpeakEnabled).
            let idleOnly = !isActive
                && backgroundSpeakEnabled
                && appIsInBackground
                && silentAudioSuspendCount == 0
            if idleOnly {
                beginIdleGraceIfNeeded()
            } else {
                // An explicit stop supersedes a grace window already in flight.
                cancelIdleGrace(reason: "explicit stop (\(reason))")
                requestStopSilentAudio(transientForeground: !appIsInBackground)
            }
        }
    }

    // MARK: - [T-ios-bg-idle-grace] Idle grace period

    /// Arm the one-shot idle grace timer, unless one is already pending.
    ///
    /// Purely time-driven: it consults no "is something still running" signal.
    /// It buys a fixed, bounded window of background battery in exchange for
    /// tolerating a state-sync hiccup around the moment the last session ends.
    ///
    /// Leak safety — this timer is cleared in EVERY one of these paths:
    ///   1. its own handler, which always nils it before doing anything else;
    ///   2. `cancelIdleGrace` from `evaluateSilentAudio` when work returns
    ///      (`shouldPlay`) or when an explicit stop reason appears;
    ///   3. `stopSilentAudio` — catches direct callers (media suspend,
    ///      interruption teardown) that bypass `evaluateSilentAudio` entirely;
    ///   4. `startSilentAudio` — a restart must never leave a stale stop queued;
    ///   5. `prepareForTermination`.
    /// Non-repeating by construction (`.now() + interval`, no `repeating:`), so
    /// even a missed cleanup can only ever fire once.
    private func beginIdleGraceIfNeeded() {
        // Idempotent: never let repeated evaluations stack timers or slide the
        // deadline forward, which is what would turn this into "keep-alive that
        // never stops".
        guard idleGraceTimer == nil else {
            let waited = idleGraceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            logger.info("[BKA][IdleGrace] already pending (\(String(format: "%.1f", waited))s elapsed) — not re-arming")
            return
        }
        logger.info("[BKA][IdleGrace] idle — holding keep-alive for \(Int(Self.idleGracePeriod))s before stopping")
        recordBKAEvent("IdleGrace(start,\(Int(Self.idleGracePeriod))s)")
        idleGraceStartedAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.idleGracePeriod)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Clear state FIRST so every path below leaves no residue, and so a
            // stop triggered from here can't re-enter this handler.
            self.idleGraceTimer?.cancel()
            self.idleGraceTimer = nil
            self.idleGraceStartedAt = nil
            // Unconditional stop. Re-checking "is it still idle" here would
            // reintroduce a branch that can expire WITHOUT stopping, which is
            // exactly the failure mode this design forbids. It is safe to be
            // unconditional: any path that made keep-alive wanted again
            // (evaluateSilentAudio -> shouldPlay, startSilentAudio) has already
            // cancelled this timer, so reaching here means nothing re-armed it.
            logger.info("[BKA][IdleGrace] expired — stopping keep-alive now")
            self.stopSilentAudio(reason: "idle_grace_expired(\(Int(Self.idleGracePeriod))s)")
        }
        idleGraceTimer = timer
        timer.resume()
    }

    /// Cancel a pending idle grace. Safe to call unconditionally; a no-op when
    /// nothing is armed.
    private func cancelIdleGrace(reason: String) {
        guard let timer = idleGraceTimer else { return }
        timer.cancel()
        idleGraceTimer = nil
        let waited = idleGraceStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        idleGraceStartedAt = nil
        logger.info("[BKA][IdleGrace] cancelled after \(String(format: "%.1f", waited))s — \(reason)")
        recordBKAEvent("IdleGrace(cancel,\(reason))")
    }

    /// [T-bg-keepalive-debounce] Decide whether to stop silent audio now or
    /// after a debounce window. A stop caused purely by a `foreground` signal
    /// (`transientForeground == true`) while sessions are still active is the
    /// dangerous case: it may be the brief blip of an app switch (call ending,
    /// app-switcher peek, Dynamic Island tap, Siri/Control Center) that is about
    /// to background again. We delay it so a `background` signal arriving within
    /// the window can cancel it. Every other reason (no active sessions, media
    /// suspend, Background Speak turned off) is a genuine intent to stop, so we
    /// stop immediately.
    private func requestStopSilentAudio(transientForeground: Bool) {
        let sessionCount = SessionActivityTracker.shared.busySessions.count
        let shouldDebounce = transientForeground && sessionCount > 0
        guard shouldDebounce else {
            cancelPendingSilentAudioStop(reason: "immediate stop")
            recordBKAEvent("Stop(reason=\(transientForeground ? "foreground,sessions=0" : "non-foreground"))")
            stopSilentAudio(reason: transientForeground ? "foreground_sessions0" : "evaluate")
            return
        }
        // Already have a pending stop — let it ride (don't reset the timer, so a
        // burst of foreground passes can't indefinitely postpone the real stop).
        if pendingSilentAudioStop != nil {
            logger.info("[BKA][Debounce] already scheduled — keeping existing timer (sessions=\(sessionCount))")
            return
        }
        logger.info("[BKA][Debounce] scheduled stop in \(Self.silentAudioStopDebounce)s — sessions=\(sessionCount) caller=foregroundSignal")
        recordBKAEvent("Stop(reason=foreground,debounce=pending)")
        let scheduledAt = Date()
        pendingStopScheduledAt = scheduledAt
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSilentAudioStop = nil
            self.pendingStopScheduledAt = nil
            let nowSessions = SessionActivityTracker.shared.busySessions.count
            // Re-check the world at fire time: if we went back to background (or
            // any other reason now keeps it playing), do NOT stop.
            let stillForeground = !self.appIsInBackground
            let stillActive = self.isActive && self.backgroundSpeakEnabled
                && self.silentAudioSuspendCount == 0
            if stillForeground || !stillActive {
                logger.info("[BKA][Debounce] fired — proceeding to stop (sessions=\(nowSessions), foreground=\(stillForeground))")
                self.stopSilentAudio(reason: "debounce_expired(\(Self.silentAudioStopDebounce)s)")
            } else {
                logger.info("[BKA][Debounce] fired — skipping stop, app re-backgrounded (sessions=\(nowSessions)) — KEEPING silent audio")
                self.recordBKAEvent("Stop skipped (re-backgrounded)")
            }
        }
        pendingSilentAudioStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silentAudioStopDebounce, execute: work)
    }

    /// Cancel any in-flight debounced stop of silent audio.
    private func cancelPendingSilentAudioStop(reason: String) {
        guard let pending = pendingSilentAudioStop else { return }
        pending.cancel()
        pendingSilentAudioStop = nil
        let elapsed = pendingStopScheduledAt.map { Date().timeIntervalSince($0) }
        pendingStopScheduledAt = nil
        let elapsedStr = elapsed.map { String(format: "elapsed=%.1fs", $0) } ?? ""
        logger.info("[BKA][Debounce] cancelled — \(reason) \(elapsedStr)")
        recordBKAEvent("Debounce cancelled (\(reason))")
    }

    private func startSilentAudio(reason: String = "evaluate") {
        guard !silentAudioActive else { return }
        // Starting up means we definitely don't want any queued stop to fire.
        cancelPendingSilentAudioStop(reason: "startSilentAudio")
        cancelIdleGrace(reason: "startSilentAudio")
        let attempt = silentAudioActivationRetries + 1
        let sessions = SessionActivityTracker.shared.busySessions.count
        logger.info("[BKA][Start] reason=\(reason) sessions=\(sessions) attempt=\(attempt)/\(Self.maxActivationRetries)")
        recordBKAEvent("Start(reason=\(reason),attempt=\(attempt))")

        // [T-bg-keepalive-debounce] Activate the session, retrying on failure.
        // After a stopSilentAudio() the session was deactivated with
        // notifyOthersOnDeactivation; the system may briefly reject a
        // re-activation while another app is still re-acquiring focus, or while
        // a call/media session is releasing. A single sync attempt here closes
        // the common case; on failure we schedule an async retry (0.5s apart,
        // up to 3 total attempts) by re-invoking startSilentAudio, so we never
        // block the main thread yet still recover from the transient rejection.
        // The session category/active is owned by AudioSessionCoordinator. Declare
        // the keep-alive intent (lowest priority) — the coordinator applies the
        // .mixWithOthers profile ONLY when nothing higher (reply TTS / media /
        // capture) is active, so the silent track no longer clobbers TTS's profile.
        // The silent AVAudioEngine below plays regardless to keep the process alive.
        MainActor.assumeIsolated {
            AudioSessionCoordinator.shared.begin(.backgroundKeepAlive)
        }
        logger.info("[BKA][Start] begin(.backgroundKeepAlive) — acquiring engine")
        silentAudioActivationRetries = 0

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Create a silent audio buffer (1 second of silence, looping)
        let sampleRate: Double = 44100
        let frameCount = AVAudioFrameCount(sampleRate) // 1 second
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.error("[BackgroundKeepAlive] Failed to create silent audio buffer")
            return
        }
        buffer.frameLength = frameCount
        // Buffer is already zero-filled (silent)

        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.001

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            audioEngine = engine
            silentPlayerNode = player
            silentAudioActive = true
            startAudioUpdateTimer()
            logger.info("[BKA][Start] engine running — silent audio keep-alive ACTIVE")
        } catch {
            logger.error("[BKA][Start] engine.start() FAILED: \(error.localizedDescription)")
        }
    }

    /// [T-bg-keepalive-debounce] Schedule a delayed re-attempt of
    /// `startSilentAudio` after a `setActive(true)` rejection, up to
    /// `maxActivationRetries` total attempts. At fire time we re-check that
    /// keep-alive is still wanted (background + active + not suspended) so we
    /// don't fight a state that has since changed.
    private func scheduleSilentAudioActivationRetry() {
        silentAudioActivationRetries += 1
        guard silentAudioActivationRetries < Self.maxActivationRetries else {
            logger.error("[BKA][Start] exhausted \(Self.maxActivationRetries) activation attempts — giving up")
            recordBKAEvent("Start FAILED (exhausted retries)")
            silentAudioActivationRetries = 0
            return
        }
        let attempt = silentAudioActivationRetries
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationRetryDelay) { [weak self] in
            guard let self else { return }
            let stillWanted = self.isActive && self.backgroundSpeakEnabled
                && self.appIsInBackground && self.silentAudioSuspendCount == 0
                && !self.silentAudioActive
            guard stillWanted else {
                logger.info("[BKA][Start] activation retry #\(attempt) skipped — keep-alive no longer wanted")
                self.silentAudioActivationRetries = 0
                return
            }
            logger.info("[BKA][Start] activation retry #\(attempt) — re-attempting")
            self.startSilentAudio(reason: "activationRetry#\(attempt)")
        }
    }

    /// Called by SpeechFinishedDelegate when TTS completes, to restart silent audio if needed.
    func evaluateSilentAudioFromDelegate() {
        evaluateSilentAudio(caller: "ttsFinished")
    }

    /// [T-shortcuts-eager-keepalive] Eager keep-alive hook for AppIntent entry
    /// points (Shortcuts automations). Call this synchronously at the top of an
    /// Intent's `perform()` BEFORE any `await` that would let iOS suspend the
    /// AppIntent-woken process. It:
    ///   1) records the (already-known) session id in the tracker so the
    ///      Combine publisher fires and `reevaluate` flips `isActive` to true,
    ///   2) immediately re-evaluates silent audio so the AVAudioEngine
    ///      spins up while the process still has wall-clock time.
    ///
    /// STRICTLY gated on `enhancedBackgroundEffective` (the user's
    /// enhancedBackgroundEnabled AND backgroundSpeakEnabled toggles both being
    /// on). If the user hasn't opted into background keep-alive, this is a
    /// no-op — we do NOT silently start background audio playback behind their
    /// back. Returns `(armed, skipReason)` — a non-nil `skipReason` accompanies
    /// `armed=false` so callers can log/persist WHY we skipped without having
    /// to reconstruct the gating logic.
    @MainActor
    @discardableResult
    func armEagerlyForShortcut(sessionId: String, caller: String) -> (armed: Bool, skipReason: String?) {
        let enhancedOn = enhancedBackgroundEnabled
        let bgSpeakOn = backgroundSpeakEnabled
        if !enhancedOn || !bgSpeakOn {
            let reason: String
            if !enhancedOn && !bgSpeakOn {
                reason = "enhancedBackgroundEnabled=false;backgroundSpeakEnabled=false"
            } else if !enhancedOn {
                reason = "enhancedBackgroundEnabled=false"
            } else {
                reason = "backgroundSpeakEnabled=false"
            }
            logger.info("[ShortcutDiag] eagerKeepAlive caller=\(caller) decision=SKIPPED reason=\(reason)")
            return (false, reason)
        }
        logger.info("[ShortcutDiag] eagerKeepAlive caller=\(caller) decision=STARTED session=\(sessionId.prefix(8))")
        SessionActivityTracker.shared.setActive(sessionId, source: "\(caller).eager")
        evaluateSilentAudio(caller: "\(caller).eager")
        return (true, nil)
    }

    func stopSilentAudio(reason: String = "direct") {
        // A direct stop supersedes any debounced one and aborts pending retries.
        cancelPendingSilentAudioStop(reason: "stopSilentAudio called")
        // [T-ios-bg-idle-grace] Also clear a pending idle grace. Required, not
        // belt-and-braces: stopSilentAudio has direct callers (media suspend,
        // interruption teardown) that never go through evaluateSilentAudio, and
        // the grace timer's own handler calls in here — clearing it first there
        // makes this a no-op rather than re-entrancy.
        cancelIdleGrace(reason: "stopSilentAudio called")
        silentAudioActivationRetries = 0
        guard silentAudioActive else { return }
        let sessions = SessionActivityTracker.shared.busySessions.count
        logger.info("[BKA][Stop] reason=\(reason) sessions=\(sessions)")
        recordBKAEvent("Stop(reason=\(reason))")
        stopAudioUpdateTimer()
        silentPlayerNode?.stop()
        audioEngine?.stop()
        silentPlayerNode = nil
        audioEngine = nil
        silentAudioActive = false
        // End the keep-alive intent — the coordinator re-applies the next-highest
        // intent's profile (reply TTS / capture) or deactivates the session,
        // letting other apps resume. (No direct setActive here anymore.)
        MainActor.assumeIsolated {
            AudioSessionCoordinator.shared.end(.backgroundKeepAlive)
        }
        logger.info("[BKA][Stop] engine.stop() + end(.backgroundKeepAlive)")
    }

    // MARK: - Live Activity Updates

    /// Shared method to push a Live Activity update. Called from:
    /// - updateTimer (foreground, every 2-10s)
    /// - location callbacks (background with location tracking)
    /// - audioUpdateTimer (background with silent audio, no location)
    /// [T-ios-live-activity-audio-toggle] Entry point for audio-driven Live
    /// Activity changes. Unlike `updateLiveActivityIfNeeded` (gated on `isActive`,
    /// which is only true while an Agent task runs), this always forwards to the
    /// manager so a pure-audio playback — with zero Agent sessions — can start,
    /// refresh, or end its own Live Activity. When an Agent task is also running,
    /// the manager updates that single existing activity in place (never a 2nd one).
    func audioPlaybackStateChanged(source: String) {
        let v = VoiceOutputState.shared
        logger.info("[LiveActivity][audio] BKA forward src=\(source) reading=\(v.isReadingAloud) paused=\(v.speechPaused) isActive=\(self.isActive)")
        AgentLiveActivityManager.shared.audioStateChanged(source: source)
    }

    func updateLiveActivityIfNeeded(source: String = "?") {
        guard isActive else {
            let cnt = SessionActivityTracker.shared.liveActivitySessions.count
            if cnt > 0 {
                logger.info("[LiveActivity][update] SKIP src=\(source) isActive=false tracker=\(cnt) session(s)")
            }
            return
        }
        let sessions = SessionActivityTracker.shared.liveActivitySessions
        let count = sessions.count
        let idList = sessions.map { $0.prefix(8) }.joined(separator: ",")
        let appState: String = {
            switch UIApplication.shared.applicationState {
            case .active: return "fg"
            case .inactive: return "inactive"
            case .background: return "bg"
            @unknown default: return "?"
            }
        }()
        let silentAudio = silentAudioIsPlaying
        let bgRemaining = UIApplication.shared.backgroundTimeRemaining
        let remainStr = bgRemaining > 99999 ? "unlimited" : String(format: "%.0fs", bgRemaining)
        logger.info("[LiveActivity][update] src=\(source) sessions=\(count) ids=[\(idList)] appState=\(appState) silentAudio=\(silentAudio) bgRemaining=\(remainStr)")
        AgentLiveActivityManager.shared.updateActivity(sessions: buildSessionSnapshots())
    }

    /// [T-ios-live-activity-audio-toggle] Public accessor so the Live Activity
    /// manager's audio-only start/update path can rebuild the current session
    /// snapshots (empty when only audio is active).
    func buildLiveSessionSnapshots() -> [LiveSessionSnapshot] {
        buildSessionSnapshots()
    }

    private func buildSessionSnapshots() -> [LiveSessionSnapshot] {
        guard #available(iOS 16.2, *) else { return [] }
        let tracker = SessionActivityTracker.shared
        let running = tracker.activeSessions.sorted().map { sid in
            let info = tracker.sessionToolInfo[sid]
            let title = info?.title ?? ""
            let toolName = info?.toolName ?? ""
            let toolStatus = info?.toolStatus ?? ""
            let icon = AgentLiveActivityManager.sfSymbol(forTool: toolName)
            let displayName = AgentLiveActivityManager.displayName(forTool: toolName)
            let statusText: String
            if toolName.isEmpty {
                statusText = AppLocalized("Working...")
            } else if toolStatus.isEmpty {
                statusText = displayName
            } else {
                statusText = "\(displayName) · \(toolStatus)"
            }
            logger.info("[LiveActivity][snapshot] sid=\(sid.prefix(8)) toolName=\(toolName) icon=\(icon) status=\(statusText) title=\(title.prefix(20))")
            return LiveSessionSnapshot(
                sessionId: sid,
                title: title.isEmpty ? AppLocalized("Agent Task") : title,
                toolIcon: icon,
                toolStatus: statusText,
                loopIteration: info?.loopIteration ?? 0
            )
        }
        // [T-live-activity-scheduled] Plus a card per conversation waiting for
        // its next scheduled run, built from the chat pill's own data.
        let waiting = ScheduledBannerModel.liveActivityWaitCards(
            for: tracker.scheduledSessions.subtracting(tracker.activeSessions).sorted(),
            titles: tracker.knownTitles)
        for card in waiting {
            logger.info("[LiveActivity][snapshot] sid=\(card.sessionId.prefix(8)) scheduled status=\(card.toolStatus) next=\(card.nextRunAt.map { String(Int($0.timeIntervalSinceNow)) } ?? "-")s")
        }
        return running + waiting
    }

    /// [T-la-refresh-5s] How often the Live Activity is refreshed by the
    /// foreground / background-audio timers (and, when a continued-processing
    /// task holds the app, in the background too). 5s, down from 10s: it
    /// matches the location tick and AgentLiveActivityManager's background
    /// rate limit (5s), so the card's status keeps up with tool changes.
    private var updateInterval: TimeInterval {
        return 5.0
    }

    /// Foreground RunLoop timer — works while app is active.
    private func startUpdateTimer() {
        stopUpdateTimer()
        let interval = updateInterval
        logger.info("[BackgroundKeepAlive] Starting update timer (interval=\(interval)s)")
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLiveActivityIfNeeded(source: "fgTimer")
            }
        }
        RunLoop.current.add(updateTimer!, forMode: .common)
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    // MARK: - Background Audio Update Timer

    /// A GCD timer that fires even when the main RunLoop is suspended,
    /// as long as the process stays alive (via audio or location background mode).
    private var audioUpdateTimer: DispatchSourceTimer?

    private func startAudioUpdateTimer() {
        stopAudioUpdateTimer()
        stopUpdateTimer()
        let interval = updateInterval
        logger.info("[BackgroundKeepAlive] Starting audio update timer (interval=\(interval)s) — fgTimer suspended")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                // [T-bka-audio-dead-watchdog] First: is the audio that keeps
                // this timer (and the process) alive still playing?
                self?.reviveSilentAudioIfDead(source: "watchdog")
                self?.updateLiveActivityIfNeeded(source: "bgAudioTimer")
            }
        }
        timer.resume()
        audioUpdateTimer = timer
    }

    private func stopAudioUpdateTimer() {
        guard audioUpdateTimer != nil else { return }
        audioUpdateTimer?.cancel()
        audioUpdateTimer = nil
        if isActive {
            startUpdateTimer()
            logger.info("[BackgroundKeepAlive] audioUpdateTimer stopped — fgTimer resumed")
        }
    }
}

// MARK: - Background Interruption Tracker

@MainActor
final class BackgroundInterruptionTracker: ObservableObject {
    static let shared = BackgroundInterruptionTracker()

    @Published var showBanner = false

    /// [T-bka-continued-hint] Why the banner is up. `.interrupted`: the system
    /// suspended a run that had no keep-alive. `.ranSlowly`: the run stayed
    /// alive in the background, but on iOS 26's continued-processing task -
    /// the fallback keep-alive, which gets about a fifth of the CPU the
    /// background-audio keep-alive does - so the banner suggests that one.
    enum Reason { case interrupted, ranSlowly }
    @Published private(set) var reason: Reason = .interrupted

    /// Deep-link focus for "Enable": the switches that make the audio
    /// keep-alive effective, plus Location Tracking - the standing location
    /// session is what keeps the Live Activity refreshing - unless location
    /// is switched off by the DEBUG override (LocationLAMode).
    static var enableFocusQuery: String {
        var q = "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true"
        if BackgroundKeepAliveManager.locationKeepAliveUsed { q += ",locationTrackingEnabled:true" }
        return q
    }

    /// How many interruptions must accumulate before the banner is shown again.
    /// Starts at 1 (remind on every interruption). Each "Remind me later" tap
    /// doubles it, clamped to [minInterval, maxInterval] — true exponential
    /// back-off: 1 → 2 → 4 → 8 → 10 (capped).
    private static let minInterval = 1
    private static let maxInterval = 10
    private static let intervalKey = "enhancedBackgroundRemindInterval"
    private static let countKey = "enhancedBackgroundInterruptionCount"

    /// Current reminder frequency (show the banner once every `remindInterval`
    /// interruptions). Defaults to 1 when unset.
    var remindInterval: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
            return stored <= 0 ? 1 : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.intervalKey) }
    }

    /// Accumulated interruptions since the last time the banner was shown or
    /// the user tapped "Remind me later".
    private var interruptionCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.countKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.countKey) }
    }

    private var wasInterrupted = false
    private var ranOnContinuedTask = false
    private var cancellables: Set<AnyCancellable> = []

    // [T-ios-scene-create-watchdog-corelocation] This singleton is first touched
    // from a SwiftUI view body (BackgroundInterruptionBanner, mounted at the app
    // root), so its init runs on the main thread during scene-create. Reaching
    // for `BackgroundKeepAliveManager.shared` HERE is what dragged that manager's
    // own dispatch_once — and, before the fix, its CoreLocation IPC — onto that
    // critical path. Keep this init free of cross-singleton work and subscribe
    // lazily instead.
    private init() {}

    /// Auto-dismiss the banner once enhanced background is turned on, so the
    /// user isn't left wondering what else they need to enable after tapping
    /// "Enable" and flipping the switch. Deferred out of `init()` (see above);
    /// idempotent, and only forces the keep-alive manager once the banner is
    /// actually being observed.
    private var didSubscribe = false
    func startObservingIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        BackgroundKeepAliveManager.shared.$enhancedBackgroundEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, enabled, self.showBanner else { return }
                self.showBanner = false
            }
            .store(in: &cancellables)
    }

    func recordInterruption() {
        wasInterrupted = true
    }

    /// [T-bka-continued-hint] The continued-processing task held the app in
    /// the background (called from its progress ticks). Counted like an
    /// interruption on the next foreground return, same reminder back-off.
    func recordContinuedFallback() {
        ranOnContinuedTask = true
    }

    /// Called when app returns to foreground. Counts the interruption (or the
    /// slow continued-task period) and only surfaces the banner once the
    /// running count reaches `remindInterval`. A real interruption wins over
    /// a slow period: it is the worse outcome.
    func checkOnForeground() {
        let interrupted = wasInterrupted
        let slow = ranOnContinuedTask
        wasInterrupted = false
        ranOnContinuedTask = false
        guard interrupted || slow,
              !BackgroundKeepAliveManager.shared.enhancedBackgroundEffective else { return }

        interruptionCount += 1
        guard interruptionCount >= remindInterval else { return }
        // Threshold reached — reset the counter and show the banner.
        interruptionCount = 0
        reason = interrupted ? .interrupted : .ranSlowly
        showBanner = true
    }

    func dismiss() {
        showBanner = false
    }

    /// "Remind me later" — back off the reminder frequency (double it, clamped
    /// to [minInterval, maxInterval]), clear the accumulated count, and dismiss.
    func remindLaterAndDismiss() {
        let doubled = remindInterval * 2
        remindInterval = min(max(doubled, Self.minInterval), Self.maxInterval)
        interruptionCount = 0
        showBanner = false
    }
}

// MARK: - Background Interruption Banner

struct BackgroundInterruptionBanner: View {
    @ObservedObject private var tracker = BackgroundInterruptionTracker.shared
    @State private var dragOffset: CGFloat = 0
    @State private var showSettings = false

    private let dismissThreshold: CGFloat = 40

    var body: some View {
        if tracker.showBanner {
            bannerContent
                .transition(.move(edge: .top).combined(with: .opacity))
                .offset(y: min(dragOffset, 0))
                .gesture(swipeToDismiss)
                .animation(.spring(response: 0.35), value: tracker.showBanner)
                .sheet(isPresented: $showSettings) {
                    NavigationStack { EnhancedBackgroundSettingsView() }
                }
                // [T-ios-scene-create-watchdog-corelocation] Subscribe only once
                // the banner is actually on screen — the subscription exists to
                // auto-dismiss a VISIBLE banner, so there is nothing to observe
                // before that. This keeps BackgroundKeepAliveManager.shared off
                // the scene-create path (it is otherwise forced by setup(), well
                // after the scene exists).
                .onAppear { tracker.startObservingIfNeeded() }
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(tracker.reason == .ranSlowly
                     ? AppLocalized("Background Task Ran Slowly")
                     : AppLocalized("Background Task Interrupted"))
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text(tracker.reason == .ranSlowly
                     // Says what to turn on, not how it works: App Review
                     // reads user-facing text about background keep-alive.
                     ? AppLocalized("Turn on Enhanced Background for better background performance")
                     : AppLocalized("Enable enhanced background to keep tasks running"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
            }

            Spacer()

            VStack(spacing: 6) {
                Button {
                    DeepLinkCoordinator.shared.setFocus(
                        rawQueryValue: BackgroundInterruptionTracker.enableFocusQuery)
                    showSettings = true
                    withAnimation { tracker.dismiss() }
                } label: {
                    Text("Enable")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.white)
                        .foregroundColor(.orange)
                        .cornerRadius(14)
                }

                Button {
                    withAnimation { tracker.remindLaterAndDismiss() }
                } label: {
                    Text("Remind me later")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.orange.gradient)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var swipeToDismiss: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                if value.translation.height < -dismissThreshold {
                    withAnimation { tracker.dismiss() }
                }
                dragOffset = 0
            }
    }
}

// [T-sched-notif-in-place] BEGIN bg-task-notification-id
/// Identity of the "task finished in the background" notification.
///
/// iOS replaces a delivered notification in place when a new request reuses its
/// identifier. A scheduled task fires again and again in the same conversation,
/// and with a fresh identifier per completion every run added another entry - a
/// loop every 10 minutes left a column of identical banners in Notification
/// Center. A run opened by a scheduled firing now uses one identifier per
/// (conversation, scheduled task), so each run updates that task's notification;
/// any other completion keeps its own entry, as before.
enum BackgroundTaskNotificationID {
    static func make(sessionId: String, scheduledJobId: String?, now: Date) -> String {
        if let scheduledJobId, !scheduledJobId.isEmpty {
            return "bg-task-\(sessionId)-job-\(scheduledJobId)"
        }
        return "bg-task-\(sessionId)-\(now.timeIntervalSince1970)"
    }

    /// The scheduled task whose firing opened a turn, from the text parts of the
    /// user message that opened it: a firing arrives as a `kind="scheduled"`
    /// agent callback envelope, on its own or next to other parts (a queued
    /// injection adds its reminder as a separate part).
    static func scheduledJobId(inTurnTexts texts: [String]) -> String? {
        for text in texts {
            guard let callback = AgentCallback.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  callback.kind == .scheduled else { continue }
            return callback.jobId
        }
        return nil
    }
}
// [T-sched-notif-in-place] END bg-task-notification-id

// MARK: - Continued processing (iOS 26+) [T-bka-continued-processing]

/// iOS 26's BGContinuedProcessingTask as the FALLBACK keep-alive.
///
/// [T-bka-continued-preferred-switch] Opt-in: the settings switch "Prefer
/// Continued Background Processing (iOS 26+)" (continuedProcessingPreferred)
/// is OFF by default.
///   - Off: the usual scheme - silent audio keeps the app alive, the standing
///     location session keeps the Live Activity rendering (see
///     LocationLAMode; without it the Lock Screen freezes ~30s after
///     backgrounding, iOS 26 and 27 alike). No continued task.
///   - On: every run started in the foreground gets a continued task, and
///     while it runs the location keep-alive stands down - the task keeps the
///     Live Activity refreshing instead, with no location indicator. Silent
///     audio is untouched (it keeps full background CPU, which the task alone
///     does not get - about a fifth in the device bench). If the task cannot
///     be submitted (a run started in the background) or ends early (system
///     expiry, Stop on its card), location comes back for the rest of the run.
///   The task shows the system's own task card with a Stop button, hence
///   opt-in.
///
/// Modes under the switch (UserDefaults bka.continuedProcessingMode, DEBUG RPC
/// debug.bka.setContinuedMode):
///   - preferred (default): as above;
///   - fallback: only for runs without the silent-audio keep-alive, and
///     location is not suppressed (the T-bka-continued-fallback scheme);
///   - off: never.
///
/// The system only accepts the request from the foreground app, so it is
/// submitted when a run starts while the app is active; a run that starts in
/// the background (a scheduled job, a relaunch) gets no continued task. The
/// task must report progress, or it is expired as stalled: a 2s timer
/// advances it and mirrors the first busy session's title / status.
extension BackgroundKeepAliveManager {
    enum ContinuedMode: String { case off, preferred, fallback }

    static let continuedModeKey = "bka.continuedProcessingMode"
    static let continuedIdPrefix = "com.openminis.app.continued."

    /// The settings switch wins: off (the default) means never. When it is on,
    /// a DEBUG override (bka.continuedProcessingMode) may pick another mode;
    /// otherwise preferred. An unknown stored value (an older build's
    /// replaceLocation / always / alongside) reads as preferred.
    static var continuedMode: ContinuedMode {
        let d = UserDefaults.standard
        guard (d.object(forKey: continuedPreferredKey) as? Bool) ?? false else { return .off }
        return ContinuedMode(rawValue: d.string(forKey: continuedModeKey) ?? "") ?? .preferred
    }

    /// [T-bka-loc-pulse] How location keeps the Live Activity refreshing in
    /// the background:
    ///   - continuous (default, every iOS version): one session for the
    ///     whole background period;
    ///   - off (experiment only): none.
    /// A "pulse" mode (a session every 15s, closed at its first fix) was
    /// tried and removed: see the results below.
    ///
    /// [T-bka-location-continuous-ios27] Device results, iPhone 17 Pro,
    /// iOS 27.0.1, 2026-10-02/03, app alive in the background on silent
    /// audio and pushing every 5s (each update() returned, activityState
    /// active):
    ///   - no location: the Lock Screen stops changing ~30s after backgrounding;
    ///   - pulse: every pulse was answered from a fresh system fix in ~20ms
    ///     (11-14m accuracy despite asking for 3 km), so each session lived
    ///     ~20ms - the Lock Screen still froze;
    ///   - a brief continued-processing task at willResignActive
    ///     (T-bka-continued-kick): froze at ~10s;
    ///   - continuous: kept updating.
    /// So only a standing location session keeps the Live Activity rendering.
    /// Override: UserDefaults bka.locationLAMode / DEBUG RPC
    /// debug.bka.setLocationMode.
    enum LocationLAMode: String { case continuous, off }
    static let locationLAModeKey = "bka.locationLAMode"

    nonisolated static var locationLAMode: LocationLAMode {
        if let raw = UserDefaults.standard.string(forKey: locationLAModeKey),
           let mode = LocationLAMode(rawValue: raw) { return mode }
        return .continuous
    }

    nonisolated static var locationKeepAliveUsed: Bool { locationLAMode != .off }

    /// [T-bka-la-after-task] Experiment, DEBUG-switchable (setProfile
    /// laRestartAfterTask): re-create the Live Activity after the continued
    /// task is up, so it is the newest system activity. off (default) /
    /// taskStart (when the task starts, ~60ms after submit) / resignActive
    /// (as the app leaves the foreground, if the task runs).
    static let laRestartAfterTaskKey = "bka.laRestartAfterTask"
    nonisolated static var laRestartAfterTask: String {
        UserDefaults.standard.string(forKey: laRestartAfterTaskKey) ?? "off"
    }

    /// Whether this run should have a continued task: always in preferred
    /// mode, only without the silent-audio keep-alive in fallback mode.
    var continuedWanted: Bool {
        switch Self.continuedMode {
        case .off: return false
        case .preferred: return true
        case .fallback: return !enhancedBackgroundEffective
        }
    }

    /// While the task runs in preferred mode, it - not location - keeps the
    /// Live Activity refreshing, so both location legs stand down.
    var continuedReplacesLocation: Bool {
        continuedTask != nil && Self.continuedMode == .preferred
    }

    /// [T-bka-continued-card-copy] What the system's task card shows.
    /// [T-bka-continued-card-status] Title stays fixed; the subtitle now says
    /// what the most recently active session is doing, like the Live Activity:
    /// "Thinking deeply…", "Replying…", or the tool and its title ("Shell ·
    /// Build the project"), prefixed with the session count when more than one
    /// runs. Task Status Privacy keeps the old content-free text (session count
    /// and "please don't stop"), as it redacts the Live Activity. Refreshed with
    /// every progress tick (2s), so it follows the run.
    private func continuedCardText() -> (title: String, subtitle: String) {
        let tracker = SessionActivityTracker.shared
        let n = max(1, tracker.busySessions.count)
        let title = AppLocalized("Minis is Processing…")
        if liveActivityPrivacyMode {
            // Kept short: the card truncates long subtitles (seen on device).
            let subtitle = n == 1
                ? AppLocalized("1 session running, please don't stop")
                : String(format: AppLocalized("%lld sessions running, please don't stop"), n)
            return (title, subtitle)
        }
        let latest = tracker.sessionToolInfo
            .filter { tracker.activeSessions.contains($0.key) }
            .max { $0.value.lastActivity < $1.value.lastActivity }?.value
        let status = ContinuedCardStatus.text(toolName: latest?.toolName ?? "",
                                              toolStatus: latest?.toolStatus ?? "",
                                              localize: { AppLocalized(String.LocalizationValue($0)) })
        return (title, ContinuedCardStatus.subtitle(status: status, sessionCount: n, localize: { AppLocalized(String.LocalizationValue($0)) }))
    }

    var continuedTaskRunning: Bool { continuedTask != nil }

    /// [T-crash-keepalive-heartbeat] What is holding the app in the background
    /// right now, for the crash heartbeat: with it, a kill after the keep-alive
    /// audio was lost is classified as that instead of "cause undetermined".
    var keepAliveHeartbeat: [String: Any] {
        let remaining = UIApplication.shared.backgroundTimeRemaining
        var d: [String: Any] = [
            "configured": enhancedBackgroundEffective,
            "audioPlaying": silentAudioIsPlaying,
            "continued": continuedTaskRunning,
            // -1 = unlimited (foreground, or a background mode is holding the app)
            "bgRemaining": remaining > 99_999 ? -1 : Int(remaining),
        ]
        if let at = lastAudioInterruptionAt {
            d["audioInterruption"] = lastAudioInterruption
            d["audioInterruptionAgoS"] = Int(Date().timeIntervalSince(at))
        }
        return d
    }

    /// Run `body` once if the continued task ends while the run is still
    /// going. AIChatViewModel ends its expiring UIKit background task while
    /// the continued task holds the app (see its expiry handler); this lets
    /// it take a fresh one when the hold goes away, so the usual expiry path
    /// (re-arm under silent audio, or suspend and resume in the foreground)
    /// applies again instead of the app being frozen mid-call. Dropped
    /// without running when the run ends.
    func onContinuedTaskEndedMidRun(_ body: @escaping () -> Void) {
        continuedEndCallbacks.append(body)
    }

    func evaluateContinuedProcessing(caller: String) {
        guard #available(iOS 26.0, *) else { return }
        // An iPad app on a Mac is never suspended in the background.
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp { return }
        let mode = Self.continuedMode
        guard continuedBusy, continuedWanted else {
            finishContinuedTask(success: true, reason: "\(caller) mode=\(mode.rawValue) busy=\(continuedBusy) wanted=\(continuedWanted)")
            return
        }
        guard continuedTask == nil, continuedPendingId == nil, !continuedUnavailableThisRun else { return }
        guard UIApplication.shared.applicationState == .active else {
            // [T-bka-continued-retry-foreground] Not `continuedUnavailableThisRun`:
            // that gave up for the whole run, so a run that (re)started in the
            // background never got a task even after the user opened the app
            // (2026-10-09: none from 17:23 to the kill at 18:01, across three
            // foreground visits).
            if !continuedAwaitingForeground {
                logger.info("[BKA][Continued] not submitted (caller=\(caller)) - app not in the foreground; will ask again when it is")
            }
            continuedAwaitingForeground = true
            return
        }
        continuedAwaitingForeground = false
        submitContinuedTask(caller: caller)
    }

    @available(iOS 26.0, *)
    private func submitContinuedTask(caller: String) {
        // A fresh identifier per request: registering one identifier twice
        // kills the app (BGTaskScheduler).
        let id = Self.continuedIdPrefix + UUID().uuidString.prefix(8)
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            // Logged here, on the handler's own thread: a hop to the main actor
            // first would lose the line if the process is suspended right after.
            task.expirationHandler = {
                NSLog("[BackgroundKeepAlive] [WARN] [BKA][Continued] expirationHandler fired id=%@", id)
                Task { @MainActor [weak self] in self?.continuedTaskExpired(id: id) }
            }
            let hold = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in self?.continuedTaskStarted(task, id: id, hold: hold) }
            // Keep the launch handler running until the task is completed
            // (Apple's examples do the work inside the handler).
            hold.wait()
            NSLog("[BackgroundKeepAlive] [INFO] [BKA][Continued] launch handler returned id=%@", id)
        }
        guard registered else {
            logger.warning("[BKA][Continued] register FAILED id=\(id) - is \(Self.continuedIdPrefix)* in BGTaskSchedulerPermittedIdentifiers?")
            continuedUnavailableThisRun = true
            return
        }
        let card = continuedCardText()
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: card.title, subtitle: card.subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedPendingId = id
            logger.info("[BKA][Continued] submitted id=\(id) caller=\(caller) mode=\(Self.continuedMode.rawValue)")
        } catch {
            let ns = error as NSError
            logger.warning("[BKA][Continued] submit FAILED id=\(id): \(ns.domain) \(ns.code) \(ns.localizedDescription) - legacy keep-alive covers this run")
            continuedUnavailableThisRun = true
        }
    }

    @available(iOS 26.0, *)
    private func continuedTaskStarted(_ task: BGContinuedProcessingTask, id: String, hold: DispatchSemaphore) {
        guard continuedPendingId == id, continuedBusy else {
            logger.info("[BKA][Continued] task \(id) started after its run ended - completing at once")
            task.setTaskCompleted(success: true)
            hold.signal()
            return
        }
        continuedPendingId = nil
        continuedTask = task
        continuedHandlerHold = hold
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 0
        logger.info("[BKA][Continued] task STARTED id=\(id) appState=\(UIApplication.shared.applicationState.rawValue)")
        if Self.laRestartAfterTask == "taskStart" {
            AgentLiveActivityManager.shared.restartForIslandPriority(reason: "continuedTaskStarted")
        }
        continuedProgressTimer?.invalidate()
        continuedProgressTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickContinuedProgress() }
        }
        // Preferred mode: location stands down while the task runs.
        evaluateLocationUpdates()
        evaluateBackgroundActivitySession()
    }

    @available(iOS 26.0, *)
    private func tickContinuedProgress() {
        guard let task = continuedTask as? BGContinuedProcessingTask else { return }
        let p = task.progress
        // Unknown length: keep moving, never reaching the end.
        if p.totalUnitCount - p.completedUnitCount < 10 { p.totalUnitCount += 100 }
        p.completedUnitCount += 1
        let card = continuedCardText()
        task.updateTitle(card.title, subtitle: card.subtitle)
        if UIApplication.shared.applicationState != .active {
            continuedLastBackgroundTick = Date()
            BackgroundInterruptionTracker.shared.recordContinuedFallback()
        }
        if p.completedUnitCount % 5 == 0 {
            logger.info("[BKA][Continued] tick \(p.completedUnitCount)/\(p.totalUnitCount) appState=\(UIApplication.shared.applicationState.rawValue) bgRemaining=\(Int(min(UIApplication.shared.backgroundTimeRemaining, 99999)))")
        }
    }

    private func continuedTaskExpired(id: String) {
        // Also what the card's Stop button produces: the API does not tell the
        // two apart. No new request this run.
        logger.warning("[BKA][Continued] task EXPIRED id=\(id) (system expiry or Stop on the card)")
        continuedUnavailableThisRun = true
        finishContinuedTask(success: false, reason: "expired")
    }

    func finishContinuedTask(success: Bool, reason: String) {
        continuedProgressTimer?.invalidate()
        continuedProgressTimer = nil
        continuedPendingId = nil
        let callbacks = continuedEndCallbacks
        continuedEndCallbacks = []
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        continuedTask = nil
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: success)
        continuedHandlerHold?.signal()
        continuedHandlerHold = nil
        logger.info("[BKA][Continued] task COMPLETED success=\(success) reason=\(reason) busy=\(continuedBusy) endCallbacks=\(callbacks.count)")
        // Location takes over again if the run goes on (no-op once it ended).
        evaluateLocationUpdates()
        evaluateBackgroundActivitySession()
        if continuedBusy { callbacks.forEach { $0() } }
    }
}

// [T-mac-dock-badge] BEGIN user-attention-badge
/// Whether the user is looking at Minis.
///
/// On iPhone and iPad that is the app state. An iPad app running on a Mac is
/// different: measured on macOS (a UIKit probe app, and two weeks of Minis logs
/// on a Mac with 32 task completions, every one `wasBackground=false` and no
/// scenePhase change at all), `applicationState` stays `.active` and the scene
/// stays `foregroundActive` while another app is frontmost. Switching apps only
/// posts AppKit's app-level activate/resign notifications, which UIKit on the
/// Mac forwards to `NotificationCenter.default`. So on a Mac "away" means "not
/// the frontmost app", tracked from those two notifications.
enum UserAttention {
    static let macDidBecomeActive = Notification.Name("NSApplicationDidBecomeActiveNotification")
    static let macDidResignActive = Notification.Name("NSApplicationDidResignActiveNotification")

    static func isAway(appState: UIApplication.State, onMac: Bool, macAppIsFrontmost: Bool) -> Bool {
        if appState != .active { return true }
        return onMac && !macAppIsFrontmost
    }
}

/// The app-icon badge (the Dock badge on a Mac): running tasks plus
/// notifications posted while the user was away and not yet seen.
enum AppBadge {
    static func total(runningSessions: Int, notificationsEnabled: Bool, unseenNotifications: Int) -> Int {
        (notificationsEnabled ? runningSessions : 0) + max(0, unseenNotifications)
    }
}
// [T-mac-dock-badge] END user-attention-badge

// MARK: - Background behaviour profile (DEBUG) [T-bka-debug-profile]

#if DEBUG
/// One switchboard for every background-behaviour knob, so combinations can
/// be tried on a device from the debug server without a rebuild
/// (debug.bka.getProfile / debug.bka.setProfile). Setters go through the
/// live @Published properties - not just UserDefaults - so a change applies
/// at once (config.set on speech.backgroundEnabled only wrote UserDefaults,
/// and the running keep-alive kept its old value until relaunch).
extension BackgroundKeepAliveManager {
    func debugProfile() -> [String: Any] {
        let d = UserDefaults.standard
        return [
            "settings": [
                "enhancedBackground": enhancedBackgroundEnabled,
                "backgroundSpeak": backgroundSpeakEnabled,
                "locationTracking": locationTrackingEnabled,
                "liveActivity": liveActivityEnabled,
                "continuedPreferred": continuedProcessingPreferred,
            ],
            "debug": [
                "continuedMode": d.string(forKey: Self.continuedModeKey) ?? "(default)",
                "continuedModeEffective": Self.continuedMode.rawValue,
                "locationMode": d.string(forKey: Self.locationLAModeKey) ?? "(default)",
                "locationModeEffective": Self.locationLAMode.rawValue,
                "liveActivityRelevance": AgentLiveActivityManager.relevanceScore,
                "laRestartAfterTask": Self.laRestartAfterTask,
            ],
            "runtime": [
                "appInBackground": appIsInBackground,
                "sinceBackgroundSec": appIsInBackground ? Self.ago(backgroundEnteredAt) : "-",
                "runActive(isActive)": isActive,
                "busy": continuedBusy,
                "continuedTaskRunning": continuedTask != nil,
                "locationSessionOpen": bgActivitySession != nil,
                "silentAudioPlaying": silentAudioIsPlaying,
                "enhancedBackgroundEffective": enhancedBackgroundEffective,
            ],
        ]
    }

    /// Presets first, then explicit keys on top. Returns the new profile.
    func debugApplyProfile(_ params: [String: Any]) throws -> [String: Any] {
        var p: [String: Any] = [:]
        if let preset = params["preset"] as? String {
            switch preset {
            case "legacy":
                p = ["continuedPreferred": false, "continuedMode": "default", "locationMode": "default"]
            case "bgtask":
                p = ["continuedPreferred": true, "continuedMode": "default", "locationMode": "default"]
            case "bgtask-only":
                p = ["continuedPreferred": true, "continuedMode": "default", "locationMode": "off", "backgroundSpeak": false]
            case "audio-only":
                p = ["continuedPreferred": false, "continuedMode": "default", "locationMode": "off", "backgroundSpeak": true]
            default:
                throw DebugProfileError.badValue("preset must be legacy / bgtask / bgtask-only / audio-only")
            }
        }
        for (k, v) in params where k != "preset" { p[k] = v }

        let d = UserDefaults.standard
        if let v = p["continuedMode"] as? String {
            if v == "default" { d.removeObject(forKey: Self.continuedModeKey) }
            else if ContinuedMode(rawValue: v) != nil { d.set(v, forKey: Self.continuedModeKey) }
            else { throw DebugProfileError.badValue("continuedMode must be preferred / fallback / off / default") }
        }
        if let v = p["locationMode"] as? String {
            if v == "default" { d.removeObject(forKey: Self.locationLAModeKey) }
            else if LocationLAMode(rawValue: v) != nil { d.set(v, forKey: Self.locationLAModeKey) }
            else { throw DebugProfileError.badValue("locationMode must be continuous / off / default") }
        }
        if let v = p["laRestartAfterTask"] as? String {
            guard ["off", "taskStart", "resignActive"].contains(v) else {
                throw DebugProfileError.badValue("laRestartAfterTask must be off / taskStart / resignActive")
            }
            d.set(v, forKey: Self.laRestartAfterTaskKey)
        }
        if let v = p["liveActivityRelevance"] as? Double {
            d.set(v, forKey: AgentLiveActivityManager.relevanceScoreKey)
        }
        // Keys of the removed kick / release experiments, so an old build's
        // values cannot linger.
        for k in ["bka.continuedKickEnabled", "bka.continuedKickHoldSec", "bka.continuedReleaseAfterBgSec"] {
            d.removeObject(forKey: k)
        }
        // Live settings last: their didSet re-evaluates with the modes above.
        if let v = p["enhancedBackground"] as? Bool, v != enhancedBackgroundEnabled { enhancedBackgroundEnabled = v }
        if let v = p["backgroundSpeak"] as? Bool, v != backgroundSpeakEnabled { backgroundSpeakEnabled = v }
        if let v = p["locationTracking"] as? Bool, v != locationTrackingEnabled { locationTrackingEnabled = v }
        if let v = p["liveActivity"] as? Bool, v != liveActivityEnabled { liveActivityEnabled = v }
        if let v = p["continuedPreferred"] as? Bool, v != continuedProcessingPreferred {
            continuedProcessingPreferred = v
        } else {
            evaluateContinuedProcessing(caller: "debugProfile")
            evaluateLocationUpdates()
            evaluateBackgroundActivitySession()
        }
        logger.info("[BKA][Profile] applied \(p.keys.sorted().joined(separator: ","))")
        return debugProfile()
    }

    enum DebugProfileError: Error, CustomStringConvertible {
        case badValue(String)
        var description: String { if case .badValue(let m) = self { return m }; return "" }
    }
}
#endif

// BEGIN SilentAudioWatchdog
/// [T-bka-audio-dead-watchdog] What to do about the keep-alive audio right now.
enum SilentAudioWatchdog {
    enum Action: Equatable {
        /// Nothing to do: not wanted, or really playing.
        case none
        /// Marked active but the engine is not running: tear down and restart.
        case restart
        /// Wanted but not started: run the normal evaluation.
        case evaluate
    }

    /// - wantsKeepAlive: backgrounded, sessions busy, background audio allowed
    ///   and not suspended for reply speech or media.
    /// - markedActive: our own flag (`silentAudioActive`).
    /// - engineRunning: what the engine reports (`AVAudioEngine.isRunning`).
    static func decide(wantsKeepAlive: Bool, markedActive: Bool, engineRunning: Bool) -> Action {
        guard wantsKeepAlive else { return .none }
        if markedActive { return engineRunning ? .none : .restart }
        return .evaluate
    }
}

/// [T-bka-audio-dead-expiry] What the finite UIKit background task's expiry
/// handler does.
enum BGTaskExpiryPolicy {
    enum Action: Equatable {
        /// A continued-processing task holds the app: end this task, keep running.
        case endOnly
        /// Keep-alive audio is really playing: take a fresh task, keep running.
        case rearm
        /// Nothing holds the app: stop the shell, end the task, resume in the
        /// foreground. The only safe answer - the system kills an app that is
        /// still holding a task when the time runs out.
        case suspend
    }

    /// - keepAliveConfigured: the settings allow background audio keep-alive.
    /// - silentAudioPlaying: the engine is running NOW. The setting alone is
    ///   not enough: with the audio dead, the "re-armed" task is granted only
    ///   the seconds that were left.
    static func decide(continuedTaskRunning: Bool, keepAliveConfigured: Bool, silentAudioPlaying: Bool) -> Action {
        if continuedTaskRunning { return .endOnly }
        if keepAliveConfigured && silentAudioPlaying { return .rearm }
        return .suspend
    }
}
// END SilentAudioWatchdog

// BEGIN ContinuedCardStatus
/// [T-bka-continued-card-status] The continued-processing card's subtitle,
/// from one session's tool info (SessionActivityTracker.SessionToolInfo).
/// Foundation only, with localization injected, so the standalone test can
/// compile this block.
enum ContinuedCardStatus {
    /// Longest tool title kept; the card truncates anyway, this just keeps the
    /// tool name in view and the update small.
    static let maxDetailLength = 60

    static func text(toolName: String, toolStatus: String, localize: (String) -> String) -> String {
        let detail = toolStatus
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let shortDetail = detail.count > maxDetailLength ? String(detail.prefix(maxDetailLength)) + "…" : detail
        switch toolName {
        case "": return localize("Working…")
        case "thinking": return localize("Thinking deeply…")
        // The status of a text block is the token "streaming", never prose.
        case "text": return localize("Replying…")
        default:
            guard let label = toolLabel(toolName) else {
                return shortDetail.isEmpty ? localize("Working…") : shortDetail
            }
            return shortDetail.isEmpty ? localize(label) : "\(localize(label)) · \(shortDetail)"
        }
    }

    static func subtitle(status: String, sessionCount: Int, localize: (String) -> String) -> String {
        guard sessionCount > 1 else { return status }
        return String(format: localize("%lld sessions · %@"), sessionCount, status)
    }

    /// Catalog keys for the tools the Live Activity names
    /// (AgentLiveActivityManager.displayName); nil = show the title alone.
    static func toolLabel(_ toolName: String) -> String? {
        switch toolName {
        case "browser", "browser_use": return "Browser"
        case "shell", "shell_execute": return "Shell"
        case "file_read": return "Read File"
        case "file_write": return "Write File"
        case "file_edit": return "Edit File"
        case "read_image": return "Read Image"
        case "memory": return "Memory"
        case "code_interpret": return "Code"
        default: return nil
        }
    }
}
// END ContinuedCardStatus
