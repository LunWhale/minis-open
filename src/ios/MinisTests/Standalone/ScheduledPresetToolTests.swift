// [T-scheduled-preset-tool] A scheduled task may carry a preset first step
// (`minis-scheduled create … --command "<sh>"`, alias `--shell`). When the task fires, that
// tool call is run in place of the model's first request, and the model gets
// its real output as a normal tool_use + tool_result, so one model request per
// fire is saved.
//
//   A. ScheduledPresetToolCall.swift, compiled as shipped and exercised:
//      CLI parsing and validation, the arguments handed to shell_execute, the
//      tool_use id format, the envelope note, and which pending presets
//      belong to the turn about to be requested.
//   B. Source wiring:
//      - the agent loop asks `takePresetToolStream` before the provider;
//      - the preset is matched by its own envelope and consumed;
//      - an undeclared tool is skipped;
//      - rejection restores what was pending;
//      - the runner passes the preset on every target except rerun;
//      - envelopes without a preset are unchanged;
//      - the CLI exposes the flags.
//
// Standalone: `swift ScheduledPresetToolTests.swift` (needs swiftc).

import Foundation

/// The sources that used to be the single file Agent/Chat/AIChatViewModel.swift -
/// the class body plus the AIChatViewModel+<Concern>.swift files it was split
/// into (the older extension files are NOT included) - read as one text.
func chatViewModelSource() -> String {
    let chat = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Agent/Chat")
    let names = ["AIChatViewModel", "AIChatViewModel+Lifecycle", "AIChatViewModel+ContextUsage",
                 "AIChatViewModel+StreamingUI", "AIChatViewModel+Speech", "AIChatViewModel+AutoPlayAudio",
                 "AIChatViewModel+SystemPrompt", "AIChatViewModel+Send", "AIChatViewModel+Rerun",
                 "AIChatViewModel+EditMessage", "AIChatViewModel+Cancel", "AIChatViewModel+PromptQueue",
                 "AIChatViewModel+DebugDumps", "AIChatViewModel+TurnCompletion", "AIChatViewModel+AgentLoop",
                 "AIChatViewModel+ThinkingLevel", "LLMProviderError"]
    return names.compactMap { try? String(contentsOf: chat.appendingPathComponent($0 + ".swift"), encoding: .utf8) }
        .joined(separator: "\n")
}

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

let model = source("Agent/Jobs/ScheduledPresetToolCall.swift")
let loop = chatViewModelSource()
let submit = source("Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift")
let runner = source("Agent/Jobs/ScheduledJobRunner.swift")
let bridge = source("NativeOffloads/ScheduledOffloadBridge.swift")
let cli = source("NativeOffloads/ScheduledOffload.m")
let registry = source("Agent/Jobs/AgentJobRegistry.swift")
let pbx = source("Minis.xcodeproj/project.pbxproj")

// MARK: - A. The shipping model, compiled

print("A. ScheduledPresetToolCall (compiled as shipped)")
let harness = model + #"""

var hFailures = 0
func t(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { hFailures += 1 }
}
typealias P = ScheduledPresetToolCall
func parse(_ command: String? = nil, _ timeout: Double? = nil, tool: String? = nil, args: String? = nil) -> Result<P?, P.PresetError> {
    P.fromCLI(command: command, timeoutSeconds: timeout, tool: tool, toolArgs: args)
}
func isErr(_ r: Result<P?, P.PresetError>, containing s: String) -> Bool {
    if case .failure(let e) = r { return e.message.contains(s) }
    return false
}

// No preset flag → no preset (old jobs / old callers unchanged).
if case .success(let p) = parse() { t("no flags → nil preset", p == nil) } else { t("no flags → nil preset", false) }

// --command
if case .success(let p?) = parse("curl -s wttr.in") {
    t("--command → shell_execute", p.toolName == "shell_execute" && p.kind == .shell(command: "curl -s wttr.in", timeoutSeconds: nil))
} else { t("--command → shell_execute", false) }
if case .success(let p?) = parse("date", 120) {
    t("--command-timeout carried as whole seconds", p.kind == .shell(command: "date", timeoutSeconds: 120))
} else { t("--command-timeout carried", false) }

