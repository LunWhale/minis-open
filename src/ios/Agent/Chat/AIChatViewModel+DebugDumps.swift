//
//  AIChatViewModel+DebugDumps.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, diagnostics: log dumps of agentHistory tool_use /
//  tool_result pairing, the prompt queue and candidate state ([PairDiag] and
//  related greps).
//
//  Map of the AIChatViewModel files: AIChatViewModel.swift.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

private let logger = AppLogger(category: "AIChatVM")

extension AIChatViewModel {
    /// [T-ios-retry-orphan-toolresult] Compact dump of the agentHistory
    /// tool_use ↔ tool_result pairing. One line per entry showing role + the
    /// tool_use ids it issues (TU:) and tool_result ids it answers (TR:), then a
    /// summary flagging every orphan: a TR whose TU is absent, or a TU with no
    /// answering TR. Grep `[PairDiag]`. Used around retryFromToolBlock's
    /// sub-message cut to see whether the cut leaves a tool_result stranded
    /// (which runAgentLoop's orphan-removal pass then has to delete, and which
    /// is the suspected source of the "AI discusses douban but the user prompt
    /// is gone" state).
    func dumpHistoryPairing(_ tag: String) {
        var tuIds = Set<String>()
        var trIds = Set<String>()
        var lines: [String] = []
        for (i, msg) in agentHistory.enumerated() {
            var tus: [String] = []
            var trs: [String] = []
            for part in msg.parts {
                if case .toolUse(let id, _, _, _) = part { tus.append(String(id.prefix(8))); tuIds.insert(id) }
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part { trs.append(String(id.prefix(8))); trIds.insert(id) }
            }
            var hasText = false
            for part in msg.parts { if case .text(let t) = part, !t.isEmpty { hasText = true } }
            let tuStr = tus.isEmpty ? "" : " TU:[\(tus.joined(separator: ","))]"
            let trStr = trs.isEmpty ? "" : " TR:[\(trs.joined(separator: ","))]"
            let textStr = hasText ? " text" : ""
            lines.append("  [\(i)] \(msg.role.rawValue)\(textStr)\(tuStr)\(trStr)")
        }
        // Orphan detection (full-id compare).
        var orphanTR: [String] = []
        var orphanTU: [String] = []
        for (_, msg) in agentHistory.enumerated() {
            for part in msg.parts {
                if case .toolResult(let id, _, _, _, _, _, _, _, _) = part, !tuIds.contains(id) {
                    orphanTR.append(String(id.prefix(8)))
                }
                if case .toolUse(let id, _, _, _) = part, !trIds.contains(id) {
                    orphanTU.append(String(id.prefix(8)))
                }
            }
        }
        let verdict = (orphanTR.isEmpty && orphanTU.isEmpty)
            ? "PAIRING-OK"
            : "ORPHANS orphanTR=[\(orphanTR.joined(separator: ","))] orphanTU=[\(orphanTU.joined(separator: ","))]"
        AppLogger(category: "PairDiag").info("[PairDiag] \(tag) count=\(self.agentHistory.count) \(verdict)\n\(lines.joined(separator: "\n"))")
    }

