#!/usr/bin/env swift
// [T-nav-row-push-animation] Opening a chat from the home list animates again.
// Minimal change on top of 5d912c58f (T-nav-ghost-row-link), whose protection is
// left exactly as it was.
//
// 5d912c58f replaced each iPhone row's hidden NavigationLink(value:) with a
// Button -> switchToSession -> commitNavigationPath, which writes the path inside
// `tx.disablesAnimations = true` - so every row tap lost its push animation.
// The fix only lets a row tap onto an EMPTY stack write without that
// transaction; what is written (the path replaced with [id]) is unchanged.
//
//   [1] The shipping rule (BEGIN/END NavPushAnimationRule), compiled and checked
//       over all 16 inputs.
//   [2] 5d912c58f's protection is untouched: no NavigationLink in the iPhone
//       row, a row tap still replaces the path with [id], the home-list "new
//       chat" entries (the reported "new chat while another session is
//       streaming" path), move-to, notification opens, quick actions and the
//       launch / share appends keep their exact code, the background gate runs
//       first, every other write stays non-animated.
//   [3] Path semantics with real NavigationPath: the row write and the new-chat
//       write each leave exactly one page.
//
// Run: swift NavRowPushAnimationTests.swift   (needs swiftc)
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

let nav = source("Views/ContentView/ContentView+Navigation.swift")
let menu = source("Views/ContentView/ContentView+SessionMenu.swift")
let rows = source("Views/ContentView/Sidebar/SessionListRows.swift")
let content = source("Views/ContentView/ContentView.swift")
let headers = source("Views/ContentView/ContentView+SectionHeaders.swift")
let empty = source("Views/ContentView/ContentView+EmptyState.swift")
guard let rule = between(nav, "// BEGIN NavPushAnimationRule", "// END NavPushAnimationRule"),
      let diag = between(nav, "// BEGIN NavDiag", "// END NavDiag") else {
    print("❌ NavPushAnimationRule / NavDiag block not found"); exit(1)
}

