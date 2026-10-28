import XCTest
@testable import Minis

/// [T-ctx-trim-ladder] Watermarks and the trim ladder: every level, the stop
/// rule, freezing, collapse, small windows and the long single-turn agent run.
/// Mirrors Android `ContextTrimPlannerTest`.
///
/// Sizes use CJK characters (1 token each in ContextSizeMeter) so the numbers
/// in the assertions can be reasoned about.
final class ContextTrimPlannerTests: XCTestCase {

    private typealias P = ContextTrimPlanner

    private let fixed = 1_000
    private var measure: ([AgentMessage]) -> Int {
        let fixed = self.fixed
        return { ContextSizeMeter.estimateTokens($0, includeReasoning: true) + fixed }
    }

    /// Records offloads; returns a guest path like the real one.
    private final class FakeOffloader {
        var calls: [(id: String, name: String)] = []
        var fn: P.Offloader {
            { [self] _, toolId, toolName in
                calls.append((toolId, toolName))
                return "/var/minis/offloads/tools/\(toolName)_\(toolId).txt"
            }
        }
    }
    private func off() -> P.Offloader { FakeOffloader().fn }

    private func cjk(_ n: Int) -> String { String(repeating: "想", count: n) }
    private func res(_ n: Int) -> String { String(repeating: "结", count: n) }

    private func user(_ text: String, _ id: String) -> AgentMessage {
        var m = AgentMessage(role: .user, parts: [.text(text)])
        m.dbMessageId = id
        return m
    }

    /// One iteration: assistant (reasoning + one tool call) and its result carrier.
    private func iteration(_ i: Int, reasoning: Int = 0, result: Int = 50, arg: String? = nil,
                           tool: String = "shell_execute", image: Data? = nil,
                           readback: Bool = false) -> [AgentMessage] {
        let id = "call_\(i)"
        var input: [String: Any] = ["command": "echo \(i)", "tool_title": "step \(i)"]
        if let arg { input["content"] = arg }
        var asst = AgentMessage(role: .assistant, parts: [.toolUse(id: id, name: tool, input: input)])
        asst.dbMessageId = "a\(i)"
        asst.reasoningContent = reasoning > 0 ? cjk(reasoning) : nil
        var carrier = AgentMessage(role: .user, parts: [
            .toolResult(id: id, name: tool, content: res(result), isError: false, imageData: image,
                        imageMimeType: image == nil ? nil : "image/png", isOffloadReadback: readback),
        ])
        carrier.dbMessageId = "r\(i)"
        return [asst, carrier]
    }

    private func run(_ n: Int, reasoning: Int = 0, result: Int = 50) -> [AgentMessage] {
        [user("请把计划表写完", "u0")] + (0..<n).flatMap { iteration($0, reasoning: reasoning, result: result) }
    }

    private func reasoningOf(_ list: [AgentMessage]) -> [String?] {
        list.filter { $0.role == .assistant }.map(\.reasoningContent)
    }
    private func emptied(_ list: [AgentMessage]) -> [Bool] { reasoningOf(list).map { $0 == "" } }

    private struct Res: Equatable { let id: String, content: String, imageBytes: Int? }
    private func results(_ list: [AgentMessage]) -> [Res] {
        list.flatMap { $0.parts }.compactMap {
            if case .toolResult(let id, _, let content, _, let img, _, _, _, _) = $0 { return Res(id: id, content: content, imageBytes: img?.count) }
            return nil
        }
    }
    private struct Use { let id: String, name: String, input: [String: Any], offloaded: Bool }
    private func uses(_ list: [AgentMessage]) -> [Use] {
        list.flatMap { $0.parts }.compactMap {
            if case .toolUse(let id, let name, let input, let o) = $0 { return Use(id: id, name: name, input: input, offloaded: o) }
            return nil
        }
    }
    private func text(_ m: AgentMessage) -> String {
        m.parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }

    /// Byte-level view of a history.
    private func dump(_ list: [AgentMessage]) -> String {
        list.map { m in
            "\(m.role.rawValue)|\(m.dbMessageId ?? "-")|\(m.reasoningContent ?? "nil")|" + m.parts.map { p -> String in
                switch p {
                case .text(let t): return "T:\(t)"
                case .toolUse(let id, let name, let input, let o):
                    return "U:\(id):\(name):\(o):" + input.keys.sorted().map { "\($0)=\(input[$0]!)" }.joined(separator: ",")
                case .toolResult(let id, _, let content, _, let img, _, _, _, _): return "R:\(id):\(content):\(img?.count ?? -1)"
                case .imageData(let d, _, _): return "I:\(d.count)"
                }
            }.joined(separator: ";")
        }.joined(separator: "\n")
    }

