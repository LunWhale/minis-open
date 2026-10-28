#!/usr/bin/env swift
// [T-sse-idle-timeout] Per-provider response idle timeout, and hidden
// reasoning counting as stream activity.
//
// Report: an OpenAI-compatible local provider (a 27B model on a desktop
// server) failed with "No response from the server for 120 seconds — the
// stream stalled mid-generation" while it was prefilling a large context or
// reasoning with the thinking level off. Two causes:
//   * the stall watchdog only sees the events the provider's parser emits,
//     and with thinking off the Chat Completions parser emitted nothing for
//     reasoning chunks - a model reasoning for two minutes looked dead;
//   * a server that is prefilling really does send nothing, and 120 s was
//     not configurable.
//
//   [1] the shipping ResponseIdleTimeoutSetting (default 120, clamp, storage,
//       transport timeout) against a private UserDefaults suite
//   [2] the shipping deltaCarriesReasoning rule: what counts as activity
//   [3] the shipping StreamStallWatchdog driven by mock SSE timelines with a
//       scaled clock: silence up to the configured timeout, reasoning-only
//       chunks, keepalive comments only, a stream that dies, the default
//   [4] source guards: who reads the setting and who must not
//   [5] localization
//
// Run: swift SSEIdleTimeoutTests.swift   (needs swiftc)
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

let agentProvider = source("Providers/AgentProvider.swift")
let openaiAgent = source("Providers/OpenAI/OpenAIAgentProvider.swift")
let openaiProvider = source("Providers/OpenAI/OpenAIProvider.swift")
let sse = source("Agent/Chat/AIChatViewModel+SSEStream.swift")
let detail = source("Views/Providers/ProviderInstanceDetailView.swift")
let strings = source("Localizable.xcstrings")

guard let settingBlock = between(agentProvider, "// BEGIN ResponseIdleTimeoutSetting", "// END ResponseIdleTimeoutSetting"),
      let activityBlock = between(openaiAgent, "// BEGIN ChatCompletionsReasoningActivity", "// END ChatCompletionsReasoningActivity"),
      let watchdogBlock = between(sse, "private final class StreamStallWatchdog", "// MARK: - Background SSE Stream Processing") else {
    print("❌ a shipping block was not found"); exit(1)
}

let shipped = """
import Foundation
\(settingBlock)
enum Shipped {
\(activityBlock)
}
final class StreamStallWatchdog\(watchdogBlock)
"""

let harness = #"""
import Foundation

// ---- [1] setting ----
let suite = "sse-idle-test-\(UUID().uuidString)"
let d = UserDefaults(suiteName: suite)!
func eff(_ id: String?) -> Int { ResponseIdleTimeoutSetting.seconds(forInstanceId: id, defaults: d) }
print("R set.unset=\(eff("p1"))")
print("R set.nilId=\(eff(nil))")
ResponseIdleTimeoutSetting.set(300, forInstanceId: "p1", defaults: d)
print("R set.300=\(eff("p1")) set.otherUntouched=\(eff("p2"))")
ResponseIdleTimeoutSetting.set(3600, forInstanceId: "p1", defaults: d); print("R set.3600=\(eff("p1"))")
ResponseIdleTimeoutSetting.set(999_999, forInstanceId: "p1", defaults: d); print("R set.huge=\(eff("p1"))")
ResponseIdleTimeoutSetting.set(0, forInstanceId: "p1", defaults: d); print("R set.zero=\(eff("p1"))")
ResponseIdleTimeoutSetting.set(-5, forInstanceId: "p1", defaults: d); print("R set.negative=\(eff("p1"))")
d.set(0, forKey: ResponseIdleTimeoutSetting.key(forInstanceId: "p1")); print("R set.rawZeroStored=\(eff("p1"))")
d.set("abc", forKey: ResponseIdleTimeoutSetting.key(forInstanceId: "p1")); print("R set.garbageStored=\(eff("p1"))")
ResponseIdleTimeoutSetting.set(120, forInstanceId: "p1", defaults: d)
print("R set.defaultRemovesKey=\(d.object(forKey: ResponseIdleTimeoutSetting.key(forInstanceId: "p1")) == nil)")
ResponseIdleTimeoutSetting.set(600, forInstanceId: "p1", defaults: d); ResponseIdleTimeoutSetting.set(nil, forInstanceId: "p1", defaults: d)
print("R set.nilResets=\(eff("p1"))")
print("R req.120=\(String(describing: ResponseIdleTimeoutSetting.requestTimeout(forIdleSeconds: 120)))")
print("R req.600=\(String(describing: ResponseIdleTimeoutSetting.requestTimeout(forIdleSeconds: 600)))")
print("R req.1800=\(String(describing: ResponseIdleTimeoutSetting.requestTimeout(forIdleSeconds: 1800)))")
print("R presets=\(ResponseIdleTimeoutSetting.presets.map(String.init).joined(separator: ","))")
print("R bounds=\(ResponseIdleTimeoutSetting.minSeconds)-\(ResponseIdleTimeoutSetting.maxSeconds)")
d.removePersistentDomain(forName: suite)

