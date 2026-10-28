//
//  ContentView.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView - the app's root view: the session list (sidebar), navigation
//  into a chat, and the entry points to settings, tools and sync.
//
//  Map of the ContentView files
//  ============================
//
//    ContentView/ContentView.swift          this file: stored state (@State,
//        @ObservedObject, ...), the draft-session id helpers, and `body`
//        (layout switch, sheets, onChange / onReceive wiring)
//    ContentView/ContentView+<Concern>.swift  ContentView members by concern:
//        Layout             split (iPad / wide) vs stack (iPhone) layout, detail
//        SidebarGrouping    date / pinned / folder sections, folder collapse and
//                           mini bar, the cheap-to-diff SidebarGroup projection
//        SessionList        the List / ForEach of rows and folder sections
//        SidebarToolbar     toolbar, sync subtitle and indicators
//        Navigation         selection helpers, new chat, open / switch session,
//                           quick-action and background navigation
//        SessionMenu        row context menu label + action channel wiring
//        RemoteSessions     sessions synced from other devices
//        PendingShare       share-extension handoff
//        EmptyState         first-run setup steps
//        Search             search bar and search scheduling
//        SessionRefresh     session list refresh / debounce
//        FAB                floating new-chat and search buttons
//        SectionHeaders     selectable rows, date and folder section headers,
//                           folder actions
//        SelectionToolbar   multi-select toolbar, force sync
//        SessionActions     delete (with info), regenerate title
//        Export             JSON / plain-text export
//    ContentView/Sidebar/   types the list is built from: SidebarGroup model,
//        row views (SessionRow, RemoteSessionRow), surfaces and modifiers,
//        context menu, action channels, folder picker and alerts, FAB, sync
//        indicators, DEBUG probes and tracer
//    ContentView/Sheets/    delete confirmation, export preview, session edit
//    ContentView/Support/   MacOS27GlassWorkaround (also used by AIChatView)
//    Settings/SettingsSheet.swift, Settings/AppearanceSettingsView.swift
//                           the settings screen opened from the toolbar
//
//  Rules that keep this split working
//  ==================================
//
//  - Stored properties (@State, @ObservedObject, @AppStorage, ...) stay in this
//    file's struct body: Swift extensions cannot hold them. The ones only an
//    extension file uses sit at the end of the body, in their original order,
//    so the struct's layout is unchanged by the split. New state goes here too.
//  - Declarations used from another file are module-internal (they were
//    `private` while ContentView was one file); treat them as private to the
//    home screen. Types used by a single file stay `private` there.
//  - Loggers are file-private, one copy per file that logs (`shareLog`,
//    `draftLog`), matching the rest of the app.
//  - Add new behaviour to the ContentView+<Concern> file it belongs to, or start
//    a new one; do not grow `body` - it is already near the type-checker's
//    budget (see FolderAlertsModifier).
//  - Source-scanning tests (MinisTests/Standalone) read every file under
//    Views/ContentView/ plus the two settings files, so code may move between
//    them freely.
//
//  History: until the split all of this was Views/ContentView.swift (~9.1k
//  lines). The code was moved verbatim; the differences are the repeated import
//  line, the per-file logger copies, the dropped `private` / `fileprivate`, the
//  relocated stored properties and the `extension ContentView { }` wrappers.
//

import SwiftUI

private let shareLog = AppLogger(category: "Share")
private let draftLog = AppLogger(category: "DraftSession")

/// Sheets triggered from the toolbar menu, consolidated into a single `.sheet(item:)`.
enum ToolSheet: String, Identifiable {
    case settings
    case rootfsManagement
    case browser
    case browserManagement
    case syncMigrationDetail
    var id: String { rawValue }
}

struct ContentView: View {
    /// Prefix for draft session IDs. Each new chat gets a unique suffix
    /// so SwiftUI's `.id()` correctly destroys old views and creates new ones.
    private static let newSessionPrefix = "__new__"

    /// Whether a session ID represents an unsaved draft session.
    static func isNewSessionId(_ id: String?) -> Bool {
        id?.hasPrefix(newSessionPrefix) == true
    }

    /// Generate a unique draft session ID.
    static func makeNewSessionId() -> String {
        "\(newSessionPrefix)\(UUID().uuidString)"
    }

    private static let groupSeparator = "__grp__"

    /// Generate a draft session ID that also carries a model group selection.
    static func makeNewSessionId(groupId: String) -> String {
        "\(newSessionPrefix)\(UUID().uuidString)\(groupSeparator)\(groupId)"
    }

    /// Extract the group ID embedded in a draft session ID, if present.
    static func extractGroupId(from id: String) -> String? {
        guard let range = id.range(of: groupSeparator) else { return nil }
        let groupId = String(id[range.upperBound...])
        return groupId.isEmpty ? nil : groupId
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var shareCoordinator: ShareCoordinator
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    /// Subscribe to the router so changes to its `@Published` fields are
    /// observed by SwiftUI — without this, `onChange(of: router.newChatTrigger)`
    /// reads a static value and never fires after the view mounts. Quick
    /// Actions that arrive before this view's `.onReceive(.newChatRequested)`
    /// publisher is attached (typical cold-launch race) would otherwise be
    /// dropped.
    @ObservedObject private var quickActionRouter = QuickActionRouter.shared
    // [T-ios-ipad-sidebar-running-indicator-stale] Observe the activity /
    // concurrency trackers AT THE LIST LEVEL too (SessionRow already observes
    // them, but the #584 id-list ForEach reuses an already-materialized cell
    // for the running session and swallows the row's @ObservedObject change
    // when only the running flag flips — id list & resolved ChatSession value
    // are unchanged). Observing here re-evaluates the list body when
    // activeSessions / suspended flips, which regenerates each row's composite
    // diff key (see sessionRowKeys) so the ForEach can't skip re-materializing
    // the row whose running state changed.
    @ObservedObject var sidebarActivityTracker = SessionActivityTracker.shared
    // Folder-header aggregates (anyUnread / anyPaused) read the badge store
    // during sidebarGroups; observing it here is what re-derives those
    // aggregates when a badge flips. Row-level observation alone would only
    // refresh the rows, not the header pass.
    @ObservedObject var sidebarBadgeStore = SessionBadgeStore.shared
    @ObservedObject var sidebarConcurrencyManager = SessionConcurrencyManager.shared
    /// [T-sidebar-subagent-running] Is this conversation busy, by the same
    /// rule the composer uses (`AIChatView.isBusy`)?
    ///
    /// `SessionActivityTracker` only knows about a session's OWN agent loop.
    /// When a turn delegates to background sub agents the parent's loop ends
    /// while they work, so the row went back to looking idle even though the
    /// composer still showed Stop and results were still on their way. The two
    /// surfaces have to answer this the same way.
    /// [T-ios-listsessions-perf] Every session id currently running work, as
    /// ONE set built per body pass.
    ///
    /// This used to be two calls per row per body pass —
    /// `SessionActivityTracker.isActive(id)` plus
    /// `AgentJobRegistry.hasActiveChildren(parent: id)`, the latter of which
    /// scans the job registry for a matching parent. The CPU Profiler trace
    /// measured 8.4 G cycles in that pair alone (inside 28.6 G of total
    /// `erasedSessionRow` work), because the cost is O(rows x registry) on a
    /// path that re-runs whenever ANY tracked activity ticks.
    ///
    /// Both underlying properties are already materialised sets — the folder
    /// header aggregate in `sidebarGroups` computes exactly this union — so
    /// gathering them once per pass and letting each row do a hash lookup
    /// makes the row side O(1) and the pass O(rows + registry).
    ///
    /// Held as @State rather than recomputed per row: the two ForEach bodies
    /// that build rows would each pay the union again, which is the cost this
    /// removes. `sidebarGroups` already builds the same union for its folder
    /// aggregates and publishes it here (see `noteRunningSessionIds`), so the
    /// set costs nothing extra to maintain.
    @State private var runningSessionIds: Set<String> = []

    /// Publish the running-id set computed by the groups pass. Assigns only on
    /// a real change: Set == is O(n) but the sets are small, and an
    /// unconditional write would invalidate the sidebar on every activity tick
    /// even when nothing started or stopped.
    func noteRunningSessionIds(_ ids: Set<String>) {
        guard ids != runningSessionIds else { return }
        DispatchQueue.main.async { runningSessionIds = ids }
    }

    func sessionIsRunning(_ id: String) -> Bool {
        runningSessionIds.contains(id)
    }

    /// [T-home-list-pass-trigger] The list inputs of this body pass, in
    /// HomeListPassInputs.names order. Lives here because runningSessionIds is
    /// private to this file. All O(1) except the small Set hashes.
    var homeListPassInputs: HomeListPassInputs {
        let sessionsIdentity = sessions.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } ^ sessions.count
        return HomeListPassInputs(values: [
            sessionsIdentity,
            runningSessionIds.hashValue,
            navigationPath.count,
            selectedSessionId?.hashValue ?? 0,
            isSearching ? searchQuery.hashValue : 0,
            isSelecting ? 1 &+ selectedIds.hashValue : 0,
            offscreenFolderHeaderIds.hashValue,
            collapsedFolderIds.hashValue,
            regeneratingTitleSessionId?.hashValue ?? 0,
            folders.count,
        ])
    }

