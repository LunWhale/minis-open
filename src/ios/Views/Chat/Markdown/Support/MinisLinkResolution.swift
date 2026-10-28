//
//  MinisLinkResolution.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  minis:// links inside rendered markdown.
//
//  - encodeRawMinisURL / percentEncodePathSegmentIdempotent repair destinations
//    the model emitted unencoded (CJK, emoji, fullwidth pipe). Used by the
//    theme's link path and by ImageAttachment.
//  - resolveMinisFileURLForNativeText maps a minis:// URL to a local file for
//    the image / video / audio attachments: the active session's folders
//    first, then the global skills / memory / shared folders. It mirrors
//    AIChatView's resolver; change both together.
//
//  App-layer edge: the resolver reads AIChatViewModel's active session id.
//  That is the only place the renderer looks up chat state for paths.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - minis:// URL encoding [T-minis-url-fullwidth-pipe-ios]

/// Percent-encode the path of a `minis://` destination that contains raw,
/// unencoded bytes (e.g. a filename with U+FF5C `｜`, CJK, emoji the LLM emitted
/// unencoded inside a minis:// link), returning a parseable URL (or nil if it
/// still can't be formed). Used by both the link path (SelectableMarkdownTheme)
/// and the image path (ImageAttachment), so it lives at file scope.
func encodeRawMinisURL(_ destination: String) -> URL? {
    let prefix = "minis://"
    guard destination.hasPrefix(prefix) else { return URL(string: destination) }
    let rest = String(destination.dropFirst(prefix.count))
    let encoded = rest.split(separator: "/", omittingEmptySubsequences: false)
        .map { percentEncodePathSegmentIdempotent(String($0)) }
        .joined(separator: "/")
    return URL(string: prefix + encoded)
}

/// Encode a single path segment idempotently: DECODE any existing percent escapes
/// first, then re-encode once. Normalizes mixed inputs (partly raw, partly
/// already-encoded, e.g. `cover%EF%BD%9C某某`) to a single clean encoding instead
/// of double-encoding the already-escaped bytes (`%EF…`→`%25EF…`). Fully-raw and
/// fully-encoded inputs both round-trip to the same result.
func percentEncodePathSegmentIdempotent(_ seg: String) -> String {
    let decoded = seg.removingPercentEncoding ?? seg
    return decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? seg
}

// MARK: - Minis URL Resolution (bridged from AIChatView)

/// Resolves a `minis://` URL to a local file URL.
/// Keeps resolution behavior aligned with AIChatView's minis resolver.
func resolveMinisFileURLForNativeText(url: URL) -> URL? {
    guard url.scheme == "minis" else { return nil }
    guard let host = url.host else {
        imgLogger.warning("[MinisImage][Resolve] no host in URL: \(url.absoluteString)")
        return nil
    }
    // Try the single-decoded subpath first; fall back to a double-decoded
    // variant when an inline-image link arrives double-encoded. This is the
    // same tolerant resolution the other 4 minis:// resolvers already use; this
    // one (the inline-markdown image resolver) was the remaining single-decode
    // holdout, so double-encoded non-ASCII inline image names still failed here.
    // [T-ios-file-preview-stale-cache, completing T-fix-double-encoding 2026-06-01]
    let subPaths = MinisURLPathDecoding.subPathCandidates(for: url)
    imgLogger.info("[MinisImage][Resolve] BEGIN url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) activeSession=\(AIChatViewModel.activeSessionId ?? "nil")")
    let fm = FileManager.default

    // Primary: active session persistent storage
    if let sid = AIChatViewModel.activeSessionId {
        for subPath in subPaths {
            let persistURL = AIChatViewModel.minisPersistentBase
                .appendingPathComponent(sid, isDirectory: true)
                .appendingPathComponent(host, isDirectory: true)
                .appendingPathComponent(subPath)
            imgLogger.info("[MinisImage][Resolve] checking session path=\(persistURL.path)")
            if fm.fileExists(atPath: persistURL.path) {
                let size = (try? fm.attributesOfItem(atPath: persistURL.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MinisImage][Resolve] FOUND in active session=\(sid) path=\(persistURL.path) size=\(size)")
                return persistURL
            }
        }
        imgLogger.info("[MinisImage][Resolve] NOT in active session=\(sid)")
    } else {
        imgLogger.info("[MinisImage][Resolve] no active session — skipping session lookup")
    }

    // Global namespaces (not session-scoped)
    if host == "skills" {
        for subPath in subPaths {
            let candidate = AIChatViewModel.minisSkillsPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MinisImage][Resolve] checking global skills path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MinisImage][Resolve] FOUND global skills path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    } else if host == "memory" {
        for subPath in subPaths {
            let candidate = AIChatViewModel.minisMemoryPersistentDir.appendingPathComponent(subPath)
            imgLogger.info("[MinisImage][Resolve] checking global memory path=\(candidate.path)")
            if fm.fileExists(atPath: candidate.path) {
                let size = (try? fm.attributesOfItem(atPath: candidate.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MinisImage][Resolve] FOUND global memory path=\(candidate.path) size=\(size)")
                return candidate
            }
        }
    }

    // [T-ios-minisurl-cross-session-isolation] DO NOT scan all session dirs.
    // This is the main image-render resolve path; the old "scan every session
    // and return the first same-named file" loop was the same P0 isolation
    // leak fixed in resolveMinisFileURL — session B rendering
    // model-use-zimage-0.jpg would resolve to session A's image. minis:// is
    // session-scoped; not-found is the correct result for a cross-session ref.
    //
    // The rootfs `/var/minis/<host>` fallback is kept ONLY for the global,
    // non-session-scoped namespaces (skills/memory/shared) — for those it just
    // points at the same global dir the iSH mount binds to. We explicitly
    // restrict it to those hosts so it can never reach another session's
    // attachments via whichever session happens to be mounted.
    let globalHosts: Set<String> = ["skills", "memory", "shared"]
    if globalHosts.contains(host) {
        for subPath in subPaths {
            let rootfsURL = RootfsManager.shared.dataPath
                .appendingPathComponent("var/minis", isDirectory: true)
                .appendingPathComponent(host, isDirectory: true)
                .appendingPathComponent(subPath)
            if fm.fileExists(atPath: rootfsURL.path) {
                let size = (try? fm.attributesOfItem(atPath: rootfsURL.path)[.size] as? Int64) ?? -1
                imgLogger.info("[MinisImage][Resolve] FOUND in global rootfs path=\(rootfsURL.path) size=\(size)")
                return rootfsURL
            }
        }
    }

    imgLogger.warning("[MinisImage][Resolve] NOT FOUND in active session / global dirs url=\(url.absoluteString) host=\(host) subPaths=\(subPaths) (cross-session scan disabled for isolation)")
    return nil
}