// ---- [2] what counts as activity ----
func delta(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
}
func act(_ json: String, field: String? = nil) -> Bool { Shipped.deltaCarriesReasoning(delta(json), interleavedField: field) }
print("R act.reasoning_content=\(act(#"{"reasoning_content":"thinking"}"#))")
print("R act.reasoning=\(act(#"{"reasoning":"thinking"}"#))")
print("R act.reasoning_text=\(act(#"{"reasoning_text":"thinking"}"#))")
print("R act.details.text=\(act(#"{"reasoning_details":[{"type":"reasoning.text","text":"t"}]}"#))")
print("R act.details.summary=\(act(#"{"reasoning_details":[{"type":"reasoning.summary","summary":"s"}]}"#))")
print("R act.details.encrypted=\(act(#"{"reasoning_details":[{"type":"reasoning.encrypted","data":"AAAA"}]}"#))")
print("R act.interleaved=\(act(#"{"thought":"t"}"#, field: "thought"))")
print("R act.interleavedNotConfigured=\(act(#"{"thought":"t"}"#))")
print("R act.emptyString=\(act(#"{"reasoning_content":""}"#))")
print("R act.null=\(act(#"{"reasoning_content":null,"content":null}"#))")
print("R act.roleOnly=\(act(#"{"role":"assistant"}"#))")
print("R act.emptyDelta=\(act("{}"))")
print("R act.emptyContent=\(act(#"{"content":""}"#))")
print("R act.details.empty=\(act(#"{"reasoning_details":[]}"#))")
print("R act.details.emptyEncrypted=\(act(#"{"reasoning_details":[{"type":"reasoning.encrypted","data":""}]}"#))")
print("R act.details.unknownType=\(act(#"{"reasoning_details":[{"type":"other","text":"x"}]}"#))")
print("R act.contentOnly=\(act(#"{"content":"visible"}"#))")

