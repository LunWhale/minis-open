//
//  MessageImageGallery.swift
//  MinisApp
//
//  Paged fullscreen image gallery shared by both preview paths:
//    1. User-message attachments (via \.openImageGallery environment action)
//    2. Assistant-message markdown-embedded images (via notification router)
//
//  Each `GalleryItem` is loaded lazily — only the current page (and its
//  neighbors, once TabView builds them) decode an image. Heavy pages off the
//  current slot stay as placeholders until navigated to.
//

import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - ImageExport [T-image-save-original]

/// Save / copy / share / print for chat images, from the ORIGINAL file.
///
/// Every preview decodes its image for the screen: the gallery, the Markdown
/// renderer and the inline previews cap the longest edge at 2048 px
/// (`downsampleImageData`). Save used to hand that display bitmap to Photos
/// (`creationRequestForAsset(from: UIImage)`), which re-encoded it at display
/// resolution: a 2560×7488 PNG (5.3 MB) came out as 700×2048 (546 KB)
/// (Telegram report, 2026-09-27). Copy, share and print exported the same
/// bitmap.
///
/// Now each action reads the original bytes. Save adds them to Photos as-is
/// (`addResource(with: .photo, data:)` — same pixels, format and metadata).
/// If Photos refuses that format it falls back to a FULL-resolution decode,
/// and only if the original cannot be read at all to the displayed bitmap.
enum ImageExport {
    private static let logger = AppLogger(category: "ImageExport")

    /// Where a previewed image came from.
    enum Source: Equatable {
        /// A Markdown / attachment source: minis://…, http(s)://…, or anything
        /// `ImageAttachment.canonicalizeMarkdownImageSource` resolves.
        case markdown(String)
        case file(URL)
        case remote(URL)
    }

    struct Original {
        let data: Data
        let filename: String
        let type: UTType?
        /// Pixel size read from the header (no decode); nil if unknown.
        let pixelSize: CGSize?
    }

    /// Read the original bytes. Local files are read directly; remote URLs are
    /// fetched again (the preview kept only the decoded bitmap).
    static func loadOriginal(_ source: Source) async -> Original? {
        switch source {
        case .file(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            return make(data: data, name: url.lastPathComponent)
        case .remote(let url):
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            let name = response.suggestedFilename ?? url.lastPathComponent
            return make(data: data, name: name)
        case .markdown(let raw):
            let canonical = ImageAttachment.canonicalizeMarkdownImageSource(raw)
            guard let url = URL(string: canonical) else { return nil }
            if url.scheme == "minis" {
                guard let fileURL = resolveMinisFileURLCached(url: url) else { return nil }
                return await loadOriginal(.file(fileURL))
            }
            if url.scheme == "http" || url.scheme == "https" { return await loadOriginal(.remote(url)) }
            if url.isFileURL { return await loadOriginal(.file(url)) }
            return nil
        }
    }

    /// Wrap bytes that ImageIO recognises as an image; the filename gets the
    /// real format's extension when it has none (or a wrong one).
    static func make(data: Data, name: String) -> Original? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(src) as String? else { return nil }
        let type = UTType(typeId)
        var size: CGSize?
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            size = CGSize(width: w, height: h)
        }
        var filename = name.isEmpty ? "image" : name
        if let ext = type?.preferredFilenameExtension {
            let current = (filename as NSString).pathExtension.lowercased()
            let accepted = Set(type?.tags[.filenameExtension] ?? []).union([ext])
            if !accepted.contains(current) { filename = (filename as NSString).deletingPathExtension + "." + ext }
        }
        return Original(data: data, filename: filename, type: type, pixelSize: size)
    }

    /// Save to Photos. `completion` runs on the main queue.
    static func saveToPhotos(source: Source?, displayed: UIImage?, completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { ok in DispatchQueue.main.async { completion(ok) } }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { finish(false); return }
            Task {
                let original: Original? = if let source { await loadOriginal(source) } else { nil }
                if let original {
                    let ok = await perform {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = original.filename
                        request.addResource(with: .photo, data: original.data, options: options)
                    }
                    if ok {
                        logger.info("[ImageExport] saved ORIGINAL \(original.filename) \(sizeText(original.pixelSize)) bytes=\(original.data.count)")
                        finish(true); return
                    }
                    // Photos refused the format (e.g. SVG-rendered or exotic
                    // codecs): save a full-resolution decode instead.
                    if let full = UIImage(data: original.data) {
                        let ok = await perform { PHAssetChangeRequest.creationRequestForAsset(from: full) }
                        logger.info("[ImageExport] original rejected by Photos — saved FULL-RES decode \(Int(full.size.width * full.scale))x\(Int(full.size.height * full.scale)) ok=\(ok)")
                        if ok { finish(true); return }
                    }
                }
                guard let displayed else { finish(false); return }
                let ok = await perform { PHAssetChangeRequest.creationRequestForAsset(from: displayed) }
                logger.warning("[ImageExport] original unavailable — saved DISPLAYED bitmap \(Int(displayed.size.width * displayed.scale))x\(Int(displayed.size.height * displayed.scale)) ok=\(ok)")
                finish(ok)
            }
        }
    }

    /// Copy the original bytes (with their type) to the pasteboard, else the
    /// displayed bitmap.
    static func copy(source: Source?, displayed: UIImage?) async {
        if let source, let original = await loadOriginal(source), let type = original.type {
            await MainActor.run { UIPasteboard.general.setItems([[type.identifier: original.data]]) }
            return
        }
        if let displayed { await MainActor.run { UIPasteboard.general.image = displayed } }
    }

    /// A temp file to share: the original bytes under their own filename, else
    /// the displayed bitmap as PNG.
    static func shareFile(source: Source?, displayed: UIImage?) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let source, let original = await loadOriginal(source) {
            let url = dir.appendingPathComponent(original.filename)
            if (try? original.data.write(to: url)) != nil { return url }
        }
        guard let data = displayed?.pngData() else { return nil }
        let url = dir.appendingPathComponent("image.png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Full-resolution image for printing, else the displayed bitmap.
    static func printableImage(source: Source?, displayed: UIImage?) async -> UIImage? {
        if let source, let original = await loadOriginal(source), let full = UIImage(data: original.data) {
            return full
        }
        return displayed
    }

    private static func perform(_ changes: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges(changes) { ok, error in
                if let error { logger.info("[ImageExport] performChanges failed: \(error.localizedDescription)") }
                cont.resume(returning: ok)
            }
        }
    }

    private static func sizeText(_ size: CGSize?) -> String {
        size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?x?"
    }
}

