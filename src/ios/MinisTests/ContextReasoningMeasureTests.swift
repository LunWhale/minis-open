import XCTest
@testable import Minis

/// [T-ctx-count-reasoning] The context meter counts what is really sent.
///
/// Android field run 2026-10-07 (DeepSeek, max thinking, 128K window): the
/// provider counted 341,873 prompt tokens while the meter read 146,874, because
/// the `reasoning_content` replayed on every past assistant turn was not in the
/// estimate and the calibration ratio that should have absorbed it was clamped
/// at 3.0. iOS had the same three gaps.
final class ContextReasoningMeasureTests: XCTestCase {

    private let reasoning = String(repeating: "Considering the next step carefully. ", count: 400)

    private func assistant(id: String? = nil, text: String = "ok", reasoning: String? = nil,
                           args: [String: Any]? = nil) -> AgentMessage {
        var parts: [AgentContentPart] = [.text(text)]
        if let args { parts.append(.toolUse(id: "call_1", name: "shell_execute", input: args)) }
        var m = AgentMessage(role: .assistant, parts: parts)
        m.reasoningContent = reasoning
        m.dbMessageId = id
        return m
    }

    // MARK: - Estimator

    func testReasoningIsCountedOnlyWhenAsked() {
        let m = assistant(reasoning: reasoning)
        let without = ContextSizeMeter.estimateTokens([m])
        let with = ContextSizeMeter.estimateTokens([m], includeReasoning: true)
        XCTAssertEqual(with - without, ContextSizeMeter.estimateWireTokens(reasoning) + ContextSizeMeter.reasoningFieldOverhead)
        XCTAssertEqual(ContextSizeMeter.estimateTokens([m], includeReasoning: false), without)
    }

    func testReasoningOnAUserMessageIsNeverCounted() {
        var m = AgentMessage(role: .user, parts: [.text("hello")])
        m.reasoningContent = reasoning
        XCTAssertEqual(ContextSizeMeter.estimateTokens([m], includeReasoning: true),
                       ContextSizeMeter.estimateTokens([m]))
    }

    func testAssistantWithoutReasoningMeasuresTheSameEitherWay() {
        let m = assistant()
        XCTAssertEqual(ContextSizeMeter.estimateTokens([m], includeReasoning: true),
                       ContextSizeMeter.estimateTokens([m]))
    }

    // MARK: - Estimate cache

    func testCachedMessageWithEmptiedReasoningIsRemeasured() {
        let id = "cache-\(UUID().uuidString)"
        let full = assistant(id: id, reasoning: reasoning)
        var emptied = full
        emptied.reasoningContent = ""
        let fullSize = ContextSizeMeter.estimateTokens(message: full, includeReasoning: true)
        let emptiedSize = ContextSizeMeter.estimateTokens(message: emptied, includeReasoning: true)
        XCTAssertEqual(fullSize - emptiedSize, ContextSizeMeter.estimateWireTokens(reasoning),
                       "a trimmed copy must not be served the untrimmed size")
    }

    func testCachedSizeDoesNotLeakBetweenTheTwoModes() {
        let id = "cache-\(UUID().uuidString)"
        let m = assistant(id: id, reasoning: reasoning)
        let with = ContextSizeMeter.estimateTokens(message: m, includeReasoning: true)
        let without = ContextSizeMeter.estimateTokens(message: m, includeReasoning: false)
        XCTAssertGreaterThan(with, without)
        XCTAssertEqual(ContextSizeMeter.estimateTokens(message: m, includeReasoning: true), with)
    }

    func testCachedMessageWithShortenedArgumentIsRemeasured() {
        let id = "cache-\(UUID().uuidString)"
        let long = assistant(id: id, args: ["command": String(repeating: "echo hello; ", count: 500)])
        let short = assistant(id: id, args: ["command": "echo hello"])
        let longSize = ContextSizeMeter.estimateTokens(message: long)
        let shortSize = ContextSizeMeter.estimateTokens(message: short)
        XCTAssertGreaterThan(longSize, shortSize + 1000, "same id, same key count, different argument")
    }

    func testArgumentFingerprintIgnoresNonStrings() {
        XCTAssertEqual(ContextSizeMeter.argumentFingerprint(["a": "abcd", "n": 12, "b": "xy"]), 6)
        XCTAssertEqual(ContextSizeMeter.argumentFingerprint([:]), 0)
    }

    // MARK: - Calibration samples are versioned

