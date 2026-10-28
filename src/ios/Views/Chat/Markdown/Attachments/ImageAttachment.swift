//
//  ImageAttachment.swift
//  Minis - markdown renderer module (Views/Chat/Markdown)
//
//  Layer: Attachments.
//
//  Markdown image. Resolves the source (minis://, file or remote), loads and
//  downsamples it asynchronously, and reserves its final size up front from
//  NativeMediaImageCache's persisted pixel sizes. Taps are handled by
//  ImageTapGesture in Media/MediaPreviewPresentation.swift.
//
//  Module map and conventions: Bridge/SelectableMarkdownView.swift.
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Image Attachment

final class ImageAttachment: NSTextAttachment {
    let source: String
    let theme: SelectableMarkdownTheme
    /// Assistant message this attachment belongs to, for resolving all sibling
    /// images in the same message when the user taps to preview. nil for
    /// contexts that aren't aware of a message (e.g. standalone previews).
    var messageId: UUID?
    /// Fingerprint (size+mtime) of the file that produced `loadedImage`.
    /// When the renderer reuses a cached attachment for the same source
    /// string, it compares this against the current on-disk fingerprint
    /// and clears `loadedImage` if they differ — so in-place rewrites of
    /// the underlying file get picked up on the next render.
    var loadedFingerprint: String?
    /// Set by `invalidateLoadedImage` when the on-disk file changed, so
    /// `updateAttachmentViews` rebuilds the `UIImageView` instead of
    /// reusing the previous view (which still holds the stale bitmap in
    /// its `UIImageView.image` property).
    var needsViewRebuild: Bool = false
    private(set) var loadedImage: UIImage?
    /// Resolved file URL of the loaded source (kept for preview/inspection).
    private var resolvedFileURL: URL?
    /// [T-ios-image-single-writer] Monotonic load generation. Every dispatch of
    /// an async load (and every invalidation) bumps it; an async completion
    /// whose captured generation no longer matches is STALE and must be
    /// dropped on the floor instead of writing `loadedImage`.
    ///
    /// This is what makes out-of-order completions impossible by construction.
    /// The predecessor design had up to three concurrent writers racing on
    /// `loadedImage` (initial load, cache adoption, and N bounds-time
    /// re-downsample tasks fired by width-bucket oscillation), guarded only by
    /// a marker that was written BEFORE the async work and never rolled back
    /// on failure — one silently-dropped task and the attachment was locked on
    /// a placeholder until the object itself was recreated (the "first open
    /// shows grey boxes, re-entering fixes it" family).
    private var loadGeneration: Int = 0
    private var isLoading = false
    /// Set when a minis:// file was not found; allows retry on next render.
    private var fileNotFound = false
    /// Number of file-not-found retries remaining (prevents infinite polling).
    private var retriesRemaining = 15
    /// Callback fired after image loads so the text view can refresh layout.
    var onLoad: (() -> Void)?

    /// [AttachHotPath] Per-instance counters: prove or refute that streaming
    /// re-runs layout / decode for the same image attachment. If these grow
    /// linearly with token count, the attachment is being thrashed.
    fileprivate var attachmentBoundsCallCount: Int = 0
    fileprivate var makeViewCallCount: Int = 0

    init(source: String, theme: SelectableMarkdownTheme, messageId: UUID? = nil) {
        self.source = source
        self.theme = theme
        self.messageId = messageId
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
        AppLogger(category: "AttachHotPath").info("[IMG][CTOR] src=\(Self.shortSrc(source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF)")
    }

    static func shortSrc(_ s: String) -> String {
        let max = 60
        return s.count <= max ? s : "…" + String(s.suffix(max - 1))
    }

