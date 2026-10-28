//
//  ContentView+Export.swift
//  Minis - home screen (session list, navigation, settings entry)
//
//  ContentView, export: streams the selected sessions to JSON or plain text,
//  zips them, and hands the file to ExportPreviewSheet.
//
//  Map of the ContentView files: ContentView/ContentView.swift.
//

import SwiftUI

extension ContentView {
    enum ExportFormat { case json, plainText }

    func exportSessions(ids: Set<String>, format: ExportFormat) {
        let targetSessions = sessions.filter { ids.contains($0.id) }
        guard !targetSessions.isEmpty else { return }

        isExporting = true
        exportProgress = (0, 0)

        let isMulti = targetSessions.count > 1

        Task.detached(priority: .userInitiated) {
            let ext: String
            switch format {
            case .json: ext = "json"
            case .plainText: ext = "txt"
            }

            // Per-export workspace under tmp
            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("minis-export-\(UUID().uuidString)", isDirectory: true)
            let workDir = tmpRoot.appendingPathComponent("payload", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            } catch {
                await MainActor.run { isExporting = false; exportProgress = nil }
                return
            }

            let baseName: String
            if ids.count == 1, let title = targetSessions.first?.title {
                baseName = title.prefix(60)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
            } else {
                baseName = "minis-sessions-\(ids.count)"
            }
            let payloadURL = workDir.appendingPathComponent("\(baseName).\(ext)")

            // No cheap per-session count available; progress total grows as
            // each session loads (handled inside the stream functions).
            await MainActor.run { exportProgress = (0, 0) }

            let summary: ExportSummary
            do {
                switch format {
                case .json:
                    summary = try await Self.streamExportAsJSON(
                        targetSessions, to: payloadURL,
                        progress: { done, total in
                            Task { @MainActor in exportProgress = (done, total) }
                        }
                    )
                case .plainText:
                    summary = try await Self.streamExportAsPlainText(
                        targetSessions, to: payloadURL,
                        progress: { done, total in
                            Task { @MainActor in exportProgress = (done, total) }
                        }
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: tmpRoot)
                await MainActor.run { isExporting = false; exportProgress = nil }
                return
            }

            // Zip the workDir (single file inside, but zip wrapping keeps spec contract
            // and shrinks large text payloads significantly).
            let zipURL = tmpRoot.appendingPathComponent("\(baseName).zip")
            let finalURL: URL
            do {
                try await Self.createZip(from: workDir, to: zipURL)
                finalURL = zipURL
            } catch {
                // Fall back to raw payload if zipping failed.
                finalURL = payloadURL
            }

            // Compute summary metadata
            var summaryWithSize = summary
            summaryWithSize.format = ext.uppercased()
            summaryWithSize.sessionCount = targetSessions.count
            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let size = attrs[.size] as? Int64 {
                summaryWithSize.fileSizeBytes = size
            }

            // Delay so context menu dismiss animation finishes
            try? await Task.sleep(nanoseconds: 600_000_000)

            await MainActor.run {
                isExporting = false
                exportProgress = nil
                exportFileURL = finalURL
                // [T-export-preview-blank] Preview the raw payload, not the zip.
                // `finalURL` is normally the .zip (that is what gets shared/saved);
                // decoding it as UTF-8 always fails, which is why the preview pane
                // was blank. The uncompressed payload is still sitting in workDir —
                // createZip copies out of it and nothing deletes it on the success
                // path — so hand that to the preview. When zipping fell back,
                // finalURL IS payloadURL and the two are simply the same file.
                exportPreviewURL = payloadURL
                exportSummary = isMulti ? summaryWithSize : nil
                showExportPreview = true
            }
        }
    }

    /// Wrap a directory into a zip via NSFileCoordinator(.forUploading).
    private static func createZip(from sourceDir: URL, to zipURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var nsError: NSError?
            coordinator.coordinate(readingItemAt: sourceDir,
                                   options: .forUploading,
                                   error: &nsError) { zippedURL in
                do {
                    if FileManager.default.fileExists(atPath: zipURL.path) {
                        try FileManager.default.removeItem(at: zipURL)
                    }
                    try FileManager.default.copyItem(at: zippedURL, to: zipURL)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            if let nsError { cont.resume(throwing: nsError) }
        }
    }

    /// Stream JSON export to disk in batches of 50 messages — avoids loading
    /// the full payload into memory. Returns aggregate summary stats.
    private static func streamExportAsJSON(
        _ targetSessions: [ChatSession],
        to fileURL: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> ExportSummary {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(domain: "ExportStream", code: 1)
        }
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let isoFmt = ISO8601DateFormatter()

        var summary = ExportSummary()
        var done = 0

        try handle.write(contentsOf: Data("[\n".utf8))
        var firstSession = true

        for session in targetSessions {
            let allMessages = await ChatStore.shared.loadMessages(sessionId: session.id)
            guard let firstUserIdx = allMessages.firstIndex(where: { $0.role == .user }) else { continue }
            let messages = Array(allMessages[firstUserIdx...])

            // Total is best-effort: at minimum we know what we've processed plus
            // this session's pending messages.
            let total = done + messages.count
            progress(done, total)

            // Per-session header
            if !firstSession { try handle.write(contentsOf: Data(",\n".utf8)) }
            firstSession = false

            var sessionHeader: [String: Any] = [
                "id": session.id,
                "modelId": session.modelId,
                "createdAt": isoFmt.string(from: session.createdAt),
                "updatedAt": isoFmt.string(from: session.updatedAt)
            ]
            if let title = session.title { sessionHeader["title"] = title }
            if let category = session.category { sessionHeader["category"] = category }

            // Write the session object opening, then stream messages array.
            let headerData = try JSONSerialization.data(withJSONObject: sessionHeader, options: [.prettyPrinted, .sortedKeys])
            // Strip the trailing "}" so we can append "messages": [...].
            guard var headerStr = String(data: headerData, encoding: .utf8) else { continue }
            if headerStr.hasSuffix("}") { headerStr.removeLast() }
            try handle.write(contentsOf: Data(headerStr.utf8))
            try handle.write(contentsOf: Data(",\n  \"messages\": [\n".utf8))

            var firstMsg = true
            var batchBuffer: [[String: Any]] = []
            batchBuffer.reserveCapacity(50)

            func flushBatch() throws {
                guard !batchBuffer.isEmpty else { return }
                for dict in batchBuffer {
                    let d = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
                    if !firstMsg { try handle.write(contentsOf: Data(",\n".utf8)) }
                    firstMsg = false
                    try handle.write(contentsOf: d)
                }
                batchBuffer.removeAll(keepingCapacity: true)
            }

            for msg in messages {
                done += 1
                if msg.isToolResultOnly { continue }

                var cleanParts: [[String: Any]] = []
                for part in msg.parts {
                    switch part {
                    case .text(let text):
                        cleanParts.append(["type": "text", "text": text])
                    case .toolUse(let tu):
                        var toolDict: [String: Any] = ["type": "tool_use", "name": tu.name]
                        if let desc = tu.description { toolDict["description"] = desc }
                        if !tu.input.isEmpty { toolDict["input"] = tu.input }
                        cleanParts.append(toolDict)
                    case .toolResult(let tr):
                        var resultDict: [String: Any] = [
                            "type": "tool_result",
                            "tool": tr.toolUseId,
                            "success": tr.success
                        ]
                        if !tr.output.isEmpty {
                            let maxLen = 2000
                            if tr.output.count > maxLen {
                                resultDict["output"] = String(tr.output.prefix(maxLen)) + "\n…[truncated]"
                            } else {
                                resultDict["output"] = tr.output
                            }
                        }
                        if let snap = tr.snapshot {
                            if let text = snap.text { resultDict["snapshot"] = text }
                            if let dur = snap.duration { resultDict["duration"] = dur }
                        }
                        cleanParts.append(resultDict)
                    case .mediaRef:
                        cleanParts.append(["type": "media", "note": "image/file attachment"])
                        summary.attachmentCount += 1
                    }
                }

                guard !cleanParts.isEmpty else { continue }

                var dict: [String: Any] = [
                    "role": msg.role.rawValue,
                    "parts": cleanParts,
                    "createdAt": isoFmt.string(from: msg.createdAt)
                ]
                if let usage = msg.tokenUsage,
                   let usageData = try? encoder.encode(usage),
                   let usageJSON = try? JSONSerialization.jsonObject(with: usageData) {
                    dict["tokenUsage"] = usageJSON
                }
                if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                    dict["reasoning"] = reasoning
                }
                batchBuffer.append(dict)

                summary.totalMessages += 1
                if summary.earliest == nil || msg.createdAt < summary.earliest! {
                    summary.earliest = msg.createdAt
                }
                if summary.latest == nil || msg.createdAt > summary.latest! {
                    summary.latest = msg.createdAt
                }

                if batchBuffer.count >= 50 {
                    try flushBatch()
                    progress(done, total)
                }
            }
            try flushBatch()

            try handle.write(contentsOf: Data("\n  ]\n}".utf8))
            progress(done, total)
        }

        try handle.write(contentsOf: Data("\n]\n".utf8))
        return summary
    }

    /// Stream plain-text export to disk — writes each message immediately
    /// so memory stays bounded regardless of session size.
    private static func streamExportAsPlainText(
        _ targetSessions: [ChatSession],
        to fileURL: URL,
        progress: @escaping (Int, Int) -> Void
    ) async throws -> ExportSummary {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw NSError(domain: "ExportStream", code: 2)
        }
        defer { try? handle.close() }

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"

        var summary = ExportSummary()
        var done = 0

        for (i, session) in targetSessions.enumerated() {
            if i > 0 {
                try handle.write(contentsOf: Data(("\n\n" + String(repeating: "=", count: 60) + "\n\n").utf8))
            }
            var header = "# \(session.title ?? "Untitled")\n"
            header += "Model: \(session.modelId)\n"
            header += "Created: \(dateFmt.string(from: session.createdAt))\n"
            header += String(repeating: "-", count: 40) + "\n"
            try handle.write(contentsOf: Data(header.utf8))

            let allMessages = await ChatStore.shared.loadMessages(sessionId: session.id)
            guard let firstUserIdx = allMessages.firstIndex(where: { $0.role == .user }) else { continue }
            let messages = Array(allMessages[firstUserIdx...])
            let total = done + messages.count
            progress(done, total)

            var batchWritten = 0
            for msg in messages {
                done += 1
                if msg.isToolResultOnly { continue }

                let role = msg.role == .user ? "User" : "Minis"
                let time = timeFmt.string(from: msg.createdAt)
                var parts: [String] = []
                for part in msg.parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty { parts.append(text) }
                    case .toolUse(let tu):
                        parts.append("[Tool: \(tu.description ?? tu.name)]")
                    case .toolResult(let tr):
                        if let snap = tr.snapshot, let text = snap.text, !text.isEmpty {
                            let preview = text.count > 200 ? String(text.prefix(200)) + "…" : text
                            parts.append("[Result: \(preview)]")
                        } else {
                            parts.append("[Result: \(tr.success ? "ok" : "failed")]")
                        }
                    case .mediaRef:
                        parts.append("[Attachment]")
                        summary.attachmentCount += 1
                    }
                }
                let body = parts.joined(separator: "\n")
                if !body.isEmpty {
                    let chunk = "\n[\(role)] \(time)\n\(body)\n---\n"
                    try handle.write(contentsOf: Data(chunk.utf8))
                    summary.totalMessages += 1
                    if summary.earliest == nil || msg.createdAt < summary.earliest! {
                        summary.earliest = msg.createdAt
                    }
                    if summary.latest == nil || msg.createdAt > summary.latest! {
                        summary.latest = msg.createdAt
                    }
                }
                batchWritten += 1
                if batchWritten >= 50 {
                    batchWritten = 0
                    progress(done, total)
                }
            }
            progress(done, total)
        }
        return summary
    }
}
