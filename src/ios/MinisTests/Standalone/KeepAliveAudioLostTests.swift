#!/usr/bin/env swift
// [T-bka-audio-dead-watchdog] Field kill, 2026-10-09 18:01, build 1.15 (15):
// a sub-agent task running in the background was killed with no dialog.
// A call took the audio (interruption began 18:00:18, route -> Receiver);
// the route-change restart ran during the call; the call ended 18:00:27
// (route -> Speaker) with the engine still reporting "running", then the
// engine stopped and no `.ended` interruption ever came. For 30 s the 5 s
// timer logged silentAudio=false / bgRemaining 27..2 s and did nothing; the
// background-task expiry handler then re-armed on the SETTING ("keep-alive is
// active") with 4 s left, and the app was killed. The same sequence at
// 17:57:56 survived only because the user reopened the app with 18 s left.
//
//   [1] SilentAudioWatchdog / BGTaskExpiryPolicy (BackgroundKeepAliveManager)
//   [2] BackgroundKillClassifier (CrashReporter): the heartbeat names this kill
//   [3] the 10-09 sequence replayed over the shipping decisions
//   [4] source guards: the three watchdog callers, the expiry handler, the
//       continued-task retry on foreground, the heartbeat field
//
// Run: swift KeepAliveAudioLostTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}

let manager = source("Agent/Background/BackgroundKeepAliveManager.swift")
let reporter = source("Diagnostics/CrashReporter.swift")
let bgTask = source("Agent/Chat/AIChatViewModel+BackgroundTask.swift")
guard let policy = between(manager, "// BEGIN SilentAudioWatchdog", "// END SilentAudioWatchdog"),
      let classifier = between(reporter, "// BEGIN BackgroundKillClassifier", "// END BackgroundKillClassifier") else {
    print("❌ SilentAudioWatchdog / BackgroundKillClassifier block not found"); exit(1)
}

let harness = #"""
import Foundation
"""# + policy + classifier + #"""

var fails = 0
func CHECK(_ label: String, _ ok: Bool) { print("  \(ok ? "PASS" : "FAIL") \(label)"); if !ok { fails += 1 } }
typealias W = SilentAudioWatchdog
typealias E = BGTaskExpiryPolicy
typealias C = BackgroundKillClassifier

print("[1] watchdog")
CHECK("playing: nothing to do", W.decide(wantsKeepAlive: true, markedActive: true, engineRunning: true) == .none)
CHECK("marked active but the engine is dead: restart", W.decide(wantsKeepAlive: true, markedActive: true, engineRunning: false) == .restart)
CHECK("wanted but never started: evaluate", W.decide(wantsKeepAlive: true, markedActive: false, engineRunning: false) == .evaluate)
CHECK("not wanted (foreground, idle, reply speech owns the audio): never touched",
      W.decide(wantsKeepAlive: false, markedActive: true, engineRunning: false) == .none
      && W.decide(wantsKeepAlive: false, markedActive: false, engineRunning: false) == .none)

print("[2] background-task expiry")
CHECK("continued task holds the app: end only", E.decide(continuedTaskRunning: true, keepAliveConfigured: true, silentAudioPlaying: false) == .endOnly)
CHECK("audio really playing: re-arm", E.decide(continuedTaskRunning: false, keepAliveConfigured: true, silentAudioPlaying: true) == .rearm)
CHECK("keep-alive ON in Settings but audio dead: suspend, never re-arm",
      E.decide(continuedTaskRunning: false, keepAliveConfigured: true, silentAudioPlaying: false) == .suspend)
CHECK("keep-alive off: suspend (as before)", E.decide(continuedTaskRunning: false, keepAliveConfigured: false, silentAudioPlaying: false) == .suspend)
CHECK("audio playing for reply speech with keep-alive off does not re-arm",
      E.decide(continuedTaskRunning: false, keepAliveConfigured: false, silentAudioPlaying: true) == .suspend)

print("[3] crash classification from the heartbeat")
let last: [String: Any] = ["configured": true, "audioPlaying": false, "continued": false, "bgRemaining": 2,
                           "audioInterruption": "began", "audioInterruptionAgoS": 42]
CHECK("the 10-09 heartbeat is named",
      C.keepAliveLost(last) == "Background time ran out (likely) — keep-alive audio was not playing (interrupted 42 s earlier, e.g. by a call, and not restored); 2 s of background time left at the last heartbeat")
CHECK("no keep-alive configured", C.keepAliveLost(["configured": false, "audioPlaying": false, "continued": false, "bgRemaining": 7])
      == "Background time ran out (likely) — no keep-alive was active; 7 s of background time left at the last heartbeat")
CHECK("unlimited background time is not this kill", C.keepAliveLost(["configured": true, "audioPlaying": false, "continued": false, "bgRemaining": -1]) == nil)
CHECK("audio playing, or a continued task, is not this kill",
      C.keepAliveLost(["configured": true, "audioPlaying": true, "continued": false, "bgRemaining": 3]) == nil
      && C.keepAliveLost(["configured": true, "audioPlaying": false, "continued": true, "bgRemaining": 3]) == nil)
CHECK("plenty of time left is not this kill; an old heartbeat without the field neither",
      C.keepAliveLost(["configured": true, "audioPlaying": false, "continued": false, "bgRemaining": 28]) == nil && C.keepAliveLost(nil) == nil)