    /// Rewrite a markdown image source so relative paths resolve against
    /// the active session's workspace directory. Paths that already carry
    /// a URL scheme (`http`, `https`, `minis`, `file`, …) are returned
    /// unchanged. Bare filenames and relative paths (e.g. `foo.png`,
    /// `./foo.png`, `subdir/bar.jpg`) become `minis://workspace/<path>`
    /// with non-ASCII segments percent-encoded so `URL(string:)` parses
    /// them cleanly.
    static func canonicalizeMarkdownImageSource(_ src: String) -> String {
        // Fast path: if there's any URL scheme, bail out.
        if let colon = src.firstIndex(of: ":") {
            let maybeScheme = src[src.startIndex..<colon]
            // Only accept alphabetic-prefixed schemes (RFC 3986 § 3.1).
            if !maybeScheme.isEmpty && maybeScheme.allSatisfy({ $0.isLetter }) {
                // [T-minis-url-fullwidth-pipe-ios] Exception: a minis:// source the
                // model emitted with raw non-ASCII in the path (e.g. `｜`, CJK) that
                // URL(string:) can't parse. Re-encode the path so the image resolves
                // instead of bailing with a dead source. Idempotent for already-
                // encoded URLs (encodeRawMinisURL decodes-then-encodes per segment).
                if src.hasPrefix("minis://"), URL(string: src) == nil,
                   let fixed = encodeRawMinisURL(src) {
                    return fixed.absoluteString
                }
                return src
            }
        }
        // Strip leading `./` and any leading slashes.
        var trimmed = src
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        // Percent-encode each path segment so multi-byte characters
        // (CJK, emoji, spaces) don't break URL parsing.
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let encoded = segments.map { seg -> String in
            String(seg).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
        }.joined(separator: "/")
        return "minis://workspace/\(encoded)"
    }

