import Foundation

// MARK: - Cross-Provider Helpers

/// Sanitize a tool-use ID so it is valid for all providers.
/// Anthropic requires `^[a-zA-Z0-9_-]+$`; OpenAI Responses API can produce
/// IDs containing `|` (e.g. `call_xxx|fc_yyy`).  Replace any disallowed
/// character with `-`.
func sanitizeToolId(_ id: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
}

// MARK: - Canonical Tool Definitions

/// Canonical tool definition used by the agent loop — provider-agnostic.
struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]
    /// Explicit property generation order. When provided, providers that support it
    /// (e.g. Gemini) will instruct the model to emit parameters in this order.
    let propertyOrdering: [String]?

    init(name: String, description: String, parameters: [String: AgentToolParam], required: [String], propertyOrdering: [String]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
        self.propertyOrdering = propertyOrdering
    }
}

struct AgentToolParam {
    let type: AgentParamType
    let description: String
    let enumValues: [String]?
    /// [T-user-ask] Nested schema for a structured (array) parameter — the
    /// three scalar types cannot express `user_ask.questions` (an array of
    /// question objects, each with an array of option objects). Providers
    /// render it in their own schema dialect; scalars leave it nil.
    let schema: AgentSchemaNode?

    init(type: AgentParamType, description: String, enumValues: [String]? = nil, schema: AgentSchemaNode? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.schema = schema
    }
}

enum AgentParamType: String {
    case string
    case integer
    case boolean
    /// [T-user-ask] Requires `AgentToolParam.schema`.
    case array
}

/// [T-user-ask] A provider-neutral JSON Schema subset: scalars, arrays and
/// objects (objects only as array items — the Anthropic SDK's Property type
/// has no `properties`). Bounds and item `required` lists are advisory: the
/// tool's parser re-validates, since not every provider accepts them.
indirect enum AgentSchemaNode {
    case string(description: String?, enumValues: [String]? = nil)
    case integer(description: String?)
    case boolean(description: String?)
    case array(description: String?, items: AgentSchemaNode, minItems: Int? = nil, maxItems: Int? = nil)
    case object(description: String?, properties: [(name: String, node: AgentSchemaNode)], required: [String])

    /// Standard JSON Schema. `uppercaseTypes` + `bounds: false` = the Gemini
    /// dialect (STRING/ARRAY/OBJECT, enums folded into the description).
    func jsonSchema(uppercaseTypes: Bool = false, bounds: Bool = true) -> [String: Any] {
        func t(_ s: String) -> String { uppercaseTypes ? s.uppercased() : s }
        var o: [String: Any] = [:]
        switch self {
        case .string(let d, let e):
            o["type"] = t("string")
            if let e, !e.isEmpty, uppercaseTypes {
                o["description"] = "\(d ?? "") (values: \(e.joined(separator: ", ")))"
            } else {
                if let d { o["description"] = d }
                if let e { o["enum"] = e }
            }
        case .integer(let d):
            o["type"] = t("integer")
            if let d { o["description"] = d }
        case .boolean(let d):
            o["type"] = t("boolean")
            if let d { o["description"] = d }
        case .array(let d, let items, let minItems, let maxItems):
            o["type"] = t("array")
            if let d { o["description"] = d }
            o["items"] = items.jsonSchema(uppercaseTypes: uppercaseTypes, bounds: bounds)
            if bounds, let minItems { o["minItems"] = minItems }
            if bounds, let maxItems { o["maxItems"] = maxItems }
        case .object(let d, let props, let required):
            o["type"] = t("object")
            if let d { o["description"] = d }
            var p: [String: Any] = [:]
            for (name, node) in props { p[name] = node.jsonSchema(uppercaseTypes: uppercaseTypes, bounds: bounds) }
            o["properties"] = p
            if !required.isEmpty { o["required"] = required }
        }
        return o
    }

    /// All descriptions / names / enum values, for the context-size estimate.
    var estimationText: String {
        switch self {
        case .string(let d, let e): return [d ?? "", (e ?? []).joined(separator: " ")].joined(separator: " ")
        case .integer(let d), .boolean(let d): return d ?? ""
        case .array(let d, let items, _, _): return (d ?? "") + " " + items.estimationText
        case .object(let d, let props, _):
            return (d ?? "") + " " + props.map { $0.name + " " + $0.node.estimationText }.joined(separator: " ")
        }
    }
}

// MARK: - Agent Messages