    func testSamplesFromTheOldEstimatorAreSkipped() {
        // An old row: estimated WITHOUT reasoning, so its ratio is 5x.
        let old = ContextSizeMeter.CalibrationSample(reported: 100_000, estimated: 20_000,
                                                     fixedTokens: 9_000, modelId: "deepseek-flash")
        let state = ContextSizeMeter.replayCalibration([old])
        XCTAssertEqual(state.samples, 0)
        XCTAssertTrue(state.ratios.isEmpty)
        XCTAssertNil(state.lastLearned)
        XCTAssertEqual(state.fixedTokens, 0)
    }

    func testAnExplicitVersionOneIsSkippedToo() {
        let v1 = ContextSizeMeter.CalibrationSample(reported: 100_000, estimated: 20_000, fixedTokens: 9_000,
                                                    modelId: "m", estimatorVersion: 1)
        XCTAssertFalse(v1.isCurrent)
        XCTAssertEqual(ContextSizeMeter.replayCalibration([v1]).samples, 0)
    }

    func testCurrentSamplesAreReplayed() {
        let v2 = ContextSizeMeter.CalibrationSample(reported: 105_000, estimated: 100_000, fixedTokens: 21_000,
                                                    modelId: "deepseek-flash",
                                                    estimatorVersion: ContextSizeMeter.estimatorVersion)
        let state = ContextSizeMeter.replayCalibration([v2])
        XCTAssertEqual(state.samples, 1)
        XCTAssertEqual(state.ratios["deepseek-flash"] ?? 0, 1.05, accuracy: 0.0001)
        XCTAssertEqual(state.fixedTokens, 21_000)
    }

    /// The Android regression: old 5x rows replayed onto an estimate that now
    /// contains reasoning read a 22K request as 229K and stopped every turn.
    func testOldRowsCannotInflateARequestThatNowCountsReasoning() {
        let old = (0..<6).map { _ in
            ContextSizeMeter.CalibrationSample(reported: 140_000, estimated: 20_000, fixedTokens: 9_000, modelId: "m")
        }
        let new = ContextSizeMeter.CalibrationSample(reported: 22_600, estimated: 22_000, fixedTokens: 9_000,
                                                     modelId: "m", estimatorVersion: ContextSizeMeter.estimatorVersion)
        let state = ContextSizeMeter.replayCalibration(old + [new])
        let ratio = ContextSizeMeter.ratio(for: "m", known: state.ratios, lastLearned: state.lastLearned)
        XCTAssertLessThan(ContextSizeMeter.calibrated(22_000, ratio: ratio), 24_000)
    }

    func testEstimatorVersionIsThree() {
        XCTAssertEqual(ContextSizeMeter.estimatorVersion, 3)
    }

    /// Pairs taken before wire framing was counted (version 2) carry a ratio
    /// that includes it; replaying them now would count it twice.
    func testVersionTwoPairsAreSkippedToo() {
        let v2 = ContextSizeMeter.CalibrationSample(reported: 119_400, estimated: 100_000, fixedTokens: 17_000,
                                                    modelId: "deepseek-flash", estimatorVersion: 2)
        XCTAssertFalse(v2.isCurrent)
        XCTAssertEqual(ContextSizeMeter.replayCalibration([v2]).samples, 0)
    }

    // MARK: - Ratio ceiling

    func testRatioCeilingIsEight() {
        XCTAssertEqual(ContextSizeMeter.calibrationRange.upperBound, 8.0)
        XCTAssertEqual(ContextSizeMeter.calibrationRange.lowerBound, 0.8)
        XCTAssertEqual(ContextSizeMeter.calibrationRatio(reported: 500_000, estimated: 100_000), 5.0)
        XCTAssertEqual(ContextSizeMeter.calibrationRatio(reported: 2_000_000, estimated: 100_000), 8.0)
    }

    // MARK: - Stored usage stays compatible