    @State var sessions: [ChatSession] = []
    @State var folders: [ChatFolder] = []
    /// Collapsed folder sections. Pure UI view-state: persisted locally, never
    /// synced (like SessionBadgeStore's .unread — cross-device expand state is
    /// noise, not signal).
    @State var collapsedFolderIds: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedFolderIds") ?? [])
    /// Folder ids whose EXPANDED header card is currently scrolled out above
    /// the list's visible top — drives the floating mini-bar. A Set (not a
    /// single id) because "expanded" is the DEFAULT folder state: before the
    /// accordion ever runs, several folders can be expanded at once, so more
    /// than one header can be offscreen. Display picks one deterministically.
    @State var offscreenFolderHeaderIds: Set<String> = []
    /// Global Y of the list's visible top edge (under the nav bar), measured
    /// by the mini-bar overlay. The header probe compares its own global
    /// frame against this to decide "scrolled out". Changes on rotation only.
    @State var folderMiniBarTopY: CGFloat = 0
    /// [T-ios-folder-accordion-scroll-anchor] Last observed global minY of each
    /// folder header row, keyed by folder id. Written by a lightweight probe on
    /// every header (collapsed ones included — the accordion needs the position
    /// of the header ABOUT to expand, which by definition is still collapsed
    /// when the tap lands). Read once per toggle to decide whether a scroll
    /// correction is needed at all; never drives layout, so the per-frame writes
    /// cost nothing but a dictionary store.
    @State var folderHeaderTopY: [String: CGFloat] = [:]
    /// The list's visible BOTTOM edge in global coords, the lower bound of the
    /// "still on screen" test. Paired with `folderMiniBarTopY` (the top edge).
    @State var folderListBottomY: CGFloat = 0
    /// Memo for the sidebar grouping — see SidebarGroupsMemo. Keeps the
    /// O(N) partition + per-folder aggregation off every AttributeGraph
    /// flush (activity ticks during streaming re-eval this body at high
    /// frequency, including mid-scroll).
    @State var sidebarGroupsMemo = SidebarGroupsMemo()
    /// Pending "move to folder" — non-nil presents the picker sheet. Shared by
    /// the multi-select toolbar and the row context menu (single-selection is a
    /// one-element set).
    @State var folderPickerRequest: FolderPickerRequest?
    /// Set when the picker applied a move that originated from multi-select;
    /// selection mode is exited in the sheet's onDismiss (not in the apply
    /// callback) to avoid the documented animation conflict.
    @State private var folderMoveApplied = false
    // Folder-header context-menu state (rename / dissolve / delete-all / new chat).
    @State var folderToRename: ChatFolder?
    @State var renameFolderText = ""
    @State var renameFolderDesc = ""
    @State var folderToDissolve: ChatFolder?
    /// When delete-all runs for a folder, the (by then empty) folder row is
    /// dropped after the sessions are gone. Cleared on cancel in onDismiss.
    @State var pendingDeleteFolderId: String?
    /// "New chat in folder": the folder intent rides with the DRAFT ID, not a
    /// bare flag — a draft is promoted to a real row only on first message, so
    /// folder_id can't be written at draft time, and keying on the draft id
    /// means an abandoned draft never mis-files a later unrelated session.
    @State var pendingFolderDraft: (draftId: String, folderId: String)?
    /// Folder id currently hovered by a drag (empty string = the "ungroup"
    /// target on a date-bucket header). Drives the drop highlight.
    @State var dropTargetFolderId: String?
    /// [T-ios-session-list-equatable-jank] id → ChatSession lookup backing the
    /// sidebar rows. Held in @State (not a per-body-eval computed `[String:
    /// ChatSession]`) on purpose: a plain `let byId = computedDict` inside the
    /// List builder was captured as an AttributeGraph node input, so EVERY
    /// transaction flush deep-compared the whole dictionary
    /// (Dictionary.== → ChatSession.== × N) — the dominant scroll-deceleration
    /// CPU cost (HangDetector: flushTransactions → AGGraphSetOutputValue →
    /// Dictionary.== → ChatSession.==; Instruments: app-update phase 60–587ms
    /// spikes). @State is diffed by storage-box identity, not by deep value, so
    /// reading it from the row closure costs nothing per frame. Rebuilt only
    /// when `sessions` changes (see .onChange below).
    @State var sessionsByIdCache: [String: ChatSession] = [:]
    /// [T-sidebar-row-lookup-miss] Answers rows that miss the cache above
    /// (the render pass before its `.onChange` rebuild) without a per-row scan.
    @State var sessionRowLookupMemo = SessionRowLookupMemo()
    /// Soul name shown as the sidebar title. Sourced from SOUL.md, falls
    /// back to "Minis". Refreshed whenever SoulStore posts .soulMdChanged.
    @State var soulName: String = SoulStore.cachedMetadata.name.isEmpty
        ? "Minis" : SoulStore.cachedMetadata.name
    /// Subtitle state shown under the "Minis" sidebar title. nil hides the
    /// row; otherwise it renders as small capsules per type or a single
    /// status string. Refreshed by a 5s timer.
    @State var migrationSubtitle: SyncSubtitleState?

    enum SyncSubtitleState: Equatable {
        case paused
        case migrating(percent: Int, byType: [(label: String, count: Int)])
        case syncing(byType: [(label: String, count: Int)])
        case upToDate
        /// Engine is not running yet (boot delay / transport still
        /// connecting / coming back from background). Title shows a
        /// neutral 'waiting' icon — not an error.
        case waiting