let harness = """
import Foundation
import SwiftUI
enum Rule {
\(rule)
}
// Stubs for NavDiag: a logger that keeps the lines, and the running-session set.
@MainActor var logged: [String] = []
struct AppLogger {
    init(category: String) {}
    @MainActor func info(_ s: @autoclosure () -> String) { logged.append("I " + s()) }
    @MainActor func warning(_ s: @autoclosure () -> String) { logged.append("W " + s()) }
}
@MainActor final class SessionActivityTracker {
    static let shared = SessionActivityTracker()
    var activeSessions: Set<String> = []
}
\(diag)
func out(_ k: String, _ v: Any) { print("R \\(k)=\\(v)") }
var animatedCombos: [String] = []
for requested in [false, true] { for empty in [false, true] { for pending in [false, true] { for active in [false, true] {
    if Rule.shouldAnimateSessionPush(requested: requested, pathIsEmpty: empty,
                                     hasPendingBackgroundNavigation: pending, appIsActive: active) {
        animatedCombos.append("\\(requested)-\\(empty)-\\(pending)-\\(active)")
    }
}}}}
out("combos", animatedCombos.joined(separator: ","))

// switchToSession's path write (always a REPLACE), animated or not.
var path = NavigationPath()
func switchTo(_ id: String) { path = NavigationPath([id]) }   // what switchToSession commits
switchTo("FD704863")              // row tap (now animated: the stack was empty)
out("afterRow", path.count)
path.removeLast()                 // swipe back
out("afterBack", path.count)
switchTo("new-draft")             // FAB new chat from the home list
out("afterNewChat", path.count)
switchTo("other")                 // move-to / notification while a chat is open
out("afterMoveTo", path.count)

// [T-nav-stack-diag]
@MainActor func diag() {
    var p = NavigationPath(["A-1"]); p.append("B-2"); p.append("C-3")
    out("d.ids", (NavDiag.ids(p) ?? []).joined(separator: ","))
    // A running session that is not the target ends up on the stack.
    SessionActivityTracker.shared.activeSessions = ["RUN-9"]
    logged = []
    NavDiag.write(event: "commit", target: "NEW-1", before: NavigationPath(), after: NavigationPath(["RUN-9", "NEW-1"]),
                  animated: false, outcome: "committed", caller: "X.swift:1")
    out("d.writeStray", logged.last?.hasPrefix("W ⚠️") == true && logged.last?.contains("RUNNING-SESSION-NOT-TARGET-IN-STACK=[RUN-9]") == true)
    // Clean write: target only, running session elsewhere.
    logged = []
    NavDiag.write(event: "commit", target: "NEW-1", before: NavigationPath(), after: NavigationPath(["NEW-1"]),
                  animated: true, outcome: "committed", caller: "X.swift:2")
    out("d.writeClean", logged.last?.hasPrefix("I [NavDiag] write") == true && logged.last?.contains("animated=true") == true
        && logged.last?.contains("running=[RUN-9]") == true)
    // Observed: the path the app wrote -> clean; a pop of it -> clean.
    logged = []
    NavDiag.observe(NavigationPath(["NEW-1"]), currentTarget: "NEW-1")
    out("d.observeOwn", logged.last?.hasPrefix("I ") == true)
    logged = []
    NavDiag.observe(NavigationPath(), currentTarget: "NEW-1")
    out("d.observePop", logged.last?.hasPrefix("I ") == true)
    // Observed: a path the app never wrote, carrying the running session.
    logged = []
    NavDiag.observe(NavigationPath(["RUN-9", "NEW-1"]), currentTarget: "NEW-1")
    let w = logged.last ?? ""
    out("d.observeGhost", w.hasPrefix("W ⚠️") && w.contains("NOT-WRITTEN-BY-APP lastWritten=[NEW-1]")
        && w.contains("RUNNING-SESSION-NOT-TARGET-IN-STACK=[RUN-9]") && w.contains("path=[RUN-9,NEW-1]"))
}
MainActor.assumeIsolated { diag() }
"""

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("navanim_\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let mainFile = tmp.appendingPathComponent("main.swift")
try? harness.write(to: mainFile, atomically: true, encoding: .utf8)
let exe = tmp.appendingPathComponent("t").path
let (cs, cout) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", mainFile.path, "-o", exe])
guard cs == 0 else { print("❌ compile failed\n\(cout)"); exit(1) }
let (_, rout) = run(exe, [])
var r: [String: String] = [:]
for line in rout.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1)
    if kv.count == 2 { r[String(kv[0])] = String(kv[1]) }
}

print("1. When a session push animates (shipping rule, all 16 inputs)")
check("only a requested push onto an empty stack, nothing deferred, app active",
      r["combos"] == "true-true-false-true")

print("\n2. The 5d912c58f ghost-page fix still holds")
let stackRow = between(rows, "struct SessionStackRow: View {", "struct SessionSplitRow") ?? ""
check("the iPhone row has no NavigationLink (the source of the ghost page)",
      !stackRow.isEmpty && !stackRow.contains("NavigationLink"))
check("a row tap still goes through the app's own channel",
      stackRow.contains("menuActions.send(.open(sid))"))
check("…whose handler switches (replaces), asking for the animation",
      menu.contains("case .open(let sid):") && menu.contains("switchToSession(sid, animated: true)"))
let switchBody = between(nav, "func switchToSession(_ id: String, animated: Bool = false,", "\n    }\n") ?? ""
check("switchToSession still REPLACES the path with [id] - one write, animated or not",
      switchBody.contains("commitNavigationPath(NavigationPath([id]), animated: animate, target: id")
      && !switchBody.contains(".append("))