    /// Every tool result has its call and vice versa; history starts with a user turn.
    private func assertWellFormed(_ list: [AgentMessage], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(list.first?.role, .user, file: file, line: line)
        XCTAssertEqual(Set(uses(list).map(\.id)), Set(results(list).map(\.id)), file: file, line: line)
    }

    private func opts(strip: Bool = true, floor: Int = 1, recent: Int = 3, collapse: Bool = false) -> P.Options {
        P.Options(stripReasoning: strip, reasoningFloor: floor, keepRecentIterations: recent, allowCollapse: collapse)
    }
    private func labels(_ steps: [String]) -> [String] { steps.map { String($0.split(separator: ":")[0]) } }
    private func levels(_ steps: [String]) -> [String] { steps.map { String($0.split(separator: "(")[0]) } }

    // MARK: - Watermarks

    func testWatermarksAreBasedOnTheUsableSpaceForEveryWindowSize() {
        let rows: [(window: Int, fixed: Int, hard: Int, usable: Int, trigger: Int, target: Int, mode: P.Mode)] = [
            (16_000, 21_000, 11_904, -9_096, 12_814, 16_452, .unusable),
            (16_000, 8_000, 11_904, 3_904, 11_513, 9_952, .tight),
            (32_000, 21_000, 27_200, 6_200, 26_580, 24_100, .tight),
            (32_000, 8_000, 27_200, 19_200, 25_280, 17_600, .normal),
            (64_000, 21_000, 54_400, 33_400, 51_060, 37_700, .normal),
            (128_000, 21_000, 111_616, 90_616, 102_554, 66_308, .normal),
            (1_000_000, 21_000, 983_616, 962_616, 887_354, 502_308, .normal),
        ]
        for r in rows {
            let w = P.watermarks(window: r.window, fixed: r.fixed, maxOutput: 16_384)!
            let label = "window=\(r.window) fixed=\(r.fixed)"
            XCTAssertEqual(w.hard, r.hard, label)
            XCTAssertEqual(w.usable, r.usable, label)
            XCTAssertEqual(w.trigger, r.trigger, label)
            XCTAssertEqual(w.target, r.target, label)
            XCTAssertEqual(w.mode, r.mode, label)
            if r.mode != .unusable { XCTAssertTrue(w.target < w.trigger && w.trigger < w.hard, label) }
        }
    }

    func testOutputReserveRules() {
        XCTAssertEqual(P.watermarks(window: 128_000, fixed: 21_000, maxOutput: 4_096)!.reserve, 4_096, "small output cap")
        XCTAssertEqual(P.watermarks(window: 64_000, fixed: 21_000, maxOutput: 16_384)!.reserve, 9_600, "15% of a 64K window")
        XCTAssertEqual(P.watermarks(window: 16_000, fixed: 8_000, maxOutput: 16_384)!.reserve, 4_096, "4K floor")
        XCTAssertNil(P.watermarks(window: 0, fixed: 21_000, maxOutput: 16_384), "unknown window")
    }

    func testFixedShareRatioIsCappedAtOnePointFive() {
        XCTAssertEqual(P.calibratedFixed(20_000, ratio: 1.2), 24_000)
        XCTAssertEqual(P.calibratedFixed(20_000, ratio: 5.0), 30_000, "a history ratio must not inflate plain text")
        // With the cap a 5x ratio leaves a 128K window usable; without it, it would not be.
        XCTAssertEqual(P.watermarks(window: 128_000, fixed: P.calibratedFixed(20_000, ratio: 5.0), maxOutput: 16_384)!.mode, .normal)
        XCTAssertEqual(P.watermarks(window: 128_000, fixed: 100_000, maxOutput: 16_384)!.mode, .tight)
    }

    // MARK: - Trigger margin

    func testTheTriggerKeepsAMarginBelowHardOnACappedGroup() {
        // The on-device case: 128K cap, compaction line 85% = hard = 108,800.
        let wm = P.watermarks(window: 128_000, fixed: 19_570, maxOutput: 128_000)!
        XCTAssertEqual(wm.hard, 108_800)
        let line = ContextPolicy(contextWindow: 128_000, isUserCap: true).compactThreshold
        XCTAssertEqual(line, 108_800, "the line alone leaves no room")
        let trigger = P.trigger(policyLine: line, watermarks: wm)
        XCTAssertEqual(trigger, wm.trigger)
        XCTAssertEqual(trigger, 19_570 + Int(Double(108_800 - 19_570) * 0.9))
        XCTAssertGreaterThan(wm.hard - trigger, 8_000, "about 10% of the usable space stays free")
    }