        static func == (a: SyncSubtitleState, b: SyncSubtitleState) -> Bool {
            switch (a, b) {
            case (.paused, .paused): return true
            case (.upToDate, .upToDate): return true
            case (.waiting, .waiting): return true
            case (.migrating(let p1, let t1), .migrating(let p2, let t2)):
                return p1 == p2 && t1.map { $0.label + "\($0.count)" } == t2.map { $0.label + "\($0.count)" }
            case (.syncing(let t1), .syncing(let t2)):
                return t1.map { $0.label + "\($0.count)" } == t2.map { $0.label + "\($0.count)" }
            default: return false
            }
        }
    }
    // [T-ios-migration-timer-sessionlist-uaf-crash] The migration-subtitle
    // refresh cadence used to be a process-lived `Timer.publish(every:5).autoconnect()`
    // subscribed via `.onReceive` on the sidebar Group (see sessionList). A
    // process-lived Combine publisher whose sink attribute AttributeGraph rebuilds
    // on every body transaction is a use-after-free hazard: a 5s tick delivered into
    // the sink while the graph tears down/rebuilds that attribute releases a dangling
    // sink closure (crash below). Replaced with a `.task`-driven async loop whose
    // lifetime SwiftUI owns and cancels deterministically — no graph-bound publisher.
    // See migrationSubtitleRefreshInterval / migrationSubtitleLoop.
    @State var remoteDeviceSessions: [(device: SyncDevice, sessions: [ChatSession])] = []
    // showSettings consolidated into activeToolSheet (.settings)
    @State var showTerminal = false
    @State var showAlarmList = false
    @State var hasAlarms = false
    @State var activeToolSheet: ToolSheet?
    #if DEBUG
    // [debug] Keep the screen awake (disable the idle/auto-lock timer) while the
    // app is in the foreground. Memory-only on purpose — NOT persisted, so it
    // resets to off on every app launch. iOS automatically clears
    // `isIdleTimerDisabled` when the app leaves the foreground, so this is
    // re-applied on scenePhase == .active below; "foreground only" falls out for
    // free. Toggled from the DEBUG-only menu item in the sidebar more-menu.
    @State var keepScreenAwake = false
    #endif
    @StateObject private var browserPool = BrowserTabPool()
    @State var selectedSessionId: String?
    /// Shadow of the previously-selected session id, used to identify the
    /// outgoing vm in `onChange(selectedSessionId)` so we can suspend it
    /// for the AttributeGraph race window. SwiftUI's iOS 16 onChange API
    /// only delivers `newValue`; we maintain the previous value ourselves.
    @State private var previousSelectedSessionId: String?
    /// [T-ios-session-coldload-listsessions-block] Coalesces the delayed
    /// outgoing-session preview refresh so rapid session switching schedules
    /// one trailing listSessions() (after the incoming load settles) instead
    /// of stacking full scans onto the serialized ChatStore actor.
    @State var outgoingPreviewRefreshWork: DispatchWorkItem?
    // [T-ios-listsessions-refresh-coalesce] Serialize session-list refreshes so
    // the ~12 refresh call sites never run listSessions() concurrently. A second
    // request that lands while one is in flight sets `pending` and is served by a
    // single trailing run — instead of each site spawning its own Task and
    // assigning its own array snapshot (the memgraph showed 3 live [ChatSession]
    // arrays from concurrent refreshes). Combined with the ChatStore-side cache
    // (T-ios-listsessions-cache), a clean refresh now returns the same cached
    // array, so this mainly prevents redundant Task churn.
    @State var sessionRefreshInFlight = false
    @State var sessionRefreshPending = false
    /// [T-ios-listsessions-perf] When the last refresh FINISHED. The cooldown
    /// is measured from completion, not from the notification that triggered
    /// it — see `SessionRefreshScheduler`.
    @State var lastRefreshFinishedAt: Date?
    /// When the one outstanding cooldown run is due, or nil if none is
    /// pending; overlapping notifications coalesce onto it rather than
    /// stacking. A `Date` driving `.task(id:)` rather than a stored
    /// `DispatchWorkItem`: a work item held in @State keeps a heap closure
    /// that captures this whole view struct, which is the exact pattern
    /// behind the objectdestroy.NNTm use-after-free cluster (a stale
    /// ContentView copy destroyed during graph teardown — see
    /// [T-ios-crash-contextmenu-uaf]). `.task` is owned by the view graph
    /// and cancelled with it.
    @State var sessionRefreshCooldownDeadline: Date?
    /// Whether the initial session load has completed (prevents showing the list before we decide to auto-navigate).
    @State var didInitialLoad = false
    /// Controls sidebar visibility on iPad (automatic handles iPhone collapse).
    @State var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Launch screen preference: 0=Auto, 1=Last Session, 2=New Chat.
    @AppStorage("launchScreen") private var launchScreen: Int = 0
    /// FAB position preference: false = right (default), true = left.
    @AppStorage("fabOnLeft") var fabOnLeft = false
    /// Mirror of `SyncV2Bootstrap.isEnabled` so SwiftUI re-evaluates
    /// the iCloud-gated menu entries (per-session Force Sync / Force
    /// Pull and the multi-select Force Sync) the moment the user
    /// flips the toggle in Settings — without this, calling the
    /// static getter inline would only re-read on the next unrelated
    /// state change. `SyncV2Bootstrap.setEnabled` writes the same key.
    @AppStorage("cloudSync.v2.enabled") var iCloudSyncEnabled: Bool = false
    /// Current drag offset of the FAB (reset to 0 on drop).
    @State var fabDragOffset: CGFloat = 0

    // Multi-select
    @State var isSelecting = false
    @State var selectedIds: Set<String> = []
    /// Transient banner shown after a Force Sync action runs against
    /// a selection. Cleared after a few seconds via DispatchQueue.
    @State var forceSyncToast: String? = nil
    @State var forceSyncInFlight = false
    @State var scrollToId: String?
    @State var showDeleteConfirm = false
    @State var isComputingDelete = false
    @State var showExportPreview = false
    @State var isExporting = false
    @State var exportFileURL: URL?
    /// [T-export-preview-blank] The UNZIPPED payload backing `exportFileURL`, used
    /// only to render the preview. `exportFileURL` is the artifact the user shares
    /// or saves (a .zip), and zip bytes cannot be decoded as text — previewing it
    /// produced a blank page. Nil when there is nothing text-previewable.
    @State var exportPreviewURL: URL?
    @State var exportProgress: (done: Int, total: Int)? = nil
    @State var exportSummary: ExportSummary? = nil
    @State var deleteInfo: DeleteInfo?

    // Single delete
    @State var sessionToDelete: ChatSession?
    @State var singleDeleteInfo: DeleteInfo?

    // Title regeneration
    @State var regeneratingTitleSessionId: String?

    // Edit session
    @State var sessionToEdit: ChatSession?

    // [T-ios-crash-contextmenu-uaf] Stable action relay for session context menus.
    @State var menuActions = SessionMenuActionChannel()

    // [T-ios-crash-objectdestroy-fab-uaf] Same, for the draggable FABs.
    @State var fabActions = FABActionChannel()

    // Search
    @State var showSearchBar = false
    var isSearching: Bool { showSearchBar && !searchText.isEmpty }
    @State var searchText = ""
    /// Session IDs that matched the current search query (nil = no active filter).
    @State var searchMatchedIds: Set<String>?
    /// Per-session matched-content snippet for sessions whose match was on
    /// message body rather than title — surfaced in the row's subtitle slot
    /// in place of the generic `lastMessage` preview. Empty when no active
    /// search or for title-only matches. Mirrors Android
    /// `SessionListViewModel.searchSnippets` (commit 545d585).
    /// T-search-highlight 8edb74f2.
    @State var searchMatchSnippets: [String: String] = [:]
    /// [T-search-folder-expand] Folders whose NAME matched the query. Their
    /// members all count as results, and the folder card shows even when
    /// empty, so a hit on the folder itself is visible.
    @State var searchMatchedFolderIds: Set<String> = []
    /// [T-search-folder-pages] Pages shown per search-expanded folder (folder
    /// id → page count, default 1). Reset whenever a new result set arrives
    /// or search ends, so every search starts at the first page.
    @State var searchFolderPages: [String: Int] = [:]
    @State var searchTask: Task<Void, Never>?
    /// [T-search-folder-expand] A search result set is on screen (not merely
    /// text in the field: whitespace-only input and the debounce window keep
    /// the normal list). Folders are shown expanded while this holds.
    var searchResultsActive: Bool { isSearching && searchMatchedIds != nil }
    /// The query as the search ran it — the rows highlight this, so a
    /// trailing space in the field does not stop the highlight.
    var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    /// Width threshold below which the layout collapses to single-column (iPhone-style).
    private let compactThreshold: CGFloat = 700
    /// Whether the device is an iPad (iPhones always use stack layout regardless of width).
    private let isIPad = UIDevice.current.userInterfaceIdiom == .pad
    /// Whether the current window is wide enough for two-column layout.
    @State var isWideLayout = false
    /// Navigation path for stack (compact) layout.
    @State var navigationPath = NavigationPath()
    /// Tracks the session ID currently visible on the compact navigation stack.
    @State var currentStackSessionId: String?
    /// [T-ios-stacknav-transition-attributegraph-race] Compact-layout analogue
    /// of `previousSelectedSessionId`: the session that was on the stack before
    /// the most recent `navigationPath` change, so the `onChange` observer can
    /// suspend the OUTGOING vm for the transition.
    ///
    /// A separate property is required — `currentStackSessionId` cannot serve
    /// here. `.onChange` is a view-update observer, so it runs after the state
    /// change is committed, and every navigation helper assigns
    /// `currentStackSessionId = newId` in the same synchronous block that
    /// mutates the path (see `switchToSession` / `handleNewChatRequest` /
    /// `openSession`). By observer time it therefore already holds the INCOMING
    /// id, and reading it would suspend the wrong vm — the one being mounted.
    @State var previousStackSessionId: String?
    /// The real session ID after a draft session is persisted (iPad only).
    /// While set, the AIChatView for this session stays alive even though
    /// selectedSessionId may still be a draft ID.
    @State var newSessionRealId: String?
    /// The draft ID that owns the current new-session view (iPad only).
    /// Used to redirect back when the user taps the real session row.
    @State var activeDraftId: String?

    /// Last `QuickActionRouter.newChatTrigger` value we've already routed.
    /// SwiftUI's `onChange` fires for transitions, not for initial values,
    /// so we use this to decide whether `onAppear` (or `onChange`) still
    /// owes a `handleNewChatRequest()` call.
    @State private var consumedQuickActionTrigger: Int = 0

    /// Set when `handleNewChatRequest()` had to pop the iPhone
    /// NavigationStack before it could open the new draft session.
    /// `onChange(of: navigationPath.count == 0)` watches this and
    /// dispatches the new-draft open once the pop has fully settled.
    @State var pendingNewChatAfterPop: Bool = false
    /// Pre-computed session id for the pending pop+open dance, so the
    /// id we hand to `QuickActionWorkflow.attachTargetSession` here
    /// matches the one `openSession` will use after the pop commits.
    @State var pendingNewChatTargetId: String? = nil

