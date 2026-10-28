//
//  AIChatViewModel+AutoPlayAudio.swift
//  Minis - chat view model (Agent/Chat)
//
//  AIChatViewModel, static media helpers: auto-play of audio links marked
//  ?auto_play=true in assistant text (works in the background, e.g. from
//  Shortcuts), resolving their minis:// URLs, and image MIME detection used
//  by the concurrent tool extensions.
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
    // MARK: - Auto-Play Audio

    /// Regex to find Markdown image syntax with audio extensions and ?auto_play=true query.
    /// Matches: ![...](minis://attachments/file.mp3?auto_play=true)
    private static let autoPlayAudioPattern: NSRegularExpression? = {
        // Match ![alt](url) where url ends with audio extension and has auto_play=true/1
        try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(([^)]+\.(?:mp3|m4a|wav|aac|ogg|flac)\?[^)]*auto_play=(?:true|1)[^)]*)\)"#,
            options: .caseInsensitive
        )
    }()

    /// Scan assistant text for audio URLs with ?auto_play=true and trigger playback
    /// directly via GlobalAudioPlayer. Works even in background (Shortcuts intents).
    static func triggerAutoPlayAudio(in text: String) {
        guard !text.isEmpty, let regex = autoPlayAudioPattern else { return }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let firstMatch = matches.first, firstMatch.numberOfRanges >= 2,
              let urlRange = Range(firstMatch.range(at: 1), in: text) else { return }
        let rawURL = String(text[urlRange])

        // Strip query parameters to get clean file URL
        guard let url = URL(string: rawURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = nil
        guard let cleanURL = components.url else { return }

        // Resolve minis:// to file URL
        let fileURL: URL?
        if cleanURL.scheme == "minis" {
            fileURL = resolveMinisFileURLForAutoPlay(url: cleanURL)
        } else {
            fileURL = cleanURL
        }

        guard let resolved = fileURL else {
            logger.warning("⏵ auto_play: could not resolve URL \(rawURL)")
            return
        }

        logger.info("⏵ auto_play: triggering playback for \(resolved.lastPathComponent)")
        // GlobalAudioPlayer.play() configures the audio session itself (without
        // .mixWithOthers) so that it appears in Control Center / lock screen.
        GlobalAudioPlayer.shared.play(url: resolved)
    }

    /// Resolve minis:// URL to local file URL (standalone, no UI dependency).
    private static func resolveMinisFileURLForAutoPlay(url: URL) -> URL? {
        guard url.scheme == "minis", let host = url.host else { return nil }
        // Tolerate double-encoded links alongside single-encoded.
        // [T-fix-double-encoding]
        let subPaths = MinisURLPathDecoding.subPathCandidates(for: url)
        let fm = FileManager.default

        // Global directories resolve without session ID
        let globalDirs = ["memory", "skills", "shared"]
        if globalDirs.contains(host) {
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            for subPath in subPaths {
                let globalURL = library.appendingPathComponent("MinisChat/\(host)", isDirectory: true)
                    .appendingPathComponent(subPath)
                if fm.fileExists(atPath: globalURL.path) { return globalURL }
            }
        }

        if let sid = activeSessionId {
            for subPath in subPaths {
                let persistURL = minisPersistentBase
                    .appendingPathComponent(sid, isDirectory: true)
                    .appendingPathComponent(host, isDirectory: true)
                    .appendingPathComponent(subPath)
                if fm.fileExists(atPath: persistURL.path) { return persistURL }
            }
        }

        // [T-ios-minisurl-cross-session-isolation] Fallback to the iSH-visible
        // /var/minis data dir ONLY for the global, non-session-scoped
        // namespaces (memory/skills/shared). For a session-scoped host like
        // `attachments`, /var/minis/<host> binds to whichever session is
        // currently MOUNTED — which may not be the session whose message is
        // being rendered — so reaching it here would be a cross-session leak.
        // Session-scoped resolution already happened above against
        // activeSessionId; not-found is correct beyond that.
        if globalDirs.contains(host) {
            let dataPath = RootfsManager.shared.dataPath
            for subPath in subPaths {
                let linuxPath = "/var/minis/\(host)/\(subPath)"
                let hostPath = dataPath.appendingPathComponent(linuxPath.hasPrefix("/") ? String(linuxPath.dropFirst()) : linuxPath)
                if fm.fileExists(atPath: hostPath.path) { return hostPath }
            }
        }

        return nil
    }

    /// Detect image MIME type from magic bytes; defaults to image/jpeg.
    /// Internal-access so concurrent tool extensions can call it. [T-concurrent-tools]
    static func detectImageMime(_ data: Data) -> String {
        guard data.count >= 4 else { return "image/jpeg" }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return "image/gif" }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 { return "image/webp" }
        return "image/jpeg"
    }
}
