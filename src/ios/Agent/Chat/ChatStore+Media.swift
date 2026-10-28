//
//  ChatStore+Media.swift
//  Minis - chat persistence (Agent/Chat)
//
//  ChatStore, media files: save / load / delete a session's media and resolve
//  media file URLs.
//
//  Map of the ChatStore files: ChatStore.swift.
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {
    // MARK: - Media File Management

    /// Save media data to disk, return a MediaRef.
    /// Files are saved to `Library/MinisChat/minis/<sessionId>/<subdir>/<fileId>.<ext>`.
    func saveMedia(
        data: Data, mimeType: String, sessionId: String,
        originalFileName: String? = nil, subdir: String = "attachments",
        linuxPath: String? = nil, fileId: String? = nil
    ) -> MediaRef {
        // [T-paste-live-bubble-card] `fileId` lets send() pre-plan the storage
        // uuid synchronously so the bubble can be BORN with a card whose path
        // is already final — the row-birth doctrine (see the inputAttachments
        // seeding comment in send()): post-insert attachment mutations are a
        // race, not a render path.
        let fileId = fileId ?? UUID().uuidString
        let ext = Self.fileExtension(for: mimeType)

        let relativePath = "\(sessionId)/\(subdir)/\(fileId).\(ext)"
        let fileURL = minisBaseURL.appendingPathComponent(relativePath)

        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        do {
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to write media file: \(error)")
        }

        let ref = MediaRef(
            id: fileId,
            relativePath: relativePath,
            mimeType: mimeType,
            originalFileName: originalFileName,
            linuxPath: linuxPath
        )

        // Mark file dirty for iCloud sync via SessionFile record type
        markDirty(recordType: "SessionFile", recordId: "\(sessionId):\(subdir)/\(fileId).\(ext)")

        return ref
    }

    /// Resolve the on-disk URL for a MediaRef.
    func mediaFileURL(for ref: MediaRef) -> URL {
        minisBaseURL.appendingPathComponent(ref.relativePath)
    }

    /// Load media data from a MediaRef.
    func loadMediaData(_ ref: MediaRef) -> Data? {
        let url = mediaFileURL(for: ref)
        return try? Data(contentsOf: url)
    }

    /// Delete all media for a session.
    func deleteSessionMedia(_ sessionId: String) {
        let fm = FileManager.default

        // [T-paste-mediaref] "pasted" holds pasted-text refs; it must be here
        // or those files outlive the session that owns them.
        for subdir in ["browser", "attachments", "images", PastePlaceholder.mediaSubdir] {
            let dirURL = minisBaseURL.appendingPathComponent("\(sessionId)/\(subdir)")
            if fm.fileExists(atPath: dirURL.path) {
                try? fm.removeItem(at: dirURL)
            }
        }
    }

    /// Returns a closure that resolves a MediaRef to a file URL.
    func mediaFileURLResolver() -> (MediaRef) -> URL {
        let minis = minisBaseURL
        return { ref in
            minis.appendingPathComponent(ref.relativePath)
        }
    }
}
