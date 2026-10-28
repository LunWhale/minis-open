//
//  AIChatViewModel.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel - one chat session's view model: messages, the agent loop
//  that talks to the model and runs tools, and the state the chat UI binds to.
//
//  Map of the AIChatViewModel files (all in Agent/Chat/)
//  ====================================================
//
//    AIChatViewModel.swift      this file: every stored property (@Published
//        state, loop / queue / speech / sync state, signals), init / deinit,
//        and a few small computed properties that read like state
//    Turn flow
//        +Send            send(), retry(), resume(), unanswered user turn
//        +AgentLoop       runAgentLoop / runAgentLoopCore (request, stream,
//                         tools, repeat)
//        +Rerun           retry from a message / tool block, delete from here
//        +EditMessage     edit a sent message, cut at a user bubble
//        +Cancel          Stop, cancel work bound to a previous model
//        +PromptQueue     queued prompts: drain, inject as a new turn
//        +TurnCompletion  haptic, failure banner, stop / cancel cleanup
//        +SSEStream, +ConcurrentTools, +ToolDefinitions, +ToolPreflight,
//        +RequestBudget, +Fallback, +ProviderFactory, +ProgrammaticPrompt,
//        +UserAsk, +Offloading, +Compaction   (older extension files)
//    Prompt and context
//        +SystemPrompt    base system prompt, fixed token cost
//        +ContextUsage    usage glow / hint, model capability queries
//        +ThinkingLevel   session thinking level
//    UI plumbing
//        +StreamingUI     streaming / transition gates, streamed text writes
//        +Speech          TTS output;  +AutoPlayAudio  audio auto-play, MIME
//        +Attachments, +MentionMenu, +SlashCommands   (older extension files)
//    Session and lifecycle
//        +Lifecycle       cache eviction teardown, font cache invalidation
//        +Persistence, +TitleGeneration, +BackgroundTask, +Misc   (older)
//    Tools
//        +FileTools, +MemoryTools, +ISHCommand   (older extension files)
//    Diagnostics
//        +DebugDumps      agentHistory / queue log dumps
//    LLMProviderError.swift  the provider error enum that ended this file
//
//  Rules that keep this split working
//  ==================================
//
//  - Stored properties stay in this class body (extensions cannot hold them);
//    their order is the order they had before the split.
//  - Each extension file declares its own file-private `logger` (category
//    "AIChatVM"), like the older extension files.
//  - Members used from another file are internal; treat them as private to
//    the view model.
//  - New behaviour goes into the extension file of its concern (or a new one).
//  - Source-scanning tests (MinisTests/Standalone) read this file together with
//    the files split out of it (chatViewModelSource() lists them), so code may
//    move between those files; a new file split out of this one belongs on
//    that list too.
//
//  History: +Lifecycle, +ContextUsage, +StreamingUI, +Speech, +AutoPlayAudio,
//  +SystemPrompt, +Send, +Rerun, +EditMessage, +Cancel, +PromptQueue,
//  +DebugDumps, +TurnCompletion, +AgentLoop, +ThinkingLevel and
//  LLMProviderError.swift were split out of this file (~8.5k lines before).
//  The code was moved verbatim; the differences are the repeated import list,
//  per-file logger copies, dropped `private` / `fileprivate`, the extension
//  wrappers and one doc comment put back on its function (see
//  AIChatViewModel+TurnCompletion.swift).
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

// MARK: - View Model

@MainActor
final class AIChatViewModel: ObservableObject, SpeechControlling {

    /// Maximum characters returned in a single tool result to the model
    static let kMaxToolResultChars = 15000

    /// Maximum number of images retained in agent history when building the
    /// context sent to the model. Older images are replaced with a text
    /// placeholder (containing dimensions + byte size + persisted path) so
    /// they can be re-viewed via the `read_image` tool.
    static let kImageContextKeepCount = 20

    // MARK: - Image byte budgets (T-imgsize-13b7d81c, T-image-budget-base64)
    //
    // [T-image-budget-base64] These budgets are measured in BASE64 bytes —
    // the size the image actually occupies in the request body — not in raw
    // decoded bytes.
    //
    // The original comment here reasoned that Anthropic's 30 MB limit applies
    // to decoded image bytes, so budgeting in raw bytes was equivalent. That
    // is true of Anthropic's own per-image content rule, but it is NOT the
    // constraint that was actually breaking requests: gateways in front of
    // several providers (OpenAI and Anthropic both observed) enforce a 32 MB
    // limit on the HTTP REQUEST BODY, and images travel that body base64
    // encoded, which inflates them by 4/3. A 25 MB raw budget therefore put
    // ~33.3 MB on the wire before a single byte of text history or tool
    // schema — over the cap on its own, which is exactly the
    // "request too large (~32 MB, limit 32 MB)" failure users hit.
    //
    // Budgeting in base64 bytes makes the number mean what it says: the
    // ceiling is what we are about to send. Raw-byte sizes are converted
    // with `estimatedBase64Length` at every comparison instead of the
    // constants being scaled down, so there is no rounding drift and the
    // headroom below stays exact rather than approximate.
    //
    // Other providers have similar but undocumented caps. We enforce a
    // tighter, pre-encoding budget so the request never reaches the wire
    // too big:
    //
    //   - Per image: 5 MB after JPEG re-encode. The Anthropic SDK's own
    //     per-image soft hint; well under the 30 MB request cap and
    //     ensures a single huge photo can't gobble the whole budget.
    //     Anything bigger runs the compressor ladder (smaller max edge +
    //     lower JPEG quality) until it fits or until we've shrunk it
    //     past readability.
    //   - Per message: 25 MB cumulative across all inlined images.
    //     Leaves ~5 MB headroom under Anthropic's 30 MB request cap for
    //     other parts of the payload (tool results, prior message
    //     attachments echoed back, etc.).
    //   - Above the message cap, additional images are dropped to a text
    //     placeholder (same fallback the count cap already uses).

    /// [T-image-budget-base64] Bytes `rawBytes` will occupy once base64
    /// encoded into the request body: 4 output bytes per 3 input bytes,
    /// rounded up to the next 4-byte group (which is what padding produces).
    ///
    /// Exact for the encoding itself, so no fudge factor is needed. It
    /// deliberately does NOT model the JSON string overhead around the
    /// payload (quotes, the `data:` prefix, escaping) — those are tens of
    /// bytes against megabytes, and the budgets already reserve headroom for
    /// the rest of the body.
    ///
    /// Computed rather than measured: base64-encoding every candidate image
    /// just to learn its length would cost a full copy of each image's bytes
    /// on every request-budget pass, for a number this returns exactly.
    ///
    /// Mirrors Android's `ImageBudget.estimatedBase64Length`.
    static func estimatedBase64Length(_ rawBytes: Int) -> Int {
        guard rawBytes > 0 else { return 0 }
        return ((rawBytes + 2) / 3) * 4
    }

    /// [T-image-budget-base64] Inverse of `estimatedBase64Length`: the largest
    /// raw byte count that still encodes within `base64Budget`.
    ///
    /// Needed because the compressor ladder (`compressedImageDataUnderBudget`)
    /// measures its output in RAW bytes — it is comparing `data.count` against
    /// the target it was handed. Feeding it a base64 budget directly would
    /// silently let it stop compressing at 5 MB raw, i.e. ~6.7 MB on the wire,
    /// which is the very overshoot this change removes. So budgets cross that
    /// boundary through here.
    ///
    /// Mirrors Android's `ImageBudget.rawBytesForBase64Budget`.
    static func rawBytesForBase64Budget(_ base64Budget: Int) -> Int {
        guard base64Budget > 0 else { return 0 }
        return (base64Budget / 4) * 3
    }

    /// Hard ceiling per single image after compression, measured in BASE64
    /// bytes (see `estimatedBase64Length`). 5 MB of wire payload is ~3.75 MB
    /// of decoded image, still comfortably above what the compressor ladder
    /// targets for a readable photo.
    static let kPerImageMaxBytes = 5 * 1024 * 1024

    /// Hard ceiling across all inlined images in one user message.
    /// 5 MB under Anthropic's 30 MB request cap, leaving headroom for
    /// tool results and prior-turn attachments still in context.
    static let kMessageImageMaxBytes = 25 * 1024 * 1024

    /// Hard ceiling on cumulative inline-image bytes across the FULL
    /// request body (all messages, all tool results). When a long
    /// session accumulates browser screenshots + attachments + read_image
    /// results past this cap, gpt-5.5 via factory.pub silently returns
    /// 200 + empty SSE + `finish_reason=stop` and the client treats the
    /// empty turn as completion (T-request-imgsize). Eldest images are
    /// elided to text placeholders here.
    static let kRequestImageMaxBytes = 25 * 1024 * 1024

    /// Hard ceiling on agent loop iterations within a single user turn.
    /// Backstop against runaway tool-call cycles that slip past
    /// `ToolLoopDetector` (e.g. visited args/results vary just enough to
    /// dodge the global circuit breaker). On reaching the limit the loop
    /// finalizes as resumable — see runAgentLoop's tail — so the user gets
    /// an inline explanation + Resume affordance rather than an unbounded
    /// runaway. Mirrors Android ChatViewModel.MAX_AGENT_TURNS.
    static let maxAgentTurns = 200
    /// [T-chat-auto-compact-inloop] Max in-loop auto-compactions per single
    /// user turn. Beyond this the loop stops as exhausted rather than
    /// compacting endlessly (which would defeat the maxAgentTurns backstop).
    static let maxInLoopCompactions = 3

    /// [StreamDiag] (#181) Monotonic counter tagging each outbound streaming
    /// request so the stall watchdog's log line can be correlated with the
    /// request it belongs to. Main-actor isolated (the whole class is), so the
    /// `&+=` bump needs no additional synchronization. Diagnostics only —
    /// nothing reads this for control flow.
    static var diagRequestSeq: UInt64 = 0

    /// If non-nil, this VM is in read-only mode viewing a remote device's session.
    var remoteDeviceId: String?

    /// Short unique ID for this ViewModel instance (for debugging lifecycle).
    let vmInstanceId = UUID().uuidString.prefix(6)

    /// [T-deferred-sync-reload] Set to true when a
    /// `.cloudSyncDidFetchChanges` notification fires WHILE
    /// `isProcessing == true`. The `$isProcessing` sink drains it on
    /// the false-edge by replaying exactly one `reloadMessagesFromDB`
    /// so the user sees the post-send DB state without waiting for the
    /// next 60s sync timer.
    var pendingSyncReloadOnIdle = false

    // MARK: - Post-stop sync hold (T-ios-defer-icloud-sync-after-stop)

    /// While the agent loop runs (`isProcessing`), and for a grace window AFTER
    /// it stops, BOTH iCloud directions are held: no push to cloud, no pull-
    /// driven local reload. This stops a deferred sync from overwriting the
    /// just-finished candidate the instant the loop ends (field repro: content
    /// vanished + a brief loading flash right after Stop). The hold is released
    /// — and a single catch-up sync (flush dirty push + replay reload) runs —
    /// when the earliest of these happens: the 60s timer fires, the user leaves
    /// the session (back to the list), or the app is backgrounded.
    static let postStopSyncHoldSeconds: TimeInterval = 60
    /// Deadline of the current hold; nil when not held.
    private(set) var postStopSyncHoldUntil: Date?
    private var postStopSyncHoldTimer: Timer?

    /// True while the post-stop grace window is active.
    var isSyncHeld: Bool {
        guard let until = postStopSyncHoldUntil else { return false }
        return until > Date()
    }