    /// [T-ios-queued-candidate-not-onscreen] Snapshot the prompt queue
    /// (`promptQueue`, the pending queued sends) and the on-screen message array
    /// (`messages`) — last 20 of each as compact summaries — to trace the
    /// "queued candidate executed but never rendered" bug. Grep `[QueueDiag]`.
    func dumpQueueSnapshot(_ tag: String) {
        // On-screen message array (last 20).
        let msgTail = messages.suffix(20)
        let msgStartIdx = messages.count - msgTail.count
        var msgLines: [String] = []
        for (offset, m) in msgTail.enumerated() {
            let idx = msgStartIdx + offset
            let roleStr: String = {
                switch m.role {
                case .user: return "user"
                case .assistant: return "asst"
                case .compactDivider: return "divider"
                case .systemInfo: return "sysinfo"
                }
            }()
            let queuedMark = m.isQueued ? " QUEUED(\(m.queuedPromptId?.uuidString.prefix(8) ?? "?"))" : ""
            let text = m.content.isEmpty
                ? (m.blocks.isEmpty ? "" : m.blocks.compactMap { $0.content.isEmpty ? nil : $0.content }.first ?? "")
                : m.content
            let preview = text.replacingOccurrences(of: "\n", with: "⏎").prefix(50)
            msgLines.append("  msg[\(idx)] \(roleStr) blocks=\(m.blocks.count)\(queuedMark) id=\(m.id.uuidString.prefix(8)) \"\(preview)\"")
        }
        // Prompt queue (last 20).
        let queueTail = promptQueue.suffix(20)
        var queueLines: [String] = []
        for p in queueTail {
            let preview = p.text.replacingOccurrences(of: "\n", with: "⏎").prefix(50)
            queueLines.append("  q[\(p.id.uuidString.prefix(8))] att=\(p.attachments.count) \"\(preview)\"")
        }
        logger.info("📋[QueueDiag] \(tag) — promptQueue=\(self.promptQueue.count) messages=\(self.messages.count) isProcessing=\(self.isProcessing)\nPROMPT-QUEUE (last \(queueTail.count)):\n\(queueLines.joined(separator: "\n"))\nMESSAGES (last \(msgTail.count)):\n\(msgLines.joined(separator: "\n"))")
    }

    /// [T-ios-stop-candidate-message-lost] One-line-per-block dump of the
    /// candidate (last assistant) message + the committed-count cursors. Use
    /// `xcrun simctl spawn booted log stream | grep StopDiag` (or read the
    /// daily LoggingManager file) to trace which blocks survive a Stop.
    func dumpCandidateState(_ tag: String) {
        let so = self.committedBlockCount
        let pso = self.prevCommittedBlockCount
        let histLast = agentHistory.last.map { "\($0.role.rawValue)[\($0.parts.count)p]" } ?? "nil"
        // Resolve the candidate by the last ASSISTANT row (a queued .user
        // message can sit after it), not messages.last.
        guard let candidateIdx = messages.lastIndex(where: { $0.role == .assistant }) else {
            logger.info("⏹️[StopDiag] \(tag) — no assistant message at all (messagesLast=\(self.messages.last?.role == .user ? "user" : "nil")) committed=\(so) prevCommitted=\(pso) histLast=\(histLast) canResume=\(self.canResume)")
            return
        }
        let last = messages[candidateIdx]
        let trailingQueued = candidateIdx < messages.count - 1
        logger.info("⏹️[StopDiag] \(tag) — candidate idx=\(candidateIdx) trailingQueued=\(trailingQueued) blocks=\(last.blocks.count) committed=\(so) prevCommitted=\(pso) histLast=\(histLast) canResume=\(self.canResume) msgId=\(last.id.uuidString.prefix(8))")
        for (i, b) in last.blocks.enumerated() {
            let kindStr: String = {
                switch b.kind {
                case .text: return "text"
                case .thinking: return "thinking"
                case .shellTool: return "shellTool"
                case .fileReadTool: return "fileRead"
                case .fileWriteTool: return "fileWrite"
                case .fileEditTool: return "fileEdit"
                case .browserTool: return "browser"
                case .readImageTool: return "readImage"
                case .memoryTool: return "memory"
                case .delegateTool: return SubAgentDefinition.toolName
                case .userAskTool: return UserAskTool.name
                case .info: return "info"
                }
            }()
            let statusStr: String = {
                guard let s = b.toolStatus else { return "-" }
                switch s {
                case .streaming: return "streaming"
                case .running: return "running"
                case .cancelled: return "cancelled"
                default: return "\(s)"
                }
            }()
            let committedMark = i < so ? "C" : "·"  // C = already committed to agentHistory
            let preview = b.content.replacingOccurrences(of: "\n", with: "⏎").prefix(40)
            logger.info("⏹️[StopDiag]   [\(committedMark)] block[\(i)] kind=\(kindStr) status=\(statusStr) len=\(b.content.count) tuId=\(b.toolUseId?.prefix(8) ?? "-") \"\(preview)\"")
        }
    }
}