    func testTheTriggerStaysBelowHardOnAMillionTokenWindow() {
        let wm = P.watermarks(window: 1_000_000, fixed: 21_000, maxOutput: 32_000)!
        let line = ContextPolicy(contextWindow: 1_000_000).compactThreshold
        XCTAssertGreaterThan(line, wm.hard, "window - 20K is above window - output reserve")
        XCTAssertEqual(P.trigger(policyLine: line, watermarks: wm), wm.trigger)
        XCTAssertLessThan(P.trigger(policyLine: line, watermarks: wm), wm.hard)
    }

    func testALowerCompactionLineStillWins() {
        // 64K native window: the line is window - 10K = 54,000; the watermark trigger is lower still here,
        // so pick a fixed share small enough that the line is the smaller one.
        let wm = P.watermarks(window: 200_000, fixed: 10_000, maxOutput: 8_000)!
        XCTAssertEqual(P.trigger(policyLine: 120_000, watermarks: wm), 120_000)
        XCTAssertEqual(P.trigger(policyLine: nil, watermarks: wm), wm.trigger, "no line: the watermark trigger")
        XCTAssertEqual(P.trigger(policyLine: 0, watermarks: wm), wm.trigger)
    }

    func testTheTriggerIsNeverAboveHardForAnyTier() {
        for window in [16_000, 32_000, 48_000, 64_000, 100_000, 128_000, 200_000, 400_000, 1_000_000] {
            for cap in [false, true] {
                for maxOut in [4_096, 16_384, 128_000] {
                    let wm = P.watermarks(window: window, fixed: 8_000, maxOutput: maxOut)!
                    let line = ContextPolicy(contextWindow: window, isUserCap: cap).compactThreshold
                    let t = P.trigger(policyLine: line > 0 ? line : nil, watermarks: wm)
                    if wm.mode != .unusable { XCTAssertLessThan(t, wm.hard, "window=\(window) cap=\(cap) maxOut=\(maxOut)") }
                }
            }
        }
    }

    // MARK: - A wrong ratio cannot wedge the session

    func testStopNeedsBothTheCalibratedAndTheRawSizeOverHard() {
        XCTAssertTrue(P.isOverHard(calibrated: 229_000, raw: 120_000, hard: 111_616))
        XCTAssertFalse(P.isOverHard(calibrated: 229_000, raw: 22_000, hard: 111_616),
                       "only the ratio says over: the request must still go out so the ratio can be corrected")
        XCTAssertFalse(P.isOverHard(calibrated: 100_000, raw: 100_000, hard: 111_616))
    }

    func testARatioOnlyOverflowStillGetsTheSendOnceValve() {
        let step = ContextPolicy.inLoopStep(verdict: .needsCompact, measured: 229_000, rawTokens: 22_000, window: 128_000,
                                            canCompact: false, ratio: 7.0, uncalibratedSendUsed: false)
        XCTAssertEqual(step, .sendUncalibratedOnce)
    }

    // MARK: - Iterations

    func testAnIterationIsAnAssistantTurnPlusTheCarriersOfItsOwnResults() {
        var textOnly = AgentMessage(role: .assistant, parts: [.text("说明一下进度")])
        textOnly.dbMessageId = "t1"
        let history = run(2) + [textOnly, user("<system-reminder>note</system-reminder>", "u9")] + iteration(5)
        let its = P.iterations(history)
        XCTAssertEqual(its.map(\.key), ["call_0", "call_1", "msg:t1", "call_5"])
        XCTAssertEqual(its[0].carrierIdx, [2])
        XCTAssertTrue(its[2].carrierIdx.isEmpty, "a text-only reply is its own iteration")
        XCTAssertFalse(its.contains { $0.pinned })
    }

    func testACarrierThatAlsoHoldsTextPinsItsIteration() {
        var history = run(2)
        history[2].parts.insert(.text("<context-summary>S</context-summary>"), at: 0)
        XCTAssertTrue(P.iterations(history)[0].pinned)
        XCTAssertFalse(P.iterations(history)[1].pinned)
    }

    // MARK: - Nothing to do

    func testUnderTheTargetNothingChanges() {
        let history = run(5, reasoning: 100)
        let r = P.plan(history, target: measure(history) + 1, options: opts(), measure: measure, offloader: off())
        XCTAssertTrue(r.state.isEmpty)
        XCTAssertEqual(dump(r.messages), dump(history))
        XCTAssertTrue(r.steps.isEmpty)
    }

