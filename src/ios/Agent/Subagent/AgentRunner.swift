import Foundation

// MARK: - Sub-Agent Runner

/// A lightweight, self-contained agent loop for sub-agent delegation.
///
/// Unlike `AIChatViewModel` (the full chat agent), `AgentRunner` owns just:
///   - a message history array (in memory, never persisted)
///   - a bounded loop: stream a response → execute any tool calls → repeat
///   - hard termination: `maxTurns` and `timeoutSeconds`
///
/// Tool execution is injected as closures (`executor`) so the runner stays
/// decoupled from the iSH coordinator and the chat view model. This mirrors
/// `OnDemandBash`'s injection pattern and keeps the runner unit-testable.
actor AgentRunner {

    struct Executor {
        /// Execute a tool by name with JSON args. Returns (output, isError).
        var execute: @Sendable (String, [String: Any]) async -> (String, Bool)
    }

    struct Config {
        var maxTurns: Int = 25
        var timeoutSeconds: TimeInterval = 600
        var thinkingLevel: ThinkingLevel = .off
        var maxTokens: Int = 4096
    }

    /// Final result of a sub-agent run.
    struct Result: Sendable {
        let text: String
        let toolCalls: Int
        let turns: Int
        let usage: LLMUsage?
        let stopReason: AgentStopReason?
        let error: String?
    }

    private let provider: AgentProvider
    private let systemPrompt: String
    private let tools: [AgentToolDefinition]
    private let executor: Executor
    private let config: Config

    init(
        provider: AgentProvider,
        systemPrompt: String,
        tools: [AgentToolDefinition],
        executor: Executor,
        config: Config = Config()
    ) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.executor = executor
        self.config = config
    }

    /// Run the sub-agent to completion for the given task.
    func run(task: String) async -> Result {
        let deadline = Date().addingTimeInterval(config.timeoutSeconds)
        var messages: [AgentMessage] = [
            AgentMessage(role: .user, parts: [.text(task)])
        ]
        var toolCalls = 0
        var turns = 0
        var lastStopReason: AgentStopReason?
        var lastUsage: LLMUsage?

        while turns < config.maxTurns {
            // Hard timeout: stop cleanly rather than burning budget.
            if Date() > deadline {
                return Result(
                    text: messages.compactMap { partText($0) }.joined(separator: "\n"),
                    toolCalls: toolCalls, turns: turns,
                    usage: lastUsage, stopReason: lastStopReason,
                    error: "Timed out after \(Int(config.timeoutSeconds))s"
                )
            }

            do {
                let stream = try await provider.streamAgentMessage(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    maxTokens: config.maxTokens,
                    thinkingLevel: config.thinkingLevel
                )

                var text = ""
                var pendingToolUses: [PendingToolUse] = []
                var doneReason: AgentStopReason?

                for try await event in stream {
                    switch event {
                    case .textDelta(let delta):
                        text += delta
                    case .toolCallComplete(let id, let name, let args, _):
                        pendingToolUses.append(PendingToolUse(id: id, name: name, args: args))
                    case .usage(let u):
                        lastUsage = u
                    case .done(let reason):
                        doneReason = reason
                    default:
                        break
                    }
                }

                lastStopReason = doneReason
                turns += 1

                // Build the assistant message (text + tool uses).
                var assistantParts: [AgentContentPart] = []
                if !text.isEmpty {
                    assistantParts.append(.text(text))
                }
                for tu in pendingToolUses {
                    assistantParts.append(.toolUse(id: tu.id, name: tu.name, input: tu.args))
                }
                if !assistantParts.isEmpty {
                    messages.append(AgentMessage(role: .assistant, parts: assistantParts))
                }

                // No tool calls → the sub-agent is done.
                if pendingToolUses.isEmpty {
                    return Result(
                        text: text,
                        toolCalls: toolCalls, turns: turns,
                        usage: lastUsage, stopReason: doneReason,
                        error: nil
                    )
                }

                // Execute tools and append results.
                var resultParts: [AgentContentPart] = []
                for tu in pendingToolUses {
                    toolCalls += 1
                    let (output, isError) = await executor.execute(tu.name, tu.args)
                    resultParts.append(.toolResult(
                        id: tu.id, name: tu.name,
                        content: output, isError: isError
                    ))
                }
                if !resultParts.isEmpty {
                    messages.append(AgentMessage(role: .user, parts: resultParts))
                }
            } catch {
                return Result(
                    text: "", toolCalls: toolCalls, turns: turns,
                    usage: lastUsage, stopReason: lastStopReason,
                    error: error.localizedDescription
                )
            }
        }

        return Result(
            text: "", toolCalls: toolCalls, turns: turns,
            usage: lastUsage, stopReason: lastStopReason,
            error: "Reached max turns (\(config.maxTurns))"
        )
    }

    // MARK: - Helpers

    private struct PendingToolUse {
        let id: String
        let name: String
        let args: [String: Any]
    }

    private func partText(_ msg: AgentMessage) -> String? {
        var out: [String] = []
        for part in msg.parts {
            if case .text(let t) = part {
                out.append(t)
            }
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