// ---- [3] the watchdog over mock SSE timelines (scaled clock) ----
// One wire line = (seconds after stream open, raw SSE line). The mini parser
// below turns a line into "an event reached the agent loop" the way the Chat
// Completions parser does with the thinking level OFF: visible content, tool
// calls, usage and finish always do; reasoning does only through the
// shipping deltaCarriesReasoning rule; comments / keepalives / empty chunks
// never do.
func reachesLoop(_ line: String) -> Bool {
    guard line.hasPrefix("data:") else { return false }               // ": keepalive", blank
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" { return true }
    guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return false }
    if obj["usage"] != nil { return true }
    guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return false }
    let dl = choice["delta"] as? [String: Any] ?? [:]
    if let c = dl["content"] as? String, !c.isEmpty { return true }
    if dl["tool_calls"] != nil { return true }
    if let fr = choice["finish_reason"] as? String, !fr.isEmpty { return true }
    return Shipped.deltaCarriesReasoning(dl, interleavedField: nil)
}
func chunk(_ deltaJSON: String, finish: String? = nil) -> String {
    "data: {\"choices\":[{\"index\":0,\"delta\":\(deltaJSON),\"finish_reason\":\(finish.map { "\"\($0)\"" } ?? "null")}]}"
}
struct Outcome { var stalled: Bool; var message = ""; var events = 0; var elapsed = 0.0 }
/// `scale`: real seconds per simulated second. The tick loop is the one in
/// processStreamEvents (compare wall-clock wait against the timeout, fire with
/// the same message), with its 1 s tick scaled.
func play(_ timeline: [(Double, String)], timeoutSeconds: Int, scale: Double = 0.004, closeAt: Double? = nil) async -> Outcome {
    let (stream, cont) = AsyncStream<Void>.makeStream()
    let feeder = Task {
        var last = 0.0
        for (at, line) in timeline {
            try? await Task.sleep(nanoseconds: UInt64(max(0, at - last) * scale * 1e9)); last = at
            if Task.isCancelled { return }
            if reachesLoop(line) { cont.yield(()) }
        }
        if let closeAt {
            try? await Task.sleep(nanoseconds: UInt64(max(0, closeAt - last) * scale * 1e9))
            cont.finish()
        }
    }
    let wd = StreamStallWatchdog()
    let timeout = Double(timeoutSeconds) * scale
    let tick = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(scale * 1e9))          // the 1 s tick
            guard !Task.isCancelled, let start = wd.waitStart else { continue }
            guard Date().timeIntervalSince(start) >= timeout else { continue }
            wd.fire(NSError(domain: "stall", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No response from the server for \(timeoutSeconds) seconds — the stream stalled mid-generation"]))
            return
        }
    }
    defer { tick.cancel(); feeder.cancel() }
    final class Box: @unchecked Sendable { var it: AsyncStream<Void>.AsyncIterator; init(_ s: AsyncStream<Void>) { it = s.makeAsyncIterator() }
        func next() async -> Void? { await it.next() } }
    let box = Box(stream)
    var out = Outcome(stalled: false)
    let t0 = Date()
    do {
        while true {
            wd.beginWait(at: Date())
            let got: Bool = try await withThrowingTaskGroup(of: Bool.self) { g in
                g.addTask { await box.next() != nil }
                g.addTask { try await wd.wait(); return false }
                let r = try await g.next()!; g.cancelAll(); return r
            }
            wd.endWait()
            if !got { break }
            out.events += 1
        }
    } catch {
        out.stalled = true; out.message = error.localizedDescription
    }
    out.elapsed = Date().timeIntervalSince(t0) / scale
    return out
}
func show(_ tag: String, _ o: Outcome) {
    print("R \(tag).stalled=\(o.stalled)"); print("R \(tag).events=\(o.events)")
    print("R \(tag).elapsed=\(Int(o.elapsed.rounded()))"); print("R \(tag).message=\(o.message)")
}
let reasoning = chunk(#"{"reasoning_content":"still thinking"}"#)
let text = chunk(#"{"content":"hello"}"#)
let done = chunk("{}", finish: "stop")

// A. total silence: prefill that never ends. Default 120.
show("silent120", await play([], timeoutSeconds: ResponseIdleTimeoutSetting.defaultSeconds))
// B. total silence with the provider set to 300.
show("silent300", await play([], timeoutSeconds: 300))
// C. prefill for 250 s, then the reply: fails at 120, passes at 300.
let prefill: [(Double, String)] = [(250, text), (252, text), (254, done)]
show("prefill120", await play(prefill, timeoutSeconds: 120, closeAt: 255))
show("prefill300", await play(prefill, timeoutSeconds: 300, closeAt: 255))
// D. reasoning-only chunks every 30 s for 400 s, thinking OFF, default 120:
//    each one is activity, so 400 s of reasoning never stalls.
var hidden: [(Double, String)] = stride(from: 30.0, through: 390.0, by: 30.0).map { ($0, reasoning) }
hidden += [(400, text), (402, done)]
show("hiddenReasoning120", await play(hidden, timeoutSeconds: 120, closeAt: 403))
// E. keepalive comments and empty chunks every 20 s, nothing real: still a stall at 120.
let junk: [(Double, String)] = stride(from: 20.0, through: 400.0, by: 20.0).flatMap {
    [($0, ": keepalive"), ($0 + 1, chunk("{}")), ($0 + 2, chunk(#"{"role":"assistant","content":""}"#)), ($0 + 3, chunk(#"{"reasoning_content":""}"#))]
}
show("keepaliveOnly120", await play(junk, timeoutSeconds: 120))
// F. a real reply that dies: text for 60 s, then nothing. Stalls 300 s after the last chunk.
let dies: [(Double, String)] = stride(from: 5.0, through: 60.0, by: 5.0).map { ($0, text) }
show("diesMidway300", await play(dies, timeoutSeconds: 300))
// G. steady output for 500 s with a 120 s timeout: total time is not what is limited.
var steady: [(Double, String)] = stride(from: 10.0, through: 490.0, by: 20.0).map { ($0, text) }
steady.append((500, done))
show("steady500", await play(steady, timeoutSeconds: 120, closeAt: 501))
"""#

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sse-idle-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let files = ["Shipped.swift": shipped, "main.swift": harness]
for (n, c) in files { try? c.write(to: tmp.appendingPathComponent(n), atomically: true, encoding: .utf8) }
let bin = tmp.appendingPathComponent("t").path
let (cc, ccOut) = run("/usr/bin/xcrun", ["swiftc", "-swift-version", "5"]
    + files.keys.sorted().map { tmp.appendingPathComponent($0).path } + ["-o", bin])
print("0. The shipping blocks compile standalone")
check("ResponseIdleTimeoutSetting + deltaCarriesReasoning + StreamStallWatchdog compile on their own", cc == 0)
if cc != 0 { print(ccOut); print("\n❌ FAILED"); exit(1) }
let (_, out) = run(bin, [])
var r: [String: String] = [:]
for line in out.split(separator: "\n") where line.hasPrefix("R ") {
    let body = String(line.dropFirst(2))
    if body.hasPrefix("set.300=") {
        for kv in body.split(separator: " ") {
            let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { r[p[0]] = p[1] }
        }
    } else if let eq = body.firstIndex(of: "=") {
        r[String(body[..<eq])] = String(body[body.index(after: eq)...])
    }
}
func num(_ k: String) -> Int { Int(r[k] ?? "") ?? -1 }

print("\n1. The setting")
check("nothing stored -> 120 (existing providers unchanged)", r["set.unset"] == "120" && r["set.nilId"] == "120")
check("300 stored for one provider -> 300 for it, 120 for every other", r["set.300"] == "300" && r["set.otherUntouched"] == "120")
check("3600 is accepted; anything larger is clamped to 3600 (no 'never')", r["set.3600"] == "3600" && r["set.huge"] == "3600")
check("0 and negative are clamped up to 30, never 'no timeout'", r["set.zero"] == "30" && r["set.negative"] == "30")
check("a raw 0 in storage still reads as 30; a non-number reads as the default", r["set.rawZeroStored"] == "30" && r["set.garbageStored"] == "120")
check("choosing the default removes the stored value; nil resets", r["set.defaultRemovesKey"] == "true" && r["set.nilResets"] == "120")
check("presets 120 / 300 / 600 / 1800 / 3600, range 30-3600", r["presets"] == "120,300,600,1800,3600" && r["bounds"] == "30-3600")
check("the transport timeout is left alone up to 600 s and raised above it", r["req.120"] == "nil" && r["req.600"] == "nil" && r["req.1800"] == "Optional(1830.0)")

print("\n2. What counts as activity while reasoning is hidden")
for k in ["reasoning_content", "reasoning", "reasoning_text", "details.text", "details.summary", "details.encrypted", "interleaved"] {
    check("counts: \(k)", r["act.\(k)"] == "true")
}
for k in ["emptyString", "null", "roleOnly", "emptyDelta", "emptyContent", "details.empty", "details.emptyEncrypted",
          "details.unknownType", "interleavedNotConfigured"] {
    check("does not count: \(k)", r["act.\(k)"] == "false")
}
check("visible content is not this rule's business (it already produces its own event)", r["act.contentOnly"] == "false")

print("\n3. Mock SSE timelines through the shipping watchdog")
check("total silence, default: stalls at ~120 s with '120 seconds' in the error",
      r["silent120.stalled"] == "true" && (118...135).contains(num("silent120.elapsed")) && r["silent120.message"]?.contains("for 120 seconds") == true)
check("total silence, provider set to 300: stalls at ~300 s, error says 300",
      r["silent300.stalled"] == "true" && (298...320).contains(num("silent300.elapsed")) && r["silent300.message"]?.contains("for 300 seconds") == true)
check("250 s prefill then a reply: fails at the default 120", r["prefill120.stalled"] == "true" && num("prefill120.events") == 0)
check("250 s prefill then a reply: completes with the provider set to 300", r["prefill300.stalled"] == "false" && num("prefill300.events") == 3)
check("reasoning-only chunks for 400 s with thinking OFF: never stalls at the default 120",
      r["hiddenReasoning120.stalled"] == "false" && num("hiddenReasoning120.events") == 15)
check("keepalive comments and empty chunks only: still a stall at 120 (junk cannot keep a dead stream alive)",
      r["keepaliveOnly120.stalled"] == "true" && num("keepaliveOnly120.events") == 0 && (118...135).contains(num("keepaliveOnly120.elapsed")))
check("a reply that dies after 60 s, provider at 300: stalls ~300 s after the last real chunk",
      r["diesMidway300.stalled"] == "true" && num("diesMidway300.events") == 12 && (355...385).contains(num("diesMidway300.elapsed")))
check("steady output for 500 s at the default 120: no stall - it is an idle limit, not a total",
      r["steady500.stalled"] == "false" && num("steady500.events") == 26)

print("\n4. Who reads the setting")
check("the watchdog takes its timeout from the provider, once per stream",
      sse.contains("let stallTimeoutSeconds: TimeInterval = provider.responseIdleTimeout") && !sse.contains("let stallTimeoutSeconds: TimeInterval = 120"))
check("the error still names the timeout that applied",
      sse.contains("\"No response from the server for \\(Int(stallTimeoutSeconds)) seconds — the stream stalled mid-generation\""))
check("the watchdog is still fed only by stream events (no reset from the tick or from rendering)",
      sse.components(separatedBy: "stallWatchdog.beginWait(at: Date())").count - 1 == 1
      && sse.components(separatedBy: "stallWatchdog.endWait()").count - 1 == 1)
check("every provider defaults to 120 through the protocol",
      agentProvider.contains("var responseIdleTimeout: TimeInterval { get }")
      && agentProvider.contains("var responseIdleTimeout: TimeInterval { TimeInterval(ResponseIdleTimeoutSetting.defaultSeconds) }"))
check("only OpenAIAgentProvider overrides it, and only on the Chat Completions path",
      openaiAgent.contains("guard provider.usesChatCompletionsAPI else { return TimeInterval(ResponseIdleTimeoutSetting.defaultSeconds) }")
      && openaiAgent.contains("ResponseIdleTimeoutSetting.seconds(forInstanceId: provider.providerInstanceId)"))
for f in ["Providers/Anthropic/AnthropicAgentProvider.swift", "Providers/Gemini/GeminiAgentProvider.swift",
          "Providers/Antigravity/AntigravityAgentProvider.swift"] {
    check("\(f.split(separator: "/").last!) does not read the setting", !source(f).contains("responseIdleTimeout") && !source(f).contains("ResponseIdleTimeoutSetting"))
}
check("hidden field reasoning is reported as activity only when thinking is off",
      openaiAgent.contains("if !thinkingLevel.isEnabled,\n                           Self.deltaCarriesReasoning(delta, interleavedField: self.model.interleavedReasoningField) {\n                            continuation.yield(.streamActivity)"))
check("hidden <think> text in content is reported as activity too",
      openaiAgent.contains("} else {\n                            // [T-sse-idle-timeout] Hidden <think> text is still output.\n                            continuation.yield(.streamActivity)"))
check("the activity event changes nothing in the transcript",
      sse.contains("case .streamActivity:\n                // [T-sse-idle-timeout]") && sse.contains("which is all it is for.\n                break"))
check("SSE comment / keepalive lines never reach the parser as data",
      openaiAgent.contains("guard line.hasPrefix(\"data:\") else { return nil }"))
check("the transport timeout is raised only for Chat Completions and only above 600 s",
      openaiProvider.contains("if !isResponsesAPI,\n           let longer = ResponseIdleTimeoutSetting.requestTimeout(")
      && openaiProvider.contains("request.timeoutInterval = longer"))
check("the settings row is shown for OpenAI-compatible providers only, not for Codex sign-in",
      detail.contains("if instance.providerType == .openAI\n                && !(instance.credentialType == .oauth && instance.effectiveCustomBaseURL == nil) {\n                responseIdleTimeoutSection(instance)"))
check("a custom value outside 30-3600 is not stored",
      detail.contains("typed >= ResponseIdleTimeoutSetting.minSeconds, typed <= ResponseIdleTimeoutSetting.maxSeconds else { return }"))
check("no ProviderInstance field, so no DB column / sync / backup change",
      !source("Providers/ProviderInstance.swift").contains("IdleTimeout") && !source("Providers/ProviderConfigDB.swift").contains("IdleTimeout"))

print("\n5. Localized")
func hasLocales(_ key: String) -> Bool {
    guard let r0 = strings.range(of: "    \"\(key)\" : {\n") else { return false }
    let tail = strings[r0.upperBound...]
    let entry = tail[..<(tail.range(of: "\n    },\n")?.lowerBound ?? tail.endIndex)]
    return entry.contains("\"zh-Hans\"") && entry.contains("\"zh-Hant\"")
}
for key in ["Response idle timeout", "2 minutes (default)", "30 minutes", "60 minutes", "Custom…", "Seconds (30–3600)"] {
    check("zh-Hans + zh-Hant: \(key)", hasLocales(key))
}
check("the footer says it is not a total-time limit, in English and Chinese",
      strings.contains("This is not a limit on total generation time") && strings.contains("这不是总生成时长的限制"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
