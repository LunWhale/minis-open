//
//  AIChatViewModel+AgentMode.swift
//  Minis
//
//  [T-minimal-mode] Choosing a session's mode, and the guards that make the
//  choice honest.
//
//  The mode is picked from the slash menu on an EMPTY session and is immutable
//  from then on. Three separate things have to agree for that to be true, so all
//  three are enforced here rather than in the picker:
//
//  1. the view model must not accept a change once it is minimal;
//  2. the store must refuse it too (a stale VM must not be able to write it);
//  3. the user must be told WHY, in their language, when it is refused.
//
//  Refusing in only the UI would leave the invariant one refactor away from
//  being silently lost — the mode changes what tools exist and what the system
//  prompt says, so a mid-thread flip would invalidate every earlier turn.
//

import Foundation

extension AIChatViewModel {

    /// Apply a mode choice coming from the slash menu.
    func chooseAgentMode(_ mode: AgentMode) {
        // Already in that mode: say so and stop. Re-picking the mode you have is
        // not an error, and must not produce a "locked" message.
        if agentMode == mode {
            appendSystemInfo(
                AppLocalized("This session is already in \(mode.displayName) mode."),
                icon: mode.symbol
            )
            return
        }

        // [T-minimal-mode] The one-way door, checked first so the message names
        // the real reason rather than a symptom (a minimal session always has
        // messages, so the thread-started guard below would also fire).
        if agentMode == .minimal {
            appendSystemInfo(
                AppLocalized("Minimal mode is locked for this session — start a new session to change it."),
                icon: "lock.fill"
            )
            return
        }

        // A mode chosen after the first turn would change the tool schema and the
        // prompt under reasoning that was produced with the old ones.
        guard messages.isEmpty else {
            appendSystemInfo(
                AppLocalized("The mode is chosen before the first message. Start a new session to pick one."),
                icon: "lock.fill"
            )
            return
        }

        guard let sid = sessionId else {
            // No session row yet (a draft). Remember it on the VM; `ensureSession`
            // writes the row and the mode together.
            agentMode = mode
            appendSystemInfo(
                AppLocalized("New sessions will start in \(mode.displayName) mode."),
                icon: mode.symbol
            )
            return
        }

        Task { @MainActor in
            let result = await ChatStore.shared.setAgentMode(sessionId: sid, mode: mode)
            switch result {
            case .applied:
                agentMode = mode
                appendSystemInfo(describe(mode), icon: mode.symbol)
            case .lockedMinimal:
                appendSystemInfo(
                    AppLocalized("Minimal mode is locked for this session — start a new session to change it."),
                    icon: "lock.fill"
                )
            case .threadStarted:
                appendSystemInfo(
                    AppLocalized("The mode is chosen before the first message. Start a new session to pick one."),
                    icon: "lock.fill"
                )
            case .noSuchSession:
                // The row vanished underneath us (deleted on another device).
                // Keeping the choice in memory is the useful outcome: the next
                // createSession persists it.
                agentMode = mode
                appendSystemInfo(describe(mode), icon: mode.symbol)
            }
        }
    }

    /// What minimal mode actually did, so the user is not left guessing which
    /// capabilities just went away.
    private func describe(_ mode: AgentMode) -> String {
        switch mode {
        case .normal:
            return AppLocalized("Normal mode: every capability you have enabled.")
        case .minimal:
            return AppLocalized("Minimal mode on: persona, memory, skills, MCP, todo and sub-agents are off, and the prompt is trimmed. The sandbox, mounted folders and environment variables stay. This cannot be changed later.")
        }
    }
}