check("the animation decision is the tested rule, fed the live stack / deferral / app state",
      switchBody.contains("pathIsEmpty: navigationPath.isEmpty")
      && switchBody.contains("hasPendingBackgroundNavigation: pendingBackgroundNavigation != nil")
      && switchBody.contains("appIsActive: UIApplication.shared.applicationState == .active"))
check("home-list new chats still replace, without animation (FAB, group FAB, folder, empty state)",
      menu.contains("if !fabDidDrag { switchToSession(Self.makeNewSessionId()) }")
      && menu.contains("switchToSession(Self.makeNewSessionId(groupId: groupId))")
      && headers.contains("switchToSession(draftId)")
      && empty.contains("switchToSession(Self.makeNewSessionId())"))
check("move-to and notification opens keep the atomic non-animated replace",
      content.contains("switchToSession(targetId)") && content.contains("switchToSession(sessionId)")
      && !content.contains("animated: true"))
let commitBody = between(nav, "private func commitNavigationPath(_ newPath: NavigationPath, animated: Bool = false,", "\n    }\n") ?? ""
let gateAt = commitBody.range(of: "if appState == .background {")?.lowerBound
let animAt = commitBody.range(of: "if animated {")?.lowerBound
check("the background gate still runs before any write, animated or not",
      gateAt != nil && animAt != nil && gateAt! < animAt!)
check("every non-animated write is still inside a disabled-animation transaction",
      commitBody.contains("var tx = Transaction()\n        tx.disablesAnimations = true\n        withTransaction(tx) {\n            navigationPath = newPath"))
check("a deferred background navigation is still flushed without animation",
      (between(nav, "func flushPendingBackgroundNavigation() {", "\n    }\n") ?? "").contains("tx.disablesAnimations = true"))
check("the [NavStack] depth diagnostic from 5d912c58f is still there",
      content.contains("[NavStack] depth="))
let openBody = between(nav, "func openSession(_ id: String, file: String = #fileID, line: Int = #line) {", "\n    }\n}") ?? ""
check("launch / share / notification opens keep their original append, untouched",
      openBody.contains("var next = pendingBackgroundNavigation?.path ?? navigationPath\n            next.append(id)\n            commitNavigationPath(next, target: id, file: file, line: line)"))
check("quick-action new chats keep their original non-animated replace, untouched",
      nav.components(separatedBy: "commitNavigationPath(NavigationPath([newId]))").count - 1 == 2)
check("only the row tap asks for animation anywhere in ContentView",
      [menu, content, headers, empty, nav].joined().components(separatedBy: "animated: true").count - 1 == 1)

print("\n3. Path semantics with real NavigationPath")
check("row tap: one page", r["afterRow"] == "1")
check("swipe back: home", r["afterBack"] == "0")
check("a home-list new chat afterwards: exactly one page", r["afterNewChat"] == "1")
check("move-to while a chat is open: still one page (replace, not push)", r["afterMoveTo"] == "1")

print("\n4. [NavDiag] diagnostics (compiled from the shipping block)")
check("path ids decode bottom to top", r["d.ids"] == "A-1,B-2,C-3")
check("a write that puts a running non-target session on the stack is flagged", r["d.writeStray"] == "true")
check("a clean write logs caller, animation and the running sessions", r["d.writeClean"] == "true")
check("observing the app's own write, or a pop of it, is not flagged", r["d.observeOwn"] == "true" && r["d.observePop"] == "true")
check("a path the app never wrote, carrying a running session, is flagged with both",
      r["d.observeGhost"] == "true")
check("every write goes through NavDiag with its caller (commit, deferral, flush)",
      nav.components(separatedBy: "NavDiag.write(").count - 1 >= 4
      && nav.contains("commitNavigationPath(NavigationPath([id]), animated: animate, target: id, file: file, line: line)")
      && nav.contains("commitNavigationPath(next, target: id, file: file, line: line)"))
check("every path change is observed", content.contains("NavDiag.observe(navigationPath, currentTarget: currentStackSessionId)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