CHECK("an interruption that ended is not blamed",
      C.keepAliveLost(["configured": true, "audioPlaying": false, "continued": false, "bgRemaining": 3, "audioInterruption": "ended", "audioInterruptionAgoS": 9])
      == "Background time ran out (likely) — keep-alive audio was not playing; 3 s of background time left at the last heartbeat")
CHECK("heartbeat line", C.heartbeatLine(last) == "audio=not playing, continued task=no, background time=2 s, last audio interruption began 42 s ago")
CHECK("heartbeat line, healthy", C.heartbeatLine(["configured": true, "audioPlaying": true, "continued": false, "bgRemaining": -1]) == "audio=playing, continued task=no, background time=unlimited")

print("[4] 2026-10-09 18:00, replayed")
// (second, markedActive, engineRunning) as the log shows them; the 5 s timer
// ticks at :25 :30 :35 … The old build acted on none of them.
var restartedAt: Int?
var engineRunning = true
for second in stride(from: 25, through: 60, by: 5) {
    if second >= 30 && restartedAt == nil { engineRunning = false }   // call ended :27, engine stopped
    if W.decide(wantsKeepAlive: true, markedActive: true, engineRunning: engineRunning) == .restart, restartedAt == nil {
        restartedAt = second; engineRunning = true
    }
}
CHECK("the first tick after the engine died restarts it (18:00:30, 28 s before the expiry)", restartedAt == 30)
CHECK("with the audio back, the 18:00:58 expiry re-arms", E.decide(continuedTaskRunning: false, keepAliveConfigured: true, silentAudioPlaying: engineRunning) == .rearm)
CHECK("had the restart failed, the expiry suspends instead of dying on a 4 s grant",
      E.decide(continuedTaskRunning: false, keepAliveConfigured: true, silentAudioPlaying: false) == .suspend)
exit(fails == 0 ? 0 : 1)
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bka-audio-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let src = tmp.appendingPathComponent("main.swift"), bin = tmp.appendingPathComponent("h").path
try? harness.write(to: src, atomically: true, encoding: .utf8)
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", src.path, "-o", bin])
check("both blocks compile standalone", cc == 0)
if cc != 0 { print(ccOut) } else {
    let (status, out) = run(bin, [])
    print(out, terminator: "")
    check("decision / classification checks all pass", status == 0 && !out.contains("FAIL "))
}

print("[5] source guards")
check("the 5 s background timer checks the audio before anything else",
      manager.contains("self?.reviveSilentAudioIfDead(source: \"watchdog\")\n                self?.updateLiveActivityIfNeeded(source: \"bgAudioTimer\")"))
check("the engine's own stop signal is observed",
      manager.contains("NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)")
      && manager.contains("engine === self.audioEngine") && manager.contains("self?.reviveSilentAudioIfDead(source: \"engineConfigChange\")"))
check("route change / secondary-audio hint still go through the same check",
      manager.contains("        reviveSilentAudioIfDead(source: source)\n    }"))
let revive = between(manager, "func reviveSilentAudioIfDead(source: String) -> Bool {", "    /// Force-reset silent audio state") ?? ""
check("revive is decided by SilentAudioWatchdog on the engine's real state",
      revive.contains("SilentAudioWatchdog.decide(wantsKeepAlive: wantsKeepAlive, markedActive: silentAudioActive,")
      && revive.contains("engineRunning: audioEngine?.isRunning ?? false)")
      && revive.contains("startSilentAudio(reason: \"\\(source)Reclaim\")"))
check("the expiry handler re-arms on the audio really playing, not on the setting",
      bgTask.contains("let expiryAction = BGTaskExpiryPolicy.decide(")
      && bgTask.contains("silentAudioPlaying: keepAlive.silentAudioIsPlaying)")
      && bgTask.contains("if expiryAction == .rearm {")
      && !bgTask.contains("if BackgroundKeepAliveManager.shared.enhancedBackgroundEffective {\n                logger.info(\"[Background] Finite task expiring"))
check("a lost-audio suspend is logged as such and counted as an interruption",
      bgTask.contains("keep-alive audio is NOT playing (interrupted and not restored) — suspending agent loop instead of re-arming")
      && bgTask.contains("if !keepAlive.enhancedBackgroundEffective || audioLost {"))
check("a continued task skipped in the background is asked for again in the foreground",
      manager.contains("continuedAwaitingForeground = true\n            return")
      && manager.contains("if self?.continuedAwaitingForeground == true {\n                    self?.evaluateContinuedProcessing(caller: \"didBecomeActive\")")
      && !manager.contains("app not in the foreground\")\n            continuedUnavailableThisRun = true"))
check("the heartbeat records the keep-alive state and the report uses it",
      reporter.contains("\"keepAlive\": BackgroundKeepAliveManager.shared.keepAliveHeartbeat,")
      && reporter.contains("BackgroundKillClassifier.keepAliveLost(heartbeat?[\"keepAlive\"] as? [String: Any])")
      && reporter.contains("BackgroundKillClassifier.heartbeatLine(hb[\"keepAlive\"] as? [String: Any])"))
// CPU-limit kills keep their precedence over the new class.
let cpuAt = reporter.range(of: "Background CPU limit kill (possible)")?.lowerBound ?? reporter.endIndex
let lostAt = reporter.range(of: "BackgroundKillClassifier.keepAliveLost(heartbeat")?.lowerBound ?? reporter.startIndex
check("CPU-limit classification still comes first", cpuAt < lostAt)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