    // MARK: - L1 reasoning

    func testL1EmptiesReasoningOneIterationAtATimeOldestFirst() {
        let history = run(10, reasoning: 5_000)
        // Room for exactly 4 of the 10 reasonings (plus a little slack).
        let target = measure(history) - 6 * 5_000 + 100
        let r = P.plan(history, target: target, options: opts(), measure: measure, offloader: off())
        XCTAssertTrue(r.reachedTarget)
        XCTAssertEqual(labels(r.steps), ["L1(n=6/10)"])
        XCTAssertEqual(emptied(r.messages), Array(repeating: true, count: 6) + Array(repeating: false, count: 4))
        XCTAssertEqual(reasoningOf(r.messages).first!, "", "field kept, value empty")
        XCTAssertEqual(results(r.messages), results(history), "tool parts untouched by L1")
        XCTAssertNil(r.state.shrinkBefore)
        // Minimal: one fewer emptied would not fit.
        let its = P.iterations(history)
        let fewer = P.apply(history, state: P.State(reasoningBefore: its[5].key), offloader: off())!
        XCTAssertGreaterThan(measure(fewer), target)
    }

    func testNormalModeKeepsTheNewestReasoningTightModeMayEmptyIt() {
        let history = run(4, reasoning: 3_000)
        let normal = P.plan(history, target: fixed + 1_000, options: opts(), measure: measure, offloader: off())
        XCTAssertEqual(emptied(normal.messages), [true, true, true, false])
        XCTAssertEqual(normal.state.reasoningBefore, "call_3")
        let tight = P.plan(history, target: fixed + 1_000, options: opts(floor: 0), measure: measure, offloader: off())
        XCTAssertTrue(reasoningOf(tight.messages).allSatisfy { $0 == "" })
        XCTAssertEqual(tight.state.reasoningBefore, P.through + "call_3",
                       "covers every iteration that exists now - and no later one")
    }

    func testAProviderThatDoesNotReplayReasoningSkipsL1() {
        let history = run(6, reasoning: 3_000, result: 3_000)
        let r = P.plan(history, target: fixed + 5_000, options: opts(strip: false), measure: measure, offloader: off())
        XCTAssertFalse(r.steps.contains { $0.hasPrefix("L1") })
        XCTAssertEqual(reasoningOf(r.messages), reasoningOf(history))
    }

    // MARK: - L2 / L3

    func testOffloadGoesOneIterationAtATime() {
        let history = run(10, result: 3_000)
        // Each offload frees ~2.9K: two are not enough, three are.
        let target = measure(history) - 6_600
        let r = P.plan(history, target: target, options: opts(), measure: measure, offloader: off())
        XCTAssertTrue(r.reachedTarget)
        XCTAssertEqual(labels(r.steps), ["L2L3(n=3/10)"])
        XCTAssertEqual(results(r.messages).map { $0.content.hasPrefix(AIChatViewModel.offloadedStubPrefix) },
                       Array(repeating: true, count: 3) + Array(repeating: false, count: 7))
        XCTAssertNil(r.state.skeletonBefore, "no skeleton needed")
        let its = P.iterations(history)
        let fewer = P.apply(history, state: P.State(shrinkBefore: its[2].key), offloader: off())!
        XCTAssertGreaterThan(measure(fewer), target, "minimal")
    }

