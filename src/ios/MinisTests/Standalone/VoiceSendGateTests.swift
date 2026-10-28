#!/usr/bin/env swift
// [T-voice-send-lock] Tapping Send while voice input is still recording stops
// the mic, waits for recognition, and only then sends. That can take seconds,
// and the send button looked and behaved as if nothing had happened, so users
// tapped it again.
//
// Now the button is busy (not tappable) for exactly that wait and for nothing
// else. It can never stay that way: every end of the wait - sent, a failed
// transcription, the time limit, the user cancelling, editing the text,
// starting to record again, leaving voice mode or the chat - goes through one
// function with the attempt it belongs to. A late callback of an attempt that
// already ended does nothing: it cannot send a second message and it cannot
// lock the button again.
//
// [1] runs the shipping gate (VoiceSendGate, lifted as text) through those
//     sequences with a driver shaped like VoiceInputViewModel's wait.
// [2] pins the wiring in the shipping sources.
//
// Run: swift VoiceSendGateTests.swift
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
func code(_ src: String) -> String {
    src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
/// The declaration starting at `marker`, through its matching closing brace.
func block(_ src: String, _ marker: String) -> String {
    guard let start = src.range(of: marker) else { return "" }
    var depth = 0, seenOpen = false
    var i = start.lowerBound
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" { depth -= 1; if seenOpen && depth == 0 { return String(src[start.lowerBound...i]) } }
        i = src.index(after: i)
    }
    return ""
}
func index(_ hay: String, _ needle: String) -> Int {
    hay.range(of: needle).map { hay.distance(from: hay.startIndex, to: $0.lowerBound) } ?? -1
}

let gate = source("Views/Chat/AIChatView/Composer/VoiceSendGate.swift")

// MARK: - 1. The shipping gate, driven like the view model drives it

let scenario = #"""

var failures = 0
func check(_ label: String, _ cond: Bool) {
    print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
    if !cond { failures += 1 }
}

/// The wait as VoiceInputViewModel runs it: begin on Send, one function that
/// ends an attempt, late callbacks that carry the attempt they were made for.
final class Wait {
    var gate = VoiceSendGate()
    var locked = false                      // isFinishingForSend → the button is busy
    var completions: [Bool] = []            // every completion(ok) that was delivered
    var sent: Int { completions.filter { $0 }.count }
    private var completion: ((Bool) -> Void)?

    /// Send tapped while voice owes text. Returns the attempt, or nil when ignored.
    @discardableResult func tapSend() -> Int? {
        guard !gate.isWaiting, let attempt = gate.begin() else { return nil }
        locked = true
        completion = { [unowned self] ok in self.completions.append(ok) }
        return attempt
    }
    func conclude(_ attempt: Int, _ end: VoiceSendGate.End) {
        guard gate.conclude(attempt) else { return }
        locked = false
        let done = completion
        completion = nil
        done?(end == .send)
    }
    func abandon(_ end: VoiceSendGate.End) {
        guard let attempt = gate.pending else { return }
        conclude(attempt, end)
    }
}

print("1a. Double taps")
let w = Wait()
let first = w.tapSend()
check("the first tap starts the wait and locks the button", first == 1 && w.locked)
check("a second and a third tap start nothing", w.tapSend() == nil && w.tapSend() == nil && w.gate.pending == 1)
w.conclude(first!, .send)
check("recognition finishes: sent once, button released", w.sent == 1 && w.completions == [true] && !w.locked)
w.conclude(first!, .send)
w.conclude(first!, .timedOut)
check("the same attempt ending again (poll tick + safety net) changes nothing", w.completions == [true] && !w.locked)

print("1b. Every other end releases the button and sends nothing")
for end in [VoiceSendGate.End.transcriptionFailed, .timedOut, .cancelled, .recordingRestarted, .textEdited, .voiceDismissed, .chatLeft] {
    let x = Wait()
    let a = x.tapSend()!
    if end == .transcriptionFailed || end == .timedOut { x.conclude(a, end) } else { x.abandon(end) }
    check("\(end.rawValue): released, not sent, completion delivered once", !x.locked && x.sent == 0 && x.completions == [false])
}

print("1c. A stale callback of an abandoned attempt")
let s = Wait()
let old = s.tapSend()!
s.abandon(.cancelled)                         // the user cancels the transcription
s.conclude(old, .send)                        // … whose result arrives anyway
check("does not send", s.sent == 0 && s.completions == [false])
check("does not lock the button again", !s.locked && !s.gate.isWaiting)
let next = s.tapSend()!
check("the next tap is a new attempt", next == old + 1 && s.locked)
s.conclude(old, .send)                        // the old poll ticks once more
s.conclude(old, .timedOut)                    // the old safety net fires
check("the old attempt's poll and safety net cannot end the new wait", s.locked && s.gate.isCurrent(next) && s.completions == [false])
s.conclude(next, .send)
check("the new attempt sends once", s.sent == 1 && s.completions == [false, true] && !s.locked)