    /// [T-ios-bg-nav-push-watchdog] A `navigationPath` write that arrived while
    /// the app was NOT active, held back until it is.
    ///
    /// Four `.ips` reports (1.12(16) 03:58 + 04:09, 1.13(1) 19:28 + 20:04, all
    /// `WatchdogVisibility: Background`) share one main-thread stack:
    ///
    ///     NavigationStackCoordinator.update(to:from:navigationController:…)
    ///     → UIKitNavigationController.pushViewController(_:animated:)
    ///     → -[UINavigationController _immediatelyApplyViewControllers:…]
    ///     → -[UINavigationBar _redisplayItems]
    ///     → -[UIView(Hierarchy) layoutBelowIfNeeded]      ← synchronous, whole tree
    ///
    /// `_immediatelyApplyViewControllers` is the non-animated branch: it runs
    /// the pushed screen's ENTIRE first layout pass inline, with no yield point.
    /// The screen being pushed is always `AIChatView` (the sole
    /// `navigationDestination` below) — the heaviest view in the app — so that
    /// pass costs hundreds of ms even on a good day.
    ///
    /// The reports' CPU statistics show the main thread pinned at ~100% of one
    /// core for the whole window (10.230s of application CPU inside a 10.00s
    /// scene-update allowance; 5.309 / 5.643 / 5.517s inside the 5.0s
    /// terminate allowance — the "17% CPU" line is percent-of-six-cores). No
    /// other thread holds a lock; SwiftUI's AsyncRenderer is itself parked on
    /// `_MovableLockLock` waiting for the ViewGraph lock main holds. So this is
    /// a compute-bound main-thread stall, not a deadlock.
    ///
    /// While the agent loop runs backgrounded (`beginBackgroundTask("AgentLoop")`
    /// + silent-audio keep-alive), notification / deep-link / QuickAction /
    /// share routes can all still write `navigationPath`. Backgrounded, that
    /// push renders nothing a user can see, yet spends its full layout cost
    /// inside the 5s termination or 10s scene-update budget — and the process
    /// gets SIGKILL'd. (The 03:58 report's `procExitAbsTime` lines up exactly
    /// with the 04:09 report's `procLaunch`: killed, relaunched, and killed
    /// again 11 minutes later on the same path.)
    ///
    /// Deferring costs nothing: the destination is offscreen either way, and
    /// on foreground return the same layout runs with a full frame budget
    /// instead of against a watchdog clock.
    ///
    /// Carries the deferral instant so a stale request can be dropped rather
    /// than flushed — see `pendingBackgroundNavigationTTL`.
    @State var pendingBackgroundNavigation: (path: NavigationPath, deferredAt: Date)?

    /// [T-ios-bg-nav-push-watchdog] How long a deferred push stays valid.
    ///
    /// The gate above answers "don't push while backgrounded"; this answers
    /// "…but for how long is that push still what the user wants?". A push
    /// deferred at 02:00 by a background agent-loop notification is not a
    /// destination the user asked for when they open the app at 09:00 to
    /// glance at the session list — flushing it would yank them into an
    /// unrelated session with no action of theirs behind it. That is a
    /// navigation-semantics bug, not a crash, but it is the direct cost of the
    /// deferral this mechanism introduced, so it belongs here.
    ///
    /// 90s: the case worth honouring is "user taps a notification / deep link,
    /// app foregrounds, push lands" — that round trip is seconds, and even a
    /// slow cold launch with a rootfs warm-up stays well inside a minute.
    /// Anything older is the app having sat suspended, where the reopen is far
    /// more likely to be the user's own intent than a reply to that stale
    /// request. Deliberately much tighter than the 15-minute "latest session is
    /// stale, open a new one instead" heuristic further down: that one picks
    /// between two reasonable destinations, whereas this one decides whether to
    /// override where the user just chose to be.
    static let pendingBackgroundNavigationTTL: TimeInterval = 90