// MARK: - GalleryItem

/// A single image in a multi-image preview session. Images are loaded lazily
/// via the `load` closure so large sets don't decode all bitmaps up front.
struct GalleryItem: Identifiable, Equatable {
    let id: String              // unique per session — typically the source URL string
    let title: String           // human-readable caption (usually file name)
    /// Decodes for DISPLAY (downsampled). Never what Save / Copy / Share export.
    let load: () async -> UIImage?
    /// [T-image-save-original] Where the original file is, for Save / Copy /
    /// Share / Print. nil only when the image has no file (then the displayed
    /// bitmap is exported, as before).
    var source: ImageExport.Source? = nil

    static func == (lhs: GalleryItem, rhs: GalleryItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Presentation payload for a gallery session. Wrap `.fullScreenCover(item:)`
/// around this on the chat root view.
struct GalleryPresentation: Identifiable {
    let id = UUID()
    let items: [GalleryItem]
    let startIndex: Int
}

// MARK: - MessageImageGallery

struct MessageImageGallery: View {
    let items: [GalleryItem]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var loaded: [String: UIImage] = [:]
    @State private var saveStatus: SaveStatus = .idle
    @State private var copyDone = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    /// Chrome (top action buttons + bottom caption) visibility toggled by
    /// single-tapping the image area, matching the system Photos app.
    @State private var chromeVisible: Bool = true

    private enum SaveStatus { case idle, saving, saved, failed }

    init(items: [GalleryItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        // Clamp in case the caller passes a stale/out-of-range index.
        let clamped = max(0, min(startIndex, max(items.count - 1, 0)))
        _currentIndex = State(initialValue: clamped)
    }

    private var currentItem: GalleryItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var currentImage: UIImage? {
        guard let item = currentItem else { return nil }
        return loaded[item.id]
    }

    var body: some View {
        ZStack {
            // No backdrop here — `ImagePreviewContent` renders its own
            // inside each page so it can fade in lock-step with the
            // pull-to-dismiss offset without bouncing a @Binding back
            // up through TabView and resetting the drag.
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    GalleryPage(
                        item: item,
                        image: loaded[item.id],
                        onDismiss: { dismiss() },
                        onSingleTap: { toggleChrome() }
                    )
                    .tag(index)
                    .task(id: item.id) {
                        await loadIfNeeded(item: item)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Top chrome — action buttons only (close, copy, save, share).
            VStack {
                chromeTopBar
                Spacer()
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: chromeVisible)
            .zIndex(10)

            // Bottom caption — file title, centered horizontally.
            VStack {
                Spacer()
                if let item = currentItem {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
            }
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: chromeVisible)
            .zIndex(10)
        }
        .onChange(of: currentIndex) { _ in
            // Reset per-image chrome state when swiping between pages so the
            // new image starts in an untouched state.
            saveStatus = .idle
            copyDone = false
        }
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                MinisShareSheet(url: shareURL)
            }
        }
        .statusBar(hidden: true)
    }

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    @ViewBuilder
    private var chromeTopBar: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                chromeIcon("xmark")
            }

            Spacer()

            Button {
                guard let img = currentImage else { return }
                let source = currentItem?.source
                copyDone = true
                Task {
                    await ImageExport.copy(source: source, displayed: img)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copyDone = false
                }
            } label: {
                chromeIcon(copyDone ? "checkmark" : "doc.on.doc",
                           tint: copyDone ? .green : nil)
            }
            .disabled(copyDone || currentImage == nil)

            Button {
                saveCurrentToPhotos()
            } label: {
                Group {
                    switch saveStatus {
                    case .idle:
                        Image(systemName: "square.and.arrow.down").offset(y: -1)
                    case .saving:
                        ProgressView().tint(ChatColors.primaryText)
                    case .saved:
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(ChatColors.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(saveStatus != .idle || currentImage == nil)

            Button {
                guard let img = currentImage else { return }
                let source = currentItem?.source
                Task {
                    guard let printable = await ImageExport.printableImage(source: source, displayed: img) else { return }
                    PrintHelper.printImage(printable, jobName: AppLocalized("Image"))
                }
            } label: {
                chromeIcon("printer")
            }
            .disabled(currentImage == nil)

            Button {
                guard let img = currentImage else { return }
                let source = currentItem?.source
                Task {
                    shareURL = await ImageExport.shareFile(source: source, displayed: img)
                    showShareSheet = shareURL != nil
                }
            } label: {
                chromeIcon("square.and.arrow.up")
            }
            .disabled(currentImage == nil)
        }
        .padding(.horizontal)
        .padding(.top, 7)
    }

    @ViewBuilder
    private func chromeIcon(_ name: String, tint: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint ?? ChatColors.primaryText)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .background(.ultraThinMaterial, in: Circle())
    }

    private func loadIfNeeded(item: GalleryItem) async {
        if loaded[item.id] != nil { return }
        if let img = await item.load() {
            await MainActor.run { loaded[item.id] = img }
        }
    }

    private func saveCurrentToPhotos() {
        guard let image = currentImage else { return }
        saveStatus = .saving
        // [T-image-save-original] The original file, not the display bitmap.
        ImageExport.saveToPhotos(source: currentItem?.source, displayed: image) { success in
            saveStatus = success ? .saved : .failed
            if success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    saveStatus = .idle
                }
            }
        }
    }
}