/// A single content part in agent messages — provider-agnostic.
enum AgentContentPart: @unchecked Sendable {
    case text(String)
    /// `isOffloadedArgument` — [T-offload-stub-system-reminder issue #374]. True
    /// when the context offloader replaced this call's `content` argument with a
    /// pruned-argument notice because the real payload was moved to
    /// `/var/minis/offloads/…`. The `.toolResult` case has carried
    /// `isOffloadReadback` since GH#343 for the same reason: the scanner cannot
    /// tell its own output from new material by reading the text.
    ///
    /// Provenance, not presentation: the notice text is also detectable via
    /// `AIChatViewModel.isOffloadedStub`, but that is a string test on a payload
    /// the model can imitate, whereas this flag is set only by the offloader.
    /// Defaults to `false` so every existing construction site and all history
    /// persisted before this change decode unchanged.
    case toolUse(id: String, name: String, input: [String: Any], isOffloadedArgument: Bool = false)
    /// `imageLinuxPath` — iSH-visible linux path the image bytes were
    /// persisted to (e.g. `/var/minis/browser/<sid>/screenshot_*.jpg`,
    /// `/var/minis/attachments/uploads/*`). Carried so the request-level
    /// image budget can emit a re-fetchable text placeholder when the
    /// cumulative payload would exceed the 25MB cap. Defaults to nil for
    /// backward compatibility with existing call sites and persisted
    /// history.
    ///
    /// `isOffloadReadback` — [T-offload-readback-loop] GH#343. True when this
    /// result is the content of a file the offloader itself wrote, fetched back
    /// by `file_read` against `/var/minis/offloads/…`.
    ///
    /// It exists because the two places that decide what to offload cannot tell
    /// that from the text: the candidate scanner skipped anything starting with
    /// `[CONTEXT OFFLOADED]`, and a read-BACK carries the original payload with
    /// no such prefix, so it re-entered as a brand-new candidate and was written
    /// to a second file, whose stub the model then read, and so on. Reproduced
    /// on an iPhone 11: context oscillated 123K→108K→124K→109K chars across
    /// four rounds while `bigInCtx` stayed at 6 — no net progress, one new file
    /// per lap.
    ///
    /// A flag rather than more text-sniffing: the marker travels with the part
    /// from the moment the read happens, so neither path has to re-derive it
    /// from a string whose format can change (`file_read` prepends its own
    /// `[path | N bytes | …]` header, which is exactly what a prefix check
    /// would trip over).
    ///
    /// Defaults to false so every existing call site and all persisted history
    /// decode unchanged.
    case toolResult(id: String, name: String, content: String, isError: Bool, imageData: Data? = nil, imageMimeType: String? = nil, pageURL: String? = nil, imageLinuxPath: String? = nil, isOffloadReadback: Bool = false)
    /// `linuxPath` — same semantics as above. Used for user attachments
    /// and read_image results that don't ride through .toolResult.
    case imageData(data: Data, mimeType: String, linuxPath: String? = nil)
}

/// Native reasoning payload captured from the provider response, used to
/// preserve chain-of-thought across multi-turn requests. Lives **in memory
/// only** (not persisted) — restart loses encrypted content, which is
/// acceptable because the visible text + tool history is unchanged.
///
/// Each echo is tagged with the producing model so cross-model switches
/// (e.g. gpt-5.5 → deepseek) can be detected and the encrypted payload
/// stripped — encrypted_content is model-specific and meaningless to a
/// different model family.
struct ReasoningEcho: @unchecked Sendable {
    /// Stable provider family tag; matches `OpenAIAgentProvider.responsesAPIProviderKind`
    /// etc. Different families never share schemas.
    let providerKind: String
    /// Concrete model id (e.g. "gpt-5.5", "o3-mini"). Encrypted payloads are
    /// only safe to echo back to the **same** model id within the same
    /// provider family.
    let modelId: String
    /// [T-responses-reasoning-inherit issue #368] The upstream that minted these
    /// items (`OpenAIAgentProvider.reasoningUpstreamIdentity` — the custom base
    /// URL, or "openai-official"). `encrypted_content` is decryptable only by
    /// that endpoint, so this — not `modelId` — is what decides whether a replay
    /// is safe.
    ///
    /// Defaulted so every existing construction site and all in-flight history
    /// keep compiling; an echo with no recorded upstream is replayed on the
    /// model-id match alone, i.e. the pre-#368 behaviour.
    var upstreamIdentity: String? = nil
    /// Reasoning items captured in original emission order — must be
    /// re-inserted into the next request's input array in the same order
    /// (Responses API rejects out-of-order reasoning items).
    let items: [Item]

    enum Item: @unchecked Sendable {
        /// OpenAI Responses API reasoning item.
        case openaiReasoning(id: String, encryptedContent: String?, summary: [String])
    }
}

// MARK: - ReasoningEcho persistence [T-responses-echo-persist]