print("1d. Abandon when nothing is pending")
let idle = Wait()
idle.abandon(.textEdited); idle.abandon(.recordingRestarted); idle.abandon(.voiceDismissed)
check("editing / recording / leaving with no pending send does nothing", idle.completions.isEmpty && !idle.locked && idle.gate.lastAttempt == 0)

print("1e. One poll tick")
func run(_ ticks: [(queued: Int, inFlight: Int, failed: Bool, t: Double)], timeout: Double = 60) -> [VoiceSendGate.Verdict] {
    var idleTicks = 0
    return ticks.map { VoiceSendGate.verdict(queuedSegments: $0.queued, inFlight: $0.inFlight, failedSinceStart: $0.failed,
                                             elapsed: $0.t, timeout: timeout, idleTicks: &idleTicks) }
}
check("idle is not trusted before the 0.3 s settle",
      run([(0, 0, false, 0.1), (0, 0, false, 0.2)]) == [.keepWaiting, .keepWaiting])
check("two consecutive idle ticks after the settle send",
      run([(0, 0, false, 0.3), (0, 0, false, 0.4)]) == [.keepWaiting, .end(.send)])
check("a transcription in flight keeps waiting, however long (below the limit)",
      run([(0, 1, false, 1.0), (0, 1, false, 30.0), (0, 1, false, 59.9)]) == [.keepWaiting, .keepWaiting, .keepWaiting])
check("a segment that arrives between two idle ticks restarts the count",
      run([(0, 0, false, 0.4), (1, 0, false, 0.5), (0, 0, false, 0.6), (0, 0, false, 0.7)]) == [.keepWaiting, .keepWaiting, .keepWaiting, .end(.send)])
check("a failure ends it at once, even when everything else is idle",
      run([(0, 0, true, 0.1)]) == [.end(.transcriptionFailed)] && run([(0, 0, false, 0.5), (0, 0, true, 0.6)]).last == .end(.transcriptionFailed))
check("the time limit ends a wait that is still transcribing",
      run([(0, 1, false, 59.9), (0, 1, false, 60.0)]) == [.keepWaiting, .end(.timedOut)])
check("a result that lands on the last tick is still sent",
      run([(0, 0, false, 59.95), (0, 0, false, 60.05)]) == [.keepWaiting, .end(.send)])
check("an empty recognition result ends the wait like any other (the lock is released)",
      run([(0, 1, false, 0.5), (0, 0, false, 0.6), (0, 0, false, 0.7)]).last == .end(.send))