// MARK: - GalleryPage

/// A single page in the gallery — shows the zoomable content when the image is
/// loaded, otherwise a progress spinner. Pass-through horizontal drag is enabled
/// so TabView retains full control of paging gestures when the image is at
/// its default scale.
private struct GalleryPage: View {
    let item: GalleryItem
    let image: UIImage?
    let onDismiss: () -> Void
    let onSingleTap: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                ImagePreviewContent(
                    image: image,
                    onDismiss: onDismiss,
                    horizontalDragLocked: true,
                    onSingleTap: onSingleTap
                )
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

// MARK: - Environment action

/// Environment action for requesting a paged gallery preview, used by
/// user-message attachment tiles. The chat root view installs a handler that
/// presents `MessageImageGallery` in a full-screen cover.
struct OpenImageGalleryAction {
    let perform: (GalleryPresentation) -> Void

    func callAsFunction(_ presentation: GalleryPresentation) {
        perform(presentation)
    }
}

// MARK: - Markdown inline image tap routing

/// Bridge used by UIKit-level tap handlers inside `SelectableMarkdownView` to
/// request a gallery preview of all markdown-embedded images in a given
/// assistant message. SwiftUI views observe `NotificationCenter` for these
/// posts and resolve the message → gallery items list on their side.
///
/// Payload keys:
///   - `messageId: UUID` — the assistant message that owns the tapped image
///   - `sourceURL: String` — the minis:// (or http) URL inside the markdown
///     `![](...)` that was tapped; used to pick the starting page
enum MarkdownImageTapRouter {
    static let tappedNotification = Notification.Name("MarkdownImageTappedNotification")
    static let messageIdKey = "messageId"
    static let sourceURLKey = "sourceURL"

    static func postTap(messageId: UUID, sourceURL: String) {
        NotificationCenter.default.post(
            name: tappedNotification,
            object: nil,
            userInfo: [messageIdKey: messageId, sourceURLKey: sourceURL]
        )
    }
}

private struct OpenImageGalleryKey: EnvironmentKey {
    static let defaultValue: OpenImageGalleryAction = OpenImageGalleryAction { _ in }
}

extension EnvironmentValues {
    var openImageGallery: OpenImageGalleryAction {
        get { self[OpenImageGalleryKey.self] }
        set { self[OpenImageGalleryKey.self] = newValue }
    }
}