    /// Enter the post-stop hold for the PULL side only, and release the push
    /// immediately. Called when the agent loop transitions to idle.
    ///
    /// [T-icloud-sync-tier1-push-on-idle] This used to also call
    /// `SyncCore.pause(for: 60)`, holding every outbound record for a full
    /// minute after the loop ended. That pause never protected anything:
    /// the on-screen overwrite it was added for (c74a3a313, 2026-06-01) is
    /// caused by a PULL-driven reload replacing in-memory content, which the
    /// `isSyncHeld` guard in `reloadMessagesFromDB` and the cancel guard from
    /// ebe9cb844 already prevent — and our own pushed records come back as
    /// `ownEcho` and never trigger a reload. Measured cost of the pause on
    /// two devices: 60 of the 96–160 s it took a finished turn to appear on
    /// the peer. `persistAgentMessage` is awaited before `isProcessing`
    /// flips, so on every normal completion the records are already durable
    /// here; on cancel the kept partial is memory-only and is never marked
    /// dirty until it persists, so nothing unpersisted can be pushed either.
    ///
    /// So: end this vm's send deferral and flush NOW (the store still holds
    /// the send back if another loop is running), and keep only the pull
    /// hold — `postStopSyncHoldUntil` + the timer — so a peer change that
    /// arrived mid-turn is merged at the hold's release, not the instant the
    /// candidate lands.
    @MainActor
    private func beginPostStopSyncHold() {
        let until = Date().addingTimeInterval(Self.postStopSyncHoldSeconds)
        postStopSyncHoldUntil = until
        postStopSyncHoldTimer?.invalidate()
        postStopSyncHoldTimer = Timer.scheduledTimer(withTimeInterval: Self.postStopSyncHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.releasePostStopSyncHold(reason: "timer-60s") }
        }
        let owner = String(vmInstanceId)
        Task {
            await ChatStore.shared.endSyncSendDeferral(owner: owner)
            await ChatStore.shared.flushPendingSyncDirty()
        }
        logger.info("[SyncHold] BEGIN pull-hold until \(until) (\(Int(Self.postStopSyncHoldSeconds))s), push released now sid=\(self.sessionId?.prefix(8) ?? "nil")")
    }

    /// Release the hold early/at-deadline and run one catch-up sync: resume
    /// SyncCore, flush deferred dirty (push), and replay any pending reload
    /// (pull). Idempotent — safe to call from any of the release triggers.
    @MainActor
    func releasePostStopSyncHold(reason: String) {
        guard postStopSyncHoldUntil != nil else { return }
        postStopSyncHoldUntil = nil
        postStopSyncHoldTimer?.invalidate()
        postStopSyncHoldTimer = nil
        // [T-p0-sync-defer-refcount] Another session's loop may still be
        // streaming. Its own hold/release will resume + flush when IT finishes
        // (SyncCore.pause is deadline-bounded, so skipping resume here can't
        // strand it). Only release this vm's deferral and let the store decide
        // whether anything is still holding the send back.
        let owner = String(vmInstanceId)
        let othersActive = SessionActivityTracker.shared.activeSessions.contains { $0 != self.sessionId }
        logger.info("[SyncHold] RELEASE reason=\(reason) sid=\(self.sessionId?.prefix(8) ?? "nil") othersActive=\(othersActive) — \(othersActive ? "deferring catch-up to the running session" : "resuming sync + catch-up")")
        // [T-icloud-sync-tier1-push-on-idle] Push was already released and
        // flushed in beginPostStopSyncHold; SyncCore was never paused, so
        // there is nothing to resume. `endSyncSendDeferral` is set-based and
        // idempotent — call it again only as a belt-and-braces for the
        // paths that reach here without having gone through begin (deinit,
        // background). It does not re-flush.
        _ = othersActive
        Task { await ChatStore.shared.endSyncSendDeferral(owner: owner) }
        // Pull: replay a deferred reload now that it's safe.
        if pendingSyncReloadOnIdle, !isProcessing, sessionId != nil {
            pendingSyncReloadOnIdle = false
            Task { @MainActor in await self.reloadMessagesFromDB(reason: "syncHoldReleased(\(reason))") }
        }
    }

    /// Cancellable for tracking `isProcessing` → `SessionActivityTracker`.
    private var activityTrackingCancellable: AnyCancellable?
    private var captureSuppressCancellable: AnyCancellable?
    private var mediaPreemptCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    /// Observer for font-size changes to invalidate cached attributed strings.
    private var fontChangeObserver: Any?
    /// Observer for iCloud sync changes to reload messages.
    private var syncChangeObserver: Any?
    /// Observer for group binding changes to update in-memory context limit.
    /// Observer that releases the post-stop sync hold when the app backgrounds.
    private var backgroundSyncHoldObserver: Any?
    /// [T-tool-bg-suspended-hint] Observer firing on foreground return; stamps
    /// still-running browser tool blocks that have spanned a background period
    /// and exceeded the long-run threshold so the chat capsule can hint at the
    /// likely background slowdown. In-memory only (not persisted).
    private var bgHintForegroundObserver: Any?
    private var snapshotForegroundObserver: Any?
    private var detachedLoopEndObserver: Any?
    /// [T-ios-switch-model-ghost-retry] Observes `.sessionModelBindingChanged`
    /// so a mid-conversation model switch tears down work aimed at the model
    /// being switched away from. The notification was already being posted by
    /// `SessionModelPicker`; until this, nothing listened to it.
    private var modelBindingChangeObserver: Any?
    /// [T-ios-switch-model-next-request] Set when the user picks a different
    /// model while a HEALTHY turn is in flight. The running agent loop checks
    /// it at the top of each iteration — i.e. before its next LLM request —
    /// and swaps to the newly bound model there, so the switch takes effect
    /// without interrupting the stream or tool call already under way.
    var pendingModelSwitch = false
    /// Timestamp of the most recent background-entry, used to detect that a
    /// long-running browser task actually spanned a background period.
    var bgHintBackgroundEntryDate: Date?
    /// A browser tool running longer than this when the app returns to the
    /// foreground (after having been backgrounded) gets the suspension hint.
    static let bgHintBrowserThreshold: TimeInterval = 5 * 60

    init() {
        logger.info("🔄SESSION [vm=\(self.vmInstanceId)] init — new AIChatViewModel created")

        fontChangeObserver = NotificationCenter.default.addObserver(
            forName: .fontSettingsMessageBaseChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.invalidateAttributedStringCaches() }
        }

        // [T-ios-defer-icloud-sync-after-stop] Backgrounding is a release
        // trigger for the post-stop sync hold — let the held catch-up sync run
        // before the app suspends, instead of waiting out the 60s window.
        backgroundSyncHoldObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // [T-tool-bg-suspended-hint] Remember when we went to background so
            // a foreground return can tell a browser task actually spanned it.
            self.bgHintBackgroundEntryDate = Date()
            Task { @MainActor in self.releasePostStopSyncHold(reason: "background") }
        }

        // [T-tool-bg-suspended-hint] On foreground return, flag any still-running
        // browser tool that spanned the background period and has now exceeded the
        // long-run threshold — the WebView/JS is likely throttled or stalled while
        // backgrounded, so the capsule surfaces the "enable enhanced background"
        // hint. In-memory only; mirrors the BackgroundInterruptionTracker gate
        // (skip when enhanced background is already effective).
        bgHintForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.markLongBackgroundBrowserTasks() }
        }

        // [T-ios-bg-blocks-lost] On foreground return, replay the deferred
        // snapshot rebuild if isProcessing went false while backgrounded.
        // When the app is in background with streamingUIUpdatesSuspended=false,
        // bind4b may call applySnapshot but UIKit can silently drop or
        // incompletely apply UICollectionView diffs while not in .active.
        // The isProcessing didSet sets needsSnapshotReloadOnResume=true for
        // this case, but clearStreamingUIUpdatesSuspended won't fire (the
        // flag was never set). This observer is the missing trigger.
        // [T-ios-bg-blocks-lost] Replay the deferred snapshot rebuild when the
        // app returns to .active. Uses didBecomeActiveNotification (not
        // willEnterForegroundNotification) because the deferred path triggers
        // for BOTH .background and .inactive states — inactive→active is
        // common (e.g. Control Center swipe, notification shade pull) and
        // willEnterForeground only fires from background, missing the
        // inactive case entirely.
        snapshotForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // [T-blockslost-defensive defect ②] Gate on being the
                // CURRENTLY-DISPLAYED session. This observer was written
                // (02970b7b) when the flag could only mean suspended /
                // backgrounded — cases where foreground-return implies this
                // VM's view is mounted. b5f6a1e1 later added the
                // "no subscriber" deferral (user viewing ANOTHER session):
                // for that case a foreground-return must NOT consume the
                // flag — the replay signal would fire with no CollectionView
                // subscriber bound and be lost, starving
                // consumeDeferredSnapshotIfNeeded (the in-app switch-back
                // path) of the flag it exists to consume.
                let sid = self.sessionId
                let gatePassed = (sid != nil && Self.activeSessionId == sid)
                let needsFlag = self.needsSnapshotReloadOnResume
                logger.info("[BlocksLost] didBecomeActive gate sid=\(sid?.prefix(8) ?? "nil") vm=\(self.vmInstanceId) activeSessionId=\(Self.activeSessionId?.prefix(8) ?? "nil") gatePassed=\(gatePassed) needsFlag=\(needsFlag)")
                guard needsFlag else { return }
                guard gatePassed else {
                    // Keep the flag: the user is on another session; the
                    // onAppear-reuse path consumes it when they switch back.
                    return
                }
                self.needsSnapshotReloadOnResume = false
                let totalBlocks = self.messages.reduce(0) { $0 + $1.blocks.count }
                let lastBlocks = self.messages.last?.blocks.count ?? 0
                logger.info("[BlocksLost] REPLAY retrySnapshot — app became active. sid=\(sid?.prefix(8) ?? "nil") totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(self.messages.count)")
                self.retrySnapshotReloadSignal.send()
            }
        }

        // [T-ios-detached-vm-loop-end] When the agent loop finishes on a
        // detached VM (user navigated away mid-loop, or VM was evicted and
        // recreated), that VM posts .sessionAgentLoopDidEnd. The currently-
        // displayed VM for the same session picks it up here and reloads
        // from DB so the final tool results / assistant text appear.
        detachedLoopEndObserver = NotificationCenter.default.addObserver(
            forName: .sessionAgentLoopDidEnd, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let sid = self.sessionId else { return }
            guard let notifSid = notification.object as? String, notifSid == sid else { return }
            guard Self.activeSessionId == sid else { return }
            guard !self.isProcessing else { return }
            logger.info("[BlocksLost] DETACHED reload — agent loop ended on another VM, reloading. sid=\(sid.prefix(8)) vm=\(self.vmInstanceId)")
            Task { @MainActor in
                await self.reloadMessagesFromDB(reason: "detachedVMLoopEnd")
            }
        }

        // [T-ios-switch-model-ghost-retry] A model switch must stop whatever is
        // still aimed at the model being switched away from. `SessionModelPicker`
        // has always posted this; nothing observed it, so the old model's agent
        // loop kept retrying and its errors kept surfacing over the new model's
        // working replies.
        modelBindingChangeObserver = NotificationCenter.default.addObserver(
            forName: .sessionModelBindingChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let sid = self.sessionId else { return }
            // Only THIS conversation's switch. The notification is global and
            // carries its session id, so a switch in another chat (or from a
            // background/scheduled binding write) must not cancel this one.
            guard let notifSid = notification.userInfo?["sessionId"] as? String,
                  notifSid == sid else { return }
            Task { @MainActor in
                self.cancelWorkBoundToPreviousModel(reason: "user switched model")
            }
        }

        syncChangeObserver = NotificationCenter.default.addObserver(
            forName: .cloudSyncDidFetchChanges, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let sid = self.sessionId else { return }
            // Only the foreground-visible VM reacts. ViewModelCache holds
            // every session the user has ever opened in this launch, and
            // each instance is a notification subscriber — without this
            // gate, one inbound batch fans out into N concurrent
            // reloadMessagesFromDB calls, each of which loadMessages-es
            // its session (potentially thousands of rows + JSON decode).
            // The hidden VMs catch up on their own via the
            // AIChatView.onAppear REUSING branch, which already does the
            // same hash+count comparison before reloading.
            if Self.activeSessionId != sid { return }
            // [T-deferred-sync-reload] If a send is in flight, don't
            // reload mid-stream — that would re-snapshot messages and
            // could clobber the streaming assistant block / hide the
            // "Minis is thinking" indicator. Flip a flag instead; the
            // $isProcessing observer below picks it up and replays one
            // reload as soon as the send completes. This avoids waiting
            // the full sync-timer cycle (~60s) for the next refresh.
            if self.isProcessing {
                self.pendingSyncReloadOnIdle = true
                logger.info("[ReloadTrace] DEFER reason=cloudSyncDidFetchChanges sid=\(sid.prefix(8)) isProcessing=true — will reload on idle")
                return
            }
            // [T-scroll-sync-defer] A reload mid-fling either costs frames (hash
            // check) or re-snapshots the list under the user's finger; run it
            // once the list is still.
            // Re-check the gates above when it finally runs: a send may have
            // started, or the user may have left, in the meantime.
            ChatScrollActivity.runWhenStill("chat.syncReload.\(sid)") { [weak self] in
                guard let self, self.sessionId == sid, Self.activeSessionId == sid else { return }
                if self.isProcessing {
                    self.pendingSyncReloadOnIdle = true
                    return
                }
                Task { @MainActor in
                    await self.reloadMessagesFromDB(reason: "cloudSyncDidFetchChanges")
                }
            }
        }

        activityTrackingCancellable = $isProcessing
            .removeDuplicates()
            .sink { [weak self] processing in
                guard let self else { return }
                // Key selection:
                //   - Before the draft has a real session (sessionId == nil),
                //     fall back to draftId so the sidebar proxy row still
                //     reflects activity.
                //   - Once sessionId exists, use ONLY it; mixing in draftId
                //     caused leaks — ensureSession migrates draft→real but
                //     draftId stays set for sidebar UX, and a second send()
                //     would setActive(draftId) again while the first send's
                //     setInactive(sessionId) wasn't reliably paired.
                let activeKey: String
                if let sid = self.sessionId {
                    activeKey = sid
                } else if let did = self.draftId {
                    activeKey = did
                } else {
                    return
                }
                let src = "vm=\(self.vmInstanceId) isProcessing=\(processing)"
                logger.info("🔄SESSION [vm=\(self.vmInstanceId)] isProcessing=\(processing) key=\(activeKey) draftId=\(self.draftId ?? "nil") sessionId=\(self.sessionId ?? "nil")")
                if processing {
                    SessionActivityTracker.shared.setActive(activeKey, source: src)
                    if let sid = self.sessionId {
                        Task {
                            if let session = await ChatStore.shared.getSession(sid),
                               let title = session.title, !title.isEmpty {
                                await MainActor.run {
                                    SessionActivityTracker.shared.updateSessionTitle(sid, title: title)
                                }
                            }
                        }
                    }
                    // [T-ios-session-running-shows-pause-badge] Starting/resuming
                    // a loop means this session is no longer paused — drop any
                    // stale ⏸ immediately, independent of the canResume didSet
                    // (which only fires on a value transition and can miss a queue
                    // entry seeded by the launch reconcile or a prior VM).
                    if let sid = self.sessionId {
                        SessionBadgeStore.shared.remove(.paused, for: sid)
                    }
                    // [T-ios-ipad-sidebar-spinner-stale-after-resend] Re-assert
                    // the draft→real alias on every activation. On iPad the
                    // sidebar keeps showing the new chat's row under its DRAFT
                    // id (ContentView.displaySessions builds a proxy with
                    // id=draftId so List(selection:) stays valid), and that row
                    // reads `isActive(draftId)`. The alias was registered once at
                    // draft→real migration, but `setInactive(real)` CLEARS it
                    // (it drops aliases pointing at a now-inactive session). So
                    // after the first stop the alias is gone; a resend calls
                    // setActive(real) but the sidebar proxy — still keyed by
                    // draftId — no longer resolves, and its spinner never spins
                    // again until the user navigates away (which collapses the
                    // proxy to the real id). Re-registering the alias here on
                    // each true-transition keeps the draft-keyed row in sync.
                    if let did = self.draftId, did != activeKey, self.sessionId != nil {
                        SessionActivityTracker.shared.setDraftAlias(draft: did, real: activeKey)
                    }
                } else {
                    SessionActivityTracker.shared.setInactive(activeKey, source: src)
                    // [T-ios-session-completed-badge-not-cleared] The loop just
                    // stopped. If it didn't stop in a resumable state, the session
                    // completed normally — clear any ⏸ that lingers. The canResume
                    // didSet handles the true→false transition, but a turn that
                    // finished with canResume ALREADY false (the common completion
                    // path: line ~4044 sets false even when it was false → no
                    // didSet) leaves a stale badge (seeded by reconcile / a prior
                    // VM) untouched. Gating on !canResume preserves a genuine
                    // interruption (Stop / bg-suspend) that ends the loop with
                    // canResume=true — that badge must stay.
                    if !self.canResume, let sid = self.sessionId {
                        SessionBadgeStore.shared.remove(.paused, for: sid)
                    }
                    // Safety net: if the draft id ever ended up in the tracker
                    // (e.g. from a prior send() that started before ensureSession
                    // returned), scrub it on this transition too so it can't
                    // orphan.
                    if let did = self.draftId, did != activeKey {
                        SessionActivityTracker.shared.setInactive(did, source: src + " (stray draftId)")
                    }
                    self.browserTabPool.releaseAllTabs()
                    // [T-deferred-sync-reload] Drain any sync reloads that
                    // arrived during the send so the UI catches up with the DB
                    // now that the stream finished.
                    // [T-ios-defer-icloud-sync-after-stop] BUT not while the
                    // post-stop hold is active — replaying a reload here is the
                    // exact overwrite we're preventing. Keep the flag armed; the
                    // hold release (timer / leave / background) replays it.
                    if self.pendingSyncReloadOnIdle, let sid = self.sessionId {
                        if self.isSyncHeld {
                            logger.info("[ReloadTrace] HOLD reason=isProcessing→false sid=\(sid.prefix(8)) — deferred reload kept until post-stop hold releases")
                        } else {
                            self.pendingSyncReloadOnIdle = false
                            logger.info("[ReloadTrace] DRAIN reason=isProcessing→false sid=\(sid.prefix(8)) — replaying deferred sync reload")
                            Task { @MainActor in
                                await self.reloadMessagesFromDB(reason: "deferredSyncReloadOnIdle")
                            }
                        }
                    }
                }
            }

        // When the mic starts capturing, immediately silence any in-progress
        // reply TTS (capture and playback are mutually exclusive — no echo). New
        // speech is already suppressed by `canSpeakNow`; this stops the current
        // System utterance too (the cloud queue is stopped by the panel).
        captureSuppressCancellable = VoiceModePreference.shared.$isCapturing
            .removeDuplicates()
            .sink { [weak self] capturing in
                if capturing { self?.stopSpeech() }
            }

        // A media attachment preempted reply TTS — stop the System synthesizer
        // (cloud queue already stopped by the coordinator). Don't auto-resume.
        mediaPreemptCancellable = NotificationCenter.default
            .publisher(for: AudioSessionCoordinator.replyTTSPreemptedNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.speechSynthesizer.isSpeaking {
                    self.speechSynthesizer.stopSpeaking(at: .immediate)
                }
                self.isReadingAloud = false
                self.speechPaused = false
            }

        // Read-replies is now GLOBAL state (VoiceOutputState.shared). Forward its
        // changes so views observing `vm.speakEnabled` refresh, and stop this VM's
        // System TTS the moment it's turned off anywhere.
        voiceStateCancellable = VoiceOutputState.shared.$isEnabled
            .dropFirst()                 // skip the synchronous current-value emit
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.objectWillChange.send()
                if !enabled { self.stopSpeech() }
            }
    }

    deinit {
        let vmId = vmInstanceId
        // Snapshot tracker-relevant state at deinit so we can spot leaks: if
        // isProcessing was still true when the vm is about to die, the
        // corresponding sessionId/draftId keys will remain stuck in
        // `SessionActivityTracker.activeSessions` because the `$isProcessing`
        // sink won't fire once self is gone. Fields are MainActor-isolated
        // and deinit is nonisolated; `_deinitSnapshot` is updated on the
        // main actor during normal flow so we can read it here safely.
        logger.info("🔄SESSION [vm=\(vmId)] deinit lastKnown: \(self._deinitSnapshot)")
        // [T-p0-sync-defer-refcount] A vm evicted mid-hold never reaches
        // releasePostStopSyncHold (the timer holds self weakly); drop its
        // deferral so it cannot pin iCloud sends off forever.
        let owner = String(vmId)
        Task { await ChatStore.shared.endSyncSendDeferral(owner: owner) }
        if let observer = fontChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = syncChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = backgroundSyncHoldObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = bgHintForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = snapshotForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = detachedLoopEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = modelBindingChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    /// [T-in-chat-search] "Search in Chat" for this conversation. Not
    /// @Published: the search bar and the highlighted rows observe it
    /// directly, so typing a query never re-renders the whole chat page.
    lazy var chatSearch: ChatSearchController = {
        let search = ChatSearchController()
        search.viewModel = self
        return search
    }()
    /// [T-voice-input-mode-preference-ios] True when a voice session
    /// contributed to the CURRENT composition (set on recording start by any
    /// path: mic tap, quick action, preference auto-entry). Cleared whenever
    /// the composer empties, so send() can detect "composed without voice
    /// since the composer was last cleared" and flip the remembered
    /// input-mode preference back to "text".
    var voiceUsedInComposition = false
    @Published var inputText = "" {
        didSet {
            if inputText.isEmpty && !oldValue.isEmpty {
                voiceUsedInComposition = false
                #if DEBUG
                logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] inputText CLEARED (was '\(String(oldValue.prefix(30)))') sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil") isProcessing=\(self.isProcessing)")
                #else
                logger.info("🔑DRAFT [vm=\(self.vmInstanceId)] inputText CLEARED (was \(oldValue.count)ch) sessionId=\(self.sessionId ?? "nil") draftId=\(self.draftId ?? "nil") isProcessing=\(self.isProcessing)")
                #endif
            }
            updateSlashMenuState()
            updateMentionMenuState()
        }
    }
    /// Caret position (character offset) published by the input text view.
    /// Used by the `@` mention detector to locate the active token.
    @Published var inputCaret: Int = 0 {
        didSet {
            updateMentionMenuState()
            // If the caret arrived at the desired location, clear the pending
            // request so subsequent edits aren't forced back.
            if let p = pendingCaret, p == inputCaret {
                pendingCaret = nil
            }
        }
    }
    /// One-shot request to move the caret to a specific offset. Cleared once
    /// the text view publishes a matching caret position via `inputCaret`.
    @Published var pendingCaret: Int?
    /// Plain string capture of the vm state for diagnostic logging from deinit
    /// (which is nonisolated and can't touch @Published MainActor properties).
    /// Updated on every isProcessing flip and on send entry.
    nonisolated(unsafe) var _deinitSnapshot: String = "isProcessing=false session=nil draft=nil"

    // [T-ios-context-usage-hint] Context-window occupancy, published so the
    // composer can render the ambient glow live and the placeholder line
    // once per finished turn. Recomputed by publishContextUsage() whenever
    // a message's usage lands or a session loads; nil when no assistant turn
    // has reported usage yet (some providers never do — the feature then
    // stays hidden instead of showing 0%).
    @Published var contextUsage: ContextUsage?
    /// One request per finished user-visible turn; the composer's Coordinator
    /// acts on each generation exactly once (debounced there).
    @Published var contextUsageHint: ContextUsageHint?
    var contextUsageHintGeneration = 0
    /// [T-ctx-usage-after-compact] The message whose stamped usage was taken
    /// BEFORE the latest compaction in this session. Its `latestContextTokens`
    /// is the size of the context the compaction replaced, so while it is
    /// still the newest usage-bearing message, `publishContextUsage()` shows
    /// the measured post-compaction size instead. Cleared implicitly: the next
    /// turn stamps usage on a newer message, which no longer matches.
    var usageReportSupersededByCompaction: UUID?
    /// [T-ios-context-usage-realtime-crossing] Shared by the mid-loop crossing
    /// path and the loop-end path so the two never announce the same tier
    /// twice within seconds. Internal (not private) so the session-load
    /// extension can reset it.
    var contextTierTracker = ContextTierCrossingTracker()

    /// [T-ctx-measure-outbound] Calibration state for `ContextSizeMeter`.
    ///
    /// Replaces `liveContextTokensForCapacity`, a mirror of the newest API
    /// report that the capacity guard folded in with `max()`. That number
    /// described the previous request and nothing but another successful call
    /// could replace it, so after a compaction it kept the guard above the line
    /// and the loop re-compacted until it gave up (see ContextSizeMeter).
    ///
    /// `contextCalibrationRatios` — provider count / our estimate, taken from the
    ///   same request, PER MODEL: a ratio mostly reflects the provider's
    ///   tokenizer, so one learned on model A does not describe model B after a
    ///   switch. `lastLearnedCalibration` is the newest ratio of any model; a
    ///   model with none of its own borrows it with a margin (see
    ///   ContextSizeMeter.ratio(for:)).
    /// `contextFixedTokens` — estimated system prompt + tool schemas, refreshed
    ///   every loop iteration; seeded from the last stamped turn on load so the
    ///   send-time check has it before any loop has run.
    /// `lastDispatchEstimate` — estimate of the request currently in flight,
    ///   paired with its report when usage arrives.
    var contextCalibrationRatios: [String: Double] = [:]
    var lastLearnedCalibration: Double? = nil
    /// The session the in-memory ratios were learned for (see seedContextCalibration).
    var calibrationSessionId: String? = nil
    /// [T-ctx-warmup-fit] Per compaction marker: how many leading warm-up
    /// messages were dropped to fit. Decided once, then reused, so the request
    /// prefix stays stable across turns (see trimWarmUpToFit).
    var warmUpDropByMarker: [String: Int] = [:]
    var contextFixedTokens = 0
    /// [T-ctx-count-reasoning] Whether the provider serving this session sends
    /// past `reasoningContent` back (AgentProvider.echoesReasoningContent). Set
    /// by the agent loop from the live provider; the send-time check, which
    /// runs before a provider exists, reads the value of the previous request.
    var contextEchoesReasoning = false
    /// [T-ctx-trim-ladder] The live provider's default output cap, for the
    /// output reserve of the watermarks. Set by the agent loop like the flag
    /// above; 16K until a provider has been seen.
    var contextProviderMaxOutput = 16_384
    /// [T-ctx-trim-ladder] The frozen trim plan: cut-off keys re-applied to
    /// every measurement and request until the next re-plan, so the request
    /// prefix (and the provider's prompt cache) stays stable. In memory only.
    /// It belongs to one session and one compaction marker; a change of either
    /// drops it (see applyFrozenTrim).
    var trimState: ContextTrimPlanner.State?
    var trimStateSessionId: String?
    var trimStateMarkerId: String?
    /// [T-ctx-trim-plan-window] The window the plan was sized for.
    var trimStateWindow: Int?
    /// Set when the next check must re-plan even below the trigger (after a
    /// compaction, or when the frozen plan stopped matching the history).
    var trimReplanPending = false
    /// [T-ctx-trim-collapse-first] Set once a re-plan was allowed to collapse;
    /// later re-plans for the same session and marker keep allowing it (see
    /// ContextTrimPlanner.CollapseUnlock).
    var trimCollapseUnlock: ContextTrimPlanner.CollapseUnlock?
    /// [T-ctx-trim-escalate] True when the re-plan just made could not
    /// collapse and recovered too little (ContextTrimPlanner.shouldEscalate).
    var lastTrimPlanEscalates = false
    /// Disk paths of what the ladder already offloaded, so re-applying a plan
    /// writes nothing.
    var trimOffloadPaths: [String: String] = [:]
    var lastDispatchEstimate = 0
    /// [T-ctx-overflow-attribute-dispatch] Model id and window of the request
    /// in flight, so a rejection is attributed to the model that received it.
    var lastDispatchModelId: String?
    var lastDispatchWindow = 0
    /// The ratio and calibrated size used for the request in flight, so its
    /// response can be scored against the prediction ([CtxMeter] actual).
    var lastDispatchRatio: Double = 1.0
    var lastDispatchPredicted = 0
    /// Whether an uncalibrated send past an extrapolated "over the window"
    /// verdict has already been spent (see the in-loop guard). One per piece
    /// of provider evidence: an accepted response re-arms it, a rejection
    /// spends it, and it survives Retry.
    var sentPastExtrapolatedLimitThisLoop = false

    @Published var isProcessing = false {
        didSet {
            _deinitSnapshot = "isProcessing=\(isProcessing) session=\(sessionId ?? "nil") draft=\(draftId ?? "nil")"
            if isProcessing && !oldValue {
                // Agent loop starting — defer iCloud sync sends until completion.
                // [T-p0-sync-defer-refcount] Owner-keyed: two sessions can run
                // loops concurrently (ViewModelCache + SessionConcurrencyManager),
                // and a plain bool let the first loop to finish un-defer sync
                // under the one still streaming. The deferral for this vm is
                // released in releasePostStopSyncHold (or deinit).
                let owner = String(vmInstanceId)
                Task { await ChatStore.shared.beginSyncSendDeferral(owner: owner) }
                // [T-ios-defer-icloud-sync-after-stop] A new turn supersedes any
                // pending post-stop hold; clear it WITHOUT a catch-up sync (the
                // new turn re-pauses sync via setSyncSendDeferred anyway).
                if postStopSyncHoldUntil != nil {
                    postStopSyncHoldUntil = nil
                    postStopSyncHoldTimer?.invalidate()
                    postStopSyncHoldTimer = nil
                    logger.info("[SyncHold] CLEAR — new turn started, superseding post-stop hold")
                }
                // Begin watching for main-thread hangs while streaming is
                // active. Captures a backtrace whenever the main runloop
                // doesn't drain for >1s, plus a snapshot of streamed text
                // around the stall, so we can confirm whether the 0x8BADF00D
                // watchdog lands inside _fillLayoutHole, SwiftUI Layout, or
                // elsewhere — and correlate with the content being rendered.
                StreamingHangLogger.shared.acquire(reason: "isProcessing=true session=\(sessionId ?? "nil")")
            } else if !isProcessing && oldValue {
                // [T-ios-defer-icloud-sync-after-stop] Agent loop finished. Do
                // NOT flush the deferred iCloud push or replay a pull reload now
                // — that immediate sync is what overwrote the just-finished
                // candidate. Instead enter the post-stop hold: both directions
                // stay paused for the grace window, then a single catch-up sync
                // runs on release (60s timer / leave session / background).
                beginPostStopSyncHold()
                StreamingHangLogger.shared.release(reason: "isProcessing=false session=\(sessionId ?? "nil")")
                // [T-p0-programmatic-prompt] A silent (programmatic) turn ends
                // here whether it completed or was cancelled; never let the
                // flag leak into the user's next manual send.
                // [T-subagent-callback-no-keyboard] Hand the fact forward first:
                // this didSet runs before SwiftUI's onChange, so the auto-focus
                // observer would otherwise see an already-cleared flag and pop
                // the keyboard on a sub agent's callback.
                turnWasSilentProgrammatic = programmaticSilentTurn
                programmaticSilentTurn = false
                programmaticTurnOrigin = nil  // [T-user-ask]
                // [T-ios-context-usage-hint] Offer the usage line for this
                // turn. Only for a turn the user started and let finish:
                // a cancelled turn's usage is whatever call happened to be
                // in flight, and a silent sub-agent callback is not the
                // user's turn at all. The composer must also be empty —
                // the label is hidden behind typed text anyway, so the
                // request would just expire unseen. The Coordinator adds
                // its own debounce on top so a burst of quick turns shows
                // the line once, for the last of them.
                publishContextUsage()
                // [T-ios-context-usage-realtime-crossing] Keep the shared tier
                // record in step with the final usage (a cancelled or
                // queued-turn path may have landed usage the mid-loop observer
                // never saw), and skip the line when the mid-loop path already
                // announced this very tier moments ago — the label would just
                // repaint the same text and the voice panel would re-show it.
                let loopEndNow = Date()
                if let tier = contextUsage?.tier { _ = contextTierTracker.observe(tier, now: loopEndNow) }
                if !userDidCancel, !turnWasSilentProgrammatic, inputText.isEmpty,
                   let usage = contextUsage {
                    if contextTierTracker.recentlyFired(for: usage.tier, now: loopEndNow) {
                        logger.info("[ContextUsageHint] loop-end → dedup: mid-loop crossing hint for \(usage.tier) fired <\(Int(ContextTierCrossingTracker.minInterval))s ago (\(usage.usedTokens)/\(usage.windowTokens))")
                    } else {
                        contextUsageHintGeneration += 1
                        contextUsageHint = ContextUsageHint.make(usage: usage, generation: contextUsageHintGeneration,
                                                              quota: composerQuotaPart())
                        contextTierTracker.markFired(usage.tier, now: loopEndNow)
                        logger.info("[ContextUsageHint] loop-end → hint gen\(contextUsageHintGeneration) '\(contextUsageHint?.text ?? "")' (\(usage.usedTokens)/\(usage.windowTokens))")
                    }
                } else {
                    logger.info("[ContextUsageHint] loop-end → NO hint: cancel=\(userDidCancel) silent=\(turnWasSilentProgrammatic) inputEmpty=\(inputText.isEmpty) usage=\(contextUsage.map { "\($0.usedTokens)/\($0.windowTokens)" } ?? "nil")")
                }
                // [T-p0-programmatic-prompt] Rescue drain. Every drain runs in
                // some loop's epilogue BEFORE that loop flips isProcessing to
                // false, so a prompt enqueued in the await-gap between the
                // epilogue's drain and this flip has no consumer — it would sit
                // in promptQueue until the user's next turn. Start one now.
                // cancel() owns its own resume (resumeQueueAfterCancel) and
                // sets userDidCancel first, so it is excluded here.
                if !promptQueue.isEmpty && !userDidCancel {
                    startDrainIfIdle(reason: "loop-ended-with-queued-prompts")
                }
                // [T-ios-ui-frozen-on-tool-while-loop-runs] Force one snapshot
                // re-apply from the CURRENT in-memory messages at loop end.
                //
                // Why this is needed: during a multi-turn agent loop, tool blocks
                // are appended to the EXISTING last-assistant ChatMessage. The
                // messages ARRAY doesn't change, so the Coordinator's `$messages`
                // sink never re-fires and the per-message block-count subscription
                // can miss the appends — the new tool capsules are in the data
                // model but never get cells. The loop-end full reload that should
                // rebuild them goes through `reloadMessagesFromDB`, which is held
                // by the post-stop SyncHold and then SKIP-LOADs (`hashSame=true`,
                // because the DB baseline already advanced as the loop persisted),
                // so it never repaints. Result: the UI froze on the last-rendered
                // capsule for minutes while many turns ran un-rendered.
                //
                // `retrySnapshotReloadSignal` already does exactly the right thing
                // — re-applies the diffable snapshot from `vm.messages` even when
                // the array identity is unchanged (its original use: in-place
                // block mutation on retry). It is a pure UI re-render from memory:
                // it does NOT touch the DB / reload / SyncHold, so it can't
                // overwrite unpersisted content. Idempotent (the snapshot diff is
                // a no-op when nothing changed).
                //
                // CRITICAL guard — only fire when FOREGROUND and not UI-suspended:
                // the Coordinator's applySnapshot does a synchronous
                // `layoutIfNeeded()` (cell creation + self-sizing) on the main
                // thread. For a large history that is heavy work; running it while
                // backgrounded risks the 0x8BADF00D background-render watchdog
                // SIGKILL that `streamingUIUpdatesSuspended` exists to prevent. If
                // the loop ends while suspended/backgrounded, the Coordinator
                // already has `hasPendingSnapshot=true` and the suspend-resume hook
                // (T-ios-ui-blocks-lost-suspend-resume) flushes it on the next
                // foreground transition — so we must NOT force-apply here. We only
                // cover the foreground case (the actual freeze: block-count sub
                // missed in-place appends with NO suspend involved). Also gated on
                // `!transitionSuspended` so a session-switch outgoing VM doesn't
                // poke a tearing-down view graph (same guard as the manual
                // objectWillChange.send sites).
                // [T-blockslost-defensive defect ③] The flag ASSIGNMENT is no
                // longer wrapped in the `!transitionSuspended` gate: setting
                // `needsSnapshotReloadOnResume` touches no view, so the gate —
                // which exists to keep view-graph pokes out of the 0.4s
                // session-switch animation window — was pure collateral here.
                // A loop that ended inside that window previously left NO flag
                // behind, so nothing ever replayed for it. The gate still
                // protects the only view-touching action (the immediate
                // signal send below), whose conditions are unchanged.
                let inTransitionWindow = transitionSuspended
                if !inTransitionWindow,
                   !streamingUIUpdatesSuspended,
                   UIApplication.shared.applicationState == .active,
                   let sid = sessionId, Self.activeSessionId == sid {
                    retrySnapshotReloadSignal.send()
                } else {
                    needsSnapshotReloadOnResume = true
                    let totalBlocks = messages.reduce(0) { $0 + $1.blocks.count }
                    let lastBlocks = messages.last?.blocks.count ?? 0
                    let reason: String
                    if streamingUIUpdatesSuspended {
                        reason = "suspended"
                    } else if UIApplication.shared.applicationState != .active {
                        reason = "backgrounded"
                    } else if let sid = sessionId, Self.activeSessionId != sid {
                        reason = "no subscriber (active=\(Self.activeSessionId?.prefix(8) ?? "nil"))"
                    } else {
                        reason = "transition window"
                    }
                    logger.info("[BlocksLost] DEFERRED retrySnapshot — \(reason) at loop end. sid=\(sessionId?.prefix(8) ?? "nil") vm=\(vmInstanceId) transitionWindow=\(inTransitionWindow) totalBlocks=\(totalBlocks) lastMsgBlocks=\(lastBlocks) msgCount=\(messages.count)")
                }
                // [T-ios-detached-vm-loop-end] When an agent loop finishes on
                // a VM that is NOT the currently-displayed one (user navigated
                // away mid-loop), the final DB writes are invisible to the
                // displayed VM. Post a notification so the active VM for this
                // session reloads from DB and picks up the new data.
                if let sid = sessionId, Self.activeSessionId != sid {
                    logger.info("[BlocksLost] DETACHED loop end — posting reload for sid=\(sid.prefix(8)) (active=\(Self.activeSessionId?.prefix(8) ?? "nil"))")
                    NotificationCenter.default.post(name: .sessionAgentLoopDidEnd, object: sid)
                }
                // Also drain any skill-filesystem rescan that the AI's
                // shell tools may have queued during this turn. We hold
                // the rescan off the hot path so it runs once at quiet
                // time, not interleaved with every iSH write event.
                if #available(iOS 17.0, *) {
                    SkillFilesystemNotifier.shared.drainIfDirty(reason: "agent turn finished")
                }
            }
        }
    }
    /// [T-ios-group-pause-badge-restamp] Set only while a load / pre-warm is
    /// flipping `canResume` because the persisted tail STILL looks interrupted —
    /// i.e. the session was already paused and we are re-deriving that fact, not
    /// observing a new interruption. The `canResume` didSet reads this to decide
    /// whether the badge's entry timestamp may be overwritten. Not `@Published`:
    /// it is a transient annotation on the assignment, never UI state.
    /// Internal (not `private`) because the detecting site lives in the
    /// `+Persistence` extension, i.e. a different file.
    var isRedetectingInterruptedTail = false

    @Published var canResume = false {
        didSet {
            // [T-session-paused-badge-active-false-positive] Drive the session-
            // list PAUSED badge directly off canResume — the authoritative "this
            // session is interrupted (tap Resume)" flag and the single chokepoint
            // over every canResume setter. true → badge on; false (resumed / new
            // turn / completed) → badge off. Replaces the prior push at the
            // background-interruption point + clear-on-open, so a session merely
            // glanced at keeps its badge and a running/resolved session never
            // shows one. (Mirrors the Android canResume collector.)
            if oldValue != canResume, let sid = sessionId {
                if canResume {
                    // [T-ios-group-pause-badge-restamp] Only a REAL interruption
                    // re-stamps the badge's entry time. This didSet is the single
                    // chokepoint over every canResume setter, so it also fires
                    // when a load/pre-warm merely RE-DETECTS an old interrupted
                    // tail — that is not a new entry into the paused state, and
                    // re-stamping it there is what let a days-old pause keep
                    // looking "fresh" to the group card's 24h window forever.
                    // The detecting site sets `isRedetectingInterruptedTail`
                    // around its assignment; everything else is a live event.
                    SessionBadgeStore.shared.pushFront(
                        .paused, for: sid,
                        restamp: !isRedetectingInterruptedTail,
                        source: isRedetectingInterruptedTail ? .redetect : .push)
                } else {
                    SessionBadgeStore.shared.remove(.paused, for: sid)
                }
            }
            // [T-ios-cancel-reload-overwrite] reloadMessagesFromDB defers a
            // sync reload while `canResume` is true and the in-memory candidate
            // holds unpersisted interrupted content (so the reload can't
            // overwrite it). Once the interrupted state clears (Resume finished
            // / a normal turn completed and persisted everything), replay the
            // deferred reload so iCloud-synced changes finally land.
            if oldValue && !canResume && pendingSyncReloadOnIdle, let sid = sessionId {
                // [T-ios-retry-usermsg-vanish] Don't replay the deferred reload
                // if canResume is being cleared as the FIRST step of a retry
                // truncation — the reload would race the in-flight
                // messages/DB truncation and can drop the retried user message
                // from the UI. Leave pendingSyncReloadOnIdle armed; the retry's
                // own completion (isProcessing→false) drains it safely.
                if isTruncatingForRetry {
                    logger.info("[ReloadTrace] SKIP reason=canResume→false sid=\(sid.prefix(8)) — retry truncation in progress; deferred reload stays armed")
                } else {
                    pendingSyncReloadOnIdle = false
                    logger.info("[ReloadTrace] DRAIN reason=canResume→false sid=\(sid.prefix(8)) — replaying deferred sync reload after interrupted state cleared")
                    Task { @MainActor [weak self] in
                        await self?.reloadMessagesFromDB(reason: "deferredAfterResumeCleared")
                    }
                }
            }
        }
    }
    @Published var isSuspended = false
    /// [T-ios-streamdiag-phantom-model] LEGACY FALLBACK DEFAULT — never
    /// written anywhere; permanently holds `.claudeHaiku45`. The real model
    /// selection flows through `activeEntryId` → `ProviderConfigStore`
    /// (see runAgentLoop). The only legitimate reads are `?? selectedModel`
    /// last-resort fallbacks when entry resolution fails (documented in
    /// +ToolDefinitions). NEVER log or display this as "the current model":
    /// the SSE stall diagnostics did exactly that, and a stall investigation
    /// was nearly pinned on claude-haiku-4-5 — a model the session never used.
    @Published var selectedModel: LLMModel = .claudeHaiku45
    @Published var isLoadingSession = false
    /// False until the FIRST loadSession() for this vm completes. Lets the view
    /// distinguish "entering the session, nothing rendered yet" (show the soft
    /// centered loading card) from every later reload — iCloud sync, compaction,
    /// stale-cache refresh — which must keep the unobtrusive spinner and never
    /// cover content the user is already reading. Not @Published on purpose: it
    /// only ever changes alongside isLoadingSession, whose publish already
    /// re-evaluates the view.
    var hasCompletedInitialLoad = false
    @Published var errorMessage: String?

    /// [T-ios-retry-keyboard] Marks the in-flight turn as one the user started
    /// by tapping Retry / Resume on an EXISTING failed message, rather than by
    /// sending something new.
    ///
    /// The auto-focus-after-reply observer keys off the `isProcessing` true→false
    /// edge, and a retry produces exactly that edge — so re-running an old
    /// failure looked identical to "a reply just finished" and popped the
    /// keyboard. That is wrong for a retry specifically: the user's gesture was
    /// "send this again", not "let me type", and the composer rising covers the
    /// error they are trying to read.
    ///
    /// Deliberately NOT "suppress focus whenever a turn fails": auto-focus at
    /// the moment a fresh send fails is existing, wanted behaviour. The
    /// distinction being drawn is the ORIGIN of the turn, not its outcome.
    ///
    /// Not @Published — the observer reads it synchronously inside the
    /// isProcessing handler, and publishing it would re-render the whole chat
    /// on every retry for no visual reason.
    var turnStartedByRetry = false

    /// [T-longctx-persona-reminder-cachebreak] Context size at which the
    /// long-context persona reminder was last appended to `agentHistory`, or
    /// nil when this session has not been reminded yet.
    ///
    /// Drives the re-arm interval in `personaReminderIsDue(contextTokens:)`.
    /// Intentionally NOT persisted: on a fresh launch it starts nil and
    /// `personaReminderAlreadyInHistory()` recovers the state from history
    /// itself, which is self-healing and survives reload / iCloud restore
    /// without adding a schema column.
    var lastPersonaReminderContextTokens: Int?

    /// [T-subagent-callback-no-keyboard] True when the turn that just ended was
    /// started programmatically and silently — a sub agent's progress report or
    /// completion callback arriving via `submitProgrammaticPrompt(silent:)`.
    ///
    /// `programmaticSilentTurn` cannot serve here: it is cleared inside
    /// `isProcessing`'s own `didSet`, which runs BEFORE SwiftUI delivers the
    /// `onChange`, so the view would always read false. This flag is set from
    /// the same place and read (and consumed) by the auto-focus observer.
    ///
    /// Why it matters: the observer treats every `isProcessing → false` edge as
    /// "a reply arrived, ready the composer". A background sub agent reporting
    /// in drives a full parent turn, so each progress callback raised the
    /// keyboard while the user was reading — a focus change they never asked
    /// for. Same reasoning as `turnStartedByRetry`: the ORIGIN of the turn
    /// decides, not its outcome.
    ///
    /// Not @Published — read synchronously in the isProcessing handler.
    var turnWasSilentProgrammatic = false
    /// Transient banner for one-off notices the user should see (e.g. a
    /// resumed sub agent whose definition is gone, HelperRunner). UI clears it
    /// after a short display window. Not for automatic per-request handling:
    /// the request-level image budget notice that used to be set here was
    /// silenced to a log line ([T-silence-auto-notices]).
    @Published var transientNotice: String?

    @Published var autoRetryAttempt: Int = 0
    @Published var autoRetryCountdown: Int = 0
    /// [T-ios-empty-after-toolresult-reminder] Guards the one-shot
    /// `<system-reminder>` retry when the server returns an empty response
    /// right after a tool result. Set the first time we inject the reminder in
    /// a given agent loop; if the reminder round is ALSO empty we report an
    /// error instead of injecting again — so it can never loop. Reset at the
    /// start of each agent loop (a fresh user turn).
    var didInjectEmptyToolReminderThisRun = false
    /// Incremented when a model fallback occurs so the UI can animate the model name change.
    @Published var fallbackTrigger: Int = 0
    /// Signal to trigger scroll-to-bottom in views (not @Published to avoid full view diff).
    let scrollToBottomSignal = PassthroughSubject<Void, Never>()
    /// Fired when the view model wants the composer to grab keyboard focus
    /// (e.g. after a `/skill` tap fills the input — the user expects to
    /// immediately type their question without an extra tap on the field).
    let requestComposerFocusSignal = PassthroughSubject<Void, Never>()
    /// Force scroll-to-bottom AND re-enable auto-scroll. Used only for explicit user actions
    /// (send, enqueue, session reuse) — NOT during streaming, so user scroll position is respected.
    let forceScrollToBottom = PassthroughSubject<Void, Never>()
    /// Force scroll-to-top (first message). Used by the floating "scroll to
    /// first message" button — a counterpart to forceScrollToBottom that does
    /// NOT change auto-scroll mode (jumping to the top is always a browse action).
    let forceScrollToTop = PassthroughSubject<Void, Never>()
    /// Signal sent when a text block transitions from empty to non-empty content.
    /// The coordinator reconfigures the affected cell so UIHostingConfiguration
    /// re-measures its height (UIKit doesn't always trigger preferredLayoutAttributesFitting
    /// reliably when the SwiftUI body changes inside a UIHostingConfiguration).
    let blockContentFilledSignal = PassthroughSubject<(messageId: UUID, blockId: UUID), Never>()
    /// [T-fold-at-request-end] The assistant message the running agent loop
    /// is writing into; nil between loops. The message list folds only this
    /// message up to its fold horizon and plans every other message whole —
    /// `isProcessing` alone is too broad (a manual compaction sets it with no
    /// loop running, and the previous reply would then be cut back).
    var toolFoldRunningMessageId: UUID?
    /// [T-fold-at-request-end] For the running message: the last block of
    /// every request (one LLM call) whose reply was long enough to fold the
    /// tool runs before it (`ToolFoldPlanner.isFoldSeparator`), plus the last
    /// block it already held when this loop started writing into it (a resumed
    /// or retried turn: that content is finished, and was planned whole). The
    /// list folds the message up to the latest of these
    /// (`ToolFoldPlanner.foldHorizon`). Kept here rather than in the list so a
    /// re-created chat view still knows them. Cleared when a loop starts/ends.
    var toolFoldSeparators: [UUID: Set<UUID>] = [:]
    /// Fires with the message id after a request added to `toolFoldSeparators`.
    let toolFoldSeparatorSignal = PassthroughSubject<UUID, Never>()
    /// Content offset Y published on each scroll event (for debug jitter monitoring).
    let contentOffsetYSignal = PassthroughSubject<CGFloat, Never>()
    /// Content size height delta signal (for debug jitter monitoring).
    let contentSizeDeltaSignal = PassthroughSubject<CGFloat, Never>()
    /// Fired after a retry truncation to force the message list to re-apply its
    /// diffable snapshot. Needed because `retryFromToolBlock`'s sub-message path
    /// mutates `messages[i].blocks` in-place without changing the messages
    /// array count, so `$messages` won't fire a new value and the UIKit-backed
    /// `CollectionViewMessageListV3` (which doesn't observe `objectWillChange`)
    /// would otherwise keep showing the pre-cut block identifiers.
    let retrySnapshotReloadSignal = PassthroughSubject<Void, Never>()
    /// Whether the message list is scrolled near the bottom. Updated by CollectionViewMessageList.
    @Published var isNearBottom: Bool = true

    /// Whether the viewport is already at the very first user turn's top — i.e.
    /// the up-button ("scroll to previous turn") has nowhere further up to go.
    /// Drives ONLY the up-button's visibility (the down-button still keys off
    /// isNearBottom): once the user has walked all the way up, the up-button
    /// hides. Updated by CollectionViewMessageList on scroll/jump.
    @Published var isAtFirstTurn: Bool = false

    /// [ScrollDiag] View-layer record of a scroll-jump button's actual SwiftUI
    /// mount/unmount, so a ring dump (debug.scrollMetrics) can be diffed against
    /// the VM-side buttonsVisible. `up` picks which button; `visible` is true on
    /// appear, false on disappear. DEBUG-only; compiled out in Release.
    func recordScrollButtonRender(up: Bool, visible: Bool) {
        #if DEBUG
        ScrollMetricsRecorder.shared.record(
            kind: "btnRender",
            a: visible ? 1 : 0,
            pos: "\(up ? "up" : "down")-\(visible ? "appear" : "disappear") vmNearBottom=\(isNearBottom)")
        #endif
    }

    // Note: Stream throttle timestamps (lastTextDeltaFlush, lastFileWriteStreamUpdate,
    // lastToolInputStreamUpdate) are now local vars inside processStreamEvents().
    @Published var kernelStatus: KernelStatus = .notBooted
    /// When enabled, agent responses and tool descriptions are spoken aloud.
    /// Initialized from the persisted "Read replies" preference so an already-on
    /// toggle drives streaming TTS for new chats.
    /// Read-replies on/off. NOT per-session state — proxies the GLOBAL
    /// `VoiceOutputState.shared` so toggling in any session (or the home screen)
    /// is reflected everywhere. `voiceStateCancellable` (set in init) forwards the
    /// global object's changes to this VM so views observing `vm.speakEnabled`
    /// still refresh.
    var speakEnabled: Bool {
        get { VoiceOutputState.shared.isEnabled }
        set { VoiceOutputState.shared.isEnabled = newValue }
    }
    /// When enabled, uses 1-hour cache TTL instead of 5-minute for Anthropic requests.
    @Published var enhancedCacheEnabled = false

    /// Whether the Enhanced Cache toggle should be visible. Only Anthropic
    /// official API (no custom base URL) supports the cache TTL protocol.
    var showEnhancedCacheToggle: Bool {
        guard let entry = resolveCurrentEntry(),
              let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId)
        else { return false }
        guard inst.providerType == .anthropic else { return false }
        if let url = inst.customBaseURL, !url.isEmpty { return false }
        return true
    }

    // MARK: - Compact State
    /// Whether the slash command menu should be shown.
    @Published var showSlashMenu = false
    /// Filter text after "/" in the input.
    @Published var slashFilter = ""
    /// Currently highlighted index in the slash menu (-1 = none selected).
    @Published var slashMenuSelectedIndex = -1
    /// Whether a compaction is in progress.
    @Published var isCompacting = false
    /// When true, shows a prompt asking user to compact before sending.
    @Published var showCompactBeforeSendPrompt = false
    /// [T-chat-auto-compact-opt-in] Global (cross-session) opt-in: when the
    /// context-capacity threshold fires, compact automatically instead of
    /// prompting — the same no-UI path shortcut sessions already use. Set
    /// from the confirm dialog's "Compact & Enable Auto-Compact" button or
    /// the "..." menu's Auto Compact toggle; persisted in UserDefaults so
    /// future conversations inherit it.
    @Published var autoCompactEnabled: Bool = UserDefaults.standard.bool(forKey: "autoCompactOnThreshold") {
        didSet {
            guard autoCompactEnabled != oldValue else { return }
            UserDefaults.standard.set(autoCompactEnabled, forKey: "autoCompactOnThreshold")
        }
    }
    /// When true, shows a prompt telling user to start a new session or clear chat.
    @Published var showContextExhaustedPrompt = false
    /// Message text held back while the compact-before-send prompt is shown.
    var pendingSendText: String?
    /// Attachments held back while the compact-before-send prompt is shown.
    var pendingSendAttachments: [InputAttachment] = []
    /// [T-programmatic-prompt-no-composer] True when `pendingSendText` came
    /// from the composer, i.e. the user typed it. A programmatic prompt can
    /// reach the same holding area (send()'s .needsCompact / .exhausted
    /// branches run for every caller), and `cancelCompactBeforeSend` must not
    /// pour a job's prompt into the user's draft — it restores only their own
    /// text.
    var pendingSendIsFromComposer = false
    /// When true, skip the needsCompactBeforeSend check (used after compactAndSend to avoid loop).
    var skipCompactCheck = false
    /// When false, memory_write tool calls are skipped (returns "Memory disabled") in this session.
    @Published var memoryEnabled = true

    // MARK: - Session Stats
    /// Accumulated streaming duration (seconds) for output token speed calculation.
    var sessionStreamDuration: TimeInterval = 0
    /// Total output tokens produced during streaming (for speed calculation).
    var sessionStreamOutputTokens: Int = 0
    /// Cumulative cache read tokens across all API calls in this session.
    var sessionCacheReadTokens: Int = 0
    /// Cumulative cache write (creation) tokens across all API calls in this session.
    var sessionCacheWriteTokens: Int = 0
    /// Cumulative input tokens (excl. cache) across all API calls in this session.
    var sessionInputTokens: Int = 0
    /// Cumulative output tokens across all API calls in this session.
    var sessionOutputTokens: Int = 0

    // Tool snapshots
    @Published var toolSnapshots: [ToolSnapshotItem] = []

    // Attachments
    @Published var attachments: [InputAttachment] = []
    /// [OpenMinis#433] The composer holds something worth keeping when the
    /// user leaves: non-blank text (which also covers `[Pasted#N]`
    /// placeholders, whose buffer lives on this VM) or an attachment.
    var hasUnsentDraft: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    /// Number of videos currently being imported from the photo picker.
    @Published var loadingVideoCount = 0

    // [T-paste-placeholder] Session-scoped buffer for long pasted texts.
    //
    // A long paste no longer becomes a .txt attachment (models treat files
    // through a different, often worse, path than inline text). Instead the
    // text is stashed here and a `[pasted#N]` literal is inserted at the
    // caret; send() expands the literals back to the original text.
    //
    // Deliberately memory-only: the composer draft itself (`inputText`) is
    // never persisted, so buffer and draft share one lifetime by
    // construction — there is no "draft survived but buffer didn't" state to
    // degrade from. `nextPasteId` is monotonically increasing per vm
    // lifetime so ids are never reused while any draft that references them
    // can still exist.
    @Published var pastedTexts: [PastedText] = []
    var nextPasteId = 1

    /// Old iOS releases visibly jitter when the actively streaming markdown block
    /// re-self-sizes during user scroll/deceleration. While this flag is set, the
    /// newest streamed text snapshot is buffered and only applied after scrolling settles.
    struct DeferredStreamingTextUpdate {
        let messageId: UUID
        let blockId: UUID
        let text: String
        let parsedMarkdown: MarkdownContent?
        let cacheAttributedString: Bool
    }
    var deferredStreamingTextUpdates: [DeferredStreamingTextUpdate] = []
    var streamingUIUpdatesSuspended = false

    /// Set when `isProcessing` transitions to false but `retrySnapshotReloadSignal`
    /// cannot fire because `streamingUIUpdatesSuspended` is true. Cleared when the
    /// suspend lifts — at that point the snapshot rebuild is safe and is replayed.
    var needsSnapshotReloadOnResume = false

    /// [T-ios-ui-blocks-lost-suspend-resume] Fired on the main thread whenever
    /// `streamingUIUpdatesSuspended` transitions from true → false, from ANY
    /// path (scroll-settle resume, transition resume, explicit clear). The
    /// message-list Coordinator registers this so it can rebuild a snapshot it
    /// deferred while suspended (`hasPendingSnapshot`). Without it, a suspend
    /// window that opens during a multi-tool agent loop and closes after the
    /// stream ends has no subscription left to trigger the deferred flush, so
    /// the trailing assistant blocks never render even though they're in the DB.
    var onStreamingUIUpdatesResumed: (() -> Void)?

    /// [T-voice-viewport-context] Installed by the message-list Coordinator: the rows
    /// around what the user is looking at, for voice correction's on-screen context.
    /// Main thread. nil (or returning nil) when no list is on screen.
    var captureViewportSnapshot: (() -> ViewportSnapshot?)?

    /// True while this vm is the OUTGOING side of a session-switch transition.
    /// During the brief window when the UICollectionView/SwiftUI host views of
    /// the previous session are being torn down and the new session's views
    /// are being mounted, both ViewGraphs share the same AsyncRenderer thread.
    /// A concurrent mutation on the outgoing vm here can cause
    /// AG::Subgraph::NodeCache::~NodeCache to deref a dangling pointer
    /// (FB13213926, recurring), evidenced by build-48 crash
    /// Minis-2026-06-01-134710.ips: user switched sessions while both vms had
    /// `isProcessing=true`, EXC_BAD_ACCESS in
    /// `_UIHostingView.isHiddenForReuse.setter → ViewGraphHost.updateRemovedState
    /// → AG::Subgraph::invalidate_now → AG::Subgraph::NodeCache::~NodeCache`.
    /// While `transitionSuspended` is true:
    ///   * `streamingUIUpdatesSuspended` is force-true (text-block flush defer)
    ///   * Manual `objectWillChange.send()` callers consult `isTransitionSuspended`
    ///     and elide the publish when true (retry / edit / thinking-level
    ///     paths). The next genuine state change after resume re-publishes.
    var transitionSuspended = false

    /// True for the synchronous window of `retryFromMessage` /
    /// `retryFromToolBlock`: from the moment we start clearing `canResume` /
    /// truncating `messages` until the DB truncation (`deleteMessagesAfter`)
    /// has completed. While set, a deferred iCloud-sync `reloadMessagesFromDB`
    /// must NOT run — it would rebuild `messages` from a DB snapshot taken
    /// mid-truncation (before/around the delete) and can drop the retried user
    /// message from the UI even though it survives in agentHistory (so the
    /// reply is based on it but its bubble vanishes). Reload calls skip+rearm
    /// while this is true, and the canResume didSet does not replay the
    /// deferred reload; the next safe idle drains it. [T-ios-retry-usermsg-vanish]
    var isTruncatingForRetry = false

    // MARK: - Browser
    /// `var`, not `let`: a helper (child) vm adopts its PARENT's pool so both
    /// agents browse in one tab set (T-p2-shared-workspace). Per-agent default
    /// tabs keep them from stepping on each other — see BrowserTabPool.owner.
    var browserTabPool = BrowserTabPool()
    /// When true, the agent loop pauses at the next checkpoint to let the user operate the browser.
    @Published var browserTakeoverActive = false

    // MARK: - Prompt Queue
    /// Prompts queued by the user while the agent loop is running.
    @Published var promptQueue: [QueuedPrompt] = []

    // MARK: - Speech

    let speechSynthesizer = AVSpeechSynthesizer()
    lazy var speechDelegate = SpeechFinishedDelegate()
    /// True when speech is paused (not stopped). Toggled by the floating speech button.
    @Published var speechPaused = false

    /// Accumulates reasons for provider fallbacks within a single attempt, consumed by runAgentLoop to insert info blocks.
    var fallbackReasons: [(model: String, instance: String, reason: String)] = []

    /// [T-provider-live-check] Model and provider each agent provider object
    /// of this conversation was built for, by entry id. Read before every
    /// request to check that provider is still there and enabled.
    var providerIdentities: [String: ProviderAvailabilityRules.Identity] = [:]

    /// True when the synthesizer is actively speaking or has queued utterances.
    var isSpeaking: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Current read-replies speed multiplier, mirrored for the player control.
    /// Source of truth is VoiceOutputPreferences.speedMultiplier.
    @Published var speechSpeed: Float = VoiceOutputPreferences.speedMultiplier

    /// True once the first reply utterance has been handed to a TTS engine — used
    /// by the player control to collapse from expanded to compact on first speak.
    @Published var isReadingAloud = false

    /// Whether the floating speech player control is expanded (vs compact). Lives
    /// here so the chat view can overlay a tap-to-dismiss layer while expanded.
    /// Defaults to COMPACT — expansion is only initiated by an explicit user action
    /// that turns reading on (so a new session / relaunch shows compact).
    @Published var speechPlayerExpanded = false

    /// Per-reply snapshot of the TTS engine choice; cleared at each reply start.
    var replyUsesCloudTTS: Bool?

    /// True once THIS turn (one user send, spanning ALL agent-loop iterations)
    /// has cleared the previous turn's TTS leftovers. Lives on the vm — NOT on
    /// StreamResult, which is recreated per loop iteration: a per-iteration
    /// flag made every iteration's first textDelta call stopSession and cut
    /// off the previous iteration's still-playing speech. One turn = one
    /// read-aloud context; iterations append and play back-to-back.
    var hasClearedTTSForCurrentTurn = false

    // MARK: - Private

    /// Approximate current time string, rounded to the hour for cache stability.
    var _cachedTimeString: String = ""
    var _cachedTimeDate: Date = .distantPast

    /// Session ID for persistence integration. Set by the view on appear.
    var sessionId: String? {
        didSet {
            // A helper shares its parent's pool; never restamp it with the
            // child's id (that would move tab persistence to the child).
            if helperConfig == nil { browserTabPool.sessionId = sessionId }
            // [T-opencode-dedicated-channel] Keep the off-MainActor mirror in
            // step. This `didSet` is the single choke point every promotion
            // path flows through (ensureSessionReturningId, loadSession, the
            // RPC/intent entry points), so mirroring here means no caller has
            // to remember to do it.
            openCodeSessionBox.value = sessionId
            // [fork] Extension system's off-MainActor snapshot of the active
            // session id, used by interceptor/tool bridges.
            if helperConfig == nil { ActiveSession.set(sessionId) }
        }
    }

    /// [T-opencode-dedicated-channel] Off-MainActor mirror of `sessionId`, read
    /// by the OpenCode channel's per-request header hook.
    ///
    /// The hook runs wherever the request is built, which is not guaranteed to
    /// be the MainActor, while `sessionId` is MainActor-isolated state — so it
    /// cannot be read directly from a `@Sendable` closure. This box is the
    /// hand-off: written on main by the `didSet` above, read under a lock by
    /// the hook. Held by the VM (not global) because the id is per
    /// conversation.
    let openCodeSessionBox = OpenCodeSessionBox()

    /// The draft ID assigned by the parent view (e.g. "__new__<UUID>").
    /// Included in `.sessionDidCreate` notification so the parent can correlate.
    var draftId: String?

    /// Source tag written to the session record on creation (e.g. "shortcut").
    var sessionSource: String?

    /// [T-shortcut-duplicate-completion-notification] Suppresses the *generic*
    /// background-completion notification for this run, because a Shortcuts
    /// intent already posts its own via `ShortcutNotification`. Without this the
    /// user gets two overlapping notifications for one task: "Minis Task
    /// Completed" from the intent and "✅ {sessionTitle}" from
    /// `endBackgroundProcessing`.
    ///
    /// Deliberately NOT keyed off `sessionSource == "shortcut"`: that value also
    /// drives near-capacity auto-compaction and the context-exhausted error path
    /// (see `send()`), and RetryRun/FollowUp operate on sessions the user may
    /// have created by hand in the app. Tagging those as "shortcut" to get the
    /// notification behaviour would silently opt them into auto-compaction too.
    /// This flag carries exactly one meaning and nothing else reads it.
    ///
    /// Run-scoped and CONSUMED on read: `endBackgroundProcessing` clears it as it
    /// checks it, so it suppresses exactly the one completion it was set for.
    /// That matters because a VM is cached and reused — if the user opens the
    /// same session later and sends a message by hand, that run must still get
    /// its normal completion notification. A sticky flag would silence the
    /// session forever. Not persisted; each intent sets it fresh.
    var suppressGeneralCompletionNotification: Bool = false

    /// Model group to bind when creating a new session (from long-press FAB).
    var initialGroupId: String?

    /// Currently active session ID — accessible from anywhere for minis:// URL resolution.
    /// Updated whenever a session is loaded.
    nonisolated(unsafe) static var activeSessionId: String?
    /// REPRO-DIAG(2026-05-16): global round counter — each runAgentLoop
    /// invocation bumps this. Use `ROUND \d+` to slice the log by attempt.
    nonisolated(unsafe) private static var diagRoundCounter: Int = 0
    nonisolated static func bumpDiagRound() -> Int {
        // Not atomic because runAgentLoop is invoked from main actor and
        // serialised per ViewModel; concurrent rounds across VMs may race
        // and skip/dup a number, which is acceptable for a diagnostic id.
        diagRoundCounter &+= 1
        return diagRoundCounter
    }
    nonisolated static func currentDiagRound() -> Int { diagRoundCounter }
    /// Timestamp when onAppear fires — used to measure end-to-end load latency.
    nonisolated(unsafe) static var onAppearTimestamp: CFAbsoluteTime = 0

    /// Number of title generation attempts for this session (max 3).
    var titleGenAttempts = 0
    /// Whether a title generation request is currently in-flight.
    var isTitleGenerating = false

    /// [T-ios-switch-model-ghost-retry] Generation token for the detached
    /// title-generation Task.
    ///
    /// That Task resolves its model ONCE (`resolveSubEntry()`, which with no
    /// per-session sub model is the PRIMARY entry) and then retries up to 3
    /// times with a 1.5s gap. Without a token, a model switch during that
    /// window left it calling the model the user had just abandoned — one of
    /// the two ghost-retry sources in this bug.
    ///
    /// `cancelWorkBoundToPreviousModel` bumps this; the Task compares it
    /// before each attempt and bails on a mismatch. A plain bool could not do
    /// the job: title generation legitimately re-runs later (more turns
    /// arrive), and a bool would either block the new run or be reset by it.
    var titleGenEpoch: UInt = 0

    /// Unified conversation history used by both Anthropic and Gemini agent loops.
    var agentHistory: [AgentMessage] = []

    #if DEBUG
    /// [T-ios-log-noise-reduction] High-water mark of how many agentHistory
    /// entries the Debug `📋 agentHistory[i]` dump has already printed. The
    /// per-API-call dump only NSLogs entries at index ≥ this value (the delta
    /// since the previous call) instead of re-printing the whole growing
    /// history every iteration. Reset to 0 when the history shrinks.
    var lastDumpedAgentHistoryCount: Int = 0
    #endif

    /// Detects tool-call loops (repeated unknown tools, no-progress polling, runaway
    /// retries) and either injects warnings or short-circuits execution.
    let toolLoopDetector = ToolLoopDetector()

    // MARK: - Cache Keep-Alive State
    /// Snapshot of agent loop state for cache keep-alive warmup requests.
    /// Updated each iteration so the manager can replay the same prefix.
    var keepAliveHistory: [AgentMessage] = []
    var keepAliveSystemPrompt: String?
    var keepAliveTools: [AgentToolDefinition] = []

    // MARK: - Compact Marker (Phase B)
    /// Cached latest compact marker for this session. Phase B agent loop uses this
    /// (via effectiveAgentHistory) to inject the summary at inference time instead
    /// of mutating agentHistory. Updated by loadSession, compactBefore, and any
    /// path that writes a new marker.
    var cachedLatestMarker: CompactMarker?
    /// [T-offload-scan-cache] Per-part verdicts of the context-offload scanner,
    /// so a re-trigger does not re-judge and re-tokenize the whole history.
    /// In memory only; an empty cache (new VM, relaunch) simply rebuilds on the
    /// next scan. See `OffloadScanCache`.
    let offloadScanCache = OffloadScanCache()
    /// The session's persisted model id (from ChatStore.getSession). Cached at
    /// loadSession time so resolveCurrentEntry can fall back to it without an
    /// async hop to the actor. Empty string means "not yet loaded" — treat as
    /// no fallback.
    var cachedSessionModelId: String = ""
    /// The ModelEntry used in the current/last agent loop, for rebuilding the provider.
    var keepAliveEntry: ModelEntry?
    /// Pending thought signatures loaded from persisted session, keyed by tool call ID.
    /// Applied to GeminiAgentProvider when the agent loop starts.
    var pendingThoughtSignatures: [String: ToolCallMetadata] = [:]
    // `internal` (not `private`): the +Compaction extension's
    // schedulePostCompactDrain() runs the post-compact queue drain on this
    // task so cancel() can stop it. [T-compact-queued-drain]
    var currentTask: Task<Void, Never>?
    var compactTask: Task<Void, Never>?

    /// [T-ios-compact-task-binding] Which entry point started the compaction
    /// `compactTask` is currently holding.
    ///
    /// This exists because cancel()'s cleanup is NOT uniform across entry
    /// points: only compact-and-send has queued prompts to roll back. Once
    /// every entry point binds `compactTask` (previously only two of five did),
    /// cancelling a long-press compaction would otherwise run the
    /// compact-and-send rollback — emptying `promptQueue` and bouncing someone
    /// else's queued message into the input box. The origin lets cancel() undo
    /// only what this particular compaction actually set up.
    enum CompactOrigin {
        /// `/compact` slash command, or the toolbar item.
        case slashCommand
        /// Long-press a message → "Compact Above".
        case longPress
        /// User sent a message that needed compaction first; prompts are queued.
        case beforeSend
        /// Debug JSON-RPC (DEBUG builds only).
        case debugRPC
    }
    var compactOrigin: CompactOrigin?
    var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// [T-ios-bgkeepalive-diag] Process-wide count of LIVE
    /// `beginBackgroundTask` grants, so crash diagnostics can report whether a
    /// real `UIBackgroundTaskIdentifier` was held — previously the crash report's
    /// "BG task active" field showed `BackgroundKeepAliveManager.isActive`, a
    /// keep-alive *intent* flag with no relation to the OS grant, which made
    /// every report read as "background task healthy" even when no task was held.
    /// Maintained by begin/endBackgroundProcessing; `nonisolated(unsafe)` +
    /// lock-free because it is only mutated on the MainActor.
    @MainActor
    private(set) static var liveBackgroundTaskCount = 0

    @MainActor
    static func noteBackgroundTaskBegan() { liveBackgroundTaskCount += 1 }

    @MainActor
    static func noteBackgroundTaskEnded() {
        liveBackgroundTaskCount = max(0, liveBackgroundTaskCount - 1)
    }
    /// Tracks how many blocks on the current assistant message have been fully committed
    /// to agentHistory. Used by retry()/resume() to trim partial iteration content.
    var committedBlockCount: Int = 0
    /// The committedBlockCount before the current/last iteration started.
    /// Used by handleUserCancelledCleanup to roll back the last iteration.
    var prevCommittedBlockCount: Int = 0
    /// Set by cancel() so the task's error handler knows this was a user stop.
    /// Internal-access so concurrent tool extensions can read it. [T-concurrent-tools]
    var userDidCancel = false
    /// [T-stop-queued-cancel-error] Whether a turn's error epilogue is looking
    /// at the end of a Stop rather than a real failure.
    ///
    /// `userDidCancel` alone is not enough. It is shared by every turn of this
    /// vm, and when Stop leaves queued prompts behind, `resumeQueueAfterCancel`
    /// resets it to false after 200 ms so the drained turn can run. A turn
    /// stopped before its first token is usually still waiting on the HTTP
    /// response at that point, so its `LLMError.cancelled` ("Request was
    /// cancelled") arrives after the reset, reads as a real failure, and is
    /// pinned (with Retry) to the last assistant row — by then the NEW drained
    /// turn's bubble, whose start-of-turn error sweep already ran, so it never
    /// goes away. `Task.isCancelled` belongs to the stopped task itself and
    /// cannot be reset from outside, so it catches that late error.
    var turnWasStopped: Bool { userDidCancel || Task.isCancelled }
    /// [T-stop-sibling-subagent] Set when the user stops a sub agent from its
    /// card rather than stopping this conversation outright.
    ///
    /// Kept separate from `userDidCancel` on purpose. `userDidCancel` is read
    /// all over the loop's ending path — it removes placeholder blocks, marks
    /// the turn interrupted and drives `handleUserCancelledCleanup`. Setting it
    /// from a card would put the parent through a stop it never asked for. This
    /// flag says only "results delivered from now on must not restart the
    /// conversation", which is the whole of what the card's Stop means for the
    /// parent. Cleared whenever a new turn begins.
    var delegationResultsMuted = false
    /// [T-p0-programmatic-prompt] True while the current turn was started by
    /// `submitProgrammaticPrompt(silent: true)`; suppresses the send and
    /// completion haptics for that turn only. Cleared on every
    /// isProcessing → false transition.
    var programmaticSilentTurn = false
    /// [T-user-ask] Origin of a programmatic prompt that STARTED the current
    /// run (Shortcut / CLI / job) — such a run has no one to ask, so user_ask
    /// is not exposed. Cleared on every isProcessing → false transition.
    var programmaticTurnOrigin: ProgrammaticPromptOrigin?
    /// [T-user-ask] Whether this run exposes user_ask, decided with the tool
    /// list so the system prompt's fragment agrees with it for the whole run.
    var userAskExposedThisRun: Bool?
    /// [T-user-ask-deferred] This run exposes user_ask in deferred mode (no
    /// one can answer while it runs): the call returns `deferred` at once.
    var userAskDeferredThisRun: Bool?
    /// [T-user-ask-fallback] user_ask was called in this run (any outcome), so
    /// a question in the final text is not a missed ask. Reset per run.
    var userAskAskedThisRun = false
    /// [T-user-ask] The assistant row (tool_use included) of the tool batch
    /// now executing, and its tool ids — the loop writes that row only after
    /// the batch, so user_ask keeps a copy for recovery after a kill.
    var currentBatchAssistantRaw: RawMessage?
    var currentBatchToolUseIds: [String] = []
    /// [T-p1-delegate-task] Non-nil on a helper (child) vm. Drives the
    /// helper-specific prompt, tool set, turn cap and skill scope.
    var helperConfig: HelperConfig?
    /// [T-agent-model-identity] What the latest served turn of this vm's
    /// loop actually ran on (entry after fallback + the API-reported model).
    /// Read by the parent's HelperRunner / AgentJobRegistry for agent
    /// sessions; harmless bookkeeping on every other vm.
    @Published var lastEffectiveModel: EffectiveModelRecord?
    /// [T-agent-wrapup-turn] Set by the parent's budget watcher when a
    /// helper's wall-clock budget runs out: the loop then gives the child ONE
    /// more turn without tools to write its deliverable (see runAgentLoop).
    var helperWrapUpRequested = false
    /// [T-subagent-timeout-reason] Set by HelperRunner right before it
    /// cancels this helper because the budget AND the wrap-up grace ran out.
    /// That `cancel()` also sets `userDidCancel`; this flag is what tells the
    /// runner's timeout stop apart from a real user / parent Stop when the
    /// ending is classified. Reset when the runner starts a run.
    var helperStoppedForTimeout = false
    /// [T-subagent-termination] The loop sent this helper its one-shot
    /// closing request after a turn that ended with no text. Read by
    /// HelperRunner when it records how the run ended.
    var helperClosingAttempted = false
    /// [T-sub-agents-steer] Course corrections the parent queued for a running
    /// sub agent, delivered at the top of its next loop turn.
    ///
    /// Deliberately NOT delivered by interrupting: an in-flight tool call is
    /// never cut, so a steer that lands while the child is inside a 2-minute
    /// shell command is read when that command returns. That is the whole point
    /// of steering rather than cancelling — the work so far is kept.
    ///
    /// Written by the parent's tool call on the main actor and drained by the
    /// child's loop on the same actor, so no lock is needed.
    var pendingSteerMessages: [String] = []
    /// [T-p0-programmatic-prompt] Ids of queued prompts that arrived through
    /// `submitProgrammaticPrompt(silent: true)`. A drain started by
    /// `startDrainIfIdle` consults this to decide whether the turn it runs is
    /// silent (only when EVERY prompt it drains is programmatic).
    var silentQueuedPromptIds = Set<UUID>()
    /// [T-scheduled-preset-tool] Preset first steps of scheduled fires handed
    /// to this session, keyed by job id, waiting for the request that answers
    /// the fire's envelope (see `takePresetToolStream`). A later fire of the
    /// same job replaces its entry.
    var pendingPresetToolCalls: [String: ScheduledPresetToolCallRequest] = [:]
    /// Reentrancy guard for `drainQueuedPrompts()`. After a Stop with queued
    /// prompts, `cancel()` hands off to a fresh Task via `resumeQueueAfterCancel()`,
    /// but the original (superseded) send/retry/resume Task ALSO reaches its own
    /// post-loop `drainQueuedPrompts()` call. Without a guard both Tasks could run
    /// the queued turn, firing the next LLM request — and thus every tool call +
    /// reply — TWICE. Set/cleared only on @MainActor, so the check-and-set is
    /// atomic and spans the `await runAgentLoop()` suspension where the second
    /// drainer would otherwise slip in. [T-ios-concurrent-stop-double-request]
    var isDrainingQueue = false
    /// [T-queue-drain-handover] A drain was requested while another task held
    /// `isDrainingQueue`; the holder re-offers it when it releases the guard.
    var drainRequestedWhileBusy = false
    /// [T-compact-queued-drain] True while a post-compact queue drain has been
    /// scheduled (task created) but not finished. Dedup guard so the two
    /// schedulers (compactBefore's success tail + compactAndSend's failure
    /// backstop) can't spawn two racing drain tasks for the same compact.
    var postCompactDrainPending = false
    /// When non-nil, the next send() acts as an edit: truncates conversation from this
    /// message index and re-sends. Cleared after the edit is applied.
    @Published var editingMessageIndex: Int?
    /// [T-bubble-span] The edited bubble's id and its pre-edit text, captured
    /// by editMessage() and cleared with editingMessageIndex. In memory only.
    /// send() uses them to re-find the bubble (the index can go stale between
    /// Edit and Send) — see resolveEditedBubbleIndex.
    var editingMessageId: UUID?
    var editingOriginalText: String?
    /// [T-bubble-span] Bubbles an edit / delete-from-here removed while their
    /// send() had not yet appended the history entry (`awaitingHistoryEntry`).
    /// That send consumes its id here and drops the stale turn instead of
    /// appending the removed message behind the cut.
    var abandonedPendingSendIds: Set<UUID> = []
    /// Set when the background task expires mid-agent-loop; cleared on resume.
    var backgroundSuspended = false
    /// Continuation used to pause the agent loop while suspended in background.
    var foregroundContinuation: CheckedContinuation<Void, Never>?
    /// Continuation used to pause the agent loop during browser takeover (between turns).
    var takeoverContinuation: CheckedContinuation<Void, Never>?
    /// Continuation used to pause mid-action when the user takes over during a browser action.
    var midActionTakeoverContinuation: CheckedContinuation<Void, Never>?
    /// Timeout task for mid-action takeover (5 minutes).
    var takeoverTimeoutTask: Task<Void, Never>?
    var foregroundObserver: NSObjectProtocol?
    /// Timer that logs tool execution status while the app is backgrounded.
    var backgroundStatusTimer: Timer?
    let defaultCommandTimeout: TimeInterval = 900 // 15 minutes
    /// PID of the currently running shell command (0 = none).
    @Published var runningCommandPid: Int32 = 0
    /// Start time of the currently running command (nil = no command running).
    @Published var commandStartTime: Date?
    /// Set to `true` when the user explicitly stops a running command via the stop button.
    /// Checked after command completion so the tool_result can inform the model.
    var commandCancelledByUser = false

    /// Number of shell_execute tools currently in their pre-execution `delay`
    /// countdown. Lets `stopCurrentCommand()` treat the stop button as a valid
    /// cancel during the wait even though no iSH process exists yet.
    /// [T-delay-stop-latency] A COUNTER, not a Bool: under concurrent tool
    /// execution a second delaying tool finishing (and running its `defer`)
    /// would otherwise flip a shared Bool back to false while a sibling was
    /// still counting down, making the stop button a NOOP for that sibling.
    var toolDelayWaitCount = 0

    /// True while at least one shell_execute tool is in its pre-execution
    /// `delay` countdown.
    var toolDelayWaitActive: Bool { toolDelayWaitCount > 0 }

    /// Whether at least one enabled provider instance exists (has selectable models).
    /// Credential validity is checked at send time, not here — avoids blocking the
    /// send button due to Keychain/OAuth state that SwiftUI can't observe.
    var isReady: Bool {
        ProviderConfigStore.shared.instances.contains { $0.isEnabled }
    }

    // MARK: - Session Persistence

    /// Load an existing session's messages from the database and rebuild UI + agent history.
    ///
    /// The DB stores one RawMessage per API turn: user, assistant, user(tool-results), assistant, ...
    /// Reload messages from DB after iCloud sync brings new data.
    /// Only reloads if there are new messages (avoids disrupting active sessions).
    /// Tracks the highest DB sortOrder seen after each load, so iCloud sync reload
    /// only triggers when genuinely new messages arrive from another device.
    var lastKnownDbSortOrder: Int = 0
    /// Tracks the DB message count so we can detect remote deletions (retry propagation).
    var lastKnownDbCount: Int = 0
    /// Hash of the (id, sort_order) pairs from the last DB load. Catches a
    /// silent reorder by another sync path (HEAL on LWW skip) where neither
    /// the count nor the max sort_order changed.
    var lastKnownDbOrderHash: Int = 0
    /// Number of assistant turns in `agentHistory` at the moment we LAST marked
    /// this session unread. `endBackgroundProcessing()` is called from ~15 sites
    /// (normal completions, kernel-failure early-returns, cancel cleanup, the
    /// bgTask-expiration handler, resumeQueueAfterCancel, …), and it used to
    /// push `.unread` unconditionally on every one of them. That made a late or
    /// duplicate call — e.g. a background keep-alive bgTask expiring after the
    /// user already read and left the session — re-add the red dot with NO new
    /// content. We now only re-badge when the assistant-turn count has actually
    /// grown since the last badge, i.e. this run genuinely produced a new
    /// completion. [T-ios-unread-dot-reappears]
    var lastBadgedAssistantTurnCount: Int = -1

    // MARK: - Slash Commands (stored state)
    // Method bodies live in AIChatViewModel+SlashCommands.swift; stored
    // properties must stay on the class itself (extensions can't add them).

    /// Set by the slash-command handler to ask the view to show the
    /// "Clear Chat?" confirmation alert. The view mirrors this into its
    /// local @State and resets the flag back to false on observation.
    @Published var clearChatConfirmRequested = false

    /// Text saved before showing slash menu over existing input.
    /// When non-nil, the menu was opened via the "/" button while text existed —
    /// executing a command should restore this text instead of clearing it.
    var savedInputBeforeSlash: String?
    /// Caret offset saved alongside `savedInputBeforeSlash`.
    var savedCaretBeforeSlash: Int?

    // MARK: - File Mention (`@`) Menu

    /// Whether the `@`-file menu is visible.
    @Published var showMentionMenu = false
    /// Currently highlighted row index (-1 = none).
    @Published var mentionSelectedIndex: Int = -1
    /// Live filter extracted from the active `@<token>` in the input.
    @Published var mentionFilter: String = ""
    /// The `@` character's UTF-16 offset in `inputText` for the currently active trigger.
    /// Used to replace the token on selection. -1 when inactive.
    var mentionAnchor: Int = -1



    /// In-memory thinking level for sessions not yet persisted (no sessionId yet).
    /// nil = user hasn't explicitly set one; fall back to the default group's level.
    var pendingThinkingLevel: ThinkingLevel?

    /// Append an ephemeral system info message (not sent to LLM).
    func appendSystemInfo(_ text: String, icon: String) {
        let msg = ChatMessage(role: .systemInfo, content: text)
        msg.systemIcon = icon
        messages.append(msg)
    }

}
