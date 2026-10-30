//
//  AgentMode.swift
//  Minis
//
//  [T-minimal-mode] The "minimal mode" session flavour: a token-lean run of the
//  same agent, modelled on deepseek-harness's minimal mode.
//
//  Design rules, in order of importance:
//
//  1. Minimal mode is NOT a plugin. It is a property of a SESSION, chosen once
//     when the session is empty and then locked, because a mode flip mid-thread
//     would change the tool schema and the system prompt under a conversation
//     that was reasoned under the old ones.
//
//  2. It is an OVERLAY on the user's existing plugin switches, never a
//     replacement. Switching a plugin on inside minimal mode cannot resurrect
//     anything this policy forbids, and switching it off here never mutates the
//     user's stored preference — leaving minimal mode restores exactly what they
//     had configured before.
//
//  3. Token cost is the criterion, not "feature count". A capability that adds
//     a tool schema entry, a system-prompt section or a per-turn injection is
//     switched off. A capability that costs nothing to keep and that the agent
//     cannot work without — the sandbox backgrounding, mounted folders, the
//     secret-handling rules — stays.
//

import Foundation

// MARK: - Mode

/// How a session runs. Chosen at session start, immutable afterwards.
enum AgentMode: String, Codable, CaseIterable, Sendable {
    /// Everything the user has switched on.
    case normal
    /// Token-lean: only the capabilities listed in `MinimalModePolicy`.
    case minimal

    /// Localised label for the session badge and the slash menu.
    var displayName: String {
        switch self {
        case .normal: return AppLocalized("Normal")
        case .minimal: return AppLocalized("Minimal")
        }
    }

    /// One-line explanation shown under the mode picker / in the badge tooltip.
    var summary: String {
        switch self {
        case .normal:
            return AppLocalized("Every capability you have switched on.")
        case .minimal:
            return AppLocalized("Token-lean: prompt, tools and injections reduced to the essentials.")
        }
    }

    /// SF Symbol used for the badge.
    var symbol: String {
        switch self {
        case .normal: return "circle.lefthalf.filled"
        case .minimal: return "leaf.fill"
        }
    }
}

// MARK: - Policy

/// The single source of truth for what minimal mode allows.
///
/// Everything here is pure and static so it can be unit-tested without a running
/// app, and so the rules are readable in one place instead of scattered through
/// the agent loop.
enum MinimalModePolicy {

    // MARK: Built-in plugins

    /// Built-in plugins force-disabled in minimal mode, with the reason.
    ///
    /// Every entry earns its place by costing tokens on EVERY turn: a tool
    /// schema entry, a system-prompt section, or a per-turn file injection.
    ///
    /// Feature plugins only. A prompt module belongs in `keptPromptModules` (or
    /// nowhere); listing one here or in `keptBuiltins` would put a row on the
    /// settings page that describes the wrong mechanism.
    static let disabledBuiltins: [String: String] = [
        BuiltinExtension.soulID:
            "A persona section in every prompt, for flavour only.",
        BuiltinExtension.memoryID:
            "Injects GLOBAL.md plus the recent daily logs into every turn, and adds two tools.",
        BuiltinExtension.skillsID:
            "Injects every enabled skill's metadata into every turn.",
        BuiltinExtension.mcpID:
            "Adds an MCP tool surface whose schemas are billed on every request.",
        BuiltinExtension.todoID:
            "Four tools plus a chat panel, for planning bookkeeping.",
        BuiltinExtension.subagentsID:
            "Adds the delegation tool and a roster section to every prompt.",
    ]

    /// Built-in plugins that STAY ON, and are therefore deliberately absent from
    /// `disabledBuiltins`. Listed explicitly so the decision is visible rather
    /// than implied by an omission.
    static let keptBuiltins: [String: String] = [
        BuiltinExtension.mountsID:
            "Mounted external folders are how the user gets their own files in. Costs nothing per turn.",
        BuiltinExtension.sharedFoldersID:
            "Same: shared folders are a data path, not a prompt section.",
        BuiltinExtension.envVarsID:
            "API keys live here. Without them shell tasks that need a key cannot work, and the value costs nothing until used.",
    ]

    /// Whether a built-in plugin may contribute anything in minimal mode.
    ///
    /// A plugin not mentioned in either table is allowed: the two tables name
    /// exceptions, so a future plugin is token-lean by default rather than
    /// silently disabled.
    static func allowsBuiltin(_ id: String) -> Bool {
        disabledBuiltins[id] == nil
    }

    // MARK: Prompt modules