    var body: some View {
        GeometryReader { geo in
            let wide = isIPad && geo.size.width >= compactThreshold
            Group {
                if wide {
                    splitLayout
                } else {
                    stackLayout
                }
            }
            .overlay(alignment: .top) {
                if let toast = forceSyncToast {
                    ForceSyncToastBanner(text: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: forceSyncToast)
            .onChange(of: wide) { newWide in
                isWideLayout = newWide
            }
            .onAppear {
                isWideLayout = wide
                wireMenuActions()
                wireFABActions()
            }
            // [T-storage-session-cache] Sessions deleted from Settings › Storage:
            // drop them from the list now and close the conversation if it is one
            // of them, as deleting from the sidebar does. Settings is a sheet, so
            // on iPhone that conversation can be open underneath it.
            .onReceive(NotificationCenter.default.publisher(for: .sessionsDeletedElsewhere), perform: handleSessionsDeletedElsewhere)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .sessionDidCreate),
            perform: handleSessionCreatedForPendingFolder
        )
        .onReceive(NotificationCenter.default.publisher(for: .newChatRequested)) { _ in
            handleNewChatRequest()
        }
        // Cold-launch belt-and-braces: a Home Screen Quick Action that
        // fires before `.onReceive(.newChatRequested)` is attached
        // (WindowGroup still mounting) would otherwise be lost. The
        // router bumps `newChatTrigger` whenever it handles a shortcut.
        //
        // `quickActionRouter` is an `@ObservedObject`, so SwiftUI re-runs
        // body on every bump and `onChange` actually fires. The
        // `consumedQuickActionTrigger` state below tracks the last value
        // we've already routed — on cold launch the router might bump to
        // 1 (or higher, if the user invokes shortcuts multiple times
        // before the WindowGroup mounts) BEFORE our `.onAppear` runs;
        // we therefore also check the initial value on appear and route
        // any unconsumed bumps then.
        .onChange(of: quickActionRouter.newChatTrigger) { newValue in
            guard newValue != consumedQuickActionTrigger else { return }
            consumedQuickActionTrigger = newValue
            handleNewChatRequest()
        }
        .onReceive(QuickActionWorkflow.shared.$state) { newState in
            // Workflow advanced to pendingDispatch (either same-runloop
            // because we were already home, or after markHome fired
            // from a navigation change). Open the new session now.
            if case .pendingDispatch = newState {
                openSessionForPendingQuickAction()
            }
        }
        .onAppear {
            if quickActionRouter.newChatTrigger != consumedQuickActionTrigger {
                consumedQuickActionTrigger = quickActionRouter.newChatTrigger
                // Defer one runloop so the NavigationStack body has a
                // chance to attach `$navigationPath` before we append to
                // it — otherwise the append on a freshly-mounted stack
                // can be lost.
                DispatchQueue.main.async {
                    handleNewChatRequest()
                }
            }
            // The Appearance language picker wrote "pendingSettingsReopen"
            // right before changing appLanguage, which forced the root
            // `.id(appLanguage)` rebuild that just dropped + re-mounted us.
            // Reopen the Settings sheet so the user lands back where they
            // were instead of stranded on the chat list. SettingsSheet's
            // own onAppear pushes the saved destination onto its navPath.
            if UserDefaults.standard.string(forKey: "pendingSettingsReopen") != nil {
                DispatchQueue.main.async {
                    activeToolSheet = .settings
                }
            }
            // [T-ios-bg-nav-push-watchdog] Backstop for the scenePhase flush.
            // `.onChange(of: scenePhase)` only fires on a TRANSITION, so a
            // deferral that happened before this view mounted — a cold launch
            // straight into the background, or a root remount (the
            // `.id(appLanguage)` rebuild above) — would leave the push stranded
            // with no later transition to release it. Deferred one runloop for
            // the same reason the quick-action path above is: the
            // NavigationStack must have attached `$navigationPath` first.
            DispatchQueue.main.async {
                flushPendingBackgroundNavigation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidCreate)) { note in
            guard isWideLayout, let newId = note.object as? String else { return }
            let noteDraftId = (note.userInfo as? [String: String])?["draftId"]
            draftLog.info("🔑DRAFT sessionDidCreate realId=\(newId) noteDraftId=\(noteDraftId ?? "nil") selId=\(selectedSessionId ?? "nil") curReal=\(newSessionRealId ?? "nil") curDraft=\(activeDraftId ?? "nil")")
            // Verify this notification came from the currently active draft.
            // A late notification from a previous (now-destroyed) draft must be ignored.
            guard let selId = selectedSessionId, Self.isNewSessionId(selId),
                  noteDraftId == selId else {
                draftLog.info("🔑DRAFT sessionDidCreate IGNORED (draftId mismatch or not a draft)")
                // [T-ios-state-publish-offmain-crash] ChatStore (an actor) posts
                // .sessionDidCreate/.sessionDidUpdate from its background
                // executor; NotificationCenter delivers synchronously on that
                // thread, so this onReceive closure can run off-main. A bare
                // Task{} started here inherits the (background) execution context,
                // so `sessions =` (a @State write) lands off-main → "Publishing
                // changes from background threads" + AttributeGraph corruption of
                // the [ChatSession]/[String:ChatSession] state it deep-compares,
                // crashing in ChatSession.== / deinit during flushTransactions.
                // This onReceive can be delivered off-main, so hop explicitly —
                // refreshSessionList's @State writes must land on the main thread.
                Task { @MainActor in
                    refreshSessionList()
                }
                return
            }
            newSessionRealId = newId
            activeDraftId = selId
            draftLog.info("🔑DRAFT sessionDidCreate ACCEPTED newSessionRealId=\(newId) activeDraftId=\(selId)")
            // [T-ios-state-publish-offmain-crash] force main-thread @State write
            Task { @MainActor in
                refreshSessionList()
            }
        }
        .onReceive(
            // Throttle (not debounce): session-list updates are infrequent (one
            // per agent tool round, seconds apart), but a long multi-tool task
            // emits a steady stream of them. `.debounce` was reset by every new
            // event, so during a continuously-running task the list NEVER
            // refreshed until the task fully stopped — the row stayed on its
            // stale preview ("No messages yet") the whole time. `.throttle`
            // fires the first event right away and then at most once per second,
            // so the preview keeps up with each tool round without thrashing
            // `listSessions`.
            NotificationCenter.default.publisher(for: .sessionDidUpdate)
            // [T-ios-listsessions-perf] This 1 s window is now only a cheap
            // pre-filter on the notification storm; the real floor on refresh
            // frequency is the completion-measured cooldown in
            // refreshSessionList (SessionRefreshScheduler).
                .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        ) { _ in
            // [T-ios-state-publish-offmain-crash] force main-thread @State write
            Task { @MainActor in
                refreshSessionList()
            }
        }
        // [T-ios-listsessions-perf] The refresh cooldown timer. See
        // `sessionRefreshCooldownDeadline` for why this is a task keyed on a
        // Date rather than a stored DispatchWorkItem.
        .task(id: sessionRefreshCooldownDeadline) {
            guard let deadline = sessionRefreshCooldownDeadline else { return }
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // [T-scroll-sync-defer] Clearing the deadline is itself a state
            // change that re-evaluates the home list; wait out a fling first.
            while ChatScrollActivity.isMoving, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ChatScrollActivity.quietInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            sessionRefreshCooldownDeadline = nil
            refreshSessionList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveInputToSession)) { note in
            guard let targetId = (note.userInfo as? [String: String])?["targetId"] else { return }
            // Skip navigation if the target session is already visible
            if isWideLayout {
                guard selectedSessionId != targetId && newSessionRealId != targetId else { return }
                // Wide layout replaces selection — no stack to worry about
                openSession(targetId)
            } else {
                // [T-ios-moveto-transfer-race] No early-return when the target
                // already reads as current: a swallowed push leaves
                // `currentStackSessionId` set to a target that never appeared,
                // and bailing here is exactly what made a retry do nothing.
                // switchToSession is idempotent, so re-running it for a target
                // that genuinely is on screen is harmless.
                switchToSession(targetId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionFromIntent)) { note in
            guard let sessionId = (note.userInfo as? [String: String])?["sessionId"] else { return }
            // [T-notification-tap-vs-launch-session] Warm path owns this
            // navigation: drop the cold-launch buffer copy and stamp the
            // handling time so an in-flight launch `.task` (the post can land
            // during its `await listSessions()`) doesn't clobber the target
            // session with the Launch Session default afterwards.
            NotificationNavigationStore.shared.markHandled()
            // Skip navigation if the target session is already visible
            if isWideLayout {
                guard selectedSessionId != sessionId && newSessionRealId != sessionId else { return }
                openSession(sessionId)
            } else {
                // [T-ios-moveto-transfer-race] Same atomic replacement as the
                // move path — the old animated-pop-then-delayed-push had the
                // same swallowed-push failure mode here.
                guard currentStackSessionId != sessionId else { return }
                switchToSession(sessionId)
            }
        }
        .fullScreenCover(isPresented: $showTerminal) {
            NavigationStack {
                ISHTerminalView(showCloseButton: true)
            }
        }
        // [T-crash-breadcrumbs] Toolbar sheets and the terminal cover: which
        // one is up (an enum name), and when it goes away.
        .onChange(of: activeToolSheet) { sheet in
            CrashBreadcrumbs.record(sheet == nil ? "sheet.hide" : "sheet.show", detail: sheet?.rawValue ?? "")
            CrashBreadcrumbs.setSlot("sheet", value: sheet?.rawValue ?? "none")
        }
        .onChange(of: showTerminal) { shown in
            CrashBreadcrumbs.record(shown ? "sheet.show" : "sheet.hide", detail: "terminal")
            CrashBreadcrumbs.setSlot("sheet", value: shown ? "terminal" : "none")
        }
        .sheet(isPresented: $showAlarmList, onDismiss: { fetchAlarmsIfNeeded() }) {
            AlarmListView()
        }
        .sheet(item: $activeToolSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(showTerminal: $showTerminal)
            case .rootfsManagement:
                NavigationStack {
                    RootfsManagementView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { activeToolSheet = nil }
                            }
                        }
                }
            case .browser:
                BrowserSheetView(pool: browserPool)
            case .browserManagement:
                NavigationStack {
                    BrowserManagementView(pool: browserPool)
                }
            case .syncMigrationDetail:
                NavigationStack {
                    SyncMigrationDetailView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { activeToolSheet = nil }
                            }
                        }
                }
            }
        }
        // Something else is taking over the screen (an incoming share, a
        // WebApp deep link, a `.minisbak` opened from Files). iOS will not
        // present a second sheet from the same root while one is up, so a tool
        // sheet left open here silently swallows the new presentation — which
        // is exactly how opening a backup while sitting in Settings did
        // nothing at all. Clearing it lets the incoming content surface.
        .onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            if activeToolSheet != nil { activeToolSheet = nil }
        }
        .sheet(item: $sessionToDelete) { session in
            DeleteConfirmSheet(info: $singleDeleteInfo, isLoading: false) {
                print("[DELETE] onDelete called for session: \(session.id)")
                deleteSession(session)
                sessionToDelete = nil
                singleDeleteInfo = nil
            }
            .onAppear {
                print("[DELETE] Sheet appeared. singleDeleteInfo is \(singleDeleteInfo == nil ? "nil" : "non-nil, sessionCount=\(singleDeleteInfo!.sessionCount)")")
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $sessionToEdit) { session in
            SessionEditSheet(session: session) { newTitle, newCategory in
                // [T-ios-state-publish-offmain-crash] @MainActor so the @State
                // write after the actor-hop await stays on the main thread.
                Task { @MainActor in
                    await ChatStore.shared.updateSessionTitle(session.id, title: newTitle, category: newCategory)
                    refreshSessionList()
                }
                sessionToEdit = nil
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showDeleteConfirm, onDismiss: {
            if deleteInfo == nil {
                // Deletion was performed — reset selection mode after sheet is fully dismissed
                isSelecting = false
                selectedIds.removeAll()
            } else {
                // Cancelled — a pending delete-folder-with-sessions must not
                // linger and attach itself to a later unrelated delete.
                pendingDeleteFolderId = nil
            }
        }) {
            DeleteConfirmSheet(info: $deleteInfo, isLoading: isComputingDelete) {
                deleteSelectedSessions()
                showDeleteConfirm = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showExportPreview) {
            ExportPreviewSheet(fileURL: exportFileURL, previewURL: exportPreviewURL, summary: exportSummary)
        }
        .sheet(item: $folderPickerRequest, onDismiss: {
            // Mirror the delete sheet's pattern (see the comment near
            // computeDeleteInfo): selection state is reset only after the
            // sheet is fully dismissed to avoid animation conflicts.
            if folderMoveApplied {
                folderMoveApplied = false
                isSelecting = false
                selectedIds.removeAll()
            }
        }) { req in
            FolderPickerSheet(
                items: folderPickerItems(),
                sessionIds: Array(req.sessionIds),
                anyFiled: req.anyFiled
            ) { choice in
                Task { @MainActor in
                    switch choice {
                    case .existing(let folderId):
                        await ChatStore.shared.setFolder(folderId, forSessions: Array(req.sessionIds))
                    case .create(let name, let desc):
                        let folder = await ChatStore.shared.createFolder(name: name, desc: desc)
                        await ChatStore.shared.setFolder(folder.id, forSessions: Array(req.sessionIds))
                    case .removeFromFolder:
                        await ChatStore.shared.setFolder(nil, forSessions: Array(req.sessionIds))
                    }
                    refreshSessionList()
                }
                if req.fromMultiSelect { folderMoveApplied = true }
                folderPickerRequest = nil
            }
            .presentationDetents([.medium, .large])
        }
        .modifier(FolderAlertsModifier(
            folderToRename: $folderToRename,
            renameFolderText: $renameFolderText,
            renameFolderDesc: $renameFolderDesc,
            folderToDissolve: $folderToDissolve,
            allFolders: folders,
            memberCount: { fid in sessions.filter { $0.folderId == fid }.count },
            onRename: { folder, name, desc in
                Task { @MainActor in
                    // Always pass desc (empty clears): the dialog is seeded with
                    // the stored value when it opens ([T-folder-rename-desc-wipe]),
                    // so whatever is in the field on Rename is the user's
                    // intended state.
                    await ChatStore.shared.renameFolder(folder.id, name: name, desc: desc)
                    refreshSessionList()
                }
            },
            onDissolve: { folder in
                Task { @MainActor in
                    _ = await ChatStore.shared.dissolveFolder(folder.id)
                    refreshSessionList()
                }
            },
            // [T-folder-duplicate-name] Merge the renamed group into the
            // existing same-named one: move its chats over, then dissolve the
            // now-empty source. Dissolve (not delete) is deliberate — it only
            // ever ungroups, so a mistake here can never cost a session.
            onMergeInto: { source, target in
                Task { @MainActor in
                    let memberIds = sessions.filter { $0.folderId == source.id }.map(\.id)
                    if !memberIds.isEmpty {
                        await ChatStore.shared.setFolder(target.id, forSessions: memberIds)
                    }
                    _ = await ChatStore.shared.dissolveFolder(source.id)
                    refreshSessionList()
                }
            }
        ))
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        // [T-ios-hud-spinner-contrast] Tint the spinner with the
                        // adaptive label colour (GH#333).
                        //
                        // The card behind it is `.ultraThinMaterial`, which is
                        // LIGHT in light mode. An untinted ProgressView takes
                        // the ambient tint rather than the label colour, and
                        // over a pale material that lands close to the
                        // background — the reported "can't tell whether it is
                        // loading". `UIColor.label` is dark on light and light
                        // on dark, so this fixes light mode without touching
                        // how dark mode looks today.
                        ProgressView()
                            .controlSize(.large)
                            .tint(ChatColors.primaryText)
                        if let p = exportProgress, p.total > 0 {
                            Text(AppLocalized("Exporting… \(p.done) / \(p.total)"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(AppLocalized("Exporting…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: isExporting)
            }
        }
        .task {
            // [T-p1-delegate-task] Hidden child sessions never reach the
            // sidebar; they are entered from their parent's helper block.
            sessions = await ChatStore.shared.listSessions().filter { !$0.isChild }
            // [T-ios-moveto-seed] Hand the sidebar's freshly-loaded list to the
            // Move-to sheet's seed, so opening the picker paints populated
            // instead of waiting on the ChatStore actor.
            ViewModelCache.noteSessionsLoaded(sessions)
            // Folders must load WITH the first session batch: groupedSessionIDs
            // treats a folder_id whose folder isn't loaded as an orphan and
            // renders the session ungrouped, so a first paint with sessions
            // but no folders shows a flat list and the folder cards only
            // "appear after a while" (whenever refreshSessionList next ran —
            // the exact symptom reported from the Mac build).
            folders = await ChatStore.shared.listFolders()
            let shareAlreadyHandled = shareCoordinator.bufferVersion > 0
            // A Home Screen Quick Action that fired during launch will
            // open the right session itself via `quickActionRouter.newChatTrigger`.
            // Skip the Launch Session logic so we don't open a second,
            // conflicting session (the "last session" / "new chat"
            // launchScreen branch races the shortcut and the user ends
            // up watching one view replaced by the other).
            // Two signals indicate a quick-action launch is in flight:
            //   1. Router bumped newChatTrigger but ContentView hasn't
            //      consumed it yet (race: .task runs before .onAppear).
            //   2. QuickActionWorkflow is past .idle — router already
            //      called start(), workflow owns the next session to
            //      open. Even if (1) flipped because .onAppear already
            //      ran and consumed the trigger, the workflow is still
            //      mid-flight and the launch session would clobber it.
            let workflowActive: Bool = {
                if case .idle = QuickActionWorkflow.shared.state { return false }
                return true
            }()
            let quickActionPending = quickActionRouter.newChatTrigger != consumedQuickActionTrigger || workflowActive
            shareLog.info("[Share] .task: hasPendingShare=\(shareCoordinator.hasPendingShare) launchScreen=\(launchScreen) sessions=\(sessions.count) bufferVersion=\(shareCoordinator.bufferVersion) shareAlreadyHandled=\(shareAlreadyHandled) quickActionPending=\(quickActionPending) workflowActive=\(workflowActive)")

            // [T-notification-tap-vs-launch-session] A notification tap's
            // explicit target session outranks every launch-screen default.
            // Cold launch: didReceive fired before our .onReceive subscriber
            // existed, so the post was lost — the buffered copy is the only
            // surviving signal. Consume it and navigate. Warm-ish overlap: the
            // post arrived while this .task was awaiting listSessions() and
            // .onReceive already navigated — handledRecently suppresses the
            // launch-screen default so it can't clobber that navigation.
            if let notificationTarget = NotificationNavigationStore.shared.takePending() {
                shareLog.info("[Share] .task: notification tap target=\(notificationTarget.prefix(8)) — overriding launchScreen logic")
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { openSession(notificationTarget) }
            } else if NotificationNavigationStore.shared.handledRecently {
                shareLog.info("[Share] .task: notification navigation just handled — skipping launchScreen logic")
            } else if quickActionPending {
                shareLog.info("[Share] .task: quick action pending — deferring launchScreen logic to QuickActionRouter")
            } else if shareAlreadyHandled {
                // onChange(hasPendingShare) already processed the share and
                // opened a new session before .task ran. Skip normal launch
                // screen logic so we don't clobber it with a different session.
                shareLog.info("[Share] .task: share already handled by onChange — skipping launchScreen logic")
            } else if shareCoordinator.hasPendingShare {
                // onChange hasn't fired yet (e.g. onOpenURL arrived during await).
                // Process share here and open a new session for it.
                shareLog.info("[Share] .task: processing pending share")
                processPendingShare()
                shareLog.info("[Share] .task: buffer stored, bufferVersion=\(shareCoordinator.bufferVersion) buffer=\(shareCoordinator.pendingShareBuffer != nil)")
                // [T-share-routes-to-background-session] Cold launch: nothing is
                // on screen yet (this branch runs before any launch-screen
                // navigation), so the "foreground session" the warm path looks
                // for does not exist and a new session IS the right
                // destination. It is still stamped onto the buffer, which is
                // what stops a session restored moments later — e.g. the
                // Launch-Session default, or a chat resuming an agent loop —
                // from mounting first and swallowing the share.
                let target = Self.makeNewSessionId()
                shareCoordinator.setBufferTarget(target)
                shareLog.info("[Share] .task: cold launch — opening new session \(target.prefix(16)) for share")
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { openSession(target) }
            } else if CrashReporter.shared.shouldBypassSessionRestore {
                // [T-ios-session-crash-loop] The last two launches both died in
                // the foreground within a minute of each other — the signature
                // of a session that faults while loading and is then re-opened
                // automatically on the next launch, which the user cannot
                // escape from inside the app (they can reach neither Settings
                // to change the launch screen nor the list to delete it).
                //
                // Open nothing: fall through to the session list so the app is
                // usable again. Deliberately placed AFTER the notification-tap
                // and share branches — those are explicit, just-expressed user
                // intent, and a stale crash flag must not swallow them.
                CrashReporter.shared.clearCrashLoopFlag()
                shareLog.warning("[Share] .task: crash-loop detected — skipping session restore, landing on the session list")
            } else {
                // No share — normal launch screen behavior
                switch launchScreen {
                case 1:
                    if let latest = sessions.first {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openSession(latest.id) }
                    }
                case 2:
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) { openSession(Self.makeNewSessionId()) }
                case 3:
                    break
                default:
                    if !sessions.isEmpty,
                       let latest = sessions.first,
                       Date().timeIntervalSince(latest.updatedAt) > 15 * 60 {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openSession(Self.makeNewSessionId()) }
                    } else if isWideLayout, let latest = sessions.first {
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openSession(latest.id) }
                    }
                }
            }
            // iPad split launch: every launchScreen branch above has resolved
            // by now, so if the restored selection lives inside a collapsed
            // folder, expand that folder (accordion — closes the others) so
            // the selected row is actually visible in the sidebar instead of
            // hidden behind a collapsed card.
            if isWideLayout, let sid = selectedSessionId,
               let fid = sessions.first(where: { $0.id == sid })?.folderId,
               collapsedFolderIds.contains(fid) {
                toggleFolderCollapsed(fid)
            }
            didInitialLoad = true
            fetchAlarmsIfNeeded()
            await refreshRemoteDeviceSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidFetchChanges)) { _ in
            // [T-ios-state-publish-offmain-crash] cloud-sync fetch fires off-main;
            // force the @State write onto the main thread.
            Task { @MainActor in
                refreshSessionList()
            }
        }
        // [T-ios-session-list-equatable-jank] Keep the id→session lookup cache
        // in sync with `sessions`. Rebuilding here (on actual list mutation)
        // instead of per body-eval is what removes the per-frame Dictionary.==
        // / ChatSession.== diff from the scroll transaction.
        .onChange(of: sessions) { _ in
            rebuildSessionsByIdCache()
        }
        .onChange(of: selectedSessionId) { newValue in
            // [T-home-list-perf-diag] iPad / wide navigation marker.
            if isWideLayout { HomeListPerf.nav("selection \(newValue == nil ? "home" : "chat")") }
            // [T-crash-breadcrumbs] Split-layout selection, hashed.
            CrashBreadcrumbs.record("nav.select", detail: newValue.map { CrashBreadcrumbs.hash8($0) } ?? "none")
            // [T-ios-session-switch-attributegraph-race] Hosting-view race
            // mitigation: when the user switches between two sessions while
            // both vms are mid-stream, the outgoing AIChatView's UIHostingView
            // subgraph is being torn down at the same instant the new
            // session's hosting views are mounting. A concurrent mutation on
            // the outgoing vm (any @Published delta, scroll signal, etc.)
            // races with `AG::Subgraph::NodeCache::~NodeCache` on the same
            // AsyncRenderer thread → EXC_BAD_ACCESS (build-48 crash
            // Minis-2026-06-01-134710.ips). Suspend the outgoing vm here,
            // then schedule a resume on a short delay so when the user comes
            // back to that session everything catches up. Run before the
            // redirect/tracking-clear logic so we always pin the right id.
            // [T-ios-session-coldload-listsessions-block] Were we leaving a real
            // (persisted, non-new) session? Only then can its list-row preview
            // have drifted and need a navigation-time refresh. Captured before
            // previousSelectedSessionId is overwritten below.
            let hadOutgoingRealSession: Bool = {
                guard let outgoing = previousSelectedSessionId, outgoing != newValue else { return false }
                return !Self.isNewSessionId(outgoing)
            }()
            if let outgoingId = previousSelectedSessionId, outgoingId != newValue {
                if let outgoingVm = ViewModelCache.shared.get(for: outgoingId) {
                    outgoingVm.setSuspendedForTransition(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak outgoingVm] in
                        outgoingVm?.setSuspendedForTransition(false)
                    }
                }
            }
            previousSelectedSessionId = newValue
            if let sid = newValue {
                SessionBadgeStore.shared.remove(.unread, for: sid)
                AIChatViewModel.activeSessionId = sid
            } else {
                AIChatViewModel.activeSessionId = nil
            }
            // [T-always-on-now] Leaving a chat ends its "Use Screen Saver"
            // choice. Its "Keep Screen On" choice is kept
            // ([T-keep-awake-sticky-off]).
            AlwaysOnController.shared.chatSelectionChanged(to: newValue)
            draftLog.info("🔑DRAFT onChange(selectedSessionId) newValue=\(newValue ?? "nil") realId=\(newSessionRealId ?? "nil") draftId=\(activeDraftId ?? "nil")")
            // If user taps the real session row that was created from a draft,
            // redirect back to the draft ID to preserve the AIChatView instance.
            if let realId = newSessionRealId, newValue == realId,
               let draftId = activeDraftId {
                draftLog.info("🔑DRAFT onChange REDIRECT to draftId=\(draftId)")
                selectedSessionId = draftId
                return
            }
            // Clear new-session tracking when navigating to a different session
            if !Self.isNewSessionId(newValue) {
                draftLog.info("🔑DRAFT onChange CLEAR tracking (non-draft)")
                newSessionRealId = nil
                activeDraftId = nil
            }
            // iPad: detail cleared (newValue == nil) — if a quick-action
            // workflow is ensuring-home, advance it now.
            if newValue == nil, case .ensuringHome = QuickActionWorkflow.shared.state {
                QuickActionWorkflow.shared.markHome()
            }
            // [T-ios-search-focus-sticky] iPad split: selecting a session (or
            // new chat) with an empty search drops the sticky search bar.
            if newValue != nil {
                dismissSearchIfEmptyOnNavigate()
            }
            // [T-ios-session-coldload-listsessions-block] Only refresh the list
            // when LEAVING a real session — that outgoing session's preview may
            // have changed while the user was inside it. Entering never changes
            // existing rows. Even so, this listSessions() is a ~1.4s full scan
            // on a large DB and, on the serialized ChatStore actor, is
            // non-preemptible — if it starts before the incoming session's
            // loadSession() reaches its 2nd actor hop (getMemoryEnabled →
            // loadMessages), that hop waits the whole scan out and the spinner
            // hangs ~1.5s. So DELAY the outgoing-preview refresh well past the
            // incoming load (which completes in ~50-150ms) instead of racing it
            // onto the actor. Content changes are already covered by
            // .sessionDidUpdate / .sessionDidCreate / .cloudSyncDidFetchChanges
            // / pin / delete / edit, so this delayed refresh is belt-and-braces.
            if hadOutgoingRealSession {
                scheduleOutgoingPreviewRefresh()
            }
        }
        .onChange(of: navigationPath) { _ in
            // [T-crash-breadcrumbs] Navigation depth; back at the root the
            // current page is the home list (a chat page records its own).
            CrashBreadcrumbs.record("nav", detail: "depth=\(navigationPath.count)")
            // [T-home-list-perf-diag] iPhone push / pop marker.
            HomeListPerf.nav("depth=\(navigationPath.count)")
            // [T-nav-stack-diag] Every change, with the running sessions and
            // whether the app itself wrote this path (see NavDiag).
            NavDiag.observe(navigationPath, currentTarget: currentStackSessionId)
            // [T-nav-ghost-row-link] A stack deeper than one chat is unusual on
            // iPhone (only the launch / share / notification paths append), so
            // name every page: a ghost page under a new chat shows up here.
            if navigationPath.count > 1 {
                let ids = navigationPath.codable
                    .flatMap { try? JSONEncoder().encode($0) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "?"
                shareLog.warning("[NavStack] depth=\(navigationPath.count) top=\(currentStackSessionId ?? "nil") path=\(ids)")
            }
            if navigationPath.isEmpty { CrashBreadcrumbs.setSlot("page", value: "home") }
            // [T-ios-stacknav-transition-attributegraph-race] The SAME hosting-
            // view teardown race the `selectedSessionId` observer above guards
            // — but that observer only fires in the SPLIT (iPad / wide) layout.
            // iPhone drives navigation through `navigationPath`, so the
            // outgoing chat's vm was NEVER suspended for a push/pop, and the
            // mitigation added for the 2026-06-01 build-48 crash simply did not
            // exist on the compact path.
            //
            // Crash 2026-08-10 19:23 (Minis 1.12(1), iOS 26.5.2, iPhone18,1 —
            // a STACK-layout device): EXC_BAD_ACCESS at 0xffffffff00000000 in
            // AG::Subgraph::~Subgraph → NodeCache::~NodeCache, reached from
            // `NavigationStackCoordinator.navigationController(_:willShow:)` →
            // `ejectDeferred/sanitize` → `replaceRootViewWhenSafe` → a
            // synchronous `ViewGraph.updateOutputs` inside the UIKit
            // transition-completion callback. The device log shows exactly the
            // documented precondition: the agent loop kept streaming straight
            // through the transition and PAST the view's teardown —
            //
            //   19:23:26.731  chat slides offscreen (x=402…804, transition starts)
            //   19:23:26.735  [TOOL:STREAMING] shell_execute …
            //   19:23:27.138  [TOOL:STREAMING] …
            //   19:23:27.213  AIChatView.onDisappear vm.isProcessing=true
            //   19:23:27.349  [TOOL:STREAMING] …   (still mutating after teardown)
            //
            // so @Published deltas were feeding a subgraph while UIKit was
            // invalidating it. Suspend the outgoing vm for the transition,
            // exactly as the split path does, and resume on the same 0.4s
            // delay so the session catches up when the user returns.
            //
            // The outgoing id is tracked separately (`previousStackSessionId`)
            // rather than read from `currentStackSessionId` — see that
            // property's doc-comment for why the latter is already the INCOMING
            // id by the time this observer runs.
            // The incoming id is `currentStackSessionId` only while the path is
            // NON-empty; a pop to the session list leaves it momentarily stale
            // (it is cleared further down in this same handler), so an empty
            // path means "incoming = nothing" and the outgoing vm must still be
            // suspended. Getting this wrong would skip the pop — which is the
            // exact transition the crash log captured.
            let incomingStackId: String? = navigationPath.isEmpty ? nil : currentStackSessionId
            let outgoingStackId = previousStackSessionId
            previousStackSessionId = incomingStackId
            if let outgoingId = outgoingStackId,
               outgoingId != incomingStackId,
               let outgoingVm = ViewModelCache.shared.get(for: outgoingId) {
                outgoingVm.setSuspendedForTransition(true)
                // Unconditional resume on the same 0.4s delay the split path
                // uses. `weak` so a deallocated vm simply drops it, and
                // `setSuspendedForTransition` is guarded on an actual change,
                // so overlapping transitions cannot leave the flag stuck.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak outgoingVm] in
                    outgoingVm?.setSuspendedForTransition(false)
                }
            }
            // [T-ios-search-focus-sticky] iPhone stack: pushing into a session
            // (or new chat) with an empty search drops the sticky search bar.
            // Only on push (path non-empty) — popping back must NOT clear an
            // active search the user is returning to.
            if !navigationPath.isEmpty {
                dismissSearchIfEmptyOnNavigate()
            }
            if navigationPath.isEmpty {
                currentStackSessionId = nil
                AIChatViewModel.activeSessionId = nil
                // [T-always-on-now] Back on the list: Screen Saver Now ends; the
                // per-chat choices are kept ([T-keep-awake-sticky-off]).
                AlwaysOnController.shared.chatSelectionChanged(to: nil)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                // If a quick-action workflow asked us to ensure-home,
                // we're there now — let it advance to pendingDispatch.
                if case .ensuringHome = QuickActionWorkflow.shared.state {
                    QuickActionWorkflow.shared.markHome()
                }
            }
            // [T-ios-session-coldload-listsessions-block] Only refresh when
            // popping back to home (path emptied) — that's when a preview that
            // changed inside the session the user just left needs to show. On
            // PUSH (entering a session, the cold-open hot path) this scan only
            // head-of-line-blocked loadSession on the ChatStore actor. Delayed
            // so it never races the incoming load's actor hops.
            if navigationPath.isEmpty {
                scheduleOutgoingPreviewRefresh()
            }
            fetchAlarmsIfNeeded()
        }
        .onChange(of: shareCoordinator.hasPendingShare) { hasPending in
            if hasPending {
                let hadRecord = SharedContainerStore.loadPendingShare() != nil
                processPendingShare()
                // [T-share-double-raise] Only navigate when this raise actually
                // carried content. A duplicate raise finds the record already
                // consumed; opening a second blank session for it would replace
                // the one the first pass just populated.
                //
                // [T-share-routes-to-background-session] Route to the chat the
                // user is LOOKING AT, and only open a new session when there
                // isn't one.
                //
                // The bug this fixes was never "a share reached an open chat" —
                // it was a share reaching a chat the user was NOT looking at.
                // Device log 2026-08-18 23:55:42: the file landed in session
                // 87B79110, mid-agent-run in the BACKGROUND, purely because
                // that view happened to be mounted; nothing checked whether the
                // share was meant for it.
                //
                // So the destination is decided here, explicitly, and stamped
                // onto the buffer — a foreground chat when there is one, a
                // fresh session otherwise — and only that destination's view is
                // allowed to consume it (see injectPendingShareIfNeeded).
                // `navigationPath.isEmpty ? nil : currentStackSessionId` is the
                // same "what is actually on screen" test the outgoing-session
                // tracker at line ~1879 uses.
                if hadRecord {
                    let foreground: String? = navigationPath.isEmpty ? nil : currentStackSessionId
                    if let foreground {
                        // Already on screen — stamp it and navigate nowhere.
                        shareCoordinator.setBufferTarget(foreground)
                        shareLog.info("[Share] onChange: routing share into the foreground session \(foreground.prefix(16)) (no navigation needed)")
                    } else {
                        let target = Self.makeNewSessionId()
                        shareCoordinator.setBufferTarget(target)
                        shareLog.info("[Share] onChange: no session on screen — opening new session \(target.prefix(16)) for share")
                        var tx = Transaction()
                        tx.disablesAnimations = true
                        withTransaction(tx) { openSession(target) }
                    }
                }
            }
        }
        .onChange(of: deepLink.showEnvironmentVariables) { show in
            if show {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.showPermissions) { show in
            if show {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.showAlarmList) { show in
            if show {
                showAlarmList = true
                deepLink.showAlarmList = false
            }
        }
        // Open the SettingsSheet whenever a deep link sets a settings
        // target. SettingsSheet itself reads `deepLink.pendingSettingsTarget`
        // in onAppear/onChange to push the right destination, then clears it.
        .onChange(of: deepLink.pendingSettingsTarget) { target in
            guard target != nil else { return }
            if activeToolSheet != .settings {
                activeToolSheet = .settings
            }
        }
        .onChange(of: deepLink.pendingRootfsManagement) { pending in
            if pending {
                activeToolSheet = .rootfsManagement
                deepLink.pendingRootfsManagement = false
            }
        }
        .onChange(of: deepLink.pendingSessionId) { sid in
            guard let sid, !sid.isEmpty else { return }
            // Switch to the requested session if it exists in the loaded
            // list. If not loaded yet (cold launch with deep link), set
            // it now — the session-load path will pick it up once the
            // list refresh completes.
            selectedSessionId = sid
            deepLink.pendingSessionId = nil
        }
        .onChange(of: scenePhase) { phase in
            // [T-ios-scenephase-active-sigkill] Defer ALL .active work off the
            // synchronous callback. Writing @Published (SyncCore.isAppInBackground)
            // here triggers objectWillChange → SwiftUI view invalidation in the
            // same runloop tick as the foreground view-graph re-evaluation → SIGTRAP.
            if phase == .active {
                Task { @MainActor in
                    await Task.yield()
                    // Guard against rapid bg→fg→bg: if scenePhase already
                    // changed back, skip the stale .active work.
                    guard scenePhase == .active else { return }
                    // [T-ios-bg-nav-push-watchdog] Commit any push that arrived
                    // while backgrounded. Runs here — after the `Task.yield()`
                    // that keeps .active work off the synchronous callback — so
                    // the pushed screen's first layout pass lands on its own
                    // runloop turn with a full frame budget, never inside the
                    // foreground-transition tick.
                    flushPendingBackgroundNavigation()
                    fetchAlarmsIfNeeded()
                    if #available(iOS 17.0, *) {
                        SyncCore.shared.isAppInBackground = false
                        // [T-icloud-migration-keeps-going] A migration that
                        // suspended (no progress for a window, or left
                        // suspended by an older build) picks up again on
                        // foreground instead of waiting for a cold launch.
                        // No-op unless suspended and idle.
                        Task { await MigrationEngine.shared.resumeIfSuspended(trigger: "foreground") }
                    }
                    #if DEBUG
                    IdleTimerLease.set(.debugMenu, held: keepScreenAwake, reason: "active")
                    #endif
                    // [T-home-fab-keyboard-inset] Defense-in-depth behind the
                    // structural .ignoresSafeArea immunity on the session lists:
                    // on foreground return with the HOME screen actually showing
                    // (no pushed chat on compact, no selected session on split —
                    // a split chat column may legitimately hold composer focus)
                    // and the inline search bar not focused, no responder is
                    // legitimate. Resign whatever UIKit resurrected during the
                    // background snapshot pass so its stale keyboard inset can't
                    // inflate the window's bottom safe area.
                    if !searchFocused, navigationPath.isEmpty, selectedSessionId == nil {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil)
                    }
                }
            } else {
                if #available(iOS 17.0, *) {
                    SyncCore.shared.isAppInBackground = (phase != .active)
                }
            }
        }
    }

    // MARK: Stored state used by the extension files
    //
    // Swift extensions cannot declare stored properties, so the state the
    // ContentView+*.swift files need is declared here, in the order it had
    // when ContentView was a single file.

    // Used by ContentView+RemoteSessions.swift.
    let syncLog = AppLogger(category: "RemoteSync")

    // Used by ContentView+EmptyState.swift.
    @StateObject var providerStore = ProviderConfigStore.shared
    @State var showAddProvider = false
    @State var showSelectModels = false
    @State var showRestoreBackup = false

    // Used by ContentView+FAB.swift (and the search field focus).
    @State var fabDidDrag = false
    @FocusState var searchFocused: Bool

    @State var searchDragOffset: CGFloat = 0
    @State var searchDidDrag = false

    /// Namespace tying the search FAB and the expanded search bar together as one
    /// glass fragment, so the two morph instead of cross-fading (iOS 26+).
    @Namespace var fabGlassNamespace
}
