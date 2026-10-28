//
//  AIChatView+LinkAndDrop.swift
//  Minis - chat page (AIChatView)
//
//  AIChatView, taps and drops routed to this page: markdown image taps open
//  the session-wide gallery, minis:// / http(s) links open the right preview
//  or the folder browser, full-screen covers are cleared before another
//  presentation takes over, and items dropped from other apps become
//  attachments.
//
//  Map of the AIChatView files: AIChatView/AIChatView.swift.
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

private let minisLogger = AppLogger(category: "MinisURL")

extension AIChatView {
    // MARK: - Input Bar

    // MARK: - Drag & Drop Import

    /// Handle items dropped onto the chat from outside the app (Files, Photos, Safari, etc.).
    /// Handle a minis:// or http(s):// URL tap forwarded from a cell-level
    /// view. Routes deep links and opens the appropriate file preview sheet
    /// (state lives on AIChatView so sheet animations play correctly).
    /// Route a tap on a markdown-embedded image into a paged gallery covering
    /// **every** inline image in every assistant message in the current
    /// session, in chronological order. The tapped image determines only
    /// the starting page — the user can swipe freely across the whole
    /// conversation's image history. The `messageId` carried by the tap
    /// notification narrows the starting-index lookup so that duplicate
    /// `src` values in different messages still resolve to the right page.
    /// Clears every fullScreenCover state this view owns. Called when
    /// a more important presentation (incoming share, WebApp deep link)
    /// is about to take over the screen — iOS only allows one
    /// fullScreenCover per host at a time, so without this the
    /// new content would silently fail to present.
    func dismissAllOwnedImmersiveCovers() {
        if previewImageFile != nil { previewImageFile = nil }
        if imageGallery != nil { imageGallery = nil }
        if previewVideoFile != nil { previewVideoFile = nil }
        if fullBrowserURL != nil { fullBrowserURL = nil }
        if showTerminal { showTerminal = false }
        if showCamera { showCamera = false }
    }

    func handleMarkdownImageTap(_ note: Notification) {
        guard let info = note.userInfo,
              let tappedMessageId = info[MarkdownImageTapRouter.messageIdKey] as? UUID,
              let tappedSource = info[MarkdownImageTapRouter.sourceURLKey] as? String
        else { return }

        // Collect every `![alt](src)` occurrence from every assistant
        // message's text blocks, in chronological order. Tool-call blocks
        // are skipped. Video/audio extensions are filtered out so the
        // gallery only contains still images.
        let imagePattern = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)
        struct MarkdownImageRef {
            let messageId: UUID
            let source: String
            let title: String
        }
        var refs: [MarkdownImageRef] = []
        for message in vm.messages {
            guard message.role == .assistant else { continue }
            for block in message.blocks {
                guard case .text = block.kind else { continue }
                let content = block.content as NSString
                let range = NSRange(location: 0, length: content.length)
                imagePattern?.enumerateMatches(in: block.content, options: [], range: range) { match, _, _ in
                    guard let match, match.numberOfRanges >= 3 else { return }
                    let src = content.substring(with: match.range(at: 2))
                    let alt = content.substring(with: match.range(at: 1))
                    let ext = (URL(string: src)?.pathExtension ?? (src as NSString).pathExtension).lowercased()
                    if minisVideoExtensions.contains(ext) || minisAudioExtensions.contains(ext) { return }
                    let title = alt.isEmpty ? ((src as NSString).lastPathComponent) : alt
                    refs.append(MarkdownImageRef(messageId: message.id, source: src, title: title))
                }
            }
        }
        guard !refs.isEmpty else { return }

        // Prefer an exact `(messageId, source)` match so duplicate src values
        // across different messages resolve correctly. Fall back to the first
        // source match, then to 0.
        let startIndex: Int = {
            if let i = refs.firstIndex(where: { $0.messageId == tappedMessageId && $0.source == tappedSource }) {
                return i
            }
            if let i = refs.firstIndex(where: { $0.source == tappedSource }) {
                return i
            }
            return 0
        }()