    /// Drop the currently-loaded bitmap so the next `beginLoadingIfNeeded`
    /// re-reads the source from disk. Called by the renderer when the
    /// on-disk fingerprint for this source changes between renders.
    func invalidateLoadedImage() {
        // [T-img-placeholder-stuck-diag] The only path that un-loads an image.
        // It was silent, which left "hasImg=true earlier, placeholder now"
        // unexplainable from a log: nothing recorded who dropped the bitmap.
        AppLogger(category: "AttachHotPath")
            .info("[IMG][INVALIDATE] src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) hadImg=\(self.loadedImage != nil) wasLoading=\(self.isLoading) gen=\(self.loadGeneration)")
        loadedImage = nil
        loadedFingerprint = nil
        resolvedFileURL = nil
        fileNotFound = false
        retriesRemaining = 15
        needsViewRebuild = true
        // [T-ios-image-single-writer] Invalidate any in-flight load: its
        // completion captured the old generation and will now be dropped,
        // so a stale bitmap can never overwrite the reload this invalidation
        // is about to trigger.
        loadGeneration &+= 1
        isLoading = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private static let placeholderHeight: CGFloat = 200
    /// Match MarkdownUI's maxWidth: 400 for images
    private static let maxImageWidth: CGFloat = 400
    /// [T-md-image-shadow-clip] Breathing room reserved on EVERY side of the
    /// rendered image inside its attachment box so the drop shadow
    /// (radius 4, y-offset 2) draws fully instead of being clipped by the
    /// text view's clipsToBounds at full-width images. attachmentBounds and
    /// makeImageView MUST use the same value or the cell height drifts.
    private static let imageShadowInset: CGFloat = 6

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        // Quantize the line-fragment width to a 4pt bucket. TextKit can call
        // attachmentBounds many times per layout pass with widths that differ
        // by sub-point floats (e.g. 329.83333 vs 330.0) as the container width
        // flows through cell self-sizing; quantizing keeps the returned box
        // geometry stable across those calls. Visually imperceptible.
        let rawWidth = lineFrag.width
        let width = (rawWidth / 4.0).rounded() * 4.0
        attachmentBoundsCallCount &+= 1
        // [AttachHotPath] Per-call log capped at first 5 + every 50 to avoid log
        // flooding while still proving cadence vs streaming token rate.
        let cnt = attachmentBoundsCallCount
        if cnt <= 5 || cnt % 50 == 0 {
            AppLogger(category: "AttachHotPath").info("[IMG][BOUNDS] #\(cnt) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) rawW=\(String(format: "%.1f", rawWidth)) bucketW=\(String(format: "%.0f", width)) hasImg=\(self.loadedImage != nil)")
        }

        // [T-img-placeholder-stuck-diag] Which branch produced the height.
        // `hasImg` alone could not distinguish "loaded" from "known-size
        // fallback" from "200pt placeholder", and the placeholder branch is
        // the one that reproduces the reported symptom.
        if cnt <= 5 || cnt % 50 == 0 {
            let branch = loadedImage != nil ? "LOADED"
                : (NativeMediaImageCache.shared.size(forSource: Self.canonicalizeMarkdownImageSource(source)) != nil ? "KNOWN-SIZE" : "PLACEHOLDER-200")
            AppLogger(category: "AttachHotPath")
                .info("[IMG][BOUNDS-BRANCH] #\(cnt) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) branch=\(branch)")
        }

        if let img = loadedImage {
            // [T-md-image-shadow-clip] Inset the displayed image by
            // shadowInset per side so the drop shadow renders INSIDE the
            // attachment box. Previously the image filled the full box width;
            // for full-width images the shadow spilled past the text view's
            // bounds (clipsToBounds=true) and was visibly cut off left/right.
            let boxWidth = min(min(width, img.size.width + Self.imageShadowInset * 2), Self.maxImageWidth)
            let imgWidth = max(boxWidth - Self.imageShadowInset * 2, 40)
            let aspect = img.size.height / max(img.size.width, 1)
            let maxH = UIScreen.main.bounds.height / 2
            let h = min(imgWidth * aspect, maxH)

            // [T-ios-image-single-writer] attachmentBounds is PURE now — it
            // measures and returns, nothing else. The bounds-time re-downsample
            // that used to live here (fire a detached decode task from inside a
            // TextKit measurement callback, replacing `loadedImage` when it
            // landed) was the root of the placeholder-stuck family: measurement
            // runs many times per layout pass at oscillating widths, so the
            // side effect fired repeatedly and concurrently, completions landed
            // out of order, and a silently-failed task left a
            // never-rolled-back marker that blocked all retries. Display-size
            // decoding now happens exactly once, in the load pipeline
            // (`displayTargetPixels`), where the aspect ratio is known and
            // there is a single completion path.

            // Return the attachment box as `imgWidth` (already clamped by
            // `maxImageWidth` and the image's own intrinsic width), NOT the
            // raw `width`. TextKit can pass `lineFrag.width = 10_000_000.0`
            // as an "unconstrained" probe during intermediate layout passes;
            // returning that value unchanged gave TextKit an attachment box
            // 10M points wide, which invalidates line-fragment geometry and
            // causes neighbouring passes (at the real container width) to
            // compute a different bounds, feeding a layout loop that can walk
            // past the 5s watchdog budget. [AttachHang fix]
            // Box = image + shadow breathing room on ALL sides (geometry must
            // match makeImageView's container exactly, or the cell height
            // drifts — the historical attachment-clip class of bugs).
            return CGRect(x: 0, y: 0, width: imgWidth + Self.imageShadowInset * 2,
                          height: h + Self.imageShadowInset * 2)
        }
        // No `loadedImage` yet — but if we've ever loaded this source before
        // we have its pixel size recorded globally. Use that to compute the
        // correct attachment height on the very first layout pass, instead of
        // returning the 200pt placeholder. Without this:
        //   1. First updateUIView creates a fresh ImageAttachment (cacheCount=0)
        //   2. SwiftUI sizeThatFits → attachmentBounds → placeholder 200pt
        //   3. Cell self-sizes to 276pt (placeholder + surrounding text)
        //   4. Async image load completes, attachmentBounds now returns 280pt
        //   5. invalidateCellSizeIfNeeded fires prev=271→new=358 delta=+87
        //   6. That late grow is sometimes lost (deferSelfSizing rejects it,
        //      SwiftUI's UIHostingConfiguration.systemLayoutSizeFitting still
        //      caches 276pt from step 3, etc.)
        //   7. Cell stays at 276pt; the UITextView inside grows to 358pt and
        //      gets clipped by the cell's clipsToBounds — image bottom cut
        //      off and the trailing prose after the image disappears.
        // [AttachHang preload-bounds fix]
        let canonicalSrc = Self.canonicalizeMarkdownImageSource(source)
        if let knownSize = NativeMediaImageCache.shared.size(forSource: canonicalSrc) {
            // [T-md-image-shadow-clip] Same inset geometry as the loaded path.
            let boxWidth = min(min(width, knownSize.width + Self.imageShadowInset * 2), Self.maxImageWidth)
            let imgWidth = max(boxWidth - Self.imageShadowInset * 2, 40)
            let aspect = knownSize.height / max(knownSize.width, 1)
            let maxH = UIScreen.main.bounds.height / 2
            let h = min(imgWidth * aspect, maxH)
            return CGRect(x: 0, y: 0, width: imgWidth + Self.imageShadowInset * 2,
                          height: h + Self.imageShadowInset * 2)
        }
        // [T-attach-bounds-probe-kick] First time we see this source. Ask for a
        // header probe before returning the 200pt box, so the NEXT layout pass
        // can take the recorded-size branch above.
        //
        // Without this the three branches formed a closed loop for any source
        // whose load had not started yet:
        //
        //   no recorded size → 200pt placeholder → no load kicked
        //     → probeAndPublishSize never runs → still no recorded size → …
        //
        // and only an outside event (the cell being rebuilt on scroll) could
        // break it. Measured on device 2026-09-22: an image written by a
        // background tool at 22:16:15 rendered at 22:16:42 with
        // `branch=PLACEHOLDER-200` five times and NO `[Load] dispatching` at
        // all; the first real load came 9m18s later when the row was scrolled
        // back into view. The file was present and decoded fine (970x1120) —
        // nothing was slow, the load simply was never asked for.
        //
        // TextKit probes this method with `lineFrag.width = 10_000_000` during
        // intermediate passes (see the loaded branch), and those passes are
        // discarded — skip them rather than spend a probe on a throwaway.
        if rawWidth < Self.unconstrainedProbeWidth {
            Self.kickHeaderProbe(source: source, canonicalSrc: canonicalSrc)
        }
        let placeholderWidth = min(width, Self.maxImageWidth)
        return CGRect(x: 0, y: 0, width: placeholderWidth, height: Self.placeholderHeight)
    }

