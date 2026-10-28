import Foundation
import UIKit
import UniformTypeIdentifiers

/// Processes NSExtensionItems from the share sheet, saves files to the shared
/// container, and writes a PendingShare for the main app to consume.
///
/// Main-actor bound: the view controller reads its state when the time limit
/// cuts processing short, while a provider load may still be suspended.
@MainActor
final class ShareViewModel {
    private var pendingItems: [PendingShare.Item] = []
    private let inlineTextLimit = 1000
    /// [T-share-one-link] What the providers returned, before the rules in
    /// `ShareItemRules.reduce` decide what one share keeps.
    private var candidates: [ShareItemRules.Candidate] = []
    private var currentGroup = 0

    /// How many items this share produced (after `processExtensionItems`).
    var itemCount: Int { pendingItems.count }

    /// Process all extension items from the share context.
    func processExtensionItems(_ extensionItems: [NSExtensionItem]) async {
        pendingItems.removeAll()
        candidates.removeAll()

        let fm = FileManager.default
        if let dir = SharedContainerStore.sharedFileDirectory {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        for (group, extensionItem) in extensionItems.enumerated() {
            guard let attachments = extensionItem.attachments else { continue }
            currentGroup = group

            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    await processURL(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    await processText(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    await processImage(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    await processVideo(provider)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    await processFile(provider)
                }
            }
        }
        finalizeItems()
    }

    /// [T-share-one-link] Apply the rules, then turn what is left into items.
    /// Also called when processing is cut short by the extension's time limit,
    /// so whatever was loaded by then is still delivered.
    func finalizeItems() {
        let kept = ShareItemRules.reduce(candidates)
        if kept.count != candidates.count {
            NSLog("[ShareExt] rules kept %d of %d loaded values", kept.count, candidates.count)
        }
        pendingItems = kept.compactMap { candidate in
            switch candidate.source {
            case .attachment:
                return .init(kind: .attachment, value: candidate.value)
            case .webURL:
                return .init(kind: .inlineText, value: candidate.value)
            case .text:
                guard candidate.value.count > inlineTextLimit else {
                    return .init(kind: .inlineText, value: candidate.value)
                }
                let fileName = "shared-text-\(UUID().uuidString.prefix(8)).txt"
                guard let dir = SharedContainerStore.sharedFileDirectory else { return nil }
                try? candidate.value.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                return .init(kind: .attachment, value: fileName)
            }
        }
    }

    private func add(_ source: ShareItemRules.Candidate.Source, _ value: String) {
        candidates.append(.init(source: source, value: value, group: currentGroup))
    }

    /// Save pending share and return true on success.
    /// [T-share-buffer-merge] MERGE with any unconsumed previous share instead
    /// of overwriting it. Rapid consecutive shares (user shares screenshot A,
    /// then B a few seconds later, before the main app ran
    /// processPendingShare) used to silently lose A: this save() replaced the
    /// App Group record wholesale. Attachment file names are UUID-suffixed so
    /// the merged item lists never collide on disk. The 300s window matches
    /// checkForPendingShare's staleness cutoff; anything older is abandoned
    /// content whose files the main app will clean up.
    func save() -> Bool {
        guard !pendingItems.isEmpty else { return false }
        var items = pendingItems
        if let existing = SharedContainerStore.loadPendingShare(),
           Date().timeIntervalSince(existing.timestamp) < 300 {
            NSLog("[ShareExt] save: merging %d existing unconsumed items with %d new",
                  existing.items.count, pendingItems.count)
            // [T-share-one-link] The same link shared twice in a row stays one line.
            items = ShareItemRules.merge(existing: existing.items, new: items)
        }
        let share = PendingShare(items: items, timestamp: Date())
        SharedContainerStore.savePendingShare(share)
        return true
    }

    // MARK: - Processors

    private func processURL(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
              let url = item as? URL else { return }

        // file:// URLs are local files — treat as file attachment, not inline text
        if url.isFileURL {
            await copyFileToShared(from: url)
            return
        }

        add(.webURL, url.absoluteString)
    }

    /// Copy a local file URL to the shared container as an attachment.
    private func copyFileToShared(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        // If it's an image, process through image pipeline for JPEG conversion
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            let fileName = "shared-image-\(UUID().uuidString.prefix(8)).jpg"
            if let dir = SharedContainerStore.sharedFileDirectory,
               let jpegData = image.jpegData(compressionQuality: 0.85) {
                let fileURL = dir.appendingPathComponent(fileName)
                try? jpegData.write(to: fileURL)
                add(.attachment, fileName)
            }
            return
        }

        // General file copy
        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            add(.attachment, fileName)
        }
    }

    private func processText(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
              let text = item as? String else { return }

        // Long text becomes a file in `finalizeItems`, after the rules ran.
        add(.text, text)
    }

    private func processImage(_ provider: NSItemProvider) async {
        if let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
            var image: UIImage?
            if let uiImage = item as? UIImage {
                image = uiImage
            } else if let imageData = item as? Data {
                image = UIImage(data: imageData)
            } else if let url = item as? URL, let data = try? Data(contentsOf: url) {
                image = UIImage(data: data)
            }

            if let image {
                let fileName = "shared-image-\(UUID().uuidString.prefix(8)).jpg"
                if let dir = SharedContainerStore.sharedFileDirectory,
                   let jpegData = image.jpegData(compressionQuality: 0.85) {
                    let fileURL = dir.appendingPathComponent(fileName)
                    try? jpegData.write(to: fileURL)
                    add(.attachment, fileName)
                }
            }
        }
    }

    private func processVideo(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.movie.identifier),
              let url = item as? URL else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let suffix = ext.isEmpty ? "mov" : ext
        let fileName = "shared-video-\(UUID().uuidString.prefix(8)).\(suffix)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            add(.attachment, fileName)
        }
    }

    private func processFile(_ provider: NSItemProvider) async {
        guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.item.identifier),
              let url = item as? URL else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fileName = "shared-\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"
        if let dir = SharedContainerStore.sharedFileDirectory {
            let destURL = dir.appendingPathComponent(fileName)
            try? FileManager.default.copyItem(at: url, to: destURL)
            add(.attachment, fileName)
        }
    }
}
