//
//  ScheduledPresetToolCall.swift
//  MinisApp
//
//  [T-scheduled-preset-tool] A tool call fixed when a scheduled task is
//  created (`minis-scheduled create … --command "<shell>"`), executed as the first step of every
//  fire instead of asking the model to decide on it.
//
//  Without it a fire costs at least two model requests: one to decide on the
//  (always identical) tool call, one to summarise its result. With it the
//  agent loop feeds this call to `processStreamEvents` as a synthetic first
//  response, so the card, the assistant tool_use, the real tool execution and
//  the tool_result are all produced by the unchanged code path, and the only
//  model request is the summary.
//
//  Foundation only: the standalone tests compile this file directly.
//

import Foundation

struct ScheduledPresetToolCall: Codable, Equatable, Sendable {

    /// One case per supported tool, with typed arguments. Add a case (and its
    /// `toolName` / `toolArguments` mapping) to support another tool.
    enum Kind: Codable, Equatable, Sendable {
        case shell(command: String, timeoutSeconds: Int?)
    }

    var kind: Kind

    static let shellToolName = "shell_execute"
    static let maxCommandLength = 16_000
    static let timeoutRange: ClosedRange<Int> = 1...3600

    var toolName: String {
        switch kind {
        case .shell: return Self.shellToolName
        }
    }

    /// The arguments exactly as a model would send them. `title` fills the
    /// required `tool_title` (shown on the card).
    func toolArguments(title: String) -> [String: Any] {
        switch kind {
        case .shell(let command, let timeout):
            var args: [String: Any] = ["tool_title": title, "command": command]
            // NSNumber: the shell executor reads `timeout` as NSNumber, as it
            // arrives from a model's JSON.
            if let timeout { args["timeout"] = NSNumber(value: timeout) }
            return args
        }
    }

    /// `list` / `create` output.
    var summary: [String: Any] {
        switch kind {
        case .shell(let command, let timeout):
            var d: [String: Any] = ["tool": toolName, "command": command]
            if let timeout { d["timeout"] = timeout }
            return d
        }
    }

    /// Extra envelope line, present only for jobs with a preset — jobs without
    /// one keep a byte-identical envelope.
    var envelopeNote: String {
        "[This task's first step already ran for you: \(toolName) — its call and output follow. Work from that output; re-run only if it failed.]\n"
    }

    /// Anthropic requires `^[a-zA-Z0-9_-]+$`; OpenAI / Gemini accept any string.
    static func makeToolUseId() -> String {
        "toolu_sched_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    // MARK: - CLI parsing

    /// Builds the preset from `minis-scheduled create` flags.
    /// - `command`: `--command "<sh>"` (alias `--shell`), the shell shorthand
    /// - `timeout`: `--command-timeout <duration>`, already parsed to seconds
    /// - `tool` / `toolArgs`: generic `--tool <name> --tool-args '<json>'`
    /// Returns `.success(nil)` when no preset flag was given.
    static func fromCLI(command: String?, timeoutSeconds: Double?, tool: String?,
                        toolArgs: String?) -> Result<ScheduledPresetToolCall?, PresetError> {
        guard command != nil || tool != nil || toolArgs != nil || timeoutSeconds != nil else {
            return .success(nil)
        }
        if command != nil, toolArgs != nil {
            return .failure(.invalid("use either --command or --tool/--tool-args, not both"))
        }
        let toolName = tool.map(normalizeToolName) ?? shellToolName
        guard toolName == shellToolName else {
            return .failure(.invalid("--tool \(tool ?? "") is not supported as a preset tool yet; only shell_execute (alias: shell) is"))
        }

        var cmd = command
        // [T-scheduled-duration-finite] Range-check the Double BEFORE the Int
        // conversion: Int(_: Double) traps on inf / nan / > Int.max, and this
        // runs inside the app process (minis-scheduled is an in-process offload).
        if let t = timeoutSeconds, !(t.isFinite && t >= Double(timeoutRange.lowerBound) - 0.5
                                     && t <= Double(timeoutRange.upperBound) + 0.5) {
            return .failure(.invalid("--command-timeout must be between 1s and 1h"))
        }
        var timeout: Int? = timeoutSeconds.map { Int($0.rounded()) }
        if let toolArgs {
            guard let data = toolArgs.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.invalid("--tool-args must be a JSON object, e.g. '{\"command\":\"date\"}'"))
            }
            let unknown = Set(obj.keys).subtracting(["command", "timeout", "tool_title"])
            guard unknown.isEmpty else {
                return .failure(.invalid("--tool-args: unsupported key(s) \(unknown.sorted().joined(separator: ", ")) for shell_execute (allowed: command, timeout)"))
            }
            guard let c = obj["command"] as? String else {
                return .failure(.invalid("--tool-args needs a \"command\" string"))
            }
            cmd = c
            if let t = obj["timeout"] {
                guard let n = t as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                    return .failure(.invalid("--tool-args \"timeout\" must be a number of seconds"))
                }
                if timeout == nil {
                    let d = n.doubleValue
                    guard d.isFinite, d >= Double(timeoutRange.lowerBound) - 0.5,
                          d <= Double(timeoutRange.upperBound) + 0.5 else {
                        return .failure(.invalid("--command-timeout must be between 1s and 1h"))
                    }
                    timeout = Int(d.rounded())
                }
            }
        }

        guard let cmd, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalid("--command needs a shell command"))
        }
        guard cmd.count <= maxCommandLength else {
            return .failure(.invalid("--command is longer than \(maxCommandLength) characters; put the script in a file and run that file"))
        }
        if let t = timeout, !timeoutRange.contains(t) {
            return .failure(.invalid("--command-timeout must be between 1s and 1h"))
        }
        return .success(ScheduledPresetToolCall(kind: .shell(command: cmd, timeoutSeconds: timeout)))
    }

    static func normalizeToolName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return (t == "shell" || t == "sh" || t == "bash") ? shellToolName : t
    }

    enum PresetError: Error, Equatable {
        case invalid(String)
        var message: String { if case .invalid(let m) = self { return m }; return "" }
    }

    // MARK: - Which pending presets belong to the turn about to be requested

    /// Job ids whose preset should run now.
    ///
    /// A preset runs only when its OWN scheduled envelope is part of the
    /// trailing user messages — the user turn the next request answers. That
    /// ties the preset to the fire that created it regardless of how the
    /// envelope got there (sent at once, drained from the queue, injected at
    /// the finish branch, batched with other queued prompts), and a turn that
    /// died before its request can never leak the command into the user's next
    /// typed turn: that turn's tail carries no matching envelope.
    ///
    /// - `trailingUserTexts`: text parts of the user messages after the last
    ///   assistant message (tool_result-only messages contribute nothing).
    /// - `scheduledJobId`: returns the job id of a `kind="scheduled"` envelope
    ///   in a text, or nil.
    static func jobIdsToRun(trailingUserTexts: [String], pending: Set<String>,
                            scheduledJobId: (String) -> String?) -> [String] {
        guard !pending.isEmpty else { return [] }
        var out: [String] = []
        for text in trailingUserTexts {
            guard let id = scheduledJobId(text), pending.contains(id), !out.contains(id) else { continue }
            out.append(id)
        }
        return out
    }
}

/// One fire's preset, handed from `ScheduledJobRunner.fire` to the session's
/// view model and kept there until the fire's turn is requested.
struct ScheduledPresetToolCallRequest: Equatable, Sendable {
    let jobId: String
    let call: ScheduledPresetToolCall
    /// `tool_title` for the card: the job's label, else its title.
    let title: String
}
