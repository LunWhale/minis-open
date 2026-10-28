//
//  ScheduledTargetDelivery.swift
//  MinisApp
//
//  [T-scheduled-default-follow-up] Where a scheduled task's fires land, decided
//  and announced in one place.
//
//  1. Default target. `minis-scheduled create` without `--target` used to mean
//     `new`, so a model that asked for "remind me in this chat" and simply left
//     the flag out got every fire in a separate "Scheduled · …" chat: the
//     result never came back to the conversation that asked for it. Run from
//     inside a chat, the default is now `follow-up` (this chat). With no chat
//     behind the command (a Shortcut, a script) it stays `new`.
//  2. Delivery sentence. `create` answers with one plain sentence saying where
//     the fires will land (this chat / another chat / a new chat / a rerun / a
//     hidden helper), and whether the target was defaulted. A wrong target is
//     then visible right away and can be corrected with delete + create,
//     instead of being discovered when the first fire goes missing.
//
//  Foundation only: the standalone tests compile this file directly.
//

import Foundation

enum ScheduledTargetDelivery {

    /// `--target` to use: the explicit one (lower-cased), else `follow-up` when
    /// a session is known (`--session` or the chat running the CLI), else `new`.
    static func resolveTarget(explicit: String?, session: String?, callerSession: String?)
        -> (target: String, defaulted: Bool) {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty {
            return (explicit.lowercased(), false)
        }
        return ((session ?? callerSession) != nil ? "follow-up" : "new", true)
    }

    /// Where each fire lands, with what the sentence needs to name it.
    enum Destination: Equatable {
        case followUp(sessionId: String, title: String?, isCallerSession: Bool)
        case newChat(label: String?)
        case rerun(sessionId: String, messageId: String, title: String?)
        case childOfCurrent(parentSessionId: String, isCallerSession: Bool)

        var kind: String {
            switch self {
            case .followUp: return "follow-up"
            case .newChat: return "new"
            case .rerun: return "rerun"
            case .childOfCurrent: return "child-of-current"
            }
        }
    }

    /// One sentence for the model (English: CLI output is read by the model).
    static func sentence(_ d: Destination, defaulted: Bool) -> String {
        switch d {
        case .followUp(let sid, let title, let isCaller):
            let name = sessionName(sid, title)
            if isCaller {
                return "Delivery: each fire runs as a new turn IN THIS CHAT (\(name))."
                    + (defaulted ? " --target defaulted to follow-up because this command ran inside a chat; to use a separate chat instead, delete this task and re-create it with --target new." : "")
            }
            return "Delivery: each fire runs as a new turn in ANOTHER chat (\(name)), NOT in this conversation. If the result should come back here, delete this task and re-create it without --session."
        case .newChat(let label):
            let titled = label.map { " titled “Scheduled · \($0)”" } ?? ""
            return "Delivery: each fire opens a NEW, separate chat\(titled); the result will NOT appear in this conversation."
                + (defaulted
                   ? " --target defaulted to new because no chat was running this command."
                   : " If the user wanted it in this chat, delete this task and re-create it with --target follow-up.")
        case .rerun(let sid, let mid, let title):
            return "Delivery: each fire RE-RUNS user message \(mid.prefix(8)) in \(sessionName(sid, title)): the existing reply is regenerated, and no new prompt is added."
        case .childOfCurrent(let parent, let isCaller):
            let whose = isCaller ? "this chat" : "chat \(parent.prefix(8))"
            return "Delivery: each fire starts a hidden helper agent under \(whose); its final answer is posted back into \(whose)."
        }
    }

    /// Structured twin of `sentence` for scripts.
    static func summary(_ d: Destination, defaulted: Bool) -> [String: Any] {
        var out: [String: Any] = ["target": d.kind, "defaulted": defaulted]
        switch d {
        case .followUp(let sid, let title, let isCaller):
            out["sessionId"] = sid
            out["isThisChat"] = isCaller
            if let title { out["sessionTitle"] = title }
        case .newChat(let label):
            if let label { out["newChatTitle"] = "Scheduled · \(label)" }
        case .rerun(let sid, let mid, let title):
            out["sessionId"] = sid
            out["messageId"] = mid
            if let title { out["sessionTitle"] = title }
        case .childOfCurrent(let parent, let isCaller):
            out["parentSessionId"] = parent
            out["isThisChat"] = isCaller
        }
        return out
    }

    private static func sessionName(_ sid: String, _ title: String?) -> String {
        if let title, !title.isEmpty { return "session \(sid.prefix(8)) “\(title)”" }
        return "session \(sid.prefix(8))"
    }
}
