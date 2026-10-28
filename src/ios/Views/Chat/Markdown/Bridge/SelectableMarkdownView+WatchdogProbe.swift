//
//  SelectableMarkdownView+WatchdogProbe.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Bridge - SelectableMarkdownView, DEBUG-only watchdog probe.
//
//  Adds up the main-thread time spent in sizeThatFits / updateUIView within one
//  run-loop iteration and logs an alarm past 2 s - early warning before the
//  system watchdog kills the app. Compiled out of Release.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

extension SelectableMarkdownView {
    #if DEBUG
    // MARK: WatchdogProbe — runloop-window cumulative tracking

    /// Tracks how much wall-clock time TextKit measurement has consumed on
    /// the main thread within a *single runloop iteration*. FRONTBOARD's
    /// 0x8BADF00D watchdog measures elapsed real time per scene-update
    /// cycle; when a single iteration burns >2s of STF/updateUIView, we are
    /// already a quarter of the way to termination. Reset by an idle observer
    /// installed lazily on the main runloop.
    private static var stfWindowTotalMs: Double = 0
    private static var stfWindowCallCount: Int = 0
    private static var updWindowTotalMs: Double = 0
    private static var updWindowCallCount: Int = 0
    private static var distinctMsgIds: Set<UUID> = []
    private static var observerInstalled = false
    private static let windowAlarmThresholdMs: Double = 2000
    private static var alarmAlreadyFiredThisHop = false

    static func recordSTF(elapsedMs: Double, msgId: UUID?, attrLen: Int) {
        installWindowObserverIfNeeded()
        stfWindowTotalMs += elapsedMs
        stfWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "stf", lastLen: attrLen, lastMsgId: msgId)
    }

    static func recordUpdateUIView(elapsedMs: Double, attrLen: Int, msgId: UUID?) {
        installWindowObserverIfNeeded()
        updWindowTotalMs += elapsedMs
        updWindowCallCount += 1
        if let msgId { distinctMsgIds.insert(msgId) }
        checkWindowAlarm(trigger: "upd", lastLen: attrLen, lastMsgId: msgId)
    }

    private static func checkWindowAlarm(trigger: String, lastLen: Int, lastMsgId: UUID?) {
        let total = stfWindowTotalMs + updWindowTotalMs
        guard total >= windowAlarmThresholdMs, !alarmAlreadyFiredThisHop else { return }
        alarmAlreadyFiredThisHop = true
        let msgIdShort = lastMsgId?.uuidString.prefix(8) ?? "—"
        watchdogProbe.warning("[WatchdogProbe][window] 🚨 cumulative=\(String(format: "%.0f", total))ms (stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs))) sttCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count) trigger=\(trigger) lastMsgId=\(msgIdShort) lastLen=\(lastLen) — main runloop is heading toward 0x8BADF00D (10s watchdog)")
    }

    private static func installWindowObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        // beforeWaiting fires once the runloop is about to sleep — natural
        // boundary for "this hop is done". We reset and, if the hop was
        // expensive, emit a summary so the log captures it even if no alarm
        // fired (cumulative under 2s but still notable).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { _, _ in
            let total = stfWindowTotalMs + updWindowTotalMs
            if total >= 500 {
                watchdogProbe.info("[WatchdogProbe][hop] cumulative=\(String(format: "%.0f", total))ms stf=\(String(format: "%.0f", stfWindowTotalMs)) upd=\(String(format: "%.0f", updWindowTotalMs)) stfCalls=\(stfWindowCallCount) updCalls=\(updWindowCallCount) distinctMsgs=\(distinctMsgIds.count)")
            }
            stfWindowTotalMs = 0
            stfWindowCallCount = 0
            updWindowTotalMs = 0
            updWindowCallCount = 0
            distinctMsgIds.removeAll(keepingCapacity: true)
            alarmAlreadyFiredThisHop = false
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }
    #endif
}