extension ReasoningEcho {
    /// Wire form written to `messages.reasoning_echo`.
    ///
    /// `encryptedContent` is intentionally absent: it is large, endpoint-bound,
    /// and cannot be decrypted by any endpoint but the one that minted it, so
    /// persisting it across a restart would cost bytes for a payload we must
    /// drop the moment the upstream differs. What DOES need to survive is the
    /// server-minted `id` — the only value that may legally appear as
    /// `reasoning.id` in a later request — plus `upstreamIdentity`, without
    /// which the replay gate cannot tell a same-relay resume from a hop.
    private struct Wire: Codable {
        struct Item: Codable {
            let id: String
            let summary: [String]
        }
        let providerKind: String
        let modelId: String
        let upstreamIdentity: String?
        let items: [Item]
    }

    /// JSON for persistence, or nil when there is nothing worth storing.
    var persistableJSON: String? {
        let wire = Wire(
            providerKind: providerKind,
            modelId: modelId,
            upstreamIdentity: upstreamIdentity,
            items: items.compactMap { item in
                if case .openaiReasoning(let id, _, let summary) = item {
                    return Wire.Item(id: id, summary: summary)
                }
                return nil
            }
        )
        guard !wire.items.isEmpty,
              let data = try? JSONEncoder().encode(wire) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Rebuild from `persistableJSON`. Items come back with no
    /// `encryptedContent`, which is the documented degradation above.
    init?(persistedJSON json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              !wire.items.isEmpty else { return nil }
        self.init(
            providerKind: wire.providerKind,
            modelId: wire.modelId,
            upstreamIdentity: wire.upstreamIdentity,
            items: wire.items.map { .openaiReasoning(id: $0.id, encryptedContent: nil, summary: $0.summary) }
        )
    }
}

/// A message in the agent conversation.
struct AgentMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    var parts: [AgentContentPart]
    /// True when this assistant message was interrupted mid-stream (e.g. network drop).
    /// tool_use blocks inside may have incomplete/empty inputs (partialJson never finished).
    /// Placeholder tool_results must NOT be injected for interrupted messages, because
    /// sending a tool_result for a tool_use with empty input causes API 400 errors.
    var isInterrupted: Bool = false
    /// Opaque reasoning content from thinking models (e.g. Kimi, DeepSeek, QwQ).
    /// Must be echoed back on assistant messages for multi-turn conversations.
    var reasoningContent: String?
    /// Native reasoning payload (Responses-API encrypted items, etc.). In
    /// memory only — see `ReasoningEcho` for cross-model isolation rules.
    var reasoningEcho: ReasoningEcho?
    /// DB message id (RawMessage.id) once this message has been persisted.
    /// Populated by persistAgentMessage after buildRawMessage succeeds, or by
    /// loadSession on restore. Used by compact logic to resolve marker boundaries
    /// via id instead of sort_order. nil while the message is still in-flight
    /// (e.g. mid-stream before persist).
    var dbMessageId: String? = nil
    /// [T-edit-anchor-link] In-memory identity linking a user-bubble entry to
    /// its chat bubble(s) (`ChatMessage.historyAnchorId`). Never persisted or
    /// synced: every load mints fresh ones on both sides from the same row.
    /// Survives in-place part edits (the struct is copied, not rebuilt).
    var anchorId = UUID()
}

// MARK: - Stream Events

/// Stream events from an agent provider — unified across Anthropic/Gemini.
enum AgentStreamEvent: @unchecked Sendable {
    /// A new content block started (text or tool).
    case contentBlockStart(AgentBlockStart)
    /// Incremental text delta.
    case textDelta(String)
    /// Tool input update (for streaming JSON preview).
    /// `accumulated` is the full JSON so far, `name` is the tool name.
    case toolInputDelta(name: String, accumulated: String)
    /// Tool call completed with final parsed arguments.
    case toolCallComplete(id: String, name: String, args: [String: Any], metadata: ToolCallMetadata?)
    /// Usage stats.
    case usage(LLMUsage)
    /// [T-agent-model-identity] The model name the API REPORTED for this
    /// response (Anthropic `message.model`, OpenAI chunk / `response.model`,
    /// Gemini `modelVersion`). Emitted once per response where the provider
    /// exposes it; consumers must tolerate its absence.
    case responseModel(String)
    /// Real-time thinking content delta for live UI display.
    case thinkingDelta(String)
    /// Accumulated reasoning content from thinking models (opaque, must be echoed back).
    case reasoningContent(String)
    /// Native reasoning payload (e.g. OpenAI Responses-API encrypted items)
    /// for in-memory multi-turn replay. Cross-model isolation rules live on
    /// `ReasoningEcho`.
    case reasoningEcho(ReasoningEcho)
    /// [T-sse-idle-timeout] The server sent real model output that produced no
    /// other event - reasoning that is not being shown because the thinking
    /// level is off. Carries nothing: it only tells the stall watchdog the
    /// stream is alive. Never sent for keepalives, comments or empty chunks.
    case streamActivity
    /// Response finished.
    case done(stopReason: AgentStopReason)
}