        let items: [GalleryItem] = refs.enumerated().map { (index, ref) in
            // Include index + messageId + fingerprinted canonical source
            // in the id so:
            //   - duplicate sources across messages stay distinct pages in
            //     TabView's ForEach identity, and
            //   - a rewrite of the underlying file (size/mtime change)
            //     produces a new id and invalidates the cached TabView page.
            // Canonicalize here so relative-path `src` values from the
            // regex scan are resolved the same way the inline markdown
            // renderer resolves them.
            let canonical = ImageAttachment.canonicalizeMarkdownImageSource(ref.source)
            let fpKey = minisMediaCacheKey(for: canonical)
            return GalleryItem(
                id: "\(index)|\(ref.messageId)|\(fpKey)",
                title: ref.title,
                load: { await Self.loadMarkdownImage(source: canonical, fingerprintKey: fpKey) },
                // [T-image-save-original] Save / Copy / Share read the file itself.
                source: .markdown(canonical)
            )
        }
        imageGallery = GalleryPresentation(items: items, startIndex: startIndex)
    }

    /// Load a markdown image source (already canonicalized to minis:// or
    /// http(s)://) off the main thread. Caches in the shared
    /// `NativeMediaImageCache` using a fingerprint-derived key so
    /// in-place rewrites of local files are picked up on the next render.
    private static func loadMarkdownImage(source: String, fingerprintKey: String) async -> UIImage? {
        let cacheKey = "gallery:\(fingerprintKey)"
        if let cached = NativeMediaImageCache.shared.image(for: cacheKey) {
            return cached
        }
        guard let url = URL(string: source) else { return nil }
        let img: UIImage?
        if url.scheme == "minis" {
            guard let fileURL = resolveMinisFileURLCached(url: url),
                  let data = try? Data(contentsOf: fileURL) else { return nil }
            img = downsampleImageData(data, maxPixelSize: 2048)
        } else {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            img = downsampleImageData(data, maxPixelSize: 2048)
        }
        if let img { NativeMediaImageCache.shared.set(img, for: cacheKey) }
        return img
    }

    func handleMinisURLTap(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            withAnimation { safariURL = url }
            return .handled
        }
        guard url.scheme == "minis" else { return .systemAction }

        // Terminal deep link: minis://open_terminal?init_command=...
        if url.host == "open_terminal" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let initCmd = comps?.queryItems?.first(where: { $0.name == "init_command" })?.value
            let dl = DeepLinkCoordinator.shared
            dl.terminalInitCommand = initCmd
            dl.showTerminal = true
            return .handled
        }
        // View deep links: minis://views/alarm
        if url.host == "views" && url.path == "/alarm" {
            DeepLinkCoordinator.shared.showAlarmList = true
            return .handled
        }
        // Any minis://settings/<path> goes through DeepLinkRouter so all
        // supported settings sub-paths (logs, providers, model-groups,
        // usage, skills, memory, storage, mounts, shared-folders,
        // appearance, background, about, permissions, environments,
        // rootfs, …) reach Settings instead of falling through to the
        // file-resource resolver below — which would treat e.g. `logs`
        // as a missing chat file and surface the "file not found" alert.
        if url.host == "settings" {
            DeepLinkRouter.handle(url: url, shareCoordinator: shareCoordinator)
            return .handled
        }
        // [T-minisurl-wrong-active-session] Scope to THIS chat's session: the
        // tapped link lives in this view's message list, so its owner is
        // vm.sessionId regardless of what any concurrent background session
        // did to the frontmost pointer.
        if let fileURL = resolveMinisFileURL(url: url, sessionId: vm.sessionId) {
            let ext = url.pathExtension.lowercased()
            // [T-minis-folder-link] A trailing slash marks a folder whatever
            // its name looks like (a folder called `site.html/` is still one).
            if url.hasDirectoryPath {
                openMinisFolderOrShare(url: url, fileURL: fileURL)
                return .handled
            }
            withAnimation {
                if minisImageExtensions.contains(ext) {
                    previewImageFile = fileURL
                } else if minisVideoExtensions.contains(ext) {
                    previewVideoFile = fileURL
                } else if minisAudioExtensions.contains(ext) {
                    previewAudioFile = fileURL
                } else if minisMarkdownExtensions.contains(ext) {
                    previewMarkdownFile = fileURL
                } else if minisTextExtensions.contains(ext) {
                    previewTextFile = fileURL
                } else if minisHTMLExtensions.contains(ext) {
                    previewHTMLFile = fileURL
                } else if minisDocumentExtensions.contains(ext) {
                    previewDocumentFile = fileURL
                } else {
                    // No known extension: usually a folder (the agent wrote
                    // minis://workspace/dir), otherwise an unknown file type.
                    openMinisFolderOrShare(url: url, fileURL: fileURL)
                }
            }
        } else {
            // File doesn't exist on disk — likely deleted, from a pruned
            // session, or iCloud sync hasn't brought it down yet. Surface
            // a dismissable alert so the tap isn't silently ignored.
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            missingMinisFileName = name.isEmpty ? url.absoluteString : name
        }
        return .handled
    }

    /// [T-minis-folder-link] Open a folder link in the in-app file browser,
    /// or share it when it turns out to be a file. The directory test runs off
    /// the main thread: on a user-mounted folder, stat can be a synchronous
    /// FileProvider round-trip, and the resolver hands back such paths
    /// unverified on main for exactly that reason.
    private func openMinisFolderOrShare(url: URL, fileURL: URL) {
        Task { @MainActor in
            let isDirectory = await Task.detached(priority: .userInitiated) { () -> Bool in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) && isDir.boolValue
            }.value
            if isDirectory {
                let (root, label) = minisFolderBrowseRoot(url: url, resolved: fileURL, sessionId: vm.sessionId)
                minisLogger.info("[MinisLink] folder \(url.absoluteString) → browser root=\(root.path) label=\(label)")
                browseMinisFolder = MinisFolderBrowseTarget(root: root, folder: fileURL, label: label)
            } else {
                withAnimation { shareFile = fileURL }
            }
        }
    }

    func handleDropProviders(_ providers: [NSItemProvider]) {
        minisLogger.info("[Drop] handleDropProviders called with \(providers.count) provider(s)")
        for (index, provider) in providers.enumerated() {
            let types = provider.registeredTypeIdentifiers
            minisLogger.info("[Drop] provider[\(index)] types=\(types) suggestedName=\(provider.suggestedName ?? "nil")")

            // Determine if this provider represents a file (vs. inline text).
            let hasFileType = types.contains { id in
                guard let ut = UTType(id) else { return false }
                return ut.conforms(to: .fileURL) || ut.conforms(to: .image)
                    || ut.conforms(to: .movie) || ut.conforms(to: .pdf)
                    || (ut.conforms(to: .data) && !ut.conforms(to: .plainText))
            }
            let hasFileName = provider.suggestedName.map {
                !($0 as NSString).pathExtension.isEmpty
            } ?? false

            minisLogger.info("[Drop] provider[\(index)] hasFileType=\(hasFileType) hasFileName=\(hasFileName)")

            guard hasFileType || hasFileName else {
                minisLogger.info("[Drop] provider[\(index)] SKIPPED — no file type or filename")
                continue
            }

            // 1. File URL (most common on iPad — files, images, videos, documents)
            let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let canLoadImage = provider.canLoadObject(ofClass: UIImage.self)
            minisLogger.info("[Drop] provider[\(index)] hasFileURL=\(hasFileURL) canLoadImage=\(canLoadImage)")

            if hasFileURL {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let error {
                        minisLogger.error("[Drop] provider[\(index)] loadItem fileURL error: \(error.localizedDescription)")
                        return
                    }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        minisLogger.error("[Drop] provider[\(index)] loadItem fileURL failed to parse — item type: \(type(of: item))")
                        return
                    }
                    minisLogger.info("[Drop] provider[\(index)] fileURL loaded: \(url.path)")
                    DispatchQueue.main.async { vm.addFileAttachment(from: url) }
                }
                continue
            }
            // 2. Image not delivered as file URL (e.g. dragged from Photos)
            if canLoadImage {
                provider.loadObject(ofClass: UIImage.self) { item, error in
                    if let error {
                        minisLogger.error("[Drop] provider[\(index)] loadObject UIImage error: \(error.localizedDescription)")
                        return
                    }
                    guard let image = item as? UIImage else {
                        minisLogger.error("[Drop] provider[\(index)] loadObject UIImage returned nil")
                        return
                    }
                    minisLogger.info("[Drop] provider[\(index)] UIImage loaded: \(image.size)")
                    DispatchQueue.main.async { vm.addImageAttachment(image) }
                }
                continue
            }
            // 3. Any other file content — load via file representation
            if let contentType = types.first(where: { id in
                guard let ut = UTType(id) else { return false }
                return ut.conforms(to: .data)
            }) {
                minisLogger.info("[Drop] provider[\(index)] fallback loadFileRepresentation contentType=\(contentType)")
                provider.loadFileRepresentation(forTypeIdentifier: contentType) { url, error in
                    if let error {
                        minisLogger.error("[Drop] provider[\(index)] loadFileRepresentation error: \(error.localizedDescription)")
                        return
                    }
                    guard let url else {
                        minisLogger.error("[Drop] provider[\(index)] loadFileRepresentation returned nil URL")
                        return
                    }
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString.prefix(8) + "_" + url.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: url, to: tmp)
                        minisLogger.info("[Drop] provider[\(index)] file copied to: \(tmp.path)")
                        DispatchQueue.main.async { vm.addFileAttachment(from: tmp) }
                    } catch {
                        minisLogger.error("[Drop] provider[\(index)] copyItem failed: \(error.localizedDescription)")
                    }
                }
                continue
            }
            minisLogger.info("[Drop] provider[\(index)] NO handler matched — dropped")
        }
    }
}
