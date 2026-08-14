import Foundation

// MARK: - Workspace Context Injection (M4)

extension AIChatViewModel {

    /// Load AGENTS.md / CLAUDE.md from the current session's workspace and
    /// return a system-prompt fragment. Gives the agent project-specific
    /// coding conventions whenever it works inside /var/minis/workspace.
    ///
    /// Priority per file: AGENTS.md then CLAUDE.md (both are honored, in
    /// that order, matching the Claude Code convention). Content is capped
    /// at 4000 chars per file so a huge convention doc can't dominate the
    /// prompt; the model can read the rest with file_read.
    nonisolated static func loadWorkspaceContextFragment(for sid: String) -> String? {
        let dir = minisWorkspacePersistentDir(for: sid)
        let fm = FileManager.default
        let candidates = ["AGENTS.md", "CLAUDE.md", "agents.md", "claude.md"]

        var parts: [String] = []
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.isEmpty else { continue }
            let capped = String(content.prefix(4000))
            if content.count > 4000 {
                parts.append("--- \(name) (first 4000 of \(content.count) chars) ---\n\(capped)")
            } else {
                parts.append("--- \(name) ---\n\(capped)")
            }
        }

        guard !parts.isEmpty else { return nil }

        return """
        Workspace coding context (from AGENTS.md/CLAUDE.md in /var/minis/workspace).
        Follow these project conventions when creating or editing code in this workspace.
        If the user's latest message conflicts with these files, follow the user's latest message:

        \(parts.joined(separator: "\n\n"))
        """
    }
}