enum AgentBlockStart: Sendable {
    case text
    case toolUse(id: String, name: String)
}

enum AgentStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
    /// Anthropic safety classifier declined the request (HTTP 200 + `stop_reason: "refusal"`,
    /// input tokens billed, empty `content`). Distinct from `.endTurn` so the agent loop can
    /// surface an actionable message instead of a generic "empty response" and skip the
    /// pointless transient-retry path (a refusal is deterministic, not transient).
    /// Fires as a false-positive on Fable 5 for benign turns carrying the large agentic
    /// system prompt + tool set (OAuth path). See [T-ios-fable5-empty-response].
    case refusal
}

/// Provider-specific metadata attached to a tool call (e.g. Gemini thought signatures).
struct ToolCallMetadata: @unchecked Sendable {
    let thoughtSignature: String?
}

// MARK: - Protocol

/// Protocol for providers that support the agent loop (streaming + tool use).
protocol AgentProvider {
    var name: String { get }
    var model: LLMModel { get }
    /// Default max output tokens for this provider.
    var defaultMaxTokens: Int { get }
    /// [T-sse-idle-timeout] How long the agent loop waits for the next stream
    /// event (the first one included) before calling the stream stalled.
    /// 120 s unless a provider says otherwise; only the OpenAI-compatible
    /// Chat Completions path reads a per-provider setting.
    var responseIdleTimeout: TimeInterval { get }

    /// Provider-specific streaming implementation. Receives a thinking level
    /// that has already been clamped to the model's effective max by the
    /// protocol extension — implementations should NOT re-clamp.
    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// [T-ctx-count-reasoning] Whether a request from this provider carries the
    /// `reasoningContent` of past assistant turns back to the server. The
    /// context meter counts that text only when it is really sent, so each
    /// provider answers with the same gate its request builder uses.
    func echoesReasoningContent(thinkingLevel: ThinkingLevel) -> Bool
}

// BEGIN ResponseIdleTimeoutSetting
/// [T-sse-idle-timeout] The per-provider "response idle timeout": the longest
/// wait for the next piece of a streamed reply, the first piece included. It is
/// NOT a limit on how long a reply may take - a stream that keeps delivering
/// never times out.
///
/// Stored per device in UserDefaults, keyed by provider instance id. Nothing
/// stored means the default, so existing providers behave exactly as before.
/// Deliberately not a ProviderInstance field: that would need a DB column and
/// sync / backup wiring for a value that describes this device's link to one
/// server.
enum ResponseIdleTimeoutSetting {
    static let defaultSeconds = 120
    static let minSeconds = 30
    /// No "never": a stream that really died would leave the turn waiting
    /// forever, holding a session slot and the background keep-alive.
    static let maxSeconds = 3600
    static let presets = [120, 300, 600, 1800, 3600]

    static func clamp(_ seconds: Int) -> Int { min(max(seconds, minSeconds), maxSeconds) }

    static func key(forInstanceId id: String) -> String { "provider.responseIdleTimeout.\(id)" }

    /// The effective value: the stored one, clamped, or the default.
    static func seconds(forInstanceId id: String?, defaults: UserDefaults = .standard) -> Int {
        guard let id, !id.isEmpty, let stored = defaults.object(forKey: key(forInstanceId: id)) as? Int else {
            return defaultSeconds
        }
        return clamp(stored)
    }

    /// Storing the default removes the key, so "default" stays "never set".
    static func set(_ seconds: Int?, forInstanceId id: String, defaults: UserDefaults = .standard) {
        guard let seconds, clamp(seconds) != defaultSeconds else {
            defaults.removeObject(forKey: key(forInstanceId: id))
            return
        }
        defaults.set(clamp(seconds), forKey: key(forInstanceId: id))
    }

    /// The per-request URLSession timeout a streaming request needs so the
    /// transport does not give up before the watchdog does. nil = leave the
    /// session's own 600 s alone.
    static func requestTimeout(forIdleSeconds idle: Int, sessionDefault: Int = 600) -> TimeInterval? {
        idle > sessionDefault ? TimeInterval(idle + 30) : nil
    }
}
// END ResponseIdleTimeoutSetting

extension AgentProvider {
    var responseIdleTimeout: TimeInterval { TimeInterval(ResponseIdleTimeoutSetting.defaultSeconds) }

    /// Gemini, Antigravity and the Responses API replay reasoning in their own
    /// signed / encrypted form, never as `reasoningContent` text.
    func echoesReasoningContent(thinkingLevel: ThinkingLevel) -> Bool { false }

    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let clamped = min(thinkingLevel, model.catalogMaxThinkingLevel)
        return try await streamAgentMessageClamped(
            messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, thinkingLevel: clamped
        )
    }

    /// Default: thinking off.
    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamAgentMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, thinkingLevel: .off)
    }
}