    /// [T-attach-bounds-probe-kick] Width at or above which a `lineFrag.width`
    /// is TextKit's "unconstrained" probe rather than a real container width.
    static let unconstrainedProbeWidth: CGFloat = 1_000_000

    /// Sources a probe has already been attempted for, so a method called once
    /// per layout pass cannot queue the same work repeatedly.
    ///
    /// Deliberately records the attempt, not the success: a source that has no
    /// resolvable file (a remote URL, a deleted attachment) must not re-probe on
    /// every pass either. A successful probe records a size, which makes the
    /// branch above win and stops the calls at the source.
    private static let probeKickedLock = NSLock()
    private static var probeKicked: Set<String> = []

    /// Run `probeAndPublishSize` OFF the layout pass, once per source.
    ///
    /// `attachmentBounds` is called from inside TextKit's layout loop — tens of
    /// times per cell, thousands of times while scrolling (the diagnostic
    /// counters in this file reach `#350`). Even a millisecond-cheap
    /// `CGImageSourceCopyPropertiesAtIndex` does not belong there, and
    /// `recordSize` writes UserDefaults. So the probe is dispatched and the
    /// current pass still returns the placeholder; the notification it posts on
    /// success is what re-measures the cell.
    private static func kickHeaderProbe(source: String, canonicalSrc: String) {
        guard NativeMediaImageCache.shared.size(forSource: canonicalSrc) == nil else { return }
        probeKickedLock.lock()
        let alreadyKicked = !probeKicked.insert(canonicalSrc).inserted
        probeKickedLock.unlock()
        guard !alreadyKicked else { return }

        // Local files only. A remote source has no header to read without a
        // network fetch, which is the load pipeline's job, not a bounds call's.
        guard let url = URL(string: canonicalSrc), url.scheme == "minis" else { return }
        Task.detached(priority: .utility) {
            guard let resolved = resolveMinisFileURLForNativeText(url: url) else { return }
            imgLogger.info("[MinisImage][Probe] bounds-kick src=\(canonicalSrc) — placeholder branch had no recorded size")
            Self.probeAndPublishSize(at: resolved, canonicalSrc: canonicalSrc)
        }
    }

