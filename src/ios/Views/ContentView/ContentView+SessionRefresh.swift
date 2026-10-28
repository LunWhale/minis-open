//
//  ContentView+SessionRefresh.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, session list refresh: reloading sessions and folders from
//  ChatStore, coalesced and rate-limited, plus the deferred refresh after
//  leaving a chat (kept off the incoming chat's load).
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    /// [T-ios-session-coldload-listsessions-block] Refresh the session list to
    /// pick up any preview change in the session the user just left, but only
    /// AFTER the incoming session's loadSession() has claimed and released the
    /// ChatStore actor for its DB reads. Firing listSessions() synchronously on
    /// navigation raced it onto the (non-preemptible, serialized) actor and hung
    /// the incoming spinner ~1.5s. A 0.6s debounce clears the incoming load
    /// (~50-150ms) with margin and coalesces bursts of session switching into a
    /// single trailing scan.
    func scheduleOutgoingPreviewRefresh() {
        outgoingPreviewRefreshWork?.cancel()
        let work = DispatchWorkItem {
            refreshSessionList()
        }
        outgoingPreviewRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// [T-ios-listsessions-refresh-coalesce] Single serialized entry point for
    /// refreshing `sessions` from the store. If a refresh is already running,
    /// mark one trailing run pending instead of spawning a concurrent Task —
    /// collapsing bursts (navigation + sync + streaming ticks) into at most one
    /// in-flight + one queued run. The ChatStore cache makes a clean run cheap.
    @MainActor
    func refreshSessionList() {
        // [T-scroll-sync-defer] Publishing a new `sessions` re-diffs the whole
        // home list (50-90 ms with ~2000 rows) even while a chat sits on top of
        // it; never start one under a fling. Every trigger funnels through here.
        if ChatScrollActivity.isMoving {
            ChatScrollActivity.runWhenStill("home.refreshSessionList") { refreshSessionList() }
            return
        }
        guard !sessionRefreshInFlight else {
            sessionRefreshPending = true
            return
        }

        // [T-ios-listsessions-perf] Cooldown measured from the END of the last
        // run. A refresh took 4-9 s in the profiled trace, so the 1 s throttle
        // on the notification publisher never actually gated anything: the run
        // outlasted its own throttle window, the pending flag re-queued the
        // moment it finished, and the result was 63 back-to-back rebuilds with
        // a median idle gap of 2.8 s. Deferring to `finishedAt + cooldown`
        // instead puts a real floor under the duty cycle.
        let now = Date()
        switch SessionRefreshScheduler.decide(now: now, lastFinishedAt: lastRefreshFinishedAt) {
        case .runNow:
            break
        case .defer(let delay):
            // Coalesce: one deadline; a trigger arriving while one is pending
            // rides on it rather than pushing it out. The `.task(id:)` on the
            // body fires it.
            guard sessionRefreshCooldownDeadline == nil else { return }
            sessionRefreshCooldownDeadline = Date().addingTimeInterval(delay)
            return
        }

        sessionRefreshInFlight = true
        Task(priority: .utility) { @MainActor in
            // [T-p1-delegate-task] Hidden child sessions never reach the
            // sidebar; they are entered from their parent's helper block.
            sessions = await ChatStore.shared.listSessions().filter { !$0.isChild }
            // [T-ios-moveto-seed] Keep the picker's seed current: this refresh
            // runs on every list-affecting change, so the snapshot tracks the
            // sidebar rather than going stale after the first load.
            ViewModelCache.noteSessionsLoaded(sessions)
            folders = await ChatStore.shared.listFolders()
            sessionRefreshInFlight = false
            lastRefreshFinishedAt = Date()
            if sessionRefreshPending {
                sessionRefreshPending = false
                // Goes back through the scheduler, so a trailing run also
                // waits out the cooldown instead of starting immediately.
                refreshSessionList()
            }
        }
    }
}