    func testL2OffloadsLargeResultsAndL3LargeArgumentsOfOlderIterationsOnly() {
        let body = String(repeating: "正文", count: 1_500)
        let history = [user("写文档", "u0")]
            + (0..<6).flatMap { iteration($0, result: 3_000, arg: body, tool: "file_write") }
        let fake = FakeOffloader()
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(shrinkBefore: its[3].key), offloader: fake.fn)!
        let r = results(applied), u = uses(applied)
        for i in 0..<3 {
            XCTAssertTrue(r[i].content.hasPrefix(AIChatViewModel.offloadedStubPrefix), "result \(i) stubbed")
            XCTAssertTrue(r[i].content.contains("/var/minis/offloads/tools/file_write_call_\(i).txt"))
            XCTAssertTrue(AIChatViewModel.isOffloadedStub(u[i].input["content"] as! String),
                          "argument \(i) is the placeholder the write tools refuse")
            XCTAssertTrue(u[i].offloaded)
        }
        for i in 3..<6 {
            XCTAssertEqual(r[i].content, res(3_000), "protected tail untouched")
            XCTAssertEqual(u[i].input["content"] as? String, body)
            XCTAssertFalse(u[i].offloaded)
        }
        XCTAssertTrue(fake.calls.contains { $0.id == "call_0" && $0.name == "args-file_write" })
        XCTAssertEqual(u[0].input["command"] as? String, "echo 0", "short values are left alone")
        assertWellFormed(applied)
    }

    func testTheResultStubIsTheExistingOffloadFormat() {
        XCTAssertEqual(P.resultStub(tokens: 12, bytes: 34, path: "/var/minis/offloads/tools/a.txt"),
                       "[CONTEXT OFFLOADED] Content (~12 tokens, 34 bytes) saved to: /var/minis/offloads/tools/a.txt\nUse file_read tool to retrieve if needed.")
        XCTAssertTrue(AIChatViewModel.isOffloadedStub(P.shortenedArgumentNotice(String(repeating: "x", count: 500))))
    }

    func testWithoutADiskPathTheLargeResultIsCutNotLostSilently() {
        let history = run(4, result: 3_000)
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(shrinkBefore: its[1].key), offloader: { _, _, _ in nil })!
        let first = results(applied).first!.content
        XCTAssertLessThan(first.count, 3_000)
        XCTAssertTrue(first.contains("chars omitted from context"))
    }

    /// iOS only: a read-back of an offloaded file is already on disk; writing
    /// it again is how GH#343 looped.
    func testAReadBackIsNeverOffloadedAgain() {
        let history = [user("读回来", "u0")] + iteration(0, result: 3_000, readback: true)
            + (1...4).flatMap { iteration($0) }
        let fake = FakeOffloader()
        let its = P.iterations(history)
        let shrunk = P.apply(history, state: P.State(shrinkBefore: its[1].key), offloader: fake.fn)!
        XCTAssertEqual(results(shrunk)[0].content, res(3_000), "L2 leaves it alone")
        let skeleton = P.apply(history, state: P.State(skeletonBefore: its[1].key), offloader: fake.fn)!
        XCTAssertTrue(results(skeleton)[0].content.contains("full output kept in the chat history"))
        XCTAssertLessThan(results(skeleton)[0].content.count, 400)
        XCTAssertTrue(fake.calls.isEmpty, "no second copy written")
    }

    // MARK: - Skeleton

    func testSkeletonKeepsTheCallAndOneLineOfTheResult() {
        let image = Data(repeating: 1, count: 10_000)
        let history = [user("看图", "u0")] + iteration(0, result: 900, image: image) + iteration(1, result: 20)
            + iteration(2) + iteration(3)
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(skeletonBefore: its[2].key), offloader: off())!
        let r0 = results(applied)[0]
        XCTAssertTrue(r0.content.contains("[shortened for context (image omitted); full output: /var/minis/offloads/tools/shell_execute_call_0.txt]"))
        XCTAssertNil(r0.imageBytes, "image dropped")
        XCTAssertLessThanOrEqual(r0.content.split(separator: "\n")[0].count, P.skeletonChars)
        XCTAssertEqual(results(applied)[1].content, res(20), "a small result is already a skeleton")
        XCTAssertEqual(uses(applied)[0].name, "shell_execute", "the call itself stays")
        assertWellFormed(applied)
    }

    func testSkeletonLeavesAnOffloadStubAsItIs() {
        let history = run(4, result: 3_000)
        let its = P.iterations(history)
        let fake = FakeOffloader()
        let both = P.State(shrinkBefore: its[1].key, skeletonBefore: its[1].key)
        let applied = P.apply(history, state: both, offloader: fake.fn)!
        let r0 = results(applied)[0].content
        XCTAssertTrue(r0.hasPrefix(AIChatViewModel.offloadedStubPrefix))
        XCTAssertTrue(r0.contains("/var/minis/offloads/tools/shell_execute_call_0.txt"))
        XCTAssertEqual(fake.calls.filter { $0.id == "call_0" }.count, 1, "offloaded once, not again for the skeleton")
        let shrunkOnly = P.apply(history, state: P.State(shrinkBefore: its[1].key), offloader: off())!
        XCTAssertLessThanOrEqual(ContextSizeMeter.estimateTokens(applied), ContextSizeMeter.estimateTokens(shrunkOnly))
    }

    func testShorteningNeverMakesAnArgumentOrAResultLonger() {
        let arg = String(repeating: "x", count: 250)
        let history = [user("跑命令", "u0")] + (0..<6).flatMap { iteration($0, result: 320, arg: arg) }
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(skeletonBefore: its[3].key), offloader: off())!
        for i in 0..<3 {
            XCTAssertEqual(uses(applied)[i].input["content"] as? String, arg, "shorter than the notice: kept")
            XCTAssertFalse(uses(applied)[i].offloaded)
            XCTAssertLessThanOrEqual(results(applied)[i].content.count, 320)
        }
        XCTAssertLessThanOrEqual(ContextSizeMeter.estimateTokens(applied), ContextSizeMeter.estimateTokens(history))
    }

    func testNoLevelEverGrowsTheRequest() {
        // Awkward sizes around every threshold.
        let sizes = [150, 250, 301, 340, 420, 1_999, 2_001, 2_300]
        let history = [user("混合", "u0")] + sizes.enumerated().flatMap { i, n in
            iteration(i, reasoning: 10, result: n, arg: String(repeating: "y", count: n))
        } + iteration(90) + iteration(91) + iteration(92)
        let its = P.iterations(history)
        let key = its[sizes.count].key
        for state in [P.State(shrinkBefore: key), P.State(skeletonBefore: key), P.State(shrinkBefore: key, skeletonBefore: key)] {
            let applied = P.apply(history, state: state, offloader: off())!
            for (a, b) in zip(results(applied), results(history)) { XCTAssertLessThanOrEqual(a.content.count, b.content.count) }
            for (a, b) in zip(uses(applied), uses(history)) {
                XCTAssertLessThanOrEqual((a.input["content"] as? String ?? "").count, (b.input["content"] as? String ?? "").count)
            }
        }
    }

    // MARK: - Restore

    func testALaterLevelThatFreesEnoughGivesBackWhatAnEarlierLevelTook() {
        // Reasoning small, results large: L1 at full extent is not enough,
        // L2/L3 closes the gap, and then most reasoning comes back.
        let history = run(10, reasoning: 300, result: 3_000)
        let target = measure(history) - 5 * 2_800
        let r = P.plan(history, target: target, options: opts(), measure: measure, offloader: off())
        XCTAssertTrue(r.reachedTarget)
        XCTAssertEqual(levels(r.steps), ["L1", "L2L3", "L1-restore"])
        XCTAssertLessThan(emptied(r.messages).filter { $0 }.count, 9, "reasoning restored")
    }

    // MARK: - L4 collapse

    func testCollapseHappensOnlyWhenAllowedOldestFirstAndNoMoreThanNeeded() {
        let history = run(20, result: 1_500)
        let noCollapse = P.plan(history, target: 0, options: opts(collapse: false), measure: measure, offloader: off())
        let target = noCollapse.after - 200
        let without = P.plan(history, target: target, options: opts(collapse: false), measure: measure, offloader: off())
        XCTAssertFalse(without.steps.contains { $0.hasPrefix("L4") })
        XCTAssertFalse(without.reachedTarget)
        XCTAssertNil(without.state.collapseBefore)

        let with = P.plan(history, target: target, options: opts(collapse: true), measure: measure, offloader: off())
        XCTAssertTrue(with.reachedTarget)
        XCTAssertTrue(with.steps.contains { $0.hasPrefix("L4") })
        let its = P.iterations(history)
        let cutAt = its.firstIndex { $0.key == with.state.collapseBefore }!
        XCTAssertGreaterThan(cutAt, 0)
        var fewerState = with.state
        fewerState.collapseBefore = cutAt == 1 ? nil : its[cutAt - 1].key
        let fewer = P.apply(history, state: fewerState, offloader: off())!
        XCTAssertGreaterThan(measure(fewer), target, "one fewer collapsed would exceed the target")
        let kept = uses(with.messages).map(\.id)
        XCTAssertFalse(kept.contains("call_0"))
        XCTAssertTrue(kept.contains("call_17") && kept.contains("call_18") && kept.contains("call_19"))
        XCTAssertEqual(results(with.messages).last!.content, res(1_500))
        XCTAssertTrue(text(with.messages[0]).hasPrefix("请把计划表写完"))
        assertWellFormed(with.messages)
    }

    func testCollapsedStepsLeaveAnIndexOnTheUsersRequest() {
        let history = run(6)
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(collapseBefore: its[3].key), offloader: off())!
        let host = applied[0]
        XCTAssertEqual(host.dbMessageId, "u0", "request kept as the host")
        guard case .text(let index)? = host.parts.last else { return XCTFail("no index part") }
        XCTAssertTrue(index.hasPrefix("<system-reminder>"))
        XCTAssertTrue(index.contains("3 earlier step(s) of this task were collapsed"))
        XCTAssertTrue(index.contains("#1 shell_execute «step 0» → ok"))
        XCTAssertTrue(index.contains("Tool calls collapsed: shell_execute 3"))
        XCTAssertTrue(index.contains("Do not redo a step listed as ok"))
        XCTAssertEqual(uses(applied).map(\.id), ["call_3", "call_4", "call_5"])
        assertWellFormed(applied)
    }

    func testTheIndexListsAtMostSixtyLinesAndCountsTheRest() {
        let collapsed = (0..<200).map { i -> (AgentMessage, [AgentMessage]) in
            let it = iteration(i)
            return (it[0], [it[1]])
        }
        let index = P.indexText(collapsed)
        XCTAssertEqual(index.split(separator: "\n").filter { $0.hasPrefix("#") }.count, P.indexMaxLines)
        XCTAssertTrue(index.contains("(140 older line(s) not listed)"))
        XCTAssertTrue(index.contains("Tool calls collapsed: shell_execute 200"))
        XCTAssertTrue(index.contains("#200 shell_execute"), "newest kept")
    }

    func testTheIndexNamesErrorsAndOutputPaths() {
        var it = iteration(0)
        it[1].parts = [.toolResult(id: "call_0", name: "shell_execute",
                                   content: P.resultStub(tokens: 1, bytes: 2, path: "/var/minis/offloads/tools/x.txt"), isError: false)]
        var failed = iteration(1)
        failed[1].parts = [.toolResult(id: "call_1", name: "shell_execute", content: "boom", isError: true)]
        let index = P.indexText([(it[0], [it[1]]), (failed[0], [failed[1]]), (iteration(2)[0], [])])
        XCTAssertTrue(index.contains("#1 shell_execute «step 0» → ok (/var/minis/offloads/tools/x.txt)"))
        XCTAssertTrue(index.contains("#2 shell_execute «step 1» → error"))
        XCTAssertTrue(index.contains("#3 shell_execute «step 2» → no result"))
    }

    func testAPinnedIterationIsNeverCollapsed() {
        var history = run(6)
        history[2].parts.insert(.text("<context-summary>S</context-summary>"), at: 0)
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(collapseBefore: its[3].key), offloader: off())!
        XCTAssertTrue(uses(applied).contains { $0.id == "call_0" })
        XCTAssertTrue(applied.contains { text($0).contains("<context-summary>") })
        XCTAssertFalse(uses(applied).contains { $0.id == "call_1" })
        assertWellFormed(applied)
    }

    func testWhenNothingPrecedesTheCollapsedRangeTheIndexBecomesItsOwnUserTurn() {
        let history = (0..<5).flatMap { iteration($0) }
        let its = P.iterations(history)
        let applied = P.apply(history, state: P.State(collapseBefore: its[2].key), offloader: off())!
        XCTAssertEqual(applied.first?.role, .user)
        XCTAssertTrue(text(applied[0]).contains("earlier step(s) of this task were collapsed"))
    }

    // MARK: - Freezing

    func testAFrozenPlanReappliedToAGrownHistoryKeepsTheOldPartByteIdentical() {
        let history = run(12, reasoning: 2_000, result: 2_500)
        let r = P.plan(history, target: measure(history) / 3, options: opts(collapse: true), measure: measure, offloader: off())
        XCTAssertFalse(r.state.isEmpty)
        let grown = history + iteration(12, reasoning: 2_000) + iteration(13, reasoning: 2_000)
        let again = P.apply(grown, state: r.state, offloader: off())!
        XCTAssertEqual(dump(Array(again.prefix(r.messages.count))), dump(r.messages), "prefix cache keeps hitting")
        XCTAssertEqual(again.last { $0.role == .assistant }?.reasoningContent, cjk(2_000), "new turns arrive untouched")
        XCTAssertEqual(results(again).suffix(2).map(\.content), [res(50), res(50)])
    }

    func testAFullExtentLevelDoesNotReachIterationsAddedLater() {
        let history = run(4, reasoning: 3_000)
        let tight = P.plan(history, target: fixed + 1_000, options: opts(floor: 0), measure: measure, offloader: off())
        let grown = history + iteration(4, reasoning: 3_000)
        let again = P.apply(grown, state: tight.state, offloader: off())!
        XCTAssertEqual(emptied(again), [true, true, true, true, false])
    }

    func testAPlanWhoseCutOffKeyIsGoneAsksForARePlan() {
        XCTAssertNil(P.apply(run(3), state: P.State(reasoningBefore: "call_missing"), offloader: off()))
        XCTAssertNil(P.apply(run(3), state: P.State(shrinkBefore: P.through + "call_missing"), offloader: off()))
        let h = run(3)
        XCTAssertEqual(dump(P.apply(h, state: P.State(), offloader: off())!), dump(h), "an empty state is a no-op")
    }

    // MARK: - Whole ladder

    func testLevelsRunCheapestFirst() {
        // Every level has something to take: reasoning (L1), 3K arguments (L3),
        // 1.5K results only a skeleton shortens (SK), iterations to collapse (L4).
        let history = [user("请把计划表写完", "u0")]
            + (0..<10).flatMap { iteration($0, reasoning: 4_000, result: 1_500, arg: String(repeating: "正", count: 3_000)) }
        let floor = P.plan(history, target: 0, options: opts(collapse: false), measure: measure, offloader: off()).after
        let r = P.plan(history, target: floor - 50, options: opts(collapse: true), measure: measure, offloader: off())
        XCTAssertEqual(Array(levels(r.steps).prefix(4)), ["L1", "L2L3", "SK", "L4"])
        XCTAssertTrue(r.reachedTarget)
        assertWellFormed(r.messages)
    }

    func testTightWindowsKeepNoOldReasoningAndOnlyTheNewestIterationIntact() {
        let history = run(6, reasoning: 1_500, result: 2_500)
        let r = P.plan(history, target: fixed + 4_000,
                       options: P.Options(stripReasoning: true, reasoningFloor: 0, keepRecentIterations: 1, allowCollapse: true),
                       measure: measure, offloader: off())
        XCTAssertTrue(reasoningOf(r.messages).allSatisfy { $0 == "" })
        XCTAssertEqual(results(r.messages).last!.content, res(2_500), "newest result intact")
        XCTAssertTrue(r.reachedTarget)
        assertWellFormed(r.messages)
    }

    func testWhenEvenTheProtectedTailIsOverTheTargetThePlanSaysSo() {
        let history = run(3, result: 9_000)
        let r = P.plan(history, target: fixed + 1_000, options: opts(recent: 3, collapse: true), measure: measure, offloader: off())
        XCTAssertFalse(r.reachedTarget)
        XCTAssertEqual(results(r.messages), results(history), "nothing protected was touched")
    }

    func testOneUserTurnDriving200ToolIterationsComesDownToTheTarget() {
        // Field shape: ~15K reasoning and ~3K output per iteration, one "continue".
        let history = run(200, reasoning: 15_000, result: 3_000)
        let target = 66_000
        XCTAssertGreaterThan(measure(history), 3_000_000, "starts far over the window")
        let r = P.plan(history, target: target, options: opts(collapse: true), measure: measure, offloader: off())
        XCTAssertTrue(r.reachedTarget, "after=\(r.after)")
        XCTAssertTrue(text(r.messages[0]).hasPrefix("请把计划表写完"), "the user's request is kept")
        XCTAssertEqual(Array(uses(r.messages).map(\.id).suffix(3)), ["call_197", "call_198", "call_199"])
        XCTAssertEqual(Array(results(r.messages).suffix(3)).map(\.content), [res(3_000), res(3_000), res(3_000)],
                       "newest three iterations intact")
        XCTAssertEqual(r.messages.last { $0.role == .assistant }?.reasoningContent, cjk(15_000),
                       "the newest step keeps its reasoning")
        // Every older reasoning emptied, then just enough old outputs offloaded - no collapse.
        XCTAssertEqual(levels(r.steps), ["L1", "L2L3"])
        XCTAssertEqual(labels(r.steps)[0], "L1(n=199/200)")
        XCTAssertNil(r.state.collapseBefore)
        XCTAssertNil(r.state.skeletonBefore)
        // Minimal: offloading one iteration fewer would not fit.
        let its = P.iterations(history)
        let cutAt = its.firstIndex { $0.key == r.state.shrinkBefore }!
        var fewer = r.state
        fewer.shrinkBefore = its[cutAt - 1].key
        XCTAssertGreaterThan(measure(P.apply(history, state: fewer, offloader: off())!), target)
        XCTAssertEqual(uses(r.messages).count, 200, "no step was removed")
        assertWellFormed(r.messages)
    }

    func testPlanningTwiceGivesTheSameState() {
        let history = run(30, reasoning: 2_000, result: 2_500)
        let a = P.plan(history, target: 30_000, options: opts(collapse: true), measure: measure, offloader: off())
        let b = P.plan(history, target: 30_000, options: opts(collapse: true), measure: measure, offloader: off())
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(dump(a.messages), dump(b.messages))
        XCTAssertEqual(dump(P.apply(history, state: a.state, offloader: off())!), dump(a.messages),
                       "apply reproduces what plan returned")
    }
}