    /// [T-ios-image-squish-probe] Read pixel dimensions from the file HEADER
    /// only — CGImageSource property lookup decodes no pixel data, so this is
    /// millisecond-cheap even on multi-MB files. Orientation-aware: EXIF
    /// orientations 5–8 are 90°-rotated, so displayed width/height swap.
    private static func probePixelSize(at url: URL) -> CGSize? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value, (5...8).contains(o) {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    /// [T-ios-image-squish-probe] Record a header-probed size and kick the
    /// cell re-measure chain BEFORE the heavyweight decode runs. This is the
    /// fc6a5bd43 lesson applied to images: a never-seen portrait image (e.g.
    /// 400×800) used to sit on the fixed 200pt placeholder until the full
    /// read + ImageIO downsample finished, and that whole window measured the
    /// cell hundreds of points short — trailing text drew over the image.
    /// With the probe, attachmentBounds' recorded-size path returns the true
    /// aspect ratio on the very next layout pass. No-op when the size is
    /// already recorded (repeat renders, or the decode won the race).
    private static func probeAndPublishSize(at url: URL, canonicalSrc: String) {
        guard NativeMediaImageCache.shared.size(forSource: canonicalSrc) == nil else { return }
        guard let size = probePixelSize(at: url) else { return }
        NativeMediaImageCache.shared.recordSize(size, forSource: canonicalSrc)
        imgLogger.info("[MinisImage][Probe] header size=\(Int(size.width))x\(Int(size.height)) src=\(canonicalSrc) — publishing before full decode")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: canonicalSrc)
        }
    }

    /// [T-ios-image-single-writer] The ONLY code path that writes
    /// `loadedImage`. Every adoption — cache hit, disk decode, HTTP fetch —
    /// funnels through here on the main thread, and the write is always paired
    /// with the refresh signal (`onLoad` + the size-changed notification).
    ///
    /// The pairing is the whole point. Two generations of placeholder-stuck
    /// bugs on this class were, at bottom, "state changed but no signal
    /// followed": first a load completion racing the render pass (the stale
    /// `loaded=false` window), then a bounds-time re-decode assigning the
    /// property bare with no refresh behind it. Making the bare assignment
    /// inexpressible closes the class of bug, not just the two instances.
    private func adoptLoaded(_ image: UIImage, fingerprint: String, canonicalSrc: String, via: String) {
        loadedImage = image
        loadedFingerprint = fingerprint
        isLoading = false
        fileNotFound = false
        imgLogger.info("[MinisImage][Adopt] via=\(via) src=\(canonicalSrc) size=\(Int(image.size.width))x\(Int(image.size.height))")
        onLoad?()
        // Adoption grows the cell: placeholder bounds → image bounds. The
        // cell must re-measure even on the synchronous cache-hit path.
        NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: canonicalSrc)
    }

    func beginLoadingIfNeeded() {
        // Canonicalize scheme-less / relative sources to minis://workspace/…
        // so the rest of the pipeline (cache key, resolve, fingerprint)
        // treats them uniformly. Agents writing plain markdown like
        // `![img](foo.png)` or `![img](subdir/foo.png)` land here.
        let canonicalSrc = Self.canonicalizeMarkdownImageSource(source)
        if canonicalSrc != source {
            imgLogger.info("[MinisImage][Load] canonicalized src=\(self.source) → \(canonicalSrc)")
        }

        // [T-ios-image-single-writer] Cache first, flags second — the shared
        // cache is the ground truth for "is this bitmap available";
        // `isLoading` is merely scheduling state. With the guard first (the
        // old order), a view that arrived while a load was in flight returned
        // early and never saw the cache, even after that load had populated
        // it: the exact window every "first open shows grey boxes, re-enter
        // fixes it" report landed in. Fingerprint-keyed so an in-place rewrite
        // of the same minis:// path misses and falls through to a fresh decode.
        let fpKey = minisMediaCacheKey(for: canonicalSrc)
        if loadedImage == nil, let cached = NativeMediaImageCache.shared.image(for: fpKey) {
            adoptLoaded(cached, fingerprint: fpKey, canonicalSrc: canonicalSrc, via: "memory-cache")
            return
        }

        guard loadedImage == nil, !isLoading else {
            imgLogger.info("[MinisImage][Load] skip src=\(self.source) alreadyLoaded=\(self.loadedImage != nil) isLoading=\(self.isLoading) — the in-flight completion or the next render's cache check will adopt")
            return
        }
        // Reset fileNotFound so we don't spin; it will be set again if still missing.
        fileNotFound = false
        guard retriesRemaining > 0 else {
            imgLogger.warning("[MinisImage][Load] no retries left src=\(self.source)")
            return
        }
        retriesRemaining -= 1
        isLoading = true
        // [T-ios-image-single-writer] Stamp this dispatch. The completion
        // re-checks the stamp on main; invalidateLoadedImage or a newer
        // dispatch bumps it, and the stale completion is dropped instead of
        // overwriting a newer state. Out-of-order completions become
        // impossible by construction rather than improbable by guard.
        loadGeneration &+= 1
        let gen = loadGeneration
        let parsedURL = URL(string: canonicalSrc)
        imgLogger.info("[MinisImage][Load] START gen=\(gen) src=\(canonicalSrc) scheme=\(parsedURL?.scheme ?? "nil") host=\(parsedURL?.host ?? "nil") path=\(parsedURL?.path ?? "nil") ext=\(parsedURL?.pathExtension ?? "nil") retriesRemaining=\(self.retriesRemaining)")

        let src = canonicalSrc
        let isMinisURL = URL(string: src).map { $0.scheme == "minis" } ?? false
        // [T-ios-failed-image-refetch-storm] For remote (non-minis) URLs that
        // failed recently, don't re-dispatch a network fetch on every cell
        // recycle — render the placeholder and bail. minis:// is exempt: those
        // are local files that may be written shortly after the markdown
        // references them, so the retriesRemaining-scheduled flow must stay.
        if !isMinisURL, NativeMediaImageCache.shared.isRecentlyFailed(src) {
            imgLogger.info("[MinisImage][Load] SUPPRESSED (recent failure within TTL) src=\(src)")
            isLoading = false
            fileNotFound = true
            return
        }
        imgLogger.info("[MinisImage][Load] dispatching async load src=\(src) isMinisURL=\(isMinisURL)")
        // [T-ios-image-single-writer] Captured on the caller's (main) thread;
        // `displayTargetPixels` needs it off-main where UIScreen is off-limits.
        let screenScale = UIScreen.main.scale
        Task.detached(priority: .userInitiated) {
            var fileURL: URL?
            let img: UIImage?
            if let url = URL(string: src), url.scheme == "minis" {
                imgLogger.info("[MinisImage][Load] resolving minis:// URL src=\(src) host=\(url.host ?? "nil") path=\(url.path)")
                if let resolved = resolveMinisFileURLForNativeText(url: url) {
                    imgLogger.info("[MinisImage][Load] minis:// resolved to localPath=\(resolved.path)")
                    fileURL = resolved
                    // [T-ios-image-squish-probe] Publish the true aspect ratio
                    // from the file header before paying for the full decode.
                    Self.probeAndPublishSize(at: resolved, canonicalSrc: src)
                    if let data = try? Data(contentsOf: resolved) {
                        imgLogger.info("[MinisImage][Load] read \(data.count) bytes from localPath=\(resolved.path)")
                        // [T-ios-image-single-writer] Decode straight to display
                        // size — the one and only decode this image gets.
                        let downsampled = downsampleImageData(data, maxPixelSize: displayTargetPixels(for: data, screenScale: screenScale))
                        if let downsampled {
                            imgLogger.info("[MinisImage][Load] downsample OK src=\(src) resultSize=\(downsampled.size.width)x\(downsampled.size.height)")
                        } else {
                            imgLogger.error("[MinisImage][Load] downsample FAILED src=\(src) dataSize=\(data.count)")
                        }
                        img = downsampled
                    } else {
                        imgLogger.error("[MinisImage][Load] Data(contentsOf:) FAILED localPath=\(resolved.path)")
                        img = nil
                    }
                } else {
                    imgLogger.warning("[MinisImage][Load] resolveMinisFileURLForNativeText returned nil src=\(src)")
                    img = nil
                }
            } else if let url = URL(string: src), url.scheme == "http" || url.scheme == "https" {
                imgLogger.info("[MinisImage][Load] fetching HTTP(S) url=\(src)")
                if let data = try? Data(contentsOf: url) {
                    imgLogger.info("[MinisImage][Load] HTTP fetched \(data.count) bytes src=\(src)")
                    img = downsampleImageData(data, maxPixelSize: displayTargetPixels(for: data, screenScale: screenScale))
                } else {
                    imgLogger.warning("[MinisImage][Load] HTTP fetch FAILED src=\(src)")
                    img = nil
                }
            } else if let url = URL(string: src) {
                // file URL or relative
                imgLogger.info("[MinisImage][Load] trying file/relative URL scheme=\(url.scheme ?? "nil") path=\(url.path)")
                fileURL = url
                // [T-ios-image-squish-probe] Same early header probe as the
                // minis:// branch. HTTP(S) is deliberately NOT probed — a
                // range-request header fetch isn't worth the complexity; the
                // full download records the size as before.
                Self.probeAndPublishSize(at: url, canonicalSrc: src)
                if let data = try? Data(contentsOf: url) {
                    imgLogger.info("[MinisImage][Load] file loaded \(data.count) bytes src=\(src)")
                    img = downsampleImageData(data, maxPixelSize: displayTargetPixels(for: data, screenScale: screenScale))
                } else {
                    imgLogger.warning("[MinisImage][Load] file load FAILED src=\(src)")
                    img = nil
                }
            } else {
                imgLogger.error("[MinisImage][Load] cannot parse URL src=\(src)")
                img = nil
            }

            // Recompute the fingerprint post-load in case the file was
            // rewritten between the pre-check at entry and this point.
            let postLoadKey = minisMediaCacheKey(for: src)
            if let img {
                imgLogger.info("[MinisImage][Load] SUCCESS src=\(src) finalSize=\(img.size.width)x\(img.size.height) — caching in memory")
                NativeMediaImageCache.shared.set(img, for: postLoadKey)
                // Also record the size (keyed by canonical source) so future
                // ImageAttachment instances can compute correct bounds before
                // the bitmap reload finishes. [AttachHang preload-bounds]
                NativeMediaImageCache.shared.recordSize(img.size, forSource: src)
                // [T-ios-failed-image-refetch-storm] A previously-failed URL
                // that now succeeded — clear its negative-cache entry.
                if !isMinisURL { NativeMediaImageCache.shared.clearFailure(src) }
            } else {
                imgLogger.warning("[MinisImage][Load] FAILED src=\(src) — no image produced")
                // [T-ios-failed-image-refetch-storm] Negative-cache remote
                // failures so cell recycling during scroll doesn't re-fetch the
                // same broken URL every recycle (the image-session decel storm).
                // minis:// is exempt — its not-yet-written-file case is handled
                // by the retriesRemaining-scheduled retry below.
                if !isMinisURL { NativeMediaImageCache.shared.recordFailure(src) }
            }

            await MainActor.run {
                // [T-ios-image-single-writer] Stale-completion gate. If the
                // generation moved on (invalidateLoadedImage ran, or a newer
                // dispatch superseded this one), this result belongs to a dead
                // request — drop it. The bitmap is already in the shared cache
                // above, so the live generation adopts it from there anyway;
                // nothing is lost, and nothing stale ever lands.
                guard gen == self.loadGeneration else {
                    imgLogger.info("[MinisImage][Load] DROP STALE completion gen=\(gen) current=\(self.loadGeneration) src=\(src)")
                    return
                }
                self.resolvedFileURL = fileURL
                if let img {
                    self.adoptLoaded(img, fingerprint: postLoadKey, canonicalSrc: src, via: "disk-load")
                } else {
                    self.isLoading = false
                    if isMinisURL && self.retriesRemaining > 0 {
                        imgLogger.info("[MinisImage][Load] RETRY scheduled src=\(src) retriesRemaining=\(self.retriesRemaining)")
                        self.fileNotFound = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            guard let self, self.fileNotFound else { return }
                            self.beginLoadingIfNeeded()
                        }
                    } else {
                        if isMinisURL {
                            imgLogger.error("[MinisImage][Load] GAVE UP src=\(src) — all retries exhausted")
                        }
                        // Failure still signals: views waiting on this load
                        // must get a pass to render their file-not-found state
                        // instead of a placeholder that never resolves.
                        self.onLoad?()
                    }
                }
            }
        }
    }


    func makeView(width: CGFloat) -> UIView {
        makeViewCallCount &+= 1
        // [AttachHotPath] makeView call counter — the GROUND-TRUTH signal:
        // if this fires more than once per attachment per layout pass, the
        // UIImageView subview is being rebuilt and we have a leak in the
        // updateAttachmentViews reuse path.
        AppLogger(category: "AttachHotPath").info("[IMG][MAKEVIEW] #\(self.makeViewCallCount) src=\(Self.shortSrc(self.source)) ptr=\(ObjectIdentifier(self).hashValue & 0xFFFFFF) hasImg=\(self.loadedImage != nil) width=\(String(format: "%.0f", width))")
        if let img = loadedImage {
            imgLogger.info("[MinisImage][MakeView] rendering LOADED image src=\(self.source) imgSize=\(img.size.width)x\(img.size.height) containerWidth=\(width)")
            return makeImageView(img, width: width)
        } else {
            imgLogger.info("[MinisImage][MakeView] rendering PLACEHOLDER src=\(self.source) containerWidth=\(width) fileNotFound=\(self.fileNotFound) retriesRemaining=\(self.retriesRemaining)")
            return makePlaceholderView(width: width)
        }
    }

    private func makeImageView(_ img: UIImage, width: CGFloat) -> UIView {
        // [T-md-image-shadow-clip] Mirror attachmentBounds' inset geometry:
        // the image is inset by imageShadowInset per side inside the
        // attachment box so the shadow renders fully within the text view's
        // clip bounds (it used to be cut off left/right on full-width images).
        let boxWidth = min(min(width, img.size.width + Self.imageShadowInset * 2), Self.maxImageWidth)
        let imgWidth = max(boxWidth - Self.imageShadowInset * 2, 40)
        let aspect = img.size.height / max(img.size.width, 1)
        let maxH = UIScreen.main.bounds.height / 2
        let h = min(imgWidth * aspect, maxH)
        imgLogger.info("[MinisImage][MakeView] layout src=\(self.source) displayWidth=\(imgWidth) displayHeight=\(h) aspect=\(aspect) maxImageWidth=\(Self.maxImageWidth)")

        let shadowInset: CGFloat = Self.imageShadowInset
        // Container == the attachment box (image + shadow room on all sides).
        let container = UIView(frame: CGRect(x: 0, y: 0, width: imgWidth + shadowInset * 2, height: h + shadowInset * 2))
        container.backgroundColor = .clear
        container.clipsToBounds = false

        // Shadow wrapper — positioned at the inset so the shadow's spill stays
        // inside the container/attachment box.
        let shadowView = UIView(frame: CGRect(x: shadowInset, y: shadowInset, width: imgWidth, height: h))
        shadowView.backgroundColor = .clear
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowOpacity = 0.15
        shadowView.layer.shadowRadius = 4
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 2)
        shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: imgWidth, height: h), cornerRadius: 8).cgPath

        // Image view — clipped to rounded corners, black background for transparent/white images
        let imageView = UIImageView(image: img)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.frame = shadowView.bounds
        imageView.layer.cornerRadius = 8
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true

        let tap = ImageTapGesture(target: nil, action: nil)
        tap.attachedImage = img
        tap.sourceURL = source
        tap.messageId = messageId
        tap.addTarget(tap, action: #selector(ImageTapGesture.handleTap))
        imageView.addGestureRecognizer(tap)

        shadowView.addSubview(imageView)
        container.addSubview(shadowView)
        return container
    }

    private func makePlaceholderView(width: CGFloat) -> UIView {
        let h = Self.placeholderHeight
        let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: h))

        let bg = UIView(frame: CGRect(x: 0, y: 0, width: min(width, 400), height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .light)
        let icon = UIImageView(image: UIImage(systemName: "photo", withConfiguration: iconConfig))
        icon.tintColor = .tertiaryLabel
        icon.sizeToFit()
        icon.center = CGPoint(x: bg.bounds.midX, y: bg.bounds.midY - 12)
        bg.addSubview(icon)

        let filename = source.components(separatedBy: "/").last ?? source
        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 8, y: icon.frame.maxY + 8, width: bg.bounds.width - 16, height: 16)
        bg.addSubview(label)

        return container
    }
}