    func testStoredUsageRoundTripsTheVersion() throws {
        var usage = StoredTokenUsage(inputTokens: 1, outputTokens: 2, cacheCreationTokens: 0, cacheReadTokens: 0,
                                     latestContextTokens: 1000)
        usage.estimatedRequestTokens = 950
        usage.estimatorVersion = ContextSizeMeter.estimatorVersion
        let data = try JSONEncoder().encode(usage)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["estimatorVersion"] as? Int, ContextSizeMeter.estimatorVersion, "same key name as Android")
        XCTAssertEqual(try JSONDecoder().decode(StoredTokenUsage.self, from: data), usage)
    }

    func testARowWrittenBeforeTheFieldDecodesAsNil() throws {
        let old = #"{"inputTokens":10,"outputTokens":5,"cacheCreationTokens":0,"cacheReadTokens":0,"latestContextTokens":900,"estimatedRequestTokens":300,"estimatedFixedTokens":100,"calibrationModelId":"m"}"#
        let usage = try JSONDecoder().decode(StoredTokenUsage.self, from: Data(old.utf8))
        XCTAssertNil(usage.estimatorVersion)
        XCTAssertEqual(usage.estimatedRequestTokens, 300)
    }

    /// What an older build does with a row from this one: it has no such
    /// property and must still decode everything else.
    func testAnOlderReaderIgnoresTheNewKey() throws {
        struct OlderStoredTokenUsage: Codable {
            var inputTokens: Int, outputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int
            var latestContextTokens: Int?
            var estimatedRequestTokens: Int?
        }
        var usage = StoredTokenUsage(inputTokens: 7, outputTokens: 2, cacheCreationTokens: 0, cacheReadTokens: 0,
                                     latestContextTokens: 1000)
        usage.estimatedRequestTokens = 950
        usage.estimatorVersion = 2
        let decoded = try JSONDecoder().decode(OlderStoredTokenUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(decoded.inputTokens, 7)
        XCTAssertEqual(decoded.estimatedRequestTokens, 950)
    }

    // MARK: - The gate matches the request builder

    private var deepseek: LLMModel {
        LLMModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", provider: "OpenAI",
                 supportsReasoning: true, interleavedReasoningField: "reasoning_content")
    }
    private var claude: LLMModel {
        LLMModel(id: "claude-sonnet-5-5", displayName: "Claude", provider: "Anthropic", supportsReasoning: true)
    }

    private func wireCarriesReasoning(_ provider: OpenAIAgentProvider) -> Bool {
        let wire = provider.flattenChatCompletionsMessages([assistant(reasoning: "thoughts")])
        return wire.contains { ($0["role"] as? String) == "assistant" && $0["reasoning_content"] != nil }
    }

    func testChatCompletionsEchoesAndSaysSo() {
        let p = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "k", model: deepseek,
                                                             customBaseURL: "https://api.deepseek.com/v1"))
        XCTAssertTrue(p.echoesReasoningContent(thinkingLevel: .off))
        XCTAssertEqual(p.echoesReasoningContent(thinkingLevel: .off), wireCarriesReasoning(p))
    }

    func testMistralAndCerebrasDoNotEcho() {
        let mistral = OpenAIProvider(apiKey: "k", model: deepseek, customBaseURL: "https://api.mistral.ai/v1")
        mistral.isMistral = true
        let m = OpenAIAgentProvider(provider: mistral)
        XCTAssertFalse(m.echoesReasoningContent(thinkingLevel: .high))
        XCTAssertEqual(m.echoesReasoningContent(thinkingLevel: .high), wireCarriesReasoning(m))

        let cerebras = OpenAIAgentProvider(provider: OpenAIProvider(apiKey: "k", model: deepseek,
                                                                    customBaseURL: "https://api.cerebras.ai/v1"))
        XCTAssertEqual(cerebras.echoesReasoningContent(thinkingLevel: .high), wireCarriesReasoning(cerebras))
        XCTAssertFalse(cerebras.echoesReasoningContent(thinkingLevel: .high))
    }

    func testResponsesAPIDoesNotEcho() {
        let upstream = OpenAIProvider(apiKey: "k", model: deepseek, customBaseURL: "https://api.openai.com/v1")
        upstream.forceResponsesAPI = true
        XCTAssertFalse(OpenAIAgentProvider(provider: upstream).echoesReasoningContent(thinkingLevel: .high))
    }

    func testAnthropicEchoesOnlyOnTheUnsignedProxyPath() {
        let proxy = AnthropicAgentProvider(provider: AnthropicProvider(apiKey: "k", model: deepseek,
                                                                       basePath: "https://api.deepseek.com/anthropic"))
        XCTAssertTrue(proxy.echoesReasoningContent(thinkingLevel: .off))

        let official = AnthropicAgentProvider(provider: AnthropicProvider(apiKey: "k", model: deepseek,
                                                                          basePath: "https://api.anthropic.com"))
        XCTAssertFalse(official.echoesReasoningContent(thinkingLevel: .high), "signed blocks only")

        let claudeOnProxy = AnthropicAgentProvider(provider: AnthropicProvider(apiKey: "k", model: claude,
                                                                               basePath: "https://relay.example.com"))
        XCTAssertFalse(claudeOnProxy.echoesReasoningContent(thinkingLevel: .high), "no interleaved field")
    }
}
