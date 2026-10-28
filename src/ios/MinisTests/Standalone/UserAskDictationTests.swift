#!/usr/bin/env swift
// [T-user-ask-dictation-double] Dictating in the user_ask answer sheet
// ("Your answer" / note / cancel reason) must not run two dictation stacks.
//
// Field report (screenshot): after tapping Dictate the sheet showed "Stop
// dictation" while the system keyboard stayed up with its own mic usable -
// the sheet started SpeechRecognitionManager under a TextField that kept
// first responder. The fix reuses the chat composer's voice input
// (InlineVoiceInputView + VoiceInputViewModel) in the composer's order:
// drop the keyboard, then voice mode.
//
//   [1] shouldClose (shipping code): the sheet closes - releasing the mic -
//       once its question is settled or the wizard moved on
//   [2] source guards: reuse, keyboard-first order, teardown on every exit,
//       draft saving, notification Other… path untouched
//
// Run: swift UserAskDictationTests.swift   (needs swiftc)
import Foundation

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}
func source(_ rel: String) -> String {
    let here = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return (try? String(contentsOf: here.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r0 = s.range(of: a), let r1 = s.range(of: b, range: r0.upperBound..<s.endIndex) else { return nil }
    return String(s[r0.upperBound..<r1.lowerBound])
}
let coreSrc = source("Agent/Chat/UserAskCore.swift")
let cardSrc = source("Views/Chat/UserAskCardView.swift")
guard let core = between(coreSrc, "// BEGIN UserAskCore", "// END UserAskCore"),
      let close = between(cardSrc, "// BEGIN UserAskInputSheetClose", "// END UserAskInputSheetClose") else {
    print("❌ source blocks not found"); exit(1)
}

let harness = #"""
import Foundation
var out: [String] = []
func R(_ k: String, _ v: Any) { out.append("R \(k)=\(v)") }
let req: UserAskRequest = {
    let qs: [[String: Any]] = [
        ["type": "options", "question": "Q1", "options": [["label": "A"], ["label": "B"]]],
        ["type": "options", "question": "Q2", "options": [["label": "C"], ["label": "D"]]],
    ]
    if case .success(let r) = UserAskParser.parse(["questions": qs]) { return r }
    fatalError("parse")
}()
var ask = PendingAsk(requestId: "r1", sessionId: "s1", toolCallId: "t1", questions: req.questions,
                     createdAt: Date(), timeoutMinutes: 5)
R("openSameIndex", UserAskInputSheet.shouldClose(ask: ask, index: 0))
R("missing", UserAskInputSheet.shouldClose(ask: nil, index: 0))
var moved = ask; moved.currentIndex = 1
R("wizardMoved", UserAskInputSheet.shouldClose(ask: moved, index: 0))
R("wizardMovedOwnIndex", UserAskInputSheet.shouldClose(ask: moved, index: 1))
var timedOut = ask; _ = timedOut.resolveTimedOut()
R("timedOut", UserAskInputSheet.shouldClose(ask: timedOut, index: 0))
var superseded = ask; _ = superseded.resolveDismissed(.supersededByUserMessage)
R("superseded", UserAskInputSheet.shouldClose(ask: superseded, index: 0))
var stopped = ask; _ = stopped.resolveDismissed(.stopped)
R("stopped", UserAskInputSheet.shouldClose(ask: stopped, index: 0))
print(out.joined(separator: "\n"))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("user-ask-dictation-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let files = [("Core.swift", "import Foundation\n" + core),
             ("Close.swift", "import Foundation\nenum UserAskInputSheet {\n" + close + "\n}\n"),
             ("main.swift", harness)]
for (name, text) in files { try? text.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8) }
func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self))
}
let bin = tmp.appendingPathComponent("t")
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc"] + files.map { tmp.appendingPathComponent($0.0).path } + ["-o", bin.path])
print("0. Compile")
check("shipping shouldClose + UserAskCore compile standalone", cc == 0)
if cc != 0 { print(ccOut); exit(1) }
let (rc, out) = run(bin.path, [])
check("runner exited", rc == 0)
if rc != 0 { print(out) }
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { r[kv[0]] = kv[1] }
}

print("\n1. The sheet only lives while its question is open")
check("open question at the sheet's index → stays", r["openSameIndex"] == "false")
check("ask gone (delivered / recovered elsewhere) → closes", r["missing"] == "true")
check("wizard moved to another question → closes (b)", r["wizardMoved"] == "true" && r["wizardMovedOwnIndex"] == "false")
check("timed out / superseded / stopped → closes (c)",
      r["timedOut"] == "true" && r["superseded"] == "true" && r["stopped"] == "true")

print("\n2. Source guards")
guard let sheet = between(cardSrc, "private struct UserAskInputSheet: View {", "\n}\n") else {
    check("UserAskInputSheet found", false); exit(1)
}
check("reuses the composer's voice input (panel + view model)",
      sheet.contains("@StateObject private var voiceVM = VoiceInputViewModel()")
      && sheet.contains("InlineVoiceInputView(viewModel: voiceVM, inputText: $text)"))
