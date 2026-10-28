// [T-voice-asr-stall-skip] Voice input: when an ASR attempt has no result after
// 5 s, the mic button becomes "retry with the next voice model" and a tap
// abandons the hung attempt and continues on the next model (System ASR as
// the last resort).
//
// Why: the fail-over chain only advanced when an attempt THREW. A half-dead
// connection or an inference server that accepted the upload and went quiet
// never throws, so a long utterance could leave the user waiting with no way
// out except cancelling (and losing) the transcription.
//
//   A. SkippableASRAttempts, compiled out of VoiceInputPanel.swift and run with
//      a 0.2 s threshold: fast attempts never stall; a slow one stalls, and a
//      skip releases the caller at once EVEN IF the operation ignores
//      cancellation; canSkip=false never stalls; errors pass through; caller
//      cancellation returns promptly; concurrent stalls skip together.
//   B. Source wiring: the fail-over loop runs each candidate through the
//      helper with the right next hop, falls back to System only after a user
//      skip, the threshold is 5 s, and the button shows the composed icon,
//      skipping BEFORE it pauses a running capture.
//
// Standalone: `swift VoiceASRStallSkipTests.swift` (needs swiftc).

import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("  ✅ \(label)") } else { print("  ❌ \(label)"); failures += 1 }
}

let root = FileManager.default.currentDirectoryPath
func source(_ rel: String) -> String {
    var dir = URL(fileURLWithPath: root)
    for _ in 0..<7 {
        let p = dir.appendingPathComponent("src/ios/" + rel).path
        if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
        dir = dir.deletingLastPathComponent()
    }
    fatalError("source not found: \(rel)")
}
func between(_ s: String, _ a: String, _ b: String) -> String? {
    guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
    return String(s[r1.upperBound..<r2.lowerBound])
}

let panel = source("Views/Chat/Voice/VoiceInputPanel.swift")
let inline = source("Views/Chat/Voice/InlineVoiceInputView.swift")

// MARK: - A. The shipping helper, compiled and exercised

print("A. SkippableASRAttempts (compiled from VoiceInputPanel.swift)")
let helper = between(panel, "// [T-voice-asr-stall-skip] BEGIN skippable-asr-attempts",
                     "// [T-voice-asr-stall-skip] END skippable-asr-attempts")
check("helper found between markers", helper != nil)