// Validation
t("empty command rejected", isErr(parse("   "), containing: "needs a shell command"))
t("over-long command rejected", isErr(parse(String(repeating: "x", count: P.maxCommandLength + 1)), containing: "longer than"))
t("command at the length cap accepted", { if case .success(.some) = parse(String(repeating: "x", count: P.maxCommandLength)) { return true }; return false }())
t("timeout 0 rejected", isErr(parse("date", 0), containing: "between 1s and 1h"))
t("timeout > 1h rejected", isErr(parse("date", 3601), containing: "between 1s and 1h"))
// [T-scheduled-duration-finite] Int(Double) traps on these — must be a clean error, not a crash.
t("timeout inf rejected (no trap)", isErr(parse("date", .infinity), containing: "between 1s and 1h"))
t("timeout nan rejected (no trap)", isErr(parse("date", .nan), containing: "between 1s and 1h"))
t("timeout 1e20 rejected (no trap)", isErr(parse("date", 1e20), containing: "between 1s and 1h"))
t("timeout -inf rejected (no trap)", isErr(parse("date", -.infinity), containing: "between 1s and 1h"))
t("--tool-args huge timeout rejected", isErr(parse(args: #"{"command":"ls","timeout":1e20}"#), containing: "between 1s and 1h"))
t("timeout without a command rejected", isErr(parse(nil, 60), containing: "needs a shell command"))
t("--command with --tool-args rejected", isErr(parse("date", args: #"{"command":"ls"}"#), containing: "not both"))
t("unsupported tool rejected with guidance", isErr(parse("x", tool: "file_read"), containing: "only shell_execute"))
for alias in ["shell", "SH", "bash", "shell_execute"] {
    if case .success(let p?) = parse("date", tool: alias) { t("--tool \(alias) accepted", p.toolName == "shell_execute") }
    else { t("--tool \(alias) accepted", false) }
}

// --tool-args JSON form
if case .success(let p?) = parse(tool: "shell_execute", args: #"{"command":"uptime","timeout":30}"#) {
    t("--tool-args JSON parsed", p.kind == .shell(command: "uptime", timeoutSeconds: 30))
} else { t("--tool-args JSON parsed", false) }
if case .success(let p?) = parse(nil, 45, args: #"{"command":"uptime","timeout":30}"#) {
    t("--command-timeout wins over tool-args timeout", p.kind == .shell(command: "uptime", timeoutSeconds: 45))
} else { t("--command-timeout wins", false) }
t("--tool-args not JSON rejected", isErr(parse(args: "command=ls"), containing: "JSON object"))
t("--tool-args JSON array rejected", isErr(parse(args: #"["ls"]"#), containing: "JSON object"))
t("--tool-args unknown key rejected", isErr(parse(args: #"{"command":"ls","cwd":"/"}"#), containing: "cwd"))
t("--tool-args without command rejected", isErr(parse(args: #"{"timeout":3}"#), containing: "\"command\""))
t("--tool-args boolean timeout rejected", isErr(parse(args: #"{"command":"ls","timeout":true}"#), containing: "number of seconds"))

// Arguments handed to shell_execute: exactly what a model sends.
let shell = P(kind: .shell(command: "curl -s x", timeoutSeconds: 90))
let args = shell.toolArguments(title: "Weather")
t("args carry tool_title (required by shell_execute)", args["tool_title"] as? String == "Weather")
t("args carry command", args["command"] as? String == "curl -s x")
t("timeout is an NSNumber (the executor reads NSNumber)", (args["timeout"] as? NSNumber)?.intValue == 90)
t("no timeout key when unset", P(kind: .shell(command: "a", timeoutSeconds: nil)).toolArguments(title: "t")["timeout"] == nil)
t("summary for `list`", (shell.summary["tool"] as? String) == "shell_execute" && (shell.summary["command"] as? String) == "curl -s x")

// tool_use id: valid for Anthropic's ^[a-zA-Z0-9_-]+$, unique.
let ids = (0..<200).map { _ in P.makeToolUseId() }
let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
t("tool_use ids match ^[a-zA-Z0-9_-]+$", ids.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
t("tool_use ids are unique", Set(ids).count == ids.count)

// Envelope note names the tool and says not to re-run blindly.
t("envelope note names the tool", shell.envelopeNote.contains("shell_execute") && shell.envelopeNote.hasSuffix("]\n"))

// Codable round trip (future persistence).
let data = try! JSONEncoder().encode(shell)
t("Codable round trip", (try? JSONDecoder().decode(P.self, from: data)) == shell)

// Which pending presets run now.
func jobOf(_ text: String) -> String? {
    guard text.hasPrefix("<agent_callback "), text.contains(#"kind="scheduled""#),
          let r = text.range(of: #"job=""#) else { return nil }
    let rest = text[r.upperBound...]
    return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
}
let envA = #"<agent_callback kind="scheduled" job="A" title="x" status="running"><prompt>p</prompt></agent_callback>"#
let envB = #"<agent_callback kind="scheduled" job="B" title="y" status="running"><prompt>q</prompt></agent_callback>"#
let finishedA = #"<agent_callback kind="finished" job="A" title="x" status="done"></agent_callback>"#
t("own envelope in the tail → runs", P.jobIdsToRun(trailingUserTexts: [envA], pending: ["A"], scheduledJobId: jobOf) == ["A"])
t("user's own typed turn → nothing runs", P.jobIdsToRun(trailingUserTexts: ["hello"], pending: ["A"], scheduledJobId: jobOf).isEmpty)
t("another job's envelope → nothing runs", P.jobIdsToRun(trailingUserTexts: [envB], pending: ["A"], scheduledJobId: jobOf).isEmpty)
t("non-scheduled callback for the same job → nothing runs", P.jobIdsToRun(trailingUserTexts: [finishedA], pending: ["A"], scheduledJobId: jobOf).isEmpty)
t("batched queue (two fires) → both, in order", P.jobIdsToRun(trailingUserTexts: [envB, "note", envA], pending: ["A", "B"], scheduledJobId: jobOf) == ["B", "A"])
t("same job twice in one batch → one run", P.jobIdsToRun(trailingUserTexts: [envA, envA], pending: ["A"], scheduledJobId: jobOf) == ["A"])
t("nothing pending → nothing runs", P.jobIdsToRun(trailingUserTexts: [envA], pending: [], scheduledJobId: jobOf).isEmpty)

print("HARNESS failures=\(hFailures)")
exit(hFailures == 0 ? 0 : 1)
"""#

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("presettool-\(UUID().uuidString)")
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
    check("ScheduledPresetToolCall.swift compiles standalone", cc == 0)
    if cc != 0 { print(ccOut) }
    let (rc, out) = run(bin.path, [])
    print(out, terminator: "")
    check("model scenarios all pass", rc == 0 && out.contains("HARNESS failures=0"))
} catch {
    check("harness setup: \(error)", false)
}

// MARK: - B. Source wiring

print("B. Wiring")

// Agent loop: the preset stream is asked for first, the provider only otherwise.
let site = between(loop, "let stream: AsyncThrowingStream<AgentStreamEvent, Error>", "noteEffectiveEntry(activeEntryId)") ?? ""
check("loop asks takePresetToolStream before the provider",
      site.contains("if let preset = takePresetToolStream(tools: tools)") && site.contains("stream = preset")
      && site.contains("} else {") && site.contains("stream = try await streamWithGroupFallback("))
check("provider call is the else branch (no model request when a preset runs)",
      (site.range(of: "takePresetToolStream")?.lowerBound ?? site.endIndex) < (site.range(of: "streamWithGroupFallback")?.lowerBound ?? site.startIndex))
check("the loop has exactly one provider-stream call site wrapped", loop.components(separatedBy: "let stream = try await streamWithGroupFallback(").count == 1)

// The synthetic stream.
let take = between(submit, "func takePresetToolStream(", "\n    }\n}") ?? ""
check("scans only the trailing user messages (stops at the last assistant)",
      take.contains("for message in agentHistory.reversed()") && take.contains("guard message.role == .user else { break }"))
check("matches by the scheduled envelope's job id",
      take.contains("AgentCallback.parse(") && take.contains("callback.kind == .scheduled") && take.contains("return callback.jobId"))
check("consumes the preset (removeValue)", take.contains("pendingPresetToolCalls.removeValue(forKey: jobId)"))
check("skips a tool this turn does not declare", take.contains("tools.contains(where: { $0.name == name })"))
check("emits tool_use start + complete + stop_reason tool_use",
      take.contains(".contentBlockStart(.toolUse(id: call.id, name: call.name))")
      && take.contains(".toolCallComplete(id: call.id, name: call.name, args: call.args, metadata: nil)")
      && take.contains(".done(stopReason: .toolUse)") && take.contains("continuation.finish()"))

// Registration on submit.
check("submitProgrammaticPrompt takes an optional preset (defaults nil)",
      submit.contains("presetToolCall: ScheduledPresetToolCallRequest? = nil,\n                                  bypassContextPrompt: Bool = false) -> ProgrammaticSubmitOutcome"))
let regIdx = submit.range(of: "pendingPresetToolCalls[preset.jobId] = preset")?.lowerBound
let busyIdx = submit.range(of: "        if isProcessing {\n            // Busy: hand to the queue.")?.lowerBound
check("preset registered before the send/queue hand-off", regIdx != nil && busyIdx != nil && regIdx! < busyIdx!)
check("both post-registration rejections undo it",
      submit.components(separatedBy: "undoPresetRegistration()\n").count - 1 == 2
      && submit.contains("pendingPresetToolCalls[preset.jobId] = displacedPreset"))

// Runner.
check("runner passes the preset on new / follow-up / child-of-current",
      runner.components(separatedBy: "presetToolCall: presetFor(job))").count - 1 == 3)
check("rerun target does not get a preset (bridge refuses it)",
      bridge.contains("if presetToolCall != nil, case .rerun = target {"))
check("envelope body unchanged without a preset",
      runner.contains(#"body: roundPrefix(job) + (job.presetToolCall?.envelopeNote ?? "") + prompt,"#))
check("card title comes from the job label/title", runner.contains("title: job.label ?? job.title)"))

// Registry / CLI.
check("AgentJob.presetToolCall defaults nil", registry.contains("var presetToolCall: ScheduledPresetToolCall?\n"))
check("list shows prefillTool (Android key) only when set", registry.contains(#"if let preset = job.presetToolCall { d["prefillTool"] = preset.summary }"#))
for flag in ["--shell", "--command", "--shell-timeout", "--command-timeout", "--tool", "--tool-args"] {
    check("CLI reads \(flag)", cli.contains("arg(argc, argv, \"\(flag)\")"))
}
check("CLI help documents the prefill", cli.contains("PREFILLED TOOL CALL (--command, alias --shell)"))
check("system prompt teaches --command / --tool-args",
      loop.contains("add `--command \\\"<shell command>\\\"` (or the general `--tool shell_execute --tool-args"))
check("bridge validates through ScheduledPresetToolCall.fromCLI", bridge.contains("ScheduledPresetToolCall.fromCLI("))
// [T-scheduled-duration-finite] parseDuration feeds --after / --interval / --command-timeout.
let jobRunner = source("Agent/Jobs/ScheduledJobRunner.swift")
check("parseDuration rejects inf / nan", jobRunner.contains("guard let n = Double(numPart), n.isFinite, n >= 0 else { return nil }"))
check("parseDuration rejects overflowing units and > 10 years",
      jobRunner.contains("guard seconds.isFinite, seconds <= maxDurationSeconds else { return nil }"))
check("new file is in the app target (build file, file ref, group, Sources phase)",
      pbx.split(separator: "\n").filter { $0.contains("ScheduledPresetToolCall.swift") }.count == 4
      && pbx.contains("E5SPT0001 /* ScheduledPresetToolCall.swift in Sources */,"))

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