check("no second dictation stack in the sheet",
      !sheet.contains("SpeechRecognitionManager") && !sheet.contains("startRecording") && !sheet.contains("recognizedText"))
if let enter = between(sheet, "private func enterVoice() {", "\n    }\n") {
    let drop = enter.range(of: "focused = false")
    let resign = enter.range(of: "#selector(UIResponder.resignFirstResponder)")
    let voice = enter.range(of: "voiceActive = true")
    check("keyboard goes down BEFORE voice mode starts (composer MicButton order)",
          drop != nil && resign != nil && voice != nil
          && drop!.lowerBound < voice!.lowerBound && resign!.lowerBound < voice!.lowerBound)
    check("listening starts through the panel's own mic action", enter.contains("voiceVM.handleMainButtonTap()"))
} else {
    check("enterVoice found", false)
}
// [T-user-ask-dictation-below] The text box stays; the panel sits under the button.
check("the text box is always there; while dictating it takes no taps or focus",
      sheet.contains("TextField(\"\", text: $text, axis: .vertical)")
      && !sheet.contains("} else {\n                    // Grows with the text")
      && sheet.contains(".allowsHitTesting(!voiceActive)"))
check("a double tap on the text box stops dictation and starts editing",
      sheet.contains(".onTapGesture(count: 2) { editFromVoice() }")
      && (between(cardSrc, "private func editFromVoice() {", "\n    }\n") ?? "").contains("leaveVoice()\n        DispatchQueue.main.async { focused = true }"))
let panelPos = sheet.range(of: "InlineVoiceInputView(viewModel: voiceVM, inputText: $text)")?.lowerBound
let buttonPos = sheet.range(of: "AppLocalized(\"Stop dictation\")")?.lowerBound
let fieldPos = sheet.range(of: "TextField(\"\", text: $text, axis: .vertical)")?.lowerBound
check("order: text box, then the Dictate / Stop dictation row, then the voice panel",
      fieldPos != nil && buttonPos != nil && panelPos != nil && fieldPos! < buttonPos! && buttonPos! < panelPos!)
let leave = between(cardSrc, "private func leaveVoice() {", "\n    }\n") ?? ""
check("leaving voice stops the VAD (keyboard stays down, as in the composer)",
      leave.contains("voiceVM.stopListening()") && !leave.contains("focused = true"))
check("Cancel / Done / a settled question all leave voice first",
      sheet.contains("Button(AppLocalized(\"Cancel\")) { leaveVoice(); onCancel() }")
      && sheet.contains("Button(AppLocalized(\"Done\")) { leaveVoice(); onDone(text) }")
      && sheet.contains("closing = true\n            leaveVoice()\n            onCancel()"))
check("the settled-question close is one-shot", sheet.contains("guard !closing, UserAskInputSheet.shouldClose("))
check("drafts (incl. dictated text) keep saving: onChange covers both input modes (d)",
      sheet.contains("            .onChange(of: text) { t in onChange(t) }\n            .navigationTitle(title)"))
let presenter = between(cardSrc, "enum UserAskInputPresenter {", "\n}\n") ?? ""
check("the presenter dismisses only its own sheet, at most once",
      presenter.contains("weak var hostRef: UIViewController?")
      && presenter.contains("guard let host = hostRef, host.presentingViewController != nil, !host.isBeingDismissed else { return }")
      && !presenter.contains("top.dismiss("))
check("the panel itself still releases the mic when it goes away",
      source("Views/Chat/Voice/InlineVoiceInputView.swift").contains("viewModel.stopListening()\n        }"))
// [T-user-ask-dictation-style] dictating keeps the text state's look
check("style: the sheet has ONE (full-height) detent - no drop to the translucent medium detent",
      presenter.contains("sheet.detents = [.large()]") && !presenter.contains(".medium()"))
check("style: an explicit opaque sheet background in both input modes",
      sheet.contains(".background(Color(UIColor.systemBackground).ignoresSafeArea())"))
check("style: the voice panel has the same hairline frame as the text box",
      sheet.components(separatedBy: ".stroke(Color(UIColor.separator), lineWidth: 0.5)").count - 1 == 2)
let enter = between(cardSrc, "private func enterVoice() {", "\n    }\n") ?? ""
check("style: the panel is the composer's own component, compact here, and the composer's choice is put back",
      sheet.contains("InlineVoiceInputView(viewModel: voiceVM, inputText: $text)")
      && enter.contains("mode.enteredFromText = false") && enter.contains("mode.expanded = false")
      && enter.contains("if savedVoiceExpanded == nil { savedVoiceExpanded = mode.expanded }")
      && leave.contains("VoiceModePreference.shared.expanded = saved"))
check("style: the panel comes and goes with a short fade, not a jump",
      sheet.contains(".animation(.easeOut(duration: 0.2), value: voiceActive)")
      && sheet.components(separatedBy: ".transition(.opacity)").count - 1 == 1)
let center = source("Agent/Chat/UserAskCenter.swift")
check("notification Other… text input untouched by voice (a)",
      center.contains("UNTextInputNotificationResponse") && !center.contains("VoiceInputViewModel")
      && !center.contains("SpeechRecognitionManager"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
