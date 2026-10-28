import XCTest
@testable import Minis

/// [T-ctx-count-wire-framing] The estimate counts what frames a message on the
/// wire, not only its text.
///
/// On-device run 2026-10-07 (DeepSeek, session 38D5C536): the calibration
/// ratio drifted 1.009 -> 1.194 and jumped at each trim. For the request after
/// the first trim (235 messages, 130 tool calls) the provider counted 70,277,
/// this estimator over the raw body gave 71,208, and the structured estimate
/// was 60,980: it left out call ids, the second escaping of arguments and the
/// keys around every message and call.
final class ContextWireFramingTests: XCTestCase {

    private typealias M = ContextSizeMeter

    private var deepseek: LLMModel {
        LLMModel(id: "deepseek-flash", displayName: "DeepSeek", provider: "OpenAI",
                 supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    }
    private func provider() -> OpenAIAgentProvider {
        OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "k", model: deepseek, customBaseURL: "https://api.deepseek.com/v1"))
    }
    /// The estimator over the Chat Completions body these messages become.
    private func wireTokens(_ messages: [AgentMessage]) throws -> Int {
        let rows = provider().flattenChatCompletionsMessages(messages, thinkingLevel: .high)
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.withoutEscapingSlashes])
        return M.estimateTokens(String(decoding: data, as: UTF8.self))
    }
    private func round(_ i: Int, command: String, output: String, reasoning: String? = "") -> [AgentMessage] {
        let id = "call_00_\(String(format: "%024d", i))"
        var a = AgentMessage(role: .assistant, parts: [.toolUse(id: id, name: "shell_execute",
                                                                input: ["command": command, "tool_title": "step \(i)"])])
        a.reasoningContent = reasoning
        let r = AgentMessage(role: .user, parts: [.toolResult(id: id, name: "shell_execute", content: output, isError: false)])
        return [a, r]
    }

    // MARK: - Pieces

    func testACallIdIsCountedOnTheCallAndOnTheResult() {
        let short = AgentContentPart.toolUse(id: "c", name: "shell_execute", input: ["command": "ls"])
        let long = AgentContentPart.toolUse(id: "call_00_6JtVL9iU05cirHCa5lT25476", name: "shell_execute", input: ["command": "ls"])
        XCTAssertEqual(M.estimateTokens(long) - M.estimateTokens(short),
                       M.estimateTokens("call_00_6JtVL9iU05cirHCa5lT25476") - M.estimateTokens("c"))
        let r1 = AgentContentPart.toolResult(id: "c", name: "shell_execute", content: "ok", isError: false)
        let r2 = AgentContentPart.toolResult(id: "call_00_6JtVL9iU05cirHCa5lT25476", name: "shell_execute", content: "ok", isError: false)
        XCTAssertGreaterThan(M.estimateTokens(r2), M.estimateTokens(r1) + 5)
    }

    func testEscapingIsCountedForQuotesBackslashesAndNewlines() {
        XCTAssertEqual(M.wireEscapeTokens("plain text 123"), 0)
        XCTAssertEqual(M.wireEscapeTokens(String(repeating: "\"", count: 20)), 7)
        XCTAssertEqual(M.wireEscapeTokens("a\nb\nc\\d\te"), 2)   // 4 escaped characters x 0.35, rounded up
        XCTAssertEqual(M.estimateWireTokens(""), 0)
        let json = #"{"a":"b","c":"d"}"#
        XCTAssertEqual(M.estimateWireTokens(json), M.estimateTokens(json) + M.wireEscapeTokens(json))
    }

    func testArgumentsAreCountedAsAStringInsideTheBody() {
        let quoted = String(repeating: "say \"hi\" ", count: 200)
        let part = AgentContentPart.toolUse(id: "c", name: "shell_execute", input: ["command": quoted])
        // Once escaped by JSONSerialization (\"), then again as a string value (\\\").
        XCTAssertGreaterThan(M.estimateTokens(part), M.estimateTokens(quoted) + 300)
    }

    func testTheToolNameIsNotCountedOnTheResult() {
        let a = AgentContentPart.toolResult(id: "c", name: "x", content: "ok", isError: false)
        let b = AgentContentPart.toolResult(id: "c", name: "a_very_long_tool_name_that_is_not_sent_again", content: "ok", isError: false)
        XCTAssertEqual(M.estimateTokens(a), M.estimateTokens(b))
    }

    func testFramingConstants() {
        XCTAssertEqual(M.perMessageOverhead, 8)
        XCTAssertEqual(M.perToolUseOverhead, 22)
        XCTAssertEqual(M.perToolResultOverhead, 6)
        XCTAssertEqual(M.reasoningFieldOverhead, 6)
    }

    func testTheReasoningFieldCostsEvenWhenEmpty() {
        var withField = AgentMessage(role: .assistant, parts: [.text("ok")])
        withField.reasoningContent = ""
        let noField = AgentMessage(role: .assistant, parts: [.text("ok")])
        XCTAssertEqual(M.estimateTokens([withField], includeReasoning: true) - M.estimateTokens([noField], includeReasoning: true),
                       M.reasoningFieldOverhead)
        XCTAssertEqual(M.estimateTokens([withField]), M.estimateTokens([noField]), "not echoed: not counted")
    }

    func testTheCacheSeparatesAnEmptyFieldFromNoField() {
        let id = "wire-\(UUID().uuidString)"
        var noField = AgentMessage(role: .assistant, parts: [.text("ok")])
        noField.dbMessageId = id
        var withField = noField
        withField.reasoningContent = ""
        let a = M.estimateTokens(message: noField, includeReasoning: true)
        let b = M.estimateTokens(message: withField, includeReasoning: true)
        XCTAssertEqual(b - a, M.reasoningFieldOverhead)
    }

    // MARK: - Against the real request body

    /// Many small tool rounds - the shape a trimmed history has, where framing
    /// is the largest share. The structured estimate must stay close to the
    /// estimator run over the body the provider is actually sent.
    func testManySmallRoundsMeasureLikeTheBodyThatIsSent() throws {
        var history = [AgentMessage(role: .user, parts: [.text("please finish the plan")])]
        for i in 0..<120 {
            history += round(i, command: "grep -n \"total\" lib/sum_\(i).sh | head -3", output: "12: total=$((total + 1))\n[exit 0]")
        }
        let wire = try wireTokens(history)
        let estimate = M.estimateTokens(history, includeReasoning: true)
        let ratio = Double(wire) / Double(estimate)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.08, "wire \(wire) vs estimate \(estimate)")
    }

    func testTheRatioNoLongerDependsOnHowSmallTheMessagesAre() throws {
        func ratio(outputChars: Int, reasoningChars: Int) throws -> Double {
            var history = [AgentMessage(role: .user, parts: [.text("please finish the plan")])]
            for i in 0..<60 {
                history += round(i, command: "cat lib/file_\(i).sh",
                                 output: String(repeating: "echo \"line\" # comment\n", count: outputChars / 22),
                                 reasoning: String(repeating: "Considering the next step. ", count: reasoningChars / 27))
            }
            return Double(try wireTokens(history)) / Double(M.estimateTokens(history, includeReasoning: true))
        }
        let large = try ratio(outputChars: 3_000, reasoningChars: 6_000)   // before a trim
        let small = try ratio(outputChars: 110, reasoningChars: 0)         // after reasoning is emptied and results shortened
        XCTAssertEqual(large, 1.0, accuracy: 0.05)
        XCTAssertEqual(small, 1.0, accuracy: 0.08)
        XCTAssertLessThan(abs(small - large), 0.08, "the old estimator: 1.03 against 1.5 and more")
    }

    func testPlainTextMessagesAreStillCloseToTheirText() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 100)
        let m = AgentMessage(role: .user, parts: [.text(text)])
        XCTAssertEqual(M.estimateTokens([m]), M.estimateTokens(text) + M.perMessageOverhead)
    }
}
