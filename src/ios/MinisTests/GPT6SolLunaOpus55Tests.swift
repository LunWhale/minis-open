import XCTest
@testable import Minis

// [T-gpt6-sol-luna, T-anthropic-opus55] Three models added from CLIProxyAPI
// registry commit 2430354330af ("update model definitions and bump codex client
// version to 0.155.0"): claude-opus-5-5, gpt-6-sol, gpt-6-luna.
//
// Same shape as GPT6AstraReasoningTests, which this mirrors deliberately — the
// two GPT-6 ids carry the identical `supportsReasoning` hazard Astra did, and
// the Opus entry adds a thinking-disabled hazard of its own.
final class GPT6SolLunaOpus55Tests: XCTestCase {

    // MARK: - GPT-6 Sol / Luna

    /// The load-bearing flag. A brand-new id is not in models-dev-api.json, so
    /// `ModelsDevAPI.enrichModels()` leaves `supportsReasoning` nil, and
    /// `reasoningEffort(for:)` guards on `supportsReasoning ?? false` — every
    /// level the user picks would collapse to the Codex-OAuth fallback "low".
    func testStaticEntriesDeclareReasoning() {
        XCTAssertEqual(LLMModel.gpt6Sol.supportsReasoning, true)
        XCTAssertEqual(LLMModel.gpt6Luna.supportsReasoning, true)
        XCTAssertEqual(LLMModel.gpt6Sol.id, "gpt-6-sol")
        XCTAssertEqual(LLMModel.gpt6Luna.id, "gpt-6-luna")
    }

    func testBothAreOfferedOverCodexOAuth() {
        let ids = LLMModel.allOpenAICodexOAuth.map(\.id)
        XCTAssertTrue(ids.contains("gpt-6-sol"))
        XCTAssertTrue(ids.contains("gpt-6-luna"))
    }

    func testCatalogCeilingIsMaxLikeAstra() {
        XCTAssertEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-sol"), .max)
        XCTAssertEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-luna"), .max)
        XCTAssertEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-sol"),
                       ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-astra"))
    }