    /// Prompt modules kept in minimal mode.
    ///
    /// Only guidance the agent cannot act correctly without. Everything else —
    /// the Apple-framework catalogue, the CLI manuals, the coding workflow, the
    /// tone rules, the scheduled-task essay — is exactly the bulk minimal mode
    /// exists to drop, and the capabilities behind them stay reachable: the
    /// model can still run those commands, it just is not told about them.
    static let keptPromptModules: Set<String> = [
        // How to wait (delay) and why a turn must not end on a promise. Without
        // it the agent sleeps the shell or goes silent mid-task.
        BuiltinExtension.promptShellID,
        // Where files live and how minis:// works. Without it every attachment
        // and every link it produces is wrong.
        BuiltinExtension.promptWorkspaceID,
    ]

    /// Whether a prompt module contributes text in minimal mode.
    static func allowsPromptModule(_ id: String) -> Bool {
        keptPromptModules.contains(id)
    }

    // MARK: User-installed extensions

    /// Default for a user-installed extension in a minimal-mode session.
    ///
    /// Off. The objective is explicit: the installed list starts closed and the
    /// user opts in the ones a given minimal session needs.
    static let userExtensionDefaultEnabled = false

    /// Whether a user-installed extension may run, given the user's allowlist.
    /// The allowlist only ever ADDS to the default for that extension, so an
    /// extension the user has since disabled globally stays disabled.
    static func allowsUserExtension(_ id: String, allowlist: Set<String>) -> Bool {
        allowlist.contains(id)
    }

    // MARK: Addendum

    /// The whole system prompt for a minimal-mode session.
    ///
    /// Modelled on DeepSeek Harness's Minimal preset, which the objective names as
    /// the reference: it ships TWO tools (a persistent shell and one file editor),
    /// replaces the prompt with a single sentence of role, and drops from ~10k
    /// tokens of context to ~1k, because the published agentic benchmarks are run
    /// in exactly that configuration.
    ///
    /// So minimal mode does not derive its prompt from the full one by switching
    /// sections off — it REPLACES it. A trimmed 27 KB prompt is still the full
    /// prompt's shape, and the point of the reference design is that the model
    /// stops carrying the shape at all.
    ///
    /// The three things kept beyond the role sentence are the ones whose absence
    /// produces wrong output rather than merely less capable output: where shared
    /// files live (every link the model writes depends on it), how to wait
    /// (`delay` instead of `sleep`, so a wait does not occupy the shell), and what
    /// is switched off (so it does not offer a memory it does not have).
    static var prompt: String {
        """
        You are a helpful software engineering assistant.

        You have exactly two tools:
        - shell_execute: run any shell command in a persistent Linux environment.
          Inspect files with `cat`, `rg`, `sed` — there is no read tool.
        - file_write: create or overwrite a file. Preferred over heredocs for any
          content that would need shell quoting.

        Waiting: pass shell_execute's `delay` parameter instead of `sleep`, so the
        wait does not hold the shell. Never end a turn promising to check something
        later — nothing runs until the user's next message.

        Shared files (the only paths the app can show the user):
        - /var/minis/workspace/ working files, link with [name](minis://workspace/file)
        - /var/minis/attachments/ images, audio, video; ![desc](minis://attachments/file)
        - /var/minis/offloads/ auto-saved large outputs
        - /var/minis/shared/ cross-session storage

        Minimal mode is ON. Persona, memory, skills, MCP servers, the todo tools and
        sub-agents are switched off; do not offer or attempt them. A normal-mode
        session has them.

        """
    }

    /// Names of the tools a minimal-mode session is given.
    ///
    /// Two, matching the reference design. Everything else — the three file tools,
    /// browser, user_ask, extension tools — is absent from the schema, so the model
    /// is never charged for it.
    static let toolNames: Set<String> = ["shell_execute", "file_write"]

    // MARK: One-shot intent

    /// A mode waiting to be applied to the next session that gets created.
    ///
    /// [T-minimal-mode] The settings page has a button that starts a minimal
    /// session directly. The session row does not exist until the first message
    /// is sent (`ensureSession`), so the choice has to travel: it is stored here,
    /// consumed where the row is created, and cleared so it applies exactly once.
    ///
    /// Deliberately NOT the same key as a session's own mode: an intent is an
    /// unsaved wish, and a crash before the first message must not leave the app
    /// silently treating some later session as minimal.
    enum Intent {
        static let key = "minimalMode.pendingMode"

        static var pending: AgentMode? {
            get {
                guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
                return AgentMode(rawValue: raw)
            }
            set {
                if let newValue { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    // MARK: Settings surface

    /// UserDefaults keys. Namespaced under `minimalMode.` so the feature can be
    /// found, backed up and audited as one unit.
    enum Key {
        /// Master switch: advertise the mode in the slash menu at all.
        static let enabled = "minimalMode.enabled"
        /// Per-extension opt-in allowlist, one boolean per extension id.
        static let allowPrefix = "minimalMode.allow."
        /// The allowlist, for a UI that needs to diff it.
        static func allow(_ extensionID: String) -> String { allowPrefix + extensionID }
    }
}