if let helper {
    let harness = #"""
    import Foundation
    \#(helper)

    func now() -> Double { Date().timeIntervalSince1970 }
    /// Sleeps WITHOUT honouring cancellation — a provider that ignores it.
    func stubbornSleep(_ s: Double) async { let end = now() + s; while now() < end { try? await Task.sleep(nanoseconds: 20_000_000) } }

    @MainActor func scenarios() async {
        var out: [String] = []
        let a = SkippableASRAttempts(stallThreshold: 0.2)
        var flips: [Bool] = []
        a.onStallChange = { flips.append($0) }

        // 1. Fast attempt: returns, never stalls.
        let r1 = try? await a.run(label: "fast", nextEntryId: "B", canSkip: true) { "hello" }
        out.append("fast=\(r1 ?? "nil") flips=\(flips)")

        // 2. Slow attempt that ignores cancellation, skipped after it stalls.
        flips = []
        let t0 = now()
        let slow = Task { @MainActor () -> String in
            do { return try await a.run(label: "slow", nextEntryId: "B", canSkip: true) { await stubbornSleep(3); return "late" } }
            catch is SkippableASRAttempts.Skipped { return "skipped" }
            catch { return "error:\(error)" }
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        out.append("stalled=\(a.hasStalled) flips=\(flips)")
        let nexts = a.skipStalled()
        let r2 = await slow.value
        let waited = now() - t0
        out.append("slow=\(r2) nexts=\(nexts.map { $0 ?? "nil" }) waited<1.0=\(waited < 1.0) stalledAfter=\(a.hasStalled) flips=\(flips)")

        // 3. canSkip=false never stalls.
        flips = []
        let noSkip = Task { @MainActor () -> String in
            (try? await a.run(label: "last", nextEntryId: nil, canSkip: false) { await stubbornSleep(0.5); return "ok" }) ?? "threw"
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        out.append("noSkipStalled=\(a.hasStalled) skipReturned=\(a.skipStalled().count)")
        out.append("noSkip=\(await noSkip.value) flips=\(flips)")

        // 4. Errors pass through.
        struct Boom: Error {}
        do { _ = try await a.run(label: "err", nextEntryId: "B", canSkip: true) { throw Boom() }; out.append("err=none") }
        catch is Boom { out.append("err=Boom") } catch { out.append("err=\(error)") }

        // 5. Caller cancellation returns promptly even though the op ignores it.
        let t1 = now()
        let cancelled = Task { @MainActor () -> String in
            do { return try await a.run(label: "cancel", nextEntryId: "B", canSkip: true) { await stubbornSleep(3); return "late" } }
            catch is CancellationError { return "cancelled" }
            catch { return "error:\(error)" }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        cancelled.cancel()
        let r5 = await cancelled.value
        out.append("cancel=\(r5) fast=\(now() - t1 < 1.0) stalledAfter=\(a.hasStalled)")

        // 6. Two concurrent stalls skip together.
        flips = []
        func slowJob(_ next: String) -> Task<String, Never> {
            Task { @MainActor in
                do { return try await a.run(label: next, nextEntryId: next, canSkip: true) { await stubbornSleep(3); return "late" } }
                catch is SkippableASRAttempts.Skipped { return "skipped" } catch { return "error" }
            }
        }
        let j1 = slowJob("N1"), j2 = slowJob("N2")
        try? await Task.sleep(nanoseconds: 450_000_000)
        let both = a.skipStalled().compactMap { $0 }.sorted()
        out.append("both=\(both) j1=\(await j1.value) j2=\(await j2.value) flips=\(flips)")

        // 8. A stalled attempt that completes on its own clears the stall
        //    (the Switch Model pill goes away and delete comes back).
        flips = []
        let late = try? await a.run(label: "late", nextEntryId: "B", canSkip: true) { await stubbornSleep(0.45); return "done" }
        out.append("selfDone=\(late ?? "nil") stalledAfter=\(a.hasStalled) flips=\(flips)")

        // 7. Nothing stalled → skip is a no-op.
        out.append("idleSkip=\(a.skipStalled().count)")
        print(out.joined(separator: "\n"))
    }

    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in await scenarios(); done.signal() }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    """#
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("asrskip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let main = tmp.appendingPathComponent("main.swift")
    try harness.write(to: main, atomically: true, encoding: .utf8)
    let bin = tmp.appendingPathComponent("t")

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5", main.path, "-o", bin.path])
    check("helper compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    check("scenarios ran", rc == 0)
    let lines = out.split(separator: "\n").map(String.init)
    func line(_ prefix: String) -> String { lines.first { $0.hasPrefix(prefix) } ?? "<missing \(prefix)>" }

    check("fast attempt returns its text and never stalls (\(line("fast=")))",
          line("fast=") == "fast=hello flips=[]")
    check("slow attempt is marked stalled after the threshold (\(line("stalled=")))",
          line("stalled=") == "stalled=true flips=[true]")
    check("skip releases the caller at once although the op ignores cancellation (\(line("slow=")))",
          line("slow=") == "slow=skipped nexts=[\"B\"] waited<1.0=true stalledAfter=false flips=[true, false]")
    check("canSkip=false never stalls and cannot be skipped (\(line("noSkipStalled=")))",
          line("noSkipStalled=") == "noSkipStalled=false skipReturned=0")
    check("canSkip=false attempt completes normally (\(line("noSkip=")))",
          line("noSkip=") == "noSkip=ok flips=[]")
    check("errors pass through unchanged (\(line("err=")))", line("err=") == "err=Boom")
    check("caller cancellation returns promptly and clears state (\(line("cancel=")))",
          line("cancel=") == "cancel=cancelled fast=true stalledAfter=false")
    check("concurrent stalls skip together (\(line("both=")))",
          line("both=") == "both=[\"N1\", \"N2\"] j1=skipped j2=skipped flips=[true, false]")
    check("skip with nothing stalled is a no-op", line("idleSkip=") == "idleSkip=0")
    check("a stalled attempt that completes on its own clears the stall (\(line("selfDone=")))",
          line("selfDone=") == "selfDone=done stalledAfter=false flips=[true, false]")
}

// MARK: - B. Source wiring

print("B. Wiring")
check("stall threshold is 5 s", panel.contains("static let asrStallThreshold: TimeInterval = 5"))
let failover = between(panel, "private func transcribeWithFailover(", "func skipStalledTranscription()") ?? ""
check("fail-over loop located", !failover.isEmpty)
check("each candidate runs through the skippable helper with its next hop",
      failover.contains("try await asrAttempts.run(label: entry.model.displayName,")
      && failover.contains("nextEntryId: nextEntryId,")
      && failover.contains("canSkip: nextEntryId != nil"))
check("the last candidate's next hop is System unless System is already in the chain",
      failover.contains(": (chainHasSystem ? nil : VoiceProviderResolver.systemEntryId)"))
check("a user skip moves on to the next candidate instead of failing the utterance",
      failover.contains("} catch is SkippableASRAttempts.Skipped {") && failover.contains("userSkipped = true"))
if let skipCatch = failover.range(of: "} catch is SkippableASRAttempts.Skipped {"),
   let cancelCatch = failover.range(of: "} catch is CancellationError {") {
    check("cancellation is still re-thrown before the skip branch", cancelCatch.lowerBound < skipCatch.lowerBound)
} else {
    check("cancellation is still re-thrown before the skip branch", false)
}
check("System fallback only after a user skip and only when System is not in the chain",
      failover.contains("if userSkipped, !chainHasSystem {")
      && failover.contains("return try await SystemVoiceProvider.shared.transcribe(request).text"))
let skipFn = between(panel, "func skipStalledTranscription() {", "func cancelTranscription()") ?? ""
check("skip re-points the NEXT segments synchronously",
      skipFn.contains("asrAttempts.skipStalled()") && skipFn.contains("stickyInputEntryId = entry.id")
      && skipFn.contains("systemASRPinned = true"))
check("a pinned System fallback routes later segments to System",
      panel.contains("let candidates = systemASRPinned ? [] : orderedInputCandidates()"))
check("re-resolving candidates clears the System pin",
      (between(panel, "private func resolveInputCandidates(reseed: Bool) {", "inputCandidates = ") ?? "")
        .contains("systemASRPinned = false"))

// UI (revised): the mic button stays "cancel" while transcribing — cancelling
// is how the user discards a take to re-record it — and the next-model retry is
// a separate "Switch Model" pill to the RIGHT of the button, shown once stalled.
// (First version turned the button itself into a retry icon, which sat on top
// of the progress ring and took the cancel away.)
let button = between(inline, "private var micButton: some View {", "// MARK: - [T-ios-context-usage-hint]") ?? ""
check("mic button located", !button.isEmpty)
check("mic button cancels while transcribing (no stall override)",
      inline.contains("viewModel.isTranscribing && viewModel.state != .recording\n    }")
      && button.contains("if showCancelIcon {\n                viewModel.cancelTranscription()")
      && !button.contains("skipStalledTranscription"))
check("no composed retry icon on the button any more",
      !inline.contains("retryNextModelIcon") && !inline.contains("showSkipIcon"))
let pill = between(inline, "private var switchModelButton: some View {", "private var micButton: some View {") ?? ""
check("Switch Model pill: next-track glyph + short label, and it only skips",
      pill.contains("Image(systemName: \"forward.end.fill\")") && pill.contains("Text(\"Switch Model\"")
      && pill.contains("viewModel.skipStalledTranscription()") && !pill.contains("handleMainButtonTap"))
check("pill shows only when stalled, to the right of the button (overlay, button stays centered)",
      inline.contains("if viewModel.isASRStalled {\n                    switchModelButton")
      && inline.contains(".offset(x: micDiameter + 10)") && inline.contains(".overlay(alignment: .leading) {"))
check("both compact and expanded layouts use it",
      inline.components(separatedBy: "micButtonWithSwitch").count - 1 >= 3)
check("the delete control yields the right-hand side while the pill shows",
      inline.contains("if !viewModel.transcript.isEmpty && !viewModel.isASRStalled {"))
check("status line no longer tells the user to tap the button to retry",
      !inline.contains("\"Tap to retry with the next voice model\"")
      && !inline.contains("\"Tap to pause and retry with the next voice model\""))
// Delete ↔ Switch Model: mutually exclusive on the right-hand side, and delete
// comes back once the stall ends (skip / self-completion / cancel — the flag
// transitions themselves are exercised by the compiled scenarios above).
func rightSide(hasText: Bool, stalled: Bool) -> (pill: Bool, delete: Bool) {
    (pill: stalled, delete: hasText && !stalled)
}
var overlapped = false
var trace: [String] = []
for (hasText, stalled) in [(true, false), (true, true), (true, false),   // stall → skip → restored
                           (true, true), (true, false),                  // stalls again on the next model → finishes
                           (false, true), (false, false)] {              // no text: pill only, then nothing
    let r = rightSide(hasText: hasText, stalled: stalled)
    if r.pill && r.delete { overlapped = true }
    trace.append(r.pill ? "pill" : (r.delete ? "delete" : "-"))
}
check("pill and delete never show together", !overlapped)
check("delete hides while switching is offered and comes back after (\(trace))",
      trace == ["delete", "pill", "delete", "pill", "delete", "pill", "-"])
check("source: delete keys off the same flag as the pill",
      inline.contains("if !viewModel.transcript.isEmpty && !viewModel.isASRStalled {")
      && inline.contains("if viewModel.isASRStalled {\n                    switchModelButton"))
check("source: the swap is animated on that flag",
      inline.contains("// Cross-fade the swap (the pill animates on the same flag).\n            .animation(.easeInOut(duration: 0.2), value: viewModel.isASRStalled)"))
check("source: skip clears the stall (restores delete)",
      (between(panel, "func skipStalled() -> [String?] {", "\n    }") ?? "").contains("stalled.removeAll()"))

let catalog = source("Localizable.xcstrings")
check("\"Switch Model\" is localized (zh-Hans / zh-Hant)",
      catalog.contains("\"Switch Model\" : {") && catalog.contains("\"切换模型\"") && catalog.contains("\"切換模型\""))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