    /// Sol's registry entry drops "ultra" from its declared levels because the
    /// backend rejects that tier (as for gpt-5.6-sol). A `.max` ceiling IS that
    /// exclusion: the picker stops at .max so .ultra is never offered, and the
    /// shared wire clamp folds .max/.ultra to "max" regardless. Pinned so a
    /// future ceiling raise cannot silently re-expose the rejected tier.
    func testUltraIsNeverOfferedForSol() {
        let ceiling = ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-sol")
        XCTAssertNotEqual(ceiling, .ultra)
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: .gpt6Sol, level: .ultra), "max",
                       "even if .ultra is reached, the wire value must not be \"ultra\"")
    }

    func testEveryLevelReachesTheWire() {
        for m in [LLMModel.gpt6Sol, LLMModel.gpt6Luna] {
            XCTAssertNil(OpenAIAgentProvider.reasoningEffort(for: m, level: .off), m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .low), "low", m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .medium), "medium", m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .high), "high", m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .xhigh), "xhigh", m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .max), "max", m.id)
            XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .ultra), "max", m.id)
        }
    }

    func testNilFlagWouldHaveCollapsedToNil() {
        // The exact pre-fix shape: same ids, flag never enriched.
        for id in ["gpt-6-sol", "gpt-6-luna"] {
            let unenriched = LLMModel(id: id, displayName: id, provider: "OpenAI")
            XCTAssertNil(OpenAIAgentProvider.reasoningEffort(for: unenriched, level: .xhigh),
                         "documents why the explicit flag is load-bearing for \(id)")
        }
    }

    /// Both ids declare `minimal_client_version: 0.155.0`. The header is a
    /// floor, so this also has to keep clearing gpt-6-astra's 0.153.0.
    func testCodexClientVersionClearsBothGates() {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        func atLeast(_ v: String, _ floor: String) -> Bool {
            let a = parts(v), b = parts(floor)
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
                if x != y { return x > y }
            }
            return true
        }
        XCTAssertTrue(atLeast(OpenAIProvider.codexClientVersion, "0.155.0"),
                      "gpt-6-sol / gpt-6-luna need >= 0.155.0, got \(OpenAIProvider.codexClientVersion)")
        XCTAssertTrue(atLeast(OpenAIProvider.codexClientVersion, "0.153.0"),
                      "gpt-6-astra must keep clearing its own floor")
    }

    // MARK: - GPT-6.1 Sol [T-gpt61-sol]

    /// CLIProxyAPI PR #6207: 272000 context, 128000 output, levels low…max.
    func testGPT61SolStaticEntry() {
        XCTAssertEqual(LLMModel.gpt61Sol.id, "gpt-6.1-sol")
        XCTAssertEqual(LLMModel.gpt61Sol.displayName, "GPT-6.1 Sol")
        XCTAssertEqual(LLMModel.gpt61Sol.provider, "OpenAI")
        XCTAssertEqual(LLMModel.gpt61Sol.supportsReasoning, true)
        XCTAssertEqual(LLMModel.gpt61Sol.contextWindow, 272_000)
        XCTAssertEqual(LLMModel.gpt61Sol.maxOutputTokens, 128_000)
        XCTAssertEqual(LLMModel.gpt61Sol.contextWindowTokens, 272_000,
                       "without the explicit value the id heuristic would say 128K")
    }

    func testGPT61SolIsOfferedOverCodexOAuth() {
        let ids = LLMModel.allOpenAICodexOAuth.map(\.id)
        XCTAssertTrue(ids.contains("gpt-6.1-sol"))
        XCTAssertFalse(LLMModel.allOpenAI.map(\.id).contains("gpt-6.1-sol"))
    }

    /// "gpt-6-sol" is not a prefix of "gpt-6.1-sol": without its own catalog
    /// rule the model had no declared ceiling.
    func testGPT61SolCeilingIsMax() {
        XCTAssertEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6.1-sol"), .max)
        XCTAssertEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6-1-sol"), .max)
        XCTAssertNotEqual(ThinkingLevelCatalog.declaredMaxLevel(for: "gpt-6.1-sol"), .ultra)
    }

    func testGPT61SolEveryLevelReachesTheWire() {
        let m = LLMModel.gpt61Sol
        XCTAssertNil(OpenAIAgentProvider.reasoningEffort(for: m, level: .off))
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .low), "low")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .medium), "medium")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .high), "high")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .xhigh), "xhigh")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .max), "max")
        XCTAssertEqual(OpenAIAgentProvider.reasoningEffort(for: m, level: .ultra), "max")
    }

    // MARK: - Claude Opus 5.5

    func testOpus55StaticEntry() {
        XCTAssertEqual(LLMModel.claudeOpus55.id, "claude-opus-5-5")
        XCTAssertEqual(LLMModel.claudeOpus55.displayName, "Claude Opus 5.5")
        XCTAssertEqual(LLMModel.claudeOpus55.provider, "Anthropic")
        XCTAssertEqual(LLMModel.claudeOpus55.contextWindow, 1_000_000)
        XCTAssertEqual(LLMModel.claudeOpus55.maxOutputTokens, 128_000)
        XCTAssertTrue(LLMModel.allAnthropic.map(\.id).contains("claude-opus-5-5"))
    }

    /// THE regression this file exists for. Opus 5.5 rejects
    /// `thinking.type: "disabled"` with 400 "not supported for this model"
    /// (thinking is always on), so "off" must be adaptive at the lowest effort.
    func testOpus55NeverSendsThinkingDisabled() {
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-opus-5-5"), .lowEffort)
        // The version really does parse — a nil parse would answer `.omit`,
        // which is wrong for a different reason (it would think at the default).
        let v = AnthropicProvider.parseClaudeVersion("claude-opus-5-5")
        XCTAssertEqual(v?.major, 5)
        XCTAssertEqual(v?.minor, 5)
    }

    /// [T-claude5-thinking-off] The per-model table from Anthropic's
    /// "Troubleshooting thinking" doc: each model gets the lowest setting it
    /// accepts, never a literal it 400s on and never an absent field that
    /// leaves Claude 5 thinking at its default effort.
    func testOffThinkingFollowsThePerModelTable() {
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-opus-4-8"), .disabled)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-opus-4-6"), .disabled)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-sonnet-5"), .disabled)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-sonnet-5-5"), .betweenTools)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-opus-5"), .lowEffort)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-fable-5-1"), .lowEffort)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-mythos-5"), .lowEffort)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "claude-sonnet-4-5"), .omit)
        XCTAssertEqual(AnthropicProvider.offThinking(for: "gpt-5"), .omit)
    }

    /// Anthropic gates `claude-opus-5-5` on `claude-cli >= 2.1.280`; an older
    /// fingerprint is refused with a 400 that reads like a bad catalog entry
    /// rather than a version gate. Monotonic, so Fable 5.1's own 2.1.251 floor
    /// still clears.
    func testClaudeCLIUserAgentClearsOpus55Gate() {
        let ua = ClaudeCLIMimicry.headers["User-Agent"] ?? ""
        XCTAssertTrue(ua.hasPrefix("claude-cli/"), ua)
        let version = ua.dropFirst("claude-cli/".count).prefix { $0 != " " }
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        XCTAssertEqual(parts.count, 3, "unexpected version shape: \(version)")
        let floor = [2, 1, 280]
        var cleared = false
        for i in 0..<3 where parts[i] != floor[i] { cleared = parts[i] > floor[i]; break }
        XCTAssertTrue(cleared || parts == floor,
                      "claude-cli \(version) is below the 2.1.280 Opus 5.5 gate")
    }
}