exit(failures == 0 ? 0 : 1)
"""#

print("1. The shipping gate, driven like the view model drives it")
check("the gate source was found", gate.contains("struct VoiceSendGate {") && gate.contains("mutating func conclude(_ attempt: Int) -> Bool {"))
if failures == 0 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceSendGate-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("main.swift")
    try? (gate + scenario).write(to: file, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift", file.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    print(text, terminator: "")
    let passed = text.components(separatedBy: "✅").count - 1
    check("harness ran to the end (\(passed) checks) and exited 0", p.terminationStatus == 0 && passed >= 25)
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 2. Wiring

print("\n2. Wiring in the shipping sources")
let vm = source("Views/Chat/Voice/VoiceInputPanel.swift")
let panel = source("Views/Chat/Voice/InlineVoiceInputView.swift")
let send = source("Views/Chat/AIChatView/AIChatView+Send.swift")
let button = source("Views/Chat/AIChatView/Composer/ChatSendButton.swift")
let controls = source("Views/Chat/AIChatView/AIChatView+ComposerControls.swift")
let chat = source("Views/Chat/AIChatView/AIChatView.swift")
let vmCode = code(vm)

let finish = block(vm, "    func finishCaptureForSend(completion: @escaping @MainActor (Bool) -> Void) {")
let conclude = block(vm, "    private func concludeFinishForSend(attempt: Int, _ end: VoiceSendGate.End) {")
check("a repeated Send is refused before anything else, then the gate hands out the attempt",
      index(finish, "guard !sendGate.isWaiting else {") > 0
      && index(finish, "guard !sendGate.isWaiting else {") < index(finish, "guard hasUntranscribedAudio else { completion(true); return }")
      && finish.contains("guard let attempt = sendGate.begin() else { return }\n        isFinishingForSend = true"))
check("every poll tick first checks it still belongs to the pending attempt",
      finish.contains("guard let self, self.sendGate.isCurrent(attempt) else { timer.invalidate(); return }"))
check("the poll's decision is the tested one",
      finish.contains("let verdict = VoiceSendGate.verdict(") && finish.contains("self.concludeFinishForSend(attempt: attempt, end)"))
check("the poll runs in the common run loop modes (a finger on the list does not hold the send)",
      finish.contains("RunLoop.main.add(timer, forMode: .common)") && !code(finish).contains("Timer.scheduledTimer"))
check("a safety net independent of the poll releases the attempt after the time limit",
      finish.contains("DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishForSendTimeout + 2) { [weak self] in\n            self?.concludeFinishForSend(attempt: attempt, .timedOut)"))
check("one function ends a wait: gate first, then the lock, then the completion - once",
      index(conclude, "guard sendGate.conclude(attempt) else { return }") > 0
      && index(conclude, "guard sendGate.conclude(attempt) else { return }") < index(conclude, "isFinishingForSend = false")
      && index(conclude, "isFinishingForSend = false") < index(conclude, "completion?(end == .send)")
      && conclude.contains("finishCompletion = nil"))
check("the lock is set in one place and cleared in one place",
      vmCode.components(separatedBy: "isFinishingForSend = true").count - 1 == 1
      && vmCode.components(separatedBy: "isFinishingForSend = false").count - 1 == 2   // the declaration's initial value + concludeFinishForSend
      && vmCode.contains("@Published private(set) var isFinishingForSend = false"))

func starts(_ marker: String, with call: String) -> Bool {
    let b = code(block(vm, marker))
    guard let brace = b.firstIndex(of: "{") else { return false }
    return b[b.index(after: brace)...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(call)
}
check("cancelling the transcription takes the send back",
      starts("    func cancelTranscription() {", with: "abandonFinishForSend(.cancelled)"))
check("the mic (start recording again) takes the send back",
      starts("    func handleMainButtonTap() {", with: "abandonFinishForSend(.recordingRestarted)"))
check("editing does: keyboard edit, outside text, backspace, clear all",
      block(vm, "    func beginEditing() {").contains("abandonFinishForSend(.textEdited)")
      && block(vm, "    func setTranscript(_ text: String) {").contains("if text != transcript { abandonFinishForSend(.textEdited) }")
      && starts("    func deleteLastCharacter() {", with: "abandonFinishForSend(.textEdited)")
      && starts("    func clearTranscript() {", with: "abandonFinishForSend(.textEdited)"))
check("leaving voice mode does, and so does clearing the panel",
      starts("    func reset(clearTranscript: Bool = true) {", with: "abandonFinishForSend(.voiceDismissed)")
      && starts("    func clearAndRearm() {", with: "abandonFinishForSend(.cancelled)"))
check("leaving the chat page does",
      block(chat, "        .onDisappear {\n            isChatViewVisible = false").contains("voiceVM.abandonFinishForSend(.chatLeft)"))
check("the timer cannot outlive the view model", block(vm, "    deinit {").contains("finishPollTimer?.invalidate()"))

let submit = block(send, "    func submitAfterVoice() {")
check("what follows a finished wait never waits again (no second wait, no second send)",
      submit.contains("performEnqueue(afterVoice: true)") && submit.contains("performSend(afterVoice: true)")
      && send.contains("func performSend(afterVoice: Bool = false) {\n        if !afterVoice, deferSendUntilVoiceFinished() { return }")
      && send.contains("func performEnqueue(afterVoice: Bool = false) {\n        if !afterVoice, deferSendUntilVoiceFinished() { return }"))
check("… and decides by what the composer holds, so an empty recognition sends nothing",
      !code(submit).contains("canSend") && !code(submit).contains("canEnqueue")
      && submit.contains("let hasText = !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty")
      && submit.contains("guard voiceInputActive else {"))
check("the deferral only sends on a true completion",
      send.contains("voiceVM.finishCaptureForSend { [composerActions] ok in\n            if ok { composerActions.send(.submitAfterVoice) }"))
check("the busy state is exactly the pending wait, in voice mode",
      send.contains("var isWaitingToSendVoice: Bool {\n        voiceInputActive && voiceVM.isFinishingForSend\n    }")
      && controls.contains("isWaitingToSendVoice: isWaitingToSendVoice,"))
let body = block(button, "    var body: some View {")
check("the send button shows it before any other state, as a spinner that is not a control",
      index(body, "if isWaitingToSendVoice {") > 0
      && index(body, "if isWaitingToSendVoice {") < index(body, "} else if vm.isProcessing && canEnqueue {")
      && { let busy = body.components(separatedBy: "if isWaitingToSendVoice {").dropFirst().first?
              .components(separatedBy: "} else if vm.isProcessing && canEnqueue {").first ?? ""
           return busy.contains("ProgressView()") && !busy.contains("Button {") && !busy.contains("Button(") && !busy.contains("returnModeMenu") && busy.contains(".accessibilityLabel(") }())
check("the voice panel says why", panel.contains("if viewModel.isFinishingForSend {\n            return AppLocalized(\"Transcribing, then sending…\""))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
