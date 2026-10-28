import XCTest
@testable import Minis

/// [T-quicktest-opencode-session] A Quick Test is its own conversation with a
/// fresh random id.
///
/// OpenCode Go rejects any request without `x-opencode-session`
/// ("400 Request is missing x-opencode-session and cannot be routed"). A Quick
/// Test belongs to no chat and used to build its provider with no session id,
/// so every Quick Test of an OpenCode Go model failed.
@MainActor
final class QuickTestOpenCodeSessionTests: XCTestCase {

    private var model: LLMModel {
        LLMModel(id: "deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash", provider: "OpenAI")
    }
    private func provider(base: String) -> OpenAIProvider {
        OpenAIProvider(apiKey: "k", model: model, customBaseURL: base, appendV1Suffix: false)
    }
    /// What LLMProviderFactory does for an instance on the OpenCode channel.
    private func onChannel(_ p: OpenAIProvider, sessionId: String?) -> OpenAIProvider {
        OpenCodeChannel.attach(to: p, resolveSessionId: { sessionId })
    }
    private func header(_ p: OpenAIProvider) -> String? {
        p.perRequestHeaders?(["messages": []])[OpenCodeChannel.sessionHeader]
    }

    func testAQuickTestIdIsAValidUUIDAndFreshEachRun() {
        let a = TestSession.quickTestSessionId(), b = TestSession.quickTestSessionId()
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertNotNil(UUID(uuidString: b))
        XCTAssertNotEqual(a, b, "one conversation per run, never a shared placeholder")
        XCTAssertNotNil(OpenCodeChannel.normalizedSessionId(a), "the channel accepts it as a real session id")
    }

    func testAnOpenCodeChannelProviderBuiltForAQuickTestCarriesTheHeader() throws {
        let p = onChannel(provider(base: "https://opencode.ai/zen/go/v1"), sessionId: TestSession.quickTestSessionId())
        let sent = try XCTUnwrap(header(p), "the request would be rejected with 400 without it")
        XCTAssertNotNil(UUID(uuidString: sent))
        XCTAssertEqual(header(p), sent, "the same id on every request of that one test")
    }

    /// [T-opencode-every-entry] Voice correction, folder suggestion, Vision and
    /// model_use outside a chat each pass a one-off id instead of none.
    func testAOneOffIdIsFreshAndReachesTheHeader() throws {
        let a = OpenCodeChannel.oneOffSessionId(), b = OpenCodeChannel.oneOffSessionId()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(UUID(uuidString: a))
        let p = onChannel(provider(base: "https://opencode.ai/zen/go/v1"), sessionId: a)
        XCTAssertEqual(try XCTUnwrap(header(p)), a)
    }

    func testWithoutASessionIdTheHeaderIsOmittedWhichIsWhatFailed() {
        let p = onChannel(provider(base: "https://opencode.ai/zen/go/v1"), sessionId: nil)
        XCTAssertNil(header(p))
    }

    func testAProviderThatIsNotOnTheChannelNeverSendsTheHeader() {
        let p = provider(base: "https://api.deepseek.com/v1")
        XCTAssertNil(p.perRequestHeaders, "no hook is installed for other providers")
        XCTAssertNil(header(p))
        XCTAssertFalse(OpenCodeChannel.looksLikeOpenCodeBaseURL("https://api.deepseek.com/v1"))
        XCTAssertTrue(OpenCodeChannel.looksLikeOpenCodeBaseURL("https://opencode.ai/zen/go/v1"))
    }
}
